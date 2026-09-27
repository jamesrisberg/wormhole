import Foundation
import Testing
@testable import wormhole

struct PortalStoreTests {
    private func makeStore() throws -> (PortalStore, URL, UserDefaults) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wormhole-portal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("portals.json")
        let suiteName = "wormhole.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = PortalStore(fileURL: file, userDefaults: defaults)
        return (store, file, defaults)
    }

    @Test func migrateFromUserDefaultsFixture() throws {
        let (store, file, defaults) = try makeStore()
        let fixture = """
        [{"id":"00000000-0000-0000-0000-000000000001","name":"wormhole","symbolName":"line.3.crossed.swirl.circle.fill","tintHex":"#763483","glowHex":"#A850B9","kind":{"wormhole":{}}},{"id":"F75709B4-CC5E-4304-A5EF-FFEB0E68FD02","name":"publish","symbolName":"photo.circle.fill","tintHex":"#4682B4","glowHex":"#64A0D2","kind":{"command":{"_0":{"commandTemplate":"~/scripts/publish.sh --push \\"{path}\\"","runInLoginShell":true,"pendingVerb":"syncing","successLabel":"added {filename}"}}}}]
        """.data(using: .utf8)!
        defaults.set(fixture, forKey: PortalFile.defaultsKey)

        let portals = try store.load().portals
        #expect(portals.count == 2)
        #expect(portals.contains(where: { $0.isWormhole }))
        let published = portals.first { $0.name == "publish" }
        #expect(published?.commandConfig?.commandTemplate.contains("publish.sh") == true)
        #expect(published?.symbolName == "photo.circle.fill")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(defaults.data(forKey: PortalFile.defaultsKey) == nil)

        let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(disk?["version"] as? Int == 2)
        let records = disk?["portals"] as? [[String: Any]]
        #expect(records?.contains(where: { $0["kind"] != nil }) == false)
        #expect(records?.contains(where: { $0["symbolName"] != nil }) == false)
        #expect(records?.contains(where: { $0["symbol"] as? String == "photo.circle.fill" }) == true)
    }

    @Test func firstRunSeedsSamplePortals() throws {
        let (store, file, _) = try makeStore()
        let portals = try store.load().portals
        #expect(portals.map(\.name) == ["wormhole", "Copy Path", "Reveal in Finder"])
        #expect(portals[1].commandConfig?.commandTemplate == "printf \"%s\" \"{path}\" | pbcopy")
        #expect(portals[2].commandConfig?.commandTemplate == "open -R \"{path}\"")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func existingFileIsNotReseeded() throws {
        let (store, _, _) = try makeStore()
        _ = try store.load()
        try store.remove(name: "Copy Path")
        try store.remove(name: "Reveal in Finder")
        #expect(try store.load().portals.map(\.name) == ["wormhole"])
    }

    @Test func addListRemove() throws {
        let (store, _, _) = try makeStore()
        _ = try store.load()
        let added = try store.add(
            name: "publish",
            command: "~/scripts/publish.sh --push \"{path}\""
        )
        #expect(added.name == "publish")
        let listed = try store.load().portals
        #expect(listed.map(\.name) == ["wormhole", "Copy Path", "Reveal in Finder", "publish"])
        try store.remove(name: "publish")
        #expect(try store.load().portals.map(\.name) == ["wormhole", "Copy Path", "Reveal in Finder"])
    }

    @Test func uniqueNames() throws {
        let (store, _, _) = try makeStore()
        _ = try store.add(name: "inbox", command: "cp \"{path}\" ~/inbox/")
        do {
            _ = try store.add(name: "Inbox", command: "echo \"{path}\"")
            Issue.record("expected nameTaken")
        } catch let error as PortalStoreError {
            #expect(error == .nameTaken("inbox"))
        }
    }

    @Test func cannotRemoveBuiltin() throws {
        let (store, _, _) = try makeStore()
        _ = try store.load()
        do {
            try store.remove(name: "wormhole")
            Issue.record("expected cannotRemoveBuiltin")
        } catch let error as PortalStoreError {
            #expect(error == .cannotRemoveBuiltin)
        }
        #expect(try store.load().portals.contains(where: { $0.isWormhole }))
    }

    @Test func cannotGiveBuiltinACommand() throws {
        let (store, _, _) = try makeStore()
        _ = try store.load()
        do {
            _ = try store.update(name: "wormhole", patch: PortalPatch(command: "echo \"{path}\""))
            Issue.record("expected cannotChangeBuiltinCommand")
        } catch let error as PortalStoreError {
            #expect(error == .cannotChangeBuiltinCommand)
        }
    }

    @Test func jsonRoundTrip() throws {
        let (store, file, _) = try makeStore()
        _ = try store.add(
            name: "publish",
            command: "~/scripts/publish.sh --push \"{path}\"",
            symbol: "photo.circle.fill",
            tint: "#4682B4",
            glow: "#6BA0D0",
            loginShell: true,
            workingDirectory: nil,
            pendingVerb: "syncing",
            successLabel: "added {filename}"
        )
        let data = try Data(contentsOf: file)
        let again = try PortalFile.decode(data).portals
        #expect(again.count == PortalDefinition.firstRunPortals.count + 1)
        let published = again.first { $0.name == "publish" }
        #expect(published?.commandConfig?.pendingVerb == "syncing")
        #expect(published?.commandConfig?.successLabel == "added {filename}")

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let records = try #require(object?["portals"] as? [[String: Any]])
        for record in records {
            #expect(record["kind"] == nil)
            #expect(record["symbolName"] == nil)
            #expect(record["tintHex"] == nil)
        }
    }

    @Test func unknownVersionDoesNotClobber() throws {
        let (store, file, _) = try makeStore()
        let original = """
        { "version": 99, "portals": [] }
        """.data(using: .utf8)!
        try original.write(to: file)
        do {
            _ = try store.load()
            Issue.record("expected unknownVersion")
        } catch let error as PortalStoreError {
            #expect(error == .unknownVersion(99))
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func cliUsageExitsTwo() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wormhole-cli-usage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PortalStore(fileURL: dir.appendingPathComponent("portals.json"))
        let empty = PortalCLI.run(arguments: [], store: store)
        #expect(empty.code == 2)
        #expect(empty.stdout.isEmpty)
        #expect(empty.stderr.contains("usage:"))
        let unknown = PortalCLI.run(arguments: ["nope"], store: store)
        #expect(unknown.code == 2)
        let help = PortalCLI.run(arguments: ["--help"], store: store)
        #expect(help.code == 0)
        #expect(help.stdout.contains("{path}"))
        #expect(help.stdout.contains("publish.sh"))
        #expect(help.stdout.contains("cp \"{path}\""))
        #expect(help.stdout.contains("/Applications/wormhole.app/Contents/MacOS/portal"))
    }

    @Test func cliAddListRmJson() throws {
        let (store, _, _) = try makeStore()
        let add = PortalCLI.run(
            arguments: [
                "add", "--name", "publish",
                "--cmd", "~/scripts/publish.sh --push \"{path}\""
            ],
            store: store
        )
        #expect(add.code == 0)
        let listed = PortalCLI.run(arguments: ["list"], store: store)
        #expect(listed.code == 0)
        #expect(listed.stdout.contains("wormhole"))
        #expect(listed.stdout.contains("publish"))
        let json = PortalCLI.run(arguments: ["list", "--json"], store: store)
        #expect(json.code == 0)
        let object = try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any]
        #expect(object?["version"] as? Int == 2)
        let missing = PortalCLI.run(arguments: ["show", "nope"], store: store)
        #expect(missing.code == 1)
        let rmBuiltin = PortalCLI.run(arguments: ["rm", "wormhole"], store: store)
        #expect(rmBuiltin.code == 1)
        let rm = PortalCLI.run(arguments: ["rm", "publish"], store: store)
        #expect(rm.code == 0)
    }

    @Test func cliWarnsWhenCmdMissingPathToken() throws {
        let (store, _, _) = try makeStore()
        let add = PortalCLI.run(
            arguments: ["add", "--name", "inbox", "--cmd", "echo hello"],
            store: store
        )
        #expect(add.code == 0)
        #expect(add.stderr.contains("{path}"))
    }

    @Test func cliBinaryUsageExitsTwo() throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/portal")
        #expect(FileManager.default.isExecutableFile(atPath: url.path), "portal helper should be embedded in the app")
        let proc = Process()
        proc.executableURL = url
        proc.arguments = []
        let err = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 2)
    }
}
