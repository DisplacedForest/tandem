import Foundation
import GRDB

final class AskPersistenceTransport: NativeChatTransport, @unchecked Sendable {
    static let opener = "Fair enough, here's one that actually shapes how I work."
    static let asking = "Help me plan the week."
    static let block = """
        ```vera:ask
        {"question":"How should I plan with you?","multiSelect":true,"options":[{"label":"Short lists","description":"A few items per day."},{"label":"Time blocks","description":"Hours set aside for each item."},{"label":"Loose themes","description":"One focus per day, no times."}]}
        ```
        """
    private let lock = NSLock()
    static let otherBlock = """
        ```vera:ask
        {"question":"Which day first?","multiSelect":false,"options":[{"label":"Monday","description":"Start the week."},{"label":"Friday","description":"End the week."}]}
        ```
        """
    private var captured: [[NativeChatMessage]] = []
    private var replacement: String?
    var nextAsk: String? {
        get { lock.withLock { replacement } }
        set { lock.withLock { replacement = newValue } }
    }
    var histories: [[NativeChatMessage]] { lock.withLock { captured } }
    private var holding = false
    var holdsAfterQuestion: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        if NativeRequestAuthorizer.asksRestrictions(messages) { return NativeRequestAuthorizer.answered(NativeRequestAuthorizer.noRestrictions) }
        lock.withLock { captured.append(messages) }
        let query = messages.last(where: { $0.role == "user" })?.content ?? ""
        let full = Self.opener + "\n\n" + (nextAsk ?? Self.block)
        let partial = Self.opener + "\n\n```vera:ask\n{\"question\":\"How should"
        return AsyncThrowingStream { continuation in
            guard query == Self.asking else {
                continuation.yield(NativeChatStreamSnapshot(content: "Noted.", toolCalls: [], finishReason: "stop"))
                continuation.finish()
                return
            }
            continuation.yield(NativeChatStreamSnapshot(content: partial, toolCalls: [], finishReason: nil))
            guard holdsAfterQuestion else {
                continuation.yield(NativeChatStreamSnapshot(content: full, toolCalls: [], finishReason: "stop"))
                continuation.finish()
                return
            }
            continuation.yield(NativeChatStreamSnapshot(content: full, toolCalls: [], finishReason: nil))
            Task {
                while self.holdsAfterQuestion { try? await Task.sleep(for: .milliseconds(10)) }
                continuation.yield(NativeChatStreamSnapshot(content: full, toolCalls: [], finishReason: "stop"))
                continuation.finish()
            }
        }
    }
}

@MainActor
enum AskPersistenceSelftest {
    static let expected = VeraAsk(question: "How should I plan with you?", multiSelect: true, options: [
        VeraAskOption(label: "Short lists", description: "A few items per day."),
        VeraAskOption(label: "Time blocks", description: "Hours set aside for each item."),
        VeraAskOption(label: "Loose themes", description: "One focus per day, no times."),
    ])

    static func run() async throws {
        let require = NativeTaskFixture.require
        try roundTrip(require)
        try staleSaves(require)
        try await retried(require)
        try await retriedAfterReply(require)
        try await composerReplyWhileStreaming(require)
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
        try require(loaded[1].answerText == nil, "A question with no later message from the person can still be answered")
        try repository.saveMessage(Message(role: .user, text: "Short lists, Time blocks"), conversationID: conversation.id, ordinal: 3)
        try repository.saveMessage(Message(role: .user, text: "Also weekends"), conversationID: conversation.id, ordinal: 4)
        let reloaded = try repository.messages(conversationID: conversation.id)[1]
        try require(reloaded.ask == expected && reloaded.answered && reloaded.answerText == "Short lists, Time blocks",
                    "A question followed by a message from the person loads answered with the first message after it")
        let recent = try repository.recentMessages(conversationID: conversation.id, limit: 4).first
        try require(recent?.ask == expected && recent?.answered == true && recent?.answerText == "Short lists, Time blocks",
                    "The recent window loads the question and its answer too")
        try require(try metadata(repository, asked.id)?.contains("answer") == false, "No answer is ever saved with the question")
    }

    static func staleSaves(_ require: (Bool, String) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ask-persistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chat.sqlite")
        let artifacts = folder.appendingPathComponent("artifacts", isDirectory: true)
        let projects = folder.appendingPathComponent("projects", isDirectory: true)
        let repository = try LocalChatRepository(url: file, artifactDirectory: artifacts, projectsDirectory: projects)
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: AskPersistenceTransport(), repository: repository,
                              artifactPersistenceEnabled: false)
        store.suspendsTurnScheduling = true
        store.newConversation()
        try require(store.sendText(AskPersistenceTransport.asking), "The chat accepts the message")
        guard let accepted = try repository.conversationTurns().last,
              let turn = try repository.claimTurn(accepted.id, attempt: UUID()) else {
            throw NativeTaskFixture.Failure.assertion("The turn is accepted and claimed")
        }
        let conversationID = turn.conversationID
        func reload() throws -> Message? {
            try repository.messages(conversationID: conversationID).first { $0.id == turn.assistantMessageID }
        }
        let early = Message(id: turn.assistantMessageID, role: .assistant, text: "Fair enough", state: .streaming)
        let asked = Message(id: turn.assistantMessageID, role: .assistant, text: AskPersistenceTransport.opener, state: .streaming, ask: expected)
        try repository.checkpointTurn(turn, message: asked, ordinal: 1)
        try repository.saveMessage(Message(role: .user, text: "Short lists"), conversationID: conversationID, ordinal: 2)
        try repository.checkpointTurn(turn, message: early, ordinal: 1)
        try repository.checkpointTurn(turn, message: asked, ordinal: 1)
        var finished = asked
        finished.state = .complete
        try repository.finishTurn(turn.id, attempt: turn.attempt, state: .complete, message: finished, ordinal: 1)
        try repository.saveMessage(finished, conversationID: conversationID, ordinal: 1)
        let stored = try metadata(repository, turn.assistantMessageID)
        try require(stored?.contains("\"ask\"") == true && stored?.contains("answer") == false,
                    "Only the question is saved, never an answer")
        let fresh = try LocalChatRepository(url: file, artifactDirectory: artifacts, projectsDirectory: projects)
        let kept = try fresh.messages(conversationID: conversationID).first { $0.id == turn.assistantMessageID }
        try require(kept?.answered == true && kept?.answerText == "Short lists" && kept?.ask == expected && kept?.state == .complete,
                    "Checkpoints saved before and after the answer in any order lose nothing on a fresh load")
        let changedAsk = VeraAsk(question: "Which day first?", options: [VeraAskOption(label: "Monday"), VeraAskOption(label: "Friday")])
        var changed = finished
        changed.ask = changedAsk
        try repository.saveMessage(changed, conversationID: conversationID, ordinal: 1)
        try require(try reload()?.ask == changedAsk, "A changed question is saved as given")
        var dropped = finished
        dropped.ask = nil
        try repository.saveMessage(dropped, conversationID: conversationID, ordinal: 1)
        let cleared = try reload()
        let clearedMetadata = try metadata(repository, turn.assistantMessageID)
        try require(cleared?.ask == nil && clearedMetadata == nil, "A reply with no question saves no question")
    }

    static func retried(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let transport = AskPersistenceTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
                              artifactPersistenceEnabled: false)
        store.newConversation()
        try require(store.sendText(AskPersistenceTransport.asking), "The chat accepts the message")
        try await NativeSessionFixture.eventually("The reply with a question completes") {
            store.selected?.messages.last?.role == .assistant && store.selected?.messages.last?.state == .complete
        }
        try await NativeSessionFixture.eventually("The finished turn settles") { store.conversationTurns.allSatisfy { $0.state != .pending && $0.state != .running } }
        guard let conversationID = store.selectedID, let ci = store.conversations.firstIndex(where: { $0.id == conversationID }),
              let ri = store.conversations[ci].messages.lastIndex(where: { $0.role == .assistant }) else {
            throw NativeTaskFixture.Failure.assertion("The reply is shown")
        }
        let replyID = store.conversations[ci].messages[ri].id
        store.conversations[ci].messages[ri].answered = true
        store.conversations[ci].messages[ri].answerText = "Short lists"
        guard let turnID = store.conversationTurns.first(where: { $0.assistantMessageID == replyID })?.id else {
            throw NativeTaskFixture.Failure.assertion("The reply has a turn")
        }
        try await repository.database.write { db in
            guard var turn = try LocalChatRepository.readTurn(turnID, db: db) else { return }
            turn.state = .interrupted
            try LocalChatRepository.writeTurn(turn, db: db)
        }
        store.conversations[ci].messages[ri].state = .interrupted
        transport.nextAsk = AskPersistenceTransport.otherBlock
        store.retryAnswer(replyID)
        try await NativeSessionFixture.eventually("The retried reply completes") {
            let message = store.conversations.first { $0.id == conversationID }?.messages.first { $0.id == replyID }
            return message?.state == .complete && message?.ask?.question == "Which day first?"
        }
        let shown = store.conversations.first { $0.id == conversationID }?.messages.first { $0.id == replyID }
        try require(shown?.answered == false && shown?.answerText == nil, "A retry that brings back a different question can be answered")
        try await NativeSessionFixture.eventually("The retried question loads answerable") {
            let saved = try? repository.messages(conversationID: conversationID).first { $0.id == replyID }
            return saved?.ask?.question == "Which day first?" && saved?.answered == false
        }
    }

    static func retriedAfterReply(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let transport = AskPersistenceTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
                              artifactPersistenceEnabled: false)
        store.newConversation()
        try require(store.sendText(AskPersistenceTransport.asking), "The chat accepts the message")
        try await NativeSessionFixture.eventually("The reply with a question completes") {
            store.selected?.messages.last?.role == .assistant && store.selected?.messages.last?.state == .complete
        }
        try await NativeSessionFixture.eventually("The finished turn settles") { store.conversationTurns.allSatisfy { $0.state != .pending && $0.state != .running } }
        guard let conversationID = store.selectedID, let ci = store.conversations.firstIndex(where: { $0.id == conversationID }),
              let ri = store.conversations[ci].messages.lastIndex(where: { $0.role == .assistant }),
              let turnID = store.conversationTurns.first(where: { $0.assistantMessageID == store.conversations[ci].messages[ri].id })?.id else {
            throw NativeTaskFixture.Failure.assertion("The reply is shown")
        }
        let replyID = store.conversations[ci].messages[ri].id
        let answer = Message(role: .user, text: "Short lists")
        store.conversations[ci].messages.append(answer)
        try repository.saveMessage(answer, conversationID: conversationID, ordinal: store.conversations[ci].messages.count - 1)
        try await repository.database.write { db in
            guard var turn = try LocalChatRepository.readTurn(turnID, db: db) else { return }
            turn.state = .interrupted
            try LocalChatRepository.writeTurn(turn, db: db)
        }
        store.conversations[ci].messages[ri].state = .interrupted
        store.conversations[ci].messages[ri].answered = false
        store.conversations[ci].messages[ri].answerText = nil
        transport.nextAsk = AskPersistenceTransport.otherBlock
        store.retryAnswer(replyID)
        let retrying = store.conversations.first { $0.id == conversationID }?.messages.first { $0.id == replyID }
        try require(retrying?.answered == true && retrying?.answerText == "Short lists",
                    "A retried card with a reply below it stays answered as soon as the retry starts")
        try await NativeSessionFixture.eventually("The retried reply streams its new question") {
            store.conversations.first { $0.id == conversationID }?.messages.first { $0.id == replyID }?.ask?.question == "Which day first?"
        }
        let streamed = store.conversations.first { $0.id == conversationID }?.messages.first { $0.id == replyID }
        try require(streamed?.answered == true && streamed?.answerText == "Short lists",
                    "A retried card with a reply below it can't be answered again while it streams")
        try await NativeSessionFixture.eventually("The retried reply completes") {
            store.conversations.first { $0.id == conversationID }?.messages.first { $0.id == replyID }?.state == .complete
        }
        try await NativeSessionFixture.eventually("It loads answered with the first reply below it") {
            let saved = try? repository.messages(conversationID: conversationID).first { $0.id == replyID }
            return saved?.ask?.question == "Which day first?" && saved?.answered == true && saved?.answerText == "Short lists"
        }
    }

    static func composerReplyWhileStreaming(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let transport = AskPersistenceTransport()
        transport.holdsAfterQuestion = true
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
                              artifactPersistenceEnabled: false)
        store.newConversation()
        try require(store.sendText(AskPersistenceTransport.asking), "The chat accepts the message")
        try await NativeSessionFixture.eventually("The question shows while the reply is still open") {
            store.selected?.messages.last(where: { $0.role == .assistant })?.ask?.question == expected.question
        }
        guard let conversationID = store.selectedID,
              let replyID = store.selected?.messages.last(where: { $0.role == .assistant })?.id else {
            throw NativeTaskFixture.Failure.assertion("The reply is shown")
        }
        func card() -> Message? { store.conversations.first { $0.id == conversationID }?.messages.first { $0.id == replyID } }
        try require(card()?.answered == false, "The open question can be answered")
        try require(store.sendText("Short lists"), "A reply typed in the message box is accepted while the question streams")
        try require(card()?.answered == true && card()?.answerText == "Short lists",
                    "A typed reply answers the open question right away")
        transport.holdsAfterQuestion = false
        try await NativeSessionFixture.eventually("The reply with the question completes") { card()?.state == .complete }
        try require(card()?.answered == true && card()?.answerText == "Short lists", "The question stays answered after the stream finishes")
        try await NativeSessionFixture.eventually("The question loads answered with the typed reply") {
            let saved = try? repository.messages(conversationID: conversationID).first { $0.id == replyID }
            return saved?.answered == true && saved?.answerText == "Short lists"
        }
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
                    "The answered question loads answered from the message after it")
    }
}
