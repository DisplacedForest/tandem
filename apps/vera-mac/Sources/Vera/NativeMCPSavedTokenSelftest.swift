import Foundation

@MainActor
enum NativeMCPSavedTokenSelftest {
    final class Service: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: Set<String> = []
        private var refusing: Set<String> = []
        private var down = false
        private var opened = 0
        private var offered: [NativeMCPDiscoveredTool]
        @MainActor init() { offered = [NativeMCPChangesSelftest.tool("lookup")] }
        var count: Int { lock.withLock { opened } }
        func refuse(_ token: String) { lock.withLock { _ = refusing.insert(token) } }
        func setDown(_ value: Bool) { lock.withLock { down = value } }
        func offer(_ tools: [NativeMCPDiscoveredTool]) { lock.withLock { offered = tools } }
        func make(_ server: NativeMCPServerConfiguration, _ authorization: NativeMCPAuthorization?) throws -> any NativeMCPConnection {
            var header = ""
            try authorization?.performAuthorizedRequest(URLRequest(url: server.endpoint)) { header = $0.value(forHTTPHeaderField: "Authorization") ?? "" }
            return try lock.withLock {
                opened += 1
                if down { throw NativeMCPTransportError.network }
                if refusing.contains(where: { header == "Bearer " + $0 }) { throw NativeMCPTransportError.authenticationRequired }
                return NativeMCPChangesConnection(offered)
            }
        }
    }

    static let token = "synthetic-saved-token-value"
    static let other = "synthetic-second-token-value"
    static let home = [192, 168].map(String.init).joined(separator: ".")
    static let ten = String(10)
    static let middle = String(172)
    static let id = "9b3de1c4-7a52-4f0e-8d16-2c5f7a90e3b1"
    static let address = "http://homeassistant.local:8123/api/mcp"

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NativeToolError.failed(message) }
    }

    static func row(_ address: String = address) -> [String: Any] {
        ["id": id, "name": "House", "url": address, "read_tools": ["lookup"], "scopes": IntegrationsText.scopeKeys, "timeout_seconds": 5.0, "authentication": "bearer"]
    }

    static func manager(_ rows: [[String: Any]], _ service: Service, _ keys: NativeCredentialFixtureStore) throws -> NativeMCPManager {
        let (servers, failure) = NativeMCPServerConfiguration.load(["native_mcp_servers": rows])
        try check(failure == nil, "The fixture service loads: \(failure ?? "")")
        return NativeMCPManager(servers: servers, enabled: Set(servers.map { $0.toolID("lookup") }),
                                authenticatedFactory: { try service.make($0, $1) }, tokens: keys,
                                reconnectDelays: [.milliseconds(5), .milliseconds(20)])
    }

    static func wait(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NativeToolError.failed(message)
    }

    static func connected(_ manager: NativeMCPManager) -> Bool { manager.servers.first?.connected == true }

    static func run() async throws {
        try addresses()
        try await savesAndReconnects()
        try await deletes()
        try await failures()
        try await races()
        try await discovery()
        try numbers()
        try await address()
        try await hints()
        try copy()
        print("NATIVE MCP SAVED TOKEN SELFTEST OK")
    }

    static func addresses() throws {
        let local = ["http://\(home).1.4:8123/api/mcp", "http://\(ten).0.0.8/mcp", "http://\(middle).16.0.1/mcp", "http://\(middle).31.255.254/mcp", "http://169.254.7.1/mcp",
                     "http://127.0.0.1:9/mcp", "http://localhost/mcp", "http://[::1]/mcp", "http://[fe80::1]/mcp", "http://homeassistant.local:8123/api/mcp", "http://HOME.LOCAL./mcp"]
        for text in local {
            let url = URL(string: text)!
            try NativeMCPAddress.validate(url, personSupplied: true)
            _ = try NativeMCPSDKConnection(endpoint: url)
            let (servers, failure) = NativeMCPServerConfiguration.load(["native_mcp_servers": [row(text)]])
            try check(failure == nil && servers.count == 1, "A local address is refused: \(text)")
            do {
                try NativeMCPAddress.validate(url, personSupplied: false)
                throw NativeMCPTransportError.network
            } catch NativeToolError.failed(let reason) {
                try check(reason == NativeMCPAddress.listNeedsHTTPS, "A listed http address is refused plainly")
            }
        }
        let open = ["http://example.com/mcp", "http://8.8.8.8/mcp", "http://172.32.0.1/mcp", "http://172.15.0.1/mcp", "http://192.169.0.1/mcp", "http://11.0.0.1/mcp", "http://169.253.0.1/mcp",
                    "http://local/mcp", "http://notlocal/mcp", "http://evil-local.com/mcp", "http://homeassistant.local.example.com/mcp", "http://\(ten).0.0.1.example.com/mcp",
                    "http://010.0.0.1/mcp", "http://0127.0.0.1/mcp", "http://192.0168.1.1/mcp", "http://\(ten).1/mcp", "http://167772161/mcp", "http://0x0a000001/mcp", "http://[2001:db8::1]/mcp", "http://[fec0::1]/mcp", "http://[::ffff:8.8.8.8]/mcp"]
        for text in open {
            let url = URL(string: text)!
            let (servers, failure) = NativeMCPServerConfiguration.load(["native_mcp_servers": [row(text)]])
            try check(servers.isEmpty && failure == NativeMCPAddress.publicNeedsHTTPS, "A public http address is accepted: \(text) \(failure ?? "")")
            do { _ = try NativeMCPSDKConnection(endpoint: url); throw NativeToolError.failed("The transport accepts \(text)") }
            catch NativeMCPTransportError.invalidEndpoint {}
        }
        try NativeMCPAddress.validate(URL(string: "https://example.com/mcp")!, personSupplied: false)
        for text in ["ftp://\(home).1.4/mcp", "http://user:word@\(home).1.4/mcp", "https://example.com/mcp?token=x", "https://example.com/mcp#x"] {
            do { try NativeMCPAddress.validate(URL(string: text)!, personSupplied: true) } catch { continue }
            throw NativeToolError.failed("An unusable address is accepted: \(text)")
        }
    }

    static func savesAndReconnects() async throws {
        let service = Service(), keys = NativeCredentialFixtureStore()
        var disk: [String: Any] = ["native_mcp_servers": [row()]]
        let first = try manager([row()], service, keys)
        let config = ConfigStore(credentialStore: keys, readConfiguration: { disk }, nativeMCP: first, writeConfiguration: { disk = $0 })
        try check(!connected(first) && service.count == 0, "A service with no saved token connects by itself")
        await first.connect(id, token: token)
        try check(connected(first) && first.hasSavedToken(id) && keys.values.count == 1, "A token that connects is saved")
        try config.save()
        let written = String(describing: disk)
        try check(!written.contains(token), "The token is written to the configuration file")
        let spoken = String(reflecting: first.servers) + String(describing: first.servers) + first.servers.map(\.status).joined()
            + String(describing: first.authority.definitions(scope: "focused").map(\.description))
        try check(!spoken.contains(token), "The token shows up in a description")

        let second = try manager([row()], service, keys)
        try await wait("A reopened service reconnects without asking") { connected(second) }
        try check(second.servers.first?.status == "Connected" && keys.startupReads.count >= 2 && keys.reads.count == keys.startupReads.count,
                  "The saved token is read without a prompt")
        let offered = second.authority.definitions(scope: IntegrationsText.scopeKeys[2])
        try check(offered.count == 1, "The reconnected service is offered to scheduled work")
        _ = try await offered[0].execute([:])

        await second.authority.disconnect(id, status: "The connection dropped")
        try await wait("A dropped service reconnects") { connected(second) }
        service.setDown(true)
        await second.authority.disconnect(id, status: "The connection dropped")
        let before = service.count
        try await wait("An unreachable service is tried again") { service.count >= before + 3 }
        try check(second.hasSavedToken(id) && IntegrationsText.state(second.servers[0], signingIn: false, reconnecting: second.reconnects(second.servers[0])) == "Reconnecting",
                  "An unreachable service keeps its token and says it is reconnecting")
        service.setDown(false)
        try await wait("The service comes back by itself") { connected(second) }
        await second.disconnect(id)
        await first.disconnect(id)
    }

    static func deletes() async throws {
        let service = Service(), keys = NativeCredentialFixtureStore()
        func opened(_ disk: NativeMCPInstallSelftest.Disk) async throws -> (NativeMCPManager, ConfigStore) {
            disk.contents = ["native_mcp_servers": [row()]]
            let manager = try self.manager([row()], service, keys)
            let config = ConfigStore(credentialStore: keys, readConfiguration: { disk.contents }, nativeMCP: manager, writeConfiguration: { disk.contents = $0 })
            await manager.connect(id, token: token)
            try check(connected(manager) && keys.values.count == 1, "The fixture service is connected and saved")
            return (manager, config)
        }
        let disk = NativeMCPInstallSelftest.Disk()
        var (manager, config) = try await opened(disk)
        await manager.disconnect(id)
        try check(keys.values.isEmpty && !manager.hasSavedToken(id) && !connected(manager), "Disconnect deletes the token")
        let count = service.count
        await manager.connect(id)
        try check(service.count == count && !connected(manager) && manager.servers[0].status == NativeMCPAuthority.tokenNeeded, "Reconnecting asks for the token again")

        (manager, config) = try await opened(disk)
        try config.removeNativeMCPServer(id: id)
        try check(keys.values.isEmpty && manager.servers.isEmpty, "Remove deletes the token")
        await config.settleNativeMCP()

        (manager, config) = try await opened(disk)
        try config.updateNativeMCPServer(row("http://\(home).1.4:8123/api/mcp"))
        try check(keys.values.isEmpty && !manager.hasSavedToken(id), "An address change deletes the token")
        await config.settleNativeMCP()
        try check(!connected(manager), "A moved service waits for a token")

        (manager, config) = try await opened(disk)
        var plain = row()
        plain.removeValue(forKey: "authentication")
        try config.updateNativeMCPServer(plain)
        try check(keys.values.isEmpty, "Turning off the token deletes it")
        await config.settleNativeMCP()

        (manager, config) = try await opened(disk)
        var renamed = row()
        renamed["name"] = "Home"
        renamed["timeout_seconds"] = 6.0
        try config.updateNativeMCPServer(renamed)
        try check(keys.values.count == 1, "Other edits keep the token")
        try await wait("The service reconnects after another edit") { connected(manager) }

        keys.failWrites = true
        do { try config.removeNativeMCPServer(id: id); throw NativeMCPTransportError.network }
        catch is NativeToolError {}
        try check(config.nativeMCPServerRows.count == 1 && manager.hasSavedToken(id), "Remove says so when the token can't be removed")
        await manager.disconnect(id)
        try check(!connected(manager) && manager.hasSavedToken(id) && manager.servers[0].status == NativeMCPManager.tokenUnremoved, "Disconnect says so when the token can't be removed")
        try await Task.sleep(for: .milliseconds(60))
        try check(!connected(manager), "A disconnected service stays disconnected")
        keys.failWrites = false
        await manager.disconnect(id)
        try check(keys.values.isEmpty, "Disconnecting again removes the token")

        (manager, config) = try await opened(disk)
        keys.failWrites = true
        let stuck = try self.manager([row("http://\(home).1.4:8123/api/mcp")], service, keys)
        try check(stuck.servers[0].status == NativeMCPManager.tokenUnremoved && stuck.hasSavedToken(id) && !stuck.reconnects(stuck.servers[0]), "A token that couldn't be removed after a hand edit says so")
        keys.denied = [NativeMCPTokenKeeper.account(id)]
        let late = try self.manager([row("http://\(home).1.4:8123/api/mcp")], service, keys)
        keys.denied = []
        try await wait("A token that couldn't be removed after a late read says so") { late.servers[0].status == NativeMCPManager.tokenUnremoved }
        keys.failWrites = false
        let moved = try self.manager([row("http://\(home).1.4:8123/api/mcp")], service, keys)
        try check(keys.values.isEmpty && !moved.hasSavedToken(id), "A token never follows a hand-edited address")
        await manager.disconnect(id)

        (manager, config) = try await opened(disk)
        keys.denied = [NativeMCPTokenKeeper.account(id)]
        do { try config.removeNativeMCPServer(id: id); throw NativeMCPTransportError.network }
        catch is NativeToolError {}
        try check(keys.values.count == 1 && config.nativeMCPServerRows.count == 1, "A token that can't be read back is never deleted by a removal")
        keys.denied = []
        let refusing = ConfigStore(credentialStore: keys, readConfiguration: { disk.contents }, nativeMCP: manager, writeConfiguration: { _ in throw NativeMCPTransportError.network })
        do { try refusing.removeNativeMCPServer(id: id); throw NativeMCPTransportError.network }
        catch is NativeToolError {}
        try check(keys.values.count == 1 && manager.hasSavedToken(id) && connected(manager), "A removal that can't be written keeps the token")
        await manager.disconnect(id)
    }

    static func failures() async throws {
        let service = Service(), keys = NativeCredentialFixtureStore()
        let manager = try self.manager([row()], service, keys)
        service.refuse(other)
        await manager.connect(id, token: other)
        try check(!connected(manager) && keys.values.isEmpty && manager.servers[0].refused, "A refused token is not saved")
        service.setDown(true)
        await manager.connect(id, token: token)
        try check(keys.values.isEmpty, "A token that never connected is not saved")
        service.setDown(false)
        keys.failWrites = true
        await manager.connect(id, token: token)
        try check(!connected(manager) && manager.servers[0].status == NativeMCPManager.tokenUnsaved, "A token that can't be saved says so")
        keys.failWrites = false
        await manager.connect(id, token: token)
        try check(connected(manager), "The service connects once the token saves")
        let kept = keys.values
        let failed = await manager.replaceToken(id, with: other)
        try check(failed == NativeMCPManager.tokenUnused && keys.values == kept, "A replacement that fails keeps the saved token")
        try await wait("The saved token is used again") { connected(manager) }
        let bad = await manager.replaceToken(id, with: "not a token")
        try check(bad == NativeMCPManager.tokenUnused && keys.values == kept, "An unreadable replacement keeps the saved token")
        try await wait("The saved token is used again after an unreadable one") { connected(manager) }
        let replaced = await manager.replaceToken(id, with: "synthetic-third-token-value")
        try check(replaced == nil && connected(manager) && keys.values != kept, "A working replacement is saved")
        service.refuse("synthetic-third-token-value")
        await manager.authority.disconnect(id, status: "The connection dropped")
        try await wait("A refused saved token asks for a new one") { manager.servers.first?.refused == true }
        let count = service.count
        try await Task.sleep(for: .milliseconds(80))
        try check(service.count == count && manager.hasSavedToken(id) && !manager.reconnects(manager.servers[0]), "A refused saved token is not tried over and over")
        keys.denied = [NativeMCPTokenKeeper.account(id)]
        let locked = try self.manager([row()], service, keys)
        try await Task.sleep(for: .milliseconds(40))
        try check(!connected(locked) && locked.hasSavedToken(id) && service.count == count, "An unreadable saved token is kept and not used")
        keys.denied = []
        await locked.disconnect(id)
        try check(keys.values.isEmpty, "A saved token that couldn't be read can still be removed")
        await manager.disconnect(id)
    }

    static func races() async throws {
        let service = Service(), keys = NativeCredentialFixtureStore()
        let seeded = try manager([row()], service, keys)
        for _ in 0..<40 {
            await seeded.connect(id, token: token)
            await seeded.authority.disconnect(id, status: "The connection dropped")
            seeded.refresh()
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...8)))
            await seeded.disconnect(id)
            try await Task.sleep(for: .milliseconds(12))
            seeded.refresh()
            try check(!connected(seeded) && keys.values.isEmpty, "A reconnect outlived Disconnect")
        }
        for delay in 0..<20 {
            await seeded.connect(id, token: token)
            let replacing = Task { await seeded.replaceToken(id, with: "synthetic-third-token-value") }
            for _ in 0..<delay { await Task.yield() }
            await seeded.disconnect(id)
            _ = await replacing.value
            try await Task.sleep(for: .milliseconds(12))
            seeded.refresh()
            if !connected(seeded) { try check(keys.values.isEmpty, "Replace outlived Disconnect") }
            else { try check(delay == 0, "Replace reconnected after Disconnect") }
            await seeded.disconnect(id)
        }
        let moved = NativeMCPServerConfiguration.load(["native_mcp_servers": [row("http://\(home).1.4:8123/api/mcp")]]).0
        let opening = Task { await seeded.connect(id, token: token) }
        await Task.yield()
        await seeded.reconcileConfiguration(moved)
        await opening.value
        try check(keys.values.isEmpty && !connected(seeded), "A token typed for the old address reached the new one")
    }

    static func discovery() async throws {
        let service = Service(), keys = NativeCredentialFixtureStore()
        var tools = (0..<199).map { NativeMCPChangesSelftest.tool("tool_\($0)") }
        tools.append(NativeMCPChangesSelftest.tool("lookup"))
        let long = String(repeating: "x", count: 50_000)
        tools.append(NativeMCPDiscoveredTool(name: "wordy", description: long, inputSchema: NativeMCPChangesSelftest.schema))
        tools.append(NativeMCPDiscoveredTool(name: "detailed", description: "Detailed", inputSchema: .object(["type": .string("object"), "description": .string(long)])))
        service.offer(tools)
        let names = tools.map(\.name)
        let manager = try manager([row().merging(["read_tools": names]) { $1 }], service, keys)
        await manager.connect(id, token: token)
        try check(connected(manager) && manager.servers[0].tools.map(\.remoteName) == names && manager.servers[0].tools.allSatisfy(\.callable),
                  "Every tool a service offers is listed and can be approved")
        try check(manager.servers[0].tools.first { $0.remoteName == "wordy" }?.description == long, "A long description is kept as sent")
        await manager.disconnect(id)
    }

    static func address() async throws {
        let secret = "private_synthetic_path_value"
        let service = Service(), keys = NativeCredentialFixtureStore()
        let manager = try manager([row("http://\(home).1.4:9583/" + secret)], service, keys)
        await manager.connect(id, token: token)
        let name = manager.servers[0].configuration.toolID("lookup")
        manager.setEnabled([name])
        guard let tool = manager.authority.definitions(scope: "focused").first else { throw NativeToolError.failed("The service is offered") }
        let answer = try await tool.execute([:])
        try check(answer.pi("source") == .string("http://\(home).1.4"), "A result names only the scheme and host")
        let scope = try NativeMCPAuthoritySelftest.scope(mode: "assistant")
        let shared = try await manager.authority.call(scope: scope, id: UUID().uuidString, name: name, arguments: .object([:]), expectedRevision: manager.authority.revision(scope: scope))
        let transport = NativeMCPChatFixture(name: name, arguments: "{}")
        let repository = try LocalChatRepository(inMemory: true)
        let config = NativeChatConfig(baseURL: URL(string: "https://fixture.invalid/v1")!, apiKey: nil, model: "fixture", chatTemplateKwargs: nil)
        let store = ChatStore(nativeConfig: config, nativeTransport: transport, repository: repository, nativeTransportFactory: { _ in transport }, nativeEnabledToolIDs: [name], nativeMCP: manager, artifactPersistenceEnabled: false)
        store.adoptNative(config, enabledToolIDs: [name])
        store.applyNativeOptions(config)
        await store.connect()
        store.newConversation(); store.sendText("Look it up")
        try await wait("The chat uses the service") { !store.generating && store.conversations.flatMap(\.messages).flatMap(\.toolActivities).contains { $0.toolID == name && $0.state == .succeeded } }
        let record = String(reflecting: store.conversations)
        try check(record.contains("\(home).1.4"), "The chat record holds the result")
        for (label, text) in [("result", String(decoding: try answer.piData(), as: UTF8.self)), ("shared result", String(decoding: try shared.piData(), as: UTF8.self)),
                              ("tool", tool.description + tool.title), ("chat record", record), ("status", manager.servers[0].status)] {
            try check(!text.contains(secret) && !text.contains(token), "The \(label) holds part of the address or token")
        }
        await manager.disconnect(id)
    }

    static func numbers() throws {
        for (text, carried) in [("9007199254740993", true), ("-9007199254740993", true), ("12345678901234567890", true), ("9007199254740990.9", true), ("99999999999998.999", true), ("-99999999999998.999", true), ("9.9999999999999999", true), ("-9.9999999999999999", true), ("9007199254740993.0", true), ("-21.299999999999997", false), ("2.1299999999999997e1", false), ("1e400", true), ("1e-400", true),
                                (String(repeating: "7", count: 400), true), ("21.299999999999997", false), ("0.10000000000000001", false), ("7", false), ("0", false), ("0.0", false), ("seven", false), ("", false), ("7 7", false), ("1\n", false)] {
            try check(NativeMCPWireJSON.carries(text) == carried, "A number is carried as text: \(text.prefix(24))")
        }
        let kept = try NativeMCPWireJSON.preserving(Data(#"{"a":[9007199254740993,1,"9007199254740993"],"b":-12345678901234567890}"#.utf8), maximumBytes: 4096)
        try check(String(decoding: kept, as: UTF8.self) == #"{"a":["9007199254740993",1,"9007199254740993"],"b":"-12345678901234567890"}"#, "Every digit is kept")
        func schema(_ count: NativeJSONValue) throws -> NativeMCPJSONSchema {
            try NativeMCPJSONSchema(.object(["type": .string("object"), "properties": .object(["count": count])]))
        }
        let long = NativeJSONValue.object(["count": .string("9007199254740993")])
        let whole = try schema(.object(["type": .string("integer"), "minimum": .string("9007199254740993"), "maximum": .string("18446744073709551615")]))
        try whole.validateResult(long)
        try check(whole.violation(long) != nil, "Arguments still can't send a number as text")
        try check(whole.violation(.object(["count": .number(0)])) != nil, "A long bound still counts")
        for shape in [NativeJSONValue.object(["oneOf": .array([.object(["type": .string("integer")]), .object(["type": .string("string")])])]), .object(["type": .string("string")])] {
            try schema(shape).validateResult(long)
        }
        try schema(.object(["type": .string("integer")])).validateResult(.object(["count": .string("9007199254740993e0")]))
        do {
            try schema(.object(["type": .string("integer")])).validateResult(.object(["count": .string("seven")]))
            throw NativeMCPTransportError.network
        } catch is NativeMCPJSONSchema.Failure {}
        let choices = NativeJSONValue.object(["type": .string("integer"), "enum": .array((0..<20).reversed().map { .number(Double($0)) })])
        try schema(.object(["type": .string("array"), "items": choices])).validateResult(.object(["count": .array(Array(repeating: .number(0), count: 100_000))]))
        try schema(.object(["type": .string("array"), "items": .object(["type": .string("integer")])])).validateResult(.object(["count": .array(Array(repeating: .number(0), count: 100_000))]))
        let entry = NativeJSONValue.object(["type": .string("object"), "properties": .object(Dictionary(uniqueKeysWithValues: (0..<100).map { ("field\($0)", .object(["type": .string("integer")])) }))])
        _ = try NativeMCPJSONSchema(.object(["$defs": .object(["entry": entry]), "type": .string("object"),
                                             "properties": .object(Dictionary(uniqueKeysWithValues: (0..<1_000).map { ("row\($0)", .object(["$ref": .string("#/$defs/entry")])) }))]))
        let numeric = try NativeMCPAuthorization(serverID: id, endpoint: URL(string: address)!, token: "1234567890123456")
        do {
            try numeric.validateResponse(Data(#"{"value":1.23456789012345600001e15}"#.utf8), endpoint: URL(string: address)!, includingDecodedJSON: true)
            throw NativeToolError.failed("A token spelled as a number is accepted")
        } catch NativeMCPTransportError.malformedResponse {}
        let spelled = try NativeMCPAuthorization(serverID: id, endpoint: URL(string: address)!, token: "9999999999999995")
        do {
            try spelled.validateResponse(Data(#"{"value":0.0000001}"#.utf8), endpoint: URL(string: address)!, includingDecodedJSON: true)
            throw NativeToolError.failed("A token spelled by rounding is accepted")
        } catch NativeMCPTransportError.malformedResponse {}
        _ = try schema(.object(["type": .string("array"), "examples": .array(Array(repeating: .null, count: 40_000))]))
    }

    static func hints() async throws {
        let cases: [(Bool?, Bool?, NativeMCPToolState)] = [(true, true, .read), (true, nil, .read), (nil, nil, .read), (nil, true, .change), (false, true, .change), (false, nil, .change), (false, false, .change)]
        for (readOnly, destructive, expected) in cases {
            let service = Service(), keys = NativeCredentialFixtureStore()
            service.offer([NativeMCPChangesSelftest.tool("lookup", readOnly: readOnly, destructive: destructive)])
            let manager = try manager([row()], service, keys)
            await manager.connect(id, token: token)
            try check(manager.servers.first?.tools.first?.state == expected, "A read labelled \(String(describing: readOnly)) and \(String(describing: destructive)) is \(expected)")
            let scope = try NativeMCPAuthoritySelftest.scope(mode: "assistant")
            let offered = try await manager.authority.catalog(scope: scope)
            try check(offered.count == (expected == .read ? 1 : 0), "Only a read is offered in the companion's thread")
            await manager.disconnect(id)
        }
        let service = Service(), keys = NativeCredentialFixtureStore()
        service.offer([NativeMCPChangesSelftest.tool("lookup", readOnly: true, destructive: true)])
        var remembered = row()
        remembered["asks_tools"] = ["lookup"]
        let manager = try manager([remembered], service, keys)
        await manager.connect(id, token: token)
        try check(manager.servers.first?.tools.first?.state == .change, "An installed service keeps asking about what it asked about")
        await manager.disconnect(id)
    }

    static func copy() throws {
        let lines = [IntegrationsText.tokenNote, IntegrationsText.tokenSaved, IntegrationsText.footer(.bearer), IntegrationsText.footer(.none), NativeMCPAuthority.tokenNeeded,
                     NativeMCPManager.tokenUnsaved, NativeMCPManager.tokenUnremoved, NativeMCPManager.tokenUnused, NativeMCPAuthority.oversized] + NativeMCPAddress.reasons
        for line in lines {
            for word in ["hour", "temporary", "enter it again", "reopen", "vera", " she ", " her ", "\u{2014}"] {
                try check(!line.lowercased().contains(word), "The copy says \(word): \(line)")
            }
        }
        try check(!IntegrationsText.footer(.bearer).contains("quits"), "A service with a saved token doesn't say it ends when Tandem quits")
    }
}
