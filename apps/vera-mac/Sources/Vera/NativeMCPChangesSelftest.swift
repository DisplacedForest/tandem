import Foundation

final class NativeMCPChangesLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.withLock { names.append(name) } }
    func count(_ name: String) -> Int { lock.withLock { names.filter { $0 == name }.count } }
}

actor NativeMCPChangesConnection: NativeMCPConnection {
    private var tools: [NativeMCPDiscoveredTool]
    nonisolated let log = NativeMCPChangesLog()
    init(_ tools: [NativeMCPDiscoveredTool]) { self.tools = tools }
    func connect() async throws {}
    func listTools(cursor: String?) async throws -> NativeMCPPage { NativeMCPPage(tools: tools, nextCursor: nil) }
    func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue {
        log.add(name)
        return .object(["content": .array([.object(["type": .string("text"), "text": .string("ok")])])])
    }
    func disconnect() async {}
    func set(_ next: [NativeMCPDiscoveredTool]) { tools = next }
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
        print("NATIVE MCP CHANGES SELFTEST OK")
    }

    static func classification() throws {
        let server = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Table", endpoint: endpoint, readTools: ["reads", "both"], actTools: ["acts", "both"])
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
                        try require(NativeMCPToolState.classify(read: false, act: false, hints: hints) == .unapproved, "An unlisted tool is never callable: \(label)")
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
}
