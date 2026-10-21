import Foundation
import GRDB

enum NativeTaskStoreError: Error, Equatable, Sendable {
    case notFound
    case conflict(String)
    case invalid(String)
}

struct NativeTaskRecord: Equatable, Sendable {
    let id: String
    let workerType: String
    let payload: Data
    let state: NativeTaskState
    let checkpoint: Data
    let result: Data?
    let decision: Data?
    let decisionReply: Data?
    let cancelRequested: Bool
    let generation: Int
    let createdAt: Double
    let updatedAt: Double

    func snapshotJSON() throws -> Data {
        var object: [String: Any] = [
            "id": id, "worker_type": workerType, "payload": try NativeTaskStore.object(payload),
            "state": state.rawValue, "checkpoint": try NativeTaskStore.object(checkpoint),
            "result": try result.map(NativeTaskStore.object) ?? NSNull(),
            "decision": try decision.map(NativeTaskStore.object) ?? NSNull(),
            "decision_reply": try decisionReply.map(NativeTaskStore.object) ?? NSNull(),
            "cancel_requested": cancelRequested, "generation": generation,
            "created_at": createdAt, "updated_at": updatedAt,
        ]
        object["id"] = id
        return try NativeTaskStore.canonical(object)
    }

    func decisionID() -> String? {
        guard let decision, let object = try? NativeTaskStore.object(decision) else { return nil }
        return object["id"] as? String
    }
}

struct NativeTaskEventRecord: Equatable, Sendable {
    let id: Int64
    let taskID: String
    let kind: String
    let state: NativeTaskState
    let data: Data
    let createdAt: Double
}

struct NativeTaskStepResult: Sendable {
    var state: NativeTaskState = .queued
    var checkpoint: Data = NativeTaskStore.emptyObject
    var result: Data? = nil
    var event: String = "progress"
    var data: Data = NativeTaskStore.emptyObject
    var decision: Data? = nil

    static func failed(checkpoint: Data, reason: String) -> NativeTaskStepResult {
        NativeTaskStepResult(state: .failed, checkpoint: checkpoint, event: "failed",
                             data: (try? NativeTaskStore.canonical(["reason": reason])) ?? NativeTaskStore.emptyObject)
    }
}

final class NativeTaskStore: Sendable {
    static let maximumJSONBytes = 262144
    static let maximumEventBytes = 16384
    static let emptyObject = Data("{}".utf8)
    let database: DatabaseQueue

    init(database: DatabaseQueue) {
        self.database = database
    }

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_engine_tasks (
                id TEXT PRIMARY KEY NOT NULL,
                worker_type TEXT NOT NULL,
                payload TEXT NOT NULL,
                creation_key TEXT NOT NULL UNIQUE,
                state TEXT NOT NULL,
                checkpoint TEXT NOT NULL DEFAULT '{}',
                result TEXT,
                decision TEXT,
                decision_reply TEXT,
                cancel_requested INTEGER NOT NULL DEFAULT 0,
                generation INTEGER NOT NULL DEFAULT 0,
                queue_order INTEGER NOT NULL DEFAULT 0,
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL,
                request TEXT
            );
            CREATE INDEX native_engine_task_queue ON native_engine_tasks(state, queue_order);
            CREATE TABLE native_engine_task_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL REFERENCES native_engine_tasks(id),
                kind TEXT NOT NULL,
                state TEXT NOT NULL,
                data TEXT NOT NULL,
                created_at DOUBLE NOT NULL
            );
            CREATE INDEX native_engine_task_events_task ON native_engine_task_events(task_id, id);
            CREATE TRIGGER native_engine_task_event_update BEFORE UPDATE ON native_engine_task_events
                BEGIN SELECT RAISE(ABORT, 'Events are append-only'); END;
            CREATE TRIGGER native_engine_task_event_delete BEFORE DELETE ON native_engine_task_events
                BEGIN SELECT RAISE(ABORT, 'Events are append-only'); END;
            CREATE TABLE native_engine_task_decisions (
                task_id TEXT NOT NULL REFERENCES native_engine_tasks(id),
                decision_id TEXT NOT NULL,
                reply_key TEXT NOT NULL,
                reply TEXT NOT NULL,
                PRIMARY KEY(task_id, decision_id)
            );
            """)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeTaskStoreError.invalid("Task data must be a JSON object")
        }
        return object
    }

    static func canonical(_ object: [String: Any], limit: Int = maximumJSONBytes) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= limit else { throw NativeTaskStoreError.invalid("Task data exceeds its size limit") }
        return data
    }

    static func canonical(_ data: Data, limit: Int = maximumJSONBytes) throws -> Data {
        try canonical(object(data), limit: limit)
    }

    private static func now() -> Double { Date().timeIntervalSince1970 }

    private static func record(_ row: Row) -> NativeTaskRecord {
        NativeTaskRecord(id: row["id"], workerType: row["worker_type"], payload: Data((row["payload"] as String).utf8),
            state: NativeTaskState(rawValue: row["state"]) ?? .failed, checkpoint: Data((row["checkpoint"] as String).utf8),
            result: (row["result"] as String?).map { Data($0.utf8) }, decision: (row["decision"] as String?).map { Data($0.utf8) },
            decisionReply: (row["decision_reply"] as String?).map { Data($0.utf8) },
            cancelRequested: (row["cancel_requested"] as Int) != 0, generation: row["generation"],
            createdAt: row["created_at"], updatedAt: row["updated_at"])
    }

    private static func row(_ db: Database, _ id: String) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM native_engine_tasks WHERE id = ?", arguments: [id]) else {
            throw NativeTaskStoreError.notFound
        }
        return row
    }

    private static func fetch(_ db: Database, _ id: String) throws -> NativeTaskRecord {
        record(try row(db, id))
    }

    @discardableResult
    private static func event(_ db: Database, _ id: String, kind: String, state: NativeTaskState, data: Data) throws -> Int64 {
        guard !kind.isEmpty, kind.utf8.count <= 80 else { throw NativeTaskStoreError.invalid("Invalid task event name") }
        let encoded = try canonical(data, limit: maximumEventBytes)
        try db.execute(sql: "INSERT INTO native_engine_task_events(task_id, kind, state, data, created_at) VALUES(?,?,?,?,?)",
                       arguments: [id, kind, state.rawValue, String(decoding: encoded, as: UTF8.self), now()])
        return db.lastInsertedRowID
    }

    private static func setQueueOrder(_ db: Database, _ id: String, _ order: Int64) throws {
        try db.execute(sql: "UPDATE native_engine_tasks SET queue_order = ? WHERE id = ?", arguments: [order, id])
    }

    func create(workerType: String, payload: Data, idempotencyKey: String,
                validate: ((Data) throws -> Data?)? = nil) throws -> NativeTaskRecord {
        let trimmedType = workerType.trimmingCharacters(in: .whitespaces)
        guard !trimmedType.isEmpty, workerType.utf8.count <= 80,
              !idempotencyKey.trimmingCharacters(in: .whitespaces).isEmpty, idempotencyKey.utf8.count <= 200 else {
            throw NativeTaskStoreError.invalid("Worker type and idempotency key are required and must fit their limits")
        }
        let body = try Self.canonical(payload)
        return try database.write { db in
            if let existing = try Row.fetchOne(db, sql: "SELECT * FROM native_engine_tasks WHERE creation_key = ?", arguments: [idempotencyKey]) {
                let text = String(decoding: body, as: UTF8.self)
                if existing["worker_type"] == workerType, [existing["request"] as String?, existing["payload"] as String?].contains(text) {
                    return Self.record(existing)
                }
                let normalized = try validate.flatMap { try $0(body) }.map { try Self.canonical($0) } ?? body
                guard existing["worker_type"] == workerType, (existing["payload"] as String) == String(decoding: normalized, as: UTF8.self) else {
                    throw NativeTaskStoreError.conflict("Idempotency key already used with different task data")
                }
                return Self.record(existing)
            }
            let normalized = try validate.flatMap { try $0(body) }.map { try Self.canonical($0) } ?? body
            let id = UUID().uuidString.lowercased()
            let now = Self.now()
            try db.execute(sql: """
                INSERT INTO native_engine_tasks(id, worker_type, payload, creation_key, state, created_at, updated_at, request)
                VALUES(?,?,?,?,?,?,?,?)
                """, arguments: [id, workerType, String(decoding: normalized, as: UTF8.self), idempotencyKey, NativeTaskState.queued.rawValue, now, now, String(decoding: body, as: UTF8.self)])
            let order = try Self.event(db, id, kind: "created", state: .queued, data: Self.emptyObject)
            try Self.setQueueOrder(db, id, order)
            return try Self.fetch(db, id)
        }
    }

    func get(_ id: String) throws -> NativeTaskRecord {
        try database.read { db in try Self.fetch(db, id) }
    }

    func events(after: Int64 = 0, taskID: String? = nil, limit: Int = 100) throws -> [NativeTaskEventRecord] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM native_engine_task_events WHERE id > ? AND (? IS NULL OR task_id = ?) ORDER BY id LIMIT ?
                """, arguments: [after, taskID, taskID, max(1, min(limit, 200))])
            return rows.map { row in
                NativeTaskEventRecord(id: row["id"], taskID: row["task_id"], kind: row["kind"],
                    state: NativeTaskState(rawValue: row["state"]) ?? .failed,
                    data: Data((row["data"] as String).utf8), createdAt: row["created_at"])
            }
        }
    }

    func latestEventID() throws -> Int64 {
        try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM native_engine_task_events") ?? 0
        }
    }

    func claim(workerTypes: Set<String>) throws -> NativeTaskRecord? {
        guard !workerTypes.isEmpty else { return nil }
        let idle = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT 1 FROM native_engine_tasks WHERE state = 'queued' LIMIT 1") == nil
        }
        if idle { return nil }
        return try database.write { db in
            if try Row.fetchOne(db, sql: "SELECT 1 FROM native_engine_tasks WHERE state = 'running' LIMIT 1") != nil { return nil }
            let placeholders = workerTypes.map { _ in "?" }.joined(separator: ",")
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM native_engine_tasks WHERE state = 'queued' AND worker_type IN (\(placeholders)) ORDER BY queue_order LIMIT 1
                """, arguments: StatementArguments(Array(workerTypes))) else { return nil }
            let id: String = row["id"]
            try db.execute(sql: "UPDATE native_engine_tasks SET state = 'running', generation = generation + 1, updated_at = ? WHERE id = ?",
                           arguments: [Self.now(), id])
            try Self.event(db, id, kind: "started", state: .running, data: Self.emptyObject)
            return try Self.fetch(db, id)
        }
    }

    func commitStep(_ id: String, generation: Int, step: NativeTaskStepResult) throws -> NativeTaskRecord {
        guard [.queued, .blocked, .needsDecision, .completed, .failed].contains(step.state) else {
            throw NativeTaskStoreError.conflict("Invalid worker transition")
        }
        guard (step.state == .needsDecision) == (step.decision != nil) else {
            throw NativeTaskStoreError.invalid("A decision is required only when waiting for a decision")
        }
        let checkpoint = try Self.canonical(step.checkpoint)
        let result = try step.result.map { try Self.canonical($0) }
        var decisionData: Data?
        if let decision = step.decision {
            var object = try Self.object(decision)
            object["id"] = UUID().uuidString.lowercased()
            decisionData = try Self.canonical(object)
        }
        _ = try Self.object(step.data)
        return try database.write { db in
            let row = try Self.row(db, id)
            guard (row["state"] as String) == NativeTaskState.running.rawValue, (row["generation"] as Int) == generation else {
                throw NativeTaskStoreError.conflict("Worker claim is no longer current")
            }
            if (row["cancel_requested"] as Int) != 0 { return try Self.finishCancel(db, id) }
            try db.execute(sql: """
                UPDATE native_engine_tasks SET state = ?, checkpoint = ?, result = ?, decision = ?, decision_reply = NULL, updated_at = ? WHERE id = ?
                """, arguments: [step.state.rawValue, String(decoding: checkpoint, as: UTF8.self),
                                 result.map { String(decoding: $0, as: UTF8.self) },
                                 decisionData.map { String(decoding: $0, as: UTF8.self) }, Self.now(), id])
            let order = try Self.event(db, id, kind: step.event, state: step.state, data: step.data)
            try Self.setQueueOrder(db, id, order)
            return try Self.fetch(db, id)
        }
    }

    private static func finishCancel(_ db: Database, _ id: String) throws -> NativeTaskRecord {
        try db.execute(sql: """
            UPDATE native_engine_tasks SET state = 'canceled', cancel_requested = 1, generation = generation + 1, decision = NULL, updated_at = ? WHERE id = ?
            """, arguments: [now(), id])
        try event(db, id, kind: "canceled", state: .canceled, data: emptyObject)
        return try fetch(db, id)
    }

    func cancel(_ id: String) throws -> NativeTaskRecord {
        try database.write { db in
            let record = try Self.fetch(db, id)
            if record.state.isTerminal || record.cancelRequested { return record }
            if record.state != .running { return try Self.finishCancel(db, id) }
            try db.execute(sql: "UPDATE native_engine_tasks SET cancel_requested = 1, updated_at = ? WHERE id = ?", arguments: [Self.now(), id])
            try Self.event(db, id, kind: "cancel_requested", state: .running, data: Self.emptyObject)
            return try Self.fetch(db, id)
        }
    }

    func respond(_ id: String, decisionID: String, replyKey: String, reply: Data) throws -> NativeTaskRecord {
        guard !replyKey.trimmingCharacters(in: .whitespaces).isEmpty, replyKey.utf8.count <= 200 else {
            throw NativeTaskStoreError.invalid("A bounded reply key is required")
        }
        let body = String(decoding: try Self.canonical(reply), as: UTF8.self)
        return try database.write { db in
            let record = try Self.fetch(db, id)
            if let prior = try Row.fetchOne(db, sql: "SELECT * FROM native_engine_task_decisions WHERE task_id = ? AND decision_id = ?", arguments: [id, decisionID]) {
                guard (prior["reply_key"] as String) == replyKey, (prior["reply"] as String) == body else {
                    throw NativeTaskStoreError.conflict("This decision already has a different response")
                }
                return record
            }
            guard record.state == .needsDecision, record.decisionID() == decisionID else {
                throw NativeTaskStoreError.conflict("This decision is no longer awaiting a response")
            }
            try db.execute(sql: "INSERT INTO native_engine_task_decisions VALUES(?,?,?,?)", arguments: [id, decisionID, replyKey, body])
            try db.execute(sql: "UPDATE native_engine_tasks SET state = 'queued', decision = NULL, decision_reply = ?, updated_at = ? WHERE id = ?",
                           arguments: [body, Self.now(), id])
            let order = try Self.event(db, id, kind: "decision_received", state: .queued,
                                       data: try Self.canonical(["decision_id": decisionID, "reply": try Self.object(reply)]))
            try Self.setQueueOrder(db, id, order)
            return try Self.fetch(db, id)
        }
    }

    func resume(_ id: String, expectedGeneration: Int? = nil, checkpointMatch: [String: String] = [:]) throws -> NativeTaskRecord {
        try database.write { db in
            let record = try Self.fetch(db, id)
            guard record.state == .blocked, !record.cancelRequested else {
                throw NativeTaskStoreError.conflict("Only blocked tasks can be resumed")
            }
            if let expectedGeneration, record.generation != expectedGeneration {
                throw NativeTaskStoreError.conflict("This task generation is no longer current")
            }
            let checkpoint = try Self.object(record.checkpoint)
            for (key, value) in checkpointMatch where (checkpoint[key] as? String) != value {
                throw NativeTaskStoreError.conflict("This task is blocked for another reason")
            }
            try db.execute(sql: "UPDATE native_engine_tasks SET state = 'queued', updated_at = ? WHERE id = ?", arguments: [Self.now(), id])
            let order = try Self.event(db, id, kind: "resumed", state: .queued, data: Self.emptyObject)
            try Self.setQueueOrder(db, id, order)
            return try Self.fetch(db, id)
        }
    }

    @discardableResult
    func recover() throws -> Int {
        try database.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM native_engine_tasks WHERE state = 'running' ORDER BY queue_order")
            for row in rows {
                let id: String = row["id"]
                if (row["cancel_requested"] as Int) != 0 {
                    _ = try Self.finishCancel(db, id)
                    continue
                }
                try db.execute(sql: "UPDATE native_engine_tasks SET state = 'queued', generation = generation + 1, updated_at = ? WHERE id = ?",
                               arguments: [Self.now(), id])
                let order = try Self.event(db, id, kind: "recovered", state: .queued, data: Self.emptyObject)
                try Self.setQueueOrder(db, id, order)
            }
            return rows.count
        }
    }
}
