import Foundation

enum RefusalCopy {
    static let leftToYou = "Left to you"
    static let notRun = "Not run"
    static let needsYou = "Needs you"
    static let changeInRules = "Change in Rules"

    static func label(_ why: NativeRuleWhy) -> String {
        why.kind == .rule && why.rule?.effect == .forbid ? notRun : leftToYou
    }

    static func offersRules(_ why: NativeRuleWhy) -> Bool {
        switch why.kind {
        case .unsaved, .outside, .rule, .held: return true
        case .tool, .folder: return false
        }
    }

    static func quoted(_ text: String) -> String { "\"" + text + "\"" }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static let risks: [(programs: Set<String>, phrase: String)] = [
        (["sudo", "doas", "su"], "asks for administrator rights"),
        (["security", "keychain", "ssh-add", "ssh-keygen", "gpg", "op", "passwd"], "touches passwords or keys"),
        (["diskutil", "launchctl", "csrutil", "spctl", "nvram", "systemsetup", "dscl", "mkfs", "newfs"], "changes system settings"),
        (["rm", "rmdir", "shred", "srm", "truncate", "dd"], "can delete things for good"),
        (["mv", "cp", "chmod", "chown", "chflags", "tee", "ln"], "can overwrite things"),
    ]

    static let pathLimit = 64

    static func shortened(_ path: String) -> String {
        let text = clean(path)
        guard text.count > pathLimit else { return text }
        return String(text.prefix(pathLimit / 2 - 2)) + "\u{2026}" + String(text.suffix(pathLimit / 2 + 1))
    }

    static func triggered(_ trigger: NativeRuleWhy.Trigger?, full: Bool = false) -> String {
        guard let trigger else { return "" }
        let text = clean(trigger.text)
        guard !text.isEmpty else { return "" }
        switch trigger.kind {
        case .program:
            guard let phrase = risks.first(where: { $0.programs.contains(text) })?.phrase else { return "" }
            return ", and this command \(phrase)"
        case .path:
            return ", and this command reaches \(full ? text : shortened(text))"
        case .feature:
            if text == NativeCommandClassifier.Feature.unreadable { return ", and this command couldn't be read in full" }
            return ", and this command uses \(text)"
        }
    }

    static func setTo(_ why: NativeRuleWhy) -> String {
        let choice = (why.choice ?? (why.handsOff ? .handOff : .ask)).title
        let place = why.source == .chat ? " in this chat" : ""
        return "\(quoted(why.action.title)) is set to \(choice)\(place)"
    }

    static func line(_ why: NativeRuleWhy, places: RulePlaces, full: Bool = false) -> CompanionLine {
        switch why.kind {
        case .unsaved:
            return .literal(setTo(why) + triggered(why.trigger, full: full) + ".")
        case .outside:
            let rule = why.rule.map { RuleRows.sentence($0.record, tools: places.tools) } ?? ""
            let subject = why.subject.map(clean).flatMap { $0.isEmpty ? nil : $0 } ?? "this"
            return .literal("Your rule \(quoted(rule)) doesn't cover \(subject).")
        case .rule:
            guard let rule = why.rule else { return .literal(setTo(why) + ".") }
            let sentence = RuleRows.sentence(rule.record, tools: places.tools)
            return .parts([.text("Your rule: " + sentence + ", ")] + RuleRows.place(rule.scope, places: places).parts + [.text(".")])
        case .held:
            let title = why.floorItem?.title ?? why.action.title
            return .literal("\(quoted(title)) is always left to you, and you can turn it on under Advanced in Rules.")
        case .tool:
            return .literal("This always asks you first, whatever your rules say.")
        case .folder:
            let path = why.subject.map { full ? clean($0) : shortened($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? "This"
            return .literal("\(path) is outside the folders shared with this chat, so share its folder to allow this.")
        }
    }

    static func plain(_ why: NativeRuleWhy, places: RulePlaces = RulePlaces(), name: String? = nil, full: Bool = false) -> String {
        line(why, places: places, full: full).plain(name: name)
    }

    static func forModel(_ why: NativeRuleWhy) -> String {
        let shown = "\(label(why)). \(plain(why, full: true))"
        if why.kind == .held {
            return "This action was not run. The user sees: \(shown) Do not attempt it and do not look for another way to do it; tell the user exactly what you would do so they can do it themselves."
        }
        if why.kind == .folder {
            return "This action was not run. The user sees: \(shown) Do not attempt it; tell the user which folder they would need to share."
        }
        return "This action was not run. The user sees: \(shown) Do not attempt it; tell the user exactly what you would do so they can do it themselves or change the rule."
    }

    static func samples() -> [NativeRuleWhy] {
        let allow = NativeRuleTarget.make(.commandPrefix, "make pdf").map {
            NativeRuleRecord(scope: .conversation("sample"), action: .commands, toolID: NativeCommandTools.toolID, target: $0, effect: .allow,
                             statement: "Allow commands that start with make pdf")
        }
        let never = NativeRuleRecord(scope: .conversation("sample"), action: nil, toolID: NativeCommandTools.toolID, effect: .forbid,
                                     statement: "Never run commands in this chat")
        return NativeRuleWhy.Kind.allCases.map { kind in
            switch kind {
            case .unsaved:
                return NativeRuleWhy(kind: .unsaved, action: .riskyCommands, handsOff: true, choice: .handOff, source: .settings,
                                     trigger: .init(.program, "sudo"))
            case .outside:
                return NativeRuleWhy(kind: .outside, action: .commands, handsOff: false, choice: .ask, source: .settings,
                                     rule: allow.map { .init($0) }, subject: "make clean")
            case .rule:
                return NativeRuleWhy(kind: .rule, action: .commands, handsOff: true, rule: .init(never))
            case .held:
                return NativeRuleWhy(kind: .held, action: .payments, handsOff: true, item: .payments)
            case .tool:
                return NativeRuleWhy.tool(.networkSends)
            case .folder:
                return NativeRuleWhy.folder(.fileEdits, path: "/Volumes/Other/notes.txt")
            }
        }
    }
}
