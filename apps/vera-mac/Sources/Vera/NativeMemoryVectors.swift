import Foundation
import GRDB

extension LocalChatRepository {
    static func migrateMemoryVectors(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_memory_vectors (
                memory_id TEXT NOT NULL REFERENCES native_memories(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL,
                model TEXT NOT NULL,
                dimension INTEGER NOT NULL,
                vector BLOB NOT NULL,
                created_at DOUBLE NOT NULL,
                PRIMARY KEY(memory_id, revision)
            );
            CREATE INDEX native_memory_vectors_model ON native_memory_vectors(model);
            UPDATE native_memories SET embedding_json = NULL, embedding_state = 'missing',
                record_json = json_set(record_json, '$.embedding', json('null')) WHERE embedding_json IS NOT NULL;
            """)
    }

    static let recallScopeSQL = """
        m.status = 'approved'
          AND (? = 'all' OR lower(m.bank) = lower(?))
          AND (m.expiry IS NULL OR m.expiry > ?)
          AND (m.durability = 'durable' OR m.expiry IS NOT NULL)
          AND (? = 1 OR COALESCE(json_extract(m.record_json, '$.sensitiveConsent'), 0) = 0)
        """

    func saveMemoryVector(_ vector: [Double], model: String, expected: NativeMemoryRecord) throws {
        guard !vector.isEmpty, !model.isEmpty else { throw NativeMemoryEvidenceError.changed }
        try database.write { db in
            guard let json = try String.fetchOne(db, sql: "SELECT record_json FROM native_memories WHERE id = ?", arguments: [expected.id]),
                  let current = try? JSONDecoder().decode(NativeMemoryRecord.self, from: Data(json.utf8)),
                  current == expected, current.status == .approved else { throw NativeMemoryEvidenceError.changed }
            var updated = current
            updated.embedding = vector
            try Self.writeMemory(updated, db: db)
            let revision = try Int.fetchOne(db, sql: "SELECT MAX(revision) FROM native_memory_revisions WHERE memory_id = ?", arguments: [expected.id]) ?? 0
            try db.execute(sql: """
                INSERT INTO native_memory_vectors(memory_id, revision, model, dimension, vector, created_at) VALUES(?,?,?,?,?,?)
                ON CONFLICT(memory_id, revision) DO UPDATE SET model = excluded.model, dimension = excluded.dimension,
                    vector = excluded.vector, created_at = excluded.created_at
                """, arguments: [expected.id, revision, model, vector.count, NativeMemoryVectorCodec.pack(vector), Date().timeIntervalSince1970])
        }
    }

    func invalidateMemoryVectors(exceptModel model: String) throws -> Int {
        try database.write { db in
            let stale = try String.fetchAll(db, sql: "SELECT DISTINCT memory_id FROM native_memory_vectors WHERE model != ?", arguments: [model])
            guard !stale.isEmpty else { return 0 }
            try db.execute(sql: "DELETE FROM native_memory_vectors WHERE model != ?", arguments: [model])
            for id in stale {
                try db.execute(sql: """
                    UPDATE native_memories SET embedding_json = NULL, embedding_state = 'missing',
                        record_json = json_set(record_json, '$.embedding', json('null')) WHERE id = ?
                    """, arguments: [id])
            }
            return stale.count
        }
    }

    func memoryVectorStatus(model: String, now: Date = Date()) throws -> NativeMemoryVectorStatus {
        try database.read { db in
            let total = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM native_memories m LEFT JOIN conversations c ON c.id = m.source_conversation_id
                WHERE m.status = 'approved' AND (m.expiry IS NULL OR m.expiry > ?) AND (m.durability = 'durable' OR m.expiry IS NOT NULL)
                  AND \(Self.sourceEligibleSQL)
                """, arguments: [now.timeIntervalSince1970]) ?? 0
            let ready = model.isEmpty ? 0 : try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM native_memories m LEFT JOIN conversations c ON c.id = m.source_conversation_id
                JOIN native_memory_vectors v ON v.memory_id = m.id
                  AND v.revision = (SELECT MAX(revision) FROM native_memory_revisions WHERE memory_id = m.id)
                WHERE m.status = 'approved' AND (m.expiry IS NULL OR m.expiry > ?) AND (m.durability = 'durable' OR m.expiry IS NOT NULL)
                  AND v.model = ? AND \(Self.sourceEligibleSQL)
                """, arguments: [now.timeIntervalSince1970, model]) ?? 0
            return NativeMemoryVectorStatus(model: model, ready: ready, total: total)
        }
    }

    func memoriesMissingVectors(model: String, now: Date = Date()) throws -> [NativeMemoryRecord] {
        guard !model.isEmpty else { return [] }
        return try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.record_json FROM native_memories m LEFT JOIN conversations c ON c.id = m.source_conversation_id
                WHERE m.status = 'approved' AND (m.expiry IS NULL OR m.expiry > ?) AND (m.durability = 'durable' OR m.expiry IS NOT NULL)
                  AND \(Self.sourceEligibleSQL)
                  AND NOT EXISTS (SELECT 1 FROM native_memory_vectors v WHERE v.memory_id = m.id AND v.model = ?
                      AND v.revision = (SELECT MAX(revision) FROM native_memory_revisions WHERE memory_id = m.id))
                ORDER BY m.updated_at DESC, m.id
                """, arguments: [now.timeIntervalSince1970, model]).compactMap { try? JSONDecoder().decode(NativeMemoryRecord.self, from: Data($0.utf8)) }
        }
    }

    func semanticMemoryCandidates(query: [Double], model: String, bankScope: String, now: Date = Date(),
                                  sensitive: NativeMemorySensitiveHandling = .neverStore,
                                  limit: Int = NativeMemoryRetrievalLimits.semanticCandidates,
                                  minimum: Double = NativeMemoryRetrievalLimits.minimumCosine) throws -> [NativeMemoryCandidate] {
        guard !query.isEmpty, !model.isEmpty, limit > 0 else { return [] }
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.record_json, v.dimension, v.vector, v.revision FROM native_memory_vectors v
                JOIN native_memories m ON m.id = v.memory_id
                LEFT JOIN conversations c ON c.id = m.source_conversation_id
                WHERE v.model = ? AND v.dimension = ?
                  AND v.revision = (SELECT MAX(revision) FROM native_memory_revisions WHERE memory_id = m.id)
                  AND \(Self.recallScopeSQL)
                  AND \(Self.sourceEligibleSQL)
                """, arguments: [model, query.count, bankScope, bankScope, now.timeIntervalSince1970, sensitive == .reviewOnly])
            var scored: [NativeMemoryCandidate] = []
            for row in rows {
                let json: String = row["record_json"]
                guard let record = try? JSONDecoder().decode(NativeMemoryRecord.self, from: Data(json.utf8)),
                      NativeMemorySafety.recordIsSafe(record),
                      let vector = NativeMemoryVectorCodec.unpack(row["vector"], dimension: row["dimension"]) else { continue }
                let cosine = NativeMemoryRecall.cosineSimilarity(query, vector)
                guard cosine >= minimum else { continue }
                scored.append(NativeMemoryCandidate(record: record, revision: row["revision"], cosine: cosine))
            }
            scored.sort { left, right in
                if left.cosine != right.cosine { return (left.cosine ?? 0) > (right.cosine ?? 0) }
                if left.record.updatedAt != right.record.updatedAt { return left.record.updatedAt > right.record.updatedAt }
                return left.record.id < right.record.id
            }
            return Array(scored.prefix(limit)).enumerated().map { index, candidate in
                var ranked = candidate
                ranked.semanticRank = index + 1
                return ranked
            }
        }
    }

    func lexicalMemoryCandidates(_ text: String, bankScope: String, now: Date = Date(),
                                 sensitive: NativeMemorySensitiveHandling = .neverStore,
                                 limit: Int = NativeMemoryRetrievalLimits.lexicalCandidates) throws -> [NativeMemoryCandidate] {
        guard limit > 0, !NativeMemorySafety.containsSensitiveData(text) else { return [] }
        let terms = Array(Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(48).map(String.init))).sorted()
        guard !terms.isEmpty else { return [] }
        let query = terms.map { "\"" + $0 + "\"" }.joined(separator: " OR ")
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.record_json, bm25(native_memory_fts) AS score,
                    (SELECT MAX(revision) FROM native_memory_revisions WHERE memory_id = m.id) AS revision
                FROM native_memory_fts JOIN native_memories m ON m.id = native_memory_fts.memory_id
                LEFT JOIN conversations c ON c.id = m.source_conversation_id
                WHERE native_memory_fts MATCH ? AND \(Self.recallScopeSQL)
                  AND \(Self.sourceEligibleSQL)
                ORDER BY bm25(native_memory_fts), m.updated_at DESC, m.id LIMIT ?
                """, arguments: [query, bankScope, bankScope, now.timeIntervalSince1970, sensitive == .reviewOnly, limit])
            var result: [NativeMemoryCandidate] = []
            for row in rows {
                let json: String = row["record_json"]
                guard let record = try? JSONDecoder().decode(NativeMemoryRecord.self, from: Data(json.utf8)),
                      NativeMemorySafety.recordIsSafe(record) else { continue }
                let score: Double = row["score"]
                result.append(NativeMemoryCandidate(record: record, revision: row["revision"], lexicalRank: result.count + 1, lexicalScore: -score))
            }
            return result
        }
    }
}
