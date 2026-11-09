import Foundation
import CryptoKit
import GRDB

enum NativeEffectState: String, Codable, Equatable, Sendable {
    case proposed
    case admitted
    case completed
    case uncertain
    case declined
    case expired
}

enum NativeEffectRefusal: String, Codable, Equatable, Sendable {
    case expired
    case staleRules = "stale_rules"
    case staleGrants = "stale_grants"
    case staleGeneration = "stale_generation"
    case digestMismatch = "digest_mismatch"
    case declined
    case notFound = "not_found"
    case alreadySettled = "already_settled"
    case ruleAsks = "rule_asks"
    case ruleHandsOff = "rule_hands_off"
    case taskInactive = "task_inactive"
}

enum NativeEffectObservation: Equatable, Sendable {
    case applied(NativeJSONValue)
    case absent
    case unknown
}

enum NativeEffectLedgerError: Error, Equatable {
    case notFound
    case invalidState(NativeEffectState)
}

struct NativeEffectProposal: Codable, Equatable, Sendable {
    static let lifetime: TimeInterval = 600

    let id: String
    let taskID: String
    let generation: Int
    let toolID: String
    let function: String
    let argumentsJSON: String
    let target: String?
    let action: NativeActionClass
    let rulesRevision: Int
    let grantsRevision: Int
    let conversationID: String
    let expiresAtMilliseconds: Int64
    let idempotencyKey: String

    static func canonicalArguments(_ value: NativeJSONValue) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value.any, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func expiry(from now: Date) -> Int64 {
        milliseconds(now.addingTimeInterval(lifetime))
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    var expiresAt: Date { Date(timeIntervalSince1970: Double(expiresAtMilliseconds) / 1000) }

    var digest: String {
        let fields = [taskID, String(generation), toolID, function, argumentsJSON, target ?? "", action.rawValue,
                      String(rulesRevision), String(grantsRevision), conversationID, String(expiresAtMilliseconds), idempotencyKey]
        var data = Data()
        for field in fields {
            let value = Data(field.utf8)
            data.append(Data("\(value.count):".utf8))
            data.append(value)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func bindsReply(_ reply: NativeJSONValue?, to digest: String) -> Bool {
        guard case .object(let fields)? = reply, case .string(let bound)? = fields["digest"] else { return false }
        return bound == digest
    }
}

struct NativeEffectRecord: Equatable, Sendable {
    let proposal: NativeEffectProposal
    let digest: String
    let state: NativeEffectState
    let decisionID: String?
    let decisionReply: NativeJSONValue?
    let receipt: NativeJSONValue?
    let modelClaim: NativeJSONValue?
    let createdAt: Date
    let updatedAt: Date
}

enum NativeEffectAdmission: Equatable, Sendable {
    case admitted(NativeEffectRecord)
    case refused(NativeEffectRefusal)
}

struct NativeEffectLedgerStore: Sendable {
    let database: DatabaseQueue
    let now: @Sendable () -> Date

    init(database: DatabaseQueue, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_effect_ledger (
                id TEXT PRIMARY KEY NOT NULL,
                task_id TEXT NOT NULL,
                generation INTEGER NOT NULL,
                tool_id TEXT NOT NULL,
                function TEXT NOT NULL,
                arguments_json TEXT NOT NULL,
                target TEXT,
                action TEXT NOT NULL,
                rules_revision INTEGER NOT NULL,
                grants_revision INTEGER NOT NULL,
                conversation_id TEXT NOT NULL,
                expires_at DOUBLE NOT NULL,
                digest TEXT NOT NULL UNIQUE,
                state TEXT NOT NULL CHECK(state IN ('proposed', 'admitted', 'completed', 'uncertain', 'declined', 'expired')),
                decision_id TEXT,
                decision_reply_json TEXT,
                idempotency_key TEXT NOT NULL,
                receipt_json TEXT,
                model_claim_json TEXT,
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX native_effect_ledger_task_state ON native_effect_ledger(task_id, state)")
    }

    func propose(_ proposal: NativeEffectProposal) throws -> NativeEffectRecord {
        let digest = proposal.digest
        let stamp = now().timeIntervalSince1970
        return try database.write { db in
            if let existing = try Self.record(db, digest: digest) { return existing }
            try db.execute(sql: """
                INSERT INTO native_effect_ledger(id, task_id, generation, tool_id, function, arguments_json, target, action,
                    rules_revision, grants_revision, conversation_id, expires_at, digest, state, idempotency_key, created_at, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'proposed', ?, ?, ?)
                """, arguments: [proposal.id, proposal.taskID, proposal.generation, proposal.toolID, proposal.function,
                                 proposal.argumentsJSON, proposal.target, proposal.action.rawValue, proposal.rulesRevision,
                                 proposal.grantsRevision, proposal.conversationID, Double(proposal.expiresAtMilliseconds) / 1000,
                                 digest, proposal.idempotencyKey, stamp, stamp])
            guard let inserted = try Self.record(db, digest: digest) else { throw NativeEffectLedgerError.notFound }
            return inserted
        }
    }

    func admit(digest: String, generation: Int, rulesRevision: Int, grantsRevision: Int,
               decision: NativeRuleDecision, decisionID: String?, reply: NativeJSONValue?,
               live: (@Sendable () -> (rules: Int, grants: Int))? = nil) throws -> NativeEffectAdmission {
        let current = now()
        return try database.write { db in
            let revisions = live?() ?? (rules: rulesRevision, grants: grantsRevision)
            guard let record = try Self.record(db, digest: digest) else { return .refused(.notFound) }
            guard record.proposal.digest == digest else { return .refused(.digestMismatch) }
            switch record.state {
            case .proposed: break
            case .declined: return .refused(.declined)
            case .expired: return .refused(.expired)
            case .admitted, .completed, .uncertain: return .refused(.alreadySettled)
            }
            if current > record.proposal.expiresAt {
                try Self.transition(db, digest: digest, to: .expired, at: current)
                return .refused(.expired)
            }
            guard let task = try Row.fetchOne(db, sql: "SELECT state, generation, cancel_requested FROM native_engine_tasks WHERE id = ?",
                                              arguments: [record.proposal.taskID]),
                  (task["state"] as String) == NativeTaskState.running.rawValue, (task["cancel_requested"] as Int) == 0 else {
                return .refused(.taskInactive)
            }
            if (task["generation"] as Int) != generation { return .refused(.staleGeneration) }
            switch decision {
            case .ask: if record.proposal.generation > generation { return .refused(.staleGeneration) }
            default: if record.proposal.generation != generation { return .refused(.staleGeneration) }
            }
            if record.proposal.rulesRevision != rulesRevision || record.proposal.rulesRevision != revisions.rules { return .refused(.staleRules) }
            if record.proposal.grantsRevision != grantsRevision || record.proposal.grantsRevision != revisions.grants { return .refused(.staleGrants) }
            switch decision {
            case .handOff: return .refused(.ruleHandsOff)
            case .ask:
                guard let decisionID, !decisionID.isEmpty, NativeEffectProposal.bindsReply(reply, to: digest) else { return .refused(.ruleAsks) }
            case .act: break
            }
            try db.execute(sql: """
                UPDATE native_effect_ledger SET state = 'admitted', decision_id = ?, decision_reply_json = ?, updated_at = ?
                WHERE digest = ? AND state = 'proposed'
                """, arguments: [decisionID, reply.map(NativeEffectProposal.canonicalArguments), current.timeIntervalSince1970, digest])
            guard db.changesCount == 1, let admitted = try Self.record(db, digest: digest) else { return .refused(.alreadySettled) }
            return .admitted(admitted)
        }
    }

    func settle(digest: String, receipt: NativeJSONValue?, modelClaim: NativeJSONValue?) throws {
        let stamp = now().timeIntervalSince1970
        try database.write { db in
            try Self.require(db, digest: digest, in: .admitted)
            try db.execute(sql: """
                UPDATE native_effect_ledger SET state = 'completed', receipt_json = ?, model_claim_json = ?, updated_at = ?
                WHERE digest = ? AND state = 'admitted'
                """, arguments: [receipt.map(NativeEffectProposal.canonicalArguments), modelClaim.map(NativeEffectProposal.canonicalArguments), stamp, digest])
        }
    }

    func markUncertain(digest: String, reason: String) throws {
        let stamp = now().timeIntervalSince1970
        try database.write { db in
            try Self.require(db, digest: digest, in: .admitted)
            try db.execute(sql: """
                UPDATE native_effect_ledger SET state = 'uncertain', receipt_json = ?, updated_at = ?
                WHERE digest = ? AND state = 'admitted'
                """, arguments: [Self.reasonJSON(reason), stamp, digest])
        }
    }

    func decline(digest: String, decisionID: String?, reply: NativeJSONValue?) throws {
        let stamp = now().timeIntervalSince1970
        try database.write { db in
            try Self.require(db, digest: digest, in: .proposed)
            try db.execute(sql: """
                UPDATE native_effect_ledger SET state = 'declined', decision_id = ?, decision_reply_json = ?, updated_at = ?
                WHERE digest = ? AND state = 'proposed'
                """, arguments: [decisionID, reply.map(NativeEffectProposal.canonicalArguments), stamp, digest])
        }
    }

    func observe(digest: String, _ observation: NativeEffectObservation) throws {
        let stamp = now().timeIntervalSince1970
        try database.write { db in
            try Self.require(db, digest: digest, in: .uncertain)
            switch observation {
            case .applied(let receipt):
                let body = NativeEffectProposal.canonicalArguments(.object(["observed": .string("applied"), "receipt": receipt]))
                try db.execute(sql: "UPDATE native_effect_ledger SET state = 'completed', receipt_json = ?, updated_at = ? WHERE digest = ? AND state = 'uncertain'",
                               arguments: [body, stamp, digest])
            case .absent:
                let body = NativeEffectProposal.canonicalArguments(.object(["observed": .string("absent")]))
                try db.execute(sql: "UPDATE native_effect_ledger SET receipt_json = ?, updated_at = ? WHERE digest = ? AND state = 'uncertain'",
                               arguments: [body, stamp, digest])
            case .unknown:
                break
            }
        }
    }

    func abandonAdmitted(taskID: String) throws -> Int {
        let stamp = now().timeIntervalSince1970
        return try database.write { db in
            try db.execute(sql: "UPDATE native_effect_ledger SET state = 'uncertain', receipt_json = ?, updated_at = ? WHERE task_id = ? AND state = 'admitted'",
                           arguments: [Self.reasonJSON("interrupted"), stamp, taskID])
            return db.changesCount
        }
    }

    func record(taskID: String, idempotencyKey: String) throws -> NativeEffectRecord? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM native_effect_ledger WHERE task_id = ? AND idempotency_key = ? ORDER BY created_at DESC, id LIMIT 1",
                             arguments: [taskID, idempotencyKey]).map(Self.record(row:))
        }
    }

    func expireStale() throws -> Int {
        let current = now().timeIntervalSince1970
        return try database.write { db in
            try db.execute(sql: "UPDATE native_effect_ledger SET state = 'expired', updated_at = ? WHERE state = 'proposed' AND expires_at < ?",
                           arguments: [current, current])
            return db.changesCount
        }
    }

    func recoverAtBringUp() throws -> [NativeEffectRecord] {
        let stamp = now().timeIntervalSince1970
        return try database.write { db in
            guard try db.tableExists("native_effect_ledger") else { return [] }
            let digests = try String.fetchAll(db, sql: "SELECT digest FROM native_effect_ledger WHERE state = 'admitted' ORDER BY created_at, id")
            guard !digests.isEmpty else { return [] }
            try db.execute(sql: "UPDATE native_effect_ledger SET state = 'uncertain', receipt_json = ?, updated_at = ? WHERE state = 'admitted'",
                           arguments: [Self.reasonJSON("interrupted"), stamp])
            return try digests.compactMap { try Self.record(db, digest: $0) }
        }
    }

    func records(taskID: String) throws -> [NativeEffectRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM native_effect_ledger WHERE task_id = ? ORDER BY created_at, id", arguments: [taskID])
                .map(Self.record(row:))
        }
    }

    func record(digest: String) throws -> NativeEffectRecord? {
        try database.read { db in try Self.record(db, digest: digest) }
    }

    private static func reasonJSON(_ reason: String) -> String {
        NativeEffectProposal.canonicalArguments(.object(["reason": .string(reason)]))
    }

    private static func require(_ db: Database, digest: String, in state: NativeEffectState) throws {
        guard let record = try record(db, digest: digest) else { throw NativeEffectLedgerError.notFound }
        guard record.state == state else { throw NativeEffectLedgerError.invalidState(record.state) }
    }

    private static func transition(_ db: Database, digest: String, to state: NativeEffectState, at date: Date) throws {
        try db.execute(sql: "UPDATE native_effect_ledger SET state = ?, updated_at = ? WHERE digest = ?",
                       arguments: [state.rawValue, date.timeIntervalSince1970, digest])
    }

    private static func record(_ db: Database, digest: String) throws -> NativeEffectRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM native_effect_ledger WHERE digest = ?", arguments: [digest]).map(record(row:))
    }

    private static func record(row: Row) throws -> NativeEffectRecord {
        guard let action = NativeActionClass(rawValue: row["action"]),
              let state = NativeEffectState(rawValue: row["state"]) else { throw NativeEffectLedgerError.notFound }
        let expires: Double = row["expires_at"]
        let proposal = NativeEffectProposal(
            id: row["id"], taskID: row["task_id"], generation: row["generation"], toolID: row["tool_id"], function: row["function"],
            argumentsJSON: row["arguments_json"], target: row["target"], action: action, rulesRevision: row["rules_revision"],
            grantsRevision: row["grants_revision"], conversationID: row["conversation_id"],
            expiresAtMilliseconds: Int64((expires * 1000).rounded()), idempotencyKey: row["idempotency_key"])
        return NativeEffectRecord(
            proposal: proposal, digest: row["digest"], state: state, decisionID: row["decision_id"],
            decisionReply: json(row["decision_reply_json"]), receipt: json(row["receipt_json"]), modelClaim: json(row["model_claim_json"]),
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }

    private static func json(_ text: String?) -> NativeJSONValue? {
        guard let text, let any = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { return nil }
        return try? NativeJSONValue(any: any)
    }
}
