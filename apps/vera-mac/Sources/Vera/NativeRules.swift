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

    static let negations = ["not", "n't", "never", "unless", "without my", "ask me", "ask first", "check with me", "before you", "only if", "only after"]

    static let quoteCharacters: Set<Character> = ["\"", "'", "`", "“", "”", "‘", "’", "«", "»"]

    static func grants(_ text: String) -> Bool {
        let sentences = text.lowercased().components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        var granting = 0
        var vetoing = 0
        for sentence in sentences where phrases.contains(where: { sentence.contains($0) }) {
            var remainder = sentence
            for phrase in phrases { remainder = remainder.replacingOccurrences(of: phrase, with: " ") }
            if remainder.contains(where: { quoteCharacters.contains($0) }) { vetoing += 1; continue }
            let padded = " " + remainder + " "
            if negations.contains(where: { padded.contains($0.hasPrefix("n't") ? $0 : " " + $0) }) { vetoing += 1 } else { granting += 1 }
        }
        return granting > 0 && vetoing == 0
    }
}

enum NativeCommandClassifier {
    static let separators = ["&&", "||", ";", "|"]
    static let privileged: Set<String> = ["sudo", "doas", "su", "security", "diskutil", "launchctl", "csrutil", "spctl", "nvram", "systemsetup", "dscl", "passwd", "ssh-add", "ssh-keygen", "gpg", "op", "keychain"]
    static let destructive: Set<String> = ["rm", "rmdir", "mv", "cp", "chmod", "chown", "chflags", "shred", "srm", "dd", "truncate", "tee", "ln", "mkfs", "newfs"]
    static let senders: Set<String> = ["scp", "sftp", "ssh", "rsync", "mail", "mailx", "sendmail", "msmtp", "mutt", "osascript", "twurl", "slack", "gh", "glab", "hub", "aws", "gcloud", "az", "heroku", "flyctl", "fly", "vercel", "netlify", "wrangler", "npm", "pnpm", "yarn", "cargo", "pip", "twine", "gem", "docker", "kubectl", "helm", "terraform", "pulumi", "ansible", "fab"]
    static let sensitiveFragments = ["/.ssh", "/.aws", "/.gnupg", "/.config/gh", "/library/keychains", "/etc/", "/private/etc/", "/system/", "/usr/", "/bin/", "/sbin/", "/var/", "/library/", "/applications/", "/.vera", "/.tandem", ".pem", ".p12", "keychain", "id_rsa", "id_ed25519"]

    static func segments(of command: String) -> [[String]] {
        var spaced = command
        for separator in ["&&", "||", "&", ";", "|", "\n", "(", ")", "{", "}"] {
            spaced = spaced.replacingOccurrences(of: separator, with: " ; ")
        }
        return spaced.components(separatedBy: " ; ").map { NativeCommandPrefix.tokens(of: $0) }.filter { !$0.isEmpty }
    }

    static func executable(_ segment: [String]) -> (name: String, arguments: [String]) {
        var tokens = segment[...]
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-"), !first.hasPrefix("/") { tokens = tokens.dropFirst() }
        while let first = tokens.first, ["env", "nohup", "time", "nice", "command", "exec", "builtin", "caffeinate"].contains(first) {
            tokens = tokens.dropFirst()
            while let next = tokens.first, next.hasPrefix("-") || next.contains("=") { tokens = tokens.dropFirst() }
        }
        guard let first = tokens.first else { return ("", []) }
        let name = first.split(separator: "/").last.map(String.init) ?? first
        return (name, Array(tokens.dropFirst()))
    }

    static func classify(_ command: String, grants: [FolderGrant], directory: String? = nil) -> NativeActionClass {
        let working = directory ?? (grants.count == 1 ? grants[0].path : nil)
        let lowered = command.lowercased()
        if sensitiveFragments.contains(where: { lowered.contains($0) }) { return .sensitive }
        var network = false
        for segment in segments(of: command) {
            let (name, arguments) = executable(segment)
            if privileged.contains(name) { return .sensitive }
            if destructive.contains(name) && arguments.contains(where: { pathLeavesGrants($0, grants: grants, working: working) }) { return .sensitive }
            if name == "git" && arguments.contains(where: { ["push", "send-email"].contains($0) }) { network = true }
            if name == "curl" && arguments.contains(where: { ["-d", "--data", "--data-binary", "--data-raw", "--data-urlencode", "-F", "--form", "-T", "--upload-file", "-X", "--request"].contains($0) || $0.hasPrefix("--data") || $0.hasPrefix("-d") && $0.count > 2 || $0.hasPrefix("-F") && $0.count > 2 || $0.hasPrefix("-T") && $0.count > 2 || $0.hasPrefix("-X") && $0.count > 2 }) { network = true }
            if name == "wget" && arguments.contains(where: { $0.hasPrefix("--post") || $0.hasPrefix("--method") || $0.hasPrefix("--body") }) { network = true }
            if senders.contains(name) { network = true }
        }
        return network ? .networkSends : .commands
    }

    static func pathLeavesGrants(_ token: String, grants: [FolderGrant], working: String?) -> Bool {
        var path = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        if path.hasPrefix("-") { return false }
        if path.hasPrefix("~") || path.hasPrefix("$") { return true }
        if path.split(separator: "/").contains("..") { return true }
        if !path.hasPrefix("/") {
            guard let working else { return path.contains("..") }
            path = working + "/" + path
        }
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        return !grants.contains { NativeFolderAccess.contains(root: $0.path, path: path) }
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
