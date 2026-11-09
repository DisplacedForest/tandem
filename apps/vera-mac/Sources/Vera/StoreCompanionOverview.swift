import Foundation

extension ChatStore {
    var companionRulesSummary: String {
        NativeDotContext.headerSummary(resolver: ruleResolver(for: veraThreadID ?? "", requestText: ""))
    }

    func companionOverviewModel() -> CompanionOverviewModel {
        let threadID = veraThreadID
        let projection = repository as? any NativeTaskProjectionRepository
        var tasks: [CompanionActivityItem] = []
        for reference in nativeTaskReferences where reference.origin.conversationID == threadID {
            let saved = try? projection?.taskProjection(id: reference.id)
            let snapshot = saved?.snapshot ?? reference.snapshot
            guard let display = try? NativeTaskProjection.display(reference: reference, snapshot: snapshot,
                                                                   connectionNote: saved?.connectionNote) else { continue }
            let date = snapshot.map { Date(timeIntervalSince1970: $0.updatedAt) }
                ?? conversations.first { $0.id == threadID }?.messages.first { $0.id == reference.origin.assistantMessageID }?.createdAt
                ?? .distantPast
            tasks.append(CompanionOverviewModel.taskItem(card: display.card, reference: reference, decision: snapshot?.decision,
                                                         hasArtifact: display.artifact != nil, date: date))
        }
        let runs = scheduleRuns.values.flatMap { $0 }
        let activity = CompanionOverviewModel.activity(tasks: tasks, runs: runs, schedules: schedules)
        let results = artifactRecords.filter { $0.conversationID == threadID }.map(CompanionOverviewModel.result)
        let options = dotServiceOptions()
        return CompanionOverviewModel.build(
            name: assistantName, profile: dotProfile,
            services: CompanionOverviewModel.servicesLine(options: options, selected: dotSelectedServices(options)),
            rules: companionRulesSummary, activity: activity, results: results)
    }

    func refreshCompanionOverview() {
        reloadSchedules()
        reloadArtifacts()
        reloadNativeTaskReferences()
    }

    func stopCompanionWork(_ item: CompanionActivityItem) {
        switch item.source {
        case .task(let id): cancelNativeTask(id.uuidString)
        case .run(let runID):
            if let run = scheduleRuns.values.flatMap({ $0 }).first(where: { $0.id == runID }) { stopScheduleRun(run) }
        }
    }

    func retryCompanionWork(_ item: CompanionActivityItem) {
        if case .task(let id) = item.source { retryNativeTask(id.uuidString) }
    }

    func companionActivityDetail(_ item: CompanionActivityItem) -> CompanionActivityDetail {
        switch item.source {
        case .task(let id):
            guard let reference = nativeTaskReferences.first(where: { $0.id == id }) else {
                return CompanionActivityDetail(request: nil, outcome: nil, canOpen: false)
            }
            let projection = repository as? any NativeTaskProjectionRepository
            let saved = try? projection?.taskProjection(id: id)
            let snapshot = saved?.snapshot ?? reference.snapshot
            let conversation = companionActivityConversation(reference.origin.conversationID)
            let request = conversation?.messages.first { $0.id == reference.origin.userMessageID }?.text
            let display = try? NativeTaskProjection.display(reference: reference, snapshot: snapshot,
                                                           connectionNote: saved?.connectionNote)
            let outcome = display?.artifact?.report ?? display?.card.answer ?? display?.card.milestone
            return CompanionActivityDetail(request: request ?? reference.request.objective, outcome: outcome,
                                           canOpen: conversation != nil)
        case .run(let id):
            guard let run = scheduleRuns.values.flatMap({ $0 }).first(where: { $0.id == id }) else {
                return CompanionActivityDetail(request: nil, outcome: nil, canOpen: false)
            }
            let reference = nativeTaskReferences.first { $0.id.uuidString.lowercased() == run.taskReferenceID?.lowercased() }
            return CompanionActivityDetail(request: reference?.request.objective, outcome: run.detail,
                                           canOpen: run.conversationID.flatMap(companionActivityConversation) != nil)
        }
    }

    private func companionActivityConversation(_ id: String) -> Conversation? {
        conversations.first { $0.id == id } ?? (try? repository?.listConversations().first { $0.id == id })
    }

    @discardableResult
    func openCompanionActivity(_ item: CompanionActivityItem) -> Bool {
        switch item.source {
        case .task(let id):
            guard let reference = nativeTaskReferences.first(where: { $0.id == id }),
                  let conversation = companionActivityConversation(reference.origin.conversationID) else { return false }
            if !conversations.contains(where: { $0.id == conversation.id }) { conversations.insert(conversation, at: 0) }
            revealOngoingWork(reference)
            return true
        case .run(let runID):
            guard let run = scheduleRuns.values.flatMap({ $0 }).first(where: { $0.id == runID }),
                  let id = run.conversationID, companionActivityConversation(id) != nil else { return false }
            openScheduleRun(run)
            return selectedID == id
        }
    }

    func openCompanionResult(_ id: String) {
        guard let record = artifactRecords.first(where: { $0.id == id }) else { return }
        requestedArtifactID = record.id
        section = .artifacts
    }

    func openCompanionOutputs() {
        pendingLibraryConversationID = veraThreadID
        section = .artifacts
    }
}
