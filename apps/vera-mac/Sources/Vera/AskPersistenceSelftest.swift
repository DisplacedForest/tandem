import Foundation
import GRDB

final class AskPersistenceTransport: NativeChatTransport, @unchecked Sendable {
    static let opener = "Fair enough, here's one that actually shapes how I work."
    static let asking = "Help me plan the week."
    static let block = """
        ```vera:ask
        {"question":"How should I plan with you?","multiSelect":true,"options":[{"label":"Short lists","description":"A few items per day."},{"label":"Time blocks","description":"Hours set aside for each task."},{"label":"Loose themes","description":"One focus per day, no times."}]}
        ```
        """
    private let lock = NSLock()
    private var captured: [[NativeChatMessage]] = []
    var histories: [[NativeChatMessage]] { lock.withLock { captured } }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        if NativeRequestAuthorizer.asksRestrictions(messages) { return NativeRequestAuthorizer.answered(NativeRequestAuthorizer.noRestrictions) }
        lock.withLock { captured.append(messages) }
        let query = messages.last(where: { $0.role == "user" })?.content ?? ""
        let full = Self.opener + "\n\n" + Self.block
        let partial = Self.opener + "\n\n```vera:ask\n{\"question\":\"How should"
        return AsyncThrowingStream { continuation in
            if query == Self.asking {
                continuation.yield(NativeChatStreamSnapshot(content: partial, toolCalls: [], finishReason: nil))
                continuation.yield(NativeChatStreamSnapshot(content: full, toolCalls: [], finishReason: "stop"))
            } else {
                continuation.yield(NativeChatStreamSnapshot(content: "Noted.", toolCalls: [], finishReason: "stop"))
            }
            continuation.finish()
        }
    }
}

@MainActor
enum AskPersistenceSelftest {
    static let expected = VeraAsk(question: "How should I plan with you?", multiSelect: true, options: [
        VeraAskOption(label: "Short lists", description: "A few items per day."),
        VeraAskOption(label: "Time blocks", description: "Hours set aside for each task."),
        VeraAskOption(label: "Loose themes", description: "One focus per day, no times."),
    ])

    static func run() async throws {
        let require = NativeTaskFixture.require
        try roundTrip(require)
        try history(require)
        try await endToEnd(require)
        print("ASK PERSISTENCE SELFTEST OK")
    }

    static func metadata(_ repository: LocalChatRepository, _ id: UUID) throws -> String? {
        try repository.database.read { db in
            try String.fetchOne(db, sql: "SELECT metadata_json FROM messages WHERE id = ?", arguments: [id.uuidString])
        }
    }

    static func roundTrip(_ require: (Bool, String) throws -> Void) throws {
        let repository = try LocalChatRepository(inMemory: true)
        let conversation = Conversation(id: UUID().uuidString, title: "Planning", messages: [], updatedAt: Date())
        try repository.saveConversation(conversation)
        let user = Message(role: .user, text: "Help me plan.")
        let asked = Message(role: .assistant, text: AskPersistenceTransport.opener, ask: expected)
        let plain = Message(role: .assistant, text: "No question here.")
        try repository.saveMessage(user, conversationID: conversation.id, ordinal: 0)
        try repository.saveMessage(asked, conversationID: conversation.id, ordinal: 1)
        try repository.saveMessage(plain, conversationID: conversation.id, ordinal: 2)
        let loaded = try repository.messages(conversationID: conversation.id)
        try require(loaded.count == 3, "Every saved message loads")
        try require(loaded[1].ask == expected && loaded[1].text == AskPersistenceTransport.opener && !loaded[1].answered,
                    "An assistant question loads back with its options and descriptions")
        try require(loaded[0].ask == nil && loaded[2].ask == nil, "Messages without a question load without one")
        let plainMetadata = try metadata(repository, plain.id)
        let userMetadata = try metadata(repository, user.id)
        try require(plainMetadata == nil && userMetadata == nil,
                    "A message without a question saves no metadata")
        try require(try metadata(repository, asked.id)?.contains("\"ask\"") == true, "The question is saved under its own key")
        var answered = loaded[1]
        answered.answered = true
        answered.answerText = "Short lists, Time blocks"
        try repository.saveAskAnswer(answered)
        let reloaded = try repository.messages(conversationID: conversation.id)[1]
        try require(reloaded.ask == expected && reloaded.answered && reloaded.answerText == "Short lists, Time blocks",
                    "An answered question stays answered after a reload")
        try require(try repository.recentMessages(conversationID: conversation.id, limit: 2).first?.ask == expected,
                    "The recent window loads the question too")
    }

    static func history(_ require: (Bool, String) throws -> Void) throws {
        let user = Message(role: .user, text: "Help me plan.")
        let asked = Message(role: .assistant, text: AskPersistenceTransport.opener, ask: expected)
        let reply = Message(role: .user, text: "Short lists")
        let built = NativeChatHistoryBuilder.build(messages: [user, asked, reply], systemPrompt: "")
        let assistant = built.first { $0.role == "assistant" }?.content ?? ""
        try require(assistant.hasPrefix(AskPersistenceTransport.opener + "\n\n```vera:ask\n") && assistant.hasSuffix("\n```"),
                    "The model sees its earlier question as the fenced block it was taught")
        try require(expected.fencedBlock.hasPrefix("```vera:ask\n{\"question\":\"How should I plan with you?\",\"multiSelect\":true,\"options\":[{\"label\":\"Short lists\""),
                    "The block uses the field order the presentation contract teaches")
        let reparsed = VeraAsk.parse(assistant)
        try require(reparsed.ask == expected && reparsed.clean == AskPersistenceTransport.opener,
                    "The block sent back to the model parses to the same question")
        let snapshot = NativeTurnHistoryMessage.snapshot([user, asked], current: reply)
        try require(snapshot.map(\.message)[1].ask == expected, "The saved turn history keeps the question")
        let onlyAsk = NativeChatHistoryBuilder.build(messages: [user, Message(role: .assistant, text: "", ask: expected), reply], systemPrompt: "")
        try require(onlyAsk.first { $0.role == "assistant" }?.content == expected.fencedBlock,
                    "A question with no other text still reaches the model")
        try require(asked.text == AskPersistenceTransport.opener && !asked.text.contains("vera:ask"),
                    "The shown and copied text never carries the block")
    }

    static func endToEnd(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let transport = AskPersistenceTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
                              artifactPersistenceEnabled: false)
        store.newConversation()
        try require(store.sendText(AskPersistenceTransport.asking), "The chat accepts the message")
        try await NativeSessionFixture.eventually("The reply with a question completes") {
            store.selected?.messages.last?.role == .assistant && store.selected?.messages.last?.state == .complete
        }
        guard let conversationID = store.selectedID else { throw NativeTaskFixture.Failure.assertion("A conversation is selected") }
        try await NativeSessionFixture.eventually("The finished turn settles") { store.conversationTurns.allSatisfy { $0.state != .pending && $0.state != .running } }
        try await Task.sleep(for: .milliseconds(100))
        let shown = store.selected?.messages.last
        try require(shown?.ask == expected && shown?.text == AskPersistenceTransport.opener,
                    "The question card is still there after the reply finishes")
        let saved = try repository.messages(conversationID: conversationID)
        guard let reply = saved.last(where: { $0.role == .assistant }) else {
            throw NativeTaskFixture.Failure.assertion("The reply is saved")
        }
        try require(reply.text == AskPersistenceTransport.opener && reply.ask == expected && reply.ask?.options.count == 3,
                    "The saved reply has its question with every option")
        let fresh = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, artifactPersistenceEnabled: false)
        fresh.conversations = try repository.listConversations()
        fresh.select(conversationID)
        try require(fresh.conversations.first { $0.id == conversationID }?.messages.last { $0.role == .assistant }?.ask == expected,
                    "A fresh launch shows the question card")

        store.submitAsk(messageID: reply.id, selections: ["Short lists", "Time blocks"], other: "")
        try await NativeSessionFixture.eventually("The answer gets a reply") {
            store.selected?.messages.count == 4 && store.selected?.messages.last?.state == .complete
        }
        guard let next = transport.histories.last(where: { $0.last?.content == "Short lists, Time blocks" }) else {
            throw NativeTaskFixture.Failure.assertion("The answer is sent to the model")
        }
        let earlier = next.filter { $0.role == "assistant" }.map(\.content).joined(separator: "\n")
        try require(earlier.contains("```vera:ask\n") && earlier.contains("How should I plan with you?")
                    && expected.options.allSatisfy { earlier.contains($0.label) },
                    "The next turn shows the model its earlier question and options")
        let answered = try repository.messages(conversationID: conversationID).first { $0.id == reply.id }
        try require(answered?.answered == true && answered?.answerText == "Short lists, Time blocks" && answered?.ask == expected,
                    "The answered question is saved as answered")
    }
}
