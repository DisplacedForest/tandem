import Foundation
import GRDB

struct NativeWorkerOriginFacts: Equatable, Sendable {
    var scheduleID: String?
    var scheduleOwner: NativeScheduleOwner?
    var conversationIsCompanion: Bool?
}

enum NativeWorkerOrigin {
    static func belongsToCompanion(_ facts: NativeWorkerOriginFacts) -> Bool {
        if facts.scheduleID != nil { return facts.scheduleOwner == .dot }
        return facts.conversationIsCompanion == true
    }

    static func facts(task: NativeTaskRecord, db: Database) -> NativeWorkerOriginFacts {
        var facts = NativeWorkerOriginFacts()
        facts.scheduleID = (try? JSONDecoder().decode(NativeResearchTaskPayload.self, from: task.payload))?.scheduleID
        if let scheduleID = facts.scheduleID {
            let owner = try? String.fetchOne(db, sql: "SELECT owner FROM native_schedules WHERE id = ?", arguments: [scheduleID])
            facts.scheduleOwner = owner.flatMap { $0 }.flatMap(NativeScheduleOwner.init(rawValue:))
            return facts
        }
        let row = try? Row.fetchOne(db, sql: """
            SELECT c.origin_type, c.origin_id FROM native_engine_tasks t
            JOIN native_task_outbox o ON o.id = t.creation_key
            JOIN conversations c ON c.id = o.conversation_id
            WHERE t.id = ?
            """, arguments: [task.id])
        if let row = row.flatMap({ $0 }) {
            let type: String? = row["origin_type"]
            let id: String? = row["origin_id"]
            facts.conversationIsCompanion = type == ChatStore.veraThreadOriginType && id == ChatStore.veraThreadOriginID
        }
        return facts
    }

    static func belongsToCompanion(task: NativeTaskRecord, database: DatabaseQueue) -> Bool {
        guard let facts = try? database.read({ db in facts(task: task, db: db) }) else { return false }
        return belongsToCompanion(facts)
    }

    static func identity(_ base: NativeWorkerIdentity, task: NativeTaskRecord, database: DatabaseQueue) -> NativeWorkerIdentity {
        guard base.assistantName != nil, !belongsToCompanion(task: task, database: database) else { return base }
        var identity = base
        identity.assistantName = nil
        return identity
    }

    static func resolver(_ source: NativeWorkerIdentitySource, database: DatabaseQueue) -> @Sendable (NativeTaskRecord) -> NativeWorkerIdentity {
        { (task: NativeTaskRecord) -> NativeWorkerIdentity in
            NativePreferenceStore.identity(identity(source.current, task: task, database: database), database: database)
        }
    }
}
