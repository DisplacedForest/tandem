import Foundation
import GRDB

actor NativeSessionGate {
    var waiting = 0
    var continuations: [CheckedContinuation<Void, Never>] = []
    var open = false
    func wait() async {
        waiting += 1
        if !open { await withCheckedContinuation { continuations.append($0) } }
    }
    func release() {
        open = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }
}

final class NativeSessionFixtureTransport: NativeChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[NativeChatMessage]] = []
    private var advertised: [[NativeToolSchema]] = []
    var histories: [[NativeChatMessage]] { lock.withLock { captured } }
    var schemas: [[NativeToolSchema]] { lock.withLock { advertised } }

    func discoverModels() async throws -> [String] { ["local-model"] }
    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        lock.withLock { captured.append(messages); advertised.append(tools) }
        let query = messages.last(where: { $0.role == "user" })?.content ?? ""
        return AsyncThrowingStream { continuation in
            let calls: [NativeChatToolCall]
            if query.contains("slow") && messages.last?.role == "user" && tools.contains(where: { $0.name == "hold" }) {
                calls = [NativeChatToolCall(id: "same-call", name: "hold", arguments: "{}")]
            } else { calls = [] }
            continuation.yield(NativeChatStreamSnapshot(content: calls.isEmpty ? "Answer for \(query)." : "",
                toolCalls: calls, finishReason: calls.isEmpty ? "stop" : "tool_calls"))
            continuation.finish()
        }
    }
}

@MainActor
enum NativeSessionFixture {
    static let config = NativeChatConfig(baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: nil,
                                        model: "local-model", chatTemplateKwargs: nil)

    static func store(_ repository: LocalChatRepository, transport: NativeSessionFixtureTransport,
                      gate: NativeSessionGate, confirmation: Bool = false) -> ChatStore {
        let definition = NativeToolDefinition(id: "hold", name: "hold", title: "Check the reference",
            description: "Read the synthetic reference", parameters: .object(["type": .string("object")]),
            confirmation: confirmation ? .required : .none, timeout: .seconds(10), isAvailable: { true },
            execute: { _ in await gate.wait(); return .object(["finding": .string("The reference is ready")]) })
        let store = ChatStore(nativeConfig: config, nativeTransport: transport, repository: repository,
            nativeEnabledToolIDs: ["hold", NativeWebTools.searchToolID, NativeWebTools.researchToolID],
            nativeToolRegistry: NativeToolRegistry(definitions: [definition]), artifactPersistenceEnabled: false)
        store.newConversation()
        return store
    }

    static func eventually(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NativeTaskFixture.Failure.assertion(message)
    }

    static func run() async throws {
        try await NativeTurnAuthorityFixture.run()
        try await continuous()
        try await serialChat()
        try await queueBound()
        try await confirmations()
        try await persistence()
        try await NativeSessionSafetyFixture.run()
        print("NATIVE SESSION FIXTURE OK")
    }

    static func continuous() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let transport = NativeSessionFixtureTransport()
        let gate = NativeSessionGate()
        let store = store(repository, transport: transport, gate: gate)
        store.setSessionMode(.continuous)
        store.sendText("slow first question")
        let firstID = store.selected!.messages.last!.id
        try await eventually("First turn must reach its real tool executor") {
            store.selected?.messages.first(where: { $0.id == firstID })?.toolActivities.first?.state == .pending
        }
        store.draft = "fridge question"
        store.send()
        let secondID = store.selected!.messages.last!.id
        try NativeTaskFixture.require(store.draft.isEmpty && (try repository.messages(conversationID: store.selectedID!)).count == 4,
                                      "Accepted second input is persisted before the draft clears")
        try await eventually("Continuous second answer must finish while first tool is blocked") {
            store.selected?.messages.first(where: { $0.id == secondID })?.state == .complete
        }
        try NativeTaskFixture.require(store.selected?.messages.first(where: { $0.id == firstID })?.state == .streaming,
                                      "Independent second answer must not stop or complete the first")
        let original = store.selectedID!
        store.newConversation()
        store.sendText("another conversation")
        try await eventually("Inactive conversations must not block a selected conversation") { store.selected?.messages.last?.state == .complete }
        store.select(original)
        store.stopAnswer(firstID)
        let stopped = store.selected!.messages.first(where: { $0.id == firstID })!
        await gate.release()
        try await Task.sleep(for: .milliseconds(80))
        try NativeTaskFixture.require(store.selected!.messages.first(where: { $0.id == firstID }) == stopped,
                                      "Cancellation-resistant tool result must not mutate a stopped answer")
        try NativeTaskFixture.require(transport.schemas.allSatisfy { !$0.contains(where: { $0.name == "deep_research" }) },
                                      "Blocking research must never be advertised")
    }

    static func serialChat() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let transport = NativeSessionFixtureTransport()
        let gate = NativeSessionGate()
        let store = store(repository, transport: transport, gate: gate)
        store.sendText("slow first question")
        try await eventually("Chat first turn should reach tool") { store.selected?.messages.last?.toolActivities.isEmpty == false }
        store.draft = "Why?"
        store.send()
        let why = store.selected!.messages.last!.id
        try NativeTaskFixture.require(store.answerStatus(why) == "Waiting to answer" && store.draft.isEmpty,
                                      "Chat accepts and visibly queues the follow-up")
        store.setSessionMode(.continuous)
        store.sendText("independent later question")
        try NativeTaskFixture.require(transport.histories.count == 1, "Mode change must not overtake queued Chat follow-up")
        await gate.release()
        try await eventually("Chat queue must drain") { store.conversationTurns.allSatisfy { $0.state == .complete } }
        let request = transport.histories.first(where: { $0.last?.role == "user" && $0.last?.content == "Why?" })
        try NativeTaskFixture.require(request?.contains(where: { $0.role == "assistant" && $0.content.contains("Answer for slow first") }) == true,
                                      "Claimed Chat follow-up must see completed predecessor answer")
        let independent = transport.histories.first(where: { $0.last?.content == "independent later question" })
        try NativeTaskFixture.require(independent?.contains(where: { $0.role == "assistant" && $0.content.contains("Answer for slow first") }) == false,
                                      "Continuous context must remain frozen at acceptance")
    }

    static func queueBound() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let transport = NativeSessionFixtureTransport()
        let gate = NativeSessionGate()
        let store = store(repository, transport: transport, gate: gate)
        store.setSessionMode(.continuous)
        for index in 0..<10 { try NativeTaskFixture.require(store.sendText("slow \(index)"), "Queue must accept its bounded capacity") }
        store.draft = "keep this draft"
        store.send()
        try NativeTaskFixture.require(store.draft == "keep this draft" && store.selected?.messages.count == 20,
                                      "Full queue preserves the draft and never duplicates messages")
        try NativeTaskFixture.require(try repository.conversationTurns().filter { $0.state == .running }.count == 2,
                                      "The two-turn global limit must be enforced transactionally")
        if let index = store.conversations.firstIndex(where: { $0.id == store.selectedID }) {
            let question = Message(role: .assistant, text: "Choose", ask: VeraAsk(question: "Choose", options: [.init(label: "A")]))
            store.conversations[index].messages.append(question)
            store.submitAsk(messageID: question.id, selections: ["A"], other: "")
            try NativeTaskFixture.require(store.conversations[index].messages.last?.answered == false,
                                          "A full queue must not consume the structured answer")
            store.conversations[index].messages.removeLast()
        }
        store.suspendsTurnScheduling = true
        for turn in store.conversationTurns { store.stopAnswer(turn.assistantMessageID) }
        await gate.release()
    }

    static func confirmations() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let gate = NativeSessionGate()
        await gate.release()
        let store = store(repository, transport: NativeSessionFixtureTransport(), gate: gate, confirmation: true)
        store.setSessionMode(.continuous)
        store.sendText("slow one")
        store.sendText("slow two")
        try await eventually("Each simultaneous turn must own a separate confirmation") { store.turnConfirmations.count == 2 }
        let ids = store.selected!.messages.filter { $0.role == .assistant }.map(\.id)
        store.resolveTurnConfirmation(ids[0], approved: true, requestID: "same-call", token: UUID())
        try NativeTaskFixture.require(store.turnConfirmations.count == 2,
                                      "A stale rendered confirmation must not approve a newer request with the same call ID")
        store.resolveTurnConfirmation(ids[0], approved: true, requestID: "same-call", token: store.turnConfirmationTokens[ids[0]])
        try await eventually("Approved turn should finish independently") { store.selected?.messages.first(where: { $0.id == ids[0] })?.state == .complete }
        try NativeTaskFixture.require(store.turnConfirmations[ids[1]] != nil,
                                      "Approving an identical call ID in one turn cannot approve another")
        store.newConversation()
        store.stopAnswer(ids[1])
        try NativeTaskFixture.require(store.turnConfirmations.isEmpty, "Stopping a hidden turn resolves only its own pending approval")
    }

    static func persistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.sqlite")
        let repository = try LocalChatRepository(url: url)
        let gate = NativeSessionGate()
        let first = store(repository, transport: NativeSessionFixtureTransport(), gate: gate)
        first.suspendsTurnScheduling = true
        first.sendText("saved pending")
        first.sendText("uncertain running")
        let records = try repository.conversationTurns()
        let claimed = try repository.claimTurn(records[0].id, attempt: UUID())!
        var crashed = claimed
        crashed.ownerPID = Int32.max
        crashed.ownerBirth = nil
        let crashedRecord = crashed
        try await repository.database.write { try LocalChatRepository.writeTurn(crashedRecord, db: $0) }
        let reopened = try LocalChatRepository(url: url)
        let restored = try reopened.conversationTurns()
        try NativeTaskFixture.require(restored[0].state == .interrupted && restored[1].state == .pending,
                                      "Restart distinguishes uncertain running effects from unsent pending messages")
        let messages = try reopened.messages(conversationID: claimed.conversationID)
        try NativeTaskFixture.require(messages[1].state == .interrupted && messages[3].state == .streaming,
                                      "Recovery keeps saved pending answers resumable without replaying uncertain work")
        let second = store(reopened, transport: NativeSessionFixtureTransport(), gate: gate)
        second.conversations = try reopened.listConversations()
        second.select(claimed.conversationID)
        second.scheduleConversationTurns()
        try await eventually("Safe pending turn should resume") { second.conversationTurns.last?.state == .complete }
        try NativeTaskFixture.require(try reopened.conversationTurns()[0].state == .interrupted
            && second.selected?.messages[1].state == .interrupted,
            "Running turn must never replay on reopen and its recovered transcript stays interrupted")
        let rollback = store(try LocalChatRepository(inMemory: true), transport: NativeSessionFixtureTransport(), gate: gate)
        let rollbackRepository = rollback.repository as! LocalChatRepository
        try await rollbackRepository.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_turn BEFORE INSERT ON native_conversation_turns BEGIN SELECT RAISE(ABORT, 'fixture rollback'); END")
        }
        rollback.draft = "preserve after failed transaction"
        rollback.send()
        try NativeTaskFixture.require(rollback.draft == "preserve after failed transaction" && rollback.selected!.messages.isEmpty,
                                      "Atomic enqueue rollback must preserve draft and history")
        try NativeTaskFixture.require(try rollbackRepository.listConversations().isEmpty,
                                      "Failed enqueue must not leave a partial conversation or message")
    }
}
