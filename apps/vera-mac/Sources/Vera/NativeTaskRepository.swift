import Foundation
import GRDB

extension LocalChatRepository: NativeTaskRepository {
    static func migrateNativeTasks(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_task_outbox (
                id TEXT PRIMARY KEY NOT NULL,
                intent_key TEXT UNIQUE NOT NULL,
                conversation_id TEXT,
                reference_json BLOB,
                orphaned INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX native_task_conversation ON native_task_outbox(conversation_id);
            CREATE TABLE native_task_generations (
                request_id TEXT NOT NULL REFERENCES native_task_outbox(id),
                generation_key TEXT NOT NULL,
                messages_digest TEXT NOT NULL,
                reserved_until DOUBLE NOT NULL,
                state TEXT NOT NULL CHECK (state IN ('reserved', 'completed', 'failed')),
                response TEXT,
                failure TEXT,
                PRIMARY KEY(request_id, generation_key)
            );
            """)
    }

    func prepareTaskReference(origin: NativeTaskOrigin, engine: NativeTaskEngineIdentity,
                              request: NativeResearchTaskRequest,
                              profile: NativeTaskProfileBinding?,
                              options: NativeTaskResearchOptions = .standard) throws -> NativeTaskReference {
        struct Intent: Encodable {
            let userMessageID: UUID
            let engine: NativeTaskEngineIdentity
            let request: NativeResearchTaskRequest
        }
        let intentKey = nativeTaskDigest(try nativeTaskEncoded(
            Intent(userMessageID: origin.userMessageID, engine: engine, request: request)))
        return try database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT reference_json FROM native_task_outbox WHERE intent_key = ?",
                                          arguments: [intentKey]) {
                guard let bytes: Data = row["reference_json"] else { throw NativeTaskError.persistenceUnavailable }
                return try JSONDecoder().decode(NativeTaskReference.self, from: bytes)
            }
            guard (1...5).contains(options.subquestions), (0...4).contains(options.pagesPerQuestion) else {
                throw NativeTaskError.invalidRequest("Research limits must be bounded.")
            }
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages WHERE conversation_id = ? AND
                ((id = ? AND role = 'user') OR (id = ? AND role = 'assistant'))
                """, arguments: [origin.conversationID, origin.userMessageID.uuidString,
                                   origin.assistantMessageID.uuidString])
            guard count == 2 else { throw NativeTaskError.persistenceUnavailable }
            let id = UUID()
            let binding: NativeTaskAdmissionBinding?
            if let profile {
                binding = NativeTaskAdmissionBinding(id: profile.id, admissionBase: profile.provider.base,
                    enrollmentDigest: nativeTaskDigest(try nativeTaskEncoded(profile) + nativeTaskEncoded(request)))
            } else {
                binding = nil
            }
            let create = NativeTaskCreateRequest(request: request, idempotencyKey: id, nativeBinding: binding, options: options)
            let reference = NativeTaskReference(
                id: id, origin: origin, engine: engine, request: request, createRequest: create,
                body: try create.encoded(), profile: profile, remoteTaskID: nil, deliveryState: .pending,
                cancelRequested: false, cancelDelivered: false, lastDeliveryError: nil, snapshot: nil)
            try db.execute(sql: """
                INSERT INTO native_task_outbox(id, intent_key, conversation_id, reference_json)
                VALUES (?, ?, ?, ?)
                """, arguments: [id.uuidString, intentKey, origin.conversationID, try nativeTaskEncoded(reference)])
            return reference
        }
    }

    func taskReferences(conversationID: String? = nil) throws -> [NativeTaskReference] {
        try database.read { db in
            let rows: [Row]
            if let conversationID {
                rows = try Row.fetchAll(db, sql: """
                    SELECT reference_json FROM native_task_outbox
                    WHERE conversation_id = ? AND reference_json IS NOT NULL
                    """, arguments: [conversationID])
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT reference_json FROM native_task_outbox WHERE reference_json IS NOT NULL")
            }
            return try rows.map { row in
                let bytes: Data = row["reference_json"]
                return try JSONDecoder().decode(NativeTaskReference.self, from: bytes)
            }
        }
    }

    func taskReference(id: UUID) throws -> NativeTaskReference? {
        try database.read { db in try Self.readTaskReference(db, id: id) }
    }

    func acknowledgeTaskReference(id: UUID, snapshot: NativeTaskSnapshot) throws -> NativeTaskReference {
        try mutateTaskReference(id) { reference in
            guard reference.remoteTaskID == nil || reference.remoteTaskID == snapshot.id,
                  reference.createRequest.payload == snapshot.payload else { throw NativeTaskError.invalidResponse }
            if reference.snapshot?.state.isTerminal == true { return }
            reference.remoteTaskID = snapshot.id
            reference.deliveryState = .accepted
            reference.snapshot = snapshot
            reference.lastDeliveryError = nil
        }
    }

    func failTaskDelivery(id: UUID, permanent: Bool, message: String) throws -> NativeTaskReference {
        try mutateTaskReference(id) { reference in
            if permanent && reference.remoteTaskID == nil { reference.deliveryState = .rejected }
            reference.lastDeliveryError = String(message.prefix(300))
        }
    }

    func requestTaskCancellation(id: UUID) throws -> NativeTaskReference {
        try mutateTaskReference(id) { $0.cancelRequested = true }
    }

    func acknowledgeTaskCancellation(id: UUID, snapshot: NativeTaskSnapshot) throws -> NativeTaskReference {
        try mutateTaskReference(id) { reference in
            guard reference.remoteTaskID == snapshot.id,
                  reference.createRequest.payload == snapshot.payload,
                  snapshot.cancelRequested || snapshot.state.isTerminal else { throw NativeTaskError.invalidResponse }
            if reference.snapshot?.state.isTerminal == true {
                reference.cancelDelivered = true
                reference.lastDeliveryError = nil
                return
            }
            reference.snapshot = snapshot
            reference.cancelDelivered = snapshot.state.isTerminal
            reference.lastDeliveryError = nil
        }
    }

    func mutateTaskReference(_ id: UUID,
                             change: (inout NativeTaskReference) throws -> Void) throws -> NativeTaskReference {
        try database.write { db in
            guard var reference = try Self.readTaskReference(db, id: id) else {
                throw NativeTaskError.persistenceUnavailable
            }
            try change(&reference)
            try db.execute(sql: "UPDATE native_task_outbox SET reference_json = ? WHERE id = ?",
                           arguments: [try nativeTaskEncoded(reference), id.uuidString])
            try Self.cleanOrphanedTask(db, reference: reference)
            return reference
        }
    }

    static func readTaskReference(_ db: Database, id: UUID) throws -> NativeTaskReference? {
        guard let row = try Row.fetchOne(db, sql: "SELECT reference_json FROM native_task_outbox WHERE id = ?",
                                        arguments: [id.uuidString]), let bytes: Data = row["reference_json"] else { return nil }
        return try JSONDecoder().decode(NativeTaskReference.self, from: bytes)
    }

    static func detachTasks(_ db: Database, conversationID: String) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id FROM native_task_outbox WHERE conversation_id = ?",
                                   arguments: [conversationID])
        for row in rows {
            let text: String = row["id"]
            guard let id = UUID(uuidString: text), var reference = try readTaskReference(db, id: id) else { continue }
            reference.cancelRequested = true
            reference.snapshot = reference.snapshot?.state.isTerminal == true ? reference.snapshot : nil
            try db.execute(sql: """
                UPDATE native_task_outbox SET conversation_id = NULL, orphaned = 1, reference_json = ? WHERE id = ?
                """, arguments: [try nativeTaskEncoded(reference), text])
            try db.execute(sql: "UPDATE native_task_generations SET response = NULL, failure = NULL WHERE request_id = ?",
                           arguments: [text])
            try cleanOrphanedTask(db, reference: reference)
        }
    }

    static func cleanOrphanedTask(_ db: Database, reference: NativeTaskReference) throws {
        guard reference.snapshot?.state.isTerminal == true || reference.deliveryState == .rejected else { return }
        let orphaned = try Bool.fetchOne(db, sql: "SELECT orphaned FROM native_task_outbox WHERE id = ?",
                                        arguments: [reference.id.uuidString]) ?? false
        guard orphaned else { return }
        try db.execute(sql: "UPDATE native_task_outbox SET reference_json = NULL WHERE id = ?",
                       arguments: [reference.id.uuidString])
        try db.execute(sql: "UPDATE native_task_generations SET response = NULL, failure = NULL WHERE request_id = ?",
                       arguments: [reference.id.uuidString])
    }
}
