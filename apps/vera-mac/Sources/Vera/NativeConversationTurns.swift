import CryptoKit
import Darwin
import Foundation
import GRDB

enum NativeSessionMode: String, Codable, CaseIterable, Sendable {
    case chat
    case continuous

    var title: String { self == .chat ? "Chat" : "Continuous" }
    var detail: String {
        self == .chat ? "One answer at a time. Later messages wait in this chat."
            : "Keep talking while research continues in the background."
    }
}

struct NativeTurnHistoryMessage: Codable, Sendable {
    let id: UUID
    let role: String
    let text: String
    let attachments: [MessageAttachment]
    var routeNote: MessageRouteNote?
    let activities: [NativeToolActivity]

    init(_ message: Message) {
        id = message.id
        role = message.role.rawValue
        text = message.text
        attachments = message.attachments
        routeNote = message.routeNote
        activities = message.toolActivities
    }

    var message: Message {
        Message(id: id, role: Message.Role(rawValue: role) ?? .user, text: text,
                attachments: attachments, toolActivities: activities, routeNote: routeNote)
    }

    static func snapshot(_ messages: [Message], current: Message, mode: NativeSessionMode = .chat) -> [Self] {
        var history: [Message] = []
        for (index, message) in messages.enumerated() where message.state == .complete {
            if message.role == .user {
                guard messages.indices.contains(index + 1),
                      messages[index + 1].role == .assistant,
                      messages[index + 1].state == .complete else {
                    if mode == .continuous {
                        history.append(Message(id: message.id, role: .user,
                            text: "[Earlier accepted request without a completed answer] " + message.text))
                    }
                    continue
                }
            }
            history.append(message)
        }
        return (history + [current]).map(Self.init)
    }
}

struct NativeConversationTurn: Codable, Sendable, Identifiable {
    enum State: String, Codable, Sendable { case pending, running, complete, interrupted, stopped }
    let id: UUID
    let conversationID: String
    let userMessageID: UUID
    let assistantMessageID: UUID
    let mode: NativeSessionMode
    let profile: String
    let enabledToolIDs: Set<String>
    let persona: String
    let userScope: String
    let instructions: String
    let grounding: [String]
    let memorySettings: NativeMemorySettings
    let createdAt: Date
    var history: [NativeTurnHistoryMessage]
    var state: State = .pending
    var attempt: UUID?
    var ownerPID: Int32?
    var ownerBirth: String?
    var mayHaveEffect = false

    static func processBirth(_ pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return "\(info.kp_proc.p_starttime.tv_sec):\(info.kp_proc.p_starttime.tv_usec)"
    }

    static let maximumActive = 2
    static let maximumPending = 8

    static func fingerprint(_ config: NativeChatConfig?) -> String {
        guard let config else { return "unconfigured" }
        let object: [String: Any] = [
            "base": config.baseURL.absoluteString, "model": config.model,
            "template": config.chatTemplateKwargs ?? "", "streaming": config.streaming,
            "topLevel": Dictionary(uniqueKeysWithValues: config.options.topLevel.map { ($0.key, $0.value.any) }),
            "kwargs": Dictionary(uniqueKeysWithValues: config.options.kwargs.map { ($0.key, $0.value.any) }),
            "streamingOverride": config.options.streamingOverride.map { $0 as Any } ?? NSNull(),
            "contextCeiling": config.options.contextCeiling.map { $0 as Any } ?? NSNull(),
        ]
        let value = String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct NativeConversationTurnHeader: Equatable, Sendable {
    let id: UUID
    let conversationID: String
    let state: String
    let attempt: String?
}

protocol NativeConversationTurnRepository: Sendable {
    func conversationTurns() throws -> [NativeConversationTurn]
    func conversationTurnChangeToken() throws -> [Int64]
    func conversationTurnHeaders() throws -> [NativeConversationTurnHeader]
    func pollConversationTurns(watching: Set<UUID>) throws -> [NativeConversationTurn]
    func acceptTurn(_ turn: NativeConversationTurn, conversation: Conversation, user: Message, reply: Message) throws
    func claimTurn(_ id: UUID, attempt: UUID) throws -> NativeConversationTurn?
    func enrollLegacyTurn(_ turn: NativeConversationTurn) throws
    func turnIsCurrent(_ id: UUID, attempt: UUID) throws -> Bool
    func markTurnDispatch(_ id: UUID, attempt: UUID, activity: NativeToolActivity) throws
    func checkpointTurn(_ turn: NativeConversationTurn, message: Message, ordinal: Int) throws
    func finishTurn(_ id: UUID, attempt: UUID?, state: NativeConversationTurn.State, message: Message, ordinal: Int) throws
    func retryTurn(_ id: UUID, profile: String) throws
}

extension LocalChatRepository: NativeConversationTurnRepository {
    static func migrateConversationTurns(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE conversations ADD COLUMN session_mode TEXT NOT NULL DEFAULT 'chat';
            CREATE TABLE native_conversation_turns (
                id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                user_message_id TEXT NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
                assistant_message_id TEXT NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
                mode TEXT NOT NULL,
                state TEXT NOT NULL,
                attempt TEXT,
                owner_pid INTEGER,
                created_at DOUBLE NOT NULL,
                record_json TEXT NOT NULL
            );
            CREATE INDEX native_conversation_turn_queue ON native_conversation_turns(state, created_at);
            """)
    }

    static func recoverConversationTurns(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT record_json FROM native_conversation_turns WHERE state = 'running'")
        for row in rows {
            var turn = try JSONDecoder().decode(NativeConversationTurn.self, from: Data((row["record_json"] as String).utf8))
            if let pid = turn.ownerPID, pid > 0 {
                let alive = kill(pid, 0) == 0 || errno == EPERM
                let currentBirth = NativeConversationTurn.processBirth(pid)
                if alive && (turn.ownerBirth == nil || currentBirth == nil || turn.ownerBirth == currentBirth) { continue }
            }
            turn.state = .interrupted
            let failure = turn.mayHaveEffect
                ? "Vera closed before this answer finished. An action already sent may have completed; check it before trying again."
                : "Vera closed before this answer finished. You can retry it."
            try db.execute(sql: "UPDATE messages SET state='interrupted', failure=? WHERE id=?",
                arguments: [failure, turn.assistantMessageID.uuidString])
            try writeTurn(turn, db: db)
        }
    }

    static func writeTurn(_ turn: NativeConversationTurn, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO native_conversation_turns
                (id, conversation_id, user_message_id, assistant_message_id, mode, state, attempt, owner_pid, created_at, record_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET state=excluded.state, attempt=excluded.attempt,
                owner_pid=excluded.owner_pid, record_json=excluded.record_json
            """, arguments: [turn.id.uuidString, turn.conversationID, turn.userMessageID.uuidString,
                turn.assistantMessageID.uuidString, turn.mode.rawValue, turn.state.rawValue,
                turn.attempt?.uuidString, turn.ownerPID, turn.createdAt.timeIntervalSince1970,
                String(decoding: try JSONEncoder().encode(turn), as: UTF8.self)])
    }

    static func readTurn(_ id: UUID, db: Database) throws -> NativeConversationTurn? {
        guard let raw = try String.fetchOne(db, sql: "SELECT record_json FROM native_conversation_turns WHERE id=?",
                                           arguments: [id.uuidString]) else { return nil }
        return try JSONDecoder().decode(NativeConversationTurn.self, from: Data(raw.utf8))
    }

    func conversationTurns() throws -> [NativeConversationTurn] {
        try database.write { db in
            try Self.recoverConversationTurns(db)
            return try String.fetchAll(db, sql: "SELECT record_json FROM native_conversation_turns ORDER BY created_at, rowid")
                .map { try JSONDecoder().decode(NativeConversationTurn.self, from: Data($0.utf8)) }
        }
    }

    func conversationTurnChangeToken() throws -> [Int64] {
        try database.read { db in
            [try Int64.fetchOne(db, sql: "PRAGMA data_version") ?? 0,
             try Int64.fetchOne(db, sql: "SELECT total_changes()") ?? 0]
        }
    }

    func conversationTurnHeaders() throws -> [NativeConversationTurnHeader] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, conversation_id, state, attempt FROM native_conversation_turns").map {
                NativeConversationTurnHeader(id: UUID(uuidString: $0["id"])!, conversationID: $0["conversation_id"],
                    state: $0["state"], attempt: $0["attempt"])
            }
        }
    }

    func pollConversationTurns(watching: Set<UUID>) throws -> [NativeConversationTurn] {
        try database.write { db in
            try Self.recoverConversationTurns(db)
            let placeholders = watching.map { _ in "?" }.joined(separator: ",")
            let extra = watching.isEmpty ? "" : " OR id IN (\(placeholders))"
            return try String.fetchAll(db,
                sql: "SELECT record_json FROM native_conversation_turns WHERE state IN ('pending','running')\(extra) ORDER BY created_at, rowid",
                arguments: StatementArguments(watching.map(\.uuidString)))
                .map { try JSONDecoder().decode(NativeConversationTurn.self, from: Data($0.utf8)) }
        }
    }

    func acceptTurn(_ turn: NativeConversationTurn, conversation: Conversation, user: Message, reply: Message) throws {
        try database.write { db in
            if try Self.readTurn(turn.id, db: db) != nil { return }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_conversation_turns WHERE state='pending'") ?? 0
            guard count < NativeConversationTurn.maximumPending else {
                throw NativeToolError.failed("Eight messages are already waiting. Your draft is kept; stop a waiting answer or send it when there is space.")
            }
            try Self.saveConversation(conversation, db: db)
            let ordinal = (try Int.fetchOne(db, sql: "SELECT MAX(ordinal) FROM messages WHERE conversation_id=?",
                                           arguments: [conversation.id]) ?? -1) + 1
            try Self.saveMessage(user, conversationID: conversation.id, ordinal: ordinal, db: db)
            try Self.saveMessage(reply, conversationID: conversation.id, ordinal: ordinal + 1, db: db)
            try Self.writeTurn(turn, db: db)
        }
    }

    func enrollLegacyTurn(_ turn: NativeConversationTurn) throws {
        try database.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_conversation_turns WHERE state='pending'") ?? 0
            guard count < NativeConversationTurn.maximumPending else {
                throw NativeToolError.failed("Eight messages are already waiting. Try again when there is space.")
            }
            let user = try String.fetchOne(db, sql: "SELECT conversation_id FROM messages WHERE id=? AND role='user'",
                                          arguments: [turn.userMessageID.uuidString])
            let reply = try String.fetchOne(db, sql: "SELECT conversation_id FROM messages WHERE id=? AND role='assistant' AND state='interrupted'",
                                           arguments: [turn.assistantMessageID.uuidString])
            guard user == turn.conversationID, reply == turn.conversationID else { throw CancellationError() }
            try Self.writeTurn(turn, db: db)
            try db.execute(sql: "UPDATE messages SET state='streaming', failure=NULL WHERE id=?", arguments: [turn.assistantMessageID.uuidString])
        }
    }

    func claimTurn(_ id: UUID, attempt: UUID) throws -> NativeConversationTurn? {
        try database.write { db in
            guard var turn = try Self.readTurn(id, db: db), turn.state == .pending else { return nil }
            let active = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_conversation_turns WHERE state='running'") ?? 0
            guard active < NativeConversationTurn.maximumActive else { return nil }
            let same = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM native_conversation_turns WHERE state='running' AND conversation_id=?
                    AND (mode='chat' OR ?='chat')
                """, arguments: [turn.conversationID, turn.mode.rawValue]) ?? 0
            guard same == 0 else { return nil }
            let earlier = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM native_conversation_turns WHERE conversation_id=? AND state='pending'
                    AND rowid < (SELECT rowid FROM native_conversation_turns WHERE id=?)
                """, arguments: [turn.conversationID, turn.id.uuidString]) ?? 0
            guard earlier == 0 else { return nil }
            if turn.mode == .chat {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM messages WHERE conversation_id=? AND ordinal <
                        (SELECT ordinal FROM messages WHERE id=?) ORDER BY ordinal
                    """, arguments: [turn.conversationID, turn.userMessageID.uuidString])
                let currentRows = try Row.fetchAll(db, sql: "SELECT * FROM messages WHERE id=?",
                                                  arguments: [turn.userMessageID.uuidString])
                guard let user = Self.decodeMessages(currentRows).first else { throw CancellationError() }
                turn.history = NativeTurnHistoryMessage.snapshot(Self.decodeMessages(rows), current: user)
            }
            turn.state = .running
            turn.attempt = attempt
            turn.ownerPID = getpid()
            turn.ownerBirth = NativeConversationTurn.processBirth(getpid())
            try Self.writeTurn(turn, db: db)
            return turn
        }
    }

    func turnIsCurrent(_ id: UUID, attempt: UUID) throws -> Bool {
        try database.read { db in
            let turn = try Self.readTurn(id, db: db)
            return turn?.state == .running && turn?.attempt == attempt
        }
    }

    func markTurnDispatch(_ id: UUID, attempt: UUID, activity: NativeToolActivity) throws {
        try database.write { db in
            guard var turn = try Self.readTurn(id, db: db), turn.state == .running, turn.attempt == attempt else {
                throw CancellationError()
            }
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM messages WHERE id=?", arguments: [turn.assistantMessageID.uuidString])
            guard var message = Self.decodeMessages(rows).first, let ordinal: Int = rows.first?["ordinal"] else {
                throw CancellationError()
            }
            if let index = message.toolActivities.firstIndex(where: { $0.id == activity.id }) { message.toolActivities[index] = activity }
            else { message.toolActivities.append(activity) }
            turn.mayHaveEffect = turn.mayHaveEffect || !NativeTurnSafety.canReplay(activity)
            try Self.saveMessage(message, conversationID: turn.conversationID, ordinal: ordinal, db: db)
            try Self.writeTurn(turn, db: db)
        }
    }

    func checkpointTurn(_ turn: NativeConversationTurn, message: Message, ordinal: Int) throws {
        try database.write { db in
            guard let saved = try Self.readTurn(turn.id, db: db), saved.state == .running,
                  saved.attempt == turn.attempt else { throw CancellationError() }
            try Self.saveMessage(message, conversationID: turn.conversationID, ordinal: ordinal, db: db)
        }
    }

    func finishTurn(_ id: UUID, attempt: UUID?, state: NativeConversationTurn.State, message: Message, ordinal: Int) throws {
        try database.write { db in
            guard var turn = try Self.readTurn(id, db: db), turn.state == .pending || turn.state == .running,
                  (attempt == nil ? turn.state == .pending : turn.attempt == attempt) else { throw CancellationError() }
            turn.state = state
            try Self.saveMessage(message, conversationID: turn.conversationID, ordinal: ordinal, db: db)
            try Self.writeTurn(turn, db: db)
        }
    }

    func retryTurn(_ id: UUID, profile: String) throws {
        try database.write { db in
            guard var turn = try Self.readTurn(id, db: db), turn.state == .interrupted || turn.state == .stopped else { return }
            guard !turn.mayHaveEffect else {
                throw NativeToolError.failed("Check whether the earlier action completed, then send a new message. It won't be replayed.")
            }
            guard turn.profile == profile else {
                throw NativeToolError.failed("This answer was saved with different settings. Send a new message to use the current settings.")
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_conversation_turns WHERE state='pending'") ?? 0
            guard count < NativeConversationTurn.maximumPending else {
                throw NativeToolError.failed("Eight messages are already waiting. Try again when there is space.")
            }
            turn.state = .pending
            turn.attempt = nil
            turn.ownerPID = nil
            try Self.writeTurn(turn, db: db)
            try db.execute(sql: "UPDATE messages SET state='streaming', failure=NULL WHERE id=?",
                           arguments: [turn.assistantMessageID.uuidString])
        }
    }
}

enum NativeTurnSafety {
    static let replayableIDs: Set<String> = [NativeWebTools.searchToolID, NativeWebTools.researchToolID, NativeTaskTools.toolID]
    static func canReplay(_ activity: NativeToolActivity) -> Bool {
        switch (activity.toolID, activity.name) {
        case (NativeWebTools.searchToolID, "web_search"), (NativeWebTools.researchToolID, "deep_research"),
             (NativeTaskTools.toolID, "create_background_task"), ("apple-reminders", "apple_reminders_list"),
             ("apple-reminders", "apple_reminders_get_lists"): return true
        default: return false
        }
    }
}
