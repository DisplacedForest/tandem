import Foundation
import GRDB

@MainActor
enum NativeTurnAuthorityFixture {
    nonisolated static let first = "Please start background research using public NASA sources about lunar water ice. Return three findings with links."
    nonisolated static let second = "What is 7 plus 5? Answer with just the number. Do not use any tools."

    static func run() async throws {
        let require = NativeTaskFixture.require
        for request in [first, "Research the fictional moon Luma in the background.", "Separately, please investigate Mars ice.",
                        "Can you start a new background research task about Europa?"] {
            try require(NativeTurnToolAuthority(request).allowsResearch, "Explicit current research request must be authorized")
        }
        for request in [second, "What did I ask you to do?", "Add links.", "Research is interesting.",
                        "Earlier I said \"Please start background research about NASA\". What is 7 plus 5? Do not use tools.",
                        "Earlier I said please research NASA. What did I ask?",
                        "The sentence please research NASA is an example.", "What does 'research NASA' mean?", "Explain ‘Please research NASA’.", "Explain this:\n> Please research NASA", "Summarize `research NASA`.",
                        "Please do not research NASA.", "Research NASA. Do not start new research."] {
            try require(!NativeTurnToolAuthority(request).allowsResearch, "Context and prohibitions cannot authorize research")
        }
        for request in ["Don't use any tools.", "Don’t use tools.", "You must not call external tools.", "Answer without calling tools."] {
            try require(!NativeTurnToolAuthority(request).allowsTools, "Explicit no-tools variants must be enforced")
        }
        try require(NativeTurnToolAuthority(second).filter(["apple-reminders", NativeWebTools.researchToolID]).isEmpty,
                    "No-tools applies to every tool family")
        try await concurrent()
        try await dispatchDenial()
        try durableEnrollment()
        print("CURRENT TURN AUTHORITY OK (concurrent context, denied stale request, one enrollment, identifier-free receipt)")
    }

    static func concurrent() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let gate = NativeSessionGate()
        let transport = NativeTurnAuthorityTransport(gate: gate)
        let requests = NativeTaskFixtureRequests()
        let client = NativeTaskClient { method, url, body, _ in
            guard method == "POST", url.lastPathComponent == "tasks", let body else { throw NativeTaskHTTPError.invalidResponse }
            await requests.append(body)
            let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            return (try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "worker_type": "research",
                "payload": request["payload"]!, "state": "running", "checkpoint": [:], "cancel_requested": false,
                "generation": 1, "updated_at": 1.0]), 201)
        }
        let store = ChatStore(veraAPI: VeraAPIClient(base: URL(string: "https://engine.test")!),
            nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
            nativeEnabledToolIDs: [NativeWebTools.researchToolID], nativeToolRegistry: NativeToolRegistry(definitions: []),
            nativeTaskClient: client, artifactPersistenceEnabled: false)
        store.newConversation()
        try require(try NativeSessionFixture.acceptLegacyContinuous(first, store: store), "First request accepted")
        let firstReply = store.selected!.messages.last!.id
        try await NativeSessionFixture.eventually("First handoff must be saved while acknowledgment is still running") {
            (try? repository.taskReferences(conversationID: nil).count) == 1 && transport.firstWaiting
        }
        try require(try NativeSessionFixture.acceptLegacyContinuous(second, store: store), "Second request accepted concurrently")
        let secondReply = store.selected!.messages.last!.id
        try await NativeSessionFixture.eventually("Arithmetic answer must complete while first acknowledgment waits") {
            store.selected?.messages.first(where: { $0.id == secondReply })?.state == .complete
        }
        let secondMessage = store.selected!.messages.first { $0.id == secondReply }!
        try require(secondMessage.text == "12" && secondMessage.toolActivities.first?.state == .failed,
                    "Unauthorized task request cannot replace the arithmetic answer")
        try require(store.selected!.messages.first { $0.id == firstReply }?.state == .streaming,
                    "The earlier request remains independent")
        let bodies = await requests.bodies
        let references = try repository.taskReferences(conversationID: nil)
        try require(bodies.count == 1 && references.count == 1, "A later no-tools turn must never reenroll previous research")
        let secondHistories = transport.records.filter { $0.messages.last(where: { $0.role == "user" })?.content == second }
        try require(!secondHistories.isEmpty && secondHistories.allSatisfy { $0.tools.isEmpty }, "No-tools suppresses every advertised schema")
        try require(secondHistories[0].messages.filter { $0.role == "user" }.count == 1
            && secondHistories[0].messages.contains { $0.role == "assistant" && $0.content.contains("Read-only context") && $0.content.contains("NASA") },
                    "Pending research remains visible as quoted context, never another user instruction")
        let toolResults = transport.records.flatMap(\.messages).filter { $0.role == "tool" }.map(\.content)
        try require(toolResults.allSatisfy { !$0.contains("task_reference") && !$0.contains(references[0].id.uuidString) },
                    "Internal identifiers never enter model-facing task receipts")
        try require(try NativeSessionFixture.acceptLegacyContinuous("What did I ask you to research?", store: store), "Context question accepted")
        try await NativeSessionFixture.eventually("Pending context supports recall without reenrollment") {
            store.selected?.messages.last?.text == "You asked for NASA sources about lunar water ice."
        }
        try require(try repository.taskReferences(conversationID: nil).count == 1, "Recall does not authorize new work")
        try require(try NativeSessionFixture.acceptLegacyContinuous("Separately, please research Mars ice using public sources.", store: store), "Independent research request accepted")
        try await NativeSessionFixture.eventually("A newly authorized independent research request remains possible") {
            (try? repository.taskReferences(conversationID: nil).count) == 2
        }
        await gate.release()
        try await NativeSessionFixture.eventually("All fixture turns drain") { store.turnExecutions.isEmpty }
        store.conversationTurnLoop?.cancel()
    }

    static func dispatchDenial() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let store = ChatStore(veraAPI: VeraAPIClient(base: URL(string: "https://engine.test")!),
            nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(), repository: repository,
            nativeEnabledToolIDs: [NativeWebTools.researchToolID], nativeToolRegistry: NativeToolRegistry(definitions: []),
            artifactPersistenceEnabled: false)
        store.newConversation()
        store.suspendsTurnScheduling = true
        store.sendText(second)
        let accepted = try repository.conversationTurns()[0]
        try await repository.database.write { db in
            try db.execute(sql: "UPDATE native_conversation_turns SET record_json=json_set(record_json, '$.enabledToolIDs', json(?)) WHERE id=?",
                           arguments: ["[\"deep-research\"]", accepted.id.uuidString])
        }
        let turn = try repository.claimTurn(accepted.id, attempt: UUID())!
        store.turnExecutions[turn.id] = NativeTurnExecution(turn)
        let activity = NativeToolActivity(id: "stale-request", toolID: NativeTaskTools.toolID, name: NativeTaskTools.toolName,
            title: "Start background research", round: 1, request: "{}", result: nil, state: .pending, confirmationRequired: false)
        let current = await store.turnCurrency(turn)
        let dispatched = await store.prepareTurnDispatch(activity, turn: turn)
        try NativeTaskFixture.require(current == .current && !dispatched,
                                      "Current request restrictions override legacy captured permissions before the dispatch marker")
        let saved = try repository.messages(conversationID: store.selectedID!)
        try NativeTaskFixture.require(saved.last?.toolActivities.isEmpty == true && repository.taskReferences(conversationID: nil).isEmpty,
                                      "Denied tools cannot persist effect markers or enroll tasks")
        store.turnExecutions = [:]
        store.conversationTurnLoop?.cancel()
    }

    static func durableEnrollment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("chat.sqlite")
        let repository = try LocalChatRepository(url: database)
        let origin = try NativeTaskFixture.origin(repository)
        let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test")!)
        let original = try NativeResearchTaskRequest(objective: "Research lunar ice", deliverables: ["Three linked findings"])
        let first = try repository.prepareTaskReference(origin: origin, engine: engine, request: original, profile: nil)
        let reopened = try LocalChatRepository(url: database)
        let paraphrase = try NativeResearchTaskRequest(objective: "Investigate ice near the lunar south pole", deliverables: ["Three findings with sources"])
        let replay = try reopened.prepareTaskReference(origin: origin, engine: engine, request: paraphrase, profile: nil)
        try NativeTaskFixture.require(first == replay && first.body == replay.body && reopened.taskReferences(conversationID: nil).count == 1,
                                      "Model paraphrases after restart reuse the original immutable enrollment")
        do {
            _ = try reopened.prepareTaskReference(origin: origin,
                engine: NativeTaskEngineIdentity(URL(string: "https://other-engine.test")!), request: paraphrase, profile: nil)
            throw NativeTaskFixture.Failure.assertion("An enrollment cannot retarget another engine")
        } catch NativeTaskError.engineChanged {}
    }
}

final class NativeTurnAuthorityTransport: NativeChatTransport, @unchecked Sendable {
    struct Record: Sendable { let messages: [NativeChatMessage]; let tools: [NativeToolSchema] }
    private let lock = NSLock()
    private var captured: [Record] = []
    private var waiting = false
    let gate: NativeSessionGate
    init(gate: NativeSessionGate) { self.gate = gate }
    var firstWaiting: Bool { lock.withLock { waiting } }
    var records: [Record] { lock.withLock { captured } }
    func discoverModels() async throws -> [String] { ["local-model"] }
    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        lock.withLock { captured.append(Record(messages: messages, tools: tools)) }
        let current = messages.last(where: { $0.role == "user" })?.content ?? ""
        return AsyncThrowingStream { continuation in
            let task = Task {
                if current == NativeTurnAuthorityFixture.first && messages.last?.role == "tool" {
                    lock.withLock { waiting = true }
                    await gate.wait()
                    continuation.yield(.init(content: "Research has started.", toolCalls: [], finishReason: "stop"))
                } else if current.contains("What did I ask") {
                    continuation.yield(.init(content: "You asked for NASA sources about lunar water ice.", toolCalls: [], finishReason: "stop"))
                } else if messages.last?.role == "user" {
                    let objective = current.contains("Mars") ? "Research Mars ice" : "Research lunar ice from NASA sources"
                    let arguments = try! NativeToolLoop.serializedResult(.object(["worker_type": .string("research"),
                        "objective": .string(objective), "deliverables": .array([.string("Three findings with links")])]))
                    continuation.yield(.init(content: "", toolCalls: [.init(id: UUID().uuidString, name: NativeTaskTools.toolName,
                        arguments: arguments)], finishReason: "tool_calls"))
                } else {
                    continuation.yield(.init(content: current == NativeTurnAuthorityFixture.second ? "12" : "Research has started.",
                        toolCalls: [], finishReason: "stop"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
