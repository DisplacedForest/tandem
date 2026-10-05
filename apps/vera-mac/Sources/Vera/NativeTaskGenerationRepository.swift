import Foundation
import GRDB

extension LocalChatRepository: NativeTaskGenerationRepository {
    func reserveTaskGeneration(referenceID: UUID, job: NativeTaskGenerationJob) throws -> NativeTaskGenerationReservation {
        try database.write { db in
            guard let reference = try Self.readTaskReference(db, id: referenceID),
                  let profile = reference.profile else { throw NativeTaskError.persistenceUnavailable }
            try job.validate(reference: reference)
            if let row = try Row.fetchOne(db, sql: """
                SELECT messages_digest, state, response, failure, reserved_until FROM native_task_generations
                WHERE request_id = ? AND generation_key = ?
                """, arguments: [referenceID.uuidString, job.key]) {
                let digest: String = row["messages_digest"]
                guard digest == job.messagesDigest else { return .unavailable("request_conflict") }
                let state: String = row["state"]
                if state == "completed", let response: String = row["response"] { return .completed(response) }
                let deadline: Double = row["reserved_until"]
                if state == "reserved" && deadline > Date().timeIntervalSince1970
                    && deadline <= Date().timeIntervalSince1970 + 180 { return .pending }
                return .unavailable((row["failure"] as String?) ?? "previous_request_uncertain")
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_task_generations WHERE request_id = ?",
                                        arguments: [referenceID.uuidString]) ?? 0
            guard count < profile.limits.maximumRequests else { return .unavailable("request_limit") }
            try db.execute(sql: """
                INSERT INTO native_task_generations(request_id, generation_key, messages_digest, reserved_until, state)
                VALUES (?, ?, ?, ?, 'reserved')
                """, arguments: [referenceID.uuidString, job.key, job.messagesDigest, Date().timeIntervalSince1970 + job.deadlineSeconds])
            return .execute
        }
    }

    func finishTaskGeneration(referenceID: UUID, job: NativeTaskGenerationJob,
                              response: String?, failure: String?) throws {
        let allowedFailures: Set<String> = ["provider_unavailable", "provider_auth", "provider_quota",
            "provider_response", "canceled", "request_timeout", "profile_changed", "credential_unavailable"]
        guard (response == nil) != (failure == nil), response.map({ $0.utf8.count <= 262144 }) ?? true,
              failure.map({ allowedFailures.contains($0) }) ?? true else { throw NativeTaskHTTPError.invalidResponse }
        try database.write { db in
            guard let reference = try Self.readTaskReference(db, id: referenceID), !reference.cancelRequested else {
                try db.execute(sql: """
                    UPDATE native_task_generations SET state = 'failed', failure = 'canceled', response = NULL
                    WHERE request_id = ? AND generation_key = ? AND state = 'reserved'
                    """, arguments: [referenceID.uuidString, job.key])
                return
            }
            try db.execute(sql: """
                UPDATE native_task_generations SET state = ?, response = ?, failure = ?
                WHERE request_id = ? AND generation_key = ? AND messages_digest = ? AND state = 'reserved' AND reserved_until >= ?
                """, arguments: [response == nil ? "failed" : "completed", response, failure,
                                   referenceID.uuidString, job.key, job.messagesDigest, Date().timeIntervalSince1970])
            guard db.changesCount == 1 else { throw NativeTaskHTTPError.invalidResponse }
        }
    }
}
