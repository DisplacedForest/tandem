import Foundation
import GRDB

struct MessageReply: Equatable, Sendable {
    let answeredID: UUID
    let quote: String
}

struct PendingReply: Equatable, Sendable {
    let messageID: UUID
    let quote: String
}

struct CompanionMessageMarks: Equatable {
    var reactions: [UUID: [String]] = [:]
    var replies: [UUID: MessageReply] = [:]
    var pending: [String: PendingReply] = [:]
}

enum MessageReplyQuote {
    static let length = 160

    static func cut(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(flat.prefix(length))
    }

    static func source(_ message: Message) -> String {
        cut(MessageActions.selectableText(message))
    }
}

enum MessageReplyCopy {
    static let chipLead = "In reply to: "
    static let barLead = "Replying to: "
    static let cancel = "Cancel reply"
    static let symbol = "arrowshape.turn.up.left"
    static let cancelSymbol = "xmark"
    static let reactionFailed = "The reaction couldn't save."
    static let replyFailed = "The reply couldn't save."
    static let instruction = "A line in parentheses after a message naming reactions shows how the person you are talking with reacted to it, and a lead in that starts with \"In reply to the earlier message\" quotes the start of the message they are answering. A reaction alone needs no answer."

    static func reactionLine(_ marks: [String]) -> String {
        "(Reactions from the person you are talking with: " + marks.joined(separator: " ") + ")"
    }

    static func replyLead(_ quote: String) -> String {
        "(In reply to the earlier message that began: \"" + quote + "\")"
    }

    static var added: [String] {
        [chipLead, barLead, cancel, symbol, cancelSymbol, reactionFailed, replyFailed, instruction,
         reactionLine(["x"]), replyLead("x")]
    }
}

enum MessageReactionStore {
    static let migration = "messageReactionsV41"

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE message_reactions (
                message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                emoji TEXT NOT NULL,
                created_at DOUBLE NOT NULL,
                PRIMARY KEY(message_id, emoji)
            );
            CREATE TABLE message_replies (
                message_id TEXT PRIMARY KEY NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                answered_id TEXT NOT NULL,
                quote TEXT NOT NULL
            );
            """)
    }

    static func reactions(_ db: Database, messageID: UUID) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT emoji FROM message_reactions WHERE message_id = ? ORDER BY created_at, rowid",
                            arguments: [messageID.uuidString])
    }
}

extension LocalChatRepository {
    func messageMarks(conversationID: String) throws -> (reactions: [UUID: [String]], replies: [UUID: MessageReply]) {
        try database.read { db in
            var reactions: [UUID: [String]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT r.message_id AS message_id, r.emoji AS emoji FROM message_reactions r JOIN messages m ON m.id = r.message_id
                WHERE m.conversation_id = ? ORDER BY r.created_at, r.rowid
                """, arguments: [conversationID]) {
                guard let id = UUID(uuidString: row["message_id"]) else { continue }
                reactions[id, default: []].append(row["emoji"])
            }
            var replies: [UUID: MessageReply] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT r.message_id AS message_id, r.answered_id AS answered_id, r.quote AS quote
                FROM message_replies r JOIN messages m ON m.id = r.message_id WHERE m.conversation_id = ?
                """, arguments: [conversationID]) {
                guard let id = UUID(uuidString: row["message_id"]), let answered = UUID(uuidString: row["answered_id"]) else { continue }
                replies[id] = MessageReply(answeredID: answered, quote: row["quote"])
            }
            return (reactions, replies)
        }
    }

    func toggleReaction(_ emoji: String, messageID: UUID, at date: Date = Date()) throws -> [String] {
        try database.write { db in
            try db.execute(sql: "DELETE FROM message_reactions WHERE message_id = ? AND emoji = ?", arguments: [messageID.uuidString, emoji])
            if db.changesCount == 0 {
                try db.execute(sql: "INSERT INTO message_reactions(message_id, emoji, created_at) VALUES (?, ?, ?)",
                               arguments: [messageID.uuidString, emoji, date.timeIntervalSince1970])
            }
            return try MessageReactionStore.reactions(db, messageID: messageID)
        }
    }

    func addReaction(_ emoji: String, messageID: UUID, at date: Date = Date()) throws -> [String] {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO message_reactions(message_id, emoji, created_at) VALUES (?, ?, ?)
                ON CONFLICT(message_id, emoji) DO NOTHING
                """, arguments: [messageID.uuidString, emoji, date.timeIntervalSince1970])
            return try MessageReactionStore.reactions(db, messageID: messageID)
        }
    }

    func recordReply(_ reply: MessageReply, messageID: UUID) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO message_replies(message_id, answered_id, quote) VALUES (?, ?, ?)
                ON CONFLICT(message_id) DO UPDATE SET answered_id = excluded.answered_id, quote = excluded.quote
                """, arguments: [messageID.uuidString, reply.answeredID.uuidString, reply.quote])
        }
    }
}

@MainActor
extension ChatStore {
    func loadCompanionMarks() {
        guard let veraThreadID, let local = repository as? LocalChatRepository,
              let loaded = try? local.messageMarks(conversationID: veraThreadID) else { return }
        companionMarks.reactions = loaded.reactions
        companionMarks.replies = loaded.replies
    }

    func reactions(on messageID: UUID) -> [String] {
        companionMarks.reactions[messageID] ?? []
    }

    func companionMessage(_ messageID: UUID) -> Message? {
        guard let veraThreadID else { return nil }
        return conversations.first { $0.id == veraThreadID }?.messages.first { $0.id == messageID }
    }

    func toggleReaction(_ emoji: String, on messageID: UUID) {
        changeReaction(emoji, on: messageID, adding: false)
    }

    func addReaction(_ emoji: String, on messageID: UUID) {
        changeReaction(emoji, on: messageID, adding: true)
    }

    private func changeReaction(_ emoji: String, on messageID: UUID, adding: Bool) {
        guard companionMessage(messageID) != nil else { return }
        let current = reactions(on: messageID)
        let next: [String]
        if let local = repository as? LocalChatRepository {
            do {
                next = adding ? try local.addReaction(emoji, messageID: messageID) : try local.toggleReaction(emoji, messageID: messageID)
            } catch {
                chatConfigurationError = MessageReplyCopy.reactionFailed
                return
            }
        } else if current.contains(emoji) {
            next = adding ? current : current.filter { $0 != emoji }
        } else {
            next = current + [emoji]
        }
        companionMarks.reactions[messageID] = next.isEmpty ? nil : next
    }

    func startReply(to message: Message) {
        guard let veraThreadID, companionMessage(message.id) != nil else { return }
        companionMarks.pending[veraThreadID] = PendingReply(messageID: message.id, quote: MessageReplyQuote.source(message))
        focusTick &+= 1
    }

    func cancelReply() {
        guard let selectedID else { return }
        companionMarks.pending[selectedID] = nil
    }

    var shownPendingReply: PendingReply? {
        guard isVeraThread(selectedID), let selectedID else { return nil }
        return companionMarks.pending[selectedID]
    }

    var pendingReplyToSend: PendingReply? { shownPendingReply }

    func recordReply(_ pending: PendingReply, messageID: UUID, conversationID: String) {
        guard isVeraThread(conversationID) else { return }
        let reply = MessageReply(answeredID: pending.messageID, quote: pending.quote)
        if let local = repository as? LocalChatRepository {
            do { try local.recordReply(reply, messageID: messageID) } catch { chatConfigurationError = MessageReplyCopy.replyFailed }
        }
        companionMarks.replies[messageID] = reply
        if companionMarks.pending[conversationID] == pending { companionMarks.pending[conversationID] = nil }
    }

    func companionRequestMessages(_ messages: [Message], turn: NativeConversationTurn) -> [Message] {
        guard isVeraThread(turn.conversationID), let local = repository as? LocalChatRepository,
              let marks = try? local.messageMarks(conversationID: turn.conversationID) else { return messages }
        return MessageRequestNotes.apply(messages, reactions: marks.reactions, replies: marks.replies)
    }
}

enum MessageRequestNotes {
    static func apply(_ messages: [Message], reactions: [UUID: [String]], replies: [UUID: MessageReply]) -> [Message] {
        messages.map { message in
            var copy = message
            if message.role == .user, let reply = replies[message.id] {
                copy.text = MessageReplyCopy.replyLead(reply.quote) + "\n\n" + copy.text
            }
            if let marks = reactions[message.id], !marks.isEmpty {
                copy.text += "\n\n" + MessageReplyCopy.reactionLine(marks)
            }
            return copy
        }
    }
}
