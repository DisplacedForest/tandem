import Foundation

@MainActor
enum ProjectShotFixture {
    static func store(variant: String) -> (store: ChatStore, selection: String?) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandem-project-shot-\(UUID().uuidString.lowercased())", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        for directory in [artifacts, projects, sources] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let repository = try? LocalChatRepository(inMemory: true, artifactDirectory: artifacts, projectsDirectory: projects) else {
            return (ChatStore(), nil)
        }
        let store = ChatStore(
            nativeConfig: nil, nativeTransport: nil, repository: repository,
            attachmentStore: NativeAttachmentStore(directory: artifacts),
            artifactPersistenceEnabled: false)
        store.section = .projects
        guard variant != "projects-empty" else {
            store.reloadProjects()
            store.reloadArtifacts()
            return (store, nil)
        }

        let now = Date()
        let day: TimeInterval = 86_400
        let project = ProjectRecord(
            id: "shot-project-garden", name: "Spring garden",
            instructions: "Plan for a small backyard plot in a cool climate. Prefer low effort perennials, keep budgets under $300, and flag anything that needs frost protection.",
            grants: [FolderGrant(path: "~/Documents/Garden", name: "Garden")],
            files: [], createdAt: now.addingTimeInterval(-12 * day), updatedAt: now)
        let other = ProjectRecord(
            id: "shot-project-kitchen", name: "Kitchen remodel", instructions: "", grants: [], files: [],
            createdAt: now.addingTimeInterval(-40 * day), updatedAt: now.addingTimeInterval(-6 * day))
        try? repository.saveProject(other)
        try? repository.saveProject(project)

        let seedList = sources.appendingPathComponent("Seed inventory.csv")
        let soil = sources.appendingPathComponent("Soil test results.pdf")
        try? Data(String(repeating: "tomato,peppers,basil,leeks\n", count: 140).utf8).write(to: seedList)
        try? Data(count: 248_000).write(to: soil)
        _ = try? repository.addProjectFile(project.id, from: seedList)
        _ = try? repository.addProjectFile(project.id, from: soil)

        var beds = Conversation(id: "shot-project-beds", title: "Raised bed layout", messages: [], updatedAt: now.addingTimeInterval(-3_600))
        beds.projectID = project.id
        var watering = Conversation(id: "shot-project-water", title: "Drip irrigation timer", messages: [],
                                    updatedAt: now.addingTimeInterval(-2 * day))
        watering.projectID = project.id
        var cabinets = Conversation(id: "shot-project-cabinets", title: "Cabinet finishes", messages: [],
                                    updatedAt: now.addingTimeInterval(-6 * day))
        cabinets.projectID = other.id
        for conversation in [beds, watering, cabinets] {
            try? repository.saveConversation(conversation)
            try? repository.setConversationProject(conversation.id, projectID: conversation.projectID)
        }
        store.conversations = [beds, watering, cabinets]

        _ = try? repository.recordArtifact(ArtifactDraft(
            kind: .document, title: "Planting calendar", conversationID: beds.id, originTitle: beds.title, messageID: nil,
            sourceKey: "shot:project:doc", data: Data("# Planting calendar\n\nStart tomatoes indoors in March.".utf8),
            mime: "text/markdown", fileExtension: "md", details: ArtifactDetails()), revising: nil)

        store.reloadProjects()
        store.reloadArtifacts()
        return (store, project.id)
    }
}
