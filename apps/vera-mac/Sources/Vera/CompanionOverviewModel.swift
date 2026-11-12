import Foundation

struct CompanionActivityItem: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case task(UUID)
        case run(String)
    }

    let id: String
    let title: String
    let state: String
    let status: NativeTaskCardPresentation.Status
    let isDocument: Bool
    let hasArtifact: Bool
    let decision: NativeTaskDecision?
    let date: Date
    let source: Source
    let canOpen: Bool
    let canStop: Bool

    var needsDecision: Bool { status == .needsInput }
    var isOpen: Bool { ![.completed, .failed, .stopped].contains(status) }
    var canRetry: Bool { decision?.choices.contains("retry") == true && taskID != nil }
    var taskID: UUID? {
        if case .task(let id) = source { return id }
        return nil
    }
}

struct CompanionOverviewResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: ArtifactKind
    let updatedAt: Date
}

struct CompanionOverviewModel: Equatable, Sendable {
    static let activityPreview = 5
    static let outputPreview = 4

    var name: String
    var mention: String { name == CompanionSubject(nil).leading ? CompanionSubject(nil).inline : name }
    var services: String
    var rules: String
    var paused: Bool
    var activity: [CompanionActivityItem]
    var outputs: [CompanionOverviewResult]

    static let noTaskRules = "No task rules yet."
    static let selectWorkHint = "Select a row in Recent activity to see which task these rules would cover."
    static let noActivity = "Nothing yet. Research, documents and scheduled work show up here as they happen."
    static let noOutputs = "Documents and other results collect here."
    static let thisMac = "This Mac"
    static let stopTitle = "Stop this task"

    static func pauseTitle(name: String, paused: Bool) -> String { paused ? "Resume \(name)" : "Pause \(name)" }

    static func servicesLine(options: [NativeDotServiceOption], selected: Set<String>) -> String {
        let names = options.filter { selected.contains($0.id) }.map(\.name)
        guard !names.isEmpty else { return options.isEmpty ? "No services turned on yet." : "No services connected." }
        if names.count == options.count { return "Can reach every service that is turned on." }
        let shown = names.prefix(3).joined(separator: ", ")
        let rest = names.count - min(names.count, 3)
        return rest > 0 ? "Can reach \(shown) and \(rest) more." : "Can reach \(shown)."
    }

    static func taskItem(card: NativeTaskCardPresentation, reference: NativeTaskReference, decision: NativeTaskDecision?,
                         hasArtifact: Bool, date: Date) -> CompanionActivityItem {
        let document = card.workerType == "document"
        let state = card.listState(card.status == .completed ? (hasArtifact ? "Ready to open" : card.statusTitle) : card.status.title(document: document))
        return CompanionActivityItem(id: reference.id.uuidString, title: card.title, state: state, status: card.status,
                                     isDocument: document, hasArtifact: hasArtifact, decision: decision, date: date, source: .task(reference.id),
                                     canOpen: true, canStop: card.canCancel)
    }

    static func runStatus(_ outcome: NativeScheduleOutcome) -> NativeTaskCardPresentation.Status {
        switch outcome {
        case .running: return .working
        case .waiting: return .needsInput
        case .blocked: return .queued
        case .completed: return .completed
        case .failed, .couldNotStart: return .failed
        case .stopped, .missed, .skipped: return .stopped
        }
    }

    static func runItem(_ run: NativeScheduleRun, schedule: NativeSchedule) -> CompanionActivityItem {
        CompanionActivityItem(id: "run:" + run.id, title: schedule.title, state: run.outcome.title, status: runStatus(run.outcome),
                              isDocument: schedule.isDocument, hasArtifact: false, decision: nil,
                              date: run.finishedAt ?? run.startedAt ?? run.scheduledFor, source: .run(run.id),
                              canOpen: run.conversationID != nil, canStop: run.outcome.isOpen && run.taskReferenceID != nil)
    }

    static func activity(tasks: [CompanionActivityItem], runs: [NativeScheduleRun], schedules: [NativeSchedule]) -> [CompanionActivityItem] {
        let taskIDs = Set(tasks.map(\.id))
        let owned = Dictionary(schedules.filter { $0.owner == .dot }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let runItems = runs.compactMap { run -> CompanionActivityItem? in
            guard let schedule = owned[run.scheduleID] else { return nil }
            if let reference = run.taskReferenceID, taskIDs.contains(reference.uppercased()) || taskIDs.contains(reference) { return nil }
            return runItem(run, schedule: schedule)
        }
        return (tasks + runItems).sorted { $0.date > $1.date }
    }

    static func result(_ record: ArtifactRecord) -> CompanionOverviewResult {
        CompanionOverviewResult(id: record.id, title: record.title, kind: record.kind, updatedAt: record.updatedAt)
    }

    static func build(name: String, profile: NativeDotProfile, services: String, rules: String,
                      activity: [CompanionActivityItem], results: [CompanionOverviewResult]) -> CompanionOverviewModel {
        CompanionOverviewModel(name: name, services: services, rules: rules, paused: profile.isPaused,
                               activity: activity, outputs: results.sorted { $0.updatedAt > $1.updatedAt })
    }

    func selected(_ id: String?) -> CompanionActivityItem? {
        guard let id else { return nil }
        return activity.first { $0.id == id }
    }

    func rulesTitle(selected id: String?) -> String? { selected(id)?.title }

    var needsYouCount: Int { activity.filter(\.needsDecision).count }
}

struct CompanionActivityDetail: Equatable, Sendable {
    let request: String?
    let outcome: String?
    let canOpen: Bool

    init(request: String?, outcome: String?, canOpen: Bool) {
        self.request = request.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.outcome = outcome.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.canOpen = canOpen
    }
}
