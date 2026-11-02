import Foundation

final class ProjectContextMemoryService: NativeMemoryServing, @unchecked Sendable {
    private let lock = NSLock()
    private var down = false

    var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return down }
        set { lock.lock(); down = newValue; lock.unlock() }
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

        try await checkProposalTagging(store, service: service, chat: chat, projectID: project.id)

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
        print("  project context OK (instructions, folders, files grant, move out and back, delete keeps chats and artifacts, proposal tagging, queued replay, recall preference)")
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
