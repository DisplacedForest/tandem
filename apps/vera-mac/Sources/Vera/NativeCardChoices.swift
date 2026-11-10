import Foundation

enum NativeCardPlace: Equatable, Sendable {
    case chat(conversationID: String)
    case task(taskID: String, conversationID: String, scheduleID: String?)

    var conversationID: String {
        switch self {
        case .chat(let conversationID): return conversationID
        case .task(_, let conversationID, _): return conversationID
        }
    }

    var hereScope: NativeRuleScope {
        switch self {
        case .chat(let conversationID): return .conversation(conversationID)
        case .task(let taskID, _, _): return .task(taskID)
        }
    }

    var hereWords: String {
        switch self {
        case .chat: return "in this chat"
        case .task: return "in this task"
        }
    }

    var neverWords: String {
        switch self {
        case .chat: return "in this chat"
        case .task: return "in this task"
        }
    }
}

enum NativeCardChoiceKind: String, CaseIterable, Sendable {
    case allowOnce = "approve"
    case allowHere = "allow_here"
    case allowSchedule = "allow_schedule"
    case allowAlways = "allow_always"
    case never
    case decline

    var approves: Bool {
        switch self {
        case .allowOnce, .allowHere, .allowSchedule, .allowAlways: return true
        case .never, .decline: return false
        }
    }

    var saves: Bool {
        switch self {
        case .allowHere, .allowSchedule, .allowAlways, .never: return true
        case .allowOnce, .decline: return false
        }
    }
}

struct NativeCardChoice: Equatable, Hashable, Sendable {
    let kind: NativeCardChoiceKind
    let title: String
}

struct NativeCardSubject: Equatable, Hashable, Sendable {
    var action: NativeActionClass
    var toolID: String
    var toolTitle: String
    var targets: [NativeRuleTarget] = []
    var command: String?
    var governed = true
    var typedText = ""
    var scheduleInstructed = false
    var phrase: String? = nil
    var alwaysAsks = false
}

enum NativeCardCoverage: Equatable, Sendable {
    case commandPrefix(NativeRuleTarget)
    case commandsOnly
    case folders([NativeRuleTarget])
    case sendTargets([NativeRuleTarget], typed: Bool)
    case wholeTool
    case none
}

enum NativeCardChoices {
    static let commandNever = "never_commands"

    static func wire(_ choice: NativeCardChoice, subject: NativeCardSubject) -> String {
        choice.kind == .never && subject.toolID == NativeCommandTools.toolID ? commandNever : choice.kind.rawValue
    }

    static func kind(wire: String) -> NativeCardChoiceKind? {
        wire == commandNever ? .never : NativeCardChoiceKind(rawValue: wire)
    }

    static let declineMenu = true

    static func wireTitle(_ wire: String) -> String? {
        switch wire {
        case NativeCardChoiceKind.allowOnce.rawValue: return "Allow once"
        case NativeCardChoiceKind.allowHere.rawValue: return "Always allow in this task"
        case NativeCardChoiceKind.allowSchedule.rawValue: return "Always allow for this schedule"
        case NativeCardChoiceKind.allowAlways.rawValue: return "Always allow everywhere"
        case NativeCardChoiceKind.never.rawValue: return "Never allow this in this task"
        case commandNever: return "Never run commands in this task"
        case NativeCardChoiceKind.decline.rawValue: return "Decline"
        default: return nil
        }
    }

    static func scope(_ subject: NativeCardSubject) -> String? {
        switch coverage(subject) {
        case .none, .commandsOnly: return nil
        case .commandPrefix(let prefix): return "Commands that start with \(prefix.value)"
        case .folders(let folders):
            let names = list(folders.map { name($0.value) })
            return subject.action == .trash ? "Moving things in \(names) to the Trash" : "Edits in \(names)"
        case .sendTargets(let targets, _): return "Messages to " + list(targets.map(\.value))
        case .wholeTool: return "This action every time"
        }
    }

    static func sentence(actor: String, subject: NativeCardSubject?, title: String) -> String {
        let plain = subject?.phrase ?? (title.prefix(1).lowercased() + title.dropFirst())
        return actor + " wants to " + (subject.map { wants($0, phrase: plain) } ?? plain) + "."
    }

    static func wants(_ subject: NativeCardSubject, phrase: String) -> String {
        switch coverage(subject) {
        case .folders(let folders): return phrase + " in " + list(folders.map { name($0.value) })
        case .sendTargets(let targets, _): return phrase + " to " + list(targets.map(\.value))
        case .commandPrefix, .commandsOnly, .wholeTool, .none: return phrase
        }
    }

    static let neverHelp = "Commands you allowed everywhere still run."

    static func coverage(_ subject: NativeCardSubject) -> NativeCardCoverage {
        guard subject.governed else { return .none }
        if subject.toolID == NativeCommandTools.toolID {
            guard subject.action == .commands, let command = subject.command, NativeCommandPrefix.isSimple(command),
                  let prefix = NativeRuleTarget.make(.commandPrefix, command) else { return .commandsOnly }
            return .commandPrefix(prefix)
        }
        switch subject.action {
        case .fileEdits, .trash:
            var folders: [NativeRuleTarget] = []
            for target in subject.targets where target.kind == .folder {
                let parent = (target.value as NSString).deletingLastPathComponent
                guard parent.hasPrefix("/"), parent != "/", let folder = NativeRuleTarget.make(.folder, parent) else { continue }
                if !folders.contains(folder) { folders.append(folder) }
            }
            if folders.isEmpty { return subject.toolID == NativeFolderTools.toolID ? .none : .wholeTool }
            return .folders(folders)
        case .networkSends:
            let named = subject.targets.filter { $0.kind == .recipient || $0.kind == .service }
            guard !named.isEmpty else { return .wholeTool }
            let typed = NativeRequestPreapproval.normalized(subject.typedText)
            return .sendTargets(named, typed: named.allSatisfy { typed.contains(NativeRequestPreapproval.normalized($0.value)) })
        default:
            return .wholeTool
        }
    }

    static func signature(_ subject: NativeCardSubject) -> String {
        var parts = [subject.action.rawValue, subject.toolID]
        switch coverage(subject) {
        case .none: parts.append("none")
        case .commandsOnly: parts.append("commands")
        case .wholeTool: parts.append(subject.alwaysAsks ? "tool-asks" : "tool")
        case .commandPrefix(let prefix): parts += ["prefix", prefix.kind.rawValue, prefix.value]
        case .folders(let folders): parts += ["folders"] + folders.flatMap { [$0.kind.rawValue, $0.value] }
        case .sendTargets(let targets, let typed): parts += [typed ? "typed" : "untyped"] + targets.flatMap { [$0.kind.rawValue, $0.value] }
        }
        guard let data = try? JSONEncoder().encode(parts), let text = String(data: data, encoding: .utf8) else { return UUID().uuidString }
        return text
    }

    static func offered(_ subject: NativeCardSubject, place: NativeCardPlace) -> [NativeCardChoice] {
        let once = NativeCardChoice(kind: .allowOnce, title: "Allow once")
        let decline = NativeCardChoice(kind: .decline, title: "Decline")
        let covered = coverage(subject)
        var standing = !subject.alwaysAsks
        var never: NativeCardChoice? = NativeCardChoice(kind: .never, title: neverTitle(covered, action: subject.action, place: place))
        switch covered {
        case .none: return [decline, once]
        case .commandPrefix:
            never = NativeCardChoice(kind: .never, title: "Never run commands \(place.neverWords)")
        case .commandsOnly:
            standing = false
            never = NativeCardChoice(kind: .never, title: "Never run commands \(place.neverWords)")
        case .sendTargets(_, let typed):
            standing = standing && typed
        case .folders, .wholeTool:
            break
        }
        var choices = [decline]
        if let never { choices.append(never) }
        if standing {
            choices.append(NativeCardChoice(kind: .allowAlways, title: "Always allow everywhere"))
            if case .task(_, _, let scheduleID) = place, scheduleID != nil, subject.scheduleInstructed {
                choices.append(NativeCardChoice(kind: .allowSchedule, title: "Always allow for this schedule"))
            }
            choices.append(NativeCardChoice(kind: .allowHere, title: "Always allow \(place.hereWords)"))
        }
        choices.append(once)
        return choices
    }

    static func neverTitle(_ covered: NativeCardCoverage, action: NativeActionClass, place: NativeCardPlace) -> String {
        switch covered {
        case .folders(let folders):
            let names = list(folders.map { name($0.value) })
            return action == .trash ? "Never move things in \(names) to the Trash" : "Never edit in \(names)"
        case .sendTargets(let targets, _): return "Never send to " + list(targets.map(\.value))
        case .wholeTool, .commandPrefix, .commandsOnly, .none: return "Never allow this \(place.neverWords)"
        }
    }

    static func name(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    static func covers(_ subject: NativeCardSubject) -> String? {
        switch coverage(subject) {
        case .none, .commandsOnly: return nil
        case .commandPrefix(let prefix): return "commands that start with \(prefix.value)"
        case .folders(let folders):
            let names = list(folders.map { name($0.value) })
            return subject.action == .trash ? "moving things in \(names) to the Trash" : "file edits in \(names)"
        case .sendTargets(let targets, _):
            return "sending to " + list(targets.map(\.value))
        case .wholeTool:
            return "this action every time"
        }
    }

    static func scope(_ kind: NativeCardChoiceKind, place: NativeCardPlace) -> NativeRuleScope? {
        switch kind {
        case .allowHere, .never: return place.hereScope
        case .allowAlways: return .everywhere
        case .allowSchedule:
            guard case .task(_, _, let scheduleID?) = place else { return nil }
            return .schedule(scheduleID)
        case .allowOnce, .decline: return nil
        }
    }

    static func lead(_ kind: NativeCardChoiceKind, place: NativeCardPlace) -> String {
        switch kind {
        case .allowAlways: return "Always allow"
        case .allowSchedule: return "For this schedule, allow"
        case .allowHere:
            if case .chat = place { return "In this chat, allow" }
            return "For this task, allow"
        case .never, .allowOnce, .decline: return "Never allow"
        }
    }

    static func records(_ kind: NativeCardChoiceKind, subject: NativeCardSubject, place: NativeCardPlace, originMessageID: String?,
                        originToolCallID: String? = nil, now: Date = Date()) -> [NativeRuleRecord] {
        guard kind.saves, offered(subject, place: place).contains(where: { $0.kind == kind }),
              let scope = scope(kind, place: place) else { return [] }
        let effect: NativeRuleEffect = kind == .never ? .forbid : .allow
        func record(_ action: NativeActionClass?, tool: String?, target: NativeRuleTarget?, statement: String) -> NativeRuleRecord {
            NativeRuleRecord(scope: scope, action: action, toolID: tool, target: target, effect: effect, statement: statement,
                             origin: .confirmCard, originConversationID: place.conversationID, originMessageID: originMessageID,
                             originToolCallID: originMessageID == nil ? nil : originToolCallID,
                             reason: "You chose this on a confirmation card.", createdAt: now)
        }
        let covered = coverage(subject)
        if kind == .never {
            switch covered {
            case .commandPrefix, .commandsOnly:
                return [record(nil, tool: subject.toolID, target: nil, statement: "Never run commands \(place.neverWords)")]
            case .folders(let folders):
                return folders.map { record(subject.action, tool: nil, target: $0, statement: "Never allow \(covers(subject) ?? "this")") }
            case .sendTargets(let targets, _):
                return targets.map { record(subject.action, tool: nil, target: $0, statement: "Never allow sending to \($0.value)") }
            case .wholeTool:
                return [record(subject.action, tool: subject.toolID, target: nil, statement: "Never allow: \(subject.toolTitle)")]
            case .none:
                return []
            }
        }
        let statement = covered == .wholeTool ? "\(lead(kind, place: place)): \(subject.toolTitle)" : "\(lead(kind, place: place)) \(covers(subject) ?? "this")"
        switch covered {
        case .commandPrefix(let prefix):
            return [record(.commands, tool: subject.toolID, target: prefix, statement: statement)]
        case .folders(let folders):
            return folders.map { record(subject.action, tool: nil, target: $0, statement: statement) }
        case .sendTargets(let targets, let typed):
            guard typed else { return [] }
            return targets.map { record(subject.action, tool: subject.toolID, target: $0, statement: statement) }
        case .wholeTool:
            return [record(subject.action, tool: subject.toolID, target: nil, statement: statement)]
        case .commandsOnly, .none:
            return []
        }
    }
}
