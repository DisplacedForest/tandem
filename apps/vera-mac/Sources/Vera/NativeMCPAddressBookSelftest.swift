import Foundation

@MainActor
enum NativeMCPAddressBookSelftest {
    typealias Disk = NativeMCPLaunchSelftest.Disk
    static let id = "2f7c9a10-6b4e-4d83-a5f1-90c3e7d2b468"
    static let secret = "private_zc7Qp2Lm9Xa4Rt8"
    static let address = "http://house.local:9583/" + secret
    static let token = "synthetic-address-token"

    static func row(_ address: String = address, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "name": "House", "url": address, "scopes": IntegrationsText.scopeKeys, "timeout_seconds": 5.0].merging(extra) { $1 }
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NativeToolError.failed(message) }
    }

    static func saved(_ disk: Disk) -> [String: Any] { (disk.contents["native_mcp_servers"] as? [[String: Any]])?.first ?? [:] }

    static func open(_ disk: Disk, _ keys: NativeCredentialFixtureStore, moves: Bool = true, answer: NativeJSONValue? = nil,
                     tools: [NativeMCPDiscoveredTool]? = nil) async throws -> (NativeMCPManager, ConfigStore) {
        let connection = NativeMCPChangesConnection(tools ?? [NativeMCPChangesSelftest.tool("look", readOnly: true)])
        if let answer { await connection.respond(answer) }
        let book = NativeMCPAddressBook(store: keys)
        let rows = book.resolved(disk.contents["native_mcp_servers"] as? [[String: Any]] ?? [])
        let (servers, failure) = NativeMCPServerConfiguration.load(["native_mcp_servers": rows])
        try check(failure == nil, "The service loads: \(failure ?? "")")
        let manager = NativeMCPManager(servers: servers, authenticatedFactory: { _, _ in connection }, tokens: keys, reconnectDelays: [.milliseconds(5), .milliseconds(20)])
        let config = ConfigStore(credentialStore: keys, readConfiguration: { disk.contents }, nativeMCP: manager, cleansRetiredKeys: moves, writeConfiguration: {
            if disk.broken { throw NativeMCPTransportError.network }
            disk.contents = $0
        })
        return (manager, config)
    }

    static func run() async throws {
        try await moves()
        try await commits()
        try await locked()
        try await missing()
        try await handEdits()
        try await echoes()
        print("NATIVE MCP ADDRESS BOOK SELFTEST OK")
    }

    static func moves() async throws {
        let disk = Disk(["native_mcp_servers": [row(address, ["authentication": "bearer"])], "other": "kept"]), keys = NativeCredentialFixtureStore()
        let (manager, config) = try await open(disk, keys)
        try check(saved(disk)["url"] as? String == "http://house.local" && saved(disk)["address_saved"] as? Bool == true && disk.contents["other"] as? String == "kept", "An installed service's address moves to the keychain")
        try check(keys.values[NativeMCPAddressBook.account(id)] == address, "The keychain holds the whole address")
        await manager.connect(id, token: token)
        let tool = manager.servers[0].configuration.toolID("look")
        try config.save()
        try check(!String(describing: disk.contents).contains(secret) && !String(describing: disk.contents).contains(token), "No save writes the address or token")
        let (again, _) = try await open(disk, keys)
        try check(again.servers[0].configuration.endpoint.absoluteString == address && again.servers[0].configuration.toolID("look") == tool, "A relaunch keeps the address and the tools' identities")
        try await NativeMCPSavedTokenSelftest.wait("A relaunch reconnects") { again.servers[0].connected }

        let plain = Disk(["native_mcp_servers": [row("https://house.example/")]])
        _ = try await open(plain, NativeCredentialFixtureStore())
        try check(saved(plain)["url"] as? String == "https://house.example/" && saved(plain)["address_saved"] == nil, "An address with nothing after the host stays as it is")
        let signIn = Disk(["native_mcp_servers": [IntegrationsShotFixture.signedInRow]])
        _ = try await open(signIn, NativeCredentialFixtureStore())
        try check(saved(signIn)["url"] as? String == "https://reference.example/mcp", "An account sign-in's address stays with its sign-in details")
        let refused = Disk(["native_mcp_servers": [row()]]), stuck = NativeCredentialFixtureStore()
        stuck.failWrites = true
        let (kept, keptConfig) = try await open(refused, stuck)
        stuck.failWrites = false
        try keptConfig.save()
        try check(saved(refused)["url"] as? String == "http://house.local", "The next save moves it")
        refused.contents["native_mcp_servers"] = [row()]
        try check(saved(refused)["url"] as? String == address && kept.servers[0].configuration.endpoint.absoluteString == address, "An address the keychain won't take isn't lost")
        let unwritten = Disk(["native_mcp_servers": [row()]])
        unwritten.broken = true
        let (still, _) = try await open(unwritten, NativeCredentialFixtureStore())
        try check(saved(unwritten)["url"] as? String == address && still.servers[0].configuration.endpoint.absoluteString == address, "A file that can't be rewritten still works")
    }

    static func commits() async throws {
        let disk = Disk([:]), keys = NativeCredentialFixtureStore()
        let (manager, config) = try await open(disk, keys)
        try config.addNativeMCPServer(row())
        try check(saved(disk)["url"] as? String == "http://house.local" && manager.servers[0].configuration.endpoint.absoluteString == address, "A new service's address never reaches the file")
        await manager.connect(id)
        try check(saved(disk)["stays_connected"] as? Bool == true, "Connecting is still remembered")
        let moved = "http://house.local:9583/private_second9Qw3Er7Ty"
        disk.broken = true
        do { try config.updateNativeMCPServer(row(moved)); throw NativeMCPTransportError.network } catch is NativeToolError {}
        try check(keys.values[NativeMCPAddressBook.account(id)] == address && manager.servers[0].configuration.endpoint.absoluteString == address, "A change that can't be written keeps the old address")
        disk.broken = false
        keys.failWrites = true
        do { try config.updateNativeMCPServer(row(moved)); throw NativeMCPTransportError.network } catch is NativeToolError {}
        try check(!String(describing: disk.contents).contains("second9Qw3Er7Ty") && saved(disk)["url"] as? String == "http://house.local", "A change the keychain won't take writes nothing")
        keys.failWrites = false
        try config.updateNativeMCPServer(row(moved))
        try check(keys.values[NativeMCPAddressBook.account(id)] == moved && !String(describing: disk.contents).contains("second9Qw3Er7Ty"), "A new address replaces the old one")
        try config.removeNativeMCPServer(id: id)
        try check(keys.values.isEmpty && disk.contents["native_mcp_servers"] == nil, "Remove deletes the address")
        await config.settleNativeMCP()
    }

    static func locked() async throws {
        let disk = Disk(["native_mcp_servers": [row(address, ["authentication": "bearer"])]]), keys = NativeCredentialFixtureStore()
        let (first, firstConfig) = try await open(disk, keys)
        await first.connect(id, token: token)
        let before = keys.values
        keys.denied = [NativeMCPAddressBook.account(id)]
        let (manager, config) = try await open(disk, keys)
        try check(manager.servers.count == 1 && manager.servers[0].configuration.name == "House" && manager.servers[0].status == NativeMCPManager.lockedAddress, "A locked keychain says what to do")
        await manager.connect(id)
        try check(!manager.servers[0].connected && keys.values == before, "Nothing is lost while it's locked")
        let changed = IntegrationsManageSheet.row(config.nativeMCPServerRows[0], id: id, name: "Home", endpoint: config.nativeMCPServerRows[0]["url"] as? String ?? "", reads: "", acts: "",
                                                  scopes: ["focused"], seconds: 5, authentication: .bearer)
        try config.updateNativeMCPServer(changed)
        try check(saved(disk)["name"] as? String == "Home" && saved(disk)["address_saved"] as? Bool == true && keys.values == before, "A rename while locked keeps the address and token")
        keys.denied = []
        try await NativeMCPSavedTokenSelftest.wait("It comes back once the keychain reads") { manager.servers[0].connected }
        try check(manager.servers[0].configuration.endpoint.absoluteString == address && keys.values[NativeMCPTokenKeeper.account(id)] == before[NativeMCPTokenKeeper.account(id)], "With its address and token")
        try config.save()
        try check(!String(describing: disk.contents).contains(secret), "Still nothing in the file")
        withExtendedLifetime((firstConfig, config)) {}
    }

    static func missing() async throws {
        let disk = Disk(["native_mcp_servers": [row("http://house.local", ["address_saved": true])]]), keys = NativeCredentialFixtureStore()
        let (manager, config) = try await open(disk, keys)
        await manager.connect(id)
        try check(!manager.servers[0].connected && manager.servers[0].status == NativeMCPManager.lockedAddress, "An address that's gone says so")
        var fresh = config.nativeMCPServerRows[0]
        fresh.removeValue(forKey: NativeMCPAddressBook.marker)
        fresh["url"] = address
        let held = "http://house.local:9583/private_held6Old5Addr"
        keys.values[NativeMCPAddressBook.account(id)] = held
        disk.broken = true
        do { try config.updateNativeMCPServer(fresh); throw NativeMCPTransportError.network } catch is NativeToolError {}
        try check(keys.values[NativeMCPAddressBook.account(id)] == held, "A failed change never deletes an address it hadn't read")
        disk.broken = false
        keys.values[NativeMCPAddressBook.account(id)] = nil
        try config.updateNativeMCPServer(fresh)
        await manager.connect(id)
        try check(manager.servers[0].connected && saved(disk)["address_saved"] as? Bool == true, "Entering it again under Manage works")
    }

    static func handEdits() async throws {
        let disk = Disk(["native_mcp_servers": [row()]]), keys = NativeCredentialFixtureStore()
        _ = try await open(disk, keys)
        disk.contents["native_mcp_servers"] = [row("http://other.local:80/private_hand7Edit4ed2", ["address_saved": true])]
        let (edited, _) = try await open(disk, keys)
        try check(edited.servers[0].configuration.endpoint.absoluteString.contains("hand7Edit4ed2") && saved(disk)["url"] as? String == "http://other.local", "A whole address typed into the file wins and moves")
        disk.contents["native_mcp_servers"] = [row("http://third.local", ["address_saved": true])]
        let (elsewhere, _) = try await open(disk, keys)
        try check(elsewhere.servers[0].configuration.endpoint.absoluteString == "http://third.local", "A saved address never follows a service to another host")
        disk.contents["native_mcp_servers"] = [row("https://house.example/mcp", ["id": UUID().uuidString])]
        _ = try await open(disk, keys)
        try check(keys.values.keys.contains { $0.hasPrefix("connected-service-address.") }, "The other service's address is kept")
        disk.contents.removeValue(forKey: "native_mcp_servers")
        disk.contents["other"] = "kept"
        _ = try await open(disk, keys)
        try check(keys.values.isEmpty, "Taking every service out of the file deletes their addresses")
        try check(keys.values[NativeMCPAddressBook.account(id)] == nil, "An address whose service is gone is deleted at launch")
    }

    static func echoes() async throws {
        let disk = Disk(["native_mcp_servers": [row()]]), keys = NativeCredentialFixtureStore()
        let answer = NativeJSONValue.object(["content": .array([.object(["type": .string("text"), "text": .string("See " + address + " or house.local:9583/" + secret + "/x")])]),
                                             "structuredContent": .object([secret: .string(address + "/"), "path": .string("/" + secret), "count": .number(4)])])
        let tools = [NativeMCPDiscoveredTool(name: "look", description: "Reads from " + address, inputSchema: .object(["type": .string("object"), "description": .string("At /" + secret)]),
                                             hints: NativeMCPToolHints(readOnly: true), title: "Look at " + secret)]
        let (manager, config) = try await open(disk, keys, answer: answer, tools: tools)
        await manager.connect(id)
        guard let tool = manager.authority.definitions(scope: "focused").first else { throw NativeToolError.failed("The read is offered") }
        let result = try await tool.execute([:])
        let seen = String(decoding: try result.piData(), as: UTF8.self) + tool.description + String(decoding: try tool.parameters.piData(), as: UTF8.self) + manager.authority.shown(manager.servers[0].tools[0])
        try check(!seen.contains(secret) && seen.contains("http://house.local") && seen.contains("[hidden]"), "A service quoting its own address gives nothing away: \(seen)")
        try check(result.pi("content").pi("structuredContent").pi("count") == .number(4), "The rest of the answer is untouched")
        let failing = NativeMCPChangesConnection(tools)
        await failing.respond(.object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("Bad path /" + secret)])])]))
        let broken = NativeMCPManager(servers: manager.servers.map(\.configuration), factory: { _ in failing })
        await broken.connect(id)
        do { _ = try await broken.authority.definitions(scope: "focused")[0].execute([:]); throw NativeMCPTransportError.network }
        catch NativeToolError.failed(let text) { try check(!text.contains(secret) && text.contains("Bad path [hidden]"), "An error gives nothing away: \(text)") }
        let ordinary = try NativeMCPServerConfiguration(id: id, name: "Docs", endpoint: URL(string: "https://docs.example/api/mcp")!, readTools: [])
        try check(ordinary.redacted("Use the api or mcp, see v2/api") == "Use the api or mcp, see v2/api", "Ordinary words aren't hidden")
        let short = try NativeMCPServerConfiguration(id: id, name: "Short", endpoint: URL(string: "https://service.example:8443/mcp/a7f29c")!, readTools: [])
        for text in ["POST /mcp/a7f29c failed", "service.example:8443/mcp/a7f29c", "at mcp/a7f29c.", "https://service.example:8443/mcp/a7f29c/x", "\"/mcp/a7f29c\""] {
            try check(!short.redacted(text).contains("a7f29c"), "A quoted path gives nothing away: \(short.redacted(text))")
        }
        let wordy = try NativeMCPServerConfiguration(id: id, name: "Wordy", endpoint: URL(string: "https://service.example/home-automations")!, readTools: [])
        try check(wordy.redacted("Your home-automations are on") == "Your home-automations are on", "A long ordinary word isn't hidden")
        let schema = NativeJSONValue.object(["type": .string("object"), "properties": .object([secret: .object(["enum": .array([.string(secret)]), "description": .string("At /" + secret)])])])
        try check(manager.servers[0].configuration.redactedSchema(schema).pi("properties").pi(secret).pi("enum") == .array([.string(secret)]), "What a call is checked against isn't changed")
        withExtendedLifetime(config) {}
    }
}
