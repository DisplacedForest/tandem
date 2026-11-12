import SwiftUI

struct NativeTaskPause: Codable, Hashable, Sendable {
    var read: [PulseSource] = []
    var more = 0
    var earlier: String? = nil
    var answer: String? = nil
}

enum PausedWorkCopy {
    static let choices: Set<String> = ["continue", "finish"]
    static let shownLimit = 6
    static let question = " paused with the work saved. Keep going, or finish with what's been found so far?"
    static let readHeading = "Read so far"
    static let nothingFound = "Nothing useful has been found yet."
    static let finishing = "Finishing with what's been found."
    static let keepingGoing = "Keeping going."

    static var line: CompanionLine { .parts([.name, .text(question)]) }
    static var savedMilestone: String { CompanionSavedText.marker + question }

    static func more(_ count: Int) -> String { "and \(count) more" }

    static func applies(_ snapshot: NativeTaskSnapshot) -> Bool {
        guard snapshot.state == .needsDecision, snapshot.checkpoint.pending?.kind == "cap",
              let offered = snapshot.decision?.choices else { return false }
        return offered.count == choices.count && Set(offered) == choices
    }

    static func answered(_ choice: String?) -> String? {
        switch choice {
        case "finish": return finishing
        case "continue": return keepingGoing
        default: return nil
        }
    }

    static func pause(_ checkpoint: NativeTaskCheckpoint, answer: String?) -> NativeTaskPause {
        var seen = Set<Int>()
        var read: [PulseSource] = []
        for source in checkpoint.sources where source.read == true {
            guard !seen.contains(source.n), source.title.unicodeScalars.count <= 200,
                  source.url.unicodeScalars.count <= 1024 else { continue }
            seen.insert(source.n)
            let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            read.append(PulseSource(n: source.n, title: title.isEmpty ? "Saved reference" : title,
                                    url: NativeResearchReportSafety.destination(source.url)?.absoluteString ?? "local"))
        }
        return NativeTaskPause(read: Array(read.prefix(shownLimit)), more: max(0, read.count - shownLimit),
                               earlier: NativeCompanionWorker.earlierLine(effects: checkpoint.effects),
                               answer: answered(answer) == nil ? nil : answer)
    }

    static func lines(_ pause: NativeTaskPause, name: String?) -> [String] {
        if let done = answered(pause.answer) { return [done] }
        var result = [line.plain(name: name)]
        if pause.read.isEmpty {
            result.append(nothingFound)
        } else {
            result.append(readHeading)
            result += pause.read.map(\.title)
            if pause.more > 0 { result.append(more(pause.more)) }
        }
        if let earlier = pause.earlier, !earlier.isEmpty { result.append(earlier) }
        return result
    }

    static func strings(name: String?) -> [String] {
        [line.plain(name: name), readHeading, nothingFound, finishing, keepingGoing, more(3)]
            + ["continue", "finish"].compactMap(NativeTaskCardPresentation.choiceTitle)
    }
}

extension NativeTaskCardPresentation {
    var pausedWork: NativeTaskPause? { isCompanion && status == .needsInput ? pause : nil }
}

struct PausedWorkView: View {
    let pause: NativeTaskPause
    var primary = Theme.textPrimary
    var secondary = Theme.textSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let done = PausedWorkCopy.answered(pause.answer) {
                Text(done)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                CompanionLineText(line: PausedWorkCopy.line)
                    .font(.system(size: 13))
                    .foregroundStyle(primary)
                    .fixedSize(horizontal: false, vertical: true)
                if pause.read.isEmpty {
                    Text(PausedWorkCopy.nothingFound)
                        .font(.system(size: 12))
                        .foregroundStyle(secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(PausedWorkCopy.readHeading)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(secondary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(pause.read) { SourceListRow(source: $0, numbered: false) }
                        if pause.more > 0 {
                            Text(PausedWorkCopy.more(pause.more))
                                .font(.system(size: 12))
                                .foregroundStyle(secondary)
                        }
                    }
                }
                if let earlier = pause.earlier, !earlier.isEmpty {
                    Text(verbatim: earlier)
                        .font(.system(size: 12))
                        .foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
