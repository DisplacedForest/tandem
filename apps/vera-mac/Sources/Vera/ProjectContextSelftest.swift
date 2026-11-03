import Foundation

final class ProjectContextMemoryService: NativeMemoryServing, @unchecked Sendable {
    private let lock = NSLock()
    private var down = false
    private var typed: [NativeDomainCandidate] = []

    var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return down }
        set { lock.lock(); down = newValue; lock.unlock() }
    }

    var domainEntries: [NativeDomainCandidate] {
        get { lock.lock(); defer { lock.unlock() }; return typed }
        set { lock.lock(); typed = newValue; lock.unlock() }
    }

    func extraction(
        user: String, assistant: String, sourceConversationID: String?, sourceMessageID: String?,
        sensitiveHandling: NativeMemorySensitiveHandling,
        existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> NativeMemoryExtraction {
        let entries = domainEntries
        if !entries.isEmpty {
            if failing { throw NativeMemoryServiceError.unavailable("The memory endpoint could not be reached") }
            return NativeMemoryExtraction(proposals: [], domainEntries: entries)
        }
        return NativeMemoryExtraction(proposals: try await proposals(
            user: user, assistant: assistant, sourceConversationID: sourceConversationID,
            sourceMessageID: sourceMessageID, existing: existing, now: now))
    }

    func embed(_ text: String) async throws -> [Double] { [1, 0] }

    func proposals(
        user: String, assistant: String, sourceConversationID: String?, sourceMessageID: String?,
        existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] {
        if failing { throw NativeMemoryServiceError.unavailable("The memory endpoint could not be reached") }
        return [NativeMemoryProposal(
            id: UUID().uuidString, kind: .create, title: "Bed layout", summary: "Tomatoes go in bed two",
            details: ["Tomatoes go in bed two"], group: .areas, category: .preference, bank: "personal",
            durability: .durable, expiry: nil, targetIDs: [], sourceConversationID: sourceConversationID,
            sourceMessageID: nil, createdAt: now, status: .pending)]
    }

    func proposal(
        request: String, existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] { [] }
}

final class ProjectMoveFailingRepository: ChatRepository, ProjectRepository, @unchecked Sendable {
    let inner: LocalChatRepository
    private let lock = NSLock()
    private var failing = false
    private var savingFails = false

    init(inner: LocalChatRepository) { self.inner = inner }

    var failMoves: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); failing = newValue; lock.unlock() }
    }

    var failSaves: Bool {
        get { lock.lock(); defer { lock.unlock() }; return savingFails }
        set { lock.lock(); savingFails = newValue; lock.unlock() }
    }

    func listConversations() throws -> [Conversation] { try inner.listConversations() }
    func messages(conversationID: String) throws -> [Message] { try inner.messages(conversationID: conversationID) }
    func recentMessages(conversationID: String, limit: Int) throws -> [Message] {
        try inner.recentMessages(conversationID: conversationID, limit: limit)
    }
    func saveConversation(_ conversation: Conversation) throws { try inner.saveConversation(conversation) }
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
        if failSaves { throw ProjectStoreError.unreadable("Project") }
        try inner.saveProject(project)
    }
    func deleteProject(_ id: String) throws -> [String] { try inner.deleteProject(id) }
    func conversationIDs(projectID: String) throws -> [String] { try inner.conversationIDs(projectID: projectID) }
    func setConversationProject(_ conversationID: String, projectID: String?) throws {
        if failMoves {
            throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "scripted move failure"])
        }
        try inner.setConversationProject(conversationID, projectID: projectID)
    }
    func projectFilesDirectory(_ projectID: String) -> URL { inner.projectFilesDirectory(projectID) }
    func addProjectFile(_ projectID: String, from url: URL) throws -> ProjectFile { try inner.addProjectFile(projectID, from: url) }
    func removeProjectFile(_ projectID: String, fileID: String) throws { try inner.removeProjectFile(projectID, fileID: fileID) }
}

enum ProjectContextSelftest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    @MainActor
    static func run() async throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory
            .appendingPathComponent("vera-project-context-\(UUID().uuidString.lowercased())", isDirectory: true)
        let artifacts = base.appendingPathComponent("attachments", isDirectory: true)
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        let folder = base.appendingPathComponent("garden-plans", isDirectory: true)
        try manager.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: artifacts, projectsDirectory: projects)
        let service = ProjectContextMemoryService()
        var settings = NativeMemorySettings.fresh
        settings.enabled = true
        settings.extractionModel = "extraction-model"
        settings.generateFromChats = true
        settings.bankScope = "all"
        let config = NativeChatConfig(
            baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
            model: "local-model", chatTemplateKwargs: nil)
        let store = ChatStore(
            nativeConfig: config, nativeTransport: ArtifactScriptTransport(), repository: repository,
            nativeMemorySettings: settings, nativeMemoryService: service,
            attachmentStore: NativeAttachmentStore(directory: artifacts), artifactPersistenceEnabled: false)

        guard let project = store.createProject(name: "Garden") else { throw Failure(description: "The project was not created") }
        store.setProjectInstructions(project.id, "Answer in metric units.")
        store.addProjectFolder(project.id, url: folder)
        store.newConversation(inProject: project.id)
        guard let chat = store.selectedID else { throw Failure(description: "No project chat is selected") }
        store.setConversationInstructions(chat, "Keep it brief.")
        try check(store.projectForConversation(chat)?.id == project.id, "A new chat in a project belongs to it")

        func folderPaths() -> [String] { store.grants(for: chat).map(\.path) }
        let folderPath = try FolderGrant.make(url: folder).path
        let scoped = store.resolvePromptScopes(conversationID: chat).instructions
        try check(scoped == "Answer in metric units.\n\nKeep it brief.", "Project instructions come before the chat's own, got \(scoped)")
        try check(folderPaths().contains(folderPath), "A project chat sees the project folder")
        try check(store.nativeGrantSource.grants(for: chat).contains { $0.path == folderPath }, "The tool grant source holds the project folder")

        let note = base.appendingPathComponent("Seed list.md")
        try Data("Tomatoes, beans".utf8).write(to: note)
        store.addProjectFile(project.id, url: note)
        let filesGrant = store.grants(for: chat).first { $0.name == "Garden files" }
        try check(filesGrant?.readOnly == true, "Project files appear as a read-only grant named after the project")

        store.moveConversation(chat, toProject: nil)
        try check(store.resolvePromptScopes(conversationID: chat).instructions == "Keep it brief.", "Moving out drops the project instructions")
        try check(!folderPaths().contains(folderPath) && !store.grants(for: chat).contains { $0.name == "Garden files" },
                  "Moving out drops the project folders")
        try check(store.nativeGrantSource.grants(for: chat).isEmpty, "Moving out clears the tool grant source")

        store.moveConversation(chat, toProject: project.id)
        try check(store.resolvePromptScopes(conversationID: chat).instructions.hasPrefix("Answer in metric units."), "Moving back restores the instructions")
        try check(folderPaths().contains(folderPath) && store.grants(for: chat).contains { $0.name == "Garden files" },
                  "Moving back restores the project folders")

        try checkFilesGrantStaysReadOnly(store, chat: chat, projectID: project.id)
        try await checkProposalTagging(store, service: service, chat: chat, projectID: project.id)
        try await checkTypedTagging(store, service: service, repository: repository, projectID: project.id)
        try await checkNewChatAndReplayScope(store, service: service, projectChat: chat, projectID: project.id)

        store.recordCanvasArtifacts([Artifact(id: "plan", title: "Bed plan", type: .markdown, language: "", content: "Bed two")],
                                    conversationID: chat, messageID: "plan-message")
        try check(store.projectArtifacts(project.id).count == 1, "The project lists its chat's artifact")
        store.deleteProject(project.id)
        try check(store.project(project.id) == nil, "The project is gone after delete")
        try check(store.conversations.first { $0.id == chat }.map { $0.projectID == nil } == true, "Deleting a project keeps its chat")
        try check(store.artifactRecords.contains { $0.conversationID == chat && $0.title == "Bed plan" }, "Deleting a project keeps its artifacts")
        try check(store.resolvePromptScopes(conversationID: chat).instructions == "Keep it brief.", "A released chat keeps only its own instructions")
        try check(!folderPaths().contains(folderPath), "A released chat loses the project folders")

        try checkPreferProject()
        try await checkProjectRecall(store, repository: repository)
        try checkFailedMove(base: base)
        try await checkUpdateRetagging(store, repository: repository)
        print("  project context OK (instructions, folders, files grant, move out and back, delete keeps chats and artifacts, proposal tagging, typed tagging, queued replay, replay scope, new chat reuse, recall preference, read-only files folder, failed moves, update retagging)")
    }

    @MainActor
    static func checkProposalTagging(_ store: ChatStore, service: ProjectContextMemoryService, chat: String, projectID: String) async throws {
        let reply = Message(role: .assistant, text: "Noted, tomatoes in bed two.")
        let source = NativeMemoryTurnSource(conversationID: chat, messageID: "turn-one", date: Date())
        await store.learnFromCompletedTurn(user: "Put the tomatoes in bed two", assistant: reply, source: source,
                                           turnKey: chat + "|turn-one", conversationExcluded: false)
        let proposal = store.memoryProposals.first { $0.title == "Bed layout" }
        try check(proposal?.projectID == projectID, "A proposal from a project chat carries the project")
        guard let proposal else { return }
        try check(store.acceptMemoryProposal(proposal), "The project proposal is accepted")
        let saved = store.memoryRecords.first { $0.title == "Bed layout" }
        try check(saved?.projectID == projectID, "The accepted record carries the project")

        service.failing = true
        let queuedSource = NativeMemoryTurnSource(conversationID: chat, messageID: "turn-two", date: Date())
        await store.learnFromCompletedTurn(user: "Beans go in bed three", assistant: reply, source: queuedSource,
                                           turnKey: chat + "|turn-two", conversationExcluded: false)
        try check(store.queuedMemoryTurns.last?.projectID == projectID, "A queued turn remembers its project")
        service.failing = false
        let before = Set(store.memoryProposals.map(\.id))
        await store.drainQueuedMemoryTurns()
        let replayed = store.memoryProposals.filter { !before.contains($0.id) }
        try check(!replayed.isEmpty && replayed.allSatisfy { $0.projectID == projectID }, "A replayed turn tags its proposals with the project")
        for pending in store.memoryProposals { store.dismissMemoryProposal(pending) }
        store.reloadNativeMemory()
    }

    @MainActor
    static func checkFilesGrantStaysReadOnly(_ store: ChatStore, chat: String, projectID: String) throws {
        guard let directory = store.projectRepository?.projectFilesDirectory(projectID),
              let index = store.conversations.firstIndex(where: { $0.id == chat }) else {
            throw Failure(description: "No project files folder for the grant check")
        }
        var writable = try FolderGrant.make(url: directory)
        writable.readOnly = false
        let saved = store.conversations[index].grants
        store.conversations[index].grants = [writable]
        store.refreshConversationGrants(chat)
        defer {
            if let restore = store.conversations.firstIndex(where: { $0.id == chat }) {
                store.conversations[restore].grants = saved
                store.refreshConversationGrants(chat)
            }
        }
        let matching = store.grants(for: chat).filter { $0.path == writable.path }
        try check(matching.count == 1 && matching[0].readOnly, "A writable chat grant on the project files folder stays read-only, got \(matching.map(\.readOnly))")
        let sourced = store.nativeGrantSource.grants(for: chat).filter { $0.path == writable.path }
        try check(sourced.count == 1 && sourced[0].readOnly, "The tool grant source holds one read-only files grant")
        let access = NativeFolderAccess(grants: store.grants(for: chat))
        let target = try access.locate(writable.path + "/written.txt")
        do {
            _ = try NativeFolderTools.write(target, content: "new", ledger: NativeFileChangeLedger())
            throw Failure(description: "Writing into the project files folder must be refused")
        } catch let error as NativeFolderAccessError {
            try check(error == .readOnly(target.path), "The project files write reports read-only: \(error)")
        }
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("written.txt").path),
                  "Nothing is written into the project files folder")
    }

    @MainActor
    static func checkUpdateRetagging(_ store: ChatStore, repository: LocalChatRepository) async throws {
        let now = Date()
        func fact(_ id: String, title: String, detail: String, project: String?) -> NativeMemoryRecord {
            var record = NativeMemoryRecord(
                id: id, title: title, summary: detail, details: [detail], group: .areas, category: .preference,
                bank: "personal", durability: .durable, expiry: nil, status: .approved, embedding: nil,
                sourceConversationID: nil, sourceMessageID: nil, createdAt: now, updatedAt: now)
            record.projectID = project
            return record
        }
        func update(_ target: String, title: String, detail: String, project: String?) -> NativeMemoryProposal {
            var proposal = NativeMemoryProposal(
                id: UUID().uuidString, kind: .update, title: title, summary: detail, details: [detail],
                group: .areas, category: .preference, bank: "personal", durability: .durable, expiry: nil,
                targetIDs: [target], sourceConversationID: nil, sourceMessageID: nil, createdAt: now, status: .pending)
            proposal.projectID = project
            return proposal
        }
        try repository.saveMemory(fact("trellis-shared", title: "Trellis height", detail: "Trellis height guidance", project: nil),
                                  decision: .accepted, note: "Test approval")
        try repository.saveMemory(fact("trellis-other", title: "Trellis width", detail: "Trellis height guidance", project: "retag-other"),
                                  decision: .accepted, note: "Test approval")
        try repository.saveMemory(fact("hedge-tagged", title: "Hedge trim", detail: "Hedge trim schedule", project: "retag-kept"),
                                  decision: .accepted, note: "Test approval")
        store.reloadNativeMemory()

        let tagging = update("trellis-shared", title: "Trellis height", detail: "Trellis height guidance revised", project: "retag-one")
        try repository.saveProposal(tagging)
        store.reloadNativeMemory()
        try check(store.acceptMemoryProposal(tagging), "A project-tagged update is accepted")
        try check(store.memoryRecords.first { $0.id == "trellis-shared" }?.projectID == "retag-one",
                  "A project-tagged update moves a shared fact into the project")
        let recalled = await store.retrieveApprovedMemory("trellis height guidance", projectID: "retag-one")
        try check(recalled.selected.first?.record.id == "trellis-shared",
                  "The retagged fact is preferred inside its project, got \(recalled.selected.map(\.record.id))")

        let plain = update("hedge-tagged", title: "Hedge trim", detail: "Hedge trim schedule revised", project: nil)
        try repository.saveProposal(plain)
        store.reloadNativeMemory()
        try check(store.acceptMemoryProposal(plain), "An untagged update is accepted")
        try check(store.memoryRecords.first { $0.id == "hedge-tagged" }?.projectID == "retag-kept",
                  "An untagged update keeps the fact's project")
        for id in ["trellis-shared", "trellis-other", "hedge-tagged"] { try repository.deleteMemory(id) }
        store.reloadNativeMemory()
    }

    @MainActor
    static func checkFailedMove(base: URL) throws {
        let manager = FileManager.default
        let root = base.appendingPathComponent("failed-move", isDirectory: true)
        let attachments = root.appendingPathComponent("attachments", isDirectory: true)
        let folder = root.appendingPathComponent("shared-folder", isDirectory: true)
        try manager.createDirectory(at: attachments, withIntermediateDirectories: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let inner = try LocalChatRepository(inMemory: true, artifactDirectory: attachments,
                                            projectsDirectory: root.appendingPathComponent("projects", isDirectory: true))
        let repository = ProjectMoveFailingRepository(inner: inner)
        let store = ChatStore(
            nativeConfig: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
                                           model: "local-model", chatTemplateKwargs: nil),
            nativeTransport: ArtifactScriptTransport(), repository: repository,
            attachmentStore: NativeAttachmentStore(directory: attachments), artifactPersistenceEnabled: false)
        guard let project = store.createProject(name: "Orchard") else { throw Failure(description: "The move fixture project was not created") }
        store.addProjectFolder(project.id, url: folder)
        store.newConversation()
        guard let chat = store.selectedID, let index = store.conversations.firstIndex(where: { $0.id == chat }) else {
            throw Failure(description: "No move fixture chat")
        }
        store.conversations[index].isPersisted = true
        try inner.saveConversation(store.conversations[index])
        let folderPath = try FolderGrant.make(url: folder).path

        repository.failMoves = true
        let outside = store.grants(for: chat)
        store.moveConversation(chat, toProject: project.id)
        try check(store.conversations.first { $0.id == chat }.map { $0.projectID == nil } == true, "A failed move in leaves the chat outside")
        try check(store.grants(for: chat) == outside && !store.grants(for: chat).contains { $0.path == folderPath },
                  "A failed move in leaves the grants unchanged")
        try check(store.projectError?.contains("scripted move failure") == true, "A failed move sets the project error")
        try check(store.chatConfigurationError?.contains("scripted move failure") == true, "A failed move sets the chat error")
        try check(try inner.conversationIDs(projectID: project.id).isEmpty, "A failed move writes nothing")

        repository.failMoves = false
        store.clearProjectError()
        store.chatConfigurationError = nil
        store.moveConversation(chat, toProject: project.id)
        try check(store.conversations.first { $0.id == chat }?.projectID == project.id, "A working move joins the project")
        try check(store.projectError == nil, "A working move sets no error")
        let inside = store.grants(for: chat)
        guard let before = store.project(project.id) else { throw Failure(description: "Missing project before editing") }
        var staged = before
        staged.name = "Updated orchard"
        staged.instructions = "Keep answers concise."
        staged.grants = []
        try check(try inner.project(project.id) == before, "Staged edits do not persist before Save")
        repository.failSaves = true
        try check(!store.saveProjectEdits(project.id, name: staged.name, instructions: staged.instructions, grants: staged.grants),
                  "A failed project save reports failure")
        try check(try inner.project(project.id) == before, "Failed staged save keeps every stored field")
        try check(store.grants(for: chat) == inside, "Failed staged save keeps effective permissions")
        repository.failSaves = false
        try check(!store.saveProjectEdits(project.id, name: " ", instructions: staged.instructions, grants: []),
                  "An empty project name is rejected")
        try check(!store.saveProjectEdits(project.id, name: staged.name,
                                         instructions: String(repeating: "x", count: NativePromptValidation.instructionsLimit + 1), grants: []),
                  "Invalid instructions reject the whole edit")
        try check(try inner.project(project.id) == before, "Validation failure cannot partially rename or revoke folders")
        try check(store.saveProjectEdits(project.id, name: staged.name, instructions: staged.instructions, grants: []),
                  "Valid staged edits save together")
        try check(store.project(project.id)?.name == staged.name && store.project(project.id)?.instructions == staged.instructions,
                  "Save persists the edited name and instructions")
        try check(store.nativeGrantSource.grants(for: chat).isEmpty, "Save applies folder revocation to existing chats")
        try check(store.selectedID == chat && store.projectForConversation(chat)?.id == project.id,
                  "Editing keeps the current conversation and its membership")
        try check(store.saveProjectEdits(project.id, name: before.name, instructions: before.instructions, grants: before.grants),
                  "The project can restore its approved folders")

        try check(inside.contains { $0.path == folderPath }, "A joined chat sees the project folder")

        repository.failMoves = true
        store.moveConversation(chat, toProject: nil)
        try check(store.conversations.first { $0.id == chat }?.projectID == project.id, "A failed move out keeps the membership")
        try check(store.grants(for: chat) == inside, "A failed move out keeps the project grants")
        try check(store.nativeGrantSource.grants(for: chat).contains { $0.path == folderPath }, "A failed move out keeps the tool grants")
        try check(store.projectError != nil && store.chatConfigurationError != nil, "A failed move out sets both errors")
        try check(try inner.conversationIDs(projectID: project.id) == [chat], "A failed move out leaves the saved membership")
    }

    @MainActor
    static func checkTypedTagging(_ store: ChatStore, service: ProjectContextMemoryService, repository: LocalChatRepository,
                                  projectID: String) async throws {
        store.newConversation(inProject: projectID)
        guard let chat = store.selectedID, let index = store.conversations.firstIndex(where: { $0.id == chat }) else {
            throw Failure(description: "No typed fixture chat")
        }
        let text = "The greenhouse heater is set to twelve degrees"
        let user = Message(role: .user, text: text)
        store.conversations[index].isPersisted = true
        try repository.saveConversation(store.conversations[index])
        try repository.saveMessage(user, conversationID: chat, ordinal: 0)
        try repository.saveMessage(Message(role: .assistant, text: "Noted."), conversationID: chat, ordinal: 1)
        service.domainEntries = [NativeDomainCandidate(
            subject: "Greenhouse heater", scope: "personal",
            payload: .fact(predicate: "setting", value: "twelve degrees", quantity: nil),
            occurredAt: nil, evidence: .asserted, supersedes: nil, span: "set to twelve degrees")]
        defer { service.domainEntries = [] }
        await store.learnFromCompletedTurn(
            user: text, assistant: Message(role: .assistant, text: "Noted."),
            source: NativeMemoryTurnSource(conversationID: chat, messageID: user.id.uuidString, date: Date()),
            turnKey: chat + "|" + user.id.uuidString, conversationExcluded: false)
        store.reloadNativeMemory()
        guard let proposal = store.memoryProposals.first(where: { $0.domain?.label == "Greenhouse heater" }) else {
            throw Failure(description: "No typed proposal was staged")
        }
        try check(proposal.projectID == projectID, "A typed proposal from a project chat carries the project")
        try check(store.acceptMemoryProposal(proposal), "The typed proposal is accepted")
        let projected = store.memoryRecords.first { $0.domainEntityID == proposal.domain?.entry.entityID }
        try check(projected?.projectID == projectID, "The projected typed record carries the project, got \(String(describing: projected?.projectID))")
        try repository.refreshDomainProjections()
        let refreshed = try repository.approvedMemories().first { $0.domainEntityID == proposal.domain?.entry.entityID }
        try check(refreshed?.projectID == projectID, "A projection refresh keeps the project")
    }

    @MainActor
    static func checkNewChatAndReplayScope(_ store: ChatStore, service: ProjectContextMemoryService,
                                           projectChat: String, projectID: String) async throws {
        store.newConversation(inProject: projectID)
        guard let emptyProjectChat = store.selectedID else { throw Failure(description: "No empty project chat") }
        store.newConversation()
        guard let plain = store.selectedID else { throw Failure(description: "No plain chat") }
        try check(plain != emptyProjectChat && plain != projectChat, "New chat does not reuse an empty project chat")
        try check(store.conversations.first { $0.id == plain }.map { $0.projectID == nil } == true, "New chat starts outside any project")

        service.failing = true
        let reply = Message(role: .assistant, text: "Noted, mulch in autumn.")
        await store.learnFromCompletedTurn(
            user: "Mulch the beds in autumn", assistant: reply,
            source: NativeMemoryTurnSource(conversationID: plain, messageID: "outside-turn", date: Date()),
            turnKey: plain + "|outside-turn", conversationExcluded: false)
        let queued = store.queuedMemoryTurns.first { $0.turnKey == plain + "|outside-turn" }
        try check(queued != nil && queued?.projectID == nil, "A turn queued outside a project has no project")
        store.moveConversation(plain, toProject: projectID)
        service.failing = false
        let before = Set(store.memoryProposals.map(\.id))
        await store.drainQueuedMemoryTurns()
        let replayed = store.memoryProposals.filter { !before.contains($0.id) }
        try check(!replayed.isEmpty && replayed.allSatisfy { $0.projectID == nil }, "Replay keeps the scope captured when the turn ran")
        for pending in store.memoryProposals { store.dismissMemoryProposal(pending) }
        store.moveConversation(plain, toProject: nil)
    }

    static func candidate(_ id: String, project: String?) -> NativeMemoryCandidate {
        var record = NativeMemoryRecord(
            id: id, title: id, summary: id, details: [id], group: .areas, category: .preference, bank: "personal",
            durability: .durable, expiry: nil, status: .approved, embedding: nil, sourceConversationID: nil,
            sourceMessageID: nil, createdAt: Date(), updatedAt: Date())
        record.projectID = project
        return NativeMemoryCandidate(record: record)
    }

    static func checkPreferProject() throws {
        let ordered = [candidate("A", project: nil), candidate("B", project: "P1"), candidate("C", project: "P2"), candidate("D", project: "P1")]
        let ids = { (list: [NativeMemoryCandidate]) in list.map(\.record.id) }
        try check(ids(NativeMemoryRetrieval.preferProject(ordered, projectID: "P1")) == ["B", "D", "A", "C"], "P1 facts lead in their order")
        try check(ids(NativeMemoryRetrieval.preferProject(ordered, projectID: nil)) == ["A", "B", "C", "D"], "Outside a project nothing moves")
        try check(ids(NativeMemoryRetrieval.preferProject(ordered, projectID: "P2")) == ["C", "A", "B", "D"], "P2 facts lead in their order")
    }

    @MainActor
    static func checkProjectRecall(_ store: ChatStore, repository: LocalChatRepository) async throws {
        let now = Date()
        func record(_ id: String, title: String, project: String?) -> NativeMemoryRecord {
            var record = NativeMemoryRecord(
                id: id, title: title, summary: "Compost spacing guidance", details: ["Compost spacing guidance"],
                group: .areas, category: .preference, bank: "personal", durability: .durable, expiry: nil,
                status: .approved, embedding: nil, sourceConversationID: nil, sourceMessageID: nil,
                createdAt: now, updatedAt: now)
            record.projectID = project
            return record
        }
        try repository.saveMemory(record("shared-fact", title: "Spacing note A", project: nil), decision: .accepted, note: "Test approval")
        try repository.saveMemory(record("first-fact", title: "Spacing note B", project: "recall-one"), decision: .accepted, note: "Test approval")
        try repository.saveMemory(record("second-fact", title: "Spacing note C", project: "recall-two"), decision: .accepted, note: "Test approval")
        store.reloadNativeMemory()
        let plain = await store.retrieveApprovedMemory("compost spacing")
        try check(plain.selected.count == 3, "All three facts are recalled, got \(plain.selected.map(\.record.id))")
        try check(plain.trace?.notes.contains("Project facts ranked first.") != true, "Outside a project no reorder note appears")
        let first = await store.retrieveApprovedMemory("compost spacing", projectID: "recall-one")
        try check(first.selected.first?.record.id == "first-fact", "The first project's fact is injected first, got \(first.selected.map(\.record.id))")
        let second = await store.retrieveApprovedMemory("compost spacing", projectID: "recall-two")
        try check(second.selected.first?.record.id == "second-fact", "The second project's fact is injected first, got \(second.selected.map(\.record.id))")
        let moved = [first, second].contains { $0.trace?.notes.contains("Project facts ranked first.") == true }
        try check(moved, "Reordering for a project leaves a trace note")
    }
}
