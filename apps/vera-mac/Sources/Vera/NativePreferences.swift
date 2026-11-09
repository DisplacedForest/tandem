import Foundation
import GRDB

enum NativePreferenceKind: String, Codable, CaseIterable, Sendable {
    case style
    case action
    case other
}

enum NativePreferenceStrength: String, Codable, CaseIterable, Sendable {
    case hard
    case standing
}

enum NativePreferenceStatus: String, Codable, Sendable {
    case active
    case removed
}

struct NativePreferenceCheck: Codable, Equatable, Sendable {
    var forbidChars: [String]?
    var forbidPhrases: [String]?
    var forbidEmoji: Bool?
    var maxCharacters: Int?

    static let allowedKeys: Set<String> = ["forbidChars", "forbidPhrases", "forbidEmoji", "maxCharacters"]
    static let maximumItems = 20
    static let maximumPhraseCharacters = 120
    static let characterLimitRange = 1...100_000

    var isEmpty: Bool {
        (forbidChars ?? []).isEmpty && (forbidPhrases ?? []).isEmpty && forbidEmoji != true && maxCharacters == nil
    }

    var isValid: Bool {
        if let chars = forbidChars {
            guard !chars.isEmpty, chars.count <= Self.maximumItems,
                  chars.allSatisfy({ $0.count == 1 && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return false }
        }
        if let phrases = forbidPhrases {
            guard !phrases.isEmpty, phrases.count <= Self.maximumItems,
                  phrases.allSatisfy({ phrase in
                      let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                      return !trimmed.isEmpty && trimmed == phrase && phrase.count <= Self.maximumPhraseCharacters
                          && !phrase.contains(where: \.isNewline)
                  }) else { return false }
        }
        if let limit = maxCharacters, !Self.characterLimitRange.contains(limit) { return false }
        return true
    }

    static func validated(_ value: Any?) -> NativePreferenceCheck?? {
        guard let value, !(value is NSNull) else { return .some(nil) }
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: allowedKeys) else { return nil }
        var check = NativePreferenceCheck()
        if let raw = object["forbidChars"], !(raw is NSNull) {
            guard let list = raw as? [Any] else { return nil }
            let strings = list.compactMap { $0 as? String }
            guard strings.count == list.count else { return nil }
            check.forbidChars = strings
        }
        if let raw = object["forbidPhrases"], !(raw is NSNull) {
            guard let list = raw as? [Any] else { return nil }
            let strings = list.compactMap { $0 as? String }
            guard strings.count == list.count else { return nil }
            check.forbidPhrases = strings
        }
        if let raw = object["forbidEmoji"], !(raw is NSNull) {
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            check.forbidEmoji = number.boolValue
        }
        if let raw = object["maxCharacters"], !(raw is NSNull) {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let exact = Int(exactly: number.doubleValue) else { return nil }
            check.maxCharacters = exact
        }
        guard check.isValid else { return nil }
        return .some(check.isEmpty ? nil : check)
    }

    static func merge(deterministic: NativePreferenceCheck?, classifier: NativePreferenceCheck?) -> NativePreferenceCheck? {
        guard let deterministic else { return classifier }
        guard let classifier else { return deterministic }
        var merged = classifier
        if deterministic.forbidChars != nil { merged.forbidChars = deterministic.forbidChars }
        if deterministic.forbidPhrases != nil { merged.forbidPhrases = deterministic.forbidPhrases }
        if deterministic.forbidEmoji != nil { merged.forbidEmoji = deterministic.forbidEmoji }
        if deterministic.maxCharacters != nil { merged.maxCharacters = deterministic.maxCharacters }
        return merged.isValid ? merged : deterministic
    }

    func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func decodedJSON(_ raw: String?) -> NativePreferenceCheck? {
        guard let raw, let check = try? JSONDecoder().decode(NativePreferenceCheck.self, from: Data(raw.utf8)), check.isValid else { return nil }
        return check
    }
}

struct NativePreference: Identifiable, Equatable, Sendable {
    let id: String
    var quote: String?
    var sourceTurnID: String?
    var statement: String
    var kind: NativePreferenceKind
    var strength: NativePreferenceStrength
    var check: NativePreferenceCheck?
    var status: NativePreferenceStatus
    var createdAt: Date
    var updatedAt: Date
    var checkedCount: Int
    var caughtCount: Int
}

struct NativePreferenceProposal: Equatable, Sendable {
    var statement: String
    var kind: NativePreferenceKind
    var strength: NativePreferenceStrength
    var check: NativePreferenceCheck?
}

enum NativePreferenceCaptureOutcomeKind: String, Sendable {
    case none
    case saved
    case removed
}

struct NativePreferenceCaptureRecord: Equatable, Sendable {
    let turnID: String
    let conversationID: String
    let userMessageID: String
    let outcome: NativePreferenceCaptureOutcomeKind
    let preferenceID: String?
}

struct NativePreferenceStoreError: Error, LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

struct NativePreferenceStore: Sendable {
    static let maximumStatementCharacters = 240
    static let maximumQuoteCharacters = 2_000

    let database: DatabaseQueue

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_preferences (
                id TEXT PRIMARY KEY NOT NULL,
                quote TEXT,
                source_turn_id TEXT UNIQUE,
                statement TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('style', 'action', 'other')),
                strength TEXT NOT NULL CHECK (strength IN ('hard', 'standing')),
                check_spec TEXT,
                status TEXT NOT NULL CHECK (status IN ('active', 'removed')),
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL,
                checked_count INTEGER NOT NULL DEFAULT 0,
                caught_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX native_preferences_status ON native_preferences(status, created_at);
            CREATE TABLE native_preference_captures (
                turn_id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL,
                user_message_id TEXT NOT NULL UNIQUE,
                outcome TEXT NOT NULL CHECK (outcome IN ('none', 'saved', 'removed')),
                preference_id TEXT,
                created_at DOUBLE NOT NULL
            );
            CREATE INDEX native_preference_captures_conversation ON native_preference_captures(conversation_id, created_at);
            """)
    }

    static func normalized(_ statement: String) -> String {
        let scalars = statement.lowercased().unicodeScalars.map { CharacterSet.punctuationCharacters.contains($0) ? " " : Character($0) }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func cleanStatement(_ statement: String) -> String? {
        let single = statement.split(whereSeparator: \.isNewline).joined(separator: " ")
        let collapsed = single.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= maximumStatementCharacters, !normalized(collapsed).isEmpty else { return nil }
        return collapsed
    }

    private static func decode(_ row: Row) -> NativePreference? {
        guard let id: String = row["id"], let statement: String = row["statement"],
              let kind = NativePreferenceKind(rawValue: row["kind"] ?? ""),
              let strength = NativePreferenceStrength(rawValue: row["strength"] ?? ""),
              let status = NativePreferenceStatus(rawValue: row["status"] ?? "") else { return nil }
        let created: Double = row["created_at"] ?? 0
        let updated: Double = row["updated_at"] ?? 0
        return NativePreference(id: id, quote: row["quote"], sourceTurnID: row["source_turn_id"], statement: statement,
                                kind: kind, strength: strength, check: NativePreferenceCheck.decodedJSON(row["check_spec"]),
                                status: status, createdAt: Date(timeIntervalSince1970: created),
                                updatedAt: Date(timeIntervalSince1970: updated),
                                checkedCount: row["checked_count"] ?? 0, caughtCount: row["caught_count"] ?? 0)
    }

    private static let columns = "id, quote, source_turn_id, statement, kind, strength, check_spec, status, created_at, updated_at, checked_count, caught_count"

    func active() throws -> [NativePreference] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.columns) FROM native_preferences WHERE status = 'active' ORDER BY created_at, id")
                .compactMap(Self.decode)
        }
    }

    func activeStatements() -> [String] {
        ((try? active()) ?? []).map(\.statement)
    }

    func preference(id: String) throws -> NativePreference? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.columns) FROM native_preferences WHERE id = ?", arguments: [id]).flatMap(Self.decode)
        }
    }

    func preference(sourceTurnID: String) throws -> NativePreference? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.columns) FROM native_preferences WHERE source_turn_id = ?", arguments: [sourceTurnID])
                .flatMap(Self.decode)
        }
    }

    func readBack(id: String, statement: String) -> NativePreference? {
        guard let stored = try? preference(id: id), stored.status == .active,
              Self.normalized(stored.statement) == Self.normalized(statement) else { return nil }
        return stored
    }

    @discardableResult
    func add(statement: String, kind: NativePreferenceKind = .other, strength: NativePreferenceStrength = .standing,
             check: NativePreferenceCheck? = nil, quote: String? = nil, sourceTurnID: String? = nil, now: Date = Date()) throws -> NativePreference {
        guard let clean = Self.cleanStatement(statement) else { throw NativePreferenceStoreError(detail: "A preference needs a short statement.") }
        let id = try database.write { db in
            try Self.upsert(db, statement: clean, kind: kind, strength: strength, check: check, quote: quote, sourceTurnID: sourceTurnID, now: now)
        }
        guard let stored = try preference(id: id) else { throw NativePreferenceStoreError(detail: "The preference did not save.") }
        return stored
    }

    private static func upsert(_ db: Database, statement: String, kind: NativePreferenceKind, strength: NativePreferenceStrength,
                               check: NativePreferenceCheck?, quote: String?, sourceTurnID: String?, now: Date) throws -> String {
        let key = normalized(statement)
        let boundedQuote = quote.map { String($0.prefix(maximumQuoteCharacters)) }
        let spec = check.flatMap { $0.isValid ? $0.encodedJSON() : nil }
        let rows = try Row.fetchAll(db, sql: "SELECT id, statement FROM native_preferences WHERE status = 'active' ORDER BY created_at, id")
        if let existing = rows.first(where: { normalized($0["statement"] ?? "") == key }), let id: String = existing["id"] {
            try db.execute(sql: """
                UPDATE native_preferences
                SET statement = ?, kind = ?, strength = ?, check_spec = COALESCE(?, check_spec), quote = COALESCE(?, quote), updated_at = ?
                WHERE id = ?
                """, arguments: [statement, kind.rawValue, strength.rawValue, spec, boundedQuote, now.timeIntervalSince1970, id])
            return id
        }
        let id = UUID().uuidString
        try db.execute(sql: """
            INSERT INTO native_preferences(id, quote, source_turn_id, statement, kind, strength, check_spec, status, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
            """, arguments: [id, boundedQuote, sourceTurnID, statement, kind.rawValue, strength.rawValue, spec,
                             now.timeIntervalSince1970, now.timeIntervalSince1970])
        return id
    }

    @discardableResult
    func updateStatement(id: String, statement: String, now: Date = Date()) throws -> NativePreference {
        guard let clean = Self.cleanStatement(statement) else { throw NativePreferenceStoreError(detail: "A preference needs a short statement.") }
        let spec = NativePreferenceRecognizer.check(for: clean)?.encodedJSON()
        try database.write { db in
            let key = Self.normalized(clean)
            let rows = try Row.fetchAll(db, sql: "SELECT id, statement FROM native_preferences WHERE status = 'active' AND id != ?", arguments: [id])
            if let duplicate = rows.first(where: { Self.normalized($0["statement"] ?? "") == key }), let other: String = duplicate["id"] {
                try db.execute(sql: "UPDATE native_preferences SET status = 'removed', updated_at = ? WHERE id = ?",
                               arguments: [now.timeIntervalSince1970, other])
            }
            try db.execute(sql: "UPDATE native_preferences SET statement = ?, check_spec = ?, updated_at = ? WHERE id = ? AND status = 'active'",
                           arguments: [clean, spec, now.timeIntervalSince1970, id])
            guard db.changesCount == 1 else { throw NativePreferenceStoreError(detail: "That preference is no longer saved.") }
        }
        guard let stored = try preference(id: id) else { throw NativePreferenceStoreError(detail: "That preference is no longer saved.") }
        return stored
    }

    func remove(id: String, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE native_preferences SET status = 'removed', updated_at = ? WHERE id = ?",
                           arguments: [now.timeIntervalSince1970, id])
        }
    }

    func capture(turnID: String, userMessageID: String) throws -> NativePreferenceCaptureRecord? {
        try database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT turn_id, conversation_id, user_message_id, outcome, preference_id FROM native_preference_captures
                WHERE turn_id = ? OR user_message_id = ?
                """, arguments: [turnID, userMessageID]).flatMap(Self.decodeCapture)
        }
    }

    func capture(conversationID: String, userMessageID: String) throws -> NativePreferenceCaptureRecord? {
        try database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT turn_id, conversation_id, user_message_id, outcome, preference_id FROM native_preference_captures
                WHERE conversation_id = ? AND user_message_id = ?
                """, arguments: [conversationID, userMessageID]).flatMap(Self.decodeCapture)
        }
    }

    private static func decodeCapture(_ row: Row) -> NativePreferenceCaptureRecord? {
        guard let turn: String = row["turn_id"], let conversation: String = row["conversation_id"],
              let message: String = row["user_message_id"],
              let outcome = NativePreferenceCaptureOutcomeKind(rawValue: row["outcome"] ?? "") else { return nil }
        return NativePreferenceCaptureRecord(turnID: turn, conversationID: conversation, userMessageID: message,
                                             outcome: outcome, preferenceID: row["preference_id"])
    }

    private static func insertCapture(_ db: Database, _ key: NativePreferenceCaptureKey, outcome: NativePreferenceCaptureOutcomeKind,
                                      preferenceID: String?, now: Date) throws {
        try db.execute(sql: """
            INSERT INTO native_preference_captures(turn_id, conversation_id, user_message_id, outcome, preference_id, created_at)
            VALUES(?, ?, ?, ?, ?, ?)
            """, arguments: [key.turnID, key.conversationID, key.userMessageID, outcome.rawValue, preferenceID, now.timeIntervalSince1970])
    }

    func recordNoCapture(_ key: NativePreferenceCaptureKey, now: Date = Date()) throws {
        try database.write { db in
            try Self.insertCapture(db, key, outcome: .none, preferenceID: nil, now: now)
        }
    }

    func saveCaptured(_ proposal: NativePreferenceProposal, quote: String, key: NativePreferenceCaptureKey, now: Date = Date()) throws -> String {
        guard let clean = Self.cleanStatement(proposal.statement) else { throw NativePreferenceStoreError(detail: "The preference statement is empty.") }
        return try database.write { db in
            let id = try Self.upsert(db, statement: clean, kind: proposal.kind, strength: proposal.strength, check: proposal.check,
                                     quote: quote, sourceTurnID: key.turnID, now: now)
            try Self.insertCapture(db, key, outcome: .saved, preferenceID: id, now: now)
            return id
        }
    }

    func removeCaptured(preferenceID: String, key: NativePreferenceCaptureKey, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE native_preferences SET status = 'removed', updated_at = ? WHERE id = ? AND status = 'active'",
                           arguments: [now.timeIntervalSince1970, preferenceID])
            guard db.changesCount == 1 else { throw NativePreferenceStoreError(detail: "The preference was not active.") }
            try Self.insertCapture(db, key, outcome: .removed, preferenceID: preferenceID, now: now)
        }
    }
}

struct NativePreferenceCaptureKey: Equatable, Sendable {
    let turnID: String
    let conversationID: String
    let userMessageID: String
}

enum NativePreferenceDetector {
    private static let markers = [
        "never", "don't", "dont", "do not", "stop", "always", "from now on", "i told you", "again", "quit",
        "please don't", "no more",
    ]

    private static let undoPhrases: Set<String> = [
        "forget that", "forget it", "forget about it", "never mind", "nevermind", "never mind that", "undo that", "undo",
        "undo it", "scratch that", "cancel that", "take that back", "actually never mind", "actually forget that",
        "ignore that", "disregard that", "please forget that", "please undo that", "forget that please", "undo that please",
        "never mind please", "oh never mind", "ok never mind", "okay never mind",
    ]

    static func folded(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
    }

    static func hits(_ text: String) -> Bool {
        let value = folded(text)
        return markers.contains { marker in
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            return value.range(of: "(?<![a-z'])" + escaped + "(?![a-z'])", options: .regularExpression) != nil
        }
    }

    static func isUndo(_ text: String) -> Bool {
        let value = folded(text).unicodeScalars.map { CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")).contains($0) ? " " : Character($0) }
        let phrase = String(value).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return undoPhrases.contains(phrase)
    }
}

enum NativePreferenceRecognizer {
    static let emDash = "\u{2014}"
    static let enDash = "\u{2013}"

    static func check(for text: String) -> NativePreferenceCheck? {
        let value = NativePreferenceDetector.folded(text)
        var chars: [String] = []
        let genericDashes = matches(value, "\\b(long |any )?dashes\\b") && !matches(value, "\\b(en|em)[- ]?dashes\\b")
        if genericDashes || matches(value, "\\b(em[- ]?|long )dash(es)?\\b") || mentions(value, emDash) { chars.append(emDash) }
        if genericDashes || matches(value, "\\ben[- ]?dash(es)?\\b") || mentions(value, enDash) { chars.append(enDash) }
        if matches(value, "\\bexclamation") || mentions(value, "!") { chars.append("!") }
        var check = NativePreferenceCheck()
        if !chars.isEmpty { check.forbidChars = chars }
        if matches(value, "\\bemojis?\\b|\\bemoticons?\\b") { check.forbidEmoji = true }
        let phrases = quotedPhrases(text)
        if !phrases.isEmpty { check.forbidPhrases = phrases }
        return check.isEmpty || !check.isValid ? nil : check
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    static func statement(for check: NativePreferenceCheck) -> String? {
        var uses: [String] = []
        for character in check.forbidChars ?? [] {
            switch character {
            case emDash: uses.append("em dashes")
            case enDash: uses.append("en dashes as dashes")
            case "!": uses.append("exclamation marks")
            default: uses.append("\"" + character + "\"")
            }
        }
        if check.forbidEmoji == true { uses.append("emoji") }
        var parts: [String] = []
        if !uses.isEmpty { parts.append("Don't use " + list(uses) + ".") }
        let phrases = (check.forbidPhrases ?? []).map { "\"" + $0 + "\"" }
        if !phrases.isEmpty { parts.append("Don't say " + list(phrases) + ".") }
        if let limit = check.maxCharacters { parts.append("Keep every reply under \(limit) characters.") }
        return NativePreferenceStore.cleanStatement(parts.joined(separator: " "))
    }

    static func proposal(for text: String, check: NativePreferenceCheck) -> NativePreferenceProposal? {
        guard let statement = statement(for: check) else { return nil }
        let value = NativePreferenceDetector.folded(text)
        let hard = matches(value, "(?<![a-z'])(never|always|no more|don't|dont|do not|stop)(?![a-z'])")
        return NativePreferenceProposal(statement: statement, kind: .style, strength: hard ? .hard : .standing, check: check)
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        if items.count == 2 { return items[0] + " or " + items[1] }
        return items.dropLast().joined(separator: ", ") + ", or " + (items.last ?? "")
    }

    private static func mentions(_ value: String, _ character: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: character)
        let quoted = "[\"'\u{201C}\u{2018}(]" + escaped + "[\"'\u{201D}\u{2019})]"
        let named = "\\b(use|using|with|write|writing|no|any|the)\\s+" + escaped + "(?=$|\\s|[.,;:])"
        return matches(value, quoted) || matches(value, named)
    }

    static func quotedPhrases(_ text: String) -> [String] {
        let pattern = "(?i)(?:never|don't|dont|do not|stop|quit|no more)\\s+(?:say|saying|use|using|write|writing)\\s+(?:the (?:word|phrase)s?\\s+)?[\"'\u{201C}\u{2018}]([^\"\u{201C}\u{201D}\n]{1,120}?)[\"'\u{201D}\u{2019}](?=$|[\\s.,;:!?)])"
        let folded = text.replacingOccurrences(of: "\u{2019}(?=[a-z])", with: "'", options: .regularExpression)
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var phrases: [String] = []
        for match in expression.matches(in: folded, range: NSRange(folded.startIndex..., in: folded)) {
            guard let range = Range(match.range(at: 1), in: folded) else { continue }
            let phrase = folded[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty, !phrases.contains(phrase), phrases.count < NativePreferenceCheck.maximumItems { phrases.append(phrase) }
        }
        return phrases
    }
}

enum NativePreferenceClassifier {
    static let marker = "standing preference classifier"
    static let excerptLimit = 2_000

    static func messages(for text: String) -> [NativeChatMessage] {
        let system = """
            You are a \(marker). Decide whether the person's message sets a standing preference for how the assistant should write or behave from now on.
            Reply with one JSON object and nothing else.
            If it does not set a lasting preference, reply {"preference": null}.
            If it does, reply {"preference": {"statement": "...", "kind": "style", "strength": "hard", "check": null}}.
            statement: one short sentence addressed to the assistant in plain words, such as "Never use em dashes."
            kind: "style" for tone, formatting, wording or characters. "action" for things to do or not do. "other" for anything else.
            strength: "hard" when the person says never or always or is repeating a correction. "standing" otherwise.
            check: null, or an object with any of "forbidChars" (a list of single characters never to write), "forbidPhrases" (a list of exact phrases never to write), "forbidEmoji" (true to never write emoji), "maxCharacters" (a whole number length limit for every reply).
            Reject anything that is not a lasting preference about the assistant. These are not preferences: "I never thought about it", "don't worry about it", "stop, I need to think", and a one-off instruction about this message only, such as "don't include an intro this time". Statements about the person's own life are not preferences either.
            """
        let body = "Message:\n" + String(text.prefix(excerptLimit))
        return [NativeChatMessage(role: "system", content: system), NativeChatMessage(role: "user", content: body)]
    }

    static func parse(_ raw: String?) -> NativePreferenceProposal? {
        guard let raw, let object = jsonObject(raw), object.count == 1, object.keys.first == "preference" else { return nil }
        guard let value = object["preference"], !(value is NSNull) else { return nil }
        guard let preference = value as? [String: Any],
              Set(preference.keys).isSubset(of: ["statement", "kind", "strength", "check"]),
              let statement = preference["statement"] as? String,
              let kindRaw = preference["kind"] as? String, let kind = NativePreferenceKind(rawValue: kindRaw),
              let strengthRaw = preference["strength"] as? String, let strength = NativePreferenceStrength(rawValue: strengthRaw),
              let check = NativePreferenceCheck.validated(preference["check"]) else { return nil }
        let dashless = statement
            .replacingOccurrences(of: "\\s*" + NativePreferenceRecognizer.emDash + "\\s*", with: ", ", options: .regularExpression)
        guard let clean = NativePreferenceStore.cleanStatement(dashless) else { return nil }
        return NativePreferenceProposal(statement: clean, kind: kind, strength: strength, check: check)
    }

    private static func jsonObject(_ raw: String) -> [String: Any]? {
        var text = raw
        if let close = text.range(of: "</think>", options: .backwards) { text = String(text[close.upperBound...]) }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        guard let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private enum Outcome: Sendable {
        case finished(String?)
        case timedOut
    }

    static func request(transport: any NativeChatTransport, model: String, text: String,
                        timeout: Duration = .seconds(30)) async -> String? {
        let prompt = messages(for: text)
        let outcome = await withTaskGroup(of: Outcome.self) { group -> Outcome in
            group.addTask {
                do {
                    var latest = ""
                    for try await snapshot in transport.stream(messages: prompt, model: model, tools: []) {
                        latest = snapshot.content
                    }
                    try Task.checkCancellation()
                    return .finished(latest)
                } catch {
                    return .finished(nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        guard case .finished(let content) = outcome else { return nil }
        return content
    }
}

enum NativePreferenceCaptureOutcome: Equatable, Sendable {
    case none
    case saved(String)
    case failed
    case removed(String)
    case removalFailed

    var note: String? {
        switch self {
        case .none: return nil
        case .saved(let statement):
            return "The person just set a preference and it is saved: \(NativePreferencePrompt.sentence(statement)) Follow it from now on. Acknowledge it in a few words."
        case .failed:
            return "The person asked for a preference but it could not be saved. Tell them plainly it was not saved."
        case .removed(let statement):
            return "The preference \(NativePreferencePrompt.quoted(statement)) was removed at the person's request. Confirm briefly."
        case .removalFailed:
            return "The person asked to remove a preference but it could not be removed. Tell them plainly it is still saved."
        }
    }
}

struct NativePreferenceCaptureRequest: Sendable {
    let key: NativePreferenceCaptureKey
    let previousUserMessageID: String?
    let text: String
}

enum NativePreferenceCapture {
    static func run(_ request: NativePreferenceCaptureRequest, store: NativePreferenceStore,
                    classify: @Sendable (String) async -> String?) async -> NativePreferenceCaptureOutcome {
        let key = request.key
        if let existing = try? store.capture(turnID: key.turnID, userMessageID: key.userMessageID) {
            return replayed(existing, store: store)
        }
        if NativePreferenceDetector.isUndo(request.text) {
            guard let previous = request.previousUserMessageID,
                  let earlier = try? store.capture(conversationID: key.conversationID, userMessageID: previous),
                  earlier.outcome == .saved, let preferenceID = earlier.preferenceID,
                  let target = try? store.preference(id: preferenceID), target.status == .active else { return .none }
            do {
                try store.removeCaptured(preferenceID: preferenceID, key: key)
            } catch {
                return .removalFailed
            }
            guard let after = try? store.preference(id: preferenceID), after.status == .removed else { return .removalFailed }
            return .removed(target.statement)
        }
        guard NativePreferenceDetector.hits(request.text) else { return .none }
        let raw = await classify(request.text)
        let recognized = NativePreferenceRecognizer.check(for: request.text)
        var proposal: NativePreferenceProposal
        if let classified = NativePreferenceClassifier.parse(raw) {
            proposal = classified
            proposal.check = NativePreferenceCheck.merge(deterministic: recognized, classifier: classified.check)
        } else if let recognized, let fallback = NativePreferenceRecognizer.proposal(for: request.text, check: recognized) {
            proposal = fallback
        } else {
            try? store.recordNoCapture(key)
            return .none
        }
        let id: String
        do {
            id = try store.saveCaptured(proposal, quote: request.text, key: key)
        } catch {
            if let existing = try? store.capture(turnID: key.turnID, userMessageID: key.userMessageID) {
                return replayed(existing, store: store)
            }
            return .failed
        }
        guard let stored = store.readBack(id: id, statement: proposal.statement) else { return .failed }
        return .saved(stored.statement)
    }

    private static func replayed(_ record: NativePreferenceCaptureRecord, store: NativePreferenceStore) -> NativePreferenceCaptureOutcome {
        guard let id = record.preferenceID, let stored = try? store.preference(id: id) else { return .none }
        switch record.outcome {
        case .none: return .none
        case .saved: return stored.status == .active ? .saved(stored.statement) : .none
        case .removed: return stored.status == .removed ? .removed(stored.statement) : .none
        }
    }
}

enum NativePreferencePrompt {
    static let header = "The person's standing preferences. Follow every one in everything you write:"
    static let maximumCharacters = 2_000

    static func section(_ statements: [String]) -> String? {
        let lines = statements.compactMap { NativePreferenceStore.cleanStatement($0) }
        guard !lines.isEmpty else { return nil }
        return ([header] + lines.map { "- " + $0 }).joined(separator: "\n")
    }

    static func sentence(_ statement: String) -> String {
        var trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".!?;:,".contains(last) { trimmed.removeLast() }
        return trimmed + "."
    }

    static func quoted(_ statement: String) -> String {
        var trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".!?;:,".contains(last) { trimmed.removeLast() }
        return "\"" + trimmed + "\""
    }
}
