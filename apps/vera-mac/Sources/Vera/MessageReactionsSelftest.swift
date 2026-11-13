import Foundation
import GRDB

@MainActor
enum MessageReactionsSelftest {
    static let require = NativeTaskFixture.require

    static func run() async throws {
        try migration()
        try toggleOrder()
        try rowOffers()
        try quoteCut()
        try copySweep()
        try startOverRemovesMarks()
        try pendingReplyRules()
        try await companionRequest()
        try await floatingSendLeavesReply()
        try await ordinaryRequestUnchanged()
        print("MESSAGE REACTIONS SELFTEST OK")
    }

    static func count(_ db: Database, _ table: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
    }

    static func migration() throws {
        let queue = try DatabaseQueue()
        try LocalChatRepository.migrator().migrate(queue, upTo: NativeTaskDelivery.migration)
        let conversation = Conversation(id: "before-reactions", title: "Before", messages: [], updatedAt: Date())
        let ask = Message(role: .user, text: "Which room is quietest?")
        let answer = Message(role: .assistant, text: "The reading room upstairs.")
        let later = Message(role: .user, text: "Thanks")
        try queue.write { db in
            try LocalChatRepository.saveConversation(conversation, db: db)
            for (ordinal, message) in [ask, answer, later].enumerated() {
                try LocalChatRepository.saveMessage(message, conversationID: conversation.id, ordinal: ordinal, db: db)
            }
        }
        try require(try queue.read { try !$0.tableExists("message_reactions") }, "The tables are new in migration 41")
        try LocalChatRepository.migrator().migrate(queue)
        let applied = try queue.read { db in
            try db.tableExists("message_reactions") && db.tableExists("message_replies") && count(db, "messages") == 3
        }
        try require(applied, "Migration 41 applies over existing messages and keeps them")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO message_reactions(message_id, emoji, created_at) VALUES (?, ?, 1)",
                           arguments: [answer.id.uuidString, MessageReaction.heart.emoji])
            try db.execute(sql: "INSERT INTO message_replies(message_id, answered_id, quote) VALUES (?, ?, ?)",
                           arguments: [later.id.uuidString, answer.id.uuidString, "The reading room upstairs."])
        }
        try queue.write { db in try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [answer.id.uuidString]) }
        let kept = try queue.read { db in try count(db, "message_reactions") == 0 && count(db, "message_replies") == 1 }
        try require(kept, "Removing the answered message drops its reactions and keeps the reply that quoted it")
        try queue.write { db in try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [conversation.id]) }
        let gone = try queue.read { db in try count(db, "message_reactions") == 0 && count(db, "message_replies") == 0 }
        try require(gone, "Deleting the conversation removes its reactions and replies through the cascade")
    }

    static func scratchURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reactions-\(UUID().uuidString).sqlite")
    }

    static func toggleOrder() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try LocalChatRepository(url: url)
        let conversation = Conversation(id: "toggles", title: "Toggles", messages: [], updatedAt: Date())
        let answer = Message(role: .assistant, text: "Here")
        let ask = Message(role: .user, text: "And this one?")
        try repository.saveConversation(conversation)
        try repository.saveMessage(answer, conversationID: conversation.id, ordinal: 0)
        try repository.saveMessage(ask, conversationID: conversation.id, ordinal: 1)
        let heart = MessageReaction.heart.emoji, up = MessageReaction.thumbsUp.emoji, fox = "\u{1F98A}"
        let base = Date(timeIntervalSince1970: 1_000)
        try require(try repository.toggleReaction(heart, messageID: answer.id, at: base) == [heart], "Toggle adds a reaction")
        try require(try repository.toggleReaction(up, messageID: answer.id, at: base) == [heart, up], "A second one is added after it")
        try require(try repository.toggleReaction(fox, messageID: answer.id, at: base) == [heart, up, fox], "A picked emoji is added last")
        try require(try repository.toggleReaction(fox, messageID: answer.id, at: base) == [heart, up], "Picking it again takes it off")
        try require(try repository.toggleReaction(fox, messageID: answer.id, at: base) == [heart, up, fox], "It can be put back")
        try require(try repository.toggleReaction(heart, messageID: answer.id, at: base) == [up, fox], "Toggling the first again removes it and keeps the order")
        try repository.recordReply(MessageReply(answeredID: answer.id, quote: "Here"), messageID: ask.id)
        let turnAsk = Message(role: .user, text: "And this?")
        let turnAnswer = Message(role: .assistant, text: "", state: .streaming)
        let turn = NativeConversationTurn(id: UUID(), conversationID: conversation.id, userMessageID: turnAsk.id, assistantMessageID: turnAnswer.id,
            mode: .chat, profile: "", enabledToolIDs: [], persona: "Persona", userScope: "", instructions: "", grounding: [],
            memorySettings: .fresh, createdAt: Date(), history: [NativeTurnHistoryMessage(turnAsk)])
        let quoted = MessageReply(answeredID: answer.id, quote: "Here too")
        try repository.acceptTurn(turn, conversation: conversation, user: turnAsk, reply: turnAnswer, answering: quoted)
        try require(try repository.messageMarks(conversationID: conversation.id).replies[turnAsk.id] == quoted,
                    "A reply is saved in the same write that accepts its message")
        let reopened = try LocalChatRepository(url: url).messageMarks(conversationID: conversation.id)
        try require(reopened.reactions[answer.id] == [up, fox], "A fresh repository on the same database returns them in order")
        try require(reopened.replies[ask.id] == MessageReply(answeredID: answer.id, quote: "Here"), "A fresh repository returns the reply")
        try require(try LocalChatRepository(url: url).messageMarks(conversationID: "other").reactions.isEmpty, "Another conversation sees none of them")
    }

    static func rowOffers() throws {
        let emoji = MessageReaction.offered.map(\.emoji)
        try require(emoji == ["\u{2764}\u{FE0F}", "\u{1F44D}", "\u{1F44E}", "\u{203C}\u{FE0F}", "\u{1F602}", "\u{2705}"],
                    "The row offers heart, thumbs up, thumbs down, double exclamation, laughing and check, in that order")
        try require(MessageReaction.offered.map(\.label) == ["Heart", "Thumbs up", "Thumbs down", "Emphasis", "Laugh", "Check"], "The six have names")
        try require(MessageReaction.addLabel == "Add reaction", "The add button is labelled Add reaction")
        try require(MessageActionsMetrics.rowSize.width > MessageActionsMetrics.itemSize * 7, "The row has room for six and the add button")
        let fox = "\u{1F98A}"
        try require(MessageReaction.label(for: fox) == fox, "Any other emoji is read as itself")
        let announced = MessageReaction.onAnnouncement([MessageReaction.heart.emoji, MessageReaction.check.emoji, fox])
        try require(announced == "Heart, Check and \(fox) are on", "The row announces every reaction that is on: \(announced)")
        try require(MessageReaction.onAnnouncement([MessageReaction.laugh.emoji]) == "Laugh is on", "One reaction is announced alone")
        let many = [MessageReaction.heart, .thumbsUp, .emphasis, .laugh, .check].map(\.emoji)
        let shown = MessageReaction.shownMarks(many)
        try require(shown.shown == Array(many.prefix(3)) && shown.more == 2, "The mark draws the first three and counts the rest")
        try require(MessageReaction.emoji(in: fox + "x") == fox && MessageReaction.emoji(in: "a") == nil && MessageReaction.emoji(in: "1") == nil,
                    "Only an emoji counts as a pick")
        try require(MessageReaction.emoji(in: "\u{1F44D}\u{1F3FD}") == "\u{1F44D}\u{1F3FD}", "A skin tone stays with its emoji")
    }

    static func quoteCut() throws {
        let long = String(repeating: "word ", count: 400)
        let cut = MessageReplyQuote.cut(long)
        try require(cut.count == MessageReplyQuote.length && long.hasPrefix(cut), "A long message is cut to the fixed length")
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let emoji = MessageReplyQuote.cut(String(repeating: family, count: 300))
        try require(emoji.count == MessageReplyQuote.length && emoji.allSatisfy { String($0) == family },
                    "The cut lands on a character boundary, never inside an emoji")
        try require(MessageReplyQuote.cut("Two lines\n\nof  text") == "Two lines of text", "The quote reads as one line")
        try require(MessageReplyQuote.cut("Short") == "Short", "A short message is kept whole")
    }

    static func copySweep() throws {
        let banned = ["vera", "background", "worker", "agent", "task", "he", "she", "him", "her", "his", "hers", "himself", "herself"]
        let strings = MessageReplyCopy.added + MessageActions.addedStrings + [MessageReaction.addLabel]
        for text in strings {
            let words = text.lowercased().split { !$0.isLetter }.map(String.init)
            let hit = banned.first { words.contains($0) }
            try require(hit == nil, "\"\(text)\" has no banned word")
            try require(!text.contains("\u{2014}"), "\"\(text)\" has no em dash")
        }
    }

    static func companionStore(transport: NativeSessionFixtureTransport? = nil) throws -> (ChatStore, LocalChatRepository, String) {
        let repository = try LocalChatRepository(inMemory: true)
        let store = ChatStore(nativeConfig: transport == nil ? nil : NativeSessionFixture.config, nativeTransport: transport,
                              repository: repository, artifactPersistenceEnabled: false)
        store.loadDotProfile()
        store.skipDotSetup()
        store.ensureVeraThread()
        guard let threadID = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion conversation exists") }
        return (store, repository, threadID)
    }

    static func place(_ messages: [Message], in store: ChatStore, conversationID: String) throws {
        guard let index = store.conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let start = store.conversations[index].messages.count
        try store.repository?.saveConversation(store.conversations[index])
        for (offset, message) in messages.enumerated() {
            try store.repository?.saveMessage(message, conversationID: conversationID, ordinal: start + offset)
        }
        store.conversations[index].messages += messages
    }

    static func startOverRemovesMarks() throws {
        let (store, repository, threadID) = try companionStore()
        let ask = Message(role: .user, text: "Hello")
        let answer = Message(role: .assistant, text: "Hi there")
        try place([ask, answer], in: store, conversationID: threadID)
        store.toggleReaction(MessageReaction.heart.emoji, on: answer.id)
        try repository.recordReply(MessageReply(answeredID: answer.id, quote: "Hi there"), messageID: ask.id)
        let saved = try repository.database.read { db in try count(db, "message_reactions") == 1 && count(db, "message_replies") == 1 }
        try require(saved, "The reaction and reply are saved")
        store.loadCompanionMarks()
        store.startReply(to: answer)
        let held = store.companionMarks.pending[threadID] != nil && !store.companionMarks.replies.isEmpty
        try require(held, "A pending reply and the saved marks are held before starting over")
        try require(store.resetDot(), "Starting the companion over succeeds")
        try require(store.companionMarks == CompanionMessageMarks(), "Starting over forgets the pending reply and every mark")
        let gone = try repository.database.read { db in try count(db, "message_reactions") == 0 && count(db, "message_replies") == 0 }
        try require(gone, "Starting the companion over removes its reactions and replies through the cascade")
    }

    static func pendingReplyRules() throws {
        let (store, _, threadID) = try companionStore()
        let first = Message(role: .assistant, text: "First answer")
        let second = Message(role: .assistant, text: "Second answer")
        try place([first, second], in: store, conversationID: threadID)
        store.select(threadID)
        let tick = store.focusTick
        store.startReply(to: first)
        try require(store.shownPendingReply == PendingReply(messageID: first.id, quote: "First answer"), "Reply sets the pending reply")
        try require(store.focusTick != tick, "Reply moves focus to the message box")
        store.startReply(to: second)
        try require(store.shownPendingReply?.messageID == second.id && store.companionMarks.pending.count == 1, "A new reply replaces the old one")
        store.cancelReply()
        try require(store.shownPendingReply == nil, "Cancel clears it")
        store.startReply(to: first)
        store.draft = "   "
        store.send()
        try require(store.shownPendingReply?.messageID == first.id, "A refused send keeps the pending reply")
        try require(!store.sendText("   ", conversationID: threadID, reply: store.pendingReplyToSend), "An empty send is refused")
        try require(store.shownPendingReply?.messageID == first.id, "A refused send through the send path keeps it too")

        store.newConversation()
        try require(store.shownPendingReply == nil && store.pendingReplyToSend == nil, "An ordinary chat shows and sends no pending reply")
        let ordinaryID = store.selectedID
        let ordinaryMessage = Message(role: .assistant, text: "Ordinary")
        if let ordinaryID { try place([ordinaryMessage], in: store, conversationID: ordinaryID) }
        store.startReply(to: ordinaryMessage)
        store.toggleReaction(MessageReaction.heart.emoji, on: ordinaryMessage.id)
        try require(store.companionMarks.pending[ordinaryID ?? ""] == nil && store.reactions(on: ordinaryMessage.id).isEmpty,
                    "An ordinary chat's messages take no reply and no reaction")
        store.select(threadID)
        try require(store.shownPendingReply?.messageID == first.id, "Back in the companion's conversation the pending reply is still there")
    }

    static func settle(_ store: ChatStore, _ label: String) async throws {
        try await NativeSessionFixture.eventually(label) {
            let last = store.conversations.flatMap(\.messages).last { $0.role == .assistant }
            let idle = !store.conversationTurns.contains { $0.state == .pending || $0.state == .running }
            return idle && last?.state == .complete
        }
    }

    static func companionRequest() async throws {
        let transport = NativeSessionFixtureTransport()
        let (store, repository, threadID) = try companionStore(transport: transport)
        store.select(threadID)
        try require(store.sendText("Which room is quietest?", conversationID: threadID), "The first message is accepted")
        try await settle(store, "The first answer completes")
        let saved = try repository.messages(conversationID: threadID)
        guard let answer = saved.last(where: { $0.role == .assistant }) else { throw NativeTaskFixture.Failure.assertion("The answer exists") }

        let requests = transport.histories.count
        let turns = store.conversationTurns.count
        let fox = "\u{1F98A}"
        store.toggleReaction(MessageReaction.heart.emoji, on: answer.id)
        store.toggleReaction(fox, on: answer.id)
        try await Task.sleep(for: .milliseconds(150))
        try require(transport.histories.count == requests && store.conversationTurns.count == turns,
                    "A reaction starts no turn and sends nothing")
        try require(try repository.conversationTurns().count == turns, "A reaction saves no turn")

        store.startReply(to: answer)
        store.draft = "Is it open late?"
        store.send()
        try await settle(store, "The reply completes")
        try require(store.shownPendingReply == nil, "A successful send clears the pending reply")
        let request = transport.histories.last ?? []
        let quote = MessageReplyQuote.source(answer)
        let user = request.last { $0.role == "user" }?.content ?? ""
        try require(user == MessageReplyCopy.replyLead(quote) + "\n\nIs it open late?", "The reply carries the lead in for the model: \(user)")
        let reacted = request.first { $0.role == "assistant" && $0.content.hasPrefix(answer.text) }?.content ?? ""
        try require(reacted == answer.text + "\n\n" + MessageReplyCopy.reactionLine([MessageReaction.heart.emoji, fox]),
                    "The reacted message carries the reaction line: \(reacted)")
        let system = request.first { $0.role == "system" }?.content ?? ""
        try require(system.contains(MessageReplyCopy.instruction), "The companion is told what the lines mean")

        let after = try repository.messages(conversationID: threadID)
        guard let sent = after.last(where: { $0.role == .user }) else { throw NativeTaskFixture.Failure.assertion("The reply is saved") }
        try require(sent.text == "Is it open late?", "The saved message is only the typed text")
        try require(after.first { $0.id == answer.id }?.text == answer.text, "The reacted message is saved unchanged")
        try require(MessageActions.copiedText(sent) == "Is it open late?" && MessageActions.selectableText(sent) == "Is it open late?",
                    "Copy and Select text give the typed text only")
        try require(store.companionMarks.replies[sent.id] == MessageReply(answeredID: answer.id, quote: quote), "The chip has its reply")
        try require(try repository.messageMarks(conversationID: threadID).replies[sent.id]?.answeredID == answer.id, "The reply is saved")
        let histories = try repository.conversationTurns().flatMap(\.history).map(\.text)
        let clean = histories.allSatisfy { !$0.contains("(In reply to") && !$0.contains("(Reactions from") }
        try require(clean && histories.contains("Is it open late?"), "The turn's saved history holds no lead in and no reaction line")

        try require(store.sendText("And on weekends?", conversationID: threadID), "A later message is accepted")
        try await settle(store, "The later answer completes")
        let later = transport.histories.last ?? []
        let earlier = later.first { $0.role == "user" && $0.content.hasSuffix("Is it open late?") }?.content ?? ""
        try require(earlier.hasPrefix(MessageReplyCopy.replyLead(quote)), "An earlier reply still in the request keeps its lead in")
        try require(later.last { $0.role == "user" }?.content == "And on weekends?", "A message without a reply has no lead in")
    }

    static func floatingSendLeavesReply() async throws {
        let transport = NativeSessionFixtureTransport()
        let (store, repository, threadID) = try companionStore(transport: transport)
        store.select(threadID)
        let answer = Message(role: .assistant, text: "An earlier answer")
        try place([Message(role: .user, text: "Earlier"), answer], in: store, conversationID: threadID)
        store.startReply(to: answer)
        store.companionDraft = "From the small window"
        try require(store.sendCompanion(), "The floating window sends")
        try await settle(store, "The floating window's answer completes")
        try require(store.shownPendingReply?.messageID == answer.id, "The floating window's send leaves the pending reply alone")
        let sent = try repository.messages(conversationID: threadID).last { $0.role == .user }
        try require(sent.map { store.companionMarks.replies[$0.id] == nil } == true, "The floating window's message has no reply")
        try require(transport.histories.last?.last { $0.role == "user" }?.content == "From the small window", "Its request has no lead in")
    }

    static func ordinaryRun(withMarks: Bool) async throws -> [String] {
        let transport = NativeSessionFixtureTransport()
        let repository = try LocalChatRepository(inMemory: true)
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
                              artifactPersistenceEnabled: false)
        store.newConversation()
        guard let id = store.selectedID else { throw NativeTaskFixture.Failure.assertion("The ordinary chat exists") }
        try require(store.sendText("Which room is quietest?"), "The ordinary chat accepts a message")
        try await settle(store, "The ordinary answer completes")
        let saved = try repository.messages(conversationID: id)
        if withMarks, let ask = saved.first(where: { $0.role == .user }), let answer = saved.last(where: { $0.role == .assistant }) {
            _ = try repository.toggleReaction(MessageReaction.heart.emoji, messageID: answer.id)
            try repository.recordReply(MessageReply(answeredID: answer.id, quote: "Quoted"), messageID: ask.id)
            store.startReply(to: answer)
            store.toggleReaction(MessageReaction.laugh.emoji, on: answer.id)
        }
        store.draft = "Is it open late?"
        store.send()
        try await settle(store, "The second ordinary answer completes")
        let request = transport.histories.last ?? []
        return request.map { message in
            let content = message.content.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("Current date and time:") }.joined(separator: "\n")
            return message.role + ":" + content
        }
    }

    static func ordinaryRequestUnchanged() async throws {
        let plain = try await ordinaryRun(withMarks: false)
        let marked = try await ordinaryRun(withMarks: true)
        try require(!plain.isEmpty && plain == marked, "An ordinary chat with reaction and reply rows sends the same request as one without")
        try require(!marked.joined().contains("(Reactions from") && !marked.joined().contains("(In reply to"), "An ordinary request has neither line")
        try require(!marked.joined().contains(MessageReplyCopy.instruction), "An ordinary chat is not told about reactions")
    }
}
