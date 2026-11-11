import Foundation

enum CompanionWorkCopy {
    static let describe = "Describe what {name} should work on."
    static let paused = "{name} is paused. Resume to give it work."
    static let conversation = "{name}'s conversation couldn't be opened."
    static let couldNotStart = "{name} couldn't start this work."
}

extension ChatStore {
    static let companionAssignmentLimit = 4000

    func companionWorkReferences() -> [NativeTaskReference] {
        nativeTaskReferences.filter { $0.createRequest.workerType == "companion" }
    }

    var companionWorkReferencesAwaitingApproval: [NativeTaskReference] {
        guard let veraThreadID else { return [] }
        return companionWorkReferences().filter { reference in
            guard reference.origin.conversationID == veraThreadID, let snapshot = reference.snapshot,
                  snapshot.state == .needsDecision, let decision = snapshot.decision else { return false }
            return decision.choices.contains(NativeCardChoiceKind.allowOnce.rawValue)
                && decision.choices.contains(NativeCardChoiceKind.decline.rawValue)
        }
    }

    var companionWorkAwaitingApproval: NativeTaskReference? { companionWorkReferencesAwaitingApproval.first }

    var companionApprovalWaiting: Bool { companionAwaitingApproval || companionWorkAwaitingApproval != nil }

    var companionChatApprovalMessageID: UUID? {
        guard let veraThreadID else { return nil }
        return conversationTurns.first { $0.conversationID == veraThreadID && turnConfirmations[$0.assistantMessageID] != nil }?
            .assistantMessageID
    }

    func revealCompanionApproval() {
        if let messageID = companionChatApprovalMessageID {
            pendingSourceNotice = nil
            pendingHighlightMessageID = messageID
            return
        }
        let waiting = companionWorkReferencesAwaitingApproval
        guard let reference = waiting.first(where: { $0.id.uuidString == pendingTaskReveal }) ?? waiting.first else { return }
        if let decisionID = reference.snapshot?.decision?.id { revealedCompanionWorkDecisionIDs.insert(decisionID) }
        revealOngoingWork(reference)
    }

    func revealWaitingCompanionWorkOnce() {
        guard !companionAwaitingApproval else { return }
        let waiting = companionWorkReferencesAwaitingApproval
        revealedCompanionWorkDecisionIDs.formIntersection(waiting.compactMap { $0.snapshot?.decision?.id })
        guard let reference = waiting.first(where: { reference in
            guard let decisionID = reference.snapshot?.decision?.id else { return false }
            return !revealedCompanionWorkDecisionIDs.contains(decisionID)
        }), let decisionID = reference.snapshot?.decision?.id else { return }
        revealedCompanionWorkDecisionIDs.insert(decisionID)
        taskRevealGeneration &+= 1
        pendingTaskReveal = reference.id.uuidString
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
    func startCompanionAssignment(_ text: String) async -> CompanionLine? {
        let assignment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assignment.isEmpty else { return .named(CompanionWorkCopy.describe) }
        guard assignment.count <= Self.companionAssignmentLimit else { return .literal("Keep the assignment under \(Self.companionAssignmentLimit) characters.") }
        guard !dotProfile.isPaused else { return .named(CompanionWorkCopy.paused) }
        guard let repository, let service = nativeTaskService, nativeTaskEngine.base != nil else {
            return .literal("Background work isn't available right now.")
        }
        guard let nativeConfig = currentNativeConfig else { return .literal("No model is set up. Add one in Settings.") }
        let profile = nativeTaskEnrollment ?? (try? nativeTaskConfiguration?.enroll(config: nativeConfig))
        if nativeTaskConfiguration != nil && profile == nil { return .literal("The model profile couldn't be prepared.") }
        let request: NativeResearchTaskRequest
        do {
            let payload = try NativeCompanionTaskPayload(assignment: assignment, mode: "manual", goal: dotProfile.goal,
                                                        connectedToolIDs: dotProfile.connectedToolIDs?.sorted())
            request = try NativeResearchTaskRequest(dot: payload)
        } catch {
            return .literal(error.localizedDescription)
        }
        ensureVeraThread()
        guard let conversationID = veraThreadID else { return .named(CompanionWorkCopy.conversation) }
        let user = Message(role: .user, text: assignment)
        let reply = Message(role: .assistant, text: "", state: .complete, modelID: nativeConfig.model)
        do {
            let ordinal = try repository.messages(conversationID: conversationID).count
            try repository.saveMessage(user, conversationID: conversationID, ordinal: ordinal)
            try repository.saveMessage(reply, conversationID: conversationID, ordinal: ordinal + 1)
        } catch {
            return .literal("The assignment couldn't be saved: \(error.localizedDescription)")
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
                return reference.lastDeliveryError.map(CompanionLine.literal) ?? .named(CompanionWorkCopy.couldNotStart)
            }
            return nil
        } catch {
            return .literal(error.localizedDescription)
        }
    }

    func cancelCompanionWork() {
        let stored = (try? nativeTaskRepository?.taskReferences(conversationID: nil)) ?? nil
        let references = (stored ?? nativeTaskReferences).filter { $0.createRequest.workerType == "companion" }
        for reference in references where !reference.cancelRequested {
            if let engine = nativeTaskLocalEngine, let remote = reference.remoteTaskID { _ = try? engine.store.cancel(remote) }
            cancelNativeTask(reference.id.uuidString)
        }
    }
}
