import SwiftUI

enum CompanionWorkKind: String, Equatable, Sendable {
    case researching, writing, changing

    var state: CompanionState {
        switch self {
        case .researching: return .researching
        case .writing: return .writing
        case .changing: return .changing
        }
    }
}

struct CompanionCurrentWork: Equatable, Sendable {
    var kind: CompanionWorkKind
    var words: String
    var more = 0

    var count: String? { more > 0 ? "and \(more) more" : nil }

    var line: String { count.map { "\(words) \($0)" } ?? words }

    static func words(workerType: String, phase: String?, title: String) -> String {
        let subject = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead: String
        switch workerType {
        case "research":
            switch phase {
            case "gather": lead = "Finding"
            case "rag": lead = "Checking"
            case "synthesize": lead = "Writing up"
            default: lead = "Researching"
            }
        case "document": lead = "Writing"
        default: lead = "Working on"
        }
        return subject.isEmpty ? lead : "\(lead) \(subject)"
    }

    static func kind(workerType: String, phase: String?) -> CompanionWorkKind {
        switch workerType {
        case "research": return phase == "synthesize" ? .writing : .researching
        case "document": return .writing
        default: return .changing
        }
    }
}

struct CompanionBackgroundWork: Equatable, Sendable {
    var running = 0
    var needsAnswer = 0
    var current: CompanionCurrentWork?

    var isEmpty: Bool { running == 0 && needsAnswer == 0 }
}

enum CompanionBackgroundTarget: Equatable {
    case task(NativeTaskReference)
    case run(NativeScheduleRun)

    static func == (lhs: CompanionBackgroundTarget, rhs: CompanionBackgroundTarget) -> Bool {
        switch (lhs, rhs) {
        case (.task(let a), .task(let b)): return a.id == b.id
        case (.run(let a), .run(let b)): return a.id == b.id
        default: return false
        }
    }
}

@MainActor
extension ChatStore {
    private var companionBackgroundSurvey: (work: CompanionBackgroundWork, waiting: [CompanionBackgroundTarget]) {
        var work = CompanionBackgroundWork()
        var waiting: [CompanionBackgroundTarget] = []
        var newest: (started: Date, order: Int)?
        func take(_ started: Date, _ order: Int, _ current: @autoclosure () -> CompanionCurrentWork) {
            if let newest, (newest.started, newest.order) > (started, order) { return }
            newest = (started, order)
            work.current = current()
        }
        let threadID = veraThreadID
        let owned = Set(schedules.filter { $0.owner == .dot }.map(\.id))
        let runs = scheduleRuns.values.flatMap { $0 }.filter { owned.contains($0.scheduleID) }
        let linked = Set(runs.compactMap { $0.taskReferenceID.flatMap(UUID.init(uuidString:)) })
        let runStart = Dictionary(runs.compactMap { run in
            run.taskReferenceID.flatMap(UUID.init(uuidString:)).map { ($0, run.startedAt ?? run.scheduledFor) }
        }, uniquingKeysWith: max)
        let references = nativeTaskReferences.filter {
            (threadID != nil && $0.origin.conversationID == threadID) || linked.contains($0.id)
        }
        let known = Set(references.map(\.id))
        let messages = conversations.first { $0.id == threadID }?.messages ?? []
        for (index, reference) in references.enumerated() {
            guard let display = try? NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot) else { continue }
            if display.card.status == .needsInput {
                work.needsAnswer += 1
                waiting.append(.task(reference))
            } else if display.card.status == .working {
                work.running += 1
                let started = messages.first { $0.id == reference.origin.userMessageID }?.createdAt
                    ?? runStart[reference.id] ?? .distantPast
                let type = reference.createRequest.workerType
                let phase = reference.snapshot?.checkpoint.phase
                take(started, index, CompanionCurrentWork(kind: CompanionCurrentWork.kind(workerType: type, phase: phase),
                                                          words: CompanionCurrentWork.words(workerType: type, phase: phase, title: display.card.title)))
            }
        }
        for (index, run) in runs.enumerated() {
            if let id = run.taskReferenceID.flatMap(UUID.init(uuidString:)), known.contains(id) { continue }
            if run.outcome == .waiting {
                work.needsAnswer += 1
                waiting.append(.run(run))
            } else if run.outcome == .running {
                work.running += 1
                let title = schedules.first { $0.id == run.scheduleID }?.title ?? ""
                take(run.startedAt ?? run.scheduledFor, references.count + index,
                     CompanionCurrentWork(kind: .changing, words: CompanionCurrentWork.words(workerType: "", phase: nil, title: title)))
            }
        }
        let more = max(0, work.running - 1)
        work.current?.more = more
        return (work, waiting)
    }

    var companionBackgroundWork: CompanionBackgroundWork { companionBackgroundSurvey.work }

    var companionBackgroundWaiting: CompanionBackgroundTarget? { companionBackgroundSurvey.waiting.first }

    func revealCompanionBackgroundWaiting() {
        switch companionBackgroundWaiting {
        case .task(let reference): revealOngoingWork(reference)
        case .run(let run): openScheduleRun(run)
        case nil: return
        }
    }
}

struct CompanionWorkingLine: View {
    let work: CompanionCurrentWork?
    var size: CGFloat = 13

    var body: some View {
        if let work {
            HStack(spacing: 8) {
                CompanionAvatar(size: size + 9)
                Text(work.words).font(.system(size: size)).foregroundStyle(Theme.warmTextSecondary)
                    .lineLimit(1).truncationMode(.tail)
                if let count = work.count {
                    Text(count).font(.system(size: size)).foregroundStyle(Theme.warmTextSecondary)
                        .lineLimit(1).fixedSize().layoutPriority(1).padding(.leading, -4)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(work.line)
        }
    }
}
