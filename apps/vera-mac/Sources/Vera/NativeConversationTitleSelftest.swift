import Foundation

final class ConversationTitleStubTransport: NativeChatTransport, @unchecked Sendable {
    enum Mode { case reply(String), fail, hang }
    struct Failure: Error {}

    private let lock = NSLock()
    private var currentMode: Mode
    private var titleRequestCount = 0
    let gate: NativeSessionGate?

    init(_ mode: Mode, gate: NativeSessionGate? = nil) {
        currentMode = mode
        self.gate = gate
    }

    var titleRequests: Int { lock.withLock { titleRequestCount } }
    var mode: Mode {
        get { lock.withLock { currentMode } }
        set { lock.withLock { currentMode = newValue } }
    }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        let isTitle = messages.first?.role == "system" && messages.first?.content.contains("title for this conversation") == true
        guard isTitle else {
            let query = messages.last(where: { $0.role == "user" })?.content ?? ""
            return AsyncThrowingStream { continuation in
                continuation.yield(NativeChatStreamSnapshot(content: "Answer for \(query).", toolCalls: [], finishReason: "stop"))
                continuation.finish()
            }
        }
        lock.withLock { titleRequestCount += 1 }
        let mode = self.mode
        let gate = self.gate
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let gate { await gate.wait() }
                switch mode {
                case .reply(let text):
                    continuation.yield(NativeChatStreamSnapshot(content: String(text.prefix(4)), toolCalls: [], finishReason: nil))
                    continuation.yield(NativeChatStreamSnapshot(content: text, toolCalls: [], finishReason: "stop"))
                    continuation.finish()
                case .fail:
                    continuation.finish(throwing: Failure())
                case .hang:
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
extension SelfTest {
    static func runConversationTitles() async throws {
        let require = NativeTaskFixture.require
        let G = ConversationTitleGenerator.self

        try require(G.clean("Morning coffee routine") == "Morning coffee routine", "A plain title is kept")
        try require(G.clean("\"Morning coffee routine.\"") == "Morning coffee routine", "Quotes and a trailing period are stripped")
        try require(G.clean("`Title: planning the garden`") == "Planning the garden", "A title prefix and backticks are stripped")
        try require(G.clean("\n\n  weekend   hiking plans  \nextra line") == "Weekend hiking plans", "The first non-empty line is used and whitespace collapses")
        try require(G.clean("Coffee") == nil, "One word is rejected")
        try require(G.clean("one two three four five six seven eight nine ten eleven twelve") == nil, "Twelve words are rejected")
        try require(G.clean(String(repeating: "abcdefghij ", count: 7)) == nil, "More than sixty characters are rejected")
        try require(G.clean("   ") == nil, "Blank output is rejected")

        let prompt = G.messages(user: String(repeating: "u", count: 2000), assistant: "Short reply")
        try require(prompt.count == 2 && prompt[0].role == "system" && prompt[1].role == "user", "The prompt is a system and a user message")
        try require(!prompt[1].content.contains(String(repeating: "u", count: 1501)), "Each excerpt is truncated to 1500 characters")
        try require(prompt[1].content.contains("Short reply"), "The first reply is included")

        let good = ConversationTitleStubTransport(.reply("\"Morning coffee routine.\""))
        let generated = await G.generate(transport: good, model: "local-model", user: "hi", assistant: "hello")
        try require(generated == "Morning coffee routine", "generate returns the cleaned final snapshot")

        let failing = ConversationTitleStubTransport(.fail)
        let failed = await G.generate(transport: failing, model: "local-model", user: "hi", assistant: "hello")
        try require(failed == nil, "generate returns nil when the stream throws")

        let hanging = ConversationTitleStubTransport(.hang)
        let start = ContinuousClock.now
        let timedOut = await G.generate(transport: hanging, model: "local-model", user: "hi", assistant: "hello", timeout: .milliseconds(200))
        try require(timedOut == nil, "generate returns nil on timeout")
        try require(start.duration(to: .now) < .seconds(2), "The timeout cancels the stream promptly")

        try await titleStoreFirstReply()
        try await titleStoreRenameWins()
        try await titleStoreExistingConversation()
        print("  conversation titles OK (clean, prompt, stream, failure, timeout, first reply, no retitle, rename wins, existing history)")
    }

    private static func titleStore(_ transport: ConversationTitleStubTransport, repository: LocalChatRepository) -> ChatStore {
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
            repository: repository, artifactPersistenceEnabled: false)
        store.generatesConversationTitles = true
        return store
    }

    private static func titleStoreFirstReply() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let transport = ConversationTitleStubTransport(.reply("Morning coffee routine"))
        let store = titleStore(transport, repository: repository)
        store.newConversation()
        try require(store.sendText("  \n How should I brew my morning coffee?"), "The first message sends")
        let id = store.selectedID!
        try require(store.selected?.title == "How should I brew my morning coffee?", "The fallback title trims leading whitespace")
        try await NativeSessionFixture.eventually("A title is generated after the first reply") {
            store.selected?.titleSource == .generated
        }
        try require(store.selected?.title == "Morning coffee routine", "The generated title is applied")
        let saved = try repository.listConversations().first { $0.id == id }
        try require(saved?.title == "Morning coffee routine" && saved?.titleSource == .generated, "The generated title is saved")

        transport.mode = .reply("Something else entirely")
        try require(store.sendText("And what about tea?"), "The second message sends")
        try await NativeSessionFixture.eventually("The second reply completes") {
            store.selected?.messages.count == 4 && store.selected?.messages.last?.state == .complete
        }
        try await Task.sleep(for: .milliseconds(100))
        try require(transport.titleRequests == 1, "A second reply never requests a title")
        try require(store.selected?.title == "Morning coffee routine", "A second reply never retitles")
        store.conversationTurnLoop?.cancel()
    }

    private static func titleStoreRenameWins() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let gate = NativeSessionGate()
        let transport = ConversationTitleStubTransport(.reply("Late generated title"), gate: gate)
        let store = titleStore(transport, repository: repository)
        store.newConversation()
        try require(store.sendText("Help me plan a garden"), "The message sends")
        let id = store.selectedID!
        try await NativeSessionFixture.eventually("The title request starts") { transport.titleRequests == 1 }
        store.renameConversation(id, title: "  My garden  ")
        try require(store.selected?.title == "My garden" && store.selected?.titleSource == .user, "A rename applies immediately")
        await gate.release()
        try await Task.sleep(for: .milliseconds(150))
        try require(store.selected?.title == "My garden" && store.selected?.titleSource == .user, "A rename wins over a late generated title")
        let saved = try repository.listConversations().first { $0.id == id }
        try require(saved?.title == "My garden" && saved?.titleSource == .user, "The rename is saved")
        store.renameConversation(id, title: "   ")
        try require(store.selected?.title == "My garden", "An empty rename is ignored")
        store.conversationTurnLoop?.cancel()
    }

    private static func titleStoreExistingConversation() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let existing = Conversation(id: UUID().uuidString, title: "Old chat about bikes", messages: [], updatedAt: Date(), isPersisted: true)
        try repository.saveConversation(existing)
        try repository.saveMessage(Message(role: .user, text: "Which bike should I buy?"), conversationID: existing.id, ordinal: 0)
        try repository.saveMessage(Message(role: .assistant, text: "A gravel bike."), conversationID: existing.id, ordinal: 1)
        let transport = ConversationTitleStubTransport(.reply("Choosing a new bike"))
        let store = titleStore(transport, repository: repository)
        await store.connect()
        store.select(existing.id)
        try require(store.selected?.messages.count == 2, "The existing history loads")
        try require(store.sendText("What tires go with it?"), "A follow-up sends")
        try await NativeSessionFixture.eventually("The follow-up completes") {
            store.selected?.messages.count == 4 && store.selected?.messages.last?.state == .complete
        }
        try await Task.sleep(for: .milliseconds(100))
        try require(transport.titleRequests == 0, "An existing conversation never requests a title")
        try require(store.selected?.title == "Old chat about bikes" && store.selected?.titleSource == .fallback,
                    "An existing conversation keeps its title")

        var four = existing
        four.messages = try repository.messages(conversationID: existing.id)
        try require(!ConversationTitleGenerator.shouldGenerate(for: four, isAssistantThread: false), "Four messages never qualify")
        var fresh = Conversation(id: "fresh", title: "Hi", messages: [Message(role: .user, text: "Hi there"), Message(role: .assistant, text: "Hello")], updatedAt: Date())
        try require(ConversationTitleGenerator.shouldGenerate(for: fresh, isAssistantThread: false), "A fresh first exchange qualifies")
        try require(!ConversationTitleGenerator.shouldGenerate(for: fresh, isAssistantThread: true), "The assistant thread never qualifies")
        fresh.messages[1].state = .interrupted
        try require(!ConversationTitleGenerator.shouldGenerate(for: fresh, isAssistantThread: false), "An interrupted reply never qualifies")
        store.conversationTurnLoop?.cancel()
    }
}
