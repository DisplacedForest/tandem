import Foundation
import GRDB

enum NativeDotState: String, Codable, Sendable {
    case active, paused
}

struct NativeDotProfile: Codable, Equatable, Sendable {
    static let goalLimit = 2000

    var goal: String = ""
    var connectedToolIDs: Set<String>? = nil
    var state: NativeDotState = .active
    var setupCompleted: Bool = false
    var needsIntroduction: Bool = false
    var updatedAt: Date = Date()
    var resumedAt: Date? = nil

    var hasGoal: Bool { !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isPaused: Bool { state == .paused }

    private enum CodingKeys: String, CodingKey {
        case goal
        case connectedToolIDs = "connected_tool_ids"
        case state
        case setupCompleted = "setup_completed"
        case needsIntroduction = "needs_introduction"
        case updatedAt = "updated_at"
        case resumedAt = "resumed_at"
    }

    init(goal: String = "", connectedToolIDs: Set<String>? = nil, state: NativeDotState = .active,
         setupCompleted: Bool = false, updatedAt: Date = Date(), resumedAt: Date? = nil) {
        self.goal = Self.clean(goal)
        self.connectedToolIDs = connectedToolIDs
        self.state = state
        self.setupCompleted = setupCompleted
        self.updatedAt = updatedAt
        self.resumedAt = resumedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goal = Self.clean((try? container.decodeIfPresent(String.self, forKey: .goal)) ?? "")
        if !container.contains(.connectedToolIDs) || ((try? container.decodeNil(forKey: .connectedToolIDs)) ?? false) {
            connectedToolIDs = nil
        } else {
            connectedToolIDs = (try? container.decode([String].self, forKey: .connectedToolIDs)).map(Set.init) ?? []
        }
        if container.contains(.state) {
            state = ((try? container.decodeIfPresent(String.self, forKey: .state)) ?? nil).flatMap(NativeDotState.init(rawValue:)) ?? .paused
        } else {
            state = .active
        }
        setupCompleted = (try? container.decodeIfPresent(Bool.self, forKey: .setupCompleted)) ?? false
        needsIntroduction = (try? container.decodeIfPresent(Bool.self, forKey: .needsIntroduction)) ?? false
        updatedAt = ((try? container.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? nil).map(Date.init(timeIntervalSince1970:)) ?? Date()
        resumedAt = ((try? container.decodeIfPresent(Double.self, forKey: .resumedAt)) ?? nil).map(Date.init(timeIntervalSince1970:))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(goal, forKey: .goal)
        try container.encodeIfPresent(connectedToolIDs.map { $0.sorted() }, forKey: .connectedToolIDs)
        try container.encode(state.rawValue, forKey: .state)
        try container.encode(setupCompleted, forKey: .setupCompleted)
        try container.encode(needsIntroduction, forKey: .needsIntroduction)
        try container.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
        try container.encodeIfPresent(resumedAt?.timeIntervalSince1970, forKey: .resumedAt)
    }

    static func clean(_ goal: String) -> String {
        String(goal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(goalLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func toolIDs(base: Set<String>) -> Set<String> {
        guard let connectedToolIDs else { return base }
        return base.intersection(connectedToolIDs)
    }

    func allowsScheduledRun(owner: NativeScheduleOwner) -> Bool {
        !(owner == .dot && state == .paused)
    }

    func missedWhilePaused(owner: NativeScheduleOwner, scheduledFor: Date) -> Bool {
        guard owner == .dot, let resumedAt else { return false }
        return scheduledFor <= resumedAt
    }
}

struct NativeDotProfileStore: Sendable {
    static let rowID = "dot"

    let database: DatabaseQueue

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_dot_profile (
                id TEXT PRIMARY KEY NOT NULL CHECK(id = 'dot'),
                profile_json TEXT NOT NULL,
                updated_at DOUBLE NOT NULL
            )
            """)
    }

    func load() throws -> NativeDotProfile? {
        try database.read { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT profile_json FROM native_dot_profile WHERE id = ?",
                                                arguments: [Self.rowID]) else { return nil }
            return try JSONDecoder().decode(NativeDotProfile.self, from: Data(raw.utf8))
        }
    }

    func save(_ profile: NativeDotProfile) throws {
        let raw = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO native_dot_profile(id, profile_json, updated_at) VALUES(?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET profile_json = excluded.profile_json, updated_at = excluded.updated_at
                """, arguments: [Self.rowID, raw, profile.updatedAt.timeIntervalSince1970])
        }
    }

    func reset() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM native_dot_profile WHERE id = ?", arguments: [Self.rowID])
        }
    }
}

struct NativeDotRemovalSummary: Equatable, Sendable {
    var messages = 0
    var memories = 0
    var proposals = 0
    var schedules = 0
    var artifacts = 0
    var hasGoal = false
    var services = false

    private static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value) \(value == 1 ? one : many)"
    }

    var sentence: String {
        var parts: [String] = []
        if messages > 0 { parts.append(Self.count(messages, "message", "messages")) }
        if memories > 0 { parts.append(Self.count(memories, "memory", "memories")) }
        if proposals > 0 { parts.append(Self.count(proposals, "suggested memory", "suggested memories")) }
        if schedules > 0 { parts.append(Self.count(schedules, "schedule", "schedules")) }
        if hasGoal { parts.append("the goal") }
        if services { parts.append("the service choices") }
        var text: String
        switch parts.count {
        case 0: text = "This starts a fresh conversation."
        case 1: text = "This removes \(parts[0])."
        default: text = "This removes \(parts.dropLast().joined(separator: ", ")) and \(parts[parts.count - 1])."
        }
        if artifacts > 0 {
            text += " " + (artifacts == 1 ? "Your 1 artifact stays in Artifacts." : "Your \(artifacts) artifacts stay in Artifacts.")
        }
        return text
    }
}

enum NativeDotContext {
    static let limit = 1200
    static let fixedLine = "Anything touching credentials, payments or deletions outside the working tree is always handed to the user."
    static let goalNote = "Keep this goal in mind when it is relevant; do not force it into unrelated conversations."
    static let coordinatorNote = "You coordinate rather than grind: work on the goal is handed to separate background workers that report back to you, so keep your own replies short and conversational, summarize what workers reported instead of repeating their output, and never paste long transcripts into this thread."

    static func wording(_ choice: NativeRuleChoice) -> String {
        switch choice {
        case .act: return "act without asking"
        case .actIfPreapproved: return "act only when the request pre-approves it, otherwise ask first"
        case .ask: return "ask the user before acting"
        case .handOff: return "hand off to the user"
        }
    }

    static func headerNoun(_ action: NativeActionClass) -> String {
        switch action {
        case .fileEdits: return "file edits"
        case .commands: return "commands"
        case .trash: return "Trash"
        case .networkSends: return "sending"
        case .sensitive: return "sensitive actions"
        }
    }

    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    static func headerSummary(resolver: NativeRuleResolver) -> String {
        let actions = NativeActionClass.allCases.filter { !$0.isFixed }
        func nouns(_ choice: NativeRuleChoice) -> [String] {
            actions.filter { resolver.choice(for: $0) == choice }.map(headerNoun)
        }
        var sentences: [String] = []
        let asks = nouns(.ask)
        if !asks.isEmpty { sentences.append("Asks first for \(list(asks)).") }
        let preapproved = nouns(.actIfPreapproved)
        if !preapproved.isEmpty { sentences.append("Needs your go-ahead in the request for \(list(preapproved)).") }
        let handed = nouns(.handOff)
        if !handed.isEmpty { sentences.append("Hands off \(list(handed)).") }
        return sentences.isEmpty ? "Acts without asking" : sentences.joined(separator: " ")
    }

    static func render(name: String, goal: String, resolver: NativeRuleResolver) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = trimmedName.isEmpty ? "You are the user's standing assistant." : "You are \(trimmedName), the user's standing assistant."
        let rules = NativeActionClass.allCases.filter { !$0.isFixed }.map { "\($0.title): \(wording(resolver.choice(for: $0)))." }
        func compose(_ goalSentence: String) -> String {
            ([opening, goalSentence, coordinatorNote, "What asks first here:"] + rules + [fixedLine]).joined(separator: "\n")
        }
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !trimmedGoal.isEmpty else { return compose("No standing goal has been set yet.") }
        let room = max(0, limit - compose("Your standing goal: . \(goalNote)").count)
        var shown = trimmedGoal
        if shown.count > room {
            shown = String(shown.prefix(max(0, room - 3))).trimmingCharacters(in: .whitespaces) + "..."
        }
        let ending = shown.hasSuffix(".") || shown.hasSuffix("!") || shown.hasSuffix("?") ? "" : "."
        return compose("Your standing goal: \(shown)\(ending) \(goalNote)")
    }
}
