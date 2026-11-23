import Foundation

enum NativeMCPInstallSelftest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    @MainActor
    final class Disk {
        var contents: [String: Any] = [:]
        var writes = 0
        var failing: (([String: Any]) -> Bool)?
    }

    @MainActor
    static func settle(_ manager: NativeMCPManager, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "the connected services did not update, found \(manager.servers.map(\.configuration.name))")
    }

    @MainActor
    static func run() async throws {
        let disk = Disk()
        disk.contents = ["unrelated_setting": "kept"]
        let manager = NativeMCPManager(servers: [])
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents }, nativeMCP: manager,
                                 writeConfiguration: { disk.contents = $0; disk.writes += 1 })
        try check(config.nativeMCPServerRows.isEmpty && config.nativeMCPConfigurationError == nil, "a fresh configuration should have no services")

        let catalog = FixtureRows()
        let entry = Fixture()
        let row = catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused", "worker"])
        guard let id = row["id"] as? String else { throw Failure(description: "row has no id") }
        try config.addNativeMCPServer(row)
        let written = disk.contents["native_mcp_servers"] as? [[String: Any]] ?? []
        try check(written.count == 1 && written[0]["id"] as? String == id, "the written configuration should hold the new row")
        try check(written[0]["publisher"] as? String == entry.publisher, "the written row should keep the publisher")
        try check(disk.contents["unrelated_setting"] as? String == "kept", "other settings should survive the write")
        try await settle(manager) { manager.servers.map(\.id) == [id] }
        guard let configuration = manager.servers.first?.configuration else { throw Failure(description: "manager has no server") }
        try check(configuration.scopes == ["focused", "worker"], "scopes should match the row")

        let toolID = configuration.toolID(entry.readTools[0])
        config.setNativeTool(toolID, enabled: true)
        config.setNativeTool("web-search", enabled: true)
        try config.save()
        try check(config.nativeSettings.enabledToolIDs.contains(toolID), "the tool should be enabled before removal")

        var renamed = row
        renamed["name"] = "Repository wiki"
        try config.updateNativeMCPServer(renamed)
        try check((disk.contents["native_mcp_servers"] as? [[String: Any]])?.first?["name"] as? String == "Repository wiki", "update should rename the written row")
        try await settle(manager) { manager.servers.first?.configuration.name == "Repository wiki" }
        try check(config.nativeSettings.enabledToolIDs.contains(toolID), "a rename should keep enabled tools")

        var broken = row
        broken["url"] = "http://mcp.example.com/mcp"
        do {
            try config.updateNativeMCPServer(broken)
            throw Failure(description: "an insecure address should be refused")
        } catch let error as NativeToolError {
            try check(!(error.errorDescription ?? "").isEmpty, "the refusal should carry a message")
        }
        try check((disk.contents["native_mcp_servers"] as? [[String: Any]])?.first?["url"] as? String == entry.url, "a refused update should not be written")

        try config.removeNativeMCPServer(id: id)
        try check(disk.contents["native_mcp_servers"] == nil, "removal should delete the row")
        try await settle(manager) { manager.servers.isEmpty }
        try check(!config.nativeSettings.enabledToolIDs.contains(toolID), "removal should prune the server's enabled tools")
        try check(config.nativeSettings.enabledToolIDs.contains("web-search"), "removal should keep unrelated enabled tools")
        let persisted = NativeChatSettings.load(from: disk.contents)
        try check(!persisted.enabledToolIDs.contains(toolID), "the pruned tool should not be persisted")

        for _ in 0..<12 {
            try config.addNativeMCPServer(catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"]))
        }
        try check(config.nativeMCPServerRows.count == 12, "any number of services can be added")
        try await settle(manager) { manager.servers.count == 12 }

        try await runScopeNarrowing(catalog: catalog, entry: entry)
        try await runReconcile(catalog: catalog, entry: entry)
        try await runFailedWrite(catalog: catalog, entry: entry)
        try await runUnrelatedChangeKeepsRead(catalog: catalog, entry: entry)
        try await runNarrowingRefusesRead(catalog: catalog, entry: entry)
        try await runRemovalCancelsRead(catalog: catalog, entry: entry)
        try await runReconnectBeforeRetirement(catalog: catalog, entry: entry)
        let bundled = try NativeMCPStarterCatalog.bundled()
        try await runCompanionJoin()
        try await runFillIn(bundled)
        try await runGitHub(bundled)
        try await runFailedConnect(bundled)
        try await runOwn()
        try await runDeletedListing()
        try checkCopy(bundled)
    }

    struct Fixture {
        let url = "https://wiki.example.com/mcp"
        let publisher = "Example"
        let readTools = ["read_structure", "read_contents", "ask_question"]
    }

    struct FixtureRows {
        func configurationRow(for entry: Fixture, readTools: [String], scopes: [String]) -> [String: Any] {
            ["id": UUID().uuidString.lowercased(), "name": "Fixture wiki", "url": entry.url, "read_tools": readTools, "scopes": scopes, "timeout_seconds": 20.0,
             "publisher": entry.publisher, "source_url": "https://example.com/docs"]
        }
    }

    actor PreviewConnection: NativeMCPConnection {
        let tools: [NativeMCPDiscoveredTool]
        init(tools: [NativeMCPDiscoveredTool]) { self.tools = tools }
        func connect() async throws {}
        func listTools(cursor: String?) async throws -> NativeMCPPage { NativeMCPPage(tools: tools, nextCursor: nil) }
        func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue { .object(["reading": .number(7)]) }
        func disconnect() async {}
    }

    final class Handed: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(URL, Bool)] = []
        func record(_ server: NativeMCPServerConfiguration, _ authorization: NativeMCPAuthorization?) {
            lock.withLock { seen.append((server.endpoint, authorization?.isValid(serverID: server.id, endpoint: server.endpoint) == true)) }
        }
        var all: [(URL, Bool)] { lock.withLock { seen } }
    }

    static func tool(_ name: String, readOnly: Bool? = nil, destructive: Bool? = nil, title: String? = nil) -> NativeMCPDiscoveredTool {
        NativeMCPDiscoveredTool(name: name, description: "Synthetic.", inputSchema: schema, hints: NativeMCPToolHints(readOnly: readOnly, destructive: destructive), title: title)
    }

    @MainActor
    static func runFillIn(_ catalog: NativeMCPStarterCatalog) async throws {
        guard let entry = catalog.entries.first(where: { $0.id == "home-assistant" }) else { throw Failure(description: "Home Assistant is missing") }
        let expected = "https://home.example.com:8123/api/mcp"
        for typed in [expected, "  \(expected) ", "HTTPS://home.example.com:8123/api/mcp"] {
            try check(try entry.endpoint(["address": typed]).absoluteString == expected, "\(typed) should become the address")
        }
        try check(try entry.endpoint(["address": "http://homeassistant.local:9583/private_x/"]).absoluteString == "http://homeassistant.local:9583/private_x/", "an add-on address should be kept as typed")
        for typed in ["", "home.example.com", "ftp://home.example.com", "https://", "https://home example.com", "https://home.example.com:99999", "https://a:b@home.example.com", "https://home.example.com?x=1", "http://home.example.com"] {
            do {
                _ = try entry.endpoint(["address": typed])
                throw Failure(description: "\(typed) should be refused")
            } catch let NativeToolError.failed(reason) { try check(!reason.isEmpty, "a refusal should carry a reason") }
        }

        let handed = Handed()
        let offered = [tool("stub_write", readOnly: false), tool("stub_read_marked_destructive", readOnly: true, destructive: true, title: "Stub title"), tool("stub_unmarked"),
                       tool("stub_read", readOnly: true)] + (0..<196).map { tool("extra_\($0)") }
        let factory: NativeMCPAuthority.AuthenticatedFactory = { server, authorization in
            handed.record(server, authorization)
            return PreviewConnection(tools: offered)
        }
        let disk = Disk()
        let manager = NativeMCPManager(servers: [], authenticatedFactory: factory)
        let config = store(disk, manager)
        let refused = NativeMCPInstallDraft(entry: entry, factory: factory)
        refused.values = ["address": "home"]
        await refused.check()
        try check(refused.step == .fill && refused.error?.isEmpty == false && handed.all.isEmpty && disk.writes == 0, "a malformed address should stop before anything is contacted or saved")
        refused.values = ["address": expected, "token": "two words"]
        await refused.check()
        try check(refused.step == .fill && handed.all.isEmpty, "a malformed token should stop before anything is contacted")
        let silent = NativeMCPInstallDraft(entry: entry, factory: { _, _ in PreviewConnection(tools: []) })
        silent.values = ["address": expected]
        await silent.check()
        try check(silent.step == .fill && silent.error == NativeMCPInstallDraft.nothing, "a server that offers nothing should say so")

        let draft = NativeMCPInstallDraft(entry: entry, factory: factory)
        try check(draft.step == .fill && !draft.filled && !draft.canInstall, "the sheet should start by asking")
        draft.values = ["address": expected, "token": "fixture-token"]
        await draft.check()
        try check(draft.step == .review && disk.writes == 0 && manager.servers.isEmpty, "listing the tools should save nothing")
        try check(draft.offers.map(\.name) == offered.map(\.name), "every tool the server reports should be shown")
        try check(draft.count == "200 tools, 198 write, 2 read", "the count should match the server's, found \(draft.count)")
        try check(draft.reads.map(\.label) == ["Stub title", "stub_read"] && draft.offers.allSatisfy { $0.detail == "Synthetic." }, "names and descriptions should be the server's own")
        guard let connecting = draft.install(config) else { throw Failure(description: "install was refused: \(draft.error ?? "")") }
        try check(draft.install(config) == nil && disk.writes == 1, "a second press should not install twice")
        await connecting.value
        try check(handed.all.count == 2 && handed.all.allSatisfy { $0.0.absoluteString == expected && $0.1 }, "the token should reach the preview and the connection")
        guard let server = manager.servers.first else { throw Failure(description: "nothing was installed") }
        try check(server.connected && server.tools.count == 200, "the service should connect whole")
        let definitions = manager.authority.definitions(scope: "focused")
        try check(definitions.count == 200, "every tool should be available, found \(definitions.count)")
        try check(definitions.first { $0.id == server.configuration.toolID("stub_read_marked_destructive") }?.effect == .read, "a tool the server marks read only should be a read")
        try check(definitions.first { $0.id == server.configuration.toolID("stub_unmarked") }?.action == .serviceChanges, "an unmarked tool should follow the rule for changes")
        try check(definitions.first { $0.id == server.configuration.toolID("stub_write") }?.action == .serviceChanges, "a write should follow the rule for changes")
        let written = String(decoding: try JSONSerialization.data(withJSONObject: disk.contents), as: UTF8.self)
        try check(!written.contains("fixture-token"), "the token should not be in the configuration")
        try check(server.configuration.scopes == Set(IntegrationsText.scopeKeys), "a new service should be available everywhere")
        try check(draft.values.isEmpty && entry.matches(server.configuration), "the typed values should be cleared and the entry should show as installed")

        let bare = NativeMCPInstallDraft(entry: entry, factory: factory)
        bare.values = ["address": "https://home.example.com/private_x"]
        await bare.check()
        let open = NativeMCPManager(servers: [], authenticatedFactory: factory)
        let other = store(Disk(), open)
        await bare.install(other)?.value
        try check(open.servers.first?.configuration.authentication == NativeMCPServerConfiguration.Authentication.none && open.servers.first?.connected == true, "a server that needs no token should connect without one")

        let dropped = NativeMCPInstallDraft(entry: entry, factory: factory)
        dropped.values = ["address": expected]
        dropped.beginCheck()
        dropped.cancel()
        try await Task.sleep(for: .milliseconds(50))
        try check(dropped.step != .review && dropped.values.isEmpty, "closing the sheet should drop the check")
    }

    @MainActor
    static func runCompanionJoin() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-join-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let offered = Offered((0..<78).map { tool("stub_\($0)", readOnly: true) })
        let kinds = ["a0000000-0000-4000-8000-000000000001", "a0000000-0000-4000-8000-000000000002"]
        let servers = try kinds.map { id in
            try NativeMCPServerConfiguration(id: id, name: "Stub", endpoint: URL(string: "https://\(id.suffix(1)).example.com/mcp")!,
                                             readTools: [], scopes: Set(IntegrationsText.scopeKeys))
        }
        let manager = NativeMCPManager(servers: servers, authenticatedFactory: { _, _ in PreviewConnection(tools: offered.tools) })
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: try LocalChatRepository(url: folder.appendingPathComponent("chat.sqlite")),
                              nativeAssistantName: "Ada", nativeMCP: manager, artifactPersistenceEnabled: false)
        store.loadDotProfile()
        for id in kinds { await manager.connect(id) }
        let reported: (Int) -> Set<String> = { index in Set(manager.servers[index].tools.map(\.id)) }
        try check(manager.servers.allSatisfy(\.connected) && reported(0).count == 78, "the fixture services should connect")
        store.connectAddedService(kinds[0], scopes: Set(IntegrationsText.scopeKeys))
        try check(store.dotProfile.connectedToolIDs == nil, "an open selection should stay open")
        store.saveDotProfile { $0.connectedToolIDs = ["notes"] }
        manager.refresh()
        try check(store.dotProfile.connectedToolIDs == ["notes"], "services taken out should stay out")
        store.connectAddedService(kinds[0], scopes: ["focused"])
        try check(store.dotProfile.connectedToolIDs == ["notes"], "a service kept from the companion should not join")
        for id in kinds { await manager.disconnect(id) }
        store.connectAddedService(kinds[0], scopes: Set(IntegrationsText.scopeKeys))
        for id in kinds { await manager.connect(id) }
        try check(store.dotProfile.connectedToolIDs?.isSuperset(of: reported(0)) == true, "an added service should join once it reports its tools")
        try check(store.dotProfile.connectedToolIDs?.isDisjoint(with: reported(1)) == true, "the other service should stay out")
        await manager.disconnect(kinds[0])
        offered.add(tool("stub_78", readOnly: true))
        await manager.connect(kinds[0])
        try check(reported(0).count == 79 && store.dotProfile.connectedToolIDs?.isSuperset(of: reported(0)) == true, "a tool the service adds later should join")
        _ = try ChatStore.companionRequest("Check the stubs.", connectedToolIDs: store.dotProfile.connectedToolIDs?.sorted(), said: "")

        let marker = "service:" + kinds[0]
        let left = "left:" + kinds[0]
        let notes = NativeDotServiceOption(id: "notes", name: "Notes", detail: "", toolIDs: ["notes"])
        await manager.disconnect(kinds[0])
        try check(store.dotConnectedToolIDs(selected: ["notes"], options: [notes]) == ["notes", marker], "saving the companion's services should keep one that isn't connected")
        try check(store.dotConnectedToolIDs(selected: [], options: [notes]) == [marker], "taking one service out should leave the ones out of sight")
        store.saveDotProfile { $0.connectedToolIDs = nil }
        try check(store.dotConnectedToolIDs(selected: [], options: [notes]) == Set(kinds.map { "service:" + $0 }), "narrowing should keep the services it can't see")

        offered.set([tool("stub_old", readOnly: true), tool("stub_current", readOnly: true)])
        store.saveDotProfile { $0.connectedToolIDs = ["notes", marker] }
        await manager.connect(kinds[0])
        await manager.disconnect(kinds[1])
        let shown = { [notes, NativeDotServiceOption(id: marker, name: "Stub", detail: "", toolIDs: reported(0))] }
        let picked = store.dotConnectedToolIDs(selected: ["notes", marker], options: shown())
        try check(picked?.contains(marker) == true && picked?.isSuperset(of: reported(0)) == true, "choosing a service should remember the service")
        offered.set([tool("stub_renamed", readOnly: true)])
        await manager.disconnect(kinds[0])
        await manager.connect(kinds[0])
        try check(store.dotProfile.connectedToolIDs?.isSuperset(of: reported(0)) == true && reported(0).count == 1, "a service that renames every tool should stay chosen")
        let taken = store.dotConnectedToolIDs(selected: ["notes"], options: shown())
        try check(taken?.contains(left) == true && taken?.contains(marker) == false && taken?.isDisjoint(with: reported(0)) == true, "a service taken out should be recorded as out")
        store.saveDotProfile { $0.connectedToolIDs = taken }
        offered.set([tool("stub_old", readOnly: true)])
        await manager.disconnect(kinds[0])
        await manager.connect(kinds[0])
        try check(store.dotProfile.connectedToolIDs == taken && store.dotToolIDs(base: reported(0).union(["notes"])) == ["notes"], "a tool that comes back shouldn't bring its service back")

        offered.set([tool("stub_old", readOnly: true)])
        store.saveDotProfile { $0.connectedToolIDs = reported(0) }
        manager.refresh()
        try check(store.dotProfile.connectedToolIDs?.contains(marker) == true, "a selection made before services were remembered should remember them")

        let sheet = shown() + [NativeDotServiceOption(id: "web", name: "Web", detail: "", toolIDs: ["web"])]
        offered.add(tool("stub_late", readOnly: true))
        await manager.disconnect(kinds[0])
        await manager.connect(kinds[0])
        try check(store.dotConnectedToolIDs(selected: [marker, "notes"], options: sheet)?.isSuperset(of: reported(0)) == true && reported(0).count == 2,
                  "saving a sheet opened before a tool arrived should keep the tool")

        let legacy = reported(0)
        await manager.disconnect(kinds[0])
        store.saveDotProfile { $0.connectedToolIDs = legacy.union(["notes"]) }
        let unseen = store.dotConnectedToolIDs(selected: ["notes"], options: [notes])
        try check(unseen?.isSuperset(of: legacy) == true, "a selection from before should survive a save while its service is unreachable")
        store.saveDotProfile { $0.connectedToolIDs = unseen }
        await manager.connect(kinds[0])
        try check(store.dotProfile.connectedToolIDs?.contains(marker) == true, "it should be remembered once the service reports")

        store.saveDotProfile { $0.connectedToolIDs = legacy.union(["notes", left]) }
        try check(store.dotToolIDs(base: legacy.union(["notes"])) == ["notes"] && !store.dotSelectedServices(shown()).contains(marker), "a service taken out should stay out whatever ids remain")
        store.connectAddedService(kinds[0], scopes: Set(IntegrationsText.scopeKeys))
        try check(store.dotProfile.connectedToolIDs?.contains(left) == false && store.dotToolIDs(base: legacy) == legacy, "adding it again should bring it back")
    }

    final class Offered: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [NativeMCPDiscoveredTool]
        init(_ tools: [NativeMCPDiscoveredTool]) { held = tools }
        var tools: [NativeMCPDiscoveredTool] { lock.withLock { held } }
        func add(_ tool: NativeMCPDiscoveredTool) { lock.withLock { held.append(tool) } }
        func set(_ tools: [NativeMCPDiscoveredTool]) { lock.withLock { held = tools } }
    }

    @MainActor
    static func runGitHub(_ catalog: NativeMCPStarterCatalog) async throws {
        guard let entry = catalog.entries.first(where: { $0.id == "github" }) else { throw Failure(description: "GitHub is missing") }
        let factory: NativeMCPAuthority.AuthenticatedFactory = { _, _ in PreviewConnection(tools: [tool("stub_read", readOnly: true), tool("stub_write", readOnly: false)]) }
        let manager = NativeMCPManager(servers: [], authenticatedFactory: factory)
        let config = store(Disk(), manager)
        let draft = NativeMCPInstallDraft(entry: entry, factory: factory)
        try check(!draft.filled, "GitHub should ask for its token")
        draft.values = ["token": "fixture-token"]
        await draft.check()
        try check(draft.count == "2 tools, 1 write, 1 read", "GitHub's tools should come from the server")
        await draft.install(config)?.value
        guard let server = manager.servers.first else { throw Failure(description: "GitHub was not installed") }
        try check(server.configuration.endpoint.absoluteString == entry.url && server.configuration.authentication == .bearer && server.connected, "GitHub should connect with its token")
    }

    @MainActor
    static func runFailedConnect(_ catalog: NativeMCPStarterCatalog) async throws {
        guard let entry = catalog.entries.first(where: { $0.id == "home-assistant" }) else { throw Failure(description: "Home Assistant is missing") }
        let typed = ["address": "https://home.example.com/mcp", "token": "fixture-token"]
        let manager = NativeMCPManager(servers: [], authenticatedFactory: { _, _ in RefusingConnection() })
        let disk = Disk()
        let config = store(disk, manager)
        let draft = NativeMCPInstallDraft(entry: entry, factory: { _, _ in PreviewConnection(tools: [tool("stub_read", readOnly: true)]) })
        draft.values = typed
        await draft.check()
        await draft.install(config)?.value
        try check(draft.step == .fill && draft.values == typed && draft.error?.isEmpty == false, "a connection that fails should say why and keep what was entered")
        try check(config.nativeMCPServerRows.isEmpty && manager.servers.isEmpty, "a service that never connected should not be left behind")
        await draft.check()
        try check(draft.canInstall, "a failed install should be tried again")

        disk.failing = { $0["native_mcp_servers"] == nil }
        await draft.install(config)?.value
        try check(draft.step == .fill && draft.error == NativeMCPInstallDraft.leftBehind && config.nativeMCPServerRows.count == 1, "a service that can't be taken out again should be said plainly")
        await draft.check()
        await draft.install(config)?.value
        try check(config.nativeMCPServerRows.count == 1, "trying again should reuse the same service")
        disk.failing = nil
        try check(draft.cancel() && config.nativeMCPServerRows.isEmpty, "cancel should take the service out")

        let slow = SlowConnection()
        let keys = NativeCredentialFixtureStore()
        let waiting = NativeMCPManager(servers: [], authenticatedFactory: { _, _ in slow }, tokens: keys)
        let pending = Disk()
        let other = store(pending, waiting)
        let leaving = NativeMCPInstallDraft(entry: entry, factory: { _, _ in PreviewConnection(tools: [tool("stub_read", readOnly: true)]) })
        leaving.values = typed
        await leaving.check()
        guard let connecting = leaving.install(other) else { throw Failure(description: "the slow install was refused") }
        for _ in 0..<200 where !(await slow.isWaiting()) { try await Task.sleep(for: .milliseconds(5)) }
        try check(await slow.isWaiting(), "the slow connection should be waiting")
        let id = leaving.id
        try check(leaving.cancel() && other.nativeMCPServerRows.isEmpty && pending.contents["native_mcp_servers"] == nil, "cancel should take the service out at once")
        await slow.release()
        await connecting.value
        await other.settleNativeMCP()
        try check(waiting.servers.isEmpty && leaving.step != .installed && leaving.values.isEmpty, "a cancelled install should not come back")
        try check(try keys.readForStartup(for: NativeMCPTokenKeeper.account(id)) == nil, "a cancelled install should not save its token")
    }

    actor SlowConnection: NativeMCPConnection {
        private var waiting = false
        private var released = false
        func connect() async throws {
            waiting = true
            while !released { try? await Task.sleep(for: .milliseconds(5)) }
        }
        func listTools(cursor: String?) async throws -> NativeMCPPage {
            NativeMCPPage(tools: [NativeMCPInstallSelftest.tool("stub_read", readOnly: true)], nextCursor: nil)
        }
        func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue { .null }
        func disconnect() async {}
        func isWaiting() -> Bool { waiting }
        func release() { released = true }
    }

    actor RefusingConnection: NativeMCPConnection {
        func connect() async throws { throw NativeToolError.failed("Refused.") }
        func listTools(cursor: String?) async throws -> NativeMCPPage { NativeMCPPage(tools: [], nextCursor: nil) }
        func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue { .null }
        func disconnect() async {}
    }

    @MainActor
    static func runOwn() async throws {
        let factory: NativeMCPAuthority.AuthenticatedFactory = { _, _ in PreviewConnection(tools: [tool("stub_read", readOnly: true), tool("stub_write", readOnly: false)]) }
        let manager = NativeMCPManager(servers: [], authenticatedFactory: factory)
        let config = store(Disk(), manager)
        let draft = NativeMCPInstallDraft(entry: .own, factory: factory)
        draft.values = ["address": "https://tools.example.com/mcp"]
        try check(!draft.filled, "an added service needs a name")
        draft.values["name"] = "Workshop"
        await draft.check()
        try check(draft.step == .review && draft.count == "2 tools, 1 write, 1 read", "an added service should show what its server reports")
        await draft.install(config)?.value
        guard let server = manager.servers.first else { throw Failure(description: "the added service is missing: \(draft.error ?? "")") }
        try check(draft.step == .installed && server.connected && server.configuration.name == "Workshop" && server.configuration.publisher == nil
                  && server.configuration.sourceURL == nil && server.configuration.authentication == .none, "an added service should connect with only what was entered")
    }

    @MainActor
    static func runDeletedListing() async throws {
        let disk = Disk()
        let row: [String: Any] = ["id": "0b6f5a52-9a1d-4e86-a4a3-6c1de6f1f0aa", "name": "Microsoft Learn", "url": "https://learn.microsoft.com/api/mcp",
                                  "read_tools": ["microsoft_docs_search"], "scopes": ["focused"], "timeout_seconds": 20.0, "publisher": "Microsoft",
                                  "source_url": "https://learn.microsoft.com/training/support/mcp"]
        disk.contents = ["native_mcp_servers": [row]]
        let (servers, failure) = NativeMCPServerConfiguration.load(disk.contents)
        let manager = NativeMCPManager(servers: servers, factory: { _ in PreviewConnection(tools: [tool("microsoft_docs_search", readOnly: true)]) })
        let config = store(disk, manager)
        guard failure == nil, let server = servers.first else { throw Failure(description: "an installed service lost its row") }
        await manager.connect(server.id)
        config.setNativeTool(server.toolID("microsoft_docs_search"), enabled: true)
        try check(manager.servers.first?.connected == true, "a service with no listing should still connect")
        let definition = manager.authority.definitions(scope: "focused").first
        guard let definition else { throw Failure(description: "a service with no listing should stay callable") }
        _ = try await definition.execute([:])
    }

    static func checkCopy(_ catalog: NativeMCPStarterCatalog) throws {
        var lines = [NativeMCPInstallDraft.unreachable, NativeMCPInstallDraft.nothing, NativeMCPInstallDraft.leftBehind]
        for entry in catalog.entries + [.own] {
            lines += [entry.name, entry.publisher, entry.description, entry.category]
            lines += entry.fields.flatMap { [$0.label, $0.placeholder ?? "", $0.help ?? ""] }
        }
        let banned = try NSRegularExpression(pattern: "\\b(vera|task|background|worker|agent|she|he|her|his)s?\\b|__|\u{2014}", options: .caseInsensitive)
        for line in lines where banned.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            throw Failure(description: "a line on the install sheet needs plainer words: \(line)")
        }
    }

    actor HeldConnection: NativeMCPConnection {
        let tools: [NativeMCPDiscoveredTool]
        var released = false
        var waiting = 0
        var closes = 0
        init(tools: [NativeMCPDiscoveredTool]) { self.tools = tools }
        func connect() async throws {}
        func listTools(cursor: String?) async throws -> NativeMCPPage { NativeMCPPage(tools: tools, nextCursor: nil) }
        func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue {
            waiting += 1
            defer { waiting -= 1 }
            while !released { try await Task.sleep(for: .milliseconds(5)) }
            return .object(["reading": .number(7)])
        }
        func disconnect() async { closes += 1 }
        func release() { released = true }
        func hold() { released = false }
        func isWaiting() -> Bool { waiting > 0 }
        func closeCount() -> Int { closes }
    }

    final class ConnectionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [(server: String, connection: HeldConnection)] = []
        func record(_ server: String, _ connection: HeldConnection) { lock.withLock { made.append((server, connection)) } }
        func connections(_ server: String) -> [HeldConnection] { lock.withLock { made.filter { $0.server == server }.map(\.connection) } }
    }

    struct Harness {
        let config: ConfigStore
        let manager: NativeMCPManager
        let log: ConnectionLog
        let id: String
        let row: [String: Any]
        let toolID: String
    }

    @MainActor
    static func harness(catalog: FixtureRows, entry: Fixture, scopes: [String]) async throws -> Harness {
        let log = ConnectionLog()
        let names = entry.readTools
        let manager = NativeMCPManager(servers: [], factory: { server in
            let connection = HeldConnection(tools: names.map { NativeMCPDiscoveredTool(name: $0, description: "Synthetic read.", inputSchema: schema) })
            log.record(server.id, connection)
            return connection
        })
        let config = store(Disk(), manager)
        let row = catalog.configurationRow(for: entry, readTools: names, scopes: scopes)
        guard let id = row["id"] as? String else { throw Failure(description: "row has no id") }
        try config.addNativeMCPServer(row)
        await config.settleNativeMCP()
        await manager.connect(id)
        guard let configuration = manager.servers.first(where: { $0.id == id })?.configuration, manager.servers.first?.connected == true else {
            throw Failure(description: "the fixture service did not connect")
        }
        let toolID = configuration.toolID(names[0])
        config.setNativeTool(toolID, enabled: true)
        return Harness(config: config, manager: manager, log: log, id: id, row: row, toolID: toolID)
    }

    @MainActor
    static func startRead(_ harness: Harness, scope: PiModelScope) async throws -> (Task<NativeJSONValue, Error>, HeldConnection) {
        guard let connection = harness.log.connections(harness.id).last else { throw Failure(description: "no fixture connection") }
        await connection.hold()
        let authority = harness.manager.authority
        let name = harness.toolID
        let task = Task { try await authority.call(scope: scope, id: UUID().uuidString, name: name, arguments: .object(["query": .string("status")])) }
        for _ in 0..<200 {
            if await connection.isWaiting() { return (task, connection) }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        throw Failure(description: "the fixture read did not start")
    }

    @MainActor
    static func runUnrelatedChangeKeepsRead(catalog: FixtureRows, entry: Fixture) async throws {
        let harness = try await harness(catalog: catalog, entry: entry, scopes: ["focused", "worker"])
        let (read, connection) = try await startRead(harness, scope: try NativeMCPAuthoritySelftest.scope(mode: "focused"))
        try harness.config.addNativeMCPServer(catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"]))
        await harness.config.settleNativeMCP()
        await connection.release()
        let result = try await read.value
        try check(result.pi("content").pi("reading") == .number(7), "the read on the unchanged service should return normally")
        try check(harness.manager.servers.first(where: { $0.id == harness.id })?.connected == true, "the unchanged service should stay connected")
        try check(await connection.closeCount() == 0, "the unchanged service connection should not close")
    }

    @MainActor
    static func runNarrowingRefusesRead(catalog: FixtureRows, entry: Fixture) async throws {
        let harness = try await harness(catalog: catalog, entry: entry, scopes: ["focused", "worker"])
        let (read, connection) = try await startRead(harness, scope: try NativeMCPAuthoritySelftest.scope("worker"))
        var narrowed = harness.row
        narrowed["scopes"] = ["focused"]
        try harness.config.updateNativeMCPServer(narrowed)
        await harness.config.settleNativeMCP()
        await connection.release()
        do {
            _ = try await read.value
            throw Failure(description: "a read in a removed scope should be refused")
        } catch is NativeToolError {} catch is CancellationError {}
        try check(harness.manager.servers.first(where: { $0.id == harness.id })?.connected == true, "narrowing should keep the service connected")
        try check(await connection.closeCount() == 0, "narrowing should not close the connection")
        let (focusedRead, _) = try await startRead(harness, scope: try NativeMCPAuthoritySelftest.scope(mode: "focused"))
        await connection.release()
        _ = try await focusedRead.value
    }

    @MainActor
    static func runRemovalCancelsRead(catalog: FixtureRows, entry: Fixture) async throws {
        let harness = try await harness(catalog: catalog, entry: entry, scopes: ["focused"])
        let (read, connection) = try await startRead(harness, scope: try NativeMCPAuthoritySelftest.scope(mode: "focused"))
        try harness.config.removeNativeMCPServer(id: harness.id)
        await harness.config.settleNativeMCP()
        do {
            _ = try await read.value
            throw Failure(description: "a read on a removed service should be cancelled")
        } catch is NativeToolError {} catch is CancellationError {}
        try check(await connection.closeCount() == 1, "removal should tear down the connection once")
        try check(harness.manager.servers.isEmpty, "removal should drop the service")
    }

    @MainActor
    static func runReconnectBeforeRetirement(catalog: FixtureRows, entry: Fixture) async throws {
        let harness = try await harness(catalog: catalog, entry: entry, scopes: ["focused"])
        guard let old = harness.log.connections(harness.id).first,
              let configuration = harness.manager.servers.first?.configuration else { throw Failure(description: "missing first connection") }
        let moved = try NativeMCPServerConfiguration(id: configuration.id, name: configuration.name, endpoint: URL(string: "https://mcp.example.com/mcp")!,
                                                     readTools: configuration.readTools, scopes: configuration.scopes)
        let stale = harness.manager.applyConfigurationSynchronously([moved])
        try check(stale[harness.id] != nil, "an address change should retire the old connection")
        await harness.manager.connect(harness.id)
        let made = harness.log.connections(harness.id)
        try check(made.count == 2, "reconnecting should open a second connection")
        try check(harness.manager.servers.first?.connected == true, "the new connection should be live before retirement")
        await harness.manager.retireConfiguration(stale)
        try check(await old.closeCount() == 1, "retirement should close exactly the old connection")
        try check(await made[1].closeCount() == 0, "retirement should leave the new connection open")
        try check(harness.manager.servers.first?.connected == true, "the new connection should stay live after retirement")
        let movedToolID = moved.toolID(entry.readTools[0])
        harness.config.setNativeTool(movedToolID, enabled: true)
        let current = Harness(config: harness.config, manager: harness.manager, log: harness.log, id: harness.id, row: harness.row, toolID: movedToolID)
        let (read, connection) = try await startRead(current, scope: try NativeMCPAuthoritySelftest.scope(mode: "focused"))
        try check(connection === made[1], "reads should use the new connection")
        await connection.release()
        _ = try await read.value
    }

    static let schema: NativeJSONValue = .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("string"), "maxLength": .number(200)])]),
        "additionalProperties": .bool(false),
    ])

    @MainActor
    @discardableResult
    static func markConnected(_ manager: NativeMCPManager, id: String) throws -> NativeMCPToolRecord {
        guard var state = manager.authority.access.snapshot().first(where: { $0.id == id }),
              let name = state.configuration.readTools.sorted().first else { throw Failure(description: "server \(id) is not configured") }
        let record = NativeMCPToolRecord(id: state.configuration.toolID(name), server: state.configuration, generation: state.generation, remoteName: name,
                                         description: "Synthetic read.", schema: schema, validator: try? NativeMCPJSONSchema(schema), reason: nil)
        state.connected = true
        state.status = "Connected"
        state.tools = [record]
        guard manager.authority.access.update(state) else { throw Failure(description: "could not mark \(id) connected") }
        manager.refresh()
        return record
    }

    @MainActor
    static func store(_ disk: Disk, _ manager: NativeMCPManager) -> ConfigStore {
        ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents }, nativeMCP: manager,
                    writeConfiguration: {
                        if disk.failing?($0) == true { throw Failure(description: "The disk refused.") }
                        disk.contents = $0
                        disk.writes += 1
                    })
    }

    @MainActor
    static func runScopeNarrowing(catalog: FixtureRows, entry: Fixture) async throws {
        let disk = Disk()
        let manager = NativeMCPManager(servers: [])
        let config = store(disk, manager)
        let row = catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused", "worker"])
        guard let id = row["id"] as? String else { throw Failure(description: "row has no id") }
        try config.addNativeMCPServer(row)
        try await settle(manager) { manager.servers.map(\.id) == [id] }
        let record = try markConnected(manager, id: id)
        config.setNativeTool(record.id, enabled: true)
        let access = manager.authority.access
        try check(access.allowed(record, scope: "worker") && access.allowed(record, scope: "focused"), "the tool should start allowed in both scopes")
        var narrowed = row
        narrowed["scopes"] = ["focused"]
        try config.updateNativeMCPServer(narrowed)
        try check(!access.allowed(record, scope: "worker"), "narrowing should revoke the worker scope before any await")
        try check(access.allowed(record, scope: "focused"), "narrowing should keep the focused scope")
        try check(access.snapshot().first?.connected == true, "narrowing should keep the connection")
        try check(config.nativeSettings.enabledToolIDs.contains(record.id), "narrowing should keep consent")
        await manager.authority.permissionsChanged()
        try check(!access.allowed(record, scope: "worker"), "the removed scope should stay revoked")
    }

    @MainActor
    static func runReconcile(catalog: FixtureRows, entry: Fixture) async throws {
        let disk = Disk()
        let manager = NativeMCPManager(servers: [])
        let config = store(disk, manager)
        let first = catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"])
        let second = catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"])
        guard let firstID = first["id"] as? String, let secondID = second["id"] as? String else { throw Failure(description: "rows have no ids") }
        try config.addNativeMCPServer(first)
        try config.addNativeMCPServer(second)
        try await settle(manager) { manager.servers.count == 2 }
        try markConnected(manager, id: firstID)
        try markConnected(manager, id: secondID)
        let access = manager.authority.access
        guard let firstGeneration = access.snapshot().first(where: { $0.id == firstID })?.generation,
              let secondGeneration = access.snapshot().first(where: { $0.id == secondID })?.generation else { throw Failure(description: "missing states") }

        try config.addNativeMCPServer(catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"]))
        try await settle(manager) { manager.servers.count == 3 }
        await manager.authority.permissionsChanged()
        let afterAdd = access.snapshot()
        try check(afterAdd.first(where: { $0.id == firstID }).map { $0.connected && $0.generation == firstGeneration && $0.tools.count == 1 } == true, "adding a service should keep the first connection")
        try check(afterAdd.first(where: { $0.id == secondID }).map { $0.connected && $0.generation == secondGeneration } == true, "adding a service should keep the second connection")
        try check(afterAdd.last?.connected == false, "a new service should start disconnected")

        var moved = second
        moved["url"] = "https://mcp.example.com/mcp"
        try config.updateNativeMCPServer(moved)
        let afterUpdate = access.snapshot()
        try check(afterUpdate.first(where: { $0.id == firstID }).map { $0.connected && $0.generation == firstGeneration } == true, "updating the second service should leave the first connected")
        try check(afterUpdate.first(where: { $0.id == secondID }).map { !$0.connected && $0.tools.isEmpty && $0.generation != secondGeneration } == true, "updating the second service address should disconnect it")
        try await settle(manager) { manager.servers.first(where: { $0.id == secondID })?.configuration.endpoint.host == "mcp.example.com" }
        try check(manager.servers.first(where: { $0.id == firstID })?.connected == true, "the first service should stay connected after teardown")
    }

    @MainActor
    final class FlakyDisk {
        var contents: [String: Any] = [:]
        var failures = 0
    }

    struct WriteFailure: Error {}

    @MainActor
    static func runFailedWrite(catalog: FixtureRows, entry: Fixture) async throws {
        let disk = FlakyDisk()
        let manager = NativeMCPManager(servers: [])
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents }, nativeMCP: manager,
                                 writeConfiguration: { value in
                                     if disk.failures > 0 { disk.failures -= 1; throw WriteFailure() }
                                     disk.contents = value
                                 })
        let row = catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"])
        guard let id = row["id"] as? String else { throw Failure(description: "row has no id") }
        try config.addNativeMCPServer(row)
        try await settle(manager) { manager.servers.map(\.id) == [id] }
        let record = try markConnected(manager, id: id)
        config.setNativeTool(record.id, enabled: true)
        try config.save()
        func persisted() -> (Bool, Bool) {
            let rows = disk.contents["native_mcp_servers"] as? [[String: Any]] ?? []
            return (rows.contains { $0["id"] as? String == id }, NativeChatSettings.load(from: disk.contents).enabledToolIDs.contains(record.id))
        }
        try check(persisted() == (true, true), "the row and consent should be saved before removal")

        disk.failures = 1
        do {
            try config.removeNativeMCPServer(id: id)
            throw Failure(description: "a failed write should fail the removal")
        } catch is NativeToolError {}
        try check(config.nativeMCPServerRows.contains { $0["id"] as? String == id }, "a failed removal should keep the row in memory")
        try check(config.nativeSettings.enabledToolIDs.contains(record.id), "a failed removal should keep consent in memory")
        try check(persisted() == (true, true), "a failed removal should leave the file untouched")
        try check(manager.authority.access.allowed(record, scope: "focused"), "a failed removal should leave the connection authorized")

        try config.removeNativeMCPServer(id: id)
        try check(config.nativeMCPServerRows.isEmpty && !config.nativeSettings.enabledToolIDs.contains(record.id), "a second removal should clear memory")
        try check(persisted() == (false, false), "a second removal should clear the row and consent in one write")
        try check(!manager.authority.access.allowed(record, scope: "focused"), "removal should revoke access immediately")
        try await settle(manager) { manager.servers.isEmpty }
    }
}
