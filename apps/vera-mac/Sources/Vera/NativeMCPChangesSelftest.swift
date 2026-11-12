import Foundation

final class NativeMCPChangesLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.withLock { names.append(name) } }
    func count(_ name: String) -> Int { lock.withLock { names.filter { $0 == name }.count } }
}

actor NativeMCPChangesConnection: NativeMCPConnection {
    private var tools: [NativeMCPDiscoveredTool]
    private var reply = "ok"
    private var holding = false
    private var held: CheckedContinuation<Void, Never>?
    nonisolated let log = NativeMCPChangesLog()
    init(_ tools: [NativeMCPDiscoveredTool]) { self.tools = tools }
    func connect() async throws {}
    func listTools(cursor: String?) async throws -> NativeMCPPage { NativeMCPPage(tools: tools, nextCursor: nil) }
    func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue {
        log.add(name)
        if holding { await withCheckedContinuation { held = $0 } }
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(reply)])])])
    }
    func disconnect() async {}
    func set(_ next: [NativeMCPDiscoveredTool]) { tools = next }
    func answer(_ text: String) { reply = text }
    func hold() { holding = true }
    func release() { holding = false; held?.resume(); held = nil }
    nonisolated func count(_ name: String) -> Int { log.count(name) }
}

@MainActor
enum NativeMCPChangesSelftest {
    static let schema: NativeJSONValue = .object(["type": .string("object"),
                                                  "properties": .object(["title": .object(["type": .string("string"), "maxLength": .number(200)])]),
                                                  "additionalProperties": .bool(false)])
    static let call: [String: NativeJSONValue] = ["title": .string("Fix the gate")]
    static let endpoint = URL(string: "https://fixture.invalid/mcp")!

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NativeToolError.failed(message) }
    }

    static func tool(_ name: String, readOnly: Bool? = nil, destructive: Bool? = nil, idempotent: Bool? = nil, openWorld: Bool? = nil) -> NativeMCPDiscoveredTool {
        NativeMCPDiscoveredTool(name: name, description: "Synthetic " + name, inputSchema: schema,
                                hints: NativeMCPToolHints(readOnly: readOnly, destructive: destructive, idempotent: idempotent, openWorld: openWorld))
    }

    static func connected(_ tools: [NativeMCPDiscoveredTool], reads: Set<String>, acts: Set<String>,
                          scopes: Set<String> = ["focused", "assistant", "worker"]) async throws
        -> (NativeMCPManager, NativeMCPChangesConnection, NativeMCPServerConfiguration) {
        let server = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Synthetic tracker", endpoint: endpoint, readTools: reads, actTools: acts, scopes: scopes)
        let connection = NativeMCPChangesConnection(tools)
        let manager = NativeMCPManager(servers: [server], enabled: Set(tools.map { server.toolID($0.name) }), factory: { _ in connection })
        await manager.connect(server.id)
        try require(manager.servers.first?.connected == true, "The fixture service connects")
        return (manager, connection, server)
    }

    static func definition(_ manager: NativeMCPManager, _ server: NativeMCPServerConfiguration, _ name: String, scope: String = "focused") -> NativeToolDefinition? {
        manager.authority.definitions(scope: scope).first { $0.id == server.toolID(name) }
    }

    static func run() async throws {
        try classification()
        try await settings()
        try await hintsChange()
        try await chat()
        try await background()
        try await readTest()
        try await rewrites()
        try await remembered()
        try await rememberedWithoutSaving()
        try await rememberedWhileSigningIn()
        try await dispatched()
        try await oversized()
        print("NATIVE MCP CHANGES SELFTEST OK")
    }

    static func classification() throws {
        let server = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Table", endpoint: endpoint, readTools: ["reads", "both"], actTools: ["acts", "both"])
        let remembered = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Table", endpoint: endpoint, readTools: ["reads"], asksTools: ["reads", "stray"])
        try require(remembered.asksTools == ["reads"], "A remembered name that is not an approved read is dropped")
        let values: [Bool?] = [nil, true, false]
        for readOnly in values {
            for destructive in values {
                for idempotent in values {
                    for openWorld in values {
                        let hints = NativeMCPToolHints(readOnly: readOnly, destructive: destructive, idempotent: idempotent, openWorld: openWorld)
                        let label = "readOnly \(String(describing: readOnly)) destructive \(String(describing: destructive)) idempotent \(String(describing: idempotent)) openWorld \(String(describing: openWorld))"
                        let careful = readOnly == false || destructive == true
                        try require(server.state(of: "reads", hints: hints) == (careful ? .change : .read), "A read is a change only when the service says so: \(label)")
                        try require(server.state(of: "acts", hints: hints) == .change, "An approved change stays a change: \(label)")
                        try require(server.state(of: "both", hints: hints) == .change, "A name on both lists is a change: \(label)")
                        try require(server.state(of: "none", hints: hints) == .unapproved, "Nothing a service says approves a tool: \(label)")
                        try require(NativeMCPToolState.classify(read: false, act: false, remembered: false, hints: hints) == .unapproved, "An unlisted tool is never callable: \(label)")
                        try require(NativeMCPToolState.classify(read: false, act: false, remembered: true, hints: hints) == .unapproved, "A remembered name alone approves nothing: \(label)")
                        try require(remembered.state(of: "reads", hints: hints) == .change, "A read the service once marked stays a change: \(label)")
                    }
                }
            }
        }
        try require(server.state(of: "reads", hints: NativeMCPToolHints()) == .read, "A service that says nothing changes nothing")
    }

    static func settings() async throws {
        let id = UUID().uuidString.lowercased()
        let plain: [String: Any] = ["id": id, "name": "Tracker", "url": endpoint.absoluteString, "read_tools": ["lookup"]]
        let (old, oldFailure) = NativeMCPServerConfiguration.load(["native_mcp_servers": [plain]])
        try require(oldFailure == nil && old.first?.readTools == ["lookup"] && old.first?.actTools == [], "A row without act_tools loads as before")
        var both = plain
        both["act_tools"] = ["post_update", "lookup"]
        let (loaded, failure) = NativeMCPServerConfiguration.load(["native_mcp_servers": [both]])
        try require(failure == nil && loaded.first?.actTools == ["post_update", "lookup"], "A row with act_tools loads")
        try require(loaded.first?.state(of: "lookup", hints: NativeMCPToolHints()) == .change, "A name on both lists is a change")
        var actOnly = plain
        actOnly.removeValue(forKey: "read_tools")
        actOnly["act_tools"] = ["post_update"]
        try require(NativeMCPServerConfiguration.load(["native_mcp_servers": [actOnly]]).1 == nil, "A row with only changes loads")
        var empty = plain
        empty["read_tools"] = [String]()
        try require(NativeMCPServerConfiguration.load(["native_mcp_servers": [empty]]).1 != nil, "A row with neither list is refused")
        var wrong = plain
        wrong["act_tools"] = "post_update"
        try require(NativeMCPServerConfiguration.load(["native_mcp_servers": [wrong]]).1 != nil, "A row whose changes are not a list is refused")
        var control = plain
        control["act_tools"] = ["bad\u{7}"]
        try require(NativeMCPServerConfiguration.load(["native_mcp_servers": [control]]).1 != nil, "A change name is checked like a read name")
        var full = plain
        full["read_tools"] = (0..<40).map { "read_\($0)" }
        full["act_tools"] = (0..<24).map { "act_\($0)" }
        try require(NativeMCPServerConfiguration.load(["native_mcp_servers": [full]]).1 == nil, "Sixty-four names across both lists load")
        full["act_tools"] = (0..<25).map { "act_\($0)" }
        try require(NativeMCPServerConfiguration.load(["native_mcp_servers": [full]]).1 != nil, "More than sixty-four names across both lists are refused")

        final class Disk { var contents: [String: Any] = [:] }
        let disk = Disk()
        let manager = NativeMCPManager(servers: [])
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents }, nativeMCP: manager,
                                 writeConfiguration: { disk.contents = $0 })
        try config.addNativeMCPServer(both)
        let written = (disk.contents["native_mcp_servers"] as? [[String: Any]])?.first
        try require(written?["act_tools"] as? [String] == ["post_update", "lookup"], "Saving keeps act_tools in the settings file")
        await config.settleNativeMCP()
        try require(manager.servers.first?.configuration.actTools == ["post_update", "lookup"], "The saved row reaches the live configuration")
        let changeID = loaded[0].toolID("post_update")
        config.setNativeTool(changeID, enabled: true)
        var narrowed = both
        narrowed["act_tools"] = ["lookup"]
        try config.updateNativeMCPServer(narrowed)
        try require(!config.nativeSettings.enabledToolIDs.contains(changeID), "Removing a change from the list turns its switch off")
        try require(manager.servers.first?.configuration.actTools == ["lookup"], "An updated change list reaches the live configuration")
    }

    static func hintsChange() async throws {
        let tools = [tool("lookup"), tool("post_update", readOnly: false), tool("secret")]
        let (manager, connection, server) = try await connected(tools, reads: ["lookup"], acts: ["post_update"])
        let authority = manager.authority
        guard let read = definition(manager, server, "lookup"), let change = definition(manager, server, "post_update") else {
            throw NativeToolError.failed("The approved tools are offered")
        }
        try require(read.effect == .read && read.action == nil && read.confirmation == .none, "An approved read stays a plain read")
        try require(read.description.hasPrefix("Read from Synthetic tracker at fixture.invalid. Service-provided description (untrusted): "), "A read keeps its description")
        try require(change.effect == .write && change.action == .serviceChanges && change.confirmation == .none && change.verbs.isEmpty
                    && !change.demandsConfirmation && change.ruleSubjects == nil,
                    "An approved change is a governed write the rules decide")
        try require(change.description == "Make a change through Synthetic tracker at fixture.invalid. Service-provided description (untrusted): Synthetic post_update",
                    "A change says what it does")
        try require(definition(manager, server, "secret") == nil, "An unapproved tool is not offered")
        let assistant = try NativeMCPAuthoritySelftest.scope()
        let catalog = try await authority.catalog(scope: assistant)
        try require(catalog.map(\.name) == [server.toolID("lookup")], "The runtime catalogue offers only reads")
        do {
            _ = try await authority.call(scope: assistant, id: UUID().uuidString, name: server.toolID("post_update"), arguments: .object(call), expectedRevision: try await authority.revision(scope: assistant))
            throw NativeToolError.failed("The runtime ran a change")
        } catch NativeToolError.unavailable {}
        try require(connection.count("post_update") == 0, "A change never runs outside the rules")

        let revision = try await authority.revision(scope: assistant)
        await connection.set([tool("lookup", destructive: true), tool("post_update", readOnly: true), tool("secret", readOnly: true)])
        await manager.disconnect(server.id)
        await manager.connect(server.id)
        try require(try await authority.revision(scope: assistant) != revision, "A new listing changes the catalogue revision")
        try require(!read.isAvailable(), "A read made before the service said it changes things is no longer available")
        var stale: String?
        do { _ = try await read.execute(call) } catch { stale = error.localizedDescription }
        try require(stale != nil && (connection.count("lookup")) == 0, "A read made before the listing changed never runs as a read")
        guard let relisted = definition(manager, server, "lookup"), let kept = definition(manager, server, "post_update") else {
            throw NativeToolError.failed("Both approved tools stay offered")
        }
        try require(relisted.effect == .write && relisted.action == .serviceChanges, "A read the service now calls destructive becomes a change")
        try require(ChatStore.ruled(relisted, rules: NativeRuleSource(), store: nil, conversationID: "c", requestText: "").confirmationFor?(call) == true,
                    "A read that became a change asks first")
        try require(kept.effect == .write && kept.action == .serviceChanges, "A change the service now calls read-only stays a change")
        let secret = manager.servers.first?.tools.first { $0.remoteName == "secret" }
        try require(definition(manager, server, "secret") == nil && secret?.callable == false
                    && secret?.reason == "This action has not been approved as a read tool.", "An unapproved tool the service calls read-only stays off")
        try require(manager.servers.first?.tools.first { $0.remoteName == "lookup" }?.asksBecauseOfService == true, "The page can tell the service caused the change")
        try require(try await authority.catalog(scope: assistant).isEmpty, "The runtime catalogue drops a read that became a change")

        let (moving, _, movingServer) = try await connected([tool("lookup")], reads: ["lookup"], acts: [])
        guard let before = definition(moving, movingServer, "lookup") else { throw NativeToolError.failed("The read is offered") }
        let moved = try NativeMCPServerConfiguration(id: movingServer.id, name: movingServer.name, endpoint: movingServer.endpoint,
                                                     readTools: ["lookup"], actTools: ["lookup"], scopes: movingServer.scopes)
        await moving.retireConfiguration(moving.applyConfigurationSynchronously([moved]))
        try require(!before.isAvailable(), "Approving a read as a change ends the read made before")
    }

    static func source(_ choice: NativeRuleChoice = .ask, records: [NativeRuleRecord] = []) -> NativeRuleSource {
        let source = NativeRuleSource()
        var rules = NativeRules.defaults
        rules.set(choice, for: .serviceChanges)
        source.setGlobal(rules)
        source.setRecords(records)
        return source
    }

    static func run(_ definition: NativeToolDefinition, confirmed: Bool) async -> String? {
        do {
            _ = try await NativeToolCallContext.$confirmed.withValue(confirmed) { try await definition.execute(call) }
            return nil
        } catch { return error.localizedDescription }
    }

    static func chat() async throws {
        let (manager, connection, server) = try await connected([tool("lookup"), tool("post_update")], reads: ["lookup"], acts: ["post_update"])
        guard let change = definition(manager, server, "post_update"), let read = definition(manager, server, "lookup") else {
            throw NativeToolError.failed("The approved tools are offered")
        }
        let chat = "chat-service-changes"
        let request = "Post the update"
        func ruled(_ rules: NativeRuleSource, typed: NativeTypedWords = .none, uses: NativeInstructionUses? = nil) -> NativeToolDefinition {
            ChatStore.ruled(change, rules: rules, store: nil, conversationID: chat, requestText: request, typed: typed, uses: uses)
        }
        try require(ChatStore.followsRules(change), "A change follows the rules in chat")

        let asking = ruled(source())
        try require(asking.governed && asking.confirmationFor?(call) == true, "A change asks first by default")
        try require(await run(asking, confirmed: false) == NativeRuleResolver.changedMessage && (connection.count("post_update")) == 0,
                    "A change never runs without its card")
        try require(await run(asking, confirmed: true) == nil && (connection.count("post_update")) == 1, "A change runs once after its card")

        let handing = ruled(source(.handOff))
        try require(handing.confirmationFor?(call) == false, "A change left to the person shows no card")
        let refusal = await run(handing, confirmed: true)
        try require(refusal?.contains(NativeActionClass.serviceChanges.title) == true && (connection.count("post_update")) == 1,
                    "A change left to the person is refused with the reason: \(refusal ?? "ran")")

        let allow = NativeRuleRecord(action: .serviceChanges, toolID: change.id, effect: .allow, statement: "Always post updates")
        let allowing = ruled(source(records: [allow]))
        let allowedRun = await run(allowing, confirmed: false)
        try require(allowing.confirmationFor?(call) == false && allowedRun == nil && connection.count("post_update") == 2,
                    "A saved allow for the tool runs it with no card")
        let otherAllow = NativeRuleRecord(action: .serviceChanges, toolID: server.toolID("lookup"), effect: .allow, statement: "Always look up")
        try require(ruled(source(records: [otherAllow])).confirmationFor?(call) == true, "A saved allow for another tool does not cover this one")

        let never = NativeRuleRecord(action: nil, toolID: change.id, effect: .forbid, statement: "Never post updates")
        let barred = ruled(source(.act, records: [never]))
        let barredRun = await run(barred, confirmed: true)
        try require(barred.confirmationFor?(call) == false && barredRun != nil && connection.count("post_update") == 2,
                    "A saved never refuses the tool")

        let typed = ruled(source(), typed: NativeTypedWords(typed: request), uses: NativeInstructionUses())
        try require(typed.confirmationFor?(call) == true && typed.instructionFor?(call) == nil, "A typed instruction does not run a change without a card")
        try require(await run(typed, confirmed: false) == NativeRuleResolver.changedMessage && (connection.count("post_update")) == 2,
                    "A typed instruction never runs a change on its own")

        let readRuled = ChatStore.ruled(read, rules: source(.handOff), store: nil, conversationID: chat, requestText: request)
        try require(!readRuled.governed && readRuled.confirmationFor == nil, "A read is unchanged by the rules")
        try require(await run(readRuled, confirmed: false) == nil && (connection.count("lookup")) == 1, "A read keeps running with no card")
    }

    static func background() async throws {
        func harness(_ choice: NativeRuleChoice, name: String = "post_update") async throws
            -> (NativeCompanionHarness, NativeMCPChangesConnection, String) {
            let (manager, connection, server) = try await connected([tool("lookup"), tool("post_update")], reads: ["lookup"], acts: ["post_update"])
            let id = server.toolID(name)
            var harness = try NativeCompanionHarness(rules: [.serviceChanges: choice]) { messages in
                NativeCompanionScriptedModel.toolResults(messages).isEmpty
                    ? NativeCompanionScriptedModel.call(id, "{\"title\":\"Fix the gate\"}") : NativeCompanionScriptedModel.text("Finished the update.")
            }
            let tools = manager.authority.definitions(scope: "worker")
            let thread = harness.thread
            harness.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: thread.current, tools: tools) }
            return (harness, connection, id)
        }

        let (asking, askingConnection, _) = try await harness(.ask)
        let askID = try asking.create("Post the update")
        let paused = try await asking.runUntilSettled()
        try require(paused.state == .needsDecision && (askingConnection.count("post_update")) == 0, "Background work asks before a change")
        try asking.reply(paused, "approve", digest: try asking.decision(paused)["digest"] as? String)
        let approved = try await asking.runUntilSettled()
        try require(approved.state == .completed && (askingConnection.count("post_update")) == 1
                    && (try asking.effects(askID)).map(\.state) == [.completed], "An approved change runs once and is recorded")

        let (handing, handingConnection, _) = try await harness(.handOff)
        let handID = try handing.create("Post the update")
        let handed = try await handing.runUntilSettled()
        let handedResult = try JSONDecoder().decode(NativeResearchTaskResult.self, from: handed.result ?? Data())
        try require(handed.state == .completed && (handingConnection.count("post_update")) == 0 && (try handing.effects(handID)).isEmpty
                    && handedResult.why?.action == .serviceChanges, "Background work leaves a change to the person and says why")

        var (allowing, allowingConnection, allowedID) = try await harness(.ask)
        try allowing.saveRecords([NativeRuleRecord(action: .serviceChanges, toolID: allowedID, effect: .allow, statement: "Always post updates")])
        let allowRun = try allowing.create("Post the update")
        let allowed = try await allowing.runUntilSettled()
        try require(allowed.state == .completed && (allowingConnection.count("post_update")) == 1
                    && (try allowing.effects(allowRun)).map(\.state) == [.completed], "A saved allow runs the change and the ledger keeps it")

        let (barring, barringConnection, barredID) = try await harness(.act)
        try barring.setRecords([NativeRuleRecord(action: nil, toolID: barredID, effect: .forbid, statement: "Never post updates")])
        _ = try barring.create("Post the update")
        let barred = try await barring.runUntilSettled()
        try require(barred.state == .completed && (barringConnection.count("post_update")) == 0, "A saved never stops the change")

        let (reading, readingConnection, _) = try await harness(.handOff, name: "lookup")
        let readRun = try reading.create("Look up the gate")
        let read = try await reading.runUntilSettled()
        try require(read.state == .completed && (readingConnection.count("lookup")) == 1 && (try reading.effects(readRun)).isEmpty,
                    "A read keeps running in background work with no card")
    }

    static func readTest() async throws {
        let (manager, connection, server) = try await connected([tool("lookup"), tool("post_update")], reads: ["lookup"], acts: ["post_update"])
        guard let change = manager.servers.first?.tools.first(where: { $0.remoteName == "post_update" }),
              let read = manager.servers.first?.tools.first(where: { $0.remoteName == "lookup" }) else { throw NativeToolError.unavailable }
        try require(NativeMCPReadTestController(manager: manager, record: change) == nil, "Try a read refuses a change")
        guard let controller = NativeMCPReadTestController(manager: manager, record: read) else { throw NativeToolError.failed("Try a read opens for a read") }
        controller.updateInput("{\"title\":\"Gate\"}")
        try require(controller.canRun, "The read is ready to run")
        await connection.set([tool("lookup", readOnly: false), tool("post_update")])
        await manager.disconnect(server.id)
        await manager.connect(server.id)
        controller.run()
        try require(!controller.running && !controller.canRun && (connection.count("lookup")) == 0, "Try a read refuses a read that became a change when it runs")
        guard let became = manager.servers.first?.tools.first(where: { $0.remoteName == "lookup" }) else { throw NativeToolError.unavailable }
        try require(became.state == .change && NativeMCPReadTestController(manager: manager, record: became) == nil,
                    "Try a read will not open a read that became a change")
        controller.close()
    }

    final class Disk { var contents: [String: Any] = [:]; var fails = false }

    static func store(_ disk: Disk, _ manager: NativeMCPManager) -> ConfigStore {
        ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents }, nativeMCP: manager,
                    writeConfiguration: { if disk.fails { throw NativeToolError.unavailable }; disk.contents = $0 })
    }

    static func savedRow(_ disk: Disk) -> [String: Any]? { (disk.contents["native_mcp_servers"] as? [[String: Any]])?.first }

    static func rewrites() async throws {
        let id = UUID().uuidString.lowercased()
        let row: [String: Any] = ["id": id, "name": "Tracker", "url": endpoint.absoluteString, "read_tools": ["lookup", "search"], "asks_tools": ["lookup", "stray"]]
        let (loaded, failure) = NativeMCPServerConfiguration.load(["native_mcp_servers": [row]])
        try require(failure == nil && loaded.first?.asksTools == ["lookup"], "A row with asks_tools loads and drops names that are not approved reads")
        try require(loaded.first?.state(of: "lookup", hints: NativeMCPToolHints(readOnly: true)) == .change, "A loaded remembered read is a change")
        var wrong = row
        wrong["asks_tools"] = "lookup"
        try require(NativeMCPServerConfiguration.load(["native_mcp_servers": [wrong]]).1 != nil, "A row whose asks_tools is not a list is refused")
        wrong["asks_tools"] = ["bad\u{7}"]
        try require(NativeMCPServerConfiguration.load(["native_mcp_servers": [wrong]]).1 != nil, "A remembered name is checked like a read name")
        wrong["asks_tools"] = ["lookup"] + (0..<64).map { "extra_\($0)" }
        try require(NativeMCPServerConfiguration.load(["native_mcp_servers": [wrong]]).1 != nil, "A remembered list cannot pass the name limit")

        let disk = Disk()
        let manager = NativeMCPManager(servers: [])
        let config = store(disk, manager)
        func asks() -> [String]? { savedRow(disk)?["asks_tools"] as? [String] }
        func live() -> Set<String>? { manager.servers.first { $0.id == id }?.configuration.asksTools }
        try config.addNativeMCPServer(row)
        await config.settleNativeMCP()
        try require(asks() == ["lookup"] && live() == ["lookup"], "Adding a row keeps asks_tools")
        var renamed = config.nativeMCPServerRows[0]
        renamed["name"] = "Tracker two"
        try config.updateNativeMCPServer(renamed)
        try require(asks() == ["lookup"] && live() == ["lookup"], "Updating a row keeps asks_tools")
        let managed = IntegrationsManageSheet.row(config.nativeMCPServerRows[0], id: id, name: "Tracker two", endpoint: endpoint.absoluteString,
                                                  reads: "lookup\nsearch", acts: "", scopes: ["focused"], seconds: 20, authentication: .none)
        try config.updateNativeMCPServer(managed)
        try require(asks() == ["lookup"] && live() == ["lookup"], "Saving the Manage sheet keeps asks_tools")
        let other = UUID().uuidString.lowercased()
        try config.addNativeMCPServer(["id": other, "name": "Other", "url": "https://other.invalid/mcp", "read_tools": ["lookup"]])
        try config.removeNativeMCPServer(id: other)
        try config.replaceNativeMCPServers(config.nativeMCPServerRows)
        await config.settleNativeMCP()
        try require(asks() == ["lookup"] && live() == ["lookup"], "Adding, removing and replacing rows keeps asks_tools")
        var dropped = config.nativeMCPServerRows[0]
        dropped.removeValue(forKey: "asks_tools")
        await manager.reconcileConfiguration(NativeMCPServerConfiguration.load(["native_mcp_servers": [dropped]]).0)
        try require(live() == ["lookup"], "A live configuration change that leaves it out does not forget it")

        let removed = IntegrationsManageSheet.row(config.nativeMCPServerRows[0], id: id, name: "Tracker two", endpoint: endpoint.absoluteString,
                                                  reads: "search", acts: "", scopes: ["focused"], seconds: 20, authentication: .none)
        try config.updateNativeMCPServer(removed)
        await config.settleNativeMCP()
        try require(asks() == nil && live() == [], "Removing the tool from the reads clears it")
        let readded = IntegrationsManageSheet.row(config.nativeMCPServerRows[0], id: id, name: "Tracker two", endpoint: endpoint.absoluteString,
                                                  reads: "search\nlookup", acts: "", scopes: ["focused"], seconds: 20, authentication: .none)
        try config.updateNativeMCPServer(readded)
        try require(config.rememberNativeMCPAsks(id, ["lookup", "missing"]) && asks() == ["lookup"] && live() == ["lookup"], "Remembering saves only approved reads")
        let moved = IntegrationsManageSheet.row(config.nativeMCPServerRows[0], id: id, name: "Tracker two", endpoint: endpoint.absoluteString,
                                                reads: "search\nlookup", acts: "lookup", scopes: ["focused"], seconds: 20, authentication: .none)
        try config.updateNativeMCPServer(moved)
        await config.settleNativeMCP()
        try require(asks() == nil && live() == [] && manager.servers.first?.configuration.actTools == ["lookup"], "Moving the tool to changes clears it")
    }

    static func service(_ disk: Disk, tools: [NativeMCPDiscoveredTool]) async throws -> (NativeMCPManager, ConfigStore, NativeMCPChangesConnection, String) {
        let id = UUID().uuidString.lowercased()
        let connection = NativeMCPChangesConnection(tools)
        let manager = NativeMCPManager(servers: [], factory: { _ in connection })
        let config = store(disk, manager)
        try config.addNativeMCPServer(["id": id, "name": "Synthetic tracker", "url": endpoint.absoluteString, "read_tools": ["lookup"],
                                       "scopes": ["focused", "assistant", "worker"]])
        await config.settleNativeMCP()
        guard let server = manager.servers.first?.configuration else { throw NativeToolError.unavailable }
        config.setNativeTool(server.toolID("lookup"), enabled: true)
        return (manager, config, connection, id)
    }

    static func stillAsks(_ manager: NativeMCPManager, _ connection: NativeMCPChangesConnection, _ label: String) async throws {
        guard let state = manager.servers.first, state.connected, let server = Optional(state.configuration),
              let record = state.tools.first(where: { $0.remoteName == "lookup" }) else { throw NativeToolError.failed("The service reconnects: \(label)") }
        try require(record.state == .change && record.callable && record.asksBecauseOfService, "A once-marked read stays a change: \(label)")
        guard let change = definition(manager, server, "lookup") else { throw NativeToolError.failed("The change is offered: \(label)") }
        try require(change.effect == .write && change.action == .serviceChanges, "A once-marked read is offered only as a change: \(label)")
        let assistant = try NativeMCPAuthoritySelftest.scope()
        try require(try await manager.authority.catalog(scope: assistant).isEmpty, "The runtime catalogue leaves out a once-marked read: \(label)")
        do {
            _ = try await manager.authority.call(scope: assistant, id: UUID().uuidString, name: record.id, arguments: .object(call), expectedRevision: try await manager.authority.revision(scope: assistant))
            throw NativeToolError.failed("The runtime ran a once-marked read: \(label)")
        } catch NativeToolError.unavailable {}
        try require(NativeMCPReadTestController(manager: manager, record: record) == nil, "Try a read will not open a once-marked read: \(label)")
        let before = connection.count("lookup")
        let never = NativeRuleRecord(action: nil, toolID: record.id, effect: .forbid, statement: "Never look up")
        let barred = ChatStore.ruled(change, rules: source(.act, records: [never]), store: nil, conversationID: "c", requestText: "Look it up")
        try require(await run(barred, confirmed: true) != nil && connection.count("lookup") == before, "A saved never still refuses a once-marked read: \(label)")
    }

    static let relistings: [(String, [NativeMCPDiscoveredTool])] = [
        ("marking dropped", [tool("lookup")]), ("read-only", [tool("lookup", readOnly: true)]),
        ("not destructive", [tool("lookup", destructive: false)]), ("read-only and not destructive", [tool("lookup", readOnly: true, destructive: false)])]

    static func remembered() async throws {
        let disk = Disk()
        let (manager, config, connection, id) = try await service(disk, tools: [tool("lookup", readOnly: false)])
        try require(savedRow(disk)?["asks_tools"] == nil, "Nothing is remembered before the service says anything")
        await manager.connect(id)
        try require(savedRow(disk)?["asks_tools"] as? [String] == ["lookup"], "The marking is saved as soon as the service says so")
        try await stillAsks(manager, connection, "first listing")
        for (label, listing) in relistings {
            await connection.set(listing)
            await manager.disconnect(id)
            await manager.connect(id)
            try await stillAsks(manager, connection, label)
        }
        let reloaded = NativeMCPServerConfiguration.load(disk.contents).0
        try require(reloaded.first?.state(of: "lookup", hints: NativeMCPToolHints(readOnly: true, destructive: false)) == .change, "A reloaded configuration still treats it as a change")
        let fresh = NativeMCPChangesConnection([tool("lookup", readOnly: true)])
        let restarted = NativeMCPManager(servers: reloaded, enabled: Set(reloaded.map { $0.toolID("lookup") }), factory: { _ in fresh })
        await restarted.connect(id)
        try await stillAsks(restarted, fresh, "after a restart")
        withExtendedLifetime(config) {}
    }

    static func rememberedWithoutSaving() async throws {
        let disk = Disk()
        let (manager, config, connection, id) = try await service(disk, tools: [tool("lookup", destructive: true)])
        disk.fails = true
        await manager.connect(id)
        try require(savedRow(disk)?["asks_tools"] == nil, "A failed save leaves the file alone")
        try await stillAsks(manager, connection, "unsaved first listing")
        for (label, listing) in relistings {
            await connection.set(listing)
            await manager.disconnect(id)
            await manager.connect(id)
            try await stillAsks(manager, connection, "unsaved " + label)
        }
        disk.fails = false
        await manager.disconnect(id)
        await manager.connect(id)
        try require((savedRow(disk)?["asks_tools"] as? [String]) == ["lookup"], "A save that failed is tried again on the next connection, even after the service stopped marking the tool")
        withExtendedLifetime(config) {}
    }

    static func rememberedWhileSigningIn() async throws {
        let resource = URL(string: "https://resource-fixture.invalid/mcp")!
        let server = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Synthetic tracker", endpoint: resource, readTools: ["lookup"],
                                                      scopes: ["focused", "assistant", "worker"], authentication: .oauth,
                                                      oauth: NativeMCPOAuthUIFixtureTransport.configuration(resource: resource))
        let browser = NativeMCPOAuthFixtureBrowser(), transport = NativeMCPOAuthUIFixtureTransport(resource: resource)
        let connection = NativeMCPChangesConnection([tool("lookup", readOnly: false)])
        let manager = NativeMCPManager(servers: [server], enabled: [server.toolID("lookup")], authenticatedFactory: { config, lease in
            guard lease?.isValid(serverID: config.id, endpoint: config.endpoint) == true else { throw NativeMCPTransportError.authenticationRequired }
            return connection
        }, oauthTransport: transport, oauthBrowserFactory: { browser })
        final class Saved: @unchecked Sendable { var names: Set<String> = [] }
        let saved = Saved()
        manager.authority.access.keepMarked { _, names in
            await MainActor.run {
                saved.names.formUnion(names)
                manager.applyConfigurationSynchronously([server.asking(saved.names)])
            }
            return true
        }
        guard let review = manager.beginOAuthReview(server.id) else { throw NativeToolError.failed("The sign-in review opens") }
        let signing = Task { await manager.signIn(server.id, reviewID: review.id) }
        for _ in 0..<400 where !browser.waiting { try await Task.sleep(nanoseconds: 5_000_000) }
        browser.complete()
        await signing.value
        try require(saved.names == ["lookup"], "Signing in saves the marking")
        try await stillAsks(manager, connection, "signed in")
        await manager.refreshOAuth(server.id)
        try require(manager.servers.first?.connected == true, "Refreshing sign-in keeps a service whose marking was saved")
        await connection.set([tool("lookup", readOnly: true)])
        await manager.refreshOAuth(server.id)
        try await stillAsks(manager, connection, "refreshed sign-in")
    }

    static func worker(_ manager: NativeMCPManager, _ id: String) throws -> NativeCompanionHarness {
        var harness = try NativeCompanionHarness(rules: [.serviceChanges: .ask]) { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call(id, "{\"title\":\"Fix the gate\"}") : NativeCompanionScriptedModel.text("Finished the update.")
        }
        try harness.saveRecords([NativeRuleRecord(action: .serviceChanges, toolID: id, effect: .allow, statement: "Always post updates")])
        let tools = manager.authority.definitions(scope: "worker")
        let thread = harness.thread
        harness.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: thread.current, tools: tools) }
        return harness
    }

    static func asksWhetherItHappened(_ harness: NativeCompanionHarness, _ task: String, _ settled: NativeTaskRecord, _ label: String) throws {
        let effects = try harness.effects(task)
        try require(effects.map(\.state) == [.uncertain], "The ledger keeps an unsure change as unsure: \(label) \(effects.map(\.state))")
        if case .object(let fields)? = effects.first?.receipt { try require(fields["observed"] != .string("absent"), "The ledger never says absent without evidence: \(label)") }
        try require(settled.state == .needsDecision && (try harness.decision(settled)["choices"] as? [String]) == ["it_happened", "it_did_not", "stop"],
                    "The task asks whether the change happened: \(label)")
    }

    static func dispatched() async throws {
        for invalidation in ["switched off", "disconnected"] {
            let (manager, connection, server) = try await connected([tool("lookup"), tool("post_update")], reads: ["lookup"], acts: ["post_update"])
            let harness = try worker(manager, server.toolID("post_update"))
            await connection.hold()
            let task = try harness.create("Post the update")
            let running = Task { try await harness.runUntilSettled() }
            for _ in 0..<500 where connection.count("post_update") == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            try require(connection.count("post_update") == 1, "The change reached the service: \(invalidation)")
            if invalidation == "switched off" {
                manager.setEnabled([])
                await manager.authority.permissionsChanged()
            } else {
                await manager.disconnect(server.id)
            }
            await connection.release()
            let settled = try await running.value
            try asksWhetherItHappened(harness, task, settled, invalidation)
        }
        let (manager, connection, server) = try await connected([tool("lookup"), tool("post_update")], reads: ["lookup"], acts: ["post_update"])
        guard let change = definition(manager, server, "post_update") else { throw NativeToolError.failed("The change is offered") }
        manager.setEnabled([])
        await manager.authority.permissionsChanged()
        var refused: Error?
        do { _ = try await change.execute(call) } catch { refused = error }
        try require(refused as? NativeToolError == .unavailable && NativeCompanionWorker.definite(refused!) && connection.count("post_update") == 0,
                    "A change refused before it is sent is still definitely not done")
    }

    static func oversized() async throws {
        let (manager, connection, server) = try await connected([tool("lookup"), tool("post_update")], reads: ["lookup"], acts: ["post_update"])
        await connection.answer(String(repeating: "x", count: 6000))
        guard let change = definition(manager, server, "post_update"), let read = definition(manager, server, "lookup") else {
            throw NativeToolError.failed("The approved tools are offered")
        }
        var changeError: Error?
        do { _ = try await change.execute(call) } catch { changeError = error }
        try require(changeError as? NativeToolError == .failed("The service replied, but its reply is too large to show. The change may have been made, so check before trying it again."),
                    "An oversized reply to a change says it may have happened: \(changeError.map { $0.localizedDescription } ?? "none")")
        try require(changeError.map { !NativeCompanionWorker.definite($0) } == true, "An oversized reply to a change is unsure")
        var readError: Error?
        do { _ = try await read.execute(call) } catch { readError = error }
        try require(readError as? NativeToolError == .failed("The service result is too large. Ask for a narrower read."), "An oversized read asks for a narrower read")
        try require(manager.servers.first?.connected == true, "An oversized reply keeps the service connected")
        let harness = try worker(manager, server.toolID("post_update"))
        let task = try harness.create("Post the update")
        try asksWhetherItHappened(harness, task, try await harness.runUntilSettled(), "oversized")
    }
}
