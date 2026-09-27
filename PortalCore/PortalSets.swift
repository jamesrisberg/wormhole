import Foundation

/// A modifier key that, held while the portal window is key, swaps in a set.
enum PortalSetModifier: String, Codable, CaseIterable, Equatable {
    case shift, option, control

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }

    /// Parses `shift`/`option`/`control` (and `alt`, `ctrl`); `none`/empty is nil.
    static func parse(_ value: String) throws -> PortalSetModifier? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "none", "null": return nil
        case "shift": return .shift
        case "option", "alt", "opt": return .option
        case "control", "ctrl": return .control
        default: throw PortalStoreError.invalidModifier(value)
        }
    }
}

/// An ordered list of portal ids drawn from the one portal library. A portal may be
/// in several sets. The built-in wormhole portal is in every set: it is implied first
/// unless the set lists it explicitly (at any position).
struct PortalSet: Identifiable, Equatable {
    static let defaultID = "default"

    var id: String
    var name: String
    var modifier: PortalSetModifier?
    var portalIDs: [UUID]

    var isDefault: Bool { id == Self.defaultID }

    /// `portalIDs` with the built-in wormhole prepended when it is not listed.
    var resolvedIDs: [UUID] {
        portalIDs.contains(PortalDefinition.wormholeID) ? portalIDs : [PortalDefinition.wormholeID] + portalIDs
    }

    func contains(_ portalID: UUID) -> Bool { resolvedIDs.contains(portalID) }
}

/// Everything in `portals.json`: the portal library plus the sets that order it.
/// Always normalized: the built-in portal exists, a `default` set exists, set ids and
/// names are unique, set members exist in the library, and each modifier is used once.
struct PortalLibrary: Equatable {
    private(set) var portals: [PortalDefinition]
    private(set) var sets: [PortalSet]

    init(portals: [PortalDefinition], sets: [PortalSet] = []) {
        self.portals = portals
        self.sets = sets
        normalize()
    }

    /// A v1 library: one `default` set in the current portal order.
    static func migrated(from portals: [PortalDefinition]) -> PortalLibrary {
        PortalLibrary(portals: portals)
    }

    // MARK: Queries

    var defaultSet: PortalSet {
        sets.first(where: \.isDefault) ?? PortalSet(id: PortalSet.defaultID, name: "default", portalIDs: portals.map(\.id))
    }

    func set(id: String) -> PortalSet? { sets.first { $0.id == id } }

    /// Looks a set up by name (case-insensitive), then by id.
    func set(named key: String) -> PortalSet? {
        index(ofSet: key).map { sets[$0] }
    }

    func index(ofSet key: String) -> Int? {
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
        return sets.firstIndex { $0.name.lowercased() == k } ?? sets.firstIndex { $0.id.lowercased() == k }
    }

    /// The set bound to the one modifier held, or nil when none or several are held.
    func set(forHeldModifiers held: Set<PortalSetModifier>) -> PortalSet? {
        guard held.count == 1, let modifier = held.first else { return nil }
        return sets.first { $0.modifier == modifier }
    }

    /// The set's portals in order (built-in included).
    func portals(in set: PortalSet) -> [PortalDefinition] {
        set.resolvedIDs.compactMap { id in portals.first { $0.id == id } }
    }

    /// Looks a portal up by name (case-insensitive) or UUID.
    func portal(named key: String) -> PortalDefinition? {
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
        if let byName = portals.first(where: { $0.name.lowercased() == k }) { return byName }
        if let uuid = UUID(uuidString: k) { return portals.first { $0.id == uuid } }
        return nil
    }

    // MARK: Portal mutations

    /// Replaces the portal list (edits, reorders, additions, removals). Ids that disappear
    /// leave every set; new ids join the default set.
    mutating func setPortals(_ newPortals: [PortalDefinition]) {
        let old = Set(portals.map(\.id))
        portals = newPortals
        let added = newPortals.map(\.id).filter { !old.contains($0) }
        if !added.isEmpty, let i = sets.firstIndex(where: \.isDefault) {
            sets[i].portalIDs.append(contentsOf: added.filter { !sets[i].portalIDs.contains($0) })
        }
        normalize()
    }

    /// Adds a portal to the library, the default set, and any extra sets.
    mutating func addPortal(_ portal: PortalDefinition, toSets extra: [String] = []) {
        setPortals(portals + [portal])
        for key in extra {
            _ = try? addPortal(portal.id, toSet: key)
        }
    }

    mutating func updatePortal(_ portal: PortalDefinition) {
        guard let i = portals.firstIndex(where: { $0.id == portal.id }) else { return }
        portals[i] = portal
        normalize()
    }

    /// Removes a portal from the library and every set.
    mutating func removePortal(id: UUID) {
        setPortals(portals.filter { $0.id != id })
    }

    // MARK: Set mutations

    @discardableResult
    mutating func createSet(name: String, modifier: PortalSetModifier? = nil, portalIDs: [UUID] = []) throws -> PortalSet {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PortalStoreError.emptyName }
        if let existing = set(named: trimmed), existing.name.lowercased() == trimmed.lowercased() {
            throw PortalStoreError.setNameTaken(existing.name)
        }
        let set = PortalSet(id: uniqueSetID(Self.slug(trimmed)), name: trimmed, modifier: nil, portalIDs: portalIDs)
        sets.append(set)
        normalize()
        if let modifier { return try setModifier(set.id, modifier) }
        return self.set(named: set.id) ?? set
    }

    @discardableResult
    mutating func renameSet(_ key: String, to newName: String) throws -> PortalSet {
        let i = try requireSet(key)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PortalStoreError.emptyName }
        if let other = sets.first(where: { $0.name.lowercased() == trimmed.lowercased() }), other.id != sets[i].id {
            throw PortalStoreError.setNameTaken(other.name)
        }
        sets[i].name = trimmed
        return sets[i]
    }

    /// Binds `modifier` to the set, unbinding it from any other set. The default set
    /// is what shows with no modifier held, so it cannot take one.
    @discardableResult
    mutating func setModifier(_ key: String, _ modifier: PortalSetModifier?) throws -> PortalSet {
        let i = try requireSet(key)
        if modifier != nil && sets[i].isDefault { throw PortalStoreError.defaultSetModifier }
        if let modifier {
            for j in sets.indices where sets[j].modifier == modifier { sets[j].modifier = nil }
        }
        sets[i].modifier = modifier
        return sets[i]
    }

    mutating func deleteSet(_ key: String) throws {
        let i = try requireSet(key)
        if sets[i].isDefault { throw PortalStoreError.cannotDeleteDefaultSet }
        sets.remove(at: i)
    }

    @discardableResult
    mutating func addPortal(_ portalID: UUID, toSet key: String) throws -> PortalSet {
        let i = try requireSet(key)
        guard portals.contains(where: { $0.id == portalID }) else { throw PortalStoreError.notFound(portalID.uuidString) }
        if !sets[i].contains(portalID) { sets[i].portalIDs.append(portalID) }
        return sets[i]
    }

    @discardableResult
    mutating func removePortal(_ portalID: UUID, fromSet key: String) throws -> PortalSet {
        let i = try requireSet(key)
        if portalID == PortalDefinition.wormholeID { throw PortalStoreError.builtinInEverySet }
        sets[i].portalIDs.removeAll { $0 == portalID }
        return sets[i]
    }

    /// Replaces the set's members and order with `ids` (the built-in stays implied first
    /// unless listed).
    @discardableResult
    mutating func orderSet(_ key: String, _ ids: [UUID]) throws -> PortalSet {
        let i = try requireSet(key)
        for id in ids where !portals.contains(where: { $0.id == id }) {
            throw PortalStoreError.notFound(id.uuidString)
        }
        sets[i].portalIDs = ids
        normalize()
        return sets[index(ofSet: sets[i].id) ?? i]
    }

    /// `.onMove` over the set's resolved order; the result is written explicitly.
    mutating func moveInSet(_ key: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let i = index(ofSet: key) else { return }
        var ids = sets[i].resolvedIDs
        let moving = source.sorted().map { ids[$0] }
        let before = source.filter { $0 < destination }.count
        for offset in source.sorted(by: >) { ids.remove(at: offset) }
        ids.insert(contentsOf: moving, at: max(0, min(ids.count, destination - before)))
        sets[i].portalIDs = ids
    }

    // MARK: Helpers

    private func requireSet(_ key: String) throws -> Int {
        guard let i = index(ofSet: key) else { throw PortalStoreError.setNotFound(key) }
        return i
    }

    private func uniqueSetID(_ base: String) -> String {
        let taken = Set(sets.map { $0.id.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)".lowercased()) { n += 1 }
        return "\(base)-\(n)"
    }

    static func slug(_ name: String) -> String {
        var out = ""
        var dash = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !out.isEmpty && !dash {
                out.append("-")
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "set" : out
    }

    private mutating func normalize() {
        portals = PortalFile.ensureBuiltin(portals)
        let known = Set(portals.map(\.id))
        var ids = Set<String>()
        var names = Set<String>()
        var modifiers = Set<PortalSetModifier>()
        var result: [PortalSet] = []
        for var set in sets {
            set.id = set.id.trimmingCharacters(in: .whitespacesAndNewlines)
            set.name = set.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if set.name.isEmpty { set.name = set.id.isEmpty ? "set" : set.id }
            if set.id.isEmpty { set.id = Self.slug(set.name) }
            if ids.contains(set.id.lowercased()) {
                if set.isDefault { continue } // a second "default" is a duplicate, not a new set
                var n = 2
                while ids.contains("\(set.id)-\(n)".lowercased()) { n += 1 }
                set.id = "\(set.id)-\(n)"
            }
            if names.contains(set.name.lowercased()) {
                var n = 2
                while names.contains("\(set.name) \(n)".lowercased()) { n += 1 }
                set.name = "\(set.name) \(n)"
            }
            var seen = Set<UUID>()
            set.portalIDs = set.portalIDs.filter { known.contains($0) && seen.insert($0).inserted }
            if set.isDefault { set.modifier = nil }
            if let m = set.modifier {
                if modifiers.contains(m) { set.modifier = nil } else { modifiers.insert(m) }
            }
            ids.insert(set.id.lowercased())
            names.insert(set.name.lowercased())
            result.append(set)
        }
        if !result.contains(where: \.isDefault) {
            var name = "default"
            if names.contains(name) {
                var n = 2
                while names.contains("default \(n)") { n += 1 }
                name = "default \(n)"
            }
            result.insert(PortalSet(id: PortalSet.defaultID, name: name, modifier: nil, portalIDs: portals.map(\.id)), at: 0)
        }
        sets = result
    }
}
