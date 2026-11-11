import Foundation

extension ChatStore {
    var projectRepository: (any ProjectRepository)? { repository as? any ProjectRepository }

    func reloadProjects() {
        guard let projectRepository else { projects = []; return }
        do { projects = try projectRepository.listProjects() }
        catch { projectError = "Projects couldn't load: \(error.localizedDescription)" }
    }

    func clearProjectError() {
        projectError = nil
    }

    func project(_ id: String) -> ProjectRecord? {
        projects.first { $0.id == id }
    }

    func projectForConversation(_ conversationID: String) -> ProjectRecord? {
        conversations.first(where: { $0.id == conversationID })?.projectID.flatMap { project($0) }
    }

    @discardableResult
    func createProject(name: String) -> ProjectRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let projectRepository else { return nil }
        let now = Date()
        let record = ProjectRecord(id: UUID().uuidString.lowercased(), name: trimmed, instructions: "", grants: [], files: [],
                                   createdAt: now, updatedAt: now)
        do { try projectRepository.saveProject(record) }
        catch { projectError = "The project couldn't be created: \(error.localizedDescription)"; return nil }
        reloadProjects()
        return project(record.id)
    }

    @discardableResult
    private func updateProject(_ id: String, failure: String, _ change: (inout ProjectRecord) -> Void) -> Bool {
        guard let projectRepository, var record = project(id) else { return false }
        change(&record)
        var saved = true
        do { try projectRepository.saveProject(record) }
        catch { projectError = "\(failure): \(error.localizedDescription)"; saved = false }
        reloadProjects()
        return saved
    }

    @discardableResult
    func saveProjectEdits(_ id: String, name: String, instructions: String, grants: [FolderGrant]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { projectError = "Enter a project name."; return false }
        guard let projectRepository else { projectError = "Projects aren't available."; return false }
        do {
            let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            try NativePromptValidation.validateInstructions(text)
            guard var record = try projectRepository.project(id) else { throw ProjectStoreError.notFound }
            record.name = trimmed
            record.instructions = text
            record.grants = grants
            record.updatedAt = Date()
            try projectRepository.saveProject(record)
            projects.removeAll { $0.id == id }
            projects.insert(record, at: 0)
            projectError = nil
            refreshProjectGrants(id)
            return true
        } catch {
            projectError = "The project couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    func renameProject(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateProject(id, failure: "The new name couldn't save") { $0.name = trimmed }
    }

    func setProjectInstructions(_ id: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try NativePromptValidation.validateInstructions(trimmed) }
        catch { projectError = error.localizedDescription; return }
        updateProject(id, failure: "The project instructions couldn't save") { $0.instructions = trimmed }
    }

    func addProjectFolder(_ id: String, url: URL) {
        let grant: FolderGrant
        do { grant = try FolderGrant.make(url: url) }
        catch { projectError = error.localizedDescription; return }
        updateProject(id, failure: "The folder couldn't be added") { record in
            guard !record.grants.contains(where: { $0.path == grant.path }) else { return }
            record.grants.append(grant)
        }
        refreshProjectGrants(id)
    }

    @discardableResult
    func removeProjectFolder(_ id: String, grantID: String) -> Bool {
        let saved = updateProject(id, failure: "The folder couldn't be removed") { $0.grants.removeAll { $0.id == grantID } }
        refreshProjectGrants(id)
        return saved
    }

    func addProjectFile(_ id: String, url: URL) {
        guard let projectRepository else { return }
        do { _ = try projectRepository.addProjectFile(id, from: url) }
        catch { projectError = error.localizedDescription }
        reloadProjects()
        refreshProjectGrants(id)
    }

    func removeProjectFile(_ id: String, fileID: String) {
        guard let projectRepository else { return }
        do { try projectRepository.removeProjectFile(id, fileID: fileID) }
        catch { projectError = error.localizedDescription }
        reloadProjects()
        refreshProjectGrants(id)
    }

    func deleteProject(_ id: String) {
        guard let projectRepository else { return }
        let released: [String]
        do { released = try projectRepository.deleteProject(id) }
        catch { projectError = "The project couldn't be deleted: \(error.localizedDescription)"; return }
        for index in conversations.indices where released.contains(conversations[index].id) || conversations[index].projectID == id {
            conversations[index].projectID = nil
        }
        reloadProjects()
        removeRules(for: .project(id))
        for conversationID in released { refreshConversationGrants(conversationID) }
        syncRuleProjects()
    }

    func projectConversations(_ id: String) -> [Conversation] {
        conversations.filter { $0.projectID == id && !isVeraThread($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func projectTaskReferences(_ id: String) -> [NativeTaskReference] {
        let members = Set(projectConversations(id).map(\.id))
        return nativeTaskReferences.filter { members.contains($0.origin.conversationID) }
    }

    func projectArtifacts(_ id: String) -> [ArtifactRecord] {
        let members = Set(projectConversations(id).map(\.id))
        return artifactRecords.filter { $0.conversationID.map(members.contains) ?? false }
    }

    func moveConversation(_ conversationID: String, toProject projectID: String?) {
        guard !isVeraThread(conversationID), let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        if let projectID, project(projectID) == nil { return }
        if conversations[index].isPersisted {
            do { try projectRepository?.setConversationProject(conversationID, projectID: projectID) }
            catch {
                let message = "The chat couldn't be moved: \(error.localizedDescription)"
                projectError = message
                chatConfigurationError = message
                return
            }
        }
        conversations[index].projectID = projectID
        refreshConversationGrants(conversationID)
    }

    func newConversation(inProject projectID: String) {
        guard project(projectID) != nil else { return }
        stashDraftForProjectSwitch()
        section = .chat
        var convo = Conversation(id: UUID().uuidString, title: "New chat", messages: [], updatedAt: Date())
        convo.projectID = projectID
        conversations.insert(convo, at: 0)
        selectedID = convo.id
        draft = ""
        lastFocusedConversationID = selectedID
        refreshConversationGrants(convo.id)
        focusTick &+= 1
    }

    private func stashDraftForProjectSwitch() {
        guard let selectedID else { return }
        if draft.isEmpty { drafts.removeValue(forKey: selectedID) } else { drafts[selectedID] = draft }
    }

    func refreshProjectGrants(_ projectID: String) {
        for conversation in conversations where conversation.projectID == projectID {
            refreshConversationGrants(conversation.id)
        }
    }

    func refreshConversationGrants(_ conversationID: String) {
        nativeGrantSource.set(effectiveGrants(for: conversationID), for: conversationID)
        nativeRuleSource.setProject(conversations.first(where: { $0.id == conversationID })?.projectID, for: conversationID)
    }

    func effectiveGrants(for conversationID: String) -> [FolderGrant] {
        let own = conversations.first(where: { $0.id == conversationID })?.grants ?? []
        guard let record = projectForConversation(conversationID) else { return own }
        var combined = own
        for grant in record.grants where !combined.contains(where: { $0.path == grant.path }) { combined.append(grant) }
        if !record.files.isEmpty, let projectRepository {
            let directory = projectRepository.projectFilesDirectory(record.id)
            if let grant = try? FolderGrant.make(url: directory) {
                var readOnly = grant
                readOnly.readOnly = true
                readOnly.name = "\(record.name) files"
                combined.removeAll { $0.path == readOnly.path }
                combined.append(readOnly)
            }
        }
        return combined
    }
}
