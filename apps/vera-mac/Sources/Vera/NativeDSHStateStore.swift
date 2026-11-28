import Foundation
import GRDB
import CryptoKit

struct NativeDSHStateStore: Sendable {
    static let maximumBytes = 16 * 1024 * 1024
    let database: DatabaseQueue

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_dsh_snapshots (
                task_id TEXT NOT NULL REFERENCES native_engine_tasks(id) ON DELETE CASCADE,
                revision TEXT NOT NULL,
                snapshot BLOB NOT NULL,
                PRIMARY KEY (task_id, revision)
            )
            """)
    }

    func save(_ snapshot: Data, task: NativeTaskRecord) throws -> String {
        guard snapshot.count <= Self.maximumBytes,
              (try? JSONSerialization.jsonObject(with: snapshot)) != nil else {
            throw NativeTaskStoreError.invalid("The saved conversation exceeds its storage limit")
        }
        let revision = SHA256.hash(data: snapshot).map { String(format: "%02x", $0) }.joined()
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT generation, state, cancel_requested, pause_requested FROM native_engine_tasks WHERE id = ?", arguments: [task.id]),
                  (row["generation"] as Int) == task.generation,
                  (row["state"] as String) == "running",
                  (row["cancel_requested"] as Int) == 0,
                  (row["pause_requested"] as Int) == 0 else { throw CancellationError() }
            try db.execute(sql: "INSERT OR IGNORE INTO native_dsh_snapshots (task_id, revision, snapshot) VALUES (?, ?, ?)", arguments: [task.id, revision, snapshot])
            let current = try Row.fetchOne(db, sql: "SELECT checkpoint FROM native_engine_tasks WHERE id = ?", arguments: [task.id])
            let old = (current?["checkpoint"] as String?).flatMap { try? JSONDecoder().decode(NativeCompanionCheckpoint.self, from: Data($0.utf8)) }?.dshRevision
            try db.execute(sql: "DELETE FROM native_dsh_snapshots WHERE task_id = ? AND revision != ? AND revision != ?", arguments: [task.id, revision, old ?? revision])
        }
        return revision
    }

    func load(_ revision: String, taskID: String) throws -> Data {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT snapshot FROM native_dsh_snapshots WHERE task_id = ? AND revision = ?", arguments: [taskID, revision]),
                  data.count <= Self.maximumBytes,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == revision else {
                throw NativeTaskStoreError.invalid("The saved conversation could not be restored")
            }
            return data
        }
    }
}
