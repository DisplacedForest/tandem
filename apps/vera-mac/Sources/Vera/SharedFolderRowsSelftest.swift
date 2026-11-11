import Foundation

final class SharedFolderFailingRepository: ChatRepository, ProjectRepository, @unchecked Sendable {
    let inner: LocalChatRepository
    private let lock = NSLock()
    private var conversationsFail = false
    private var projectsFail = false

    init(inner: LocalChatRepository) { self.inner = inner }

    var failConversations: Bool {
        get { lock.lock(); defer { lock.unlock() }; return conversationsFail }
        set { lock.lock(); conversationsFail = newValue; lock.unlock() }
    }

    var failProjects: Bool {
        get { lock.lock(); defer { lock.unlock() }; return projectsFail }
        set { lock.lock(); projectsFail = newValue; lock.unlock() }
    }

    private func scripted() -> NSError {
        NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "scripted save failure"])
    }

    func listConversations() throws -> [Conversation] { try inner.listConversations() }
    func messages(conversationID: String) throws -> [Message] { try inner.messages(conversationID: conversationID) }
    func recentMessages(conversationID: String, limit: Int) throws -> [Message] {
        try inner.recentMessages(conversationID: conversationID, limit: limit)
    }
    func saveConversation(_ conversation: Conversation) throws {
        if failConversations { throw scripted() }
        try inner.saveConversation(conversation)
    }
    func saveMessage(_ message: Message, conversationID: String, ordinal: Int) throws {
        try inner.saveMessage(message, conversationID: conversationID, ordinal: ordinal)
    }
    func deleteConversation(_ id: String) throws { try inner.deleteConversation(id) }
    func conversation(originType: String, originID: String) throws -> Conversation? {
        try inner.conversation(originType: originType, originID: originID)
    }
    func createOriginConversation(_ conversation: Conversation, seed: Message) throws {
        try inner.createOriginConversation(conversation, seed: seed)
    }
    func referencedAttachmentFileNames() throws -> Set<String> { try inner.referencedAttachmentFileNames() }

    func listProjects() throws -> [ProjectRecord] { try inner.listProjects() }
    func project(_ id: String) throws -> ProjectRecord? { try inner.project(id) }
    func saveProject(_ project: ProjectRecord) throws {
        if failProjects { throw scripted() }
        try inner.saveProject(project)
    }
    func deleteProject(_ id: String) throws -> [String] { try inner.deleteProject(id) }
    func conversationIDs(projectID: String) throws -> [String] { try inner.conversationIDs(projectID: projectID) }
    func setConversationProject(_ conversationID: String, projectID: String?) throws {
        try inner.setConversationProject(conversationID, projectID: projectID)
    }
    func projectFilesDirectory(_ projectID: String) -> URL { inner.projectFilesDirectory(projectID) }
    func addProjectFile(_ projectID: String, from url: URL) throws -> ProjectFile { try inner.addProjectFile(projectID, from: url) }
    func removeProjectFile(_ projectID: String, fileID: String) throws { try inner.removeProjectFile(projectID, fileID: fileID) }
}

@MainActor
extension SelfTest {
    static func runSharedFolderRows() throws {
        let require = NativeTaskFixture.require
        let thread = "shared-thread"
        func chat(_ id: String, _ title: String, _ grants: [FolderGrant], project: String? = nil) -> Conversation {
            var conversation = Conversation(id: id, title: title, messages: [], updatedAt: Date())
            conversation.grants = grants
            conversation.projectID = project
            return conversation
        }
        func project(_ id: String, _ name: String, _ grants: [FolderGrant], files: [ProjectFile] = []) -> ProjectRecord {
            ProjectRecord(id: id, name: name, instructions: "", grants: grants, files: files, createdAt: Date(), updatedAt: Date())
        }
        func rows(_ conversations: [Conversation], _ projects: [ProjectRecord] = [], name: String? = "Ada") -> [SharedFolderRow] {
            SharedFolderRows.rows(conversations: conversations, projects: projects, companionThreadID: thread, name: name)
        }

        let seedlings = FolderGrant(id: "g-seedlings", path: "/garden/Seedlings")
        let greenhouse = chat("c-greenhouse", "Greenhouse notes", [seedlings])
        let single = rows([greenhouse])
        try require(single.count == 1 && single[0].title == "Seedlings" && single[0].path == "/garden/Seedlings"
                    && single[0].sentence == .literal("Shared with Greenhouse notes")
                    && single[0].kind == .chat(conversationID: "c-greenhouse", grantID: "g-seedlings") && !single[0].readOnly,
                    "A chat's folder is one row naming the folder and the chat: \(single)")
        try require(rows([chat("c-empty", "Nothing here", [])]).isEmpty, "Nothing shared means no rows")
        let missing = rows([chat("c-gone", "Old chat", [FolderGrant(path: "/nowhere/\(UUID().uuidString)/Gone")])])
        try require(missing.count == 1 && missing[0].title == "Gone", "A folder missing on disk is still listed")

        let journal = FolderGrant(id: "g-journal", path: "/home/Journal")
        let companion = chat(thread, "Ada", [journal])
        for name in ["Ada", nil] as [String?] {
            let listed = rows([companion], name: name)
            try require(listed.count == 1 && listed[0].sentence == .parts([.text("Shared with "), .name, .text("'s thread")]),
                        "The companion's own conversation reads as its thread")
            let spoken = listed[0].spoken(name: name)
            try require(spoken == (name == nil ? "Shared with your companion's thread" : "Shared with Ada's thread"),
                        "The companion's thread follows the saved name: \(spoken)")
            try require(listed[0].stopLabel(name: name).hasPrefix("Stop sharing Journal, shared with ")
                        && listed[0].stopLabel(name: name).hasSuffix("'s thread"),
                        "The stop button names the folder and the place: \(listed[0].stopLabel(name: name))")
        }

        let plans = FolderGrant(id: "g-plans", path: "/garden/Plans")
        let garden = project("p-garden", "Spring garden", [plans])
        func projectLine(_ members: Int) throws -> String {
            let members = (0..<members).map { chat("m-\($0)", "Member \($0)", [], project: "p-garden") }
            let listed = rows(members + [chat("m-other", "Elsewhere", [], project: "p-other")], [garden])
            guard listed.count == 1, case .project(let id, let grant) = listed[0].kind, id == "p-garden", grant == "g-plans" else {
                throw NativeTaskFixture.Failure.assertion("A project's folder is one project row: \(listed)")
            }
            return listed[0].spoken(name: "Ada")
        }
        try require(try projectLine(0) == "Shared with the project Spring garden, no chats yet", "A project with no chats says so")
        try require(try projectLine(1) == "Shared with the project Spring garden, used by 1 chat", "A project with one chat counts it")
        try require(try projectLine(3) == "Shared with the project Spring garden, used by 3 chats", "A project with three chats counts them")

        let receipts = FolderGrant(id: "g-receipts", path: "/archive/Receipts", readOnly: true)
        let readOnly = rows([chat("c-receipts", "Receipts", [receipts])], [project("p-ro", "Archive", [FolderGrant(id: "g-ro", path: "/archive/Old", readOnly: true)])])
        try require(readOnly.count == 2 && readOnly.allSatisfy(\.readOnly)
                    && readOnly.map { $0.spoken(name: nil) }.sorted() == ["Shared with Receipts. Read only.", "Shared with the project Archive, no chats yet. Read only."],
                    "A read only folder says so after its sentence: \(readOnly.map { $0.spoken(name: nil) })")
        let readOnlyThread = rows([chat(thread, "Ada", [FolderGrant(path: "/home/Letters", readOnly: true)])], name: nil)
        try require(readOnlyThread.first?.spoken(name: nil) == "Shared with your companion's thread. Read only.", "The companion's read only folder says so too")

        let sharedTwice = FolderGrant(id: "g-twice-a", path: "/garden/Seed packets")
        let sharedTwiceAgain = FolderGrant(id: "g-twice-b", path: "/garden/Seed packets")
        let twice = rows([chat("c-one", "One", [sharedTwice]), chat("c-two", "Two", [sharedTwiceAgain])],
                         [project("p-twice", "Garden", [FolderGrant(id: "g-twice-c", path: "/garden/Seed packets")])])
        try require(twice.count == 3 && twice.allSatisfy { $0.title == "Seed packets" } && Set(twice.map(\.id)).count == 3,
                    "The same folder shared in three places is three rows with the plain name: \(twice.map(\.title))")

        let work = FolderGrant(id: "g-work", path: "/srv/someone/Work/Documents")
        let home = FolderGrant(id: "g-home", path: "/srv/someone/Home/Documents")
        let pair = rows([chat("c-work", "Work chat", [work]), chat("c-home", "Home chat", [home])])
        try require(pair.map(\.title) == ["Home/Documents", "Work/Documents"],
                    "Two different folders with the same name show their parent: \(pair.map(\.title))")
        let deepA = FolderGrant(id: "g-deep-a", path: "/one/Work/Documents")
        let deepB = FolderGrant(id: "g-deep-b", path: "/two/Work/Documents")
        let deepC = FolderGrant(id: "g-deep-c", path: "/three/Home/Documents")
        let deep = rows([chat("c-deep", "Deep", [deepA, deepB, deepC])])
        try require(Set(deep.map(\.title)) == ["one/Work/Documents", "two/Work/Documents", "Home/Documents"],
                    "Parents that still match add one more folder, and only where needed: \(deep.map(\.title))")
        let rootLevel = rows([chat("c-root", "Root", [FolderGrant(path: "/Documents"), FolderGrant(path: "/srv/Documents")])])
        try require(Set(rootLevel.map(\.title)).count == 2, "Folders that can't be told apart by parents still read differently: \(rootLevel.map(\.title))")
        let mixed = rows([chat("c-mixed", "Mixed", [work]), chat("c-mixed-2", "Again", [FolderGrant(path: work.path)]), chat("c-mixed-3", "Other", [home])])
        try require(mixed.filter { $0.path == work.path }.allSatisfy { $0.title == "Work/Documents" } && mixed.count == 3,
                    "The same folder in two places keeps one title while another folder with its name is told apart")

        let filesDir = FolderGrant(id: "g-files", path: "/projects/p-files/files")
        let withFiles = project("p-files", "Recipes", [filesDir], files: [ProjectFile(id: "f", name: "Bread.pdf", fileName: "bread.pdf", byteSize: 10, addedAt: Date())])
        let fileRows = rows([chat("c-recipes", "Baking", [], project: "p-files")], [withFiles])
        try require(fileRows.count == 1 && fileRows[0].title == "files" && !fileRows.contains { $0.title.hasSuffix(" files") || $0.readOnly },
                    "A project's added files never show as a shared folder, only its real folders: \(fileRows.map(\.title))")

        let unsorted = rows([chat("c-z", "Zinnias", [FolderGrant(id: "g-b1", path: "/b/Beds")]), chat("c-a", "Asters", [FolderGrant(id: "g-b2", path: "/b/Beds")]),
                             chat("c-m", "Middle", [FolderGrant(id: "g-a", path: "/a/Annuals")])],
                            [project("p-b", "Borders", [FolderGrant(id: "g-b3", path: "/b/Beds")])])
        try require(unsorted.map { $0.spoken(name: "Ada") } == ["Shared with Middle", "Shared with Asters", "Shared with the project Borders, no chats yet", "Shared with Zinnias"],
                    "Rows sort by folder name, then by place: \(unsorted.map { $0.spoken(name: "Ada") })")
        let again = rows([chat("c-m", "Middle", [FolderGrant(id: "g-a", path: "/a/Annuals")]), chat("c-a", "Asters", [FolderGrant(id: "g-b2", path: "/b/Beds")]),
                          chat("c-z", "Zinnias", [FolderGrant(id: "g-b1", path: "/b/Beds")])],
                         [project("p-b", "Borders", [FolderGrant(id: "g-b3", path: "/b/Beds")])])
        try require(again.map(\.id) == unsorted.map(\.id), "The order doesn't depend on the order things were loaded")

        let veraWord = "Ver" + "a"
        let hostile = ["\(veraWord) notes", "Notes about {name}", "**bold** _soft_ [link](example)", "{name}'s plan"]
        for text in hostile {
            let literal = rows([chat("c-hostile", text, [FolderGrant(path: "/x/\(text)")])],
                               [project("p-hostile", text, [FolderGrant(path: "/y/\(text)")])])
            for name in ["Ada", nil] as [String?] {
                try require(literal.allSatisfy { $0.title.hasSuffix(text) }, "A folder name is shown exactly: \(literal.map(\.title))")
                try require(literal.contains { $0.spoken(name: name) == "Shared with \(text)" }
                            && literal.contains { $0.spoken(name: name) == "Shared with the project \(text), no chats yet" },
                            "Chat and project names are shown exactly: \(literal.map { $0.spoken(name: name) })")
            }
        }

        let everyRow = single + rows([companion]) + pair + deep + readOnly + twice + readOnlyThread + rows([chat("m-1", "Member", [], project: "p-garden")], [garden])
        let banned: Set<String> = [veraWord.lowercased(), "grant", "grants", "granted", "revoke", "revoked", "scope", "access", "she", "her", "he", "his"]
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        }
        for name in ["Ada", nil] as [String?] {
            let strings = SharedFolderRows.screenStrings(everyRow, name: name)
            try require(SharedFolderRows.screenStrings([], name: name).allSatisfy { RulesCopy.screenStrings(name: name).contains($0) },
                        "The section's fixed copy is part of the screen copy audits")
            for text in strings {
                let hits = words(text).intersection(banned)
                try require(hits.isEmpty, "Shared folder copy uses no internal or gendered words: \(hits) in \(text)")
                try require(!text.contains("\u{2014}"), "Shared folder copy has no long dash: \(text)")
                try require(!text.contains(CompanionSentence.placeholder), "Shared folder copy fills the name: \(text)")
                if name == nil { try require(!words(text).contains("tandem"), "An unnamed companion is never called by the app's name: \(text)") }
            }
        }
        try require(SharedFolderRows.info == "Sharing a folder is what lets files there be edited and commands run there. The rules above decide whether you're asked first.",
                    "The info sentence reads as written")
        print("  shared folder rows OK (chat, companion, project counts, read only, same folder twice, same names told apart, files area left out, order, copy, names as written)")
    }

    static func runSharedFolderRowsStore() throws {
        let require = NativeTaskFixture.require
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("shared-folders-\(UUID().uuidString.lowercased())", isDirectory: true)
        let attachments = base.appendingPathComponent("attachments", isDirectory: true)
        let projectFiles = base.appendingPathComponent("projects", isDirectory: true)
        try manager.createDirectory(at: attachments, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let repository = SharedFolderFailingRepository(inner: try LocalChatRepository(inMemory: true, artifactDirectory: attachments, projectsDirectory: projectFiles))
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, attachmentStore: NativeAttachmentStore(directory: attachments))
        func folder(_ name: String) throws -> String {
            let path = base.appendingPathComponent(name, isDirectory: true).path
            try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        func add(_ id: String, _ title: String, _ grants: [FolderGrant], project: String? = nil) throws {
            var conversation = Conversation(id: id, title: title, messages: [], updatedAt: Date())
            conversation.grants = grants
            conversation.projectID = project
            try repository.saveConversation(conversation)
            conversation.isPersisted = true
            store.conversations.insert(conversation, at: 0)
            store.refreshConversationGrants(id)
        }
        func paths(_ id: String) -> Set<String> { Set(store.grants(for: id).map(\.path)) }
        func toolPaths(_ id: String) -> Set<String> { Set(store.nativeGrantSource.grants(for: id).map(\.path)) }
        func row(_ id: String) -> SharedFolderRow? { store.sharedFolderRows.first { $0.id == id } }

        let seedlings = FolderGrant(id: "s-seedlings", path: try folder("Seedlings"))
        let orders = FolderGrant(id: "s-orders", path: try folder("Orders"))
        try add("s-open", "Open chat", [seedlings])
        try add("s-other", "Other chat", [orders])
        store.selectedID = "s-open"
        guard let otherRow = row("chat|s-other|s-orders") else { throw NativeTaskFixture.Failure.assertion("The other chat's folder is listed") }
        try require(store.stopSharing(otherRow), "Stopping a chat that isn't open saves")
        try require(store.conversations.first { $0.id == "s-other" }?.grants.isEmpty == true && paths("s-other").isEmpty && toolPaths("s-other").isEmpty,
                    "The other chat no longer has the folder")
        try require(paths("s-open") == [seedlings.path] && store.selectedID == "s-open" && store.selectedGrants.map(\.id) == ["s-seedlings"],
                    "The open chat is untouched")
        try require(row("chat|s-other|s-orders") == nil, "The row goes away")
        try require(try repository.inner.listConversations().first { $0.id == "s-other" }?.grants.isEmpty == true, "The change is saved")

        store.revokeGrant("s-seedlings")
        try require(paths("s-open").isEmpty && row("chat|s-open|s-seedlings") == nil, "The chat chip's remove goes through the same path")

        guard let project = store.createProject(name: "Spring garden") else { throw NativeTaskFixture.Failure.assertion("The project saves") }
        let plans = FolderGrant(id: "s-plans", path: try folder("Plans"))
        try require(store.saveProjectEdits(project.id, name: project.name, instructions: "", grants: [plans]), "The project folder saves")
        let ownBeds = FolderGrant(id: "s-beds", path: try folder("Beds"))
        try add("s-member-a", "Member A", [ownBeds], project: project.id)
        try add("s-member-b", "Member B", [], project: project.id)
        try require(paths("s-member-a") == [plans.path, ownBeds.path] && paths("s-member-b") == [plans.path], "Project chats see the project folder")
        guard let projectRow = row("project|\(project.id)|s-plans") else { throw NativeTaskFixture.Failure.assertion("The project folder is listed") }
        try require(projectRow.spoken(name: nil) == "Shared with the project Spring garden, used by 2 chats", "The project row counts its chats")

        repository.failProjects = true
        try require(!store.stopSharing(projectRow), "A failed project save reports it")
        try require(row(projectRow.id) != nil && store.rulesNotice == SharedFolderRows.failed
                    && store.project(project.id)?.grants.map(\.id) == ["s-plans"] && paths("s-member-b") == [plans.path] && toolPaths("s-member-b") == [plans.path],
                    "A failed project save keeps the folder shared and says so")
        repository.failProjects = false
        try require(store.stopSharing(projectRow), "Stopping a project folder saves")
        try require(store.rulesNotice == nil, "A later success clears the notice")
        try require(paths("s-member-a") == [ownBeds.path] && paths("s-member-b").isEmpty && toolPaths("s-member-a") == [ownBeds.path] && toolPaths("s-member-b").isEmpty,
                    "Every chat in the project loses the folder and a chat's own folder stays")
        try require(store.project(project.id)?.grants.isEmpty == true && row(projectRow.id) == nil, "The project no longer shares it")

        let packets = try folder("Packets")
        try add("s-twin-a", "Twin A", [FolderGrant(id: "s-packets-a", path: packets)])
        try add("s-twin-b", "Twin B", [FolderGrant(id: "s-packets-b", path: packets)])
        guard let twinA = row("chat|s-twin-a|s-packets-a") else { throw NativeTaskFixture.Failure.assertion("The first copy is listed") }
        repository.failConversations = true
        try require(!store.stopSharing(twinA), "A failed chat save reports it")
        try require(store.grantError == nil && store.projectError == nil, "A failed save from the list says it once, in the list's own line")
        try require(row(twinA.id) != nil && store.rulesNotice == SharedFolderRows.failed && paths("s-twin-a") == [packets] && toolPaths("s-twin-a") == [packets],
                    "A failed chat save keeps the folder shared, in the list and for the chat's tools")
        repository.failConversations = false
        try require(store.stopSharing(twinA) && store.rulesNotice == nil, "Trying again saves")
        try require(row(twinA.id) == nil && row("chat|s-twin-b|s-packets-b") != nil && paths("s-twin-b") == [packets],
                    "Stopping one of two rows for the same folder leaves the other")

        store.rulesNotice = "Some other notice"
        _ = store.stopSharing(conversationID: "s-twin-b", grantID: "s-packets-b")
        try require(store.rulesNotice == "Some other notice", "Stopping by id leaves an unrelated notice alone")
        print("  shared folder rows store OK (another chat, the open chat untouched, project chats, failed saves keep the folder, one of two)")
    }
}
