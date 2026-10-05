import Foundation
import GRDB

struct NativeTaskStreamLease: Equatable, Sendable {
    let engine: NativeTaskEngineIdentity
    let token: UUID
    let instanceID: UUID
    let cursor: Int64
}

struct NativeTaskSavedProjection: Sendable {
    let referenceID: UUID
    let snapshot: NativeTaskSnapshot?
    let cursor: Int64
    let connectionNote: String?
}

struct NativeTaskMessageUpdate: Sendable {
    let conversationID: String
    let messageID: UUID
    let blocks: [NativeDisplayBlock]
}

protocol NativeTaskProjectionRepository: NativeTaskRepository {
    func claimTaskStream(engine: NativeTaskEngineIdentity, instanceID: UUID) throws -> NativeTaskStreamLease
    func releaseTaskStream(_ lease: NativeTaskStreamLease) throws
    func taskStreamIsCurrent(_ lease: NativeTaskStreamLease) throws -> Bool
    func saveTaskCursor(_ cursor: Int64, lease: NativeTaskStreamLease, reset: Bool) throws
    func taskProjection(id: UUID) throws -> NativeTaskSavedProjection?
    func beginTaskRefresh(id: UUID, lease: NativeTaskStreamLease) throws -> Int64
    func projectTask(id: UUID, snapshot: NativeTaskSnapshot?, cursor: Int64,
                     connectionNote: String?, lease: NativeTaskStreamLease?, generation: Int64?) throws -> NativeTaskMessageUpdate?
    func prepareTaskRetry(id: UUID, decisionID: String) throws -> NativeTaskDecisionIntent
    func pendingTaskRetries() throws -> [NativeTaskDecisionIntent]
    func resolveTaskRetry(_ intent: NativeTaskDecisionIntent) throws
}

extension LocalChatRepository: NativeTaskProjectionRepository {
    static func migrateNativeTaskDisplay(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE messages ADD COLUMN spoken_text TEXT;
            ALTER TABLE messages ADD COLUMN display_blocks_json BLOB;
            CREATE TABLE native_task_projections (
                reference_id TEXT PRIMARY KEY NOT NULL REFERENCES native_task_outbox(id),
                message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                snapshot_json BLOB,
                cursor INTEGER NOT NULL DEFAULT 0,
                connection_note TEXT,
                request_generation INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE native_task_streams (
                engine TEXT PRIMARY KEY NOT NULL,
                cursor INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE native_task_stream_sessions (
                engine TEXT NOT NULL,
                instance_id TEXT NOT NULL,
                token TEXT NOT NULL,
                PRIMARY KEY(engine, instance_id)
            );
            CREATE TABLE native_task_retries (
                reference_id TEXT NOT NULL REFERENCES native_task_outbox(id),
                message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                decision_id TEXT NOT NULL,
                reply_key TEXT NOT NULL,
                pending INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY(reference_id, decision_id)
            );
            """)
    }

    func claimTaskStream(engine: NativeTaskEngineIdentity, instanceID: UUID) throws -> NativeTaskStreamLease {
        try database.write { db in
            let cursor = try Int64.fetchOne(db, sql: "SELECT cursor FROM native_task_streams WHERE engine = ?",
                                            arguments: [engine.base.absoluteString]) ?? 0
            let token = UUID()
            try db.execute(sql: """
                INSERT INTO native_task_streams(engine, cursor) VALUES (?, ?) ON CONFLICT(engine) DO NOTHING
                """, arguments: [engine.base.absoluteString, cursor])
            try db.execute(sql: """
                INSERT INTO native_task_stream_sessions(engine, instance_id, token) VALUES (?, ?, ?)
                ON CONFLICT(engine, instance_id) DO UPDATE SET token = excluded.token
                """, arguments: [engine.base.absoluteString, instanceID.uuidString, token.uuidString])
            return NativeTaskStreamLease(engine: engine, token: token, instanceID: instanceID, cursor: cursor)
        }
    }

    func taskStreamIsCurrent(_ lease: NativeTaskStreamLease) throws -> Bool {
        try database.read { db in
            let token = try String.fetchOne(db, sql: "SELECT token FROM native_task_stream_sessions WHERE engine = ? AND instance_id = ?",
                arguments: [lease.engine.base.absoluteString, lease.instanceID.uuidString])
            return token == lease.token.uuidString
        }
    }

    func releaseTaskStream(_ lease: NativeTaskStreamLease) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM native_task_stream_sessions WHERE engine = ? AND instance_id = ? AND token = ?",
                           arguments: [lease.engine.base.absoluteString, lease.instanceID.uuidString, lease.token.uuidString])
        }
    }

    func saveTaskCursor(_ cursor: Int64, lease: NativeTaskStreamLease, reset: Bool = false) throws {
        guard cursor >= 0 else { throw NativeTaskError.invalidResponse }
        try database.write { db in
            try Self.requireTaskLease(db, lease: lease)
            if reset {
                let rows = try Row.fetchAll(db, sql: "SELECT id, reference_json FROM native_task_outbox WHERE reference_json IS NOT NULL")
                for row in rows {
                    let bytes: Data = row["reference_json"]
                    let reference = try JSONDecoder().decode(NativeTaskReference.self, from: bytes)
                    if reference.engine == lease.engine {
                        try db.execute(sql: "UPDATE native_task_projections SET cursor = 0, request_generation = request_generation + 1 WHERE reference_id = ?",
                                       arguments: [reference.id.uuidString])
                    }
                }
            }
            try db.execute(sql: reset
                ? "UPDATE native_task_streams SET cursor = ? WHERE engine = ?"
                : "UPDATE native_task_streams SET cursor = MAX(cursor, ?) WHERE engine = ?",
                arguments: [cursor, lease.engine.base.absoluteString])
            if reset {
                try db.execute(sql: "DELETE FROM native_task_stream_sessions WHERE engine = ?",
                               arguments: [lease.engine.base.absoluteString])
            }
        }
    }

    static func requireTaskLease(_ db: Database, lease: NativeTaskStreamLease) throws {
        let token = try String.fetchOne(db, sql: "SELECT token FROM native_task_stream_sessions WHERE engine = ? AND instance_id = ?",
                                        arguments: [lease.engine.base.absoluteString, lease.instanceID.uuidString])
        guard token == lease.token.uuidString else { throw CancellationError() }
    }

    func beginTaskRefresh(id: UUID, lease: NativeTaskStreamLease) throws -> Int64 {
        try database.write { db in
            try Self.requireTaskLease(db, lease: lease)
            guard let reference = try Self.readTaskReference(db, id: id), reference.engine == lease.engine else {
                throw NativeTaskError.engineChanged
            }
            try db.execute(sql: "UPDATE native_task_projections SET request_generation = request_generation + 1 WHERE reference_id = ?",
                           arguments: [id.uuidString])
            guard let generation = try Int64.fetchOne(db,
                sql: "SELECT request_generation FROM native_task_projections WHERE reference_id = ?", arguments: [id.uuidString]) else {
                throw NativeTaskError.persistenceUnavailable
            }
            return generation
        }
    }

    func taskProjection(id: UUID) throws -> NativeTaskSavedProjection? {
        try database.read { db in try Self.readTaskProjection(db, id: id) }
    }

    static func readTaskProjection(_ db: Database, id: UUID) throws -> NativeTaskSavedProjection? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM native_task_projections WHERE reference_id = ?",
                                        arguments: [id.uuidString]) else { return nil }
        let bytes: Data? = row["snapshot_json"]
        return NativeTaskSavedProjection(referenceID: id,
            snapshot: try bytes.map { try JSONDecoder().decode(NativeTaskSnapshot.self, from: $0) },
            cursor: row["cursor"], connectionNote: row["connection_note"])
    }

    func projectTask(id: UUID, snapshot: NativeTaskSnapshot?, cursor: Int64 = 0,
                     connectionNote: String? = nil, lease: NativeTaskStreamLease? = nil,
                     generation: Int64? = nil) throws -> NativeTaskMessageUpdate? {
        try database.write { db in
            if let lease { try Self.requireTaskLease(db, lease: lease) }
            guard var reference = try Self.readTaskReference(db, id: id) else { return nil }
            if let generation {
                let current = try Int64.fetchOne(db,
                    sql: "SELECT request_generation FROM native_task_projections WHERE reference_id = ?", arguments: [id.uuidString])
                guard current == generation else { throw CancellationError() }
            }
            if let lease, reference.engine != lease.engine { throw NativeTaskError.engineChanged }
            guard let row = try Row.fetchOne(db, sql: """
                SELECT spoken_text, display_blocks_json FROM messages WHERE id = ? AND conversation_id = ?
                """, arguments: [reference.origin.assistantMessageID.uuidString, reference.origin.conversationID]) else { return nil }
            let previous = try Self.readTaskProjection(db, id: id)
            var canonical = snapshot ?? previous?.snapshot
            if previous?.snapshot?.state.isTerminal == true { canonical = previous?.snapshot }
            else if reference.snapshot?.state.isTerminal == true { canonical = reference.snapshot }
            if let canonical {
                guard reference.remoteTaskID == canonical.id,
                      reference.createRequest.payload == canonical.payload else { throw NativeTaskError.invalidResponse }
            }
            let retryPending = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM native_task_retries WHERE reference_id = ? AND pending = 1 AND decision_id = ?)
                """, arguments: [id.uuidString, canonical?.decision?.id ?? ""]) ?? false
            let display = try NativeTaskProjection.display(reference: reference, snapshot: canonical,
                                                            connectionNote: connectionNote, retryPending: retryPending)
            let bytes: Data? = row["display_blocks_json"]
            var envelope = NativeMessageEnvelope(spokenText: row["spoken_text"] ?? "",
                displayBlocks: try bytes.map { try JSONDecoder().decode([NativeDisplayBlock].self, from: $0) } ?? [])
            let oldBlocks = envelope.displayBlocks
            envelope.reconcile(card: display.card, artifact: display.artifact)
            if let previous, previous.snapshot == canonical, previous.cursor >= cursor,
               previous.connectionNote == connectionNote, oldBlocks == envelope.displayBlocks,
               reference.snapshot == canonical {
                return NativeTaskMessageUpdate(conversationID: reference.origin.conversationID,
                    messageID: reference.origin.assistantMessageID, blocks: envelope.displayBlocks)
            }
            try db.execute(sql: "UPDATE messages SET display_blocks_json = ? WHERE id = ?",
                arguments: [try nativeTaskEncoded(envelope.displayBlocks), reference.origin.assistantMessageID.uuidString])
            let snapshotBytes = try canonical.map { try nativeTaskEncoded($0) }
            try db.execute(sql: """
                INSERT INTO native_task_projections(reference_id, message_id, snapshot_json, cursor, connection_note)
                VALUES (?, ?, ?, ?, ?) ON CONFLICT(reference_id) DO UPDATE SET
                snapshot_json = excluded.snapshot_json, cursor = MAX(cursor, excluded.cursor),
                connection_note = excluded.connection_note
                """, arguments: [id.uuidString, reference.origin.assistantMessageID.uuidString,
                                   snapshotBytes, cursor, connectionNote])
            if let canonical {
                reference.snapshot = canonical
                try db.execute(sql: "UPDATE native_task_outbox SET reference_json = ? WHERE id = ?",
                               arguments: [try nativeTaskEncoded(reference), id.uuidString])
                if canonical.state.isTerminal || canonical.decision == nil {
                    try db.execute(sql: "UPDATE native_task_retries SET pending = 0 WHERE reference_id = ?",
                                   arguments: [id.uuidString])
                } else {
                    try db.execute(sql: "UPDATE native_task_retries SET pending = 0 WHERE reference_id = ? AND decision_id != ?",
                                   arguments: [id.uuidString, canonical.decision?.id ?? ""])
                }
            }
            return NativeTaskMessageUpdate(conversationID: reference.origin.conversationID,
                                           messageID: reference.origin.assistantMessageID,
                                           blocks: envelope.displayBlocks)
        }
    }

    func prepareTaskRetry(id: UUID, decisionID: String) throws -> NativeTaskDecisionIntent {
        try database.write { db in
            guard let reference = try Self.readTaskReference(db, id: id), !reference.cancelRequested,
                  let snapshot = try Self.readTaskProjection(db, id: id)?.snapshot,
                  snapshot.state == .needsDecision, snapshot.decision?.id == decisionID,
                  snapshot.decision?.choices.contains("retry") == true else { throw NativeTaskError.invalidResponse }
            try db.execute(sql: "UPDATE native_task_projections SET request_generation = request_generation + 1 WHERE reference_id = ?",
                           arguments: [id.uuidString])
            if let key = try String.fetchOne(db, sql: """
                SELECT reply_key FROM native_task_retries WHERE reference_id = ? AND decision_id = ?
                """, arguments: [id.uuidString, decisionID]), let value = UUID(uuidString: key) {
                return NativeTaskDecisionIntent(referenceID: id, decisionID: decisionID, key: value)
            }
            let intent = NativeTaskDecisionIntent(referenceID: id, decisionID: decisionID, key: UUID())
            try db.execute(sql: """
                INSERT INTO native_task_retries(reference_id, message_id, decision_id, reply_key) VALUES (?, ?, ?, ?)
                """, arguments: [id.uuidString, reference.origin.assistantMessageID.uuidString, decisionID, intent.key.uuidString])
            return intent
        }
    }

    func pendingTaskRetries() throws -> [NativeTaskDecisionIntent] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT reference_id, decision_id, reply_key FROM native_task_retries WHERE pending = 1")
                .map { row in
                    guard let id = UUID(uuidString: row["reference_id"]),
                          let key = UUID(uuidString: row["reply_key"]) else { throw NativeTaskError.persistenceUnavailable }
                    return NativeTaskDecisionIntent(referenceID: id, decisionID: row["decision_id"], key: key)
                }
        }
    }

    func resolveTaskRetry(_ intent: NativeTaskDecisionIntent) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE native_task_retries SET pending = 0 WHERE reference_id = ? AND decision_id = ? AND reply_key = ?
                """, arguments: [intent.referenceID.uuidString, intent.decisionID, intent.key.uuidString])
        }
    }
}
