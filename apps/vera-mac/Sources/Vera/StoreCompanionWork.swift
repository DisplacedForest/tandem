import Foundation

extension ChatStore {
    static let companionAssignmentLimit = 4000

    func companionWorkReferences() -> [NativeTaskReference] {
        nativeTaskReferences.filter { $0.createRequest.workerType == "companion" }
    }

    func companionWorkInProgress() -> Bool {
        companionWorkReferences().contains { reference in
            guard !reference.cancelRequested else { return false }
            let projection = try? (nativeTaskRepository as? any NativeTaskProjectionRepository)?.taskProjection(id: reference.id)
            guard let saved = projection ?? nil, let state = saved.snapshot?.state else { return true }
            return !state.isTerminal
        }
    }

    @discardableResult
    func startCompanionAssignment(_ text: String) async -> String? {
        let assignment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assignment.isEmpty else { return "Describe what \(assistantName) should work on." }
        guard assignment.count <= Self.companionAssignmentLimit else { return "Keep the assignment under \(Self.companionAssignmentLimit) characters." }
        guard !dotProfile.isPaused else { return "\(assistantName) is paused. Resume to give it work." }
        guard let repository, let service = nativeTaskService, nativeTaskEngine.base != nil else {
            return "Background work isn't available right now."
        }
        guard let nativeConfig = currentNativeConfig else { return "No model is set up. Add one in Settings." }
        let profile = nativeTaskEnrollment ?? (try? nativeTaskConfiguration?.enroll(config: nativeConfig))
        if nativeTaskConfiguration != nil && profile == nil { return "The model profile couldn't be prepared." }
        let request: NativeResearchTaskRequest
        do {
            let payload = try NativeCompanionTaskPayload(assignment: assignment, mode: "manual", goal: dotProfile.goal,
                                                        connectedToolIDs: dotProfile.connectedToolIDs?.sorted())
            request = try NativeResearchTaskRequest(dot: payload)
        } catch {
            return error.localizedDescription
        }
        ensureVeraThread()
        guard let conversationID = veraThreadID else { return "\(assistantName)'s conversation couldn't be opened." }
        let user = Message(role: .user, text: assignment)
        let reply = Message(role: .assistant, text: "", state: .complete, modelID: nativeConfig.model)
        do {
            let ordinal = try repository.messages(conversationID: conversationID).count
            try repository.saveMessage(user, conversationID: conversationID, ordinal: ordinal)
            try repository.saveMessage(reply, conversationID: conversationID, ordinal: ordinal + 1)
        } catch {
            return "The assignment couldn't be saved: \(error.localizedDescription)"
        }
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            if !conversations[index].messages.isEmpty || selectedID == conversationID {
                conversations[index].messages.append(contentsOf: [user, reply])
            }
            conversations[index].updatedAt = Date()
            conversations[index].isPersisted = true
            try? repository.saveConversation(conversations[index])
        }
        let origin = NativeTaskOrigin(conversationID: conversationID, userMessageID: user.id, assistantMessageID: reply.id)
        do {
            let reference = try await service.submit(origin: origin, request: request, profile: profile)
            reloadNativeTaskReferences()
            if reference.deliveryState == NativeTaskDeliveryState.rejected {
                return reference.lastDeliveryError ?? "\(assistantName) couldn't start this work."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func cancelCompanionWork() {
        for reference in companionWorkReferences() where !reference.cancelRequested {
            if let engine = nativeTaskLocalEngine, let remote = reference.remoteTaskID { _ = try? engine.store.cancel(remote) }
            cancelNativeTask(reference.id.uuidString)
        }
    }
}
