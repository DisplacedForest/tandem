import Foundation
import GRDB

struct NativeInstructionSpend: Equatable, Sendable {
    let messageID: UUID
    let conversationID: String
    let signature: String
    let holder: String
}

struct NativeInstructionUseStore: Sendable {
    static let migration = "nativeInstructionUsesV42"

    let database: DatabaseQueue

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_instruction_uses (
                message_id TEXT NOT NULL,
                signature TEXT NOT NULL,
                conversation_id TEXT NOT NULL,
                holder TEXT NOT NULL,
                created_at DOUBLE NOT NULL,
                PRIMARY KEY(message_id, signature)
            );
            CREATE INDEX native_instruction_uses_conversation ON native_instruction_uses(conversation_id);
            """)
    }

    static func spend(_ db: Database, _ spend: NativeInstructionSpend, at date: Date) throws -> Bool {
        try db.execute(sql: """
            INSERT INTO native_instruction_uses(message_id, signature, conversation_id, holder, created_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(message_id, signature) DO NOTHING
            """, arguments: [spend.messageID.uuidString, spend.signature, spend.conversationID, spend.holder, date.timeIntervalSince1970])
        if db.changesCount == 1 { return true }
        let holder = try String.fetchOne(db, sql: "SELECT holder FROM native_instruction_uses WHERE message_id = ? AND signature = ?",
                                         arguments: [spend.messageID.uuidString, spend.signature])
        return !spend.holder.isEmpty && holder == spend.holder
    }

    static func remove(_ db: Database, conversationID: String) throws {
        try db.execute(sql: "DELETE FROM native_instruction_uses WHERE conversation_id = ?", arguments: [conversationID])
    }

    static func origin(_ db: Database, taskID: String) throws -> NativeTaskOrigin? {
        guard try db.tableExists("native_task_outbox"), try db.tableExists("native_engine_tasks"),
              let bytes = try Data.fetchOne(db, sql: """
                SELECT o.reference_json FROM native_engine_tasks t JOIN native_task_outbox o ON o.id = t.creation_key WHERE t.id = ?
                """, arguments: [taskID]) else { return nil }
        return try JSONDecoder().decode(NativeTaskReference.self, from: bytes).origin
    }

    func take(_ messageID: UUID, conversationID: String, signature: String, holder: String, at date: Date = Date()) -> Bool {
        let spend = NativeInstructionSpend(messageID: messageID, conversationID: conversationID, signature: signature, holder: holder)
        return (try? database.write { db in try Self.spend(db, spend, at: date) }) ?? false
    }

    func used(_ messageID: UUID, signature: String, excluding holder: String?) -> Bool {
        do {
            return try database.read { db in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM native_instruction_uses WHERE message_id = ? AND signature = ? AND (? IS NULL OR holder != ?))
                    """, arguments: [messageID.uuidString, signature, holder, holder]) ?? true
            }
        } catch {
            return true
        }
    }

    func origin(taskID: String) -> NativeTaskOrigin? {
        try? database.read { db in try Self.origin(db, taskID: taskID) }
    }
}
