import Foundation

struct PortalCLI {
    struct Result {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    static let usageHint = "usage: portal <list|show|add|set|rm|sets|set-create|set-add|set-rm|set-order|set-edit|set-delete> …  (try portal --help)"

    static let helpText = """
    portal — add and manage Wormhole command portals

    Usage:
      portal list [--set <set>] [--json]
      portal show  <name> [--json]
      portal add   --name <name> --cmd <template> [--set <set>] [options]
      portal set   <name> [options]
      portal rm    <name>

      portal sets                                   [--json]
      portal set-create <set> [--modifier <mod>]    [--json]
      portal set-add    <set> <portal>...           [--json]
      portal set-rm     <set> <portal>...           [--json]
      portal set-order  <set> <portal>...           [--json]
      portal set-edit   <set> [--name <new>] [--modifier <mod>|none] [--json]
      portal set-delete <set>
      portal --help

    Command portals run a shell command when a file is dropped on the portal
    window. Put tokens in double quotes so paths with spaces survive.

    Tokens:
      {path}      full path of the dropped file
      {filename}  last path component
      {dir}       enclosing directory

    Options for add/set:
      --symbol <sf-symbol>     default: circle.fill
      --tint <#RRGGBB>         default: #4682B4
      --glow <#RRGGBB>         default: #6BA0D0
      --cmd <template>
      --login-shell / --no-login-shell
      --cwd <path>
      --pending <verb>         default: working
      --success <label>        default: done

    Sets:
      Portals live in one library; a set is an ordered list of them, and a
      portal can be in several sets. The built-in wormhole portal is in every
      set (first, unless the set lists it elsewhere). The `default` set shows
      normally; holding a set's modifier (shift, option or control) while the
      portal window is focused swaps that set in until you let go.
      set-order replaces the set's members with exactly the portals given, in
      that order. Portals and sets are named by name or id. New portals join
      the default set.

    Examples:
      portal add --name publish --cmd '~/scripts/publish.sh --push "{path}"'
      portal add --name inbox --cmd 'cp "{path}" /path/to/this/repo/'

    If `portal` is not on PATH:
      /Applications/wormhole.app/Contents/MacOS/portal

    The JSON file is the contract. Writing
    ~/Library/Application Support/Wormhole/portals.json is a supported way
    to add a portal; `portal add` is sugar.
    """

    static func run(arguments: [String], store: PortalStore) -> Result {
        if arguments.isEmpty {
            return usage()
        }
        let head = arguments[0]
        if head == "--help" || head == "-h" || head == "help" {
            return Result(code: 0, stdout: helpText + "\n", stderr: "")
        }

        do {
            switch head {
            case "list":
                return try runList(Array(arguments.dropFirst()), store: store)
            case "show":
                return try runShow(Array(arguments.dropFirst()), store: store)
            case "add":
                return try runAdd(Array(arguments.dropFirst()), store: store)
            case "set":
                return try runSet(Array(arguments.dropFirst()), store: store)
            case "rm", "remove", "delete":
                return try runRm(Array(arguments.dropFirst()), store: store)
            case "sets":
                return try runSets(Array(arguments.dropFirst()), store: store)
            case "set-create", "set-add", "set-rm", "set-order", "set-edit", "set-delete":
                return try runSetCommand(head, Array(arguments.dropFirst()), store: store)
            default:
                return usage(extra: "unknown command '\(head)'")
            }
        } catch let error as PortalStoreError {
            return Result(code: 1, stdout: "", stderr: "error: \(error.localizedDescription)\n")
        } catch let error as CLIParseError {
            return usage(extra: error.message)
        } catch {
            return Result(code: 1, stdout: "", stderr: "error: \(error.localizedDescription)\n")
        }
    }

    private static func usage(extra: String? = nil) -> Result {
        var err = ""
        if let extra {
            err += "error: \(extra)\n"
        }
        err += usageHint + "\n"
        return Result(code: 2, stdout: "", stderr: err)
    }

    // MARK: - Commands

    private static func runList(_ args: [String], store: PortalStore) throws -> Result {
        let parsed = try parseFlags(args, takingPositionals: false)
        if parsed.unknown.isEmpty == false {
            throw CLIParseError("unknown option '\(parsed.unknown[0])'")
        }
        let library = try store.load()
        var portals = library.portals
        if let key = parsed.set {
            guard let set = library.set(named: key) else { throw PortalStoreError.setNotFound(key) }
            portals = library.portals(in: set)
            if parsed.json {
                return Result(code: 0, stdout: string(from: try PortalFile.encodeSetListing(set, portals: portals)), stderr: "")
            }
        } else if parsed.json {
            return Result(code: 0, stdout: string(from: try PortalFile.encode(library)), stderr: "")
        }
        let width = portals.map(\.name.count).max() ?? 0
        var lines: [String] = []
        for portal in portals {
            if let cmd = portal.commandConfig?.commandTemplate {
                let pad = String(repeating: " ", count: max(2, width - portal.name.count + 4))
                lines.append("  \(portal.name)\(pad)\(cmd)")
            } else {
                lines.append("  \(portal.name)")
            }
        }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return Result(code: 0, stdout: body, stderr: "")
    }

    private static func runShow(_ args: [String], store: PortalStore) throws -> Result {
        let parsed = try parseFlags(args, takingPositionals: true)
        if parsed.unknown.isEmpty == false {
            throw CLIParseError("unknown option '\(parsed.unknown[0])'")
        }
        guard let name = parsed.positionals.first else {
            throw CLIParseError("show requires a portal name")
        }
        let portals = try store.load().portals
        guard let portal = portals.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw PortalStoreError.notFound(name)
        }
        if parsed.json {
            return Result(code: 0, stdout: string(from: try PortalFile.encodeRecord(portal)), stderr: "")
        }
        var lines = [
            "name:    \(portal.name)",
            "id:      \(portal.id.uuidString)",
            "symbol:  \(portal.symbolName)",
            "tint:    \(portal.tintHex)",
            "glow:    \(portal.glowHex)"
        ]
        if let cfg = portal.commandConfig {
            lines.append("command: \(cfg.commandTemplate)")
            lines.append("login:   \(cfg.runInLoginShell)")
            lines.append("cwd:     \(cfg.workingDirectory ?? "")")
            lines.append("pending: \(cfg.pendingVerb)")
            lines.append("success: \(cfg.successLabel)")
        } else {
            lines.append("kind:    wormhole (built-in)")
        }
        return Result(code: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    private static func runAdd(_ args: [String], store: PortalStore) throws -> Result {
        let parsed = try parseFlags(args, takingPositionals: false)
        if parsed.unknown.isEmpty == false {
            throw CLIParseError("unknown option '\(parsed.unknown[0])'")
        }
        guard let name = parsed.name, !name.isEmpty else {
            throw CLIParseError("add requires --name")
        }
        guard let cmd = parsed.cmd else {
            throw CLIParseError("add requires --cmd")
        }
        if let key = parsed.set, try store.load().set(named: key) == nil {
            throw PortalStoreError.setNotFound(key)
        }
        let portal = try store.add(
            name: name,
            command: cmd,
            symbol: parsed.symbol ?? PortalDefinition.defaultCommandSymbol,
            tint: parsed.tint ?? PortalDefinition.defaultCommandTint,
            glow: parsed.glow ?? PortalDefinition.defaultCommandGlow,
            loginShell: parsed.loginShell ?? true,
            workingDirectory: parsed.cwd,
            pendingVerb: parsed.pending ?? CommandPortalConfig.template.pendingVerb,
            successLabel: parsed.success ?? CommandPortalConfig.template.successLabel
        )
        if let key = parsed.set {
            try store.mutate { try $0.addPortal(portal.id, toSet: key) }
        }
        var stderr = ""
        if !cmd.contains(PortalToken.path) {
            stderr = "warning: --cmd does not contain \(PortalToken.path); dropped files will not be passed in\n"
        }
        return Result(code: 0, stdout: "added \(portal.name)\n", stderr: stderr)
    }

    private static func runSet(_ args: [String], store: PortalStore) throws -> Result {
        let parsed = try parseFlags(args, takingPositionals: true)
        if parsed.unknown.isEmpty == false {
            throw CLIParseError("unknown option '\(parsed.unknown[0])'")
        }
        guard let target = parsed.positionals.first else {
            throw CLIParseError("set requires a portal name")
        }
        var patch = PortalPatch()
        var hasField = false
        if let name = parsed.name { patch.name = name; hasField = true }
        if let symbol = parsed.symbol { patch.symbol = symbol; hasField = true }
        if let tint = parsed.tint { patch.tint = tint; hasField = true }
        if let glow = parsed.glow { patch.glow = glow; hasField = true }
        if let cmd = parsed.cmd { patch.command = cmd; hasField = true }
        if let login = parsed.loginShell { patch.loginShell = login; hasField = true }
        if parsed.cwdWasSet {
            if let cwd = parsed.cwd, !cwd.isEmpty {
                patch.workingDirectory = cwd
            } else {
                patch.clearWorkingDirectory = true
            }
            hasField = true
        }
        if let pending = parsed.pending { patch.pendingVerb = pending; hasField = true }
        if let success = parsed.success { patch.successLabel = success; hasField = true }
        if !hasField {
            throw CLIParseError("set requires at least one option to change")
        }
        let portal = try store.update(name: target, patch: patch)
        var stderr = ""
        if let cmd = parsed.cmd, !cmd.contains(PortalToken.path) {
            stderr = "warning: --cmd does not contain \(PortalToken.path); dropped files will not be passed in\n"
        }
        return Result(code: 0, stdout: "updated \(portal.name)\n", stderr: stderr)
    }

    private static func runRm(_ args: [String], store: PortalStore) throws -> Result {
        let parsed = try parseFlags(args, takingPositionals: true)
        if parsed.unknown.isEmpty == false {
            throw CLIParseError("unknown option '\(parsed.unknown[0])'")
        }
        guard let name = parsed.positionals.first ?? parsed.name else {
            throw CLIParseError("rm requires a portal name")
        }
        try store.remove(name: name)
        return Result(code: 0, stdout: "removed \(name)\n", stderr: "")
    }

    // MARK: - Sets

    private static func runSets(_ args: [String], store: PortalStore) throws -> Result {
        let parsed = try parseFlags(args, takingPositionals: false)
        if let bad = parsed.unknown.first { throw CLIParseError("unknown option '\(bad)'") }
        let library = try store.load()
        if parsed.json {
            return Result(code: 0, stdout: string(from: try PortalFile.encodeSets(library.sets)), stderr: "")
        }
        let width = library.sets.map(\.name.count).max() ?? 0
        let lines = library.sets.map { set -> String in
            let pad = String(repeating: " ", count: max(2, width - set.name.count + 2))
            let mod = set.modifier.map { "[\($0.rawValue)] " } ?? ""
            let names = library.portals(in: set).map(\.name).joined(separator: ", ")
            return "  \(set.name)\(pad)\(mod)\(names)"
        }
        return Result(code: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    private static func runSetCommand(_ command: String, _ args: [String], store: PortalStore) throws -> Result {
        let parsed = try parseFlags(args, takingPositionals: true)
        if let bad = parsed.unknown.first { throw CLIParseError("unknown option '\(bad)'") }
        guard let key = parsed.positionals.first else { throw CLIParseError("\(command) requires a set name") }
        let rest = Array(parsed.positionals.dropFirst())

        func portalIDs(_ library: PortalLibrary) throws -> [UUID] {
            try rest.map { name in
                guard let portal = library.portal(named: name) else { throw PortalStoreError.notFound(name) }
                return portal.id
            }
        }

        if command == "set-delete" {
            if !rest.isEmpty { throw CLIParseError("set-delete takes one set name") }
            let name = try store.mutate { library -> String in
                let name = library.set(named: key)?.name ?? key
                try library.deleteSet(key)
                return name
            }
            return Result(code: 0, stdout: "deleted set \(name)\n", stderr: "")
        }

        let (set, message): (PortalSet, String) = try store.mutate { library in
            switch command {
            case "set-create":
                if !rest.isEmpty { throw CLIParseError("set-create takes one set name (quote names with spaces)") }
                let modifier = try parsed.modifier.flatMap { try PortalSetModifier.parse($0) }
                let set = try library.createSet(name: key, modifier: modifier)
                return (set, "created set \(set.name)")
            case "set-add", "set-rm":
                if rest.isEmpty { throw CLIParseError("\(command) requires at least one portal") }
                var set = try library.set(named: key) ?? { throw PortalStoreError.setNotFound(key) }()
                for id in try portalIDs(library) {
                    set = command == "set-add"
                        ? try library.addPortal(id, toSet: set.id)
                        : try library.removePortal(id, fromSet: set.id)
                }
                return (set, "\(command == "set-add" ? "added to" : "removed from") \(set.name)")
            case "set-order":
                let set = try library.orderSet(key, try portalIDs(library))
                return (set, "ordered \(set.name)")
            default: // set-edit
                if !rest.isEmpty { throw CLIParseError("set-edit takes one set name") }
                guard parsed.name != nil || parsed.modifier != nil else {
                    throw CLIParseError("set-edit requires --name or --modifier")
                }
                var set = try library.set(named: key) ?? { throw PortalStoreError.setNotFound(key) }()
                if let modifier = parsed.modifier {
                    set = try library.setModifier(set.id, try PortalSetModifier.parse(modifier))
                }
                if let name = parsed.name {
                    set = try library.renameSet(set.id, to: name)
                }
                return (set, "updated set \(set.name)")
            }
        }
        if parsed.json {
            return Result(code: 0, stdout: string(from: try PortalFile.encodeSet(set)), stderr: "")
        }
        return Result(code: 0, stdout: message + "\n", stderr: "")
    }

    // MARK: - Flag parser

    private struct Parsed {
        var json = false
        var name: String?
        var cmd: String?
        var symbol: String?
        var tint: String?
        var glow: String?
        var loginShell: Bool?
        var cwd: String?
        var cwdWasSet = false
        var pending: String?
        var success: String?
        var set: String?
        var modifier: String?
        var positionals: [String] = []
        var unknown: [String] = []
    }

    private struct CLIParseError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    private static func parseFlags(_ args: [String], takingPositionals: Bool) throws -> Parsed {
        var parsed = Parsed()
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" {
                parsed.positionals.append(contentsOf: args[(i + 1)...])
                break
            }
            if arg == "--json" {
                parsed.json = true
                i += 1
                continue
            }
            if arg == "--login-shell" {
                parsed.loginShell = true
                i += 1
                continue
            }
            if arg == "--no-login-shell" {
                parsed.loginShell = false
                i += 1
                continue
            }
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                let key = String(arg[..<eq])
                let value = String(arg[arg.index(after: eq)...])
                try assign(key: key, value: value, into: &parsed)
                i += 1
                continue
            }
            if arg.hasPrefix("--") {
                let key = arg
                switch key {
                case "--name", "--cmd", "--symbol", "--tint", "--glow", "--cwd", "--pending", "--success", "--set", "--modifier":
                    let next = i + 1
                    guard next < args.count else { throw CLIParseError("\(key) requires a value") }
                    try assign(key: key, value: args[next], into: &parsed)
                    i += 2
                    continue
                default:
                    parsed.unknown.append(arg)
                    i += 1
                    continue
                }
            }
            if arg.hasPrefix("-") && arg != "-" {
                parsed.unknown.append(arg)
                i += 1
                continue
            }
            if takingPositionals {
                parsed.positionals.append(arg)
                i += 1
                continue
            }
            parsed.unknown.append(arg)
            i += 1
        }
        return parsed
    }

    private static func assign(key: String, value: String, into parsed: inout Parsed) throws {
        switch key {
        case "--name": parsed.name = value
        case "--cmd": parsed.cmd = value
        case "--symbol": parsed.symbol = value
        case "--tint": parsed.tint = value
        case "--glow": parsed.glow = value
        case "--cwd":
            parsed.cwd = value
            parsed.cwdWasSet = true
        case "--pending": parsed.pending = value
        case "--success": parsed.success = value
        case "--set": parsed.set = value
        case "--modifier": parsed.modifier = value
        default:
            parsed.unknown.append(key)
        }
    }

    private static func string(from data: Data) -> String {
        var s = String(data: data, encoding: .utf8) ?? ""
        if !s.hasSuffix("\n") { s += "\n" }
        return s
    }
}
