import Foundation

struct RulePlaces: Equatable, Sendable {
    var chats: [String: String] = [:]
    var companionThreadID: String?
    var projects: [String: String] = [:]
    var schedules: [String: String] = [:]
    var work: [String: String] = [:]

    func contains(_ scope: NativeRuleScope) -> Bool {
        switch scope {
        case .everywhere: return true
        case .conversation(let id): return chats[id] != nil || id == companionThreadID
        case .project(let id): return projects[id] != nil
        case .schedule(let id): return schedules[id] != nil
        case .task(let id): return work[id] != nil
        }
    }
}

struct RuleRow: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case saved(String)
        case chat(conversationID: String, action: NativeActionClass)
    }

    let id: String
    let source: Source
    let sentence: String
    let place: String
    let note: String?
    let off: Bool
    let widens: Bool
    let widenQuestion: String?

    var line: String { sentence + ", " + place }
    var toggleTitle: String? {
        guard case .saved = source else { return nil }
        return off ? RuleRows.switchOn : RuleRows.switchOff
    }
    var menuTitles: [String] { [toggleTitle, widens ? RuleRows.applyEverywhere : nil].compactMap { $0 } }
}

enum RuleRows {
    static let sectionTitle = "Rules you saved"
    static let empty = "Nothing saved yet. Rules you save from a card show up here."
    static let remove = "Remove"
    static let more = "More"
    static let switchOff = "Switch off"
    static let switchOn = "Switch on"
    static let applyEverywhere = "Apply everywhere"
    static let widenConfirm = "Apply everywhere"
    static let cancel = "Cancel"
    static let offMark = "Switched off"
    static let carriedOver = "Carried over from an earlier version"
    static let everywhere = "everywhere"
    static let unnamedWork = "for background work"
    static let fallbackTool = "this action"

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: CompanionSentence.placeholder, with: "name")
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func lead(_ effect: NativeRuleEffect) -> String {
        switch effect {
        case .allow: return "Always allow"
        case .ask: return "Always ask before"
        case .handOff: return "Always leave to you"
        case .forbid: return "Never allow"
        }
    }

    static func toolName(_ record: NativeRuleRecord) -> String {
        guard let range = record.statement.range(of: ": ") else { return fallbackTool }
        let name = plain(String(record.statement[range.upperBound...]))
        return name.isEmpty ? fallbackTool : name
    }

    static func sentence(_ record: NativeRuleRecord) -> String {
        let lead = lead(record.effect)
        if let target = record.target {
            switch target.kind {
            case .commandPrefix: return "\(lead) commands that start with \(plain(target.value))"
            case .folder:
                let name = plain(NativeCardChoices.name(target.value))
                return record.action == .trash ? "\(lead) moving things in \(name) to the Trash" : "\(lead) file edits in \(name)"
            case .recipient, .service: return "\(lead) sending to \(plain(target.value))"
            }
        }
        if record.toolID == NativeCommandTools.toolID, record.action == nil || record.action == .commands {
            switch record.effect {
            case .forbid: return "Never run commands"
            case .ask: return "Always ask before running commands"
            case .handOff: return "Always leave commands to you"
            case .allow: return "Always allow commands"
            }
        }
        if record.toolID != nil { return "\(lead): \(toolName(record))" }
        if let action = record.action { return "\(lead): \(lowered(action.title))" }
        return "\(lead): \(fallbackTool)"
    }

    static func lowered(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }

    static func place(_ scope: NativeRuleScope, places: RulePlaces) -> String {
        switch scope {
        case .everywhere: return everywhere
        case .conversation(let id):
            if id == places.companionThreadID { return "in \(CompanionSentence.placeholder)'s thread" }
            return "in \(plain(places.chats[id] ?? ""))"
        case .project(let id): return "in the \(plain(places.projects[id] ?? "")) project"
        case .schedule(let id): return "for the schedule \(plain(places.schedules[id] ?? ""))"
        case .task(let id):
            let title = plain(places.work[id] ?? "")
            return title.isEmpty ? unnamedWork : "for \(title)"
        }
    }

    static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        let start = calendar.startOfDay(for: now)
        let then = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: then, to: start).day ?? 0
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMM d" : "MMMM d, yyyy"
        return formatter.string(from: date)
    }

    static func until(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days == 0 { return "until the end of today" }
        if days == 1 { return "until tomorrow" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = days > 1 && days < 7 ? "EEEE" : "MMMM d"
        return "until " + formatter.string(from: date)
    }

    static func source(_ record: NativeRuleRecord, places: RulePlaces, now: Date, calendar: Calendar) -> String? {
        switch record.origin {
        case .migration: return carriedOver
        case .confirmCard:
            let when = day(record.createdAt, now: now, calendar: calendar)
            guard let id = record.originConversationID else { return "From a card, \(when)" }
            if id == places.companionThreadID { return "From a card in \(CompanionSentence.placeholder)'s thread, \(when)" }
            guard let title = places.chats[id], !plain(title).isEmpty else { return "From a card, \(when)" }
            return "From a card in \(plain(title)), \(when)"
        case .settings, .chat, .modelCard: return nil
        }
    }

    static func limit(_ record: NativeRuleRecord, now: Date, calendar: Calendar) -> String? {
        var parts: [String] = []
        if let uses = record.remainingUses { parts.append(uses == 1 ? "1 use left" : "\(uses) uses left") }
        if let end = record.expiresAt { parts.append(until(end, now: now, calendar: calendar)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func widens(_ record: NativeRuleRecord) -> Bool {
        switch record.scope {
        case .conversation, .project: break
        case .everywhere, .task, .schedule: return false
        }
        return record.effect == .allow || record.effect == .forbid
    }

    static func widenQuestion(_ record: NativeRuleRecord) -> String? {
        guard widens(record), record.effect == .forbid else { return nil }
        return "\(sentence(record)), in every chat and in background work?"
    }

    static func row(_ record: NativeRuleRecord, places: RulePlaces, now: Date, calendar: Calendar) -> RuleRow {
        var notes: [String] = []
        if record.status == .disabled { notes.append(offMark) }
        if let limit = limit(record, now: now, calendar: calendar) { notes.append(limit) }
        if let source = source(record, places: places, now: now, calendar: calendar) { notes.append(source) }
        return RuleRow(id: record.id, source: .saved(record.id), sentence: sentence(record), place: place(record.scope, places: places),
                       note: notes.isEmpty ? nil : notes.joined(separator: ". "), off: record.status == .disabled,
                       widens: widens(record), widenQuestion: widenQuestion(record))
    }

    static func chatRow(conversationID: String, action: NativeActionClass, choice: NativeRuleChoice, places: RulePlaces) -> RuleRow {
        RuleRow(id: "chat|\(conversationID)|\(action.rawValue)", source: .chat(conversationID: conversationID, action: action),
                sentence: "\(choice.title): \(lowered(action.title))", place: place(.conversation(conversationID), places: places),
                note: nil, off: false, widens: false, widenQuestion: nil)
    }

    static func rank(_ scope: NativeRuleScope) -> Int {
        switch scope {
        case .everywhere: return 0
        case .project: return 1
        case .conversation: return 2
        case .schedule: return 3
        case .task: return 4
        }
    }

    static func rows(records: [NativeRuleRecord], chatRules: [(id: String, rules: NativeConversationRules)], places: RulePlaces,
                     now: Date = Date(), calendar: Calendar = .current) -> [RuleRow] {
        let shown = records.filter { $0.status != .revoked && places.contains($0.scope) }
        let ordered = shown.sorted { first, second in
            let left = (rank(first.scope), place(first.scope, places: places))
            let right = (rank(second.scope), place(second.scope, places: places))
            if left != right { return left < right }
            if first.createdAt != second.createdAt { return first.createdAt > second.createdAt }
            return first.id < second.id
        }
        var rows = ordered.map { row($0, places: places, now: now, calendar: calendar) }
        for entry in chatRules.sorted(by: { (places.chats[$0.id] ?? "", $0.id) < (places.chats[$1.id] ?? "", $1.id) })
        where places.contains(.conversation(entry.id)) {
            for action in NativeActionClass.allCases {
                guard let choice = entry.rules.choices[action] else { continue }
                rows.append(chatRow(conversationID: entry.id, action: action, choice: choice, places: places))
            }
        }
        return rows
    }

    static func leftBehind(_ records: [NativeRuleRecord], exists: (NativeRuleScope) -> Bool?) -> [String] {
        records.compactMap { record in
            guard record.status != .revoked, record.scope != .everywhere, exists(record.scope) == false else { return nil }
            return record.id
        }
    }

    static func screenStrings(_ rows: [RuleRow], name: String?) -> [String] {
        var strings = [sectionTitle, empty, remove, more, switchOff, switchOn, applyEverywhere, widenConfirm, cancel]
        for row in rows {
            strings.append(CompanionSentence.plain(row.line, name: name))
            if let note = row.note { strings.append(CompanionSentence.plain(note, name: name)) }
            if let question = row.widenQuestion { strings.append(question) }
        }
        return strings
    }
}
