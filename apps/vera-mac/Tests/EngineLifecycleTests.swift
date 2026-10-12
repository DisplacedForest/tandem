import Foundation

struct TestFailure: Error { let message: String }

@MainActor
final class EngineFixture {
    let root: URL
    let layout: EngineLayout
    var active: String?
    var failedVersions = Set<String>()
    var bootstrapFailures = Set<String>()
    var commands: [[String]] = []
    var requests: [URL] = []
    var stopFails = false
    var checksumFails = false
    var networkFails = false
    var extractionFails = false
    var extractionMissing = false
    var duringDownload: (() async throws -> Void)?
    var duringHealth: (() throws -> Void)?
    var duringProbe: (() async -> Void)?
    let archiveBytes = Data("fixture archive".utf8)

    init(existingRoot: URL? = nil) throws {
        root = existingRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("engine-test-\(UUID().uuidString)/root & <é>")
        layout = EngineLayout(root: root, home: root.appendingPathComponent("fake-home"))
        try FileManager.default.createDirectory(at: layout.dataDir, withIntermediateDirectories: true)
        try Data("preserved task data".utf8).write(to: layout.dataDir.appendingPathComponent("tasks.db"))
    }

    func clean() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func binary(_ version: String) throws {
        try makeBinary(layout.binary(version))
    }

    func makeBinary(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture executable".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func seed(_ version: String = "1.0.0", port: Int = 8089) throws -> Data {
        try binary(version)
        try FileManager.default.createDirectory(at: layout.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try layout.plist(binary: layout.binary(version), port: port)
        try bytes.write(to: layout.launchAgent)
        active = version
        return bytes
    }

    func manager() -> EngineManager {
        EngineManager(configURL: root.appendingPathComponent("config.json"), operations: operations())
    }

    func operations() -> EngineOperations {
        EngineOperations(command: { path, arguments in
            self.commands.append([path] + arguments)
            if path == "/usr/bin/ditto" {
                if self.extractionFails { return EngineCommandResult(status: 1, output: "fixture failure") }
                if !self.extractionMissing {
                    try self.makeBinary(URL(fileURLWithPath: arguments.last!).appendingPathComponent("vera-api/vera-api"))
                }
            } else if path == "/bin/launchctl", arguments.first == "bootout" {
                if self.stopFails { return EngineCommandResult(status: 1, output: "fixture failure") }
                self.active = nil
            } else if path == "/bin/launchctl", arguments.first == "bootstrap" {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: arguments.last!))
                let object = try PropertyListSerialization.propertyList(from: bytes, format: nil) as! [String: Any]
                let binary = (object["ProgramArguments"] as! [String])[0]
                let version = URL(fileURLWithPath: binary).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                if self.bootstrapFailures.contains(version) { return EngineCommandResult(status: 1, output: "fixture failure") }
                self.active = self.failedVersions.contains(version) ? nil : version
            } else if path == "/bin/launchctl", arguments.first == "print" {
                return EngineCommandResult(status: self.active == nil ? 113 : 0, output: "last exit code = 0\n")
            } else { throw TestFailure(message: "Unexpected command: \(path)") }
            return EngineCommandResult(status: 0, output: "")
        }, request: { request in
            let url = request.url!
            self.requests.append(url)
            var data: Data
            if url.path == "/version" {
                if let action = self.duringProbe {
                    self.duringProbe = nil
                    await action()
                }
                if let action = self.duringHealth, self.commands.contains(where: { $0.contains("bootstrap") }) {
                    self.duringHealth = nil
                    try action()
                }
                guard let active = self.active else { throw URLError(.cannotConnectToHost) }
                data = try JSONSerialization.data(withJSONObject: ["version": active])
            } else if url.path.hasSuffix("/releases/tags/v2.0.0") {
                if self.networkFails { throw URLError(.notConnectedToInternet) }
                data = try JSONSerialization.data(withJSONObject: [
                    "tag_name": "v2.0.0",
                    "assets": [
                        ["name": EngineManager.engineZipName, "browser_download_url": "https://fixture.invalid/engine.zip"],
                        ["name": EngineManager.engineShaName, "browser_download_url": "https://fixture.invalid/engine.sha256"],
                    ],
                ])
            } else if url.path == "/engine.sha256" {
                data = Data((self.checksumFails ? String(repeating: "0", count: 64) : EngineManager.sha256Hex(self.archiveBytes)).utf8)
            } else { throw TestFailure(message: "Unexpected request: \(url)") }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, download: { _ in
            try await self.duringDownload?()
            let file = self.root.appendingPathComponent("download.zip")
            try self.archiveBytes.write(to: file)
            return file
        }, pause: {}, attempts: 2)
    }

    func preserved() throws {
        let bytes = try Data(contentsOf: layout.dataDir.appendingPathComponent("tasks.db"))
        try expect(bytes == Data("preserved task data".utf8), "Data changed")
        try expect(commands.allSatisfy { !$0.contains("gui/\(getuid())/com.vera.engine") }, "Fixture reached default job")
    }
}

@MainActor
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure(message: message) }
}

@main
struct EngineLifecycleTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--interrupt-fixture" {
            let fixture = try EngineFixture(existingRoot: URL(fileURLWithPath: CommandLine.arguments[2]))
            _ = try fixture.seed()
            fixture.duringHealth = { kill(getpid(), SIGKILL) }
            await fixture.manager().installAndStart()
            throw TestFailure(message: "Interrupted fixture did not terminate")
        }
        var passed = 0
        func run(_ name: String, _ test: (EngineFixture) async throws -> Void) async throws {
            let fixture = try EngineFixture()
            defer { fixture.clean() }
            try await test(fixture)
            try fixture.preserved()
            passed += 1
            print("PASS \(name)")
        }

        try await run("structural plist and isolated roots") { f in
            let bytes = try f.layout.plist(binary: f.layout.binary("2.0.0"), port: 8139)
            let object = try PropertyListSerialization.propertyList(from: bytes, format: nil) as! [String: Any]
            try expect(object["ProgramArguments"] as? [String] == [f.layout.binary("2.0.0").path], "Escaped path changed")
            let environment = object["EnvironmentVariables"] as! [String: String]
            try expect(environment["VERA_DATA_DIR"] == f.layout.dataDir.path, "Data root escaped")
            let home = f.root.appendingPathComponent("home")
            let normal = EngineLayout(root: home.appendingPathComponent(".vera"), home: home)
            try expect(normal.label == "com.vera.engine", "Default identity changed")
            try expect(f.layout.label != normal.label, "Isolated job shares default identity")
            try expect(f.layout.launchAgent.path.hasPrefix(f.root.path + "/"), "Isolated plist escapes root")
        }
        for mode in [EngineMode.remote, .off] {
            try await run("\(mode.rawValue) removes job across relaunch") { f in
                _ = try f.seed()
                await f.manager().apply(mode: mode)
                try expect(!FileManager.default.fileExists(atPath: f.layout.launchAgent.path), "Login plist retained")
                try expect(f.active == nil, "Job retained")
                await f.manager().reconcileOnLaunch()
                try expect(!f.commands.contains(where: { $0.contains("bootstrap") }), "Relaunch restarted job")
                try expect(ConfigFile.read(at: f.root.appendingPathComponent("config.json"))["engine_mode"] as? String == mode.rawValue, "Mode not saved")
            }
        }
        try await run("healthy upgrade retains exact previous version") { f in
            _ = try f.seed("3.0.0")
            try f.binary("4.0.0")
            let manager = f.manager()
            await manager.installAndStart()
            try expect(manager.running && manager.phase == .healthy, "Upgrade not healthy")
            try expect(f.active == "2.0.0", "New version not active")
            try expect(FileManager.default.fileExists(atPath: f.layout.binary("3.0.0").path), "Previous binary pruned")
            try expect(!FileManager.default.fileExists(atPath: f.layout.versionDir("4.0.0").path), "Stale version retained")
        }
        try await run("failed health restores prior plist and binary") { f in
            let prior = try f.seed()
            f.failedVersions.insert("2.0.0")
            let manager = f.manager()
            await manager.installAndStart()
            let restored = try Data(contentsOf: f.layout.launchAgent)
            try expect(restored == prior, "Prior plist changed")
            try expect(f.active == "1.0.0" && manager.running, "Prior engine not restored")
            try expect(manager.installedVersion == "1.0.0", "Failed version advertised")
            guard case .failed = manager.phase else { throw TestFailure(message: "Failure not surfaced") }
        }
        try await run("bootstrap failure restores previous engine") { f in
            let prior = try f.seed()
            f.bootstrapFailures.insert("2.0.0")
            await f.manager().installAndStart()
            let restored = try Data(contentsOf: f.layout.launchAgent)
            try expect(restored == prior && f.active == "1.0.0", "Bootstrap rollback failed")
        }
        try await run("rollback failure stays explicit and retains recovery files") { f in
            _ = try f.seed()
            f.failedVersions.insert("2.0.0")
            f.bootstrapFailures.insert("1.0.0")
            let manager = f.manager()
            await manager.installAndStart()
            guard case .failed(let message) = manager.phase else { throw TestFailure(message: "Failure hidden") }
            try expect(message.contains("recovery needs attention"), "Rollback failure hidden")
            try expect(FileManager.default.fileExists(atPath: f.layout.binary("1.0.0").path), "Recovery binary removed")
        }
        for failure in ["checksum", "network", "extraction", "missing binary"] {
            try await run("\(failure) preserves working engine before swap") { f in
                let prior = try f.seed()
                f.checksumFails = failure == "checksum"
                f.networkFails = failure == "network"
                f.extractionFails = failure == "extraction"
                f.extractionMissing = failure == "missing binary"
                let manager = f.manager()
                await manager.installAndStart()
                let retained = try Data(contentsOf: f.layout.launchAgent)
                try expect(retained == prior && f.active == "1.0.0", "Prior engine changed before validation")
                try expect(!f.commands.contains(where: { $0.contains("bootout") }), "Old job stopped before verification")
                try expect(!FileManager.default.fileExists(atPath: f.layout.versionDir("2.0.0").path), "Bad version installed")
                guard case .failed = manager.phase else { throw TestFailure(message: "Failure not surfaced") }
            }
        }
        try await run("fresh failed start leaves no login job") { f in
            f.failedVersions.insert("2.0.0")
            await f.manager().installAndStart()
            try expect(!FileManager.default.fileExists(atPath: f.layout.launchAgent.path), "Failed fresh start can relaunch")
            try expect(f.active == nil, "Failed engine still active")
        }
        try await run("stop during download prevents later bootstrap") { f in
            _ = try f.seed()
            let service = EngineLifecycle(layout: f.layout, operations: f.operations())
            do {
                try await service.start(version: "2.0.0", port: 8089, archive: {
                    try service.stop()
                    return f.root.appendingPathComponent("unused.zip")
                })
                throw TestFailure(message: "Stopped operation completed")
            } catch is CancellationError {}
            try expect(!f.commands.contains(where: { $0.contains("bootstrap") }), "Stopped download restarted job")
            try expect(!FileManager.default.fileExists(atPath: f.layout.launchAgent.path), "Stopped job restored plist")
        }
        try await run("stop during health never restores previous job") { f in
            _ = try f.seed()
            try f.binary("2.0.0")
            let service = EngineLifecycle(layout: f.layout, operations: f.operations())
            f.duringHealth = { try service.stop() }
            do {
                try await service.start(version: "2.0.0", port: 8089, archive: { throw TestFailure(message: "Unexpected download") })
                throw TestFailure(message: "Stopped health completed")
            } catch is CancellationError {}
            try expect(f.active == nil, "Stopped health restored job")
            try expect(!FileManager.default.fileExists(atPath: f.layout.launchAgent.path), "Stopped health restored plist")
        }
        try await run("unmanaged engine cannot be replaced") { f in
            f.active = "1.0.0"
            let manager = f.manager()
            await manager.installAndStart()
            try expect(f.commands.allSatisfy { $0.contains("print") }, "Unmanaged job mutated")
            guard case .failed = manager.phase else { throw TestFailure(message: "Conflict hidden") }
        }
        try await run("filesystem failure before swap preserves job") { f in
            let prior = try f.seed()
            try Data("blocking file".utf8).write(to: f.layout.versionDir("2.0.0"))
            await f.manager().installAndStart()
            let retained = try Data(contentsOf: f.layout.launchAgent)
            try expect(retained == prior && f.active == "1.0.0", "Filesystem failure altered prior job")
        }
        try await run("stop failure is visible and disables login restart") { f in
            _ = try f.seed()
            f.stopFails = true
            let manager = f.manager()
            await manager.apply(mode: .off)
            guard case .failed = manager.phase else { throw TestFailure(message: "Stop failure hidden") }
            try expect(!FileManager.default.fileExists(atPath: f.layout.launchAgent.path), "Stop failure retains login plist")
        }
        try await run("remove engine files preserves data") { f in
            _ = try f.seed()
            f.manager().removeEngineFiles()
            try expect(!FileManager.default.fileExists(atPath: f.layout.engineRoot.path), "Engine binaries retained")
            try expect(!FileManager.default.fileExists(atPath: f.layout.launchAgent.path), "Job retained on remove")
        }
        try await run("failed local install retains saved remote mode") { f in
            try ConfigFile.write(["engine_mode": "remote", "vera_api_base": "https://fixture.invalid", "untouched": "value"],
                                 at: f.root.appendingPathComponent("config.json"))
            f.networkFails = true
            let manager = f.manager()
            await manager.apply(mode: .local)
            let config = ConfigFile.read(at: f.root.appendingPathComponent("config.json"))
            try expect(config["engine_mode"] as? String == "remote", "Failed install changed mode")
            try expect(config["untouched"] as? String == "value", "Unrelated config changed")
        }
        try await run("new remote choice survives suspended local install") { f in
            try ConfigFile.write(["engine_mode": "off"], at: f.root.appendingPathComponent("config.json"))
            let manager = f.manager()
            f.duringDownload = { await manager.apply(mode: .remote) }
            await manager.apply(mode: .local)
            try expect(manager.currentMode == .remote, "Older request overwrote latest choice")
            try expect(f.commands.allSatisfy { !$0.contains("bootstrap") }, "Canceled local choice started a job")
        }
        try await run("successful local install commits selected mode") { f in
            try ConfigFile.write(["engine_mode": "off"], at: f.root.appendingPathComponent("config.json"))
            let manager = f.manager()
            await manager.apply(mode: .local)
            try expect(manager.currentMode == .local && manager.running, "Healthy install did not commit mode")
        }
        try await run("symlinked storage cannot mutate another root") { f in
            let outside = f.root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("retained".utf8).write(to: outside.appendingPathComponent("marker"))
            try FileManager.default.createSymbolicLink(at: f.layout.engineRoot, withDestinationURL: outside)
            let manager = f.manager()
            await manager.installAndStart()
            guard case .failed = manager.phase else { throw TestFailure(message: "Linked storage accepted") }
            try expect(f.commands.allSatisfy { $0.contains("print") }, "Linked storage triggered mutation")
            let marker = try Data(contentsOf: outside.appendingPathComponent("marker"))
            try expect(marker == Data("retained".utf8), "External root changed")
        }
        try await run("stop failure restores previous launch settings") { f in
            let prior = try f.seed()
            f.stopFails = true
            await f.manager().installAndStart()
            let bytes = try Data(contentsOf: f.layout.launchAgent)
            try expect(bytes == prior, "Prior plist lost when bootout failed")
            try expect(f.active == "1.0.0", "Prior engine replaced despite failed bootout")
        }
        try await run("SIGKILL during activation recovers prior engine on reopen") { f in
            let prior = try f.seed()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--interrupt-fixture", f.root.path]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            try expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "Fixture was not killed")
            try expect(FileManager.default.fileExists(atPath: f.layout.engineRoot.appendingPathComponent("activation.json").path), "Recovery record missing")
            f.active = "2.0.0"
            let reopened = EngineLifecycle(layout: f.layout, operations: f.operations())
            try await reopened.recoverPending()
            let restored = try Data(contentsOf: f.layout.launchAgent)
            try expect(restored == prior && reopened.running && f.active == "1.0.0", "Killed activation did not recover")
            try expect(!FileManager.default.fileExists(atPath: f.layout.engineRoot.appendingPathComponent("activation.json").path), "Recovered transaction retained")
        }
        try await run("data deletion refuses an independently running job") { f in
            _ = try f.seed()
            let manager = f.manager()
            manager.deleteData()
            guard case .failed = manager.phase else { throw TestFailure(message: "Active engine data deletion permitted") }
        }
        for mode in [EngineMode.off, .remote] {
            try await run("reconcile cannot restart after newer \(mode.rawValue) choice") { f in
                _ = try f.seed()
                try ConfigFile.write(["engine_mode": "local"], at: f.root.appendingPathComponent("config.json"))
                let manager = f.manager()
                f.duringProbe = { await manager.apply(mode: mode) }
                await manager.reconcileOnLaunch()
                try expect(manager.currentMode == mode && !manager.running && f.active == nil, "Reconcile overrode newer mode")
                try expect(f.commands.allSatisfy { !$0.contains("bootstrap") }, "Stale reconcile restarted engine")
            }
        }
        try await run("repeated local selection preserves first successful mode commit") { f in
            try ConfigFile.write(["engine_mode": "off"], at: f.root.appendingPathComponent("config.json"))
            let manager = f.manager()
            f.duringDownload = { await manager.apply(mode: .local) }
            await manager.apply(mode: .local)
            try expect(manager.currentMode == .local && manager.running, "Repeated local choice invalidated successful request")
            try expect(f.commands.filter { $0.contains("bootstrap") }.count == 1, "Repeated local choice duplicated start")
        }
        print("Engine lifecycle: \(passed) tests passed. All commands and network requests were injected.")
    }
}
