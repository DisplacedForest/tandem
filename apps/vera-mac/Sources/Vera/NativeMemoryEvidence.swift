import CryptoKit
import Foundation
import GRDB

struct NativeMemoryEvidence: Identifiable, Sendable {
    let revision: Int
    let record: NativeMemoryRecord
    let sourceText: String?
    let sourceVersion: String?
    var domainSources: [NativeDomainCitation] = []
    var id: Int { revision }
}

enum NativeMemoryEvidenceError: LocalizedError {
    case removed
    case unavailable
    case changed
    var errorDescription: String? {
        switch self {
        case .changed: "This memory changed. Open it again before saving."
        case .removed: "This memory was removed. Create a new memory to save it again."
        case .unavailable: "The source is no longer available for memory."
        }
    }
}

extension LocalChatRepository {
    static func migrateMemoryEvidence(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_memory_revisions (
                memory_id TEXT NOT NULL REFERENCES native_memories(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL,
                record_json TEXT NOT NULL,
                source_conversation_id TEXT,
                source_message_id TEXT,
                source_text TEXT,
                source_version TEXT,
                PRIMARY KEY(memory_id, revision)
            );
            CREATE VIRTUAL TABLE native_memory_fts USING fts5(memory_id UNINDEXED, title, summary, details, tokenize='unicode61');
            INSERT INTO native_memory_fts SELECT id, title, summary, details_json FROM native_memories WHERE status = 'approved';
            CREATE TRIGGER memory_fts_insert AFTER INSERT ON native_memories WHEN new.status = 'approved' BEGIN
                INSERT INTO native_memory_fts VALUES(new.id, new.title, new.summary, new.details_json);
            END;
            CREATE TRIGGER memory_fts_update AFTER UPDATE ON native_memories BEGIN
                DELETE FROM native_memory_fts WHERE memory_id = old.id;
                INSERT INTO native_memory_fts SELECT new.id, new.title, new.summary, new.details_json WHERE new.status = 'approved';
            END;
            CREATE TRIGGER memory_fts_delete AFTER DELETE ON native_memories BEGIN
                DELETE FROM native_memory_fts WHERE memory_id = old.id;
            END;
            CREATE TRIGGER memory_source_message_change AFTER UPDATE ON messages
                WHEN new.content != old.content OR new.state != 'complete' OR new.failure IS NOT NULL BEGIN
                UPDATE native_memory_revisions SET source_text = NULL, source_version = NULL WHERE source_message_id = old.id;
            END;
            CREATE TRIGGER memory_source_message_delete BEFORE DELETE ON messages BEGIN
                UPDATE native_memory_revisions SET source_text = NULL, source_version = NULL WHERE source_message_id = old.id;
            END;
            CREATE TRIGGER memory_source_exclusion AFTER UPDATE OF memory_excluded ON conversations WHEN new.memory_excluded = 1 BEGIN
                UPDATE native_memory_revisions SET source_text = NULL, source_version = NULL
                    WHERE source_conversation_id = new.id;
            END;
            CREATE TRIGGER memory_source_deletion BEFORE DELETE ON conversations BEGIN
                UPDATE native_memory_revisions SET source_text = NULL, source_version = NULL
                    WHERE source_conversation_id = old.id;
            END;
            """)
        for json in try String.fetchAll(db, sql: "SELECT record_json FROM native_memories WHERE status != 'deleted'") {
            let memory = try JSONDecoder().decode(NativeMemoryRecord.self, from: Data(json.utf8))
            try preserveMemoryEvidence(memory, db: db)
        }
    }

    static func preserveMemoryEvidence(_ memory: NativeMemoryRecord, db: Database) throws {
        let previous = try String.fetchOne(db, sql: "SELECT record_json FROM native_memory_revisions WHERE memory_id = ? ORDER BY revision DESC LIMIT 1", arguments: [memory.id])
        var snapshot = memory
        snapshot.embedding = nil
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        if let previous, let data = previous.data(using: .utf8),
           let old = try? JSONDecoder().decode(NativeMemoryRecord.self, from: data) {
            var normalized = snapshot
            normalized.updatedAt = old.updatedAt
            if normalized == old { return }
        }
        var sourceText: String?
        if let conversation = memory.sourceConversationID, let message = memory.sourceMessageID {
            sourceText = try String.fetchOne(db, sql: """
                SELECT messages.content FROM messages JOIN conversations ON conversations.id = messages.conversation_id
                WHERE messages.id = ? AND conversations.id = ? AND conversations.memory_excluded = 0
                  AND messages.state = 'complete' AND messages.failure IS NULL
                """, arguments: [message, conversation])
            if let text = sourceText, NativeMemorySafety.containsSensitiveData(text)
                || text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("private:") || text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("do not remember") {
                sourceText = nil
            }
        }
        let version = sourceText.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        try db.execute(sql: """
            INSERT INTO native_memory_revisions(memory_id, revision, record_json, source_conversation_id, source_message_id, source_text, source_version)
            SELECT ?, COALESCE(MAX(revision), 0) + 1, ?, ?, ?, ?, ? FROM native_memory_revisions WHERE memory_id = ?
            """, arguments: [memory.id, json, memory.sourceConversationID, memory.sourceMessageID, sourceText, version, memory.id])
    }

    func memoryEvidence(_ id: String) throws -> [NativeMemoryEvidence] {
        try database.read { db in
            guard try String.fetchOne(db, sql: "SELECT status FROM native_memories WHERE id = ?", arguments: [id]) != "deleted" else {
                throw NativeMemoryEvidenceError.removed
            }
            return try Row.fetchAll(db, sql: """
                SELECT revision, record_json, source_text, source_version FROM native_memory_revisions
                WHERE memory_id = ? ORDER BY revision DESC
                """, arguments: [id]).map { row in
                    let json: String = row["record_json"]
                    return NativeMemoryEvidence(revision: row["revision"],
                        record: try JSONDecoder().decode(NativeMemoryRecord.self, from: Data(json.utf8)),
                        sourceText: row["source_text"], sourceVersion: row["source_version"],
                        domainSources: try Self.domainCitations(id, revision: row["revision"], db: db))
                }
        }
    }

    func eligibleMemory(_ selected: [NativeMemoryRanked], bankScope: String, now: Date = Date()) throws -> [NativeMemoryRanked] {
        try database.read { db in
            try selected.compactMap { item in
                guard let json = try String.fetchOne(db, sql: "SELECT record_json FROM native_memories WHERE id = ?", arguments: [item.record.id]) else { return nil }
                let current = try JSONDecoder().decode(NativeMemoryRecord.self, from: Data(json.utf8))
                guard NativeMemorySafety.recordIsSafe(current), current == item.record, current.eligible(at: now), current.expiry.map({ $0 > now }) ?? true,
                      bankScope == "all" || current.bank.caseInsensitiveCompare(bankScope) == .orderedSame else { return nil }
                if let conversation = current.sourceConversationID {
                    guard try Int.fetchOne(db, sql: "SELECT memory_excluded FROM conversations WHERE id = ?", arguments: [conversation]) == 0 else { return nil }
                }
                let revision = try Int.fetchOne(db, sql: "SELECT MAX(revision) FROM native_memory_revisions WHERE memory_id = ?", arguments: [current.id])
                if let message = current.sourceMessageID {
                    guard try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM messages s JOIN native_memory_revisions r ON r.memory_id = ?
                        WHERE s.id = ? AND s.conversation_id = ? AND s.content = r.source_text
                          AND s.state = 'complete' AND s.failure IS NULL AND r.revision = ?)
                        """, arguments: [current.id, message, current.sourceConversationID, revision]) == true else { return nil }
                }
                return NativeMemoryRanked(record: current, score: item.score, revision: revision)
            }
        }
    }

    func saveMemoryEmbedding(_ embedding: [Double], expected: NativeMemoryRecord) throws {
        try database.write { db in
            guard let json = try String.fetchOne(db, sql: "SELECT record_json FROM native_memories WHERE id = ?", arguments: [expected.id]),
                  let current = try? JSONDecoder().decode(NativeMemoryRecord.self, from: Data(json.utf8)),
                  current == expected, current.status == .approved else { throw NativeMemoryEvidenceError.changed }
            var updated = current
            updated.embedding = embedding
            try Self.writeMemory(updated, db: db)
        }
    }

    func recallMemory(_ text: String, bankScope: String, now: Date = Date(),
                      itemLimit: Int = 8, byteLimit: Int = 2_800) throws -> [NativeMemoryRanked] {
        guard itemLimit > 0, byteLimit > 0, !NativeMemorySafety.containsSensitiveData(text) else { return [] }
        let terms = Array(Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(32).map(String.init))).sorted()
        guard !terms.isEmpty else { return [] }
        let query = terms.map { "\"" + $0 + "\"" }.joined(separator: " OR ")
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.record_json, (SELECT MAX(revision) FROM native_memory_revisions WHERE memory_id = m.id) AS revision
                FROM native_memory_fts JOIN native_memories m ON m.id = native_memory_fts.memory_id
                LEFT JOIN conversations c ON c.id = m.source_conversation_id
                WHERE native_memory_fts MATCH ? AND m.status = 'approved'
                  AND (? = 'all' OR lower(m.bank) = lower(?))
                  AND (m.expiry IS NULL OR m.expiry > ?)
                  AND (m.durability = 'durable' OR m.expiry IS NOT NULL)
                  AND (m.source_conversation_id IS NULL OR (c.id IS NOT NULL AND c.memory_excluded = 0))
                  AND (m.source_message_id IS NULL OR EXISTS (
                    SELECT 1 FROM messages s JOIN native_memory_revisions r ON r.memory_id = m.id
                    WHERE s.id = m.source_message_id AND s.conversation_id = m.source_conversation_id
                      AND s.content = r.source_text AND s.state = 'complete' AND s.failure IS NULL
                      AND r.revision = (SELECT MAX(revision) FROM native_memory_revisions WHERE memory_id = m.id)))
                ORDER BY bm25(native_memory_fts), m.updated_at DESC, m.id LIMIT 64
                """, arguments: [query, bankScope, bankScope, now.timeIntervalSince1970])
            var result: [NativeMemoryRanked] = []
            var used = 0
            for row in rows {
                let json: String = row["record_json"]
                let record = try JSONDecoder().decode(NativeMemoryRecord.self, from: Data(json.utf8))
                guard NativeMemorySafety.recordIsSafe(record) else { continue }
                let size = (record.title + record.summary + record.details.joined(separator: "; ")).utf8.count + 48
                guard result.count < min(itemLimit, 8), used + size <= byteLimit else { continue }
                result.append(NativeMemoryRanked(record: record, score: 1, revision: row["revision"]))
                used += size
            }
            return result
        }
    }
}

enum NativeMemoryCitation {
    static let offset = 10_001
    static func merging(_ research: [PulseSource], grounding: [PulseSource], memories: [NativeMemoryRanked]) -> [PulseSource] {
        research + grounding + sources(memories)
    }
    static func sources(_ selected: [NativeMemoryRanked]) -> [PulseSource] {
        selected.enumerated().map { index, item in
            var url = URLComponents()
            url.scheme = "vera-memory"
            url.host = "record"
            url.queryItems = [URLQueryItem(name: "id", value: item.record.id),
                              URLQueryItem(name: "revision", value: item.revision.map(String.init))]
            return PulseSource(n: offset + index, title: "Memory: \(item.record.title)", url: url.string ?? "")
        }
    }
    static func revision(_ value: String) -> Int? {
        guard recordID(value) != nil, let url = URLComponents(string: value),
              let raw = url.queryItems?.first(where: { $0.name == "revision" })?.value,
              let revision = Int(raw), revision > 0 else { return nil }
        return revision
    }
    static func recordID(_ value: String) -> String? {
        guard let url = URLComponents(string: value), url.scheme == "vera-memory", url.host == "record" else { return nil }
        return url.queryItems?.first(where: { $0.name == "id" })?.value
    }
}
