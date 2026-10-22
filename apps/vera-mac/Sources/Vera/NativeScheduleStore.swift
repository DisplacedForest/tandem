import Foundation
import GRDB

final class NativeScheduleStore: Sendable {
    let database: DatabaseQueue

    init(database: DatabaseQueue) {
        self.database = database
    }

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_schedules (
                id TEXT PRIMARY KEY NOT NULL,
                owner TEXT NOT NULL,
                conversation_id TEXT,
                worker_type TEXT NOT NULL,
                title TEXT NOT NULL,
                instruction TEXT NOT NULL,
                cadence_json TEXT NOT NULL,
                time_zone TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                next_run_at DOUBLE,
                last_run_at DOUBLE,
                last_outcome TEXT,
                created_at DOUBLE NOT NULL
            );
            CREATE INDEX native_schedules_due ON native_schedules(enabled, next_run_at);
            CREATE TABLE native_schedule_runs (
                id TEXT PRIMARY KEY NOT NULL,
                schedule_id TEXT NOT NULL REFERENCES native_schedules(id) ON DELETE CASCADE,
                scheduled_for DOUBLE NOT NULL,
                started_at DOUBLE,
                finished_at DOUBLE,
                outcome TEXT NOT NULL,
                detail TEXT NOT NULL DEFAULT '',
                conversation_id TEXT,
                message_id TEXT,
                task_reference_id TEXT
            );
            CREATE INDEX native_schedule_runs_schedule ON native_schedule_runs(schedule_id, scheduled_for);
            CREATE INDEX native_schedule_runs_open ON native_schedule_runs(outcome);
            CREATE TABLE native_scheduler_state (
                key TEXT PRIMARY KEY NOT NULL,
                value DOUBLE NOT NULL
            );
            """)
    }

    private static func schedule(_ row: Row) throws -> NativeSchedule {
        let cadence = try JSONDecoder().decode(NativeScheduleCadence.self, from: Data((row["cadence_json"] as String).utf8))
        return try NativeSchedule(
            id: row["id"], owner: NativeScheduleOwner(rawValue: row["owner"]) ?? .conversation,
            conversationID: row["conversation_id"], workerType: row["worker_type"], title: row["title"],
            instruction: row["instruction"], cadence: cadence,
            timeZone: TimeZone(identifier: row["time_zone"]) ?? .current, enabled: (row["enabled"] as Int) != 0,
            nextRunAt: (row["next_run_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            lastRunAt: (row["last_run_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            lastOutcome: (row["last_outcome"] as String?).flatMap(NativeScheduleOutcome.init(rawValue:)),
            createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }

    private static func run(_ row: Row) -> NativeScheduleRun {
        NativeScheduleRun(
            id: row["id"], scheduleID: row["schedule_id"], scheduledFor: Date(timeIntervalSince1970: row["scheduled_for"]),
            startedAt: (row["started_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            finishedAt: (row["finished_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            outcome: NativeScheduleOutcome(rawValue: row["outcome"]) ?? .failed, detail: row["detail"],
            conversationID: row["conversation_id"], messageID: row["message_id"], taskReferenceID: row["task_reference_id"])
    }

    func all() throws -> [NativeSchedule] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM native_schedules ORDER BY created_at").compactMap { try? Self.schedule($0) }
        }
    }

    func get(_ id: String) throws -> NativeSchedule? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM native_schedules WHERE id = ?", arguments: [id]).map { try Self.schedule($0) }
        }
    }

    func save(_ schedule: NativeSchedule) throws {
        let cadence = String(decoding: try JSONEncoder().encode(schedule.cadence), as: UTF8.self)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO native_schedules(id, owner, conversation_id, worker_type, title, instruction, cadence_json, time_zone,
                    enabled, next_run_at, last_run_at, last_outcome, created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET owner = excluded.owner, conversation_id = excluded.conversation_id,
                    worker_type = excluded.worker_type, title = excluded.title, instruction = excluded.instruction,
                    cadence_json = excluded.cadence_json, time_zone = excluded.time_zone, enabled = excluded.enabled,
                    next_run_at = excluded.next_run_at, last_run_at = excluded.last_run_at, last_outcome = excluded.last_outcome
                """, arguments: [schedule.id, schedule.owner.rawValue, schedule.conversationID, schedule.workerType, schedule.title,
                                 schedule.instruction, cadence, schedule.timeZoneID, schedule.enabled ? 1 : 0,
                                 schedule.nextRunAt?.timeIntervalSince1970, schedule.lastRunAt?.timeIntervalSince1970,
                                 schedule.lastOutcome?.rawValue, schedule.createdAt.timeIntervalSince1970])
        }
    }

    func delete(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM native_schedule_runs WHERE schedule_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM native_schedules WHERE id = ?", arguments: [id])
        }
    }

    func due(at now: Date) throws -> [NativeSchedule] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM native_schedules WHERE enabled = 1 AND next_run_at IS NOT NULL AND next_run_at <= ? ORDER BY next_run_at
                """, arguments: [now.timeIntervalSince1970]).compactMap { try? Self.schedule($0) }
        }
    }

    func claim(_ id: String, expectedNextRunAt: Date, nextRunAt: Date?, enabled: Bool) throws -> Bool {
        try database.write { db in
            try db.execute(sql: """
                UPDATE native_schedules SET next_run_at = ?, enabled = ? WHERE id = ? AND enabled = 1 AND next_run_at = ?
                """, arguments: [nextRunAt?.timeIntervalSince1970, enabled ? 1 : 0, id, expectedNextRunAt.timeIntervalSince1970])
            return db.changesCount == 1
        }
    }

    func heartbeat() throws -> Date? {
        try database.read { db in
            try Double.fetchOne(db, sql: "SELECT value FROM native_scheduler_state WHERE key = 'heartbeat'").map(Date.init(timeIntervalSince1970:))
        }
    }

    func recordHeartbeat(_ date: Date) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO native_scheduler_state(key, value) VALUES('heartbeat', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [date.timeIntervalSince1970])
        }
    }

    func saveRun(_ run: NativeScheduleRun) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO native_schedule_runs(id, schedule_id, scheduled_for, started_at, finished_at, outcome, detail,
                    conversation_id, message_id, task_reference_id)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET started_at = excluded.started_at, finished_at = excluded.finished_at,
                    outcome = excluded.outcome, detail = excluded.detail, conversation_id = excluded.conversation_id,
                    message_id = excluded.message_id, task_reference_id = excluded.task_reference_id
                """, arguments: [run.id, run.scheduleID, run.scheduledFor.timeIntervalSince1970, run.startedAt?.timeIntervalSince1970,
                                 run.finishedAt?.timeIntervalSince1970, run.outcome.rawValue, run.detail, run.conversationID,
                                 run.messageID, run.taskReferenceID])
            try db.execute(sql: """
                UPDATE native_schedules SET last_run_at = ?, last_outcome = ? WHERE id = ? AND (last_run_at IS NULL OR last_run_at <= ?)
                """, arguments: [run.scheduledFor.timeIntervalSince1970, run.outcome.rawValue, run.scheduleID, run.scheduledFor.timeIntervalSince1970])
        }
    }

    func runs(scheduleID: String, limit: Int = 50) throws -> [NativeScheduleRun] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM native_schedule_runs WHERE schedule_id = ? ORDER BY scheduled_for DESC, rowid DESC LIMIT ?
                """, arguments: [scheduleID, max(1, min(limit, 200))]).map(Self.run)
        }
    }

    func activeRuns() throws -> [NativeScheduleRun] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM native_schedule_runs WHERE outcome = 'running' ORDER BY scheduled_for").map(Self.run)
        }
    }

    func run(_ id: String) throws -> NativeScheduleRun? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM native_schedule_runs WHERE id = ?", arguments: [id]).map(Self.run)
        }
    }
}
