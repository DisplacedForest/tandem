import Foundation

@MainActor
enum NativeMCPReportedToolsSelftest {
    static let id = "4d6f0c52-19ab-4b7e-9c33-7be0a2d15f80"
    static let row: [String: Any] = ["id": id, "name": "House", "url": "https://fixture.invalid/mcp", "scopes": IntegrationsText.scopeKeys, "timeout_seconds": 5.0]

    @MainActor
    final class Disk {
        var contents: [String: Any]
        let keys = NativeCredentialFixtureStore()
        var loaded: [String: Any] {
            ["native_mcp_servers": NativeMCPAddressBook(store: keys).resolved(contents["native_mcp_servers"] as? [[String: Any]] ?? [])]
        }
        var writes = 0
        init(_ contents: [String: Any]) { self.contents = contents }
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NativeToolError.failed(message) }
    }

    static func make(_ disk: Disk, _ connection: NativeMCPChangesConnection) -> (NativeMCPManager, ConfigStore) {
        let (servers, _) = NativeMCPServerConfiguration.load(disk.loaded)
        let manager = NativeMCPManager(servers: servers, factory: { _ in connection })
        let config = ConfigStore(credentialStore: disk.keys, readConfiguration: { disk.contents }, nativeMCP: manager,
                                 writeConfiguration: { disk.contents = $0; disk.writes += 1 })
        return (manager, config)
    }

    static func run() async throws {
        try loads()
        try await everyTool()
        try await turnsOff()
        try await manage()
        try await names()
        try await longLists()
        try await sentence()
        try copy()
        print("NATIVE MCP REPORTED TOOLS SELFTEST OK")
    }

    static func loads() throws {
        let (servers, failure) = NativeMCPServerConfiguration.load(["native_mcp_servers": [row]])
        try check(failure == nil && servers.first?.reportsTools == true, "A service with no stored list loads")
        for key in ["read_tools", "act_tools"] {
            var empty = row
            empty[key] = [String]()
            try check(NativeMCPServerConfiguration.load(["native_mcp_servers": [empty]]).1 != nil, "A stored list that is empty is still refused")
        }
        var listed = row
        listed["read_tools"] = ["lookup"]
        let server = NativeMCPServerConfiguration.load(["native_mcp_servers": [listed]]).0.first
        try check(server?.reportsTools == false && server?.state(of: "other", hints: NativeMCPToolHints(readOnly: true)) == .unapproved, "A stored list keeps its meaning")
        guard let reporting = servers.first else { throw NativeToolError.failed("The service loads") }
        for readOnly in [nil, true, false] as [Bool?] {
            for destructive in [nil, true, false] as [Bool?] {
                try check(reporting.state(of: "any", hints: NativeMCPToolHints(readOnly: readOnly, destructive: destructive)) == (readOnly == true ? .read : .change),
                          "Only what the service marks read-only is a read")
            }
        }
        try check(NativeMCPServerConfiguration.load(["native_mcp_servers": (0..<30).map { _ in row.merging(["id": UUID().uuidString]) { $1 } }]).1 == nil, "Any number of services loads")
    }

    static func everyTool() async throws {
        let long = String(repeating: "x", count: 6_000)
        var tools = (0..<200).map { index in
            NativeMCPDiscoveredTool(name: "tool_\(index)", description: "Description \(index)", inputSchema: NativeMCPChangesSelftest.schema,
                                    hints: NativeMCPToolHints(readOnly: index % 2 == 0, destructive: true))
        }
        tools.append(NativeMCPDiscoveredTool(name: String(repeating: "n", count: 300), description: long, inputSchema: NativeMCPChangesSelftest.schema))
        let connection = NativeMCPChangesConnection(tools)
        let disk = Disk(["native_mcp_servers": [row]])
        let (manager, config) = make(disk, connection)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil, nativeMCP: manager, artifactPersistenceEnabled: false)
        await manager.connect(id)
        try check(disk.writes == 1 && config.nativeSettings.enabledToolIDs.isEmpty, "Connecting writes only that it was connected")
        let definitions = manager.authority.definitions(scope: "focused")
        try check(definitions.count == 201 && definitions.filter { $0.effect == .read }.count == 100, "Every tool is on straight after connecting, read or change as reported")
        try check(zip(tools, definitions).allSatisfy { $1.title == "House: " + $0.name && $1.description.hasSuffix($0.description) }, "Each keeps the service's own name and description")
        try check(store.enabledNativeToolIDs == Set(definitions.map(\.id)), "Chat's own copy has them without being told")
        try check(definitions.filter { $0.effect == .write }.allSatisfy { $0.action == .serviceChanges }, "A change still follows its rule")
        let scope = try NativeMCPAuthoritySelftest.scope(mode: "assistant")
        let catalog = try await manager.authority.catalog(scope: scope)
        try check(catalog.count == 100, "The companion's thread is offered every read")
        try PiRuntimeTools.validate(catalog)
        _ = try await manager.authority.call(scope: scope, id: UUID().uuidString, name: definitions[0].name, arguments: .object(["title": .string("x")]),
                                             expectedRevision: manager.authority.revision(scope: scope))
        let added = tools + [NativeMCPChangesSelftest.tool("added_later", readOnly: true)]
        await connection.set(added)
        await manager.disconnect(id)
        await manager.connect(id)
        try check(manager.authority.definitions(scope: "focused").contains { $0.title == "House: added_later" }, "A tool added later is on without reinstalling")
    }

    static func turnsOff() async throws {
        let connection = NativeMCPChangesConnection([NativeMCPChangesSelftest.tool("look", readOnly: true), NativeMCPChangesSelftest.tool("change")])
        let disk = Disk(["native_mcp_servers": [row]])
        let (manager, config) = make(disk, connection)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil, nativeMCP: manager, artifactPersistenceEnabled: false)
        await manager.connect(id)
        guard let look = manager.servers.first?.tools.first(where: { $0.remoteName == "look" }),
              let definition = manager.authority.definitions(scope: "focused").first(where: { $0.id == look.id }) else { throw NativeToolError.failed("The read is offered") }
        try config.setNativeMCPTool(look, enabled: false)
        try check(!definition.isAvailable() && !manager.authority.access.isOn(look) && !store.enabledNativeToolIDs.contains(look.id), "An off tool stops at once")
        try check(manager.servers.first?.connected == true && manager.authority.definitions(scope: "focused").count == 1, "Turning one off keeps the connection and the rest")
        config.setNativeTool(look.id, enabled: true)
        try check(!manager.authority.access.isOn(look) && !manager.authority.definitions(scope: "focused").contains { $0.id == look.id }, "An old saved choice doesn't undo it")
        let (again, _) = make(disk, connection)
        await again.connect(id)
        try check(again.authority.definitions(scope: "focused").map(\.id) == [look.server.toolID("change")], "Off lasts across a relaunch")
        try config.setNativeMCPTool(look, enabled: true)
        try check(manager.authority.access.isOn(look) && !definition.isAvailable(), "On again needs a fresh offer")
        try check((disk.contents["native_mcp_servers"] as? [[String: Any]])?.first?["off_tools"] == nil, "Nothing is left in the row")
        await connection.set([NativeMCPChangesSelftest.tool("look\n", readOnly: true)])
        await manager.disconnect(id)
        await manager.connect(id)
        guard let odd = manager.servers.first?.tools.first else { throw NativeToolError.failed("The oddly named tool is listed") }
        try config.setNativeMCPTool(odd, enabled: false)
        try check(manager.authority.definitions(scope: "focused").isEmpty && NativeMCPServerConfiguration.load(disk.loaded).1 == nil, "Any tool the service reports can be turned off")
        try config.setNativeMCPTool(odd, enabled: true)
    }

    static func manage() async throws {
        let connection = NativeMCPChangesConnection([NativeMCPChangesSelftest.tool("look", readOnly: true)])
        let disk = Disk(["native_mcp_servers": [row.merging(["off_tools": ["other"]]) { $1 }]])
        let (manager, config) = make(disk, connection)
        await manager.connect(id)
        let saved = IntegrationsManageSheet.row(config.nativeMCPServerRows[0], id: id, name: "Home", endpoint: "https://fixture.invalid/mcp", reads: "", acts: "",
                                                scopes: ["focused"], seconds: 5, authentication: .none)
        try check(saved["read_tools"] == nil && saved["act_tools"] == nil && saved["asks_tools"] == nil && saved["off_tools"] as? [String] == ["other"], "Saving Manage doesn't write a list back")
        try config.updateNativeMCPServer(saved)
        try check(manager.servers.first?.configuration.reportsTools == true && manager.authority.definitions(scope: "focused").count == 1
                    && manager.servers.first?.connected == true, "Saving Manage leaves the tools on")
        let typed = IntegrationsManageSheet.row([:], id: UUID().uuidString, name: "New", endpoint: "https://fixture.invalid/mcp", reads: "", acts: "",
                                                scopes: ["focused"], seconds: 9, authentication: .none)
        try check(typed["read_tools"] as? [String] == [], "A new service with nothing typed is not taken as everything")
    }

    static func names() async throws {
        let look = NativeMCPChangesSelftest.tool("look", readOnly: true)
        let second = NativeMCPDiscoveredTool(name: "look", description: "Another", inputSchema: NativeMCPChangesSelftest.schema)
        let connection = NativeMCPChangesConnection([look, second, NativeMCPChangesSelftest.tool("", readOnly: true)])
        let (manager, _) = make(Disk(["native_mcp_servers": [row]]), connection)
        await manager.connect(id)
        guard let state = manager.servers.first else { throw NativeToolError.failed("The service is listed") }
        try check(state.connected && state.tools.count == 1 && state.tools[0].description == look.description && state.tools[0].state == .read, "A broken name leaves the rest working")
        try check(state.notes == ["This service listed a tool with no name, which can't be used.", "This service listed a tool under a name it had already used. The first one is used."], "The screen says what is wrong")
        await manager.disconnect(id)
        try check(manager.servers[0].notes.isEmpty, "A disconnected service says nothing about its tools")
    }

    static func longLists() async throws {
        let ids = (0..<300).map { "mcp_\($0)" }
        _ = try NativeCompanionTaskPayload(assignment: "Look around the house", mode: "manual", connectedToolIDs: ids)
        do {
            _ = try NativeCompanionTaskPayload(assignment: "Look", mode: "manual", connectedToolIDs: ["a", "a"])
            throw NativeMCPTransportError.network
        } catch is NativeTaskError {}
        let long = String(repeating: "x", count: 40_000)
        let connection = NativeMCPChangesConnection([NativeMCPDiscoveredTool(name: "note", description: "Keep a note", inputSchema: .object(["type": .string("object")]))])
        let (manager, _) = make(Disk(["native_mcp_servers": [row]]), connection)
        await manager.connect(id)
        guard let note = manager.authority.definitions(scope: "focused").first else { throw NativeToolError.failed("The change is offered") }
        _ = try await note.execute(note.validatedArguments("{\"text\":\"" + long + "\"}"))
        try check(NativeTaskGenerationJob.validCall(NativeTaskGenerationToolCall(id: "call", name: "note", arguments: long)), "A long call fits handed-off work")
    }

    static func sentence() async throws {
        func titled(_ name: String, _ title: String?) -> NativeMCPDiscoveredTool {
            NativeMCPDiscoveredTool(name: name, description: "Change", inputSchema: NativeMCPChangesSelftest.schema, title: title)
        }
        let connection = NativeMCPChangesConnection([titled("HassTurnOff", nil), titled("HassTurnOn", "Turn on a device"), titled("HassLock", "Lock"), titled("HassSecure", "lock"),
                                                     titled("HassBlank", " \u{202e}\n"), titled("HassMimic", "HassTurnOff"), titled("HassSplit", "Set\nscene")])
        let (manager, _) = make(Disk(["native_mcp_servers": [row.merging(["name": "Home Assistant"]) { $1 }]]), connection)
        await manager.connect(id)
        let phrases = Dictionary(uniqueKeysWithValues: manager.authority.definitions(scope: "focused").map { ($0.title, $0.wantsPhrase) })
        let expected = ["HassTurnOff": "HassTurnOff", "HassTurnOn": "Turn on a device", "HassLock": "HassLock", "HassSecure": "HassSecure", "HassBlank": "HassBlank",
                        "HassMimic": "HassMimic", "HassSplit": "Set scene"]
        for (name, shown) in expected {
            let phrase = phrases["Home Assistant: " + name]
            try check(phrase == "use \(shown) in Home Assistant", "The card asks plainly: \(phrase ?? "none")")
        }
    }

    static func copy() throws {
        let lines = NativeMCPAuthority.notes(nameless: 2, repeated: 2) + [IntegrationsText.footer(.bearer, reports: true), IntegrationsText.disconnectNote, NativeMCPAddress.publicNeedsHTTPS]
        for line in lines {
            for word in ["vera", " she ", " her ", "approve", "\u{2014}"] { try check(!line.lowercased().contains(word), "The copy says \(word): \(line)") }
        }
    }
}
