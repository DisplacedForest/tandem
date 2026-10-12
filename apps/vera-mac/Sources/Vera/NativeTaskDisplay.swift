import Foundation

struct NativeMessageEnvelope: Codable, Hashable, Sendable {
    var spokenText: String
    var displayBlocks: [NativeDisplayBlock]

    private enum CodingKeys: String, CodingKey {
        case spokenText = "spoken_text"
        case displayBlocks = "display_blocks"
    }

    var speechInput: String { NativeSpokenText.clean(spokenText) }

    mutating func reconcile(card: NativeTaskCardPresentation, artifact: NativeResearchArtifact?) {
        if let index = displayBlocks.firstIndex(where: { $0.id == "task:" + card.id }) {
            displayBlocks[index] = .taskCard(card)
        } else {
            displayBlocks.append(.taskCard(card))
        }
        if let artifact {
            if let index = displayBlocks.firstIndex(where: { $0.id == "artifact:" + artifact.id }) {
                displayBlocks[index] = .artifact(artifact)
            } else {
                displayBlocks.append(.artifact(artifact))
            }
        }
    }
}

enum NativeSpokenText {
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let range = Range(match.range, in: result) { result.removeSubrange(range) }
            }
        }
        result = result.replacingOccurrences(
            of: "(?i)\\b(?:[a-z][a-z0-9+.-]*://|www\\.)[^\\s<>]+", with: "", options: .regularExpression)
        return result.strippedMarkdown()
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum NativeDisplayBlock: Codable, Hashable, Identifiable, Sendable {
    case taskCard(NativeTaskCardPresentation)
    case link(NativeDisplayLink)
    case artifact(NativeResearchArtifact)

    var id: String {
        switch self {
        case .taskCard(let card): return "task:" + card.id
        case .link(let link): return "link:" + link.id
        case .artifact(let artifact): return "artifact:" + artifact.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, link, artifact
        case taskCard = "task_card"
    }
    private enum Kind: String, Codable { case taskCard = "task_card", link, artifact }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .taskCard: self = .taskCard(try container.decode(NativeTaskCardPresentation.self, forKey: .taskCard))
        case .link: self = .link(try container.decode(NativeDisplayLink.self, forKey: .link))
        case .artifact: self = .artifact(try container.decode(NativeResearchArtifact.self, forKey: .artifact))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .taskCard(let card):
            try container.encode(Kind.taskCard, forKey: .type)
            try container.encode(card, forKey: .taskCard)
        case .link(let link):
            try container.encode(Kind.link, forKey: .type)
            try container.encode(link, forKey: .link)
        case .artifact(let artifact):
            try container.encode(Kind.artifact, forKey: .type)
            try container.encode(artifact, forKey: .artifact)
        }
    }
}

struct NativeDisplayLink: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var url: String

    var destination: URL? {
        guard let value = URL(string: url),
              ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              value.host?.isEmpty == false, value.user == nil, value.password == nil else { return nil }
        return value
    }
}

struct NativeResearchArtifact: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var report: String
    var sources: [PulseSource]
}

struct NativeTaskCardPresentation: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case preparing, queued, working, stopping, stopped, completed, needsInput, failed

        var title: String {
            switch self {
            case .preparing: return "Starting research"
            case .queued: return "Ready to continue"
            case .working: return "Researching"
            case .stopping: return "Stopping research"
            case .stopped: return "Research stopped"
            case .completed: return "Research complete"
            case .needsInput: return "Needs your input"
            case .failed: return "Couldn't finish"
            }
        }

        var symbol: String {
            switch self {
            case .preparing, .queued: return "clock"
            case .working: return "magnifyingglass"
            case .stopping, .stopped: return "stop.circle"
            case .completed: return "checkmark.circle"
            case .needsInput: return "questionmark.circle"
            case .failed: return "exclamationmark.circle"
            }
        }
    }

    var id: String
    var title: String
    var status: Status
    var milestone: String
    var sources: [PulseSource] = []
    var connectionNote: String? = nil
    var canCancel: Bool = false
    var canRetry: Bool = false
}
