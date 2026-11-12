import Foundation
import OSLog

enum NativeActionClass: String, Codable, CaseIterable, Hashable, Sendable {
    case fileEdits = "file_edits"
    case commands
    case trash
    case networkSends = "network_sends"
    case riskyCommands = "risky_commands"
    case reminders
    case serviceChanges = "service_changes"
    case otherChanges = "other_changes"
    case credentialEntry = "credential_entry"
    case payments
    case permanentDeletion = "permanent_deletion"

    static let configurable: [NativeActionClass] = allCases.filter { $0.floorItem == nil }

    var title: String {
        switch self {
        case .fileEdits: return "Edit files in shared folders"
        case .commands: return "Run commands in shared folders"
        case .trash: return "Move files to the Trash"
        case .networkSends: return "Send on your behalf"
        case .riskyCommands: return "Run risky commands"
        case .reminders: return "Change your reminders"
        case .serviceChanges: return "Make changes through connected services"
        case .otherChanges: return "Make other changes"
        case .credentialEntry: return NativeFloorItem.credentialEntry.title
        case .payments: return NativeFloorItem.payments.title
        case .permanentDeletion: return NativeFloorItem.permanentDeletion.title
        }
    }

    var detail: String {
        switch self {
        case .fileEdits: return "Writing, editing, moving and creating files and folders inside a folder you shared."
        case .commands: return "Running a command inside a folder you shared."
        case .trash: return "Moving a file or folder from a folder you shared to the Trash. Nothing is ever deleted outright."
        case .networkSends: return "Connected services that send messages, posts or uploads for you."
        case .riskyCommands: return "Commands that need administrator rights, reach into system or password locations, or can't be fully checked before they run."
        case .reminders: return "Adding, editing and completing Apple Reminders when you ask in a chat."
        case .serviceChanges: return "Creating or changing things in a connected service, like filing an issue."
        case .otherChanges: return "Changes made by tools you added that don't fit the kinds above."
        case .credentialEntry: return NativeFloorItem.credentialEntry.reason
        case .payments: return NativeFloorItem.payments.reason
        case .permanentDeletion: return NativeFloorItem.permanentDeletion.reason
        }
    }

    var floorItem: NativeFloorItem? {
        switch self {
        case .credentialEntry: return .credentialEntry
        case .payments: return .payments
        case .permanentDeletion: return .permanentDeletion
        case .fileEdits, .commands, .trash, .networkSends, .riskyCommands, .reminders, .serviceChanges, .otherChanges: return nil
        }
    }
}

enum NativeFloorItem: String, CaseIterable, Hashable, Sendable {
    case credentialEntry = "credential_entry"
    case payments
    case permanentDeletion = "permanent_deletion"
    case ruleChanges = "rule_changes"

    var title: String {
        switch self {
        case .credentialEntry: return "Enter a credential, card number or one-time code"
        case .payments: return "Pay or transfer money"
        case .permanentDeletion: return "Delete permanently outside a shared folder, or empty the Trash"
        case .ruleChanges: return "Loosen a rule because a message said to"
        }
    }

    var reason: String {
        switch self {
        case .credentialEntry: return "A wrong fill leaks a secret that can't be taken back."
        case .payments: return "Money that has left can't be called back."
        case .permanentDeletion: return "There is no undo."
        case .ruleChanges: return "Only you can loosen a rule, by clicking a card or changing it here. Text in a chat, a web page or an email can't."
        }
    }

    var actionClass: NativeActionClass? {
        switch self {
        case .credentialEntry: return .credentialEntry
        case .payments: return .payments
        case .permanentDeletion: return .permanentDeletion
        case .ruleChanges: return nil
        }
    }

    var isLiftable: Bool { actionClass != nil }
}

enum NativeRuleChoice: String, Codable, CaseIterable, Hashable, Sendable {
    case act
    case ask
    case handOff = "hand_off"

    static let retiredAsk = "act_if_preapproved"

    static func saved(_ raw: String) -> NativeRuleChoice? {
        raw == retiredAsk ? .ask : NativeRuleChoice(rawValue: raw)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let choice = Self.saved(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown rule choice")
        }
        self = choice
    }

    var title: String {
        switch self {
        case .act: return "Do it without asking"
        case .ask: return "Ask first"
        case .handOff: return "Leave it to me"
        }
    }

    var strictness: Int {
        switch self {
        case .act: return 0
        case .ask: return 2
        case .handOff: return 3
        }
    }

    static func stricter(_ lhs: NativeRuleChoice, _ rhs: NativeRuleChoice) -> NativeRuleChoice {
        lhs.strictness >= rhs.strictness ? lhs : rhs
    }
}

struct NativeRules: Codable, Equatable, Hashable, Sendable {
    var choices: [NativeActionClass: NativeRuleChoice]

    static let defaults = NativeRules(choices: [
        .fileEdits: .act,
        .commands: .ask,
        .trash: .ask,
        .networkSends: .ask,
        .riskyCommands: .handOff,
        .reminders: .act,
        .serviceChanges: .ask,
        .otherChanges: .ask,
    ])

    static let liftedDefault = NativeRuleChoice.ask

    init(choices: [NativeActionClass: NativeRuleChoice]) {
        self.choices = choices
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode([String: String].self)) ?? [:]
        var parsed: [NativeActionClass: NativeRuleChoice] = [:]
        for (key, value) in raw {
            guard let action = NativeActionClass(rawValue: key), let choice = NativeRuleChoice.saved(value) else { continue }
            if action.floorItem == nil { parsed[action] = choice }
        }
        for item in NativeFloorItem.allCases {
            guard let action = item.actionClass, let value = raw[Self.liftedPrefix + item.rawValue],
                  let choice = NativeRuleChoice.saved(value) else { continue }
            parsed[action] = choice
        }
        if raw[Self.defaultsKey] == nil, parsed[.networkSends] == .handOff { parsed.removeValue(forKey: .networkSends) }
        choices = parsed
    }

    static let liftedPrefix = "lifted."

    static let defaultsKey = "defaults_revision"
    static let defaultsRevision = "2"

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        var raw = Dictionary(uniqueKeysWithValues: choices.map { entry in
            (entry.key.floorItem.map { Self.liftedPrefix + $0.rawValue } ?? entry.key.rawValue, entry.value.rawValue)
        })
        raw[Self.defaultsKey] = Self.defaultsRevision
        try container.encode(raw)
    }

    func choice(for action: NativeActionClass) -> NativeRuleChoice {
        choices[action] ?? Self.defaults.choices[action] ?? .handOff
    }

    static func detail(for action: NativeActionClass, choice: NativeRuleChoice) -> String {
        guard action == .riskyCommands, choice == .act else { return action.detail }
        return action.detail + " Commands like sudo will run without asking."
    }

    func isLifted(_ item: NativeFloorItem) -> Bool {
        guard let action = item.actionClass else { return false }
        return choices[action] != nil
    }

    func holds(_ action: NativeActionClass) -> Bool {
        guard let item = action.floorItem else { return false }
        return !isLifted(item)
    }

    mutating func set(_ choice: NativeRuleChoice, for action: NativeActionClass) {
        if action.floorItem != nil && choices[action] == nil { return }
        choices[action] = choice
    }

    mutating func lift(_ item: NativeFloorItem, choice: NativeRuleChoice = NativeRules.liftedDefault) {
        guard let action = item.actionClass else { return }
        choices[action] = choice
    }

    mutating func restore(_ item: NativeFloorItem) {
        guard let action = item.actionClass else { return }
        choices.removeValue(forKey: action)
    }
}

struct NativeConversationRules: Codable, Equatable, Hashable, Sendable {
    var choices: [NativeActionClass: NativeRuleChoice] = [:]

    var isEmpty: Bool { choices.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case choices
    }

    init(choices: [NativeActionClass: NativeRuleChoice] = [:]) {
        self.choices = choices
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decodeIfPresent([String: String].self, forKey: .choices)) ?? [:]
        var parsed: [NativeActionClass: NativeRuleChoice] = [:]
        for (key, value) in raw {
            guard let action = NativeActionClass(rawValue: key), let choice = NativeRuleChoice.saved(value) else { continue }
            parsed[action] = choice
        }
        choices = parsed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .choices)
    }

    static func encode(_ rules: NativeConversationRules) -> String? {
        guard !rules.isEmpty, let data = try? JSONEncoder().encode(rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ raw: String?) -> NativeConversationRules {
        guard let raw, let data = raw.data(using: .utf8),
              let rules = try? JSONDecoder().decode(NativeConversationRules.self, from: data) else { return NativeConversationRules() }
        return rules
    }

    mutating func tighten(_ choice: NativeRuleChoice, for action: NativeActionClass, global: NativeRules) {
        guard !global.holds(action) else { choices.removeValue(forKey: action); return }
        let base = global.choice(for: action)
        if choice.strictness <= base.strictness {
            choices.removeValue(forKey: action)
        } else {
            choices[action] = choice
        }
    }
}

enum NativeCommandPrefix {
    static let words = 2
    static let controlCharacters: Set<Character> = [";", "&", "|", "`", "$", "(", ")", "<", ">", "\n", "\r", "\\", "\"", "'", "{", "}", "!", "#"]

    static func isSimple(_ command: String) -> Bool {
        let tokens = tokens(of: command)
        guard let first = tokens.first, !first.contains("="), !first.hasPrefix("-") else { return false }
        return !command.contains { controlCharacters.contains($0) }
    }

    static func tokens(of command: String) -> [String] {
        command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func normalize(_ prefix: String) -> String {
        tokens(of: prefix).prefix(words).joined(separator: " ")
    }

    static func prefix(of command: String) -> String {
        normalize(command)
    }

    static func matches(command: String, prefix: String) -> Bool {
        let own = tokens(of: command)
        let wanted = tokens(of: prefix)
        guard !wanted.isEmpty, own.count >= wanted.count else { return false }
        return Array(own.prefix(wanted.count)) == wanted
    }
}

enum NativeRequestPreapproval {
    static let negations = ["not", "n't", "never", "unless", "without my", "ask me", "ask first", "check with me", "before you", "only if", "only after",
                            "if ", "when ", "whenever ", "once ", "after ", "before ", "later", "pending", "until", "provided", "providing", "assuming", "condition", "conditions", "contingent", "subject to", "as long as", "so long as", "so long", "in the event", "in case", "given that", "while", "as soon as", "depending", "depends", "depend", "whether", "otherwise", "cancel", "cancelled", "canceled", "stop", "abort", "disregard", "ignore", "forget", "scratch", "nevermind", "never mind", "retract", "withdraw", "undo", "hold", "hold off", "hold on", "hang on", "wait", "not yet", "one moment", "let me", "pause", "review first", "before that", "do nothing", "on second thought", "actually", "instead", "no", "nope", "changed my mind", "change of mind", "on reflection", "rather not", "revoke", "revoked", "rescind", "rescinded", "retracted", "reverse", "strike that", "belay", "void", "nullify", "explain", "why ", "what ", "whether", "mean", "should ", "would ", "could ", "is it", "dangerous", "risky"]

    static let openers = ["please", "yes", "ok", "okay", "sure", "fine", "alright", "just", "you can", "you may", "feel free", "feel free to"].sorted { $0.count > $1.count }
    static let framing = ["translate", "summarize", "summarise", "describe", "compare", "define", "discuss", "quote", "repeat", "rewrite", "paraphrase", "proofread", "phrase", "sentence", "wording", "example", "sample", "instruction", "says", "said", "wrote", "means", "meaning", "distinguish", "here is", "here's", "this is", "like this", "such as",
                          "permission", "approval", "authorization", "authorisation", "consent", "express", "expresses", "analyze", "analyse", "analysis", "grammar", "grammatical", "parse", "syntax", "language", "linguistic", "imperative", "verb", "noun", "following"]
    static let speech = ["says", "said", "saying", "replied", "replies", "answered", "answers", "told", "tells", "wrote", "writes", "texted", "messaged", "asked", "asks", "mentioned", "mentions", "suggested", "suggests", "noted", "quoted", "quotes", "responded", "responds", "whispered", "whispers", "shouted", "shouts", "yelled", "muttered", "insisted", "added", "remarked"]

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init)
    }

    static func negated(_ text: String) -> Bool {
        let list = words(text)
        let joined = " " + list.joined(separator: " ") + " "
        return negations.contains { negation in
            let trimmed = negation.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("n't") { return list.contains { $0.hasSuffix("n't") } }
            return joined.contains(" " + trimmed + " ")
        }
    }

    static func settled(_ remainder: String, original: String) -> Bool {
        if negated(remainder) { return false }
        if original.contains("?") { return false }
        let wordList = " " + words(remainder).joined(separator: " ") + " "
        if framing.contains(where: { wordList.contains(" " + $0 + " ") }) { return false }
        if speech.contains(where: { wordList.contains(" " + $0 + " ") }) { return false }
        return true
    }
}

enum NativeCommandClassifier {
    static let separators = ["&&", "||", ";", "|"]
    static let privileged: Set<String> = ["sudo", "doas", "su", "security", "diskutil", "launchctl", "csrutil", "spctl", "nvram", "systemsetup", "dscl", "passwd", "ssh-add", "ssh-keygen", "gpg", "op", "keychain"]
    static let destructive: Set<String> = ["rm", "rmdir", "mv", "cp", "chmod", "chown", "chflags", "shred", "srm", "dd", "truncate", "tee", "ln", "mkfs", "newfs"]
    static let senders: Set<String> = ["scp", "sftp", "ssh", "rsync", "mail", "mailx", "sendmail", "msmtp", "mutt", "osascript", "twurl", "slack", "gh", "glab", "hub", "aws", "gcloud", "az", "heroku", "flyctl", "fly", "vercel", "netlify", "wrangler", "kubectl", "helm", "terraform", "pulumi", "ansible", "fab", "gsutil", "rclone", "nc"]
    static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "cargo", "pip", "pip3", "twine", "gem", "docker", "bun", "poetry", "uv"]
    static let publishing: Set<String> = ["publish", "deploy", "push", "login", "upload", "release"]
    static let executing: Set<String> = ["exec", "dlx", "x", "create", "init"]
    static let executors: Set<String> = ["npx", "bunx", "uvx", "pipx"]
    static let writers: Set<String> = ["curl", "wget"]
    static let globCharacters: Set<Character> = ["*", "?", "["]
    static let wrappers: Set<String> = ["eval", "xargs", "source", ".", "timeout", "gtimeout", "stdbuf", "if", "then", "else", "elif", "fi", "for", "do", "done", "while", "until", "case", "esac", "select", "function", "in", "!"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    static let interpreters: Set<String> = ["python", "python3", "perl", "ruby", "node", "php", "lua", "deno"]
    static let findEffects: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"]
    static let destructiveGit: Set<String> = ["clean", "reset", "rm", "restore", "checkout", "switch", "stash", "worktree", "branch", "filter-branch", "gc", "prune", "reflog"]
    static let unsafeCharacters: Set<Character> = ["\"", "'", "`", "$", "\\"]
    static let sensitiveFragments = ["/.ssh", "/.aws", "/.gnupg", "/.config/gh", "/library/keychains", "/etc/", "/private/etc/", "/system/", "/usr/", "/bin/", "/sbin/", "/var/", "/library/", "/applications/", "/.vera", "/.tandem", ".pem", ".p12", "keychain", "id_rsa", "id_ed25519"]

    static func segments(of command: String) -> [[String]] {
        var spaced = command
        for separator in ["&&", "||", "&", ";", "|", "\n", "(", ")", "{", "}"] {
            spaced = spaced.replacingOccurrences(of: separator, with: " ; ")
        }
        return spaced.components(separatedBy: " ; ").map { shellTokens($0) }.filter { !$0.isEmpty }
    }

    static func executable(_ segment: [String], grants: [FolderGrant] = [], working: String? = nil) -> (name: String, arguments: [String]) {
        var tokens = segment[...]
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-") {
            guard isPlainAssignment(first, grants: grants, working: working) else { return ("?", Array(tokens.dropFirst())) }
            tokens = tokens.dropFirst()
        }
        let launchers = ["env", "nohup", "time", "nice", "command", "exec", "builtin", "caffeinate", "arch", "xcrun"]
        while let first = tokens.first, launchers.contains(stripOuterQuotes(first)) {
            if stripOuterQuotes(first) != first { return ("?", Array(tokens.dropFirst())) }
            tokens = tokens.dropFirst()
            if let next = tokens.first, next.hasPrefix("-") { return ("?", Array(tokens.dropFirst())) }
            while let next = tokens.first, next.contains("=") {
                guard isPlainAssignment(next, grants: grants, working: working) else { return ("?", Array(tokens.dropFirst())) }
                tokens = tokens.dropFirst()
            }
        }
        guard let first = tokens.first else { return ("", []) }
        let unquoted = stripOuterQuotes(first)
        if unquoted.isEmpty || unquoted.contains(where: { !($0.isLetter || $0.isNumber || "._+-/~".contains($0)) }) { return ("?", Array(tokens.dropFirst())) }
        let name = unquoted.split(separator: "/").last.map(String.init) ?? unquoted
        return (name, tokens.dropFirst().map(stripOuterQuotes))
    }

    static func assignmentValue(_ token: String) -> String {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return token }
        let name = token[token.startIndex..<equals]
        guard let head = name.first, head.isLetter || head == "_", name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return token }
        return String(token[token.index(after: equals)...])
    }

    static func isPlainAssignment(_ token: String, grants: [FolderGrant] = [], working: String? = nil) -> Bool {
        guard let equals = token.firstIndex(of: "=") else { return false }
        let name = token[token.startIndex..<equals]
        let value = stripOuterQuotes(String(token[token.index(after: equals)...]))
        guard let head = name.first, head.isLetter || head == "_", name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        if name.uppercased().hasPrefix("GIT_") { return false }
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || "._+-/~:,@%=".contains($0) }) else { return false }
        if value.contains("/") || value.hasPrefix("~") || value.hasPrefix("..") {
            if pathLeavesGrants(value, grants: grants, working: working) { return false }
        }
        return true
    }

    static func shellTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func stripOuterQuotes(_ token: String) -> String {
        guard token.count >= 2, let first = token.first, let last = token.last, first == last, first == "\"" || first == "'" else { return token }
        return String(token.dropFirst().dropLast())
    }

    static func hasInlineCode(_ name: String, _ arguments: [String]) -> Bool {
        if wrappers.contains(name) || executors.contains(name) { return true }
        if packageManagers.contains(name), let first = arguments.first(where: { !$0.hasPrefix("-") }), executing.contains(first), name != "cargo" { return true }
        if shells.contains(name) && arguments.contains(where: { argument in
            if argument.hasPrefix("--") { return argument.contains("command") }
            return argument.hasPrefix("-") && argument.dropFirst().contains("c")
        }) { return true }
        if interpreters.contains(name) && arguments.contains(where: { argument in
            if argument.hasPrefix("--") { return argument.contains("eval") || argument.contains("exec") || argument.contains("command") }
            return argument.hasPrefix("-") && argument.dropFirst().contains(where: { $0 == "c" || $0 == "e" })
        }) { return true }
        if name == "deno", arguments.first(where: { !$0.hasPrefix("-") }) == "eval" { return true }
        return false
    }

    static let metacharacters: Set<Character> = [";", "&", "|", "(", ")", "{", "}", "`", "$", "<", ">", "\\", "\n", "\r"]
    static let keywords: Set<String> = ["if", "then", "else", "elif", "fi", "for", "do", "done", "while", "until", "case", "esac", "select", "function", "in", "!", "time", "coproc"]

    static func isPlainWord(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isLetter || $0.isNumber || "._+-/~".contains($0) }
    }

    struct Classified: Equatable, Sendable {
        var action: NativeActionClass
        var trigger: NativeRuleWhy.Trigger? = nil
        var outside: String? = nil

        static func risky(_ trigger: NativeRuleWhy.Trigger, outside: String? = nil) -> Classified {
            Classified(action: .riskyCommands, trigger: trigger, outside: outside)
        }
    }

    enum Feature {
        static let backticks = "a command inside backticks"
        static let substitution = "a command inside another command"
        static let inline = "inline code"
        static let wildcard = "a wildcard"
        static let variable = "a variable"
        static let home = "a home folder shortcut"
        static let up = "a path that goes up with .."
        static let unreadable = "something that could not be read"
        static let several = "more than one command"
        static let redirect = "a redirect"
        static let group = "a group of commands"
        static let unchecked = "a place that could not be checked"
        static let elsewhere = "a place outside the shared folders"
        static let places = [unchecked, elsewhere]
        static let all = [backticks, substitution, inline, wildcard, variable, home, up, unreadable, several, redirect, group, unchecked, elsewhere]
    }

    static func feature(_ text: String) -> NativeRuleWhy.Trigger { NativeRuleWhy.Trigger(.feature, text) }

    static func feature(of text: String) -> NativeRuleWhy.Trigger {
        if text.contains("`") { return feature(Feature.backticks) }
        if text.contains("$(") { return feature(Feature.substitution) }
        if text.contains("$") { return feature(Feature.variable) }
        return feature(Feature.unreadable)
    }

    static func feature(mark: Character, in command: String) -> NativeRuleWhy.Trigger {
        switch mark {
        case "`", "$": return feature(of: command)
        case ";", "&", "|", "\n", "\r": return feature(Feature.several)
        case "<", ">": return feature(Feature.redirect)
        case "(", ")", "{", "}": return feature(Feature.group)
        default: return feature(Feature.unreadable)
        }
    }

    static func isPlain(_ command: String, grants: [FolderGrant] = [], directory: String? = nil) -> Bool {
        unplain(command, grants: grants, directory: directory) == nil
    }

    static func unplain(_ command: String, grants: [FolderGrant] = [], directory: String? = nil) -> NativeRuleWhy.Trigger? {
        if let mark = command.first(where: { metacharacters.contains($0) }) { return feature(mark: mark, in: command) }
        let working = directory ?? (grants.count == 1 ? grants[0].path : nil)
        var tokens = shellTokens(command)[...]
        guard !tokens.isEmpty else { return feature(Feature.unreadable) }
        for token in tokens {
            let inner = stripOuterQuotes(assignmentValue(token))
            if inner.contains(where: { $0 == "\"" || $0 == "'" }) { return feature(Feature.unreadable) }
        }
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-") {
            guard isPlainAssignment(first, grants: grants, working: working) else { return feature(Feature.variable) }
            tokens = tokens.dropFirst()
        }
        let launchers: Set<String> = ["env", "nohup", "time", "nice", "command", "exec", "builtin", "caffeinate", "arch", "xcrun"]
        while true {
            guard let executable = tokens.first, isPlainWord(executable), !executable.hasPrefix("-") else { return feature(Feature.unreadable) }
            let name = executable.split(separator: "/").last.map(String.init) ?? executable
            if keywords.contains(name) || wrappers.contains(name) { return NativeRuleWhy.Trigger(.program, name) }
            if launchers.contains(name) && name != executable { return NativeRuleWhy.Trigger(.program, executable) }
            if name == "git" && tokens.dropFirst().contains(where: { let token = stripOuterQuotes($0); return token == "-c" || token.hasPrefix("--config") }) {
                return NativeRuleWhy.Trigger(.program, "git -c")
            }
            if hasInlineCode(name, tokens.dropFirst().map(stripOuterQuotes)) { return feature(Feature.inline) }
            guard launchers.contains(name) else { break }
            tokens = tokens.dropFirst()
            while let next = tokens.first, next.contains("="), !next.hasPrefix("-") {
                guard isPlainAssignment(next, grants: grants, working: working) else { return feature(Feature.variable) }
                tokens = tokens.dropFirst()
            }
        }
        if let keyword = tokens.dropFirst().first(where: { keywords.contains(stripOuterQuotes($0)) }) {
            return NativeRuleWhy.Trigger(.program, stripOuterQuotes(keyword))
        }
        return nil
    }

    static func classify(_ command: String, grants: [FolderGrant], directory: String? = nil) -> NativeActionClass {
        classified(command, grants: grants, directory: directory).action
    }

    static func trigger(_ command: String, grants: [FolderGrant], directory: String? = nil) -> NativeRuleWhy.Trigger? {
        classified(command, grants: grants, directory: directory).trigger
    }

    static func classified(_ command: String, grants: [FolderGrant], directory: String? = nil) -> Classified {
        var result = classifiedUnfloored(command, grants: grants, directory: directory)
        guard result.action == .riskyCommands, namesDestructiveProgram(command) else { return result }
        result.action = .permanentDeletion
        return result
    }

    static func namesDestructiveProgram(_ command: String) -> Bool {
        let joined = command.replacingOccurrences(of: "\\\r\n", with: "").replacingOccurrences(of: "\\\n", with: "")
            .filter { $0 != "\"" && $0 != "'" }
        return [joined.filter { $0 != "\\" }, joined.replacingOccurrences(of: "\\", with: " ")].contains { text in
            let words = text.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init)
            let flagged = text.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")) }).map(String.init)
            if words.contains("IFS") { return true }
            if words.contains(where: { destructive.contains($0) }) { return true }
            if flagged.contains(where: { findEffects.contains($0) }) { return true }
            guard words.contains("git") else { return false }
            return words.contains(where: { destructiveGit.contains($0) }) || flagged.contains(where: { destructiveGit.contains($0) })
        }
    }

    static func classifyUnfloored(_ command: String, grants: [FolderGrant], directory: String? = nil) -> NativeActionClass {
        classifiedUnfloored(command, grants: grants, directory: directory).action
    }

    static func classifiedUnfloored(_ command: String, grants: [FolderGrant], directory: String? = nil) -> Classified {
        let plain = isPlain(command, grants: grants, directory: directory)
        let segmented = classifiedSegments(command, grants: grants, directory: directory)
        if plain || segmented.action == .riskyCommands { return segmented }
        let working = directory ?? (grants.count == 1 ? grants[0].path : nil)
        var sends = segmented.action == .networkSends
        var sending = segmented.trigger
        for token in shellTokens(command.replacingOccurrences(of: ";", with: " ").replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "&", with: " ")) {
            let inner = stripOuterQuotes(assignmentValue(token))
            let name = inner.split(separator: "/").last.map(String.init) ?? inner
            if privileged.contains(name) || destructive.contains(name) || wrappers.contains(name) || destructiveGit.contains(name) {
                return .risky(NativeRuleWhy.Trigger(.program, name))
            }
            if inner.contains(where: { unsafeCharacters.contains($0) }) { return .risky(feature(of: inner)) }
            if inner.hasPrefix("~") { return .risky(feature(Feature.home)) }
            if inner.hasPrefix("$") { return .risky(feature(Feature.variable)) }
            if (inner.contains("/") || inner.hasPrefix("..")) && !inner.hasPrefix("-"), let left = leaving(inner, grants: grants, working: working) { return left }
            if senders.contains(name) || publishing.contains(name) {
                sends = true
                sending = sending ?? NativeRuleWhy.Trigger(.program, name)
            }
        }
        return sends ? Classified(action: .networkSends, trigger: sending) : Classified(action: .commands)
    }

    static func classifySegments(_ command: String, grants: [FolderGrant], directory: String? = nil) -> NativeActionClass {
        classifiedSegments(command, grants: grants, directory: directory).action
    }

    static func classifiedSegments(_ command: String, grants: [FolderGrant], directory: String? = nil) -> Classified {
        var working = directory ?? (grants.count == 1 ? grants[0].path : nil)
        let lowered = command.lowercased()
        if let fragment = sensitiveFragments.first(where: { lowered.contains($0) }) {
            return .risky(NativeRuleWhy.Trigger(.path, fragment))
        }
        if command.contains("`") { return .risky(feature(Feature.backticks)) }
        if command.contains("$(") { return .risky(feature(Feature.substitution)) }
        let subshells = command.contains { "(){}".contains($0) }
        var network: NativeRuleWhy.Trigger?
        var sending = false
        func send(_ program: String) {
            sending = true
            network = network ?? NativeRuleWhy.Trigger(.program, program)
        }
        for segment in segments(of: command) {
            var (name, arguments) = executable(segment, grants: grants, working: working)
            if name == "?" { return .risky(feature(Feature.unreadable)) }
            if privileged.contains(name) { return .risky(NativeRuleWhy.Trigger(.program, name)) }
            if hasInlineCode(name, arguments) { return .risky(wrappers.contains(name) ? NativeRuleWhy.Trigger(.program, name) : feature(Feature.inline)) }
            var segmentWorking = working
            var program = name
            if name == "git" {
                var index = 0
                while index < arguments.count {
                    let token = arguments[index]
                    if token == "-C", index + 1 < arguments.count {
                        let target = arguments[index + 1]
                        if let left = leaving(target, grants: grants, working: segmentWorking) { return left }
                        segmentWorking = resolved(target, working: segmentWorking)
                        index += 2
                        continue
                    }
                    if token.hasPrefix("--git-dir") || token.hasPrefix("--work-tree") || token == "-C" { return .risky(NativeRuleWhy.Trigger(.program, "git " + token)) }
                    if token == "-c" || token == "--config-env" || token == "--namespace" || token == "--exec-path" || token == "--super-prefix" {
                        guard index + 1 < arguments.count else { return .risky(NativeRuleWhy.Trigger(.program, "git " + token)) }
                        let operand = arguments[index + 1].lowercased()
                        if token == "-c" || token == "--config-env" {
                            if ["alias.", "core.sshcommand", "core.pager", "core.editor", "core.hookspath", "credential.", "http.", "url.", "remote.", "include.", "includeif.", "filter.", "diff.external", "merge.tool", "mergetool.", "difftool.", "sequence.editor", "core.fsmonitor", "core.gitproxy", "uploadpack.", "receive."].contains(where: { operand.hasPrefix($0) }) {
                                return .risky(NativeRuleWhy.Trigger(.program, "git " + token + " " + arguments[index + 1]))
                            }
                            if let equals = operand.firstIndex(of: "=") {
                                let value = String(operand[operand.index(after: equals)...])
                                if value.contains("/") || value.hasPrefix("~") || value.hasPrefix(".."), let left = leaving(value, grants: grants, working: segmentWorking) { return left }
                            }
                        }
                        index += 2
                        continue
                    }
                    if !token.hasPrefix("-") {
                        if destructiveGit.contains(token) { program = "git " + token; name = "rm"; arguments = Array(arguments[(index + 1)...]) }
                        break
                    }
                    index += 1
                }
            }
            if name == "find", let effect = arguments.first(where: { findEffects.contains($0) }) {
                program = "find " + effect
                name = "rm"
                arguments = Array(arguments.prefix(while: { !$0.hasPrefix("-") && !$0.hasPrefix("(") && $0 != "!" }))
            }
            if ["cd", "pushd", "popd", "chdir"].contains(name) {
                if name == "popd" { working = nil; continue }
                guard let target = arguments.first(where: { !$0.hasPrefix("-") }) else { working = nil; continue }
                if pathLeavesGrants(target, grants: grants, working: working) { working = nil } else { working = resolved(target, working: working) }
                continue
            }
            if destructive.contains(name) {
                guard let segmentWorking, !subshells else { return .risky(NativeRuleWhy.Trigger(.program, program)) }
                if let left = arguments.lazy.compactMap({ leaving($0, grants: grants, working: segmentWorking) }).first { return left }
                if arguments.contains(where: { !$0.hasPrefix("-") && $0.contains(where: { globCharacters.contains($0) }) }) { return .risky(feature(Feature.wildcard)) }
            }
            if writers.contains(name) {
                for argument in arguments where !argument.contains("://") {
                    let value = argument.hasPrefix("--") && argument.contains("=") ? String(argument[argument.index(after: argument.firstIndex(of: "=")!)...]) : argument
                    if value.hasPrefix("-") { continue }
                    if value.contains("/") || value.hasPrefix("~") || value.hasPrefix("..") {
                        if let left = leaving(value, grants: grants, working: segmentWorking) { return left }
                    }
                }
            }
            if name == "git", let verb = arguments.first(where: { ["push", "send-email"].contains($0) }) { send("git " + verb) }
            if name == "curl" && arguments.contains(where: { argument in
                if argument.hasPrefix("@") { return true }
                if argument.hasPrefix("--") { return argument.hasPrefix("--data") || ["--form", "--form-string", "--upload-file", "--request", "--json", "--url-query", "--config", "--variable"].contains(argument) }
                return argument.hasPrefix("-") && argument.dropFirst().contains(where: { "dFTXK".contains($0) })
            }) { send(name) }
            if name == "wget" && arguments.contains(where: { $0.hasPrefix("--post") || $0.hasPrefix("--method") || $0.hasPrefix("--body") }) { send(name) }
            if senders.contains(name) { send(name) }
            if packageManagers.contains(name), let verb = arguments.first(where: { publishing.contains($0) }) { send(name + " " + verb) }
        }
        return sending ? Classified(action: .networkSends, trigger: network) : Classified(action: .commands)
    }

    static func pathLeavesGrants(_ token: String, grants: [FolderGrant], working: String?) -> Bool {
        leaving(token, grants: grants, working: working) != nil
    }

    static func leaving(_ token: String, grants: [FolderGrant], working: String?) -> Classified? {
        var path = stripOuterQuotes(assignmentValue(token))
        if path.hasPrefix("-") { return nil }
        if path.contains(where: { unsafeCharacters.contains($0) }) { return .risky(feature(of: path)) }
        if path.hasPrefix("~") { return .risky(feature(Feature.home)) }
        if path.hasPrefix("$") { return .risky(feature(Feature.variable)) }
        if path.split(separator: "/").contains("..") { return .risky(feature(Feature.up)) }
        let written = path
        if !path.hasPrefix("/") {
            guard let working else { return .risky(feature(Feature.unchecked)) }
            path = working + "/" + path
        }
        guard let real = resolved(path, working: nil) else { return .risky(feature(Feature.unchecked)) }
        if grants.contains(where: { NativeFolderAccess.contains(root: resolved($0.path, working: nil) ?? $0.path, path: real) }) { return nil }
        let exists = FileManager.default.fileExists(atPath: real)
        return .risky(exists ? NativeRuleWhy.Trigger(.path, written) : feature(Feature.elsewhere), outside: real)
    }

    static func resolved(_ token: String, working: String?) -> String? {
        var path = stripOuterQuotes(token)
        if !path.hasPrefix("/") {
            guard let working else { return nil }
            path = working + "/" + path
        }
        var prefix = URL(fileURLWithPath: path).standardizedFileURL.path
        var rest: [String] = []
        while !prefix.isEmpty && prefix != "/" {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            if realpath(prefix, &buffer) != nil {
                let base = String(cString: buffer)
                return rest.reversed().reduce(base) { $0 + "/" + $1 }
            }
            let url = URL(fileURLWithPath: prefix)
            rest.append(url.lastPathComponent)
            prefix = url.deletingLastPathComponent().path
        }
        return nil
    }
}

enum NativeRuleDecision: Equatable, Hashable, Sendable {
    case act(NativeRuleReason)
    case ask
    case handOff

    var requiresConfirmation: Bool { self == .ask }

    var atLeastAsk: NativeRuleDecision {
        if case .act = self { return .ask }
        return self
    }
}

enum NativeRuleReason: String, Codable, Equatable, Hashable, Sendable {
    case rule
    case requestPreapproval = "request_preapproval"
    case userApproved = "user_approved"
    case conversationPrefix = "conversation_prefix"
    case grant
    case instruction

    var title: String {
        switch self {
        case .rule: return "Ran without asking, as your rules allow"
        case .requestPreapproval: return "Ran because your request pre-approved it"
        case .userApproved: return "Ran after you approved it"
        case .conversationPrefix: return "Ran under an approval you gave earlier in this chat"
        case .grant: return "Ran under a permission you saved"
        case .instruction: return "Ran because you asked for this"
        }
    }
}

final class NativeRuleSource: @unchecked Sendable {
    private let lock = NSLock()
    private let changeLock = NSLock()
    private var global: NativeRules = .defaults
    private var conversations: [String: NativeConversationRules] = [:]
    private var records: [NativeRuleRecord] = []
    private var projects: [String: String] = [:]
    private var revisionValue = 0
    private var allocator: (@Sendable () throws -> Int)?
    private var version = 0
    private var failed = false
    private var failureRevision = 0

    private static let failureLock = NSLock()
    nonisolated(unsafe) private static var failureCounter = 0

    private static func nextFailureRevision() -> Int {
        failureLock.lock(); defer { failureLock.unlock() }
        failureCounter -= 1
        return failureCounter
    }

    var revision: Int {
        lock.lock(); defer { lock.unlock() }
        return currentRevision()
    }

    var isDurable: Bool {
        lock.lock(); defer { lock.unlock() }
        return allocator != nil
    }

    var hasFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return failed
    }

    var currentRecords: [NativeRuleRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    private func currentRevision() -> Int {
        if failed { return failureRevision }
        return allocator == nil ? revisionValue : version
    }

    func attach(allocator: @escaping @Sendable () throws -> Int) {
        lock.lock(); defer { lock.unlock() }
        self.allocator = allocator
    }

    func fail() {
        lock.lock(); defer { lock.unlock() }
        failClosed()
    }

    private func failClosed() {
        if !failed {
            Logger(subsystem: "Vera", category: "rules").error("rules_version_unavailable")
        }
        failed = true
        failureRevision = Self.nextFailureRevision()
        records = NativeRuleRecord.strictFallback(records)
    }

    private func change(_ differs: () -> Bool, _ apply: () -> Void) {
        changeLock.lock(); defer { changeLock.unlock() }
        lock.lock()
        guard differs() else { lock.unlock(); return }
        guard let allocator, !failed else {
            apply()
            revisionValue += 1
            if failed { failureRevision = Self.nextFailureRevision() }
            lock.unlock()
            return
        }
        lock.unlock()
        let next = try? allocator()
        lock.lock(); defer { lock.unlock() }
        apply()
        revisionValue += 1
        if let next { version = max(version, next) } else { failClosed() }
    }

    func setRecords(_ next: [NativeRuleRecord]) {
        change({ records != next }, { records = next })
    }

    @discardableResult
    func publish(_ next: [NativeRuleRecord], version snapshot: Int) -> Bool {
        changeLock.lock(); defer { changeLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        if failed {
            failureRevision = Self.nextFailureRevision()
            return true
        }
        guard allocator != nil else {
            if records != next { records = next; revisionValue += 1 }
            return true
        }
        guard snapshot >= version else { return false }
        records = next
        version = snapshot
        return true
    }

    func setProject(_ projectID: String?, for conversationID: String) {
        change({ projects[conversationID] != projectID }, { projects[conversationID] = projectID })
    }

    func replaceProjects(_ pairs: [(String, String?)]) {
        var next: [String: String] = [:]
        for (conversationID, projectID) in pairs {
            if let projectID, next[conversationID] == nil { next[conversationID] = projectID }
        }
        change({ projects != next }, { projects = next })
    }

    func setGlobal(_ rules: NativeRules) {
        change({ global != rules }, { global = rules })
    }

    func set(_ rules: NativeConversationRules, for conversationID: String) {
        let next: NativeConversationRules? = rules.isEmpty ? nil : rules
        change({ conversations[conversationID] != next }, { conversations[conversationID] = next })
    }

    func replaceAll(_ pairs: [(String, NativeConversationRules)]) {
        let next = Dictionary(pairs.filter { !$0.1.isEmpty }, uniquingKeysWith: { first, _ in first })
        change({ conversations != next }, { conversations = next })
    }

    func resolver(for conversationID: String, requestText: String, typed: NativeTypedWords = .none, projectID: String? = nil,
                  taskID: String? = nil, scheduleID: String? = nil) -> NativeRuleResolver {
        lock.lock(); defer { lock.unlock() }
        var resolver = NativeRuleResolver(global: global, conversation: conversations[conversationID] ?? NativeConversationRules(),
                                          requestText: requestText, revision: currentRevision(), records: records,
                                          context: NativeRuleContext(conversationID: conversationID, projectID: projectID ?? projects[conversationID],
                                                                     taskID: taskID, scheduleID: scheduleID))
        resolver.durable = allocator != nil
        resolver.failed = failed
        resolver.typed = typed
        return resolver
    }
}

enum NativeRuleAdmission {
    @TaskLocal static var admitted = false
    @TaskLocal static var footprint: [String]?
    @TaskLocal static var expectsHandOff = false
}

struct NativeRuleVerdict: Sendable {
    var decision: NativeRuleDecision
    var confirm: (@Sendable () -> Bool)?
    var why: NativeRuleWhy?

    init(_ decision: NativeRuleDecision, why: NativeRuleWhy? = nil, confirm: (@Sendable () -> Bool)? = nil) {
        self.decision = decision
        self.confirm = confirm
        self.why = why
    }
}

struct NativeRuleRefusal: Error, LocalizedError, Equatable, Sendable {
    let why: NativeRuleWhy
    var errorDescription: String? { RefusalCopy.forModel(why) }
}

struct NativeRuleResolver: Sendable {
    var global: NativeRules
    var conversation: NativeConversationRules
    var requestText: String
    let revision: Int
    var records: [NativeRuleRecord] = []
    var context: NativeRuleContext?
    var now: Date = Date()
    var durable = false
    var toolID: String?
    var failed = false
    var subjects: [[NativeRuleTarget]] = []
    var typed: NativeTypedWords = .none
    var asked: NativeInstructionClaim?
    var uses: NativeInstructionUses?

    init(global: NativeRules, conversation: NativeConversationRules, requestText: String, revision: Int = 0,
         records: [NativeRuleRecord] = [], context: NativeRuleContext? = nil, now: Date = Date()) {
        self.global = global
        self.conversation = conversation
        self.requestText = requestText
        self.revision = revision
        self.records = records
        self.context = context
        self.now = now
    }

    func tool(_ id: String?, targets: [NativeRuleTarget]) -> NativeRuleResolver {
        tool(id, subjects: targets.isEmpty ? [] : [targets])
    }

    func tool(_ id: String?, subjects: [[NativeRuleTarget]]) -> NativeRuleResolver {
        var copy = self
        copy.toolID = id
        copy.subjects = subjects.filter { !$0.isEmpty }
        return copy
    }

    func choice(for action: NativeActionClass) -> NativeRuleChoice {
        if global.holds(action) { return .handOff }
        let base = global.choice(for: action)
        guard let tightened = conversation.choices[action] else { return base }
        return NativeRuleChoice.stricter(base, tightened)
    }

    private func baseDecision(for action: NativeActionClass) -> NativeRuleDecision {
        switch choice(for: action) {
        case .act: return .act(.rule)
        case .ask: return .ask
        case .handOff: return .handOff
        }
    }

    static func decision(for effect: NativeRuleEffect) -> NativeRuleDecision {
        switch effect {
        case .allow: return .act(.grant)
        case .ask: return .ask
        case .handOff, .forbid: return .handOff
        }
    }

    static func rank(_ decision: NativeRuleDecision) -> Int {
        switch decision {
        case .act: return 0
        case .ask: return 1
        case .handOff: return 2
        }
    }

    func tightens(_ action: NativeActionClass) -> Bool {
        guard let own = conversation.choices[action] else { return false }
        return own.strictness > global.choice(for: action).strictness
    }

    func overruled(_ resolution: NativeRuleResolution?, for action: NativeActionClass) -> Bool {
        guard let winner = resolution?.decidedBy, winner.effect == .allow, winner.specificity == 0, tightens(action) else { return false }
        if case .act = baseDecision(for: action) { return false }
        return true
    }

    func unnamed(_ part: NativeRuleQuery, honoringLimitedUse: Bool) -> NativeRuleTarget? {
        guard part.action == .networkSends else { return nil }
        return part.targets.first { target in
            guard target.kind == .recipient || target.kind == .service, !typed.names(target) else { return false }
            let single = NativeRuleQuery(action: part.action, toolID: part.toolID, targets: [target])
            let winner = NativeRuleMatcher.resolve(records, query: single, context: context, at: now, honoringLimitedUse: honoringLimitedUse)?.decidedBy
            return !(winner?.effect == .allow && winner?.target != nil)
        }
    }

    func unnamed(in query: NativeRuleQuery, honoringLimitedUse: Bool) -> NativeRuleTarget? {
        for part in query.parts {
            if let target = unnamed(part, honoringLimitedUse: honoringLimitedUse) { return target }
        }
        return nil
    }

    func resolve(_ query: NativeRuleQuery, honoringLimitedUse: Bool)
        -> (decision: NativeRuleDecision, resolution: NativeRuleResolution?, authorizedBy: [String]) {
        let settled = settle(query, honoringLimitedUse: honoringLimitedUse)
        var decided = settled
        if case .act = settled.decision, unnamed(in: query, honoringLimitedUse: honoringLimitedUse) != nil { decided = (.ask, settled.resolution, []) }
        guard decided.decision == .ask, instructed(query, honoringLimitedUse: honoringLimitedUse) != nil else { return decided }
        return (.act(.instruction), decided.resolution, [])
    }

    func settle(_ query: NativeRuleQuery, honoringLimitedUse: Bool)
        -> (decision: NativeRuleDecision, resolution: NativeRuleResolution?, authorizedBy: [String]) {
        if global.holds(query.action) { return (.handOff, nil, []) }
        var worst: (decision: NativeRuleDecision, resolution: NativeRuleResolution?)?
        var firstResolution: NativeRuleResolution?
        var authorizing: [String] = []
        var granted = false
        for part in query.parts {
            let resolution = NativeRuleMatcher.resolve(records, query: part, context: context, at: now, honoringLimitedUse: honoringLimitedUse)
            var decision = resolution.map { Self.decision(for: $0.decidedBy.effect) } ?? baseDecision(for: query.action)
            if overruled(resolution, for: query.action) { decision = baseDecision(for: query.action) }
            if firstResolution == nil { firstResolution = resolution }
            if case .act = decision, let winner = resolution?.decidedBy, winner.effect == .allow {
                granted = true
                if !authorizing.contains(winner.id) { authorizing.append(winner.id) }
            }
            if let current = worst {
                let stricter = Self.rank(decision) > Self.rank(current.decision)
                    || (Self.rank(decision) == Self.rank(current.decision)
                        && (resolution?.decidedBy.effect.strictness ?? -1) > (current.resolution?.decidedBy.effect.strictness ?? -1))
                if stricter { worst = (decision, resolution) }
            } else {
                worst = (decision, resolution)
            }
        }
        guard var decision = worst?.decision else { return (baseDecision(for: query.action), nil, []) }
        var resolution = worst?.resolution
        if case .act = decision {
            resolution = resolution ?? firstResolution
            if granted { decision = .act(.grant) }
        }
        if case .act = decision, NativeRuleMatcher.restrictsUntargeted(records, query: query, context: context, at: now) { decision = .ask }
        if failed, case .act = decision { decision = .ask }
        guard case .act = decision else { return (decision, resolution, []) }
        return (decision, resolution, authorizing)
    }

    func query(for action: NativeActionClass, command: String? = nil) -> NativeRuleQuery {
        var parts = subjects
        if let command, !parts.contains(where: { $0.contains { $0.kind == .commandPrefix } }),
           let target = NativeRuleTarget.candidate(.commandPrefix, command) {
            parts.append([target])
        }
        return NativeRuleQuery(action: action, toolID: toolID, subjects: parts)
    }

    func decide(for action: NativeActionClass, honoringLimitedUse: Bool = false) -> (decision: NativeRuleDecision, authorizedBy: [String]) {
        let resolved = resolve(query(for: action), honoringLimitedUse: honoringLimitedUse)
        return (resolved.decision, resolved.authorizedBy)
    }

    func decide(forCommand command: String, honoringLimitedUse: Bool = false) -> (decision: NativeRuleDecision, authorizedBy: [String]) {
        let resolved = resolve(query(for: .commands, command: command), honoringLimitedUse: honoringLimitedUse)
        return (resolved.decision, resolved.authorizedBy)
    }

    func decision(for action: NativeActionClass) -> NativeRuleDecision {
        decide(for: action).decision
    }

    func decision(forCommand command: String) -> NativeRuleDecision {
        decide(forCommand: command).decision
    }

    static let changedMessage = "The user's rules changed while this answer was running, so this action now needs their approval. It was not run. Tell the user and let them send the request again."

    static func gate(_ verdict: NativeRuleVerdict?, fallback: NativeRuleDecision?, planned: NativeRuleDecision, action: NativeActionClass,
                     approved: Bool, why: NativeRuleWhy? = nil) throws -> () throws -> Void {
        let live = verdict?.decision ?? fallback ?? planned
        try gate(live: live, planned: planned, action: action, approved: approved, why: verdict?.why ?? why)
        guard case .act = live, let confirm = verdict?.confirm else { return { NativeToolCallContext.effectStarts() } }
        return {
            if !confirm() { throw NativeToolError.failed(changedMessage) }
            if live == .act(.instruction) { NativeToolCallContext.reason?.note(.instruction) }
            NativeToolCallContext.effectStarts()
        }
    }

    static func gate(live: NativeRuleDecision, planned: NativeRuleDecision, action: NativeActionClass, approved: Bool, why: NativeRuleWhy? = nil) throws {
        if live == .handOff { throw NativeRuleRefusal(why: why ?? NativeRuleWhy(kind: .unsaved, action: action, handsOff: true)) }
        if NativeRuleAdmission.expectsHandOff { throw NativeToolError.failed(changedMessage) }
        if live == .ask, !approved { throw NativeToolError.failed(changedMessage) }
    }
}
