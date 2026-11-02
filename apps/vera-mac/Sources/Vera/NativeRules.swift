import Foundation

enum NativeActionClass: String, Codable, CaseIterable, Hashable, Sendable {
    case fileEdits = "file_edits"
    case commands
    case trash
    case networkSends = "network_sends"
    case sensitive

    var title: String {
        switch self {
        case .fileEdits: return "Edit files in granted folders"
        case .commands: return "Run commands in granted folders"
        case .trash: return "Move files to the Trash"
        case .networkSends: return "Send on your behalf"
        case .sensitive: return "Sensitive actions"
        }
    }

    var detail: String {
        switch self {
        case .fileEdits: return "Writing, editing, moving and creating files and folders inside a folder you granted."
        case .commands: return "Running a shell command with a granted folder as its working directory."
        case .trash: return "Moving a file or folder inside a grant to the Trash. Nothing is ever deleted outright."
        case .networkSends: return "Connected services that send messages, posts or uploads for you."
        case .sensitive: return "Credentials, payments and deleting anything outside the working tree. Always handed to you."
        }
    }

    var isFixed: Bool { self == .sensitive }
}

enum NativeRuleChoice: String, Codable, CaseIterable, Hashable, Sendable {
    case act
    case actIfPreapproved = "act_if_preapproved"
    case ask
    case handOff = "hand_off"

    var title: String {
        switch self {
        case .act: return "Act without asking"
        case .actIfPreapproved: return "Act only when the request pre-approves it"
        case .ask: return "Ask first"
        case .handOff: return "Hand off to me"
        }
    }

    var strictness: Int {
        switch self {
        case .act: return 0
        case .actIfPreapproved: return 1
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
        .networkSends: .handOff,
        .sensitive: .handOff,
    ])

    init(choices: [NativeActionClass: NativeRuleChoice]) {
        self.choices = choices
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode([String: String].self)) ?? [:]
        var parsed: [NativeActionClass: NativeRuleChoice] = [:]
        for (key, value) in raw {
            guard let action = NativeActionClass(rawValue: key), let choice = NativeRuleChoice(rawValue: value) else { continue }
            parsed[action] = choice
        }
        choices = parsed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value.rawValue) }))
    }

    func choice(for action: NativeActionClass) -> NativeRuleChoice {
        if action.isFixed { return .handOff }
        return choices[action] ?? Self.defaults.choices[action] ?? .handOff
    }

    mutating func set(_ choice: NativeRuleChoice, for action: NativeActionClass) {
        guard !action.isFixed else { return }
        choices[action] = choice
    }
}

struct NativeConversationRules: Codable, Equatable, Hashable, Sendable {
    static let maximumPrefixes = 64

    var choices: [NativeActionClass: NativeRuleChoice] = [:]
    var approvedCommandPrefixes: [String] = []

    var isEmpty: Bool { choices.isEmpty && approvedCommandPrefixes.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case choices
        case approvedCommandPrefixes = "approved_command_prefixes"
    }

    init(choices: [NativeActionClass: NativeRuleChoice] = [:], approvedCommandPrefixes: [String] = []) {
        self.choices = choices
        self.approvedCommandPrefixes = approvedCommandPrefixes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decodeIfPresent([String: String].self, forKey: .choices)) ?? [:]
        var parsed: [NativeActionClass: NativeRuleChoice] = [:]
        for (key, value) in raw {
            guard let action = NativeActionClass(rawValue: key), let choice = NativeRuleChoice(rawValue: value) else { continue }
            parsed[action] = choice
        }
        choices = parsed
        let prefixes = (try? container.decodeIfPresent([String].self, forKey: .approvedCommandPrefixes)) ?? []
        approvedCommandPrefixes = Array(prefixes.filter { !$0.isEmpty }.prefix(Self.maximumPrefixes))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .choices)
        try container.encode(approvedCommandPrefixes, forKey: .approvedCommandPrefixes)
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
        guard !action.isFixed else { return }
        let base = global.choice(for: action)
        if choice.strictness <= base.strictness {
            choices.removeValue(forKey: action)
        } else {
            choices[action] = choice
        }
    }

    mutating func approve(prefix: String) {
        let trimmed = NativeCommandPrefix.normalize(prefix)
        guard !trimmed.isEmpty, !approvedCommandPrefixes.contains(trimmed) else { return }
        approvedCommandPrefixes.append(trimmed)
        if approvedCommandPrefixes.count > Self.maximumPrefixes { approvedCommandPrefixes.removeFirst() }
    }

    mutating func revoke(prefix: String) {
        approvedCommandPrefixes.removeAll { $0 == prefix }
    }

    func isApproved(command: String) -> Bool {
        let own = NativeCommandPrefix.prefix(of: command)
        guard !own.isEmpty, NativeCommandPrefix.isSimple(command) else { return false }
        return approvedCommandPrefixes.contains { NativeCommandPrefix.matches(command: command, prefix: $0) }
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
    static let phrases = [
        "no need to ask", "don't ask", "do not ask", "dont ask", "without asking", "go ahead",
        "you have my approval", "you have my permission", "pre-approved", "preapproved", "pre approved",
        "just do it", "don't check with me", "do not check with me", "no confirmation needed", "skip the confirmation",
    ]

    static let negations = ["not", "n't", "never", "unless", "without my", "ask me", "ask first", "check with me", "before you", "only if", "only after",
                            "if ", "when ", "whenever ", "once ", "after ", "before ", "later", "pending", "until", "provided", "providing", "assuming", "condition", "conditions", "contingent", "subject to", "as long as", "so long as", "so long", "in the event", "in case", "given that", "while", "as soon as", "depending", "depends", "depend", "whether", "otherwise", "explain", "why ", "what ", "whether", "mean", "should ", "would ", "could ", "is it", "dangerous", "risky"]

    static let quoteCharacters: Set<Character> = ["\"", "'", "`", "“", "”", "‘", "’", "«", "»", ">", ":"]

    static let openers = ["please", "yes", "ok", "okay", "sure", "fine", "alright", "just", "you can", "you may", "feel free", "feel free to"].sorted { $0.count > $1.count }
    static let framing = ["translate", "summarize", "summarise", "describe", "compare", "define", "discuss", "quote", "repeat", "rewrite", "paraphrase", "proofread", "phrase", "sentence", "wording", "example", "sample", "instruction", "says", "said", "wrote", "means", "meaning", "distinguish", "here is", "here's", "this is", "like this", "such as",
                          "permission", "approval", "authorization", "authorisation", "consent", "express", "expresses", "analyze", "analyse", "analysis", "grammar", "grammatical", "parse", "syntax", "language", "linguistic", "imperative", "verb", "noun", "following"]
    static let subjects: Set<String> = ["i", "you", "he", "she", "it", "we", "they", "my", "your", "his", "her", "its", "our", "their", "the", "a", "an", "this", "that", "these", "those", "someone", "somebody", "everyone", "anyone", "nobody"]
    static let speech = ["says", "said", "saying", "replied", "replies", "answered", "answers", "told", "tells", "wrote", "writes", "texted", "messaged", "asked", "asks", "mentioned", "mentions", "suggested", "suggests", "noted", "quoted", "quotes", "responded", "responds", "whispered", "whispers", "shouted", "shouts", "yelled", "muttered", "insisted", "added", "remarked"]

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
    }


    static func quoted(_ text: String) -> Bool {
        let characters = Array(text)
        for (index, character) in characters.enumerated() where quoteCharacters.contains(character) {
            if character == "'" || character == "’" {
                let before = index > 0 && characters[index - 1].isLetter
                let after = index + 1 < characters.count && characters[index + 1].isLetter
                if before && after { continue }
            }
            return true
        }
        return false
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

    static func sentenceGrants(_ sentence: String) -> Bool {
        var rest = sentence.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
        while true {
            if phrases.contains(rest) { return true }
            guard let opener = openers.first(where: { rest.hasPrefix($0 + " ") || rest.hasPrefix($0 + ",") }) else { return false }
            rest = String(rest.dropFirst(opener.count)).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
        }
    }

    static func grants(_ text: String) -> Bool {
        let lowered = normalized(text)
        guard phrases.contains(where: { lowered.contains($0) }) else { return false }
        var remainder = lowered
        for phrase in phrases { remainder = remainder.replacingOccurrences(of: phrase, with: " ") }
        if quoted(remainder) { return false }
        if negated(remainder) { return false }
        if lowered.contains("?") { return false }
        let wordList = " " + words(remainder).joined(separator: " ") + " "
        if framing.contains(where: { wordList.contains(" " + $0 + " ") }) { return false }
        if speech.contains(where: { wordList.contains(" " + $0 + " ") }) { return false }
        let sentences = lowered.components(separatedBy: CharacterSet(charactersIn: ".!;\n")).map { $0.trimmingCharacters(in: .whitespaces) }
        return sentences.contains { sentenceGrants($0) }
    }
}

enum NativeCommandClassifier {
    static let separators = ["&&", "||", ";", "|"]
    static let privileged: Set<String> = ["sudo", "doas", "su", "security", "diskutil", "launchctl", "csrutil", "spctl", "nvram", "systemsetup", "dscl", "passwd", "ssh-add", "ssh-keygen", "gpg", "op", "keychain"]
    static let destructive: Set<String> = ["rm", "rmdir", "mv", "cp", "chmod", "chown", "chflags", "shred", "srm", "dd", "truncate", "tee", "ln", "mkfs", "newfs"]
    static let senders: Set<String> = ["scp", "sftp", "ssh", "rsync", "mail", "mailx", "sendmail", "msmtp", "mutt", "osascript", "twurl", "slack", "gh", "glab", "hub", "aws", "gcloud", "az", "heroku", "flyctl", "fly", "vercel", "netlify", "wrangler", "npm", "pnpm", "yarn", "cargo", "pip", "twine", "gem", "docker", "kubectl", "helm", "terraform", "pulumi", "ansible", "fab"]
    static let wrappers: Set<String> = ["eval", "xargs", "source", ".", "timeout", "gtimeout", "stdbuf"]
    static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "perl", "ruby", "node", "php", "lua"]
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
        return (name, Array(tokens.dropFirst()))
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
        if wrappers.contains(name) { return true }
        if interpreters.contains(name) && arguments.contains(where: { argument in
            if argument.hasPrefix("--") { return argument.contains("eval") || argument.contains("exec") || argument.contains("command") }
            return argument.hasPrefix("-") && argument.dropFirst().contains(where: { $0 == "c" || $0 == "e" })
        }) { return true }
        return false
    }

    static func classify(_ command: String, grants: [FolderGrant], directory: String? = nil) -> NativeActionClass {
        var working = directory ?? (grants.count == 1 ? grants[0].path : nil)
        let lowered = command.lowercased()
        if sensitiveFragments.contains(where: { lowered.contains($0) }) { return .sensitive }
        let subshells = command.contains { "(){}".contains($0) }
        var network = false
        for segment in segments(of: command) {
            var (name, arguments) = executable(segment, grants: grants, working: working)
            if name == "?" { return .sensitive }
            if privileged.contains(name) { return .sensitive }
            if hasInlineCode(name, arguments) { return .sensitive }
            var segmentWorking = working
            if name == "git" {
                var index = 0
                while index < arguments.count {
                    let token = arguments[index]
                    if token == "-C", index + 1 < arguments.count {
                        let target = arguments[index + 1]
                        if pathLeavesGrants(target, grants: grants, working: segmentWorking) { return .sensitive }
                        segmentWorking = resolved(target, working: segmentWorking)
                        index += 2
                        continue
                    }
                    if token.hasPrefix("--git-dir") || token.hasPrefix("--work-tree") || token == "-C" { return .sensitive }
                    if token == "-c" || token == "--config-env" || token == "--namespace" || token == "--exec-path" || token == "--super-prefix" {
                        guard index + 1 < arguments.count else { return .sensitive }
                        index += 2
                        continue
                    }
                    if !token.hasPrefix("-") {
                        if destructiveGit.contains(token) { name = "rm"; arguments = Array(arguments[(index + 1)...]) }
                        break
                    }
                    index += 1
                }
            }
            if name == "find" && arguments.contains(where: { findEffects.contains($0) }) { name = "rm" }
            if ["cd", "pushd", "popd", "chdir"].contains(name) {
                if name == "popd" { working = nil; continue }
                guard let target = arguments.first(where: { !$0.hasPrefix("-") }) else { working = nil; continue }
                if pathLeavesGrants(target, grants: grants, working: working) { working = nil } else { working = resolved(target, working: working) }
                continue
            }
            if destructive.contains(name) {
                guard let segmentWorking, !subshells else { return .sensitive }
                if arguments.contains(where: { pathLeavesGrants($0, grants: grants, working: segmentWorking) }) { return .sensitive }
            }
            if name == "git" && arguments.contains(where: { ["push", "send-email"].contains($0) }) { network = true }
            if name == "curl" && arguments.contains(where: { ["-d", "--data", "--data-binary", "--data-raw", "--data-urlencode", "-F", "--form", "-T", "--upload-file", "-X", "--request"].contains($0) || $0.hasPrefix("--data") || $0.hasPrefix("-d") && $0.count > 2 || $0.hasPrefix("-F") && $0.count > 2 || $0.hasPrefix("-T") && $0.count > 2 || $0.hasPrefix("-X") && $0.count > 2 }) { network = true }
            if name == "wget" && arguments.contains(where: { $0.hasPrefix("--post") || $0.hasPrefix("--method") || $0.hasPrefix("--body") }) { network = true }
            if senders.contains(name) { network = true }
        }
        return network ? .networkSends : .commands
    }

    static func pathLeavesGrants(_ token: String, grants: [FolderGrant], working: String?) -> Bool {
        var path = stripOuterQuotes(token)
        if path.hasPrefix("-") { return false }
        if path.contains(where: { unsafeCharacters.contains($0) }) { return true }
        if path.hasPrefix("~") || path.hasPrefix("$") { return true }
        if path.split(separator: "/").contains("..") { return true }
        if !path.hasPrefix("/") {
            guard let working else { return true }
            path = working + "/" + path
        }
        guard let real = resolved(path, working: nil) else { return true }
        return !grants.contains { NativeFolderAccess.contains(root: resolved($0.path, working: nil) ?? $0.path, path: real) }
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
}

enum NativeRuleReason: String, Codable, Equatable, Hashable, Sendable {
    case rule
    case requestPreapproval = "request_preapproval"
    case userApproved = "user_approved"
    case conversationPrefix = "conversation_prefix"

    var title: String {
        switch self {
        case .rule: return "Ran without asking, as your rules allow"
        case .requestPreapproval: return "Ran because your request pre-approved it"
        case .userApproved: return "Ran after you approved it"
        case .conversationPrefix: return "Ran under an approval you gave earlier in this chat"
        }
    }
}

final class NativeRuleSource: @unchecked Sendable {
    private let lock = NSLock()
    private var global: NativeRules = .defaults
    private var conversations: [String: NativeConversationRules] = [:]

    func setGlobal(_ rules: NativeRules) {
        lock.lock(); defer { lock.unlock() }
        global = rules
    }

    func set(_ rules: NativeConversationRules, for conversationID: String) {
        lock.lock(); defer { lock.unlock() }
        if rules.isEmpty { conversations.removeValue(forKey: conversationID) } else { conversations[conversationID] = rules }
    }

    func replaceAll(_ pairs: [(String, NativeConversationRules)]) {
        lock.lock(); defer { lock.unlock() }
        conversations = Dictionary(pairs.filter { !$0.1.isEmpty }, uniquingKeysWith: { first, _ in first })
    }

    func resolver(for conversationID: String, requestText: String) -> NativeRuleResolver {
        lock.lock(); defer { lock.unlock() }
        return NativeRuleResolver(global: global, conversation: conversations[conversationID] ?? NativeConversationRules(), requestText: requestText)
    }
}

struct NativeRuleResolver: Sendable {
    var global: NativeRules
    var conversation: NativeConversationRules
    var requestText: String

    func choice(for action: NativeActionClass) -> NativeRuleChoice {
        let base = global.choice(for: action)
        guard let tightened = conversation.choices[action] else { return base }
        return NativeRuleChoice.stricter(base, tightened)
    }

    func decision(for action: NativeActionClass) -> NativeRuleDecision {
        switch choice(for: action) {
        case .act: return .act(.rule)
        case .actIfPreapproved: return NativeRequestPreapproval.grants(requestText) ? .act(.requestPreapproval) : .ask
        case .ask: return .ask
        case .handOff: return .handOff
        }
    }

    func decision(forCommand command: String) -> NativeRuleDecision {
        let base = decision(for: .commands)
        guard base == .ask, conversation.isApproved(command: command) else { return base }
        return .act(.conversationPrefix)
    }

    static let changedMessage = "The user's rules changed while this answer was running, so this action now needs their approval. It was not run. Tell the user and let them send the request again."

    static func gate(live: NativeRuleDecision, planned: NativeRuleDecision, action: NativeActionClass, approved: Bool) throws {
        if live == .handOff { throw NativeToolError.failed(handOffMessage(action)) }
        if live == .ask, !planned.requiresConfirmation, !approved { throw NativeToolError.failed(changedMessage) }
    }

    static func handOffMessage(_ action: NativeActionClass) -> String {
        "This action is set to hand off to the user in their rules (\(action.title.lowercased())). Do not attempt it; tell the user exactly what you would do so they can do it themselves or change the rule."
    }
}
