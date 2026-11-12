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

    var line: String { more > 0 ? "\(words) and \(more) more" : words }

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
        var newest = -Double.infinity
        let threadID = veraThreadID
        let owned = Set(schedules.filter { $0.owner == .dot }.map(\.id))
        let runs = scheduleRuns.values.flatMap { $0 }.filter { owned.contains($0.scheduleID) }
        let linked = Set(runs.compactMap { $0.taskReferenceID.flatMap(UUID.init(uuidString:)) })
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
                let started = messages.first { $0.id == reference.origin.userMessageID }?.createdAt.timeIntervalSince1970 ?? Double(index)
                if started >= newest {
                    newest = started
                    let type = reference.createRequest.workerType
                    let phase = reference.snapshot?.checkpoint.phase
                    work.current = CompanionCurrentWork(kind: CompanionCurrentWork.kind(workerType: type, phase: phase),
                                                        words: CompanionCurrentWork.words(workerType: type, phase: phase, title: display.card.title))
                }
            }
        }
        for run in runs {
            if let id = run.taskReferenceID.flatMap(UUID.init(uuidString:)), known.contains(id) { continue }
            if run.outcome == .waiting {
                work.needsAnswer += 1
                waiting.append(.run(run))
            } else if run.outcome == .running {
                work.running += 1
                if work.current == nil {
                    let title = schedules.first { $0.id == run.scheduleID }?.title ?? ""
                    work.current = CompanionCurrentWork(kind: .changing, words: CompanionCurrentWork.words(workerType: "", phase: nil, title: title))
                }
            }
        }
        work.current?.more = max(0, work.running - 1)
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
                Text(work.line).font(.system(size: size)).foregroundStyle(Theme.warmTextSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(work.line)
        }
    }
}
