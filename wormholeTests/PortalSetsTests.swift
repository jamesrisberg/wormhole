import AppKit
import Foundation
import Testing
@testable import wormhole

struct PortalSetsTests {
    private let copyPath = PortalDefinition.copyPath
    private let reveal = PortalDefinition.revealInFinder

    private func makeStore() throws -> (PortalStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wormhole-sets-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("portals.json")
        let suite = "wormhole.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PortalStore(fileURL: file, userDefaults: defaults), file)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Migration

    @Test func v1FileMigratesToDefaultSetInFileOrder() throws {
        let (store, file) = try makeStore()
        let v1 = """
        {"version": 1, "portals": [
          {"id": "00000000-0000-0000-0000-000000000003", "name": "Reveal in Finder", "symbol": "folder.circle.fill",
           "tint": "#C07A12", "glow": "#F0B550", "command": "open -R \\"{path}\\""},
          {"id": "00000000-0000-0000-0000-000000000001", "name": "wormhole", "symbol": "line.3.crossed.swirl.circle.fill",
           "tint": "#763483", "glow": "#A850B9"}
        ]}
        """
        try Data(v1.utf8).write(to: file)
        let library = try store.load()
        #expect(library.sets.count == 1)
        let set = library.defaultSet
        #expect(set.id == "default")
        #expect(set.modifier == nil)
        #expect(set.portalIDs == [reveal.id, PortalDefinition.wormholeID])
        // The file listed wormhole second, so it stays second rather than implied first.
        #expect(library.portals(in: set).map(\.name) == ["Reveal in Finder", "wormhole"])
        // Loading does not rewrite the file; the next save writes v2.
        #expect(try json(Data(contentsOf: file))["version"] as? Int == 1)
        try store.save(library)
        let disk = try json(Data(contentsOf: file))
        #expect(disk["version"] as? Int == 2)
        let sets = try #require(disk["sets"] as? [[String: Any]])
        #expect(sets.count == 1)
        #expect(sets[0]["id"] as? String == "default")
        #expect(sets[0].keys.contains("modifier"), "modifier is written as an explicit null")
        #expect(sets[0]["modifier"] is NSNull)
    }

    @Test func firstRunHasDefaultSetOfAllPortals() throws {
        let (store, _) = try makeStore()
        let library = try store.load()
        #expect(library.sets.map(\.id) == ["default"])
        #expect(library.portals(in: library.defaultSet).map(\.id) == PortalDefinition.firstRunPortals.map(\.id))
    }

    @Test func newerVersionIsRejectedEvenWithUnknownShape() throws {
        let (store, file) = try makeStore()
        let future = Data(#"{"version": 3, "portals": {"shape": "changed"}}"#.utf8)
        try future.write(to: file)
        #expect(throws: PortalStoreError.unknownVersion(3)) { try store.load() }
        #expect(try Data(contentsOf: file) == future)
    }

    // MARK: Codec

    @Test func v2RoundTrip() throws {
        var library = PortalLibrary(portals: PortalDefinition.firstRunPortals)
        try library.createSet(name: "Work Stuff", modifier: .shift, portalIDs: [reveal.id])
        try library.createSet(name: "alt", modifier: .option, portalIDs: [copyPath.id, PortalDefinition.wormholeID])
        let data = try PortalFile.encode(library)
        let again = try PortalFile.decode(data)
        #expect(again == library)
        let work = try #require(again.set(named: "work stuff"))
        #expect(work.id == "work-stuff")
        #expect(work.modifier == .shift)
        #expect(again.portals(in: work).map(\.name) == ["wormhole", "Reveal in Finder"], "wormhole implied first")
        let alt = try #require(again.set(named: "alt"))
        #expect(again.portals(in: alt).map(\.name) == ["Copy Path", "wormhole"], "explicit position kept")
    }

    @Test func decodeNormalizesHandEditedSets() throws {
        let doc = """
        {"version": 2, "portals": [
          {"id": "00000000-0000-0000-0000-000000000002", "name": "Copy Path", "symbol": "doc", "tint": "#000000",
           "glow": "#000000", "command": "echo"}],
         "sets": [
          {"id": "a", "name": "A", "modifier": "shift", "portals": ["00000000-0000-0000-0000-000000000002",
             "00000000-0000-0000-0000-000000000002", "11111111-1111-1111-1111-111111111111", "not-a-uuid"]},
          {"id": "b", "name": "a", "modifier": "shift", "portals": []},
          {"id": "c", "name": "C", "modifier": "hyper", "portals": []}
        ]}
        """
        let library = try PortalFile.decode(Data(doc.utf8))
        #expect(library.portals.first?.isWormhole == true, "built-in restored")
        #expect(library.sets.first?.id == "default", "missing default set is added")
        let a = try #require(library.set(id: "a"))
        #expect(a.portalIDs == [copyPath.id], "unknown and duplicate ids dropped")
        let b = try #require(library.set(id: "b"))
        #expect(b.name == "a 2", "set names are unique")
        #expect(b.modifier == nil, "each modifier binds one set")
        #expect(library.set(id: "c")?.modifier == nil, "unknown modifier dropped")
    }

    // MARK: Library operations

    @Test func setOperations() throws {
        var library = PortalLibrary(portals: PortalDefinition.firstRunPortals)
        let work = try library.createSet(name: "work")
        #expect(library.portals(in: work).map(\.isWormhole) == [true])
        #expect(throws: PortalStoreError.setNameTaken("work")) { try library.createSet(name: "Work") }
        #expect(throws: PortalStoreError.setNameTaken("default")) { try library.createSet(name: "default") }

        try library.addPortal(reveal.id, toSet: "work")
        try library.addPortal(copyPath.id, toSet: "work")
        try library.addPortal(copyPath.id, toSet: "work")
        #expect(library.set(named: "work")?.portalIDs == [reveal.id, copyPath.id])
        #expect(throws: PortalStoreError.builtinInEverySet) {
            try library.removePortal(PortalDefinition.wormholeID, fromSet: "work")
        }
        try library.removePortal(reveal.id, fromSet: "work")
        #expect(library.set(named: "work")?.portalIDs == [copyPath.id])

        try library.orderSet("work", [copyPath.id, PortalDefinition.wormholeID, reveal.id])
        #expect(library.portals(in: library.set(named: "work")!).map(\.name) == ["Copy Path", "wormhole", "Reveal in Finder"])

        library.moveInSet("work", fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(library.set(named: "work")?.portalIDs == [reveal.id, copyPath.id, PortalDefinition.wormholeID])

        try library.renameSet("work", to: "play")
        #expect(library.set(named: "play")?.id == "work", "rename keeps the id")
        #expect(library.set(named: "work")?.name == "play", "id still resolves")

        #expect(throws: PortalStoreError.cannotDeleteDefaultSet) { try library.deleteSet("default") }
        try library.deleteSet("play")
        #expect(library.sets.map(\.id) == ["default"])
        #expect(throws: PortalStoreError.setNotFound("nope")) { try library.addPortal(reveal.id, toSet: "nope") }
    }

    @Test func removingAPortalLeavesEverySet() throws {
        var library = PortalLibrary(portals: PortalDefinition.firstRunPortals)
        try library.createSet(name: "x", portalIDs: [reveal.id, copyPath.id])
        library.removePortal(id: reveal.id)
        #expect(library.set(named: "x")?.portalIDs == [copyPath.id])
        #expect(!library.defaultSet.portalIDs.contains(reveal.id))

        let added = PortalDefinition.newCommandPortal(name: "fresh")
        library.addPortal(added, toSets: ["x"])
        #expect(library.defaultSet.portalIDs.last == added.id, "new portals join the default set")
        #expect(library.set(named: "x")?.portalIDs.last == added.id)
    }

    // MARK: Modifier lookup

    @Test func modifierLookup() throws {
        var library = PortalLibrary(portals: PortalDefinition.firstRunPortals)
        try library.createSet(name: "shifted", modifier: .shift)
        try library.createSet(name: "opt", modifier: .option)
        #expect(library.set(forHeldModifiers: []) == nil)
        #expect(library.set(forHeldModifiers: [.shift])?.name == "shifted")
        #expect(library.set(forHeldModifiers: [.option])?.name == "opt")
        #expect(library.set(forHeldModifiers: [.control]) == nil)
        #expect(library.set(forHeldModifiers: [.shift, .option]) == nil, "chords pick no set")

        // Moving a modifier unbinds it from its old set; the default set cannot take one.
        try library.setModifier("opt", .shift)
        #expect(library.set(named: "shifted")?.modifier == nil)
        #expect(library.set(forHeldModifiers: [.shift])?.name == "opt")
        #expect(throws: PortalStoreError.defaultSetModifier) { try library.setModifier("default", .control) }

        #expect(try PortalSetModifier.parse("ctrl") == .control)
        #expect(try PortalSetModifier.parse("none") == nil)
        #expect(throws: PortalStoreError.invalidModifier("hyper")) { try PortalSetModifier.parse("hyper") }
    }

    @Test func trackerMasksTheHotKeyChordUntilReleased() {
        let chord: Set<PortalSetModifier> = [.option, .control]
        // Chord still held: its modifiers don't count, shift does.
        var r = ModifierSetTracker.resolve(flags: [.option, .control, .shift], mask: chord)
        #expect(r.held == [.shift])
        #expect(r.mask == chord)
        // One chord key still down: still masked.
        r = ModifierSetTracker.resolve(flags: [.control], mask: chord)
        #expect(r.held.isEmpty)
        #expect(r.mask == chord)
        // Chord released: mask cleared, later presses count.
        r = ModifierSetTracker.resolve(flags: [], mask: chord)
        #expect(r.mask.isEmpty)
        r = ModifierSetTracker.resolve(flags: [.option, .command], mask: [])
        #expect(r.held == [.option])
    }

    @Test func hotKeyParsing() {
        #expect(AppDelegate.parseHotKey("option+control+p") == HUDHotKeyShim.make("p", ["option", "control"]))
        #expect(AppDelegate.parseHotKey("Ctrl + Alt + Space") == HUDHotKeyShim.make("space", ["control", "option"]))
        #expect(AppDelegate.parseHotKey("p") == nil, "needs a modifier")
        #expect(AppDelegate.parseHotKey("hyper+p") == nil)
        #expect(AppDelegate.parseHotKey("option+nokey") == nil)
        #expect(AppDelegate.hotKeyString(AppDelegate.defaultHotKey) == "option+control+p")
    }

    @MainActor @Test func actionAcceptsCLIShape() {
        let cli = PortalHUDController.resolveAction("work", args: ["select-set": "1"])
        #expect(cli.action == "select-set")
        #expect(cli.args == ["set": "work"])
        let canonical = PortalHUDController.resolveAction("select-set", args: ["set": "work"])
        #expect(canonical.action == "select-set")
        #expect(canonical.args == ["set": "work"])
    }

    @Test func bundleShipsMacHUDManifest() throws {
        let manifest = try HUDManifest.load(fromBundleAt: Bundle.main.bundleURL)
        #expect(manifest.id == "JER.wormhole")
        #expect(manifest.socket == "wormhole")
        let panel = try #require(manifest.panel(id: "portal"))
        #expect(panel.defaultSize == HUDSize(width: 220, height: 220))
        #expect(panel.compactSize == HUDSize(width: 72, height: 72))
        #expect(panel.capabilities == ["acceptsFileDrop"])
        #expect(panel.verbs.contains("select-set"))
    }

    // MARK: CLI

    @Test func cliSetCommands() throws {
        let (store, _) = try makeStore()
        func run(_ args: String...) -> PortalCLI.Result { PortalCLI.run(arguments: args, store: store) }

        #expect(run("set-create", "work", "--modifier", "shift").code == 0)
        #expect(run("set-create", "work").code == 1, "duplicate name")
        #expect(run("set-create", "x", "--modifier", "hyper").code == 1)
        #expect(run("set-add", "work", "Reveal in Finder", "copy path").code == 0)
        #expect(run("set-add", "work", "nope").code == 1)
        #expect(run("set-add", "nope", "copy path").code == 1)

        let listed = run("list", "--set", "work")
        #expect(listed.code == 0)
        let names = listed.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(names.first == "wormhole")
        #expect(names.count == 3)
        #expect(names[1].hasPrefix("Reveal in Finder"))

        let listJSON = try json(Data(run("list", "--set", "work", "--json").stdout.utf8))
        #expect((listJSON["set"] as? [String: Any])?["modifier"] as? String == "shift")
        #expect((listJSON["portals"] as? [[String: Any]])?.map { $0["name"] as? String } == ["wormhole", "Reveal in Finder", "Copy Path"])

        let order = run("set-order", "work", "copy path", "wormhole", "--json")
        #expect(order.code == 0)
        let ordered = try json(Data(order.stdout.utf8))
        #expect(ordered["portals"] as? [String] == [copyPath.id.uuidString, PortalDefinition.wormholeID.uuidString])

        #expect(run("set-rm", "work", "wormhole").code == 1)
        #expect(run("set-rm", "work", "copy path").code == 0)

        let sets = try json(Data(run("sets", "--json").stdout.utf8))
        let records = try #require(sets["sets"] as? [[String: Any]])
        #expect(records.map { $0["id"] as? String } == ["default", "work"])
        #expect(run("sets").stdout.contains("[shift]"))

        #expect(run("set-edit", "work", "--name", "play", "--modifier", "none").code == 0)
        #expect(try store.load().set(named: "play")?.modifier == nil)
        #expect(run("set-edit", "default", "--modifier", "control").code == 1)
        #expect(run("set-delete", "default").code == 1)
        #expect(run("set-delete", "play").code == 0)
        #expect(run("list", "--set", "play").code == 1)

        // add --set puts a new portal in the default set and the named one.
        #expect(run("set-create", "inbox").code == 0)
        #expect(run("add", "--name", "drop", "--cmd", "echo \"{path}\"", "--set", "inbox").code == 0)
        let library = try store.load()
        let drop = try #require(library.portal(named: "drop"))
        #expect(library.defaultSet.portalIDs.contains(drop.id))
        #expect(library.set(named: "inbox")?.portalIDs == [drop.id])
        #expect(run("add", "--name", "other", "--cmd", "x", "--set", "missing").code == 1)
        #expect(try store.load().portal(named: "other") == nil, "nothing added when the set is missing")

        #expect(run("rm", "drop").code == 0)
        #expect(try store.load().set(named: "inbox")?.portalIDs == [])
    }
}

import HUDKit

private enum HUDHotKeyShim {
    static func make(_ key: String, _ modifiers: [String]) -> HUDHotKey { HUDHotKey(key: key, modifiers: modifiers) }
}
