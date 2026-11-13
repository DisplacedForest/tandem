import Foundation

extension ChatStore {
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

    func companionHandOff(said typed: String = "") -> @Sendable (String) async throws -> NativeResearchTaskRequest {
        let said = typed.unicodeScalars.count <= NativeCompanionTaskPayload.saidLimit ? typed : ""
        return { [weak self] assignment in
            let live: (paused: Bool, connected: [String]?)? = await MainActor.run { [weak self] in
                self.map { ($0.dotProfile.isPaused, $0.dotProfile.connectedToolIDs?.sorted()) }
            }
            guard let live else { throw NativeTaskTools.NotStarted(message: NativeTaskTools.notStarted) }
            guard !live.paused else { throw NativeTaskTools.NotStarted(message: NativeTaskTools.pausedReply) }
            return try ChatStore.companionRequest(assignment, connectedToolIDs: live.connected, said: said)
        }
    }

    nonisolated static func companionRequest(_ assignment: String, connectedToolIDs: [String]?, said: String? = nil,
                                             carried: NativeCompanionCarried? = nil) throws -> NativeResearchTaskRequest {
        try NativeResearchTaskRequest(dot: NativeCompanionTaskPayload(assignment: assignment, mode: "manual", connectedToolIDs: connectedToolIDs, said: said,
                                                                      carried: carried))
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
