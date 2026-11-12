import SwiftUI

struct NativeTaskPause: Codable, Hashable, Sendable {
    var pages: [PulseSource] = []
    var more = 0
    var earlier: String? = nil
    var answer: String? = nil
    var found: Bool? = nil
    var decisionID: String? = nil

    var heading: String? {
        pages.isEmpty ? nil : found == true ? PausedWorkCopy.foundHeading : PausedWorkCopy.readHeading
    }
}

extension NativeTaskSource {
    var label: String {
        let shown = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shown.isEmpty || shown == address || Self.webHost(shown) != nil else { return shown }
        guard let host = Self.webHost(address) ?? Self.webHost(shown) else { return "Saved page" }
        return host
    }

    static func webHost(_ text: String) -> String? {
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty else { return nil }
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }
}

enum PausedWorkCopy {
    static let choices: Set<String> = ["continue", "finish"]
    static let shownLimit = 6
    static let question = " paused with the work saved. Keep going, or finish with what's been found so far?"
    static let readHeading = "Read so far"
    static let foundHeading = "Found so far"
    static let nothingRead = "No pages have been read yet."
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

    static func pause(_ checkpoint: NativeTaskCheckpoint, answer: String?, decisionID: String? = nil) -> NativeTaskPause {
        func listable(_ sources: [NativeTaskSource]) -> [PulseSource] {
            var seen = Set<Int>()
            var listed: [PulseSource] = []
            for source in sources {
                guard !seen.contains(source.n), source.title.unicodeScalars.count <= 200,
                      source.url.unicodeScalars.count <= 1024 else { continue }
                seen.insert(source.n)
                listed.append(PulseSource(n: source.n, title: source.label,
                                          url: NativeResearchReportSafety.destination(source.url)?.absoluteString ?? "local"))
            }
            return listed
        }
        let read = listable(checkpoint.sources.filter { $0.read == true })
        let unknown = read.isEmpty ? listable(checkpoint.sources.filter { $0.read == nil }) : []
        let pages = read.isEmpty ? unknown : read
        return NativeTaskPause(pages: Array(pages.prefix(shownLimit)), more: max(0, pages.count - shownLimit),
                               earlier: NativeCompanionWorker.earlierLine(effects: checkpoint.effects),
                               answer: answered(answer) == nil ? nil : answer,
                               found: read.isEmpty && !unknown.isEmpty ? true : nil, decisionID: decisionID)
    }

    static func lines(_ pause: NativeTaskPause, name: String?) -> [String] {
        if let done = answered(pause.answer) { return [done] }
        var result = [line.plain(name: name)]
        if let heading = pause.heading {
            result.append(heading)
            result += pause.pages.map(\.title)
            if pause.more > 0 { result.append(more(pause.more)) }
        } else {
            result.append(nothingRead)
        }
        if let earlier = pause.earlier, !earlier.isEmpty { result.append(earlier) }
        return result
    }

    static func strings(name: String?) -> [String] {
        [line.plain(name: name), readHeading, foundHeading, nothingRead, finishing, keepingGoing, more(3)]
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
                if let heading = pause.heading {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(heading)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(secondary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(pause.pages) { SourceListRow(source: $0, numbered: false) }
                        if pause.more > 0 {
                            Text(PausedWorkCopy.more(pause.more))
                                .font(.system(size: 12))
                                .foregroundStyle(secondary)
                        }
                    }
                } else {
                    Text(PausedWorkCopy.nothingRead)
                        .font(.system(size: 12))
                        .foregroundStyle(secondary)
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
