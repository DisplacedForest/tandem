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

    func openCompanionActivity(_ item: CompanionActivityItem) {
        switch item.source {
        case .task:
            openVeraThread()
        case .run(let runID):
            if let run = scheduleRuns.values.flatMap({ $0 }).first(where: { $0.id == runID }) { openScheduleRun(run) }
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
