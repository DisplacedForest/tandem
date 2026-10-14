import CryptoKit
import Foundation
import GRDB

struct NativeDomainProposal: Codable, Hashable, Sendable {
    let entry: NativeDomainEntry
    let expectedRevision: Int
    let label: String
}

struct NativeUpcomingSubject: Identifiable, Sendable {
    let entityID: UUID
    let scope: String
    let label: String
    let entries: [NativeDomainEntry]
    let sources: [NativeDomainCitation]
    var id: String { entityID.uuidString + "|" + scope }
}

struct NativeDomainCitation: Identifiable, Sendable {
    let id: UUID
    let source: NativeDomainSource
    let text: String
    var entry: NativeDomainEntry? = nil
    var supersededAt: Date? = nil
    var superseded = false
}

extension LocalChatRepository {
    static func domainJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func domainHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func domainKey(_ entry: NativeDomainEntry) throws -> String {
        var object = try JSONSerialization.jsonObject(with: Data(domainJSON(entry).utf8)) as! [String: Any]
        object.removeValue(forKey: "id")
        object.removeValue(forKey: "learnedAt")
        return domainHash(String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self))
    }

    static func migrateDomainState(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_domain_streams (
                entity_id TEXT NOT NULL, scope TEXT NOT NULL, label TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0, memory_id TEXT, disabled INTEGER NOT NULL DEFAULT 0,
                has_stock INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(entity_id, scope)
            );
            CREATE TABLE native_domain_entries (
                id TEXT PRIMARY KEY NOT NULL, entity_id TEXT NOT NULL, scope TEXT NOT NULL,
                entry_json TEXT NOT NULL, source_key TEXT NOT NULL UNIQUE,
                source_conversation_id TEXT, source_message_id TEXT, source_text TEXT,
                FOREIGN KEY(entity_id, scope) REFERENCES native_domain_streams(entity_id, scope)
            );
            CREATE TABLE native_domain_projection_sources (
                memory_id TEXT NOT NULL REFERENCES native_memories(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL, entry_id TEXT NOT NULL REFERENCES native_domain_entries(id),
                PRIMARY KEY(memory_id, revision, entry_id)
            );
            CREATE TRIGGER domain_entry_redaction AFTER UPDATE OF source_text ON native_domain_entries
                WHEN new.source_text IS NULL AND old.source_text IS NOT NULL BEGIN
                DELETE FROM native_memory_proposals WHERE json_extract(proposal_json, '$.domain.entry.entityID') = new.entity_id
                    AND json_extract(proposal_json, '$.domain.entry.scope') = new.scope;
                DELETE FROM native_memories WHERE id IN (
                    SELECT memory_id FROM native_domain_streams WHERE entity_id = new.entity_id AND scope = new.scope);
                UPDATE native_domain_streams SET revision = revision + 1, memory_id = NULL, label = 'Saved record'
                    WHERE entity_id = new.entity_id AND scope = new.scope;
            END;
            """)
        let redaction = """
            UPDATE native_domain_entries SET source_text = NULL, source_message_id = NULL, source_conversation_id = NULL,
                entry_json = json_remove(json_set(entry_json, '$.status', 'deleted'), '$.source', '$.actor', '$.payload', '$.validUntil')
            """
        for (name, event, condition, match) in [
            ("message_change", "AFTER UPDATE ON messages", "WHEN new.content != old.content OR new.state != 'complete' OR new.failure IS NOT NULL", "source_message_id = old.id"),
            ("message_delete", "BEFORE DELETE ON messages", "", "source_message_id = old.id"),
            ("exclusion", "AFTER UPDATE OF memory_excluded ON conversations", "WHEN new.memory_excluded = 1", "source_conversation_id = new.id"),
            ("conversation_delete", "BEFORE DELETE ON conversations", "", "source_conversation_id = old.id")
        ] {
            try db.execute(sql: """
                CREATE TRIGGER domain_source_\(name) \(event) \(condition) BEGIN
                    \(redaction) WHERE \(match);
                    DELETE FROM native_memory_proposals WHERE \(match) AND json_extract(proposal_json, '$.domain') IS NOT NULL;
                END;
                """)
        }
    }

    static func domainSourceText(_ source: NativeDomainSource, db: Database) throws -> String {
        guard let text = try String.fetchOne(db, sql: """
            SELECT m.content FROM messages m JOIN conversations c ON c.id = m.conversation_id
            WHERE m.id = ? AND c.id = ? AND c.memory_excluded = 0 AND m.role = 'user'
              AND m.state = 'complete' AND m.failure IS NULL
            """, arguments: [source.messageID, source.conversationID]),
              domainHash(text) == source.version, !NativeMemorySafety.containsSensitiveData(text),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("private:"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("do not remember") else { throw NativeDomainError.sourceUnavailable }
        let bytes = Array(text.utf8)
        guard source.lowerUTF8 >= 0, source.upperUTF8 <= bytes.count, source.upperUTF8 > source.lowerUTF8,
              let span = String(bytes: bytes[source.lowerUTF8..<source.upperUTF8], encoding: .utf8),
              !span.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeDomainError.invalid }
        return span
    }

    static func domainEntries(_ entity: UUID, scope: String, db: Database) throws -> [NativeDomainEntry] {
        try String.fetchAll(db, sql: "SELECT entry_json FROM native_domain_entries WHERE entity_id = ? AND scope = ? ORDER BY id",
            arguments: [entity.uuidString, scope]).map { try JSONDecoder().decode(NativeDomainEntry.self, from: Data($0.utf8)) }
    }

    func domainEntries(_ entity: UUID, scope: String) throws -> [NativeDomainEntry] {
        try database.read { try Self.domainEntries(entity, scope: scope, db: $0) }
    }

    func stageDomainProposal(_ entry: NativeDomainEntry, label: String, proposalID: String = UUID().uuidString) throws -> NativeMemoryProposal? {
        try entry.validate()
        guard entry.status == .supported || entry.status == .uncertain || entry.status == .disputed,
              let source = entry.source, !label.isEmpty, label.count <= 80,
              !NativeMemorySafety.containsSensitiveData(label) else { throw NativeDomainError.invalid }
        return try database.write { db in
            _ = try Self.domainSourceText(source, db: db)
            let key = try Self.domainKey(entry)
            if let existing = try String.fetchOne(db, sql: "SELECT source_key FROM native_domain_entries WHERE id = ? OR source_key = ?", arguments: [entry.id.uuidString, key]) {
                guard existing == key else { throw NativeDomainError.conflict }
                return nil
            }
            if let raw = try String.fetchOne(db, sql: "SELECT proposal_json FROM native_memory_proposals WHERE id = ?", arguments: [proposalID]) {
                let previous = try JSONDecoder().decode(NativeMemoryProposal.self, from: Data(raw.utf8))
                guard let domain = previous.domain, try Self.domainKey(domain.entry) == key, domain.label == label else { throw NativeDomainError.conflict }
                return previous.status == .pending ? previous : nil
            }
            try db.execute(sql: "INSERT OR IGNORE INTO native_domain_streams(entity_id, scope, label) VALUES (?, ?, ?)", arguments: [entry.entityID.uuidString, entry.scope, "Saved record"])
            guard let stream = try Row.fetchOne(db, sql: "SELECT revision, disabled FROM native_domain_streams WHERE entity_id = ? AND scope = ?", arguments: [entry.entityID.uuidString, entry.scope]),
                  (stream["disabled"] as Int) == 0 else { throw NativeDomainError.changed }
            let proposal = try Self.domainProposal(entry, label: label, proposalID: proposalID, learned: Date(), revision: stream["revision"], db: db)
            try db.execute(sql: """
                INSERT INTO native_memory_proposals(id, kind, status, target_ids_json, source_conversation_id, source_message_id, created_at, proposal_json)
                VALUES (?, 'create', 'pending', '[]', ?, ?, ?, ?)
                """, arguments: [proposal.id, proposal.sourceConversationID, proposal.sourceMessageID, proposal.createdAt.timeIntervalSince1970, try Self.domainJSON(proposal)])
            return proposal
        }
    }

    static func domainProposal(_ entry: NativeDomainEntry, label: String, proposalID: String, learned: Date, revision: Int,
                               db: Database) throws -> NativeMemoryProposal {
        guard let source = entry.source else { throw NativeDomainError.invalid }
        let span = try domainSourceText(source, db: db)
        let staged = NativeDomainEntry(id: entry.id, entityID: entry.entityID, scope: entry.scope, occurredAt: entry.occurredAt,
            validUntil: entry.validUntil, learnedAt: learned, actor: entry.actor, source: source, evidence: entry.evidence,
            entityResolved: entry.entityResolved, status: entry.status, supersedes: entry.supersedes, payload: entry.payload)
        let entries = try domainEntries(entry.entityID, scope: entry.scope, db: db)
        _ = try NativeDomainProjection.active(entries + [staged], entity: entry.entityID, scope: entry.scope, at: .distantFuture, knownAt: .distantFuture)
        let replacing = try entries.filter { staged.supersedes.contains($0.id) }.flatMap { target -> [String] in
            var lines = ["Replaces: " + domainDescription(target) + " (" + target.occurredAt.formatted(date: .abbreviated, time: .standard) + ")"]
            if let source = target.source { lines.append("Earlier evidence: " + (try domainSourceText(source, db: db))) }
            return lines
        }
        let timing = "Applies from: " + staged.occurredAt.formatted(date: .abbreviated, time: .standard)
        let ending = staged.validUntil.map { ["Applies until: " + $0.formatted(date: .abbreviated, time: .standard)] } ?? []
        let proposal = NativeMemoryProposal(id: proposalID, kind: .create, title: label,
            summary: domainDescription(staged), details: [domainDescription(staged), "Library: " + entry.scope, "Attributed to: " + (entry.actor ?? "unknown"), timing] + ending + replacing + ["Original evidence: " + span],
            group: .areas, category: .other, bank: entry.scope, durability: .durable, expiry: nil, targetIDs: [],
            sourceConversationID: source.conversationID, sourceMessageID: source.messageID, createdAt: learned, status: .pending,
            domain: NativeDomainProposal(entry: staged, expectedRevision: revision, label: label),
            sourceVersion: source.version)
        guard NativeMemorySafety.proposalIsSafe(proposal) else { throw NativeDomainError.invalid }
        return proposal
    }

    static func rebaseDomainProposals(_ entity: UUID, scope: String, db: Database) throws {
        guard let revision = try Int.fetchOne(db, sql: "SELECT revision FROM native_domain_streams WHERE entity_id = ? AND scope = ? AND disabled = 0",
            arguments: [entity.uuidString, scope]) else { return }
        for raw in try String.fetchAll(db, sql: """
            SELECT proposal_json FROM native_memory_proposals WHERE status = 'pending'
              AND json_extract(proposal_json, '$.domain.entry.entityID') = ? AND json_extract(proposal_json, '$.domain.entry.scope') = ?
            """, arguments: [entity.uuidString, scope]) {
            let previous = try JSONDecoder().decode(NativeMemoryProposal.self, from: Data(raw.utf8))
            guard let domain = previous.domain, domain.expectedRevision != revision else { continue }
            let known = try String.fetchOne(db, sql: "SELECT id FROM native_domain_entries WHERE id = ? OR source_key = ?",
                arguments: [domain.entry.id.uuidString, try domainKey(domain.entry)]) != nil
            guard !known, let rebuilt = try? domainProposal(domain.entry, label: domain.label, proposalID: previous.id,
                learned: domain.entry.learnedAt, revision: revision, db: db) else {
                try db.execute(sql: "DELETE FROM native_memory_proposals WHERE id = ?", arguments: [previous.id])
                continue
            }
            try db.execute(sql: "UPDATE native_memory_proposals SET proposal_json = ? WHERE id = ?", arguments: [try domainJSON(rebuilt), previous.id])
        }
    }

    func approveDomainProposal(_ submitted: NativeMemoryProposal) throws {
        try database.write { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT proposal_json FROM native_memory_proposals WHERE id = ?", arguments: [submitted.id]) else { throw NativeDomainError.changed }
            var proposal = try JSONDecoder().decode(NativeMemoryProposal.self, from: Data(raw.utf8))
            var comparison = proposal
            comparison.status = submitted.status
            guard comparison == submitted, let domain = proposal.domain else { throw NativeDomainError.changed }
            if proposal.status == .accepted { return }
            guard proposal.status == .pending else { throw NativeDomainError.changed }
            let entry = domain.entry
            try entry.validate()
            guard let source = entry.source else { throw NativeDomainError.invalid }
            let span = try Self.domainSourceText(source, db: db)
            guard let stream = try Row.fetchOne(db, sql: "SELECT revision, disabled FROM native_domain_streams WHERE entity_id = ? AND scope = ?", arguments: [entry.entityID.uuidString, entry.scope]),
                  (stream["revision"] as Int) == domain.expectedRevision, (stream["disabled"] as Int) == 0 else { throw NativeDomainError.changed }
            let existing = try Self.domainEntries(entry.entityID, scope: entry.scope, db: db)
            _ = try NativeDomainProjection.active(existing + [entry], entity: entry.entityID, scope: entry.scope, at: .distantFuture, knownAt: .distantFuture)
            try db.execute(sql: """
                INSERT INTO native_domain_entries(id, entity_id, scope, entry_json, source_key, source_conversation_id, source_message_id, source_text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [entry.id.uuidString, entry.entityID.uuidString, entry.scope, try Self.domainJSON(entry), try Self.domainKey(entry), source.conversationID, source.messageID, span])
            try db.execute(sql: "UPDATE native_domain_streams SET revision = revision + 1, label = ? WHERE entity_id = ? AND scope = ?", arguments: [domain.label, entry.entityID.uuidString, entry.scope])
            if case .stock = entry.payload {
                try db.execute(sql: "UPDATE native_domain_streams SET has_stock = 1 WHERE entity_id = ? AND scope = ?", arguments: [entry.entityID.uuidString, entry.scope])
            }
            try Self.refreshDomainProjection(entry.entityID, scope: entry.scope, now: Date(), db: db)
            proposal.status = .accepted
            try db.execute(sql: "UPDATE native_memory_proposals SET status = 'accepted', proposal_json = ? WHERE id = ?", arguments: [try Self.domainJSON(proposal), proposal.id])
            try Self.writeChange(NativeMemoryChange(id: UUID().uuidString, memoryID: nil, proposalID: proposal.id,
                decision: .accepted, note: "Approved evidence-backed record", createdAt: Date()), db: db)
            try Self.rebaseDomainProposals(entry.entityID, scope: entry.scope, db: db)
        }
    }

    static func domainDescription(_ entry: NativeDomainEntry) -> String {
        let evidence: String = switch entry.evidence {
        case .asserted: ""
        case .negated: "Source denies this: "
        case .hypothetical: "Hypothetical, not established: "
        case .reported: "Reported by someone else, unconfirmed: "
        case .ambiguous: "Meaning unclear: "
        }
        let qualifier = (entry.entityResolved ? "" : "Subject unclear: ")
            + (entry.status == .supported ? "" : "Needs clarification: ") + evidence
        switch entry.payload {
        case .stock(let kind, let quantity):
            let label: String = switch kind {
            case .baseline: "Observed count"
            case .addition: "Added"
            case .removal: "Removed"
            case .purchase: "Purchased, ownership not established"
            case .mention: "Mentioned, ownership not established"
            }
            return qualifier + "\(label): \(quantity.amount)"
        case .fact(let predicate, let value, let quantity):
            return qualifier + predicate + ": " + value + (quantity.map { " (\($0.amount) \($0.unit.rawValue))" } ?? "")
        case .care(let activity, let status):
            let label: String = switch status {
            case .completed: "completed"
            case .planned: "planned, not completed"
            case .recommended: "recommended, not completed"
            case .possible: "possible, not completed"
            case .notOccurred: "did not occur"
            }
            return qualifier + activity + ": " + label
        case .retraction: return "Retract the referenced evidence"
        case nil: return "Original evidence removed"
        }
    }

    func refreshDomainProjections(now: Date = Date()) throws {
        try database.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT entity_id, scope FROM native_domain_streams WHERE disabled = 0") {
                guard let id = UUID(uuidString: row["entity_id"]) else { throw NativeDomainError.invalid }
                try Self.refreshDomainProjection(id, scope: row["scope"], now: now, db: db)
            }
        }
    }

    static func refreshDomainProjection(_ entity: UUID, scope: String, now: Date, db: Database) throws {
        guard let stream = try Row.fetchOne(db, sql: "SELECT * FROM native_domain_streams WHERE entity_id = ? AND scope = ? AND disabled = 0", arguments: [entity.uuidString, scope]) else { return }
        let entries = try domainEntries(entity, scope: scope, db: db)
        guard let state = try projectedState(entries, entity: entity, scope: scope, hasStock: (stream["has_stock"] as Int) == 1, now: now) else {
            if let id: String = stream["memory_id"] { try db.execute(sql: "DELETE FROM native_memories WHERE id = ?", arguments: [id]) }
            try db.execute(sql: "UPDATE native_domain_streams SET memory_id = NULL WHERE entity_id = ? AND scope = ?", arguments: [entity.uuidString, scope])
            return
        }
        let active = state.active
        let details = state.details
        let basis = state.basis
        let selected = entries.filter { basis.contains($0.id) && $0.source != nil }.sorted { $0.id.uuidString < $1.id.uuidString }
        let primary = selected.max { $0.learnedAt < $1.learnedAt }
        let id: String = (stream["memory_id"] as String?) ?? UUID().uuidString
        let existing = try String.fetchOne(db, sql: "SELECT record_json FROM native_memories WHERE id = ?", arguments: [id]).map { try JSONDecoder().decode(NativeMemoryRecord.self, from: Data($0.utf8)) }
        var memory = NativeMemoryRecord(id: id, title: stream["label"], summary: String(details[0].prefix(180)),
            details: Array(details.prefix(8)), group: .areas, category: .other, bank: scope, durability: .durable,
            expiry: active.compactMap(\.validUntil).min(), status: .approved, embedding: nil,
            sourceConversationID: primary?.source?.conversationID, sourceMessageID: primary?.source?.messageID,
            createdAt: existing?.createdAt ?? now, updatedAt: existing?.updatedAt ?? now, domainEntityID: entity,
            domainRevision: stream["revision"])
        if var previous = existing {
            previous.embedding = nil
            if previous == memory { return }
        }
        memory.updatedAt = now
        guard NativeMemorySafety.recordIsSafe(memory) else { throw NativeDomainError.invalid }
        if existing == nil, (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_memories WHERE status = 'approved'") ?? 0) >= NativeMemoryRecall.capacity {
            throw NativeDomainError.changed
        }
        try writeMemory(memory, db: db)
        try preserveMemoryEvidence(memory, db: db)
        let revision = try Int.fetchOne(db, sql: "SELECT MAX(revision) FROM native_memory_revisions WHERE memory_id = ?", arguments: [id])!
        for entry in selected {
            try db.execute(sql: "INSERT OR IGNORE INTO native_domain_projection_sources(memory_id, revision, entry_id) VALUES (?, ?, ?)", arguments: [id, revision, entry.id.uuidString])
        }
        try db.execute(sql: "UPDATE native_domain_streams SET memory_id = ? WHERE entity_id = ? AND scope = ?", arguments: [id, entity.uuidString, scope])
    }

    static func projectedState(_ entries: [NativeDomainEntry], entity: UUID, scope: String, hasStock: Bool,
                               now: Date) throws -> (active: [NativeDomainEntry], details: [String], basis: Set<UUID>)? {
        let active = try NativeDomainProjection.active(entries, entity: entity, scope: scope, at: now, knownAt: now)
        guard !active.isEmpty else { return nil }
        var details: [String] = []
        var basis = Set(active.filter { !$0.supersedes.isEmpty }.map(\.id))
        if hasStock {
            let stock = try NativeDomainProjection.stock(entries, entity: entity, scope: scope, at: now, knownAt: now)
            details.append(stock.quantity.map { "Current count: " + $0.amount } ?? (stock.reason ?? "The current count is uncertain."))
            basis.formUnion(stock.evidenceIDs)
        }
        let facts = Dictionary(grouping: active.filter { if case .fact = $0.payload { return true }; return false }) { entry -> String in
            if case .fact(let predicate, _, _) = entry.payload { return predicate }; return ""
        }
        for predicate in facts.keys.sorted() {
            let values = facts[predicate]!
            let newest = values.map(\.occurredAt).max()!
            let current = values.filter { $0.occurredAt == newest }
            let descriptions = Set(current.map(domainDescription))
            let expiredNewer = entries.contains { entry in
                guard entry.occurredAt >= newest, entry.occurredAt <= now, entry.learnedAt <= now,
                      entry.validUntil.map({ $0 <= now }) == true,
                      case .fact(let name, _, _) = entry.payload else { return false }
                return name == predicate
            }
            if expiredNewer {
                details.append(predicate + ": the latest evidence expired; the current value is unknown")
            } else if active.contains(where: { $0.status == .deleted && $0.occurredAt >= newest }) {
                details.append(predicate + ": evidence was removed; the current value is unknown")
            } else {
                details.append(descriptions.count == 1 ? descriptions.first! : predicate + ": conflicting evidence needs review")
            }
            basis.formUnion(current.map(\.id))
        }
        let completed = Set(try NativeDomainProjection.completedCare(entries, entity: entity, scope: scope, at: now, knownAt: now).map(\.id))
        for entry in active {
            guard case .care(_, let status) = entry.payload else { continue }
            if status == .completed && !completed.contains(entry.id) { details.append("Care completion needs clarification.") }
            else { details.append(domainDescription(entry)) }
            basis.insert(entry.id)
        }
        if details.isEmpty { details = ["No confirmed current state is established by this evidence."]; basis.formUnion(active.map(\.id)) }
        return (active, details, basis)
    }

    func domainProjectionPreview(_ entry: NativeDomainEntry, now: Date = Date()) throws -> [String] {
        try database.read { db in
            let existing = try Self.domainEntries(entry.entityID, scope: entry.scope, db: db).filter { $0.id != entry.id }
            let streamStock = try Int.fetchOne(db, sql: "SELECT has_stock FROM native_domain_streams WHERE entity_id = ? AND scope = ?",
                arguments: [entry.entityID.uuidString, entry.scope]) == 1
            var hasStock = streamStock
            if case .stock = entry.payload { hasStock = true }
            return try Self.projectedState(existing + [entry], entity: entry.entityID, scope: entry.scope,
                hasStock: hasStock, now: max(now, entry.learnedAt))?.details ?? []
        }
    }

    static func supersession(of entry: NativeDomainEntry, in entries: [NativeDomainEntry], now: Date) -> (superseded: Bool, at: Date?) {
        let replacements = entries.filter {
            $0.supersedes.contains(entry.id) && $0.occurredAt <= now && $0.learnedAt <= now
                && ($0.status == .supported || $0.status == .deleted) && $0.entityResolved && $0.evidence == .asserted
        }
        return (!replacements.isEmpty || entry.status == .superseded, replacements.map(\.occurredAt).max())
    }

    static func redactDomainMemory(_ id: String, db: Database) throws {
        guard let stream = try Row.fetchOne(db, sql: "SELECT entity_id, scope FROM native_domain_streams WHERE memory_id = ?", arguments: [id]) else { return }
        try redactDomainStream(stream["entity_id"], scope: stream["scope"], db: db)
    }

    func revokeUnprojectedDomainStreams() throws {
        try database.write { db in
            for row in try Row.fetchAll(db, sql: """
                SELECT entity_id, scope FROM native_domain_streams s WHERE disabled = 0 AND memory_id IS NULL
                  AND EXISTS (SELECT 1 FROM native_domain_entries e WHERE e.entity_id = s.entity_id AND e.scope = s.scope)
                """) {
                try Self.redactDomainStream(row["entity_id"], scope: row["scope"], db: db)
            }
        }
    }

    static func redactDomainStream(_ entity: String, scope: String, db: Database) throws {
        try db.execute(sql: "UPDATE native_domain_streams SET disabled = 1 WHERE entity_id = ? AND scope = ?", arguments: [entity, scope])
        try db.execute(sql: "DELETE FROM native_memory_proposals WHERE json_extract(proposal_json, '$.domain.entry.entityID') = ? AND json_extract(proposal_json, '$.domain.entry.scope') = ?", arguments: [entity, scope])
        try db.execute(sql: """
            UPDATE native_domain_entries SET source_text = NULL, source_message_id = NULL, source_conversation_id = NULL,
                entry_json = json_remove(json_set(entry_json, '$.status', 'deleted'), '$.source', '$.actor', '$.payload', '$.validUntil')
            WHERE entity_id = ? AND scope = ?
            """, arguments: [entity, scope])
    }

    func domainCitations(_ memoryID: String, revision: Int, now: Date = Date()) throws -> [NativeDomainCitation] {
        try database.read { try Self.domainCitations(memoryID, revision: revision, now: now, db: $0) }
    }

    static func domainCitations(_ memoryID: String, revision: Int, now: Date = Date(), db: Database) throws -> [NativeDomainCitation] {
        var streams: [String: [NativeDomainEntry]] = [:]
        return try Row.fetchAll(db, sql: """
            SELECT e.entry_json, e.source_text FROM native_domain_projection_sources p
            JOIN native_domain_entries e ON e.id = p.entry_id WHERE p.memory_id = ? AND p.revision = ? ORDER BY e.id
            """, arguments: [memoryID, revision]).compactMap { row in
                let entry = try JSONDecoder().decode(NativeDomainEntry.self, from: Data((row["entry_json"] as String).utf8))
                guard let source = entry.source, let text: String = row["source_text"] else { return nil }
                let key = entry.entityID.uuidString + "|" + entry.scope
                if streams[key] == nil { streams[key] = try domainEntries(entry.entityID, scope: entry.scope, db: db) }
                let state = supersession(of: entry, in: streams[key] ?? [], now: now)
                return NativeDomainCitation(id: entry.id, source: source, text: text, entry: entry,
                    supersededAt: state.at, superseded: state.superseded)
            }
    }

    static func upcomingCare(_ entries: [NativeDomainEntry], now: Date) -> [NativeDomainEntry] {
        let replaced = Set(entries.filter { ($0.status == .supported || $0.status == .deleted) && $0.entityResolved && $0.evidence == .asserted }.flatMap(\.supersedes))
        return entries.filter { entry in
            guard case .care(_, .planned) = entry.payload, entry.status == .supported, entry.occurredAt > now,
                  !replaced.contains(entry.id), entry.validUntil.map({ $0 > now }) ?? true else { return false }
            return true
        }.sorted { $0.occurredAt < $1.occurredAt }
    }

    func upcomingDomainCare(now: Date = Date()) throws -> [String: [NativeDomainEntry]] {
        try database.read { db in
            var result: [String: [NativeDomainEntry]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT entity_id, scope, memory_id FROM native_domain_streams WHERE disabled = 0 AND memory_id IS NOT NULL") {
                guard let entity = UUID(uuidString: row["entity_id"]) else { continue }
                let upcoming = Self.upcomingCare(try Self.domainEntries(entity, scope: row["scope"], db: db), now: now)
                if !upcoming.isEmpty { result[row["memory_id"]] = upcoming }
            }
            return result
        }
    }

    func upcomingOnlySubjects(now: Date = Date()) throws -> [NativeUpcomingSubject] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT entity_id, scope, label FROM native_domain_streams WHERE disabled = 0 AND memory_id IS NULL ORDER BY label, scope").compactMap { row in
                guard let entity = UUID(uuidString: row["entity_id"]) else { return nil }
                let scope: String = row["scope"]
                let upcoming = Self.upcomingCare(try Self.domainEntries(entity, scope: scope, db: db), now: now)
                guard !upcoming.isEmpty else { return nil }
                let sources = try upcoming.compactMap { entry -> NativeDomainCitation? in
                    guard let source = entry.source, let text = try String.fetchOne(db, sql: "SELECT source_text FROM native_domain_entries WHERE id = ?",
                        arguments: [entry.id.uuidString]) else { return nil }
                    return NativeDomainCitation(id: entry.id, source: source, text: text, entry: entry)
                }
                return NativeUpcomingSubject(entityID: entity, scope: scope, label: row["label"], entries: upcoming, sources: sources)
            }
        }
    }

    func memoriesWithUnavailableSources() throws -> Set<String> {
        try database.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT m.id FROM native_memories m
                LEFT JOIN conversations c ON c.id = m.source_conversation_id
                WHERE m.status != 'deleted' AND m.source_message_id IS NOT NULL
                  AND json_extract(m.record_json, '$.domainEntityID') IS NULL
                  AND NOT (\(Self.sourceEligibleSQL))
                """))
        }
    }
}

extension NativeMemoryProposal {
    var displayLabel: String {
        if let domain, !domain.entry.supersedes.isEmpty { return NativeMemoryProposalKind.update.label }
        return kind.label
    }
}

extension NativeUpcomingSubject {
    var libraryGroup: NativeMemoryGroup { .areas }
}

extension NativeMemoryLibraryFilter {
    func matchingEntries(_ subject: NativeUpcomingSubject, now: Date = Date()) -> [NativeDomainEntry] {
        subject.entries.filter { entry in
            switch expiry {
            case .all: true
            case .active: entry.validUntil.map { $0 > now } ?? true
            case .expired: entry.validUntil.map { $0 <= now } ?? false
            case .noExpiry: entry.validUntil == nil
            case .scheduled: entry.validUntil.map { $0 > now } ?? false
            }
        }
    }

    func matches(_ subject: NativeUpcomingSubject, now: Date = Date()) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let activities = subject.entries.compactMap { entry -> String? in
            if case .care(let activity, _) = entry.payload { return activity }
            return nil
        }
        return (normalized.isEmpty || subject.label.lowercased().contains(normalized)
                || activities.contains { $0.lowercased().contains(normalized) })
            && (group == nil || group == subject.libraryGroup)
            && (bank == nil || bank == subject.scope)
            && (category == nil || category == .other)
            && (status == nil || status == .approved)
            && !matchingEntries(subject, now: now).isEmpty
    }
}
