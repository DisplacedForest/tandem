import Foundation
import Security

final class OwnSettingsWire: URLProtocol, @unchecked Sendable {
    static let host = "fixture.example"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fixture".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
enum OwnSettingsSelftest {
    static let probeSetting = "VERA_TRAP_PROBE"
    static let probes = ["settings", "keychain", "keychain-read", "preferences", "database", "database-wal"]

    static func run() async throws {
        guard let runRoot = AppLocations.headlessRoot else { throw NativeTaskFixture.Failure.assertion("This check runs inside a headless run") }
        let scratch = runRoot.appendingPathComponent("own-settings-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try checkGuardPredicate()
        try checkPlainStoreHasNoConnection()
        try await checkRequestsStopBeforeConnecting()
        try checkSettingsFile(runRoot, scratch: scratch.appendingPathComponent("settings", isDirectory: true))
        try checkDatabase(runRoot, scratch: scratch.appendingPathComponent("database", isDirectory: true))
        try checkKeysStayInMemory()
        try checkPreferences()
        try checkRetiredKeys()
        try checkTraps()
    }

    static func checkGuardPredicate() throws {
        let require = NativeTaskFixture.require
        let selftest = LaunchPlan.Mode.run("--selftest")
        try require(OutboundGuard.policy(for: .app, environment: [:]) == .open, "A plain start reaches any address, as before")
        for live in LaunchPlan.realDataModes {
            try require(OutboundGuard.policy(for: .run(live), environment: [:]) == .open, "A live mode reaches any address, as before: \(live)")
        }
        try require(OutboundGuard.policy(for: .run("--shot"), environment: [:]) == .loopbackOnly([]), "A shot only reaches this Mac")
        try require(OutboundGuard.policy(for: selftest, environment: [:]) == .loopbackOnly([]), "A selftest only reaches this Mac")
        let local = OutboundGuard.Policy.loopbackOnly([])
        func permits(_ text: String, _ policy: OutboundGuard.Policy = local) -> Bool { OutboundGuard.permits(URL(string: text), policy: policy) }
        for loopback in ["http://127.0.0.1:8080/v1", "http://127.4.5.6/", "http://[::1]:9000/", "http://localhost/", "http://LOCALHOST./",
                         "ws://127.0.0.1:8188/ws", "http://[::ffff:127.0.0.1]/", "file:///tmp/x.json", "data:text/plain,ok"] {
            try require(permits(loopback), "A loopback address stays reachable in a test run: \(loopback)")
        }
        for lan in ["http://[fd12:3456::8]:6590/", "http://100.64.0.9/", "http://[fe80::1]/", "http://printer.local:8089/", "http://169.254.1.1/", "http://nas.internal/"] {
            try require(!permits(lan), "A private network address is refused in a test run: \(lan)")
        }
        for outside in ["https://openrouter.ai/api/v1", "https://8.8.8.8/", "https://127.evil.example/", "http://localhost.example/",
                        "http://127.0.0.1.example/", "https://[2001:db8::1]/", "wss://image.example/ws", "mailto:someone", "x-unknown:thing"] {
            try require(!permits(outside), "A public or unknown address is refused in a test run: \(outside)")
        }
        let optIn = OutboundGuard.policy(for: selftest, environment: ["VERA_MEMORY_LIVE_BASE": "http://Memory.Example:8080/v1",
                                                                     "VERA_IMAGE_LIVE_BASE": "http://198.51.100.20:8083"])
        try require(optIn == .loopbackOnly(["memory.example", "198.51.100.20"]), "An explicit live address allows exactly its host")
        try require(permits("http://memory.example:9999/v1/embeddings", optIn) && permits("http://198.51.100.20:8083/prompt", optIn),
                    "The named host is reachable for that run")
        try require(!permits("http://sub.memory.example/v1", optIn) && !permits("http://memory.example.net/", optIn)
                    && !permits("http://198.51.100.21:8083/", optIn) && !permits("https://openrouter.ai/api/v1", optIn),
                    "Nothing wider than the named host is reachable")
        try require(OutboundGuard.policy(for: .run("--shot"), environment: ["VERA_MEMORY_LIVE_BASE": "not a url"]) == .loopbackOnly([]),
                    "An unusable live address allows nothing")
        try require(permits("https://openrouter.ai/api/v1", .open) && permits("http://[fd12:3456::8]/", .open), "An open run reaches every address")
        try require(OutboundGuard.policy != .open, "This test run only reaches this Mac")
        try require(!LaunchPlan.isShotRun, "Only a shot uses the built-in site icon, never a selftest")
    }

    static func checkPlainStoreHasNoConnection() throws {
        let require = NativeTaskFixture.require
        let store = ChatStore()
        try require(store.currentNativeConfig == nil && !store.hasChatTransport, "The plain store in a test run has no live model connection")
        try require(store.companionDefaults is MemoryPreferences, "The plain store in a test run keeps its preferences in memory")
    }

    static func refusal(_ operation: () async throws -> Void) async -> (refused: Bool, seconds: Double) {
        let started = Date()
        do {
            try await operation()
            return (false, Date().timeIntervalSince(started))
        } catch let error as NSError where error.domain == OutboundGuard.errorDomain {
            return (true, Date().timeIntervalSince(started))
        } catch is OutboundGuard.Refusal {
            return (true, Date().timeIntervalSince(started))
        } catch {
            return (false, Date().timeIntervalSince(started))
        }
    }

    static func checkRequestsStopBeforeConnecting() async throws {
        let require = NativeTaskFixture.require
        let unroutable = URL(string: "http://198.51.100.7:9/probe")!
        var request = URLRequest(url: unroutable)
        request.timeoutInterval = 20
        let before = OutboundGuard.refusals
        let shared = await refusal { _ = try await URLSession.shared.data(for: request) }
        try require(shared.refused && shared.seconds < 5, "A shared-session request to an outside address fails at once, before any connection")
        try require(OutboundGuard.refusals > before, "The guard handled that request itself")
        let session = OutboundGuard.session()
        defer { session.invalidateAndCancel() }
        let made = await refusal { _ = try await session.data(for: request) }
        try require(made.refused && made.seconds < 5, "A request from a made session to an outside address fails at once")
        let download = await refusal { _ = try await URLSession.shared.download(from: unroutable) }
        try require(download.refused, "A download from an outside address fails at once")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OwnSettingsWire.self]
        let fixtureSession = OutboundGuard.session(configuration: configuration)
        defer { fixtureSession.invalidateAndCancel() }
        let (data, _) = try await fixtureSession.data(from: URL(string: "https://\(OwnSettingsWire.host)/answer")!)
        try require(data == Data("fixture".utf8), "A fixture transport still answers its own requests")
        let beside = await refusal { _ = try await fixtureSession.data(from: URL(string: "https://openrouter.ai/api/v1/models")!) }
        try require(beside.refused, "A request the fixture doesn't answer is refused, not sent")
        let client = NativeChatClient(config: NativeChatConfig(baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: "synthetic-never-sent",
                                                               model: "fixture", chatTemplateKwargs: nil))
        let models = await refusal { _ = try await client.discoverModels() }
        try require(models.refused, "A model client in a test run can't reach a hosted model")
        let page = await refusal { _ = try await NativePageTransport.pinnedAddress("example.com") }
        try require(page.refused, "A page read in a test run stops before looking the name up")
        let socket = await refusal { try OutboundGuard.check(URL(string: "ws://[fd12:3456::9]:8188/ws")) }
        try require(socket.refused, "A socket to another machine is refused in a test run")
        try require((try? OutboundGuard.check(URL(string: "ws://127.0.0.1:8188/ws"))) != nil, "A socket on this Mac is allowed")
    }

    static func checkSettingsFile(_ runRoot: URL, scratch: URL) throws {
        let require = NativeTaskFixture.require
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let current = AppLocations.current
        if case .setting(let folder) = current.situation {
            try require(AppLocations.isInside(current.configFile, folder), "With the setting the settings file stays in that folder")
        } else {
            try require(AppLocations.isInside(current.configFile, runRoot), "A test run reads its settings from its own scratch folder")
        }
        try require(ConfigFile.defaultURL == current.configFile, "The settings file goes through the one resolver")
        try require(AppLocations.isInside(NativeCapabilityTools.defaultDirectory, current.configFile.deletingLastPathComponent()),
                    "The tools folder follows the settings file")
        try require(current.configFile != AppLocations.realSettingsFile, "A test run never resolves the real settings file")
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let setting = scratch.appendingPathComponent("elsewhere", isDirectory: true)
        let support = scratch.appendingPathComponent("support", isDirectory: true)
        let run = scratch.appendingPathComponent("run", isDirectory: true)
        let headless = AppLocations.resolve(environment: [:], home: home, applicationSupport: support, headlessRoot: run)
        try require(headless.configFile == run.appendingPathComponent("config.json"), "Headless with no setting: the settings file is in the scratch root")
        let namesStandard = AppLocations.resolve(environment: [AppLocations.settingName: home.appendingPathComponent(".vera").path],
                                                 home: home, applicationSupport: support, headlessRoot: run)
        try require(namesStandard.configFile == run.appendingPathComponent("config.json"),
                    "A test run whose setting names the standard folder still reads its own settings")
        let separate = AppLocations.resolve(environment: [AppLocations.settingName: setting.path], home: home, applicationSupport: support, headlessRoot: run)
        try require(separate.configFile.path == setting.appendingPathComponent("config.json").path, "A separate setting keeps its own settings file")
        let plain = AppLocations.resolve(environment: [:], home: home, applicationSupport: support, headlessRoot: nil)
        try require(plain.configFile == AppLocations.realSettingsFile(home: home), "A plain start reads the settings file where it always did")

        let standIn = AppLocations.realSettingsFile(home: home)
        try FileManager.default.createDirectory(at: standIn.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: standIn)
        let link = scratch.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: standIn)
        let hard = scratch.appendingPathComponent("hard.json")
        try FileManager.default.linkItem(at: standIn, to: hard)
        let dotted = home.appendingPathComponent(".vera/../.vera/config.json")
        let upper = home.appendingPathComponent(".VERA/CONFIG.JSON")
        try require(AppLocations.isRealSettingsFile(standIn, realFile: standIn), "The trap knows the settings file itself")
        try require(AppLocations.isRealSettingsFile(link, realFile: standIn), "The trap follows a link to the settings file")
        try require(AppLocations.isRealSettingsFile(hard, realFile: standIn), "The trap knows the same file under another name")
        try require(AppLocations.isRealSettingsFile(dotted, realFile: standIn), "The trap reads through dot segments")
        try require(AppLocations.isRealSettingsFile(upper, realFile: standIn, foldCase: true), "On a case-insensitive volume a differently cased name is the same file")
        try require(AppLocations.isRealSettingsFile(upper, realFile: standIn) == AppLocations.isCaseInsensitiveVolume(standIn),
                    "A differently cased name matches only on a case-insensitive volume")
        try require(!AppLocations.isRealSettingsFile(run.appendingPathComponent("config.json"), realFile: standIn), "A scratch settings file is not the real one")
        if let real = AppLocations.realSettingsFile {
            try require(AppLocations.isRealSettingsFile(real), "The trap knows the real settings file")
            try require(!AppLocations.isRealSettingsFile(current.configFile), "This run's settings file is not the real one")
        }
    }

    static func checkDatabase(_ runRoot: URL, scratch: URL) throws {
        let require = NativeTaskFixture.require
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let current = AppLocations.current
        if case .setting(let folder) = current.situation {
            try require(AppLocations.isInside(current.database, folder), "With the setting the database stays in that folder")
        } else {
            try require(AppLocations.isInside(current.database, runRoot), "A test run's default database is in its own scratch folder")
        }
        try require(LocalChatRepository.defaultURL == current.database, "The database goes through the one resolver")
        if let real = AppLocations.realDatabase {
            try require(!AppLocations.isRealDatabaseFile(current.database), "This run's default database is not the real one")
            try require(AppLocations.isRealDatabaseFile(real) && AppLocations.isRealDatabaseFile(URL(fileURLWithPath: real.path + "-wal"))
                        && AppLocations.isRealDatabaseFile(URL(fileURLWithPath: real.path + "-shm")), "The trap knows the real database and its siblings")
        }
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let support = scratch.appendingPathComponent("support", isDirectory: true)
        let run = scratch.appendingPathComponent("run", isDirectory: true)
        let setting = scratch.appendingPathComponent("elsewhere", isDirectory: true)
        let headless = AppLocations.resolve(environment: [:], home: home, applicationSupport: support, headlessRoot: run)
        try require(headless.database == run.appendingPathComponent(AppLocations.databaseName) && headless.configDirectory == run,
                    "Headless with no setting: the database and everything kept beside the settings file are in the scratch root")
        let engine = EngineLayout(root: headless.configFile.deletingLastPathComponent(), home: home)
        try require(AppLocations.isInside(engine.engineRoot, run) && AppLocations.isInside(engine.dataDir, run) && AppLocations.isInside(engine.logFile, run)
                    && AppLocations.isInside(engine.launchAgent, run) && engine.label != EngineManager.label,
                    "A test run's local server folders, log and launch file are in its scratch root under their own label")
        let namesStandard = AppLocations.resolve(environment: [AppLocations.settingName: home.appendingPathComponent(".vera").path],
                                                 home: home, applicationSupport: support, headlessRoot: run)
        try require(namesStandard.database == run.appendingPathComponent(AppLocations.databaseName),
                    "A test run whose setting names the standard folder still gets its own database")
        let separate = AppLocations.resolve(environment: [AppLocations.settingName: setting.path], home: home, applicationSupport: support, headlessRoot: run)
        try require(separate.database.path == setting.appendingPathComponent(AppLocations.databaseName).path, "A separate setting keeps its own database")
        let plain = AppLocations.resolve(environment: [:], home: home, applicationSupport: support, headlessRoot: nil)
        try require(plain.database == AppLocations.realDatabase(home: home), "A plain start opens the database where it always did")

        let standIn = AppLocations.realDatabase(home: home)
        try FileManager.default.createDirectory(at: standIn.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stand-in".utf8).write(to: standIn)
        let link = scratch.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: standIn)
        let hard = scratch.appendingPathComponent("hard.sqlite")
        try FileManager.default.linkItem(at: standIn, to: hard)
        let linkedFolder = scratch.appendingPathComponent("linked-folder", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: standIn.deletingLastPathComponent())
        try require(AppLocations.isRealDatabaseFile(standIn, realFile: standIn), "The trap knows the database itself")
        try require(AppLocations.isRealDatabaseFile(link, realFile: standIn), "The trap follows a link to the database")
        try require(AppLocations.isRealDatabaseFile(hard, realFile: standIn), "The trap knows the same database under another name")
        try require(AppLocations.isRealDatabaseFile(home.appendingPathComponent(".vera/../.vera/vera.sqlite"), realFile: standIn), "The trap reads through dot segments")
        for suffix in ["-wal", "-shm", "-journal"] {
            try require(AppLocations.isRealDatabaseFile(URL(fileURLWithPath: standIn.path + suffix), realFile: standIn),
                        "The trap knows the database's \(suffix) sibling by folder and name")
            try require(AppLocations.isRealDatabaseFile(linkedFolder.appendingPathComponent(AppLocations.databaseName + suffix), realFile: standIn),
                        "The trap knows the \(suffix) sibling through a linked folder")
        }
        try require(AppLocations.isRealDatabaseFile(home.appendingPathComponent(".VERA/VERA.SQLITE-WAL"), realFile: standIn, foldCase: true)
                    && !AppLocations.isRealDatabaseFile(home.appendingPathComponent(".vera/VERA.SQLITE-WAL"), realFile: standIn, foldCase: false),
                    "Letter case follows the volume's rules")
        try require(!AppLocations.isRealDatabaseFile(run.appendingPathComponent(AppLocations.databaseName), realFile: standIn)
                    && !AppLocations.isRealDatabaseFile(URL(fileURLWithPath: standIn.path + "-other"), realFile: standIn)
                    && !AppLocations.isRealDatabaseFile(standIn.deletingLastPathComponent().appendingPathComponent("gate.sqlite"), realFile: standIn),
                    "A scratch database or an unrelated name is not the real database")
    }

    static func checkKeysStayInMemory() throws {
        let require = NativeTaskFixture.require
        let store = AppLocations.credentialStore()
        try require(store is NativeCredentialFixtureStore && (store as AnyObject) === AppLocations.runCredentials, "A test run keeps saved keys in memory")
        try require(AppLocations.credentialStore(allowsInteraction: false) is NativeCredentialFixtureStore, "Every key store a test run gets is in memory")
        let config = ConfigStore(readConfiguration: { [:] }, writeConfiguration: { _ in })
        let id = "own-settings-\(UUID().uuidString.lowercased())"
        try AppLocations.runCredentials.set("synthetic-memory-key", for: id)
        try require(AppLocations.runCredentials.values[id] == "synthetic-memory-key", "A key saved in a test run stays in memory")
        try AppLocations.runCredentials.set(nil, for: id)
        try require(config.credentialError == nil, "The default settings store opens with the memory key store")
        let configuration = NativeTaskConfiguration(settings: { .fresh })
        try require(configuration.credential("missing-\(id)") == nil, "Saved-profile setup reads keys from memory in a test run")
    }

    static func checkPreferences() throws {
        let require = NativeTaskFixture.require
        try require(AppLocations.preferences is MemoryPreferences && AppLocations.preferences === AppLocations.runPreferences,
                    "A test run's preferences live in memory")
        let first = AppLocations.scratchPreferences()
        let second = AppLocations.scratchPreferences()
        try require(first !== second && first is MemoryPreferences, "Fixtures that need separate preferences get separate ones")
        first.set("one", forKey: "own-settings")
        first.set(true, forKey: "own-settings-flag")
        try require(first.string(forKey: "own-settings") == "one" && first.bool(forKey: "own-settings-flag")
                    && second.string(forKey: "own-settings") == nil && !second.bool(forKey: "own-settings-flag"),
                    "Separate preferences don't share values")
        first.removeObject(forKey: "own-settings")
        try require(first.string(forKey: "own-settings") == nil, "A removed preference is gone")
        first.set(Data([1, 2]), forKey: "own-settings-data")
        try require(first.data(forKey: "own-settings-data") == Data([1, 2]), "Data round trips in memory")
        first.removePersistentDomain(forName: "own-settings")
        try require(first.dictionaryRepresentation()["own-settings-data"] == nil, "Clearing a memory store empties it")
    }

    static func checkRetiredKeys() throws {
        let require = NativeTaskFixture.require
        try require(ConfigStore.cleansRetiredKeys(.app, headless: false), "The app's own plain start tidies retired keys")
        try require(!ConfigStore.cleansRetiredKeys(.run("--selftest"), headless: true) && !ConfigStore.cleansRetiredKeys(.run("--shot"), headless: true)
                    && !ConfigStore.cleansRetiredKeys(.app, headless: true), "A test run never rewrites settings to tidy retired keys")
        for live in LaunchPlan.realDataModes {
            try require(!ConfigStore.cleansRetiredKeys(.run(live), headless: false), "A live mode never rewrites settings to tidy retired keys: \(live)")
        }
        try require(!ConfigStore.cleansRetiredKeysInThisRun, "This test run can't tidy retired keys")
        var written: [String: Any]?
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(),
                                 readConfiguration: { ["base": "http://old.example", "api_key": "k", "owner_name": "Test"] },
                                 writeConfiguration: { written = $0 })
        try require(written == nil && config["base"].isEmpty, "In a test run retired keys drop from memory and nothing is written")
    }

    static func probe(_ kind: String) -> Never {
        switch kind {
        case "settings":
            if let real = AppLocations.realSettingsFile { _ = ConfigFile.read(at: real) }
        case "keychain":
            _ = KeychainNativeCredentialStore()
        case "keychain-read":
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "own-settings-probe-\(UUID().uuidString)"]
            _ = NativeKeychainOperations().read(query as CFDictionary, nil)
        case "preferences":
            _ = AppLocations.standardPreferences
        case "database", "database-wal":
            guard let real = AppLocations.realDatabase else { break }
            let target = kind == "database" ? real : URL(fileURLWithPath: real.path + "-wal")
            guard AppLocations.isHeadless, AppLocations.isRealDatabaseFile(target) else { break }
            _ = try? LocalChatRepository(url: target, artifactDirectory: AppLocations.current.attachments, projectsDirectory: AppLocations.current.projects)
        default:
            break
        }
        print("PROBE NOT STOPPED")
        exit(0)
    }

    static func checkTraps() throws {
        let require = NativeTaskFixture.require
        guard let binary = Bundle.main.executableURL else { throw NativeTaskFixture.Failure.assertion("The selftest binary is known") }
        for kind in probes {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--selftest"]
            var environment = ProcessInfo.processInfo.environment
            environment[probeSetting] = kind
            process.environment = environment
            let errors = Pipe()
            let output = Pipe()
            process.standardError = errors
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            try require(process.terminationStatus != 0 && !printed.contains("PROBE NOT STOPPED") && message.contains("This test run keeps its own"),
                        "A test run stops before it reaches the real \(kind)")
        }
    }
}
