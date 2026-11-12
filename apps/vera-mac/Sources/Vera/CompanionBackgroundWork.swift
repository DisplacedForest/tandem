import SwiftUI

struct CompanionBackgroundWork: Equatable, Sendable {
    var running = 0
    var needsAnswer = 0

    var isEmpty: Bool { running == 0 && needsAnswer == 0 }

    var runningLine: String? {
        switch running {
        case 0: return nil
        case 1: return "1 thing running in the background"
        default: return "\(running) things running in the background"
        }
    }

    var answerLine: String? {
        switch needsAnswer {
        case 0: return nil
        case 1: return "1 thing in the background needs your answer"
        default: return "\(needsAnswer) things in the background need your answer"
        }
    }
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
        let threadID = veraThreadID
        let owned = Set(schedules.filter { $0.owner == .dot }.map(\.id))
        let runs = scheduleRuns.values.flatMap { $0 }.filter { owned.contains($0.scheduleID) }
        let linked = Set(runs.compactMap { $0.taskReferenceID.flatMap(UUID.init(uuidString:)) })
        let references = nativeTaskReferences.filter {
            (threadID != nil && $0.origin.conversationID == threadID) || linked.contains($0.id)
        }
        let known = Set(references.map(\.id))
        for reference in references {
            guard let display = try? NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot) else { continue }
            if display.card.status == .needsInput {
                work.needsAnswer += 1
                waiting.append(.task(reference))
            } else if display.card.status == .working {
                work.running += 1
            }
        }
        for run in runs {
            if let id = run.taskReferenceID.flatMap(UUID.init(uuidString:)), known.contains(id) { continue }
            if run.outcome == .waiting {
                work.needsAnswer += 1
                waiting.append(.run(run))
            } else if run.outcome == .running {
                work.running += 1
            }
        }
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

struct CompanionBackgroundLines: View {
    let work: CompanionBackgroundWork
    var size: CGFloat = 12
    let onAnswer: () -> Void

    var body: some View {
        if !work.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let line = work.runningLine {
                    Text(line).font(.system(size: size)).foregroundStyle(Theme.warmTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line = work.answerLine {
                    Button(action: onAnswer) {
                        HStack(spacing: 4) {
                            Text(line).font(.system(size: size, weight: .medium))
                            Image(systemName: "chevron.right").font(.system(size: size - 3, weight: .semibold))
                        }
                        .foregroundStyle(Theme.sage)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(line)
                    .accessibilityHint("Shows the question")
                }
            }
        }
    }
}
