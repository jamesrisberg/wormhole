import Darwin
import Foundation

/// Tokens substituted into a command portal template when a file is dropped.
/// Put them inside double quotes so paths with spaces survive.
enum PortalToken {
    static let path = "{path}"
    static let filename = "{filename}"
    static let dir = "{dir}"
}

/// Configuration for a user-defined command portal.
struct CommandPortalConfig: Codable, Equatable {
    var commandTemplate: String
    var runInLoginShell: Bool
    var workingDirectory: String?
    /// Shown as "<verb>..." while the command runs (e.g. "syncing").
    var pendingVerb: String
    /// Shown on success; supports the `{filename}` token (e.g. "added {filename}").
    var successLabel: String

    static let template = CommandPortalConfig(
        commandTemplate: "echo \"\(PortalToken.path)\"",
        runInLoginShell: true,
        workingDirectory: nil,
        pendingVerb: "working",
        successLabel: "done"
    )
}

enum PortalKind: Codable, Equatable {
    case wormhole                       // built-in, bespoke magic-wormhole send/receive
    case command(CommandPortalConfig)   // user-defined shell command
}

struct PortalDefinition: Identifiable, Equatable {
    var id: UUID
    var name: String
    var symbolName: String   // SF Symbol
    var tintHex: String      // #RRGGBB
    var glowHex: String      // #RRGGBB
    var kind: PortalKind

    var isWormhole: Bool {
        if case .wormhole = kind { return true }
        return false
    }

    var commandConfig: CommandPortalConfig? {
        if case .command(let cfg) = kind { return cfg }
        return nil
    }

    /// Stable id for the built-in Wormhole portal so identity/selection survive launches.
    static let wormholeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static let wormhole = PortalDefinition(
        id: wormholeID,
        name: "wormhole",
        symbolName: "line.3.crossed.swirl.circle.fill",
        tintHex: "#763483",
        glowHex: "#A850B9",
        kind: .wormhole
    )

    /// Sample command portals seeded on first run (only when no portals.json
    /// exists and there is nothing to migrate). Stable ids so tests and docs
    /// can refer to them; users may edit or delete them freely.
    static let copyPath = PortalDefinition(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Copy Path",
        symbolName: "doc.on.clipboard.fill",
        tintHex: "#2E8B57",
        glowHex: "#4CC38A",
        kind: .command(CommandPortalConfig(
            commandTemplate: "printf \"%s\" \"\(PortalToken.path)\" | pbcopy",
            runInLoginShell: false,
            workingDirectory: nil,
            pendingVerb: "copying",
            successLabel: "copied path of {filename}"
        ))
    )

    static let revealInFinder = PortalDefinition(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Reveal in Finder",
        symbolName: "folder.circle.fill",
        tintHex: "#C07A12",
        glowHex: "#F0B550",
        kind: .command(CommandPortalConfig(
            commandTemplate: "open -R \"\(PortalToken.path)\"",
            runInLoginShell: false,
            workingDirectory: nil,
            pendingVerb: "revealing",
            successLabel: "revealed {filename}"
        ))
    )

    /// What a brand-new install starts with.
    static let firstRunPortals: [PortalDefinition] = [.wormhole, .copyPath, .revealInFinder]

    static let defaultCommandSymbol = "circle.fill"
    static let defaultCommandTint = "#4682B4"
    static let defaultCommandGlow = "#6BA0D0"

    static func newCommandPortal(name: String = "new portal") -> PortalDefinition {
        PortalDefinition(
            id: UUID(),
            name: name,
            symbolName: defaultCommandSymbol,
            tintHex: defaultCommandTint,
            glowHex: defaultCommandGlow,
            kind: .command(.template)
        )
    }
}

enum PortalStoreError: LocalizedError, Equatable {
    case unknownVersion(Int)
    case nameTaken(String)
    case notFound(String)
    case cannotRemoveBuiltin
    case cannotChangeBuiltinCommand
    case invalidColor(String)
    case emptyName
    case io(String)
    case setNotFound(String)
    case setNameTaken(String)
    case cannotDeleteDefaultSet
    case defaultSetModifier
    case builtinInEverySet
    case invalidModifier(String)

    var errorDescription: String? {
        switch self {
        case .unknownVersion(let v):
            return "portals.json version \(v) is not supported"
        case .nameTaken(let name):
            return "a portal named '\(name)' already exists"
        case .notFound(let name):
            return "no portal named '\(name)'"
        case .cannotRemoveBuiltin:
            return "cannot remove the built-in wormhole portal"
        case .cannotChangeBuiltinCommand:
            return "cannot give the built-in wormhole portal a command"
        case .invalidColor(let value):
            return "invalid color '\(value)' (expected #RRGGBB)"
        case .emptyName:
            return "portal name cannot be empty"
        case .io(let message):
            return message
        case .setNotFound(let name):
            return "no set named '\(name)'"
        case .setNameTaken(let name):
            return "a set named '\(name)' already exists"
        case .cannotDeleteDefaultSet:
            return "cannot delete the default set"
        case .defaultSetModifier:
            return "the default set is the one shown with no modifier held; it cannot take a modifier"
        case .builtinInEverySet:
            return "the built-in wormhole portal is in every set"
        case .invalidModifier(let value):
            return "invalid modifier '\(value)' (expected shift, option, control or none)"
        }
    }
}

/// Optional field updates for `portal set`.
struct PortalPatch: Equatable {
    var name: String?
    var symbol: String?
    var tint: String?
    var glow: String?
    var command: String?
    var loginShell: Bool?
    var workingDirectory: String?
    var clearWorkingDirectory: Bool = false
    var pendingVerb: String?
    var successLabel: String?
}

/// On-disk contract for `~/Library/Application Support/Wormhole/portals.json`.
/// Flat records — not Swift enum Codable (`kind.command._0`).
///
/// Version 2 adds `sets`: `[{"id", "name", "modifier": null|"shift"|"option"|"control",
/// "portals": [portal ids]}]`. Version 1 files load as one `default` set in file order
/// and are written back as version 2 on the next save.
enum PortalFile {
    static let currentVersion = 2
    static let defaultsKey = "portalDefinitions_v1"

    static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("Wormhole", isDirectory: true)
            .appendingPathComponent("portals.json")
    }

    static func encode(_ library: PortalLibrary) throws -> Data {
        let doc = Document(
            version: currentVersion,
            portals: library.portals.map(Record.init(definition:)),
            sets: library.sets.map(SetRecord.init(set:))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(doc)
    }

    static func encodeRecord(_ portal: PortalDefinition) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Record(definition: portal))
    }

    static func decode(_ data: Data) throws -> PortalLibrary {
        let decoder = JSONDecoder()
        // Check the version before the body so a newer file with a different shape
        // reports unknownVersion rather than a parse error.
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).version
        } catch {
            throw PortalStoreError.io("could not read portals.json: \(error.localizedDescription)")
        }
        guard version == 1 || version == currentVersion else {
            throw PortalStoreError.unknownVersion(version)
        }
        let doc: Document
        do {
            doc = try decoder.decode(Document.self, from: data)
        } catch {
            throw PortalStoreError.io("could not read portals.json: \(error.localizedDescription)")
        }
        let portals = ensureBuiltin(doc.portals.map { $0.definition() })
        if version == 1 || doc.sets == nil {
            return PortalLibrary.migrated(from: portals)
        }
        return PortalLibrary(portals: portals, sets: (doc.sets ?? []).map { $0.set() })
    }

    static func encodeSet(_ set: PortalSet) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(SetRecord(set: set))
    }

    static func encodeSets(_ sets: [PortalSet]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(["sets": sets.map(SetRecord.init(set:))])
    }

    /// `portal list --set <name> --json`: the set plus its portals in order.
    static func encodeSetListing(_ set: PortalSet, portals: [PortalDefinition]) throws -> Data {
        struct Listing: Encodable {
            var set: SetRecord
            var portals: [Record]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Listing(set: SetRecord(set: set), portals: portals.map(Record.init(definition:))))
    }

    /// UserDefaults `portalDefinitions_v1` payload — Swift enum Codable, migrate-only.
    static func decodeLegacy(_ data: Data) throws -> [PortalDefinition] {
        let records = try JSONDecoder().decode([LegacyRecord].self, from: data)
        return ensureBuiltin(records.map { $0.definition() })
    }

    static func ensureBuiltin(_ portals: [PortalDefinition]) -> [PortalDefinition] {
        var result = portals
        if let idx = result.firstIndex(where: { $0.id == PortalDefinition.wormholeID || $0.isWormhole }) {
            var builtin = result[idx]
            builtin.id = PortalDefinition.wormholeID
            builtin.kind = .wormhole
            result[idx] = builtin
            // Collapse any extra wormhole-kind rows into the canonical builtin.
            var seenBuiltin = false
            result = result.filter { portal in
                if portal.isWormhole || portal.id == PortalDefinition.wormholeID {
                    if seenBuiltin { return false }
                    seenBuiltin = true
                    return true
                }
                return true
            }
        } else {
            result.insert(.wormhole, at: 0)
        }
        return result
    }

    static func normalizeHex(_ value: String) throws -> String {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else {
            throw PortalStoreError.invalidColor(value)
        }
        return "#" + s.uppercased()
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }

    fileprivate struct Document: Codable {
        var version: Int
        var portals: [Record]
        var sets: [SetRecord]?

        enum CodingKeys: String, CodingKey {
            case version, portals, sets
        }

        init(version: Int, portals: [Record], sets: [SetRecord]?) {
            self.version = version
            self.portals = portals
            self.sets = sets
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            portals = try c.decode([Record].self, forKey: .portals)
            sets = try c.decodeIfPresent([SetRecord].self, forKey: .sets)
        }
    }

    fileprivate struct SetRecord: Codable {
        var id: String
        var name: String
        var modifier: String?
        var portals: [String]

        enum CodingKeys: String, CodingKey {
            case id, name, modifier, portals
        }

        init(set: PortalSet) {
            id = set.id
            name = set.name
            modifier = set.modifier?.rawValue
            portals = set.portalIDs.map(\.uuidString)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            modifier = try c.decodeIfPresent(String.self, forKey: .modifier)
            portals = try c.decodeIfPresent([String].self, forKey: .portals) ?? []
        }

        /// `modifier` is written as an explicit null so the key is always visible to hand-editors.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(modifier, forKey: .modifier)
            try c.encode(portals, forKey: .portals)
        }

        /// Unknown modifiers and malformed ids are dropped rather than failing the file.
        func set() -> PortalSet {
            PortalSet(
                id: id,
                name: name,
                modifier: modifier.flatMap { try? PortalSetModifier.parse($0) },
                portalIDs: portals.compactMap(UUID.init(uuidString:))
            )
        }
    }

    fileprivate struct Record: Codable {
        var id: UUID
        var name: String
        var symbol: String
        var tint: String
        var glow: String
        var command: String?
        var loginShell: Bool?
        var workingDirectory: String?
        var pendingVerb: String?
        var successLabel: String?

        init(definition: PortalDefinition) {
            id = definition.id
            name = definition.name
            symbol = definition.symbolName
            tint = definition.tintHex
            glow = definition.glowHex
            if let cfg = definition.commandConfig {
                command = cfg.commandTemplate
                loginShell = cfg.runInLoginShell
                workingDirectory = cfg.workingDirectory
                pendingVerb = cfg.pendingVerb
                successLabel = cfg.successLabel
            } else {
                command = nil
                loginShell = nil
                workingDirectory = nil
                pendingVerb = nil
                successLabel = nil
            }
        }

        func definition() -> PortalDefinition {
            let kind: PortalKind
            if id == PortalDefinition.wormholeID || command == nil {
                kind = .wormhole
            } else {
                kind = .command(CommandPortalConfig(
                    commandTemplate: command ?? CommandPortalConfig.template.commandTemplate,
                    runInLoginShell: loginShell ?? true,
                    workingDirectory: workingDirectory,
                    pendingVerb: pendingVerb ?? CommandPortalConfig.template.pendingVerb,
                    successLabel: successLabel ?? CommandPortalConfig.template.successLabel
                ))
            }
            return PortalDefinition(
                id: id,
                name: name,
                symbolName: symbol,
                tintHex: tint,
                glowHex: glow,
                kind: kind
            )
        }
    }

    /// Matches the in-app UserDefaults encoding of `PortalDefinition` prior to the file store.
    fileprivate struct LegacyRecord: Codable {
        var id: UUID
        var name: String
        var symbolName: String
        var tintHex: String
        var glowHex: String
        var kind: PortalKind

        func definition() -> PortalDefinition {
            PortalDefinition(
                id: id,
                name: name,
                symbolName: symbolName,
                tintHex: tintHex,
                glowHex: glowHex,
                kind: kind
            )
        }
    }
}

/// Load, save (atomic temp + rename), migrate, add/set/rm, ensure builtin.
/// Store path is injectable so tests can use a temp dir.
final class PortalStore {
    let fileURL: URL
    private let userDefaults: UserDefaults
    private let defaultsKey: String
    private var watchSource: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var onChange: ((PortalLibrary) -> Void)?
    private let debounceNanos: UInt64
    /// Bytes of our own most recent write, so the watcher can ignore echoes of
    /// it without also ignoring a different write that lands shortly after.
    private var lastWrittenData: Data?

    init(
        fileURL: URL = PortalFile.defaultFileURL(),
        userDefaults: UserDefaults = .standard,
        defaultsKey: String = PortalFile.defaultsKey,
        debounceNanoseconds: UInt64 = 100_000_000
    ) {
        self.fileURL = fileURL
        self.userDefaults = userDefaults
        self.defaultsKey = defaultsKey
        self.debounceNanos = debounceNanoseconds
    }

    deinit {
        stopWatching()
    }

    /// Loads the file, or migrates UserDefaults, or (first run) seeds
    /// `PortalDefinition.firstRunPortals`.
    /// Unknown future versions throw without writing. A version 1 file is returned
    /// migrated (one `default` set) but is not rewritten until the next save.
    func load() throws -> PortalLibrary {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw PortalStoreError.io("could not read \(fileURL.path): \(error.localizedDescription)")
            }
            return try PortalFile.decode(data)
        }

        if let data = userDefaults.data(forKey: defaultsKey), !data.isEmpty,
           let migrated = try? PortalFile.decodeLegacy(data), !migrated.isEmpty {
            let library = PortalLibrary.migrated(from: migrated)
            try save(library)
            userDefaults.removeObject(forKey: defaultsKey)
            return library
        }

        let library = PortalLibrary(portals: PortalDefinition.firstRunPortals)
        try save(library)
        return library
    }

    func save(_ library: PortalLibrary) throws {
        let data = try PortalFile.encode(library)
        let dir = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let tempURL = dir.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
            try data.write(to: tempURL, options: .withoutOverwriting)
            if fm.fileExists(atPath: fileURL.path) {
                _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: fileURL)
            }
            lastWrittenData = data
        } catch let error as PortalStoreError {
            throw error
        } catch {
            throw PortalStoreError.io("could not write \(fileURL.path): \(error.localizedDescription)")
        }
    }

    /// Loads, applies `body`, saves. The file is untouched if `body` throws.
    @discardableResult
    func mutate<T>(_ body: (inout PortalLibrary) throws -> T) throws -> T {
        var library = try load()
        let result = try body(&library)
        try save(library)
        return result
    }

    func add(
        name: String,
        command: String,
        symbol: String = PortalDefinition.defaultCommandSymbol,
        tint: String = PortalDefinition.defaultCommandTint,
        glow: String = PortalDefinition.defaultCommandGlow,
        loginShell: Bool = true,
        workingDirectory: String? = nil,
        pendingVerb: String = CommandPortalConfig.template.pendingVerb,
        successLabel: String = CommandPortalConfig.template.successLabel
    ) throws -> PortalDefinition {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PortalStoreError.emptyName }
        var library = try load()
        if let existing = library.portals.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            throw PortalStoreError.nameTaken(existing.name)
        }
        let portal = PortalDefinition(
            id: UUID(),
            name: trimmed,
            symbolName: symbol,
            tintHex: try PortalFile.normalizeHex(tint),
            glowHex: try PortalFile.normalizeHex(glow),
            kind: .command(CommandPortalConfig(
                commandTemplate: command,
                runInLoginShell: loginShell,
                workingDirectory: workingDirectory,
                pendingVerb: pendingVerb,
                successLabel: successLabel
            ))
        )
        library.addPortal(portal)
        try save(library)
        return portal
    }

    func update(name: String, patch: PortalPatch) throws -> PortalDefinition {
        var library = try load()
        let portals = library.portals
        guard let idx = portals.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw PortalStoreError.notFound(name)
        }
        var portal = portals[idx]
        if let newName = patch.name {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw PortalStoreError.emptyName }
            if trimmed.lowercased() != portal.name.lowercased(),
               let existing = portals.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                throw PortalStoreError.nameTaken(existing.name)
            }
            portal.name = trimmed
        }
        if let symbol = patch.symbol { portal.symbolName = symbol }
        if let tint = patch.tint { portal.tintHex = try PortalFile.normalizeHex(tint) }
        if let glow = patch.glow { portal.glowHex = try PortalFile.normalizeHex(glow) }

        let wantsCommandChange = patch.command != nil || patch.loginShell != nil
            || patch.workingDirectory != nil || patch.clearWorkingDirectory
            || patch.pendingVerb != nil || patch.successLabel != nil
        if portal.isWormhole && (patch.command != nil) {
            throw PortalStoreError.cannotChangeBuiltinCommand
        }
        if !portal.isWormhole, var cfg = portal.commandConfig {
            if let command = patch.command { cfg.commandTemplate = command }
            if let loginShell = patch.loginShell { cfg.runInLoginShell = loginShell }
            if patch.clearWorkingDirectory { cfg.workingDirectory = nil }
            else if let cwd = patch.workingDirectory { cfg.workingDirectory = cwd }
            if let pending = patch.pendingVerb { cfg.pendingVerb = pending }
            if let success = patch.successLabel { cfg.successLabel = success }
            portal.kind = .command(cfg)
        } else if !portal.isWormhole && wantsCommandChange && portal.commandConfig == nil {
            // Shouldn't happen; treat as command portal with template defaults.
            var cfg = CommandPortalConfig.template
            if let command = patch.command { cfg.commandTemplate = command }
            if let loginShell = patch.loginShell { cfg.runInLoginShell = loginShell }
            if patch.clearWorkingDirectory { cfg.workingDirectory = nil }
            else if let cwd = patch.workingDirectory { cfg.workingDirectory = cwd }
            if let pending = patch.pendingVerb { cfg.pendingVerb = pending }
            if let success = patch.successLabel { cfg.successLabel = success }
            portal.kind = .command(cfg)
        }

        library.updatePortal(portal)
        try save(library)
        return portal
    }

    func remove(name: String) throws {
        var library = try load()
        let portals = library.portals
        guard let idx = portals.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw PortalStoreError.notFound(name)
        }
        if portals[idx].isWormhole {
            throw PortalStoreError.cannotRemoveBuiltin
        }
        library.removePortal(id: portals[idx].id)
        try save(library)
    }

    func startWatching(onChange: @escaping (PortalLibrary) -> Void) {
        stopWatching()
        self.onChange = onChange
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            print("❌ could not watch \(dir.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .link, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        watchSource = source
    }

    func stopWatching() {
        debounceWork?.cancel()
        debounceWork = nil
        watchSource?.cancel()
        watchSource = nil
        onChange = nil
    }

    private func scheduleReload() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: self.fileURL)
                if data == self.lastWrittenData { return }
                let library = try PortalFile.decode(data)
                self.onChange?(library)
            } catch {
                print("❌ portal reload failed: \(error.localizedDescription)")
            }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(debounceNanos)), execute: work)
    }
}
