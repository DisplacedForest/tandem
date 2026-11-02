import Foundation
import GRDB

struct ProjectFile: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var fileName: String
    var byteSize: Int
    var addedAt: Date
}

struct ProjectRecord: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var instructions: String
    var grants: [FolderGrant]
    var files: [ProjectFile]
    var createdAt: Date
    var updatedAt: Date
}

enum ProjectStoreError: Error, LocalizedError, Equatable {
    case notFound
    case fileTooLarge(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "This project no longer exists."
        case .fileTooLarge(let name): return "\(name) is larger than the 50 MB limit for project files."
        case .unreadable(let name): return "\(name) couldn't be read."
        }
    }
}

protocol ProjectRepository: Sendable {
    func listProjects() throws -> [ProjectRecord]
    func project(_ id: String) throws -> ProjectRecord?
    func saveProject(_ project: ProjectRecord) throws
    func deleteProject(_ id: String) throws -> [String]
    func conversationIDs(projectID: String) throws -> [String]
    func setConversationProject(_ conversationID: String, projectID: String?) throws
    func projectFilesDirectory(_ projectID: String) -> URL
    func addProjectFile(_ projectID: String, from url: URL) throws -> ProjectFile
    func removeProjectFile(_ projectID: String, fileID: String) throws
}

extension LocalChatRepository: ProjectRepository {
    static let projectFileByteLimit = 50 * 1024 * 1024

    static var standardProjectsDirectory: URL {
        NativeAttachmentStore.standardDirectory.deletingLastPathComponent()
            .appendingPathComponent("projects", isDirectory: true)
    }

    static func migrateProjects(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE projects (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                instructions TEXT NOT NULL DEFAULT '',
                grants_json TEXT,
                files_json TEXT,
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL
            )
            """)
        try db.execute(sql: "ALTER TABLE conversations ADD COLUMN project_id TEXT")
    }

    func listProjects() throws -> [ProjectRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, instructions, grants_json, files_json, created_at, updated_at
                FROM projects
                ORDER BY updated_at DESC
                """).map(Self.decodeProject)
        }
    }

    func project(_ id: String) throws -> ProjectRecord? {
        try database.read { db in
            try Self.fetchProject(id, db: db)
        }
    }

    func saveProject(_ project: ProjectRecord) throws {
        try database.write { db in
            try Self.writeProject(project, updatedAt: Date(), db: db)
        }
    }

    func deleteProject(_ id: String) throws -> [String] {
        let ungrouped = try database.write { db -> [String] in
            let members = try String.fetchAll(db, sql: "SELECT id FROM conversations WHERE project_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE conversations SET project_id = NULL WHERE project_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id])
            return members
        }
        try? FileManager.default.removeItem(at: projectsDirectory.appendingPathComponent(id, isDirectory: true))
        return ungrouped
    }

    func conversationIDs(projectID: String) throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM conversations WHERE project_id = ? ORDER BY updated_at DESC
                """, arguments: [projectID])
        }
    }

    func setConversationProject(_ conversationID: String, projectID: String?) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE conversations SET project_id = ? WHERE id = ?", arguments: [projectID, conversationID])
        }
    }

    func projectFilesDirectory(_ projectID: String) -> URL {
        projectsDirectory
            .appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
    }

    func addProjectFile(_ projectID: String, from url: URL) throws -> ProjectFile {
        guard try project(projectID) != nil else { throw ProjectStoreError.notFound }
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else { throw ProjectStoreError.unreadable(name) }
        guard size <= Self.projectFileByteLimit else { throw ProjectStoreError.fileTooLarge(name) }
        let directory = projectFilesDirectory(projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let ext = url.pathExtension.lowercased()
        let fileName = ext.isEmpty ? id : "\(id).\(ext)"
        let destination = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw ProjectStoreError.unreadable(name)
        }
        let file = ProjectFile(id: id, name: name, fileName: fileName, byteSize: size, addedAt: Date())
        do {
            try database.write { db in
                guard var stored = try Self.fetchProject(projectID, db: db) else { throw ProjectStoreError.notFound }
                stored.files.append(file)
                try Self.writeProject(stored, updatedAt: Date(), db: db)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return file
    }

    func removeProjectFile(_ projectID: String, fileID: String) throws {
        let removed = try database.write { db -> ProjectFile? in
            guard var stored = try Self.fetchProject(projectID, db: db) else { throw ProjectStoreError.notFound }
            guard let index = stored.files.firstIndex(where: { $0.id == fileID }) else { return nil }
            let file = stored.files.remove(at: index)
            try Self.writeProject(stored, updatedAt: Date(), db: db)
            return file
        }
        if let removed {
            try? FileManager.default.removeItem(at: projectFilesDirectory(projectID).appendingPathComponent(removed.fileName))
        }
    }

    private static func fetchProject(_ id: String, db: Database) throws -> ProjectRecord? {
        try Row.fetchOne(db, sql: """
            SELECT id, name, instructions, grants_json, files_json, created_at, updated_at
            FROM projects
            WHERE id = ?
            """, arguments: [id]).map(decodeProject)
    }

    private static func writeProject(_ project: ProjectRecord, updatedAt: Date, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO projects (id, name, instructions, grants_json, files_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                instructions = excluded.instructions,
                grants_json = excluded.grants_json,
                files_json = excluded.files_json,
                updated_at = excluded.updated_at
            """, arguments: [
                project.id,
                project.name,
                project.instructions,
                FolderGrant.encode(project.grants),
                encodeFiles(project.files),
                project.createdAt.timeIntervalSince1970,
                updatedAt.timeIntervalSince1970,
            ])
    }

    private static func encodeFiles(_ files: [ProjectFile]) -> String? {
        guard !files.isEmpty, let data = try? JSONEncoder().encode(files) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeFiles(_ raw: String?) -> [ProjectFile] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ProjectFile].self, from: data)) ?? []
    }

    private static func decodeProject(_ row: Row) -> ProjectRecord {
        ProjectRecord(
            id: row["id"],
            name: row["name"],
            instructions: row["instructions"] ?? "",
            grants: FolderGrant.decode(row["grants_json"]),
            files: decodeFiles(row["files_json"]),
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }
}
