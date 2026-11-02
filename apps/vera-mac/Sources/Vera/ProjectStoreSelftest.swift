import Foundation

enum ProjectStoreSelftest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func run() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory
            .appendingPathComponent("vera-project-selftest-\(UUID().uuidString.lowercased())", isDirectory: true)
        let artifacts = base.appendingPathComponent("attachments", isDirectory: true)
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        try manager.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: artifacts, projectsDirectory: projects)
        try checkStore(repository, base: base, projects: projects)
        try checkReadOnlyFolderTools(base: base)
        try checkMemoryProjectTag()
    }

    static func checkStore(_ repository: LocalChatRepository, base: URL, projects: URL) throws {
        let manager = FileManager.default
        let created = Date(timeIntervalSince1970: 1_785_600_000)
        let grantFolder = base.appendingPathComponent("reference", isDirectory: true)
        try manager.createDirectory(at: grantFolder, withIntermediateDirectories: true)
        var grant = try FolderGrant.make(url: grantFolder)
        grant.readOnly = true
        var record = ProjectRecord(
            id: "project-a", name: "Garden", instructions: "Keep answers short.", grants: [grant], files: [],
            createdAt: created, updatedAt: created)
        try repository.saveProject(record)
        var listed = try repository.listProjects()
        try check(listed.count == 1 && listed[0].name == "Garden" && listed[0].instructions == "Keep answers short.", "A saved project lists")
        try check(listed[0].updatedAt > created && listed[0].createdAt == created, "Saving bumps updated_at and keeps created_at")
        try check(listed[0].grants == [grant] && listed[0].grants[0].readOnly, "A read-only grant round-trips through grants_json")

        record.name = "Vegetable garden"
        try repository.saveProject(record)
        try check(try repository.project("project-a")?.name == "Vegetable garden", "A rename persists")
        try check(try repository.listProjects().count == 1, "Saving again updates rather than duplicating")
        try check(try repository.project("missing") == nil, "An unknown project reads as nil")

        let source = base.appendingPathComponent("Planting Notes.MD")
        let bytes = Data("# Beds\nTomatoes in bed two".utf8)
        try bytes.write(to: source)
        let file = try repository.addProjectFile("project-a", from: source)
        let folder = repository.projectFilesDirectory("project-a")
        try check(folder == projects.appendingPathComponent("project-a/files", isDirectory: true), "Project files live under the projects directory")
        try check(file.name == "Planting Notes.MD" && file.fileName == "\(file.id).md" && file.byteSize == bytes.count, "The file entry records name, stored name and size")
        try check(try Data(contentsOf: folder.appendingPathComponent(file.fileName)) == bytes, "The bytes are copied into the project folder")
        listed = try repository.listProjects()
        try check(listed[0].files == [file], "The project lists its file")
        do {
            _ = try repository.addProjectFile("missing", from: source)
            throw Failure(description: "Adding a file to a missing project must fail")
        } catch let error as ProjectStoreError {
            try check(error == .notFound, "A missing project reports not found")
        }
        try repository.removeProjectFile("project-a", fileID: file.id)
        try check(try repository.project("project-a")?.files.isEmpty == true, "Removing a file drops its entry")
        try check(!manager.fileExists(atPath: folder.appendingPathComponent(file.fileName).path), "Removing a file deletes its bytes")
        let second = try repository.addProjectFile("project-a", from: source)

        let now = Date()
        var member = Conversation(id: "conversation-a", title: "Beds", messages: [], updatedAt: now)
        member.projectID = "project-a"
        try repository.saveConversation(member)
        try repository.saveConversation(Conversation(id: "conversation-b", title: "Loose", messages: [], updatedAt: now))
        var other = Conversation(id: "conversation-c", title: "Seeds", messages: [], updatedAt: now)
        other.projectID = "project-a"
        try repository.saveConversation(other)
        let conversations = try repository.listConversations()
        try check(conversations.first(where: { $0.id == "conversation-a" })?.projectID == "project-a", "project_id round-trips through saveConversation")
        try check(conversations.first(where: { $0.id == "conversation-b" })?.projectID == nil, "A conversation without a project reads nil")
        try check(Set(try repository.conversationIDs(projectID: "project-a")) == ["conversation-a", "conversation-c"], "Members list by project")
        try repository.setConversationProject("conversation-c", projectID: nil)
        try check(try repository.listConversations().first(where: { $0.id == "conversation-c" })?.projectID == nil, "Setting the project to nil clears it")
        try check(try repository.conversationIDs(projectID: "project-a") == ["conversation-a"], "A cleared conversation leaves the project")
        try repository.setConversationProject("conversation-b", projectID: "project-a")
        try check(Set(try repository.conversationIDs(projectID: "project-a")) == ["conversation-a", "conversation-b"], "Setting a project adds the conversation")

        try check(manager.fileExists(atPath: folder.appendingPathComponent(second.fileName).path), "The second file is on disk before delete")
        let ungrouped = try repository.deleteProject("project-a")
        try check(Set(ungrouped) == ["conversation-a", "conversation-b"], "Deleting a project returns the conversations it ungrouped")
        try check(try repository.project("project-a") == nil && (try repository.listProjects()).isEmpty, "The project row is gone")
        try check(!manager.fileExists(atPath: projects.appendingPathComponent("project-a").path), "The project folder is removed")
        let remaining = try repository.listConversations()
        try check(remaining.count == 3 && remaining.allSatisfy { $0.projectID == nil }, "Conversations survive with no project")
    }

    static func checkReadOnlyFolderTools(base: URL) throws {
        let manager = FileManager.default
        let folder = base.appendingPathComponent("read-only", isDirectory: true)
        try manager.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try "alpha\nbeta\n".write(to: folder.appendingPathComponent("notes/one.txt"), atomically: true, encoding: .utf8)
        var grant = try FolderGrant.make(url: folder)
        grant.readOnly = true
        let access = NativeFolderAccess(grants: [grant])
        try check(access.roots.first?.readOnly == true, "A resolved grant keeps its read-only flag")
        let ledger = NativeFileChangeLedger()
        let file = try access.locate("notes/one.txt")
        let fresh = try access.locate("notes/two.txt")
        let directory = try access.locate("notes")

        _ = try NativeFolderTools.list(directory, hidden: false)
        _ = try NativeFolderTools.read(file, startLine: 1, maximumBytes: 4096)

        func refuses(_ label: String, _ path: String, _ body: () throws -> Void) throws {
            do {
                try body()
                throw Failure(description: "\(label) must be refused in a read-only grant")
            } catch let error as NativeFolderAccessError {
                try check(error == .readOnly(path), "\(label) reports the read-only path: \(error)")
                try check(error.localizedDescription == "\(path) is read-only in this chat.", "\(label) uses plain wording")
            }
        }
        try refuses("Write", fresh.path) { _ = try NativeFolderTools.write(fresh, content: "new", ledger: ledger) }
        try refuses("Edit", file.path) { _ = try NativeFolderTools.edit(file, old: "alpha", new: "omega", all: false, ledger: ledger) }
        try refuses("Move", file.path) { _ = try NativeFolderTools.move(from: file, to: fresh, ledger: ledger) }
        try refuses("Trash", file.path) { _ = try NativeFolderTools.moveToTrash(file, ledger: ledger) }
        try refuses("Make folder", try access.locate("notes/deeper").path) {
            _ = try NativeFolderTools.makeDirectory(try access.locate("notes/deeper"), ledger: ledger)
        }
        try check(try String(contentsOf: folder.appendingPathComponent("notes/one.txt"), encoding: .utf8) == "alpha\nbeta\n", "The file is unchanged")
        try check(!manager.fileExists(atPath: folder.appendingPathComponent("notes/two.txt").path), "No new file was written")
        try check(!manager.fileExists(atPath: folder.appendingPathComponent("notes/deeper").path), "No folder was created")

        var writable = try FolderGrant.make(url: base.appendingPathComponent("reference", isDirectory: true))
        writable.readOnly = false
        let note = NativeFolderTools.grantNote([grant, writable]) ?? ""
        try check(note.contains("- read-only: \(grant.path) (read-only)"), "The grant note marks a read-only folder")
        try check(note.contains("- reference: \(writable.path)\n") || note.hasSuffix("- reference: \(writable.path)"), "A writable grant line is unmarked")

        let legacy = Data(#"[{"id":"legacy","path":"/Volumes/Archive/notes","name":"notes"}]"#.utf8)
        let decoded = try JSONDecoder().decode([FolderGrant].self, from: legacy)
        try check(decoded.count == 1 && !decoded[0].readOnly && decoded[0].path == "/Volumes/Archive/notes", "A grant saved before read-only decodes as writable")
    }

    static func checkMemoryProjectTag() throws {
        guard let template = NativeMemoryRecord.shotLibrary.first else { throw Failure(description: "The memory fixture is empty") }
        let encoded = try JSONEncoder().encode(template)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw Failure(description: "A memory record encodes as an object")
        }
        try check(object["projectID"] == nil, "A record without a project omits the key")
        let untagged = try JSONDecoder().decode(NativeMemoryRecord.self, from: encoded)
        try check(untagged.projectID == nil, "A record without projectID decodes as nil")
        object["projectID"] = "project-a"
        let tagged = try JSONDecoder().decode(NativeMemoryRecord.self, from: try JSONSerialization.data(withJSONObject: object))
        try check(tagged.projectID == "project-a", "A record with projectID decodes it")

        var filter = NativeMemoryLibraryFilter()
        try check(filter.matches(untagged) && filter.matches(tagged), "No project filter matches every record")
        filter.project = "project-a"
        try check(filter.matches(tagged) && !filter.matches(untagged), "The project filter keeps only that project's records")
        filter.project = "project-b"
        try check(!filter.matches(tagged), "Another project's filter excludes the record")

        let proposal = NativeMemoryProposal(
            id: "proposal", kind: .create, title: "Beds", summary: "Tomatoes in bed two", details: [],
            group: template.group, category: template.category, bank: template.bank, durability: template.durability,
            expiry: nil, targetIDs: [], sourceConversationID: nil, sourceMessageID: nil, createdAt: template.createdAt,
            status: .pending)
        let proposalData = try JSONEncoder().encode(proposal)
        try check(try JSONDecoder().decode(NativeMemoryProposal.self, from: proposalData).projectID == nil, "A proposal without projectID decodes as nil")
        var taggedProposal = proposal
        taggedProposal.projectID = "project-a"
        let roundTrip = try JSONDecoder().decode(NativeMemoryProposal.self, from: try JSONEncoder().encode(taggedProposal))
        try check(roundTrip.projectID == "project-a", "A proposal round-trips its projectID")
    }
}
