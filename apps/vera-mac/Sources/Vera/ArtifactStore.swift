import CryptoKit
import Foundation
import GRDB

enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case document, image, fileChange = "file_change", canvas
}

struct ArtifactRecord: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var kind: ArtifactKind
    var title: String
    var conversationID: String?
    var originTitle: String?
    var createdAt: Date
    var updatedAt: Date
    var versionCount: Int
}

struct ArtifactVersion: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var artifactID: String
    var ordinal: Int
    var sourceKey: String
    var fileName: String
    var mime: String
    var byteSize: Int
    var contentHash: String
    var messageID: String?
    var details: ArtifactDetails
    var createdAt: Date
}

struct ArtifactDetails: Hashable, Codable, Sendable {
    var filePath: String? = nil
    var changeKind: NativeFileChangeKind? = nil
    var movedFrom: String? = nil
    var beforeText: String? = nil
    var truncated: Bool = false
    var sources: [PulseSource] = []
    var prompt: String? = nil
    var imageSize: String? = nil
    var canvasType: ArtifactType? = nil
    var language: String? = nil

    init(
        filePath: String? = nil, changeKind: NativeFileChangeKind? = nil, movedFrom: String? = nil,
        beforeText: String? = nil, truncated: Bool = false, sources: [PulseSource] = [],
        prompt: String? = nil, imageSize: String? = nil, canvasType: ArtifactType? = nil,
        language: String? = nil
    ) {
        self.filePath = filePath
        self.changeKind = changeKind
        self.movedFrom = movedFrom
        self.beforeText = beforeText
        self.truncated = truncated
        self.sources = sources
        self.prompt = prompt
        self.imageSize = imageSize
        self.canvasType = canvasType
        self.language = language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        changeKind = try? container.decodeIfPresent(NativeFileChangeKind.self, forKey: .changeKind)
        movedFrom = try container.decodeIfPresent(String.self, forKey: .movedFrom)
        beforeText = try container.decodeIfPresent(String.self, forKey: .beforeText)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        sources = try container.decodeIfPresent([PulseSource].self, forKey: .sources) ?? []
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        imageSize = try container.decodeIfPresent(String.self, forKey: .imageSize)
        canvasType = try? container.decodeIfPresent(ArtifactType.self, forKey: .canvasType)
        language = try container.decodeIfPresent(String.self, forKey: .language)
    }
}

struct ArtifactDraft: Sendable {
    var kind: ArtifactKind
    var title: String
    var conversationID: String?
    var originTitle: String?
    var messageID: String?
    var sourceKey: String
    var data: Data
    var mime: String
    var fileExtension: String
    var details: ArtifactDetails = ArtifactDetails()
}

enum ArtifactConversationDeletion: Sendable { case keep, delete }

protocol ArtifactRepository: Sendable {
    func listArtifacts() throws -> [ArtifactRecord]
    func artifact(_ id: String) throws -> ArtifactRecord?
    func artifactVersions(_ artifactID: String) throws -> [ArtifactVersion]
    func artifactVersion(sourceKey: String) throws -> ArtifactVersion?
    func recordArtifact(_ draft: ArtifactDraft, revising artifactID: String?) throws -> ArtifactVersion
    func artifactIDs(conversationID: String) throws -> [String]
    func resolveArtifacts(conversationID: String, choice: ArtifactConversationDeletion) throws -> [String]
    func updateArtifactOrigin(conversationID: String, title: String) throws
    func revisionTarget(messageID: String) throws -> String?
    func setRevisionTarget(messageID: String, artifactID: String) throws
    func clearRevisionTarget(messageID: String) throws
}

extension LocalChatRepository: ArtifactRepository {
    static func migrateArtifacts(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE artifacts (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                conversation_id TEXT,
                origin_title TEXT,
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL
            );
            CREATE INDEX artifacts_updated ON artifacts(updated_at);
            CREATE INDEX artifacts_conversation ON artifacts(conversation_id);
            CREATE TABLE artifact_versions (
                id TEXT PRIMARY KEY NOT NULL,
                artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                source_key TEXT NOT NULL,
                file_name TEXT NOT NULL,
                mime TEXT NOT NULL,
                byte_size INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                message_id TEXT,
                details_json TEXT NOT NULL,
                created_at DOUBLE NOT NULL,
                UNIQUE(artifact_id, ordinal)
            );
            CREATE INDEX artifact_versions_source_key ON artifact_versions(source_key);
            CREATE TABLE artifact_revision_targets (
                message_id TEXT PRIMARY KEY NOT NULL,
                artifact_id TEXT NOT NULL,
                created_at DOUBLE NOT NULL
            );
            """)
    }

    private static let artifactSelect = """
        SELECT a.id, a.kind, a.title, a.conversation_id, a.origin_title, a.created_at, a.updated_at,
            (SELECT COUNT(*) FROM artifact_versions v WHERE v.artifact_id = a.id) AS version_count
        FROM artifacts a
        """

    func listArtifacts() throws -> [ArtifactRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "\(Self.artifactSelect) ORDER BY a.updated_at DESC, a.id ASC")
                .compactMap(Self.decodeArtifact)
        }
    }

    func artifact(_ id: String) throws -> ArtifactRecord? {
        try database.read { db in try Self.fetchArtifact(db, id: id) }
    }

    func artifactVersions(_ artifactID: String) throws -> [ArtifactVersion] {
        try database.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM artifact_versions WHERE artifact_id = ? ORDER BY ordinal ASC",
                arguments: [artifactID]
            ).compactMap(Self.decodeArtifactVersion)
        }
    }

    func artifactVersion(sourceKey: String) throws -> ArtifactVersion? {
        try database.read { db in try Self.fetchArtifactVersion(db, sourceKey: sourceKey) }
    }

    func recordArtifact(_ draft: ArtifactDraft, revising artifactID: String?) throws -> ArtifactVersion {
        let directory = artifactDirectory
        return try database.write { db in
            let contentHash = Self.contentHash(draft.data)
            let now = Date()
            var target: String?
            var ordinal = 1
            if let existing = try Self.fetchArtifactVersion(db, sourceKey: draft.sourceKey) {
                if existing.contentHash == contentHash { return existing }
                target = existing.artifactID
                let last = try Int.fetchOne(
                    db, sql: "SELECT MAX(ordinal) FROM artifact_versions WHERE artifact_id = ?",
                    arguments: [existing.artifactID]) ?? existing.ordinal
                ordinal = last + 1
            } else if let artifactID,
               let row = try Row.fetchOne(db, sql: "SELECT kind FROM artifacts WHERE id = ?", arguments: [artifactID]),
               (row["kind"] as String?) == draft.kind.rawValue {
                target = artifactID
                let last = try Int.fetchOne(
                    db, sql: "SELECT MAX(ordinal) FROM artifact_versions WHERE artifact_id = ?",
                    arguments: [artifactID]) ?? 0
                ordinal = last + 1
            }
            let detailsJSON = String(decoding: try nativeTaskEncoded(draft.details), as: UTF8.self)
            let fileName = "artifact-\(UUID().uuidString.lowercased()).\(draft.fileExtension)"
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(fileName)
            try draft.data.write(to: fileURL, options: .atomic)
            do {
                let artifactKey: String
                if let target {
                    artifactKey = target
                    try db.execute(
                        sql: "UPDATE artifacts SET title = ?, updated_at = ? WHERE id = ?",
                        arguments: [draft.title, now.timeIntervalSince1970, target])
                } else {
                    artifactKey = UUID().uuidString.lowercased()
                    try db.execute(
                        sql: """
                            INSERT INTO artifacts (id, kind, title, conversation_id, origin_title, created_at, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            artifactKey, draft.kind.rawValue, draft.title, draft.conversationID, draft.originTitle,
                            now.timeIntervalSince1970, now.timeIntervalSince1970,
                        ])
                }
                let version = ArtifactVersion(
                    id: UUID().uuidString.lowercased(), artifactID: artifactKey, ordinal: ordinal,
                    sourceKey: draft.sourceKey, fileName: fileName, mime: draft.mime, byteSize: draft.data.count,
                    contentHash: contentHash, messageID: draft.messageID, details: draft.details, createdAt: now)
                try db.execute(
                    sql: """
                        INSERT INTO artifact_versions
                            (id, artifact_id, ordinal, source_key, file_name, mime, byte_size, content_hash, message_id,
                             details_json, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        version.id, version.artifactID, version.ordinal, version.sourceKey, version.fileName,
                        version.mime, version.byteSize, version.contentHash, version.messageID, detailsJSON,
                        now.timeIntervalSince1970,
                    ])
                return try Self.fetchArtifactVersion(db, sourceKey: draft.sourceKey) ?? version
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
        }
    }

    func revisionTarget(messageID: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT t.artifact_id FROM artifact_revision_targets t
                    JOIN artifacts a ON a.id = t.artifact_id
                    WHERE t.message_id = ?
                    """,
                arguments: [messageID])
        }
    }

    func setRevisionTarget(messageID: String, artifactID: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO artifact_revision_targets (message_id, artifact_id, created_at) VALUES (?, ?, ?)
                    ON CONFLICT(message_id) DO UPDATE SET artifact_id = excluded.artifact_id, created_at = excluded.created_at
                    """,
                arguments: [messageID, artifactID, Date().timeIntervalSince1970])
        }
    }

    func clearRevisionTarget(messageID: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM artifact_revision_targets WHERE message_id = ?", arguments: [messageID])
        }
    }

    static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func artifactIDs(conversationID: String) throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db, sql: "SELECT id FROM artifacts WHERE conversation_id = ? ORDER BY updated_at DESC, id ASC",
                arguments: [conversationID])
        }
    }

    func resolveArtifacts(conversationID: String, choice: ArtifactConversationDeletion) throws -> [String] {
        try database.write { db in
            switch choice {
            case .keep:
                try db.execute(
                    sql: "UPDATE artifacts SET conversation_id = NULL WHERE conversation_id = ?",
                    arguments: [conversationID])
                return []
            case .delete:
                let fileNames = try String.fetchAll(
                    db,
                    sql: """
                        SELECT v.file_name FROM artifact_versions v
                        JOIN artifacts a ON a.id = v.artifact_id
                        WHERE a.conversation_id = ?
                        ORDER BY v.artifact_id, v.ordinal
                        """,
                    arguments: [conversationID])
                try db.execute(sql: "DELETE FROM artifacts WHERE conversation_id = ?", arguments: [conversationID])
                return fileNames
            }
        }
    }

    func updateArtifactOrigin(conversationID: String, title: String) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE artifacts SET origin_title = ? WHERE conversation_id = ?",
                arguments: [title, conversationID])
        }
    }

    private static func fetchArtifact(_ db: Database, id: String) throws -> ArtifactRecord? {
        try Row.fetchOne(db, sql: "\(artifactSelect) WHERE a.id = ?", arguments: [id]).flatMap(decodeArtifact)
    }

    private static func fetchArtifactVersion(_ db: Database, sourceKey: String) throws -> ArtifactVersion? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM artifact_versions WHERE source_key = ? ORDER BY ordinal DESC, created_at DESC LIMIT 1",
            arguments: [sourceKey])
            .flatMap(decodeArtifactVersion)
    }

    private static func decodeArtifact(_ row: Row) -> ArtifactRecord? {
        guard let kind = ArtifactKind(rawValue: row["kind"]) else { return nil }
        return ArtifactRecord(
            id: row["id"], kind: kind, title: row["title"],
            conversationID: row["conversation_id"], originTitle: row["origin_title"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            versionCount: row["version_count"])
    }

    private static func decodeArtifactVersion(_ row: Row) -> ArtifactVersion? {
        let raw: String = row["details_json"]
        let details = raw.data(using: .utf8).flatMap { try? JSONDecoder().decode(ArtifactDetails.self, from: $0) }
            ?? ArtifactDetails()
        return ArtifactVersion(
            id: row["id"], artifactID: row["artifact_id"], ordinal: row["ordinal"],
            sourceKey: row["source_key"], fileName: row["file_name"], mime: row["mime"],
            byteSize: row["byte_size"], contentHash: row["content_hash"], messageID: row["message_id"], details: details,
            createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }
}
