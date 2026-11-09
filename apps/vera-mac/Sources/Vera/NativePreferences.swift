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
        func union(_ base: [String]?, _ extra: [String]?) -> [String]? {
            let combined = (base ?? []) + (extra ?? []).filter { !(base ?? []).contains($0) }
            return combined.isEmpty ? nil : Array(combined.prefix(maximumItems))
        }
        merged.forbidChars = union(classifier.forbidChars, deterministic.forbidChars)
        merged.forbidPhrases = union(classifier.forbidPhrases, deterministic.forbidPhrases)
        if deterministic.forbidEmoji == true { merged.forbidEmoji = true }
        if merged.maxCharacters == nil { merged.maxCharacters = deterministic.maxCharacters }
        return merged.isValid ? merged : classifier
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

struct NativePreferenceStoreError: Error, LocalizedError, Equatable {
    enum Reason: Equatable, Sendable { case empty, tooLong, full, missing, stopped, failed }
    let reason: Reason

    var errorDescription: String? {
        switch reason {
        case .empty: return "Write the preference first."
        case .tooLong: return "Keep a preference under \(NativePreferenceStore.maximumStatementCharacters) characters."
        case .full: return "You have \(NativePreferenceStore.maximumActive) preferences. Remove one to add another."
        case .missing: return "That preference is no longer saved."
        case .stopped: return "The answer stopped before the preference saved."
        case .failed: return "The preference did not save."
        }
    }
}

struct NativePreferenceStore: Sendable {
    static let maximumStatementCharacters = 300
    static let maximumActive = 40
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
                created_new INTEGER NOT NULL DEFAULT 0,
                prior_json TEXT,
                written_at DOUBLE,
                created_at DOUBLE NOT NULL
            );
            CREATE INDEX native_preference_captures_conversation ON native_preference_captures(conversation_id, created_at);
            """)
    }

    static func normalized(_ statement: String) -> String {
        let scalars = statement.lowercased().unicodeScalars.map { CharacterSet.punctuationCharacters.contains($0) ? " " : Character($0) }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func collapsed(_ statement: String) -> String {
        statement.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func cleanStatement(_ statement: String) -> String? {
        let value = collapsed(NativePreferenceRecognizer.named(statement))
        guard !value.isEmpty, value.count <= maximumStatementCharacters, !normalized(value).isEmpty else { return nil }
        return value
    }

    static func settingsStatement(_ statement: String) throws -> String {
        let value = collapsed(NativePreferenceRecognizer.named(statement))
        guard !value.isEmpty, !normalized(value).isEmpty else { throw NativePreferenceStoreError(reason: .empty) }
        guard value.count <= maximumStatementCharacters else { throw NativePreferenceStoreError(reason: .tooLong) }
        return value
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
             check: NativePreferenceCheck? = nil, recognize: Bool = false, quote: String? = nil, sourceTurnID: String? = nil,
             now: Date = Date()) throws -> NativePreference {
        let clean = try Self.settingsStatement(statement)
        let resolved = recognize ? NativePreferenceCheck.merge(deterministic: NativePreferenceRecognizer.check(for: clean, settings: true), classifier: check) : check
        let id = try database.write { db in
            try Self.upsert(db, statement: clean, kind: kind, strength: strength, check: resolved, quote: quote, sourceTurnID: sourceTurnID, now: now).id
        }
        guard let stored = try preference(id: id) else { throw NativePreferenceStoreError(reason: .failed) }
        return stored
    }

    private static func upsert(_ db: Database, statement: String, kind: NativePreferenceKind, strength: NativePreferenceStrength,
                               check: NativePreferenceCheck?, quote: String?, sourceTurnID: String?, now: Date) throws -> (id: String, prior: String?) {
        let key = normalized(statement)
        let boundedQuote = quote.map { String($0.prefix(maximumQuoteCharacters)) }
        let spec = check.flatMap { $0.isValid ? $0.encodedJSON() : nil }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, statement, kind, strength, check_spec, quote FROM native_preferences WHERE status = 'active' ORDER BY created_at, id
            """)
        if let existing = rows.first(where: { normalized($0["statement"] ?? "") == key }), let id: String = existing["id"] {
            let fields: [String: Any] = ["statement": existing["statement"] as String? ?? "", "kind": existing["kind"] as String? ?? "other",
                                         "strength": existing["strength"] as String? ?? "standing",
                                         "check_spec": (existing["check_spec"] as String?) ?? NSNull(), "quote": (existing["quote"] as String?) ?? NSNull()]
            let prior = String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
            try db.execute(sql: """
                UPDATE native_preferences
                SET statement = ?, kind = ?, strength = ?, check_spec = COALESCE(?, check_spec), quote = COALESCE(?, quote), updated_at = ?
                WHERE id = ?
                """, arguments: [statement, kind.rawValue, strength.rawValue, spec, boundedQuote, now.timeIntervalSince1970, id])
            return (id, prior)
        }
        guard rows.count < maximumActive else { throw NativePreferenceStoreError(reason: .full) }
        let id = UUID().uuidString
        try db.execute(sql: """
            INSERT INTO native_preferences(id, quote, source_turn_id, statement, kind, strength, check_spec, status, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
            """, arguments: [id, boundedQuote, sourceTurnID, statement, kind.rawValue, strength.rawValue, spec,
                             now.timeIntervalSince1970, now.timeIntervalSince1970])
        return (id, nil)
    }

    @discardableResult
    func updateStatement(id: String, statement: String, now: Date = Date()) throws -> NativePreference {
        let clean = try Self.settingsStatement(statement)
        let recomputed = NativePreferenceRecognizer.check(for: clean, settings: true)?.encodedJSON()
        try database.write { db in
            let key = Self.normalized(clean)
            guard let current = try String.fetchOne(db, sql: "SELECT statement FROM native_preferences WHERE id = ? AND status = 'active'",
                                                    arguments: [id]) else { throw NativePreferenceStoreError(reason: .missing) }
            let unchanged = Self.normalized(current) == key
            let rows = try Row.fetchAll(db, sql: "SELECT id, statement FROM native_preferences WHERE status = 'active' AND id != ?", arguments: [id])
            if let duplicate = rows.first(where: { Self.normalized($0["statement"] ?? "") == key }), let other: String = duplicate["id"] {
                try db.execute(sql: "UPDATE native_preferences SET status = 'removed', updated_at = ? WHERE id = ?",
                               arguments: [now.timeIntervalSince1970, other])
            }
            if unchanged {
                try db.execute(sql: "UPDATE native_preferences SET statement = ?, updated_at = ? WHERE id = ? AND status = 'active'",
                               arguments: [clean, now.timeIntervalSince1970, id])
            } else {
                try db.execute(sql: "UPDATE native_preferences SET statement = ?, check_spec = ?, updated_at = ? WHERE id = ? AND status = 'active'",
                               arguments: [clean, recomputed, now.timeIntervalSince1970, id])
            }
            guard db.changesCount == 1 else { throw NativePreferenceStoreError(reason: .missing) }
        }
        guard let stored = try preference(id: id) else { throw NativePreferenceStoreError(reason: .missing) }
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
                                      preferenceID: String?, createdNew: Bool = false, prior: String? = nil, now: Date) throws {
        try db.execute(sql: """
            INSERT INTO native_preference_captures(turn_id, conversation_id, user_message_id, outcome, preference_id, created_new, prior_json,
                                                   written_at, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [key.turnID, key.conversationID, key.userMessageID, outcome.rawValue, preferenceID, createdNew, prior,
                             preferenceID == nil ? nil : now.timeIntervalSince1970, now.timeIntervalSince1970])
    }

    @discardableResult
    func revertCapture(turnID: String, now: Date = Date()) throws -> Bool {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT outcome, preference_id, created_new, prior_json, written_at FROM native_preference_captures WHERE turn_id = ?
                """, arguments: [turnID]),
                  let outcome = NativePreferenceCaptureOutcomeKind(rawValue: row["outcome"] ?? ""), outcome != .none,
                  let id: String = row["preference_id"], let written: Double = row["written_at"],
                  let current = try Row.fetchOne(db, sql: "SELECT status, updated_at FROM native_preferences WHERE id = ?", arguments: [id]),
                  (current["updated_at"] as Double?) == written,
                  (current["status"] as String?) == (outcome == .saved ? "active" : "removed") else { return false }
            let stamp = now.timeIntervalSince1970
            switch outcome {
            case .saved:
                if (row["created_new"] as Bool?) == true {
                    try db.execute(sql: "UPDATE native_preferences SET status = 'removed', updated_at = ? WHERE id = ?", arguments: [stamp, id])
                } else if let raw: String = row["prior_json"],
                          let prior = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                    try db.execute(sql: """
                        UPDATE native_preferences SET statement = ?, kind = ?, strength = ?, check_spec = ?, quote = ?, updated_at = ? WHERE id = ?
                        """, arguments: [prior["statement"] as? String ?? "", prior["kind"] as? String ?? "other",
                                         prior["strength"] as? String ?? "standing", prior["check_spec"] as? String,
                                         prior["quote"] as? String, stamp, id])
                }
            case .removed:
                let statement = try String.fetchOne(db, sql: "SELECT statement FROM native_preferences WHERE id = ?", arguments: [id]) ?? ""
                let active = try String.fetchAll(db, sql: "SELECT statement FROM native_preferences WHERE status = 'active'")
                guard active.count < Self.maximumActive, !active.contains(where: { Self.normalized($0) == Self.normalized(statement) }) else {
                    return false
                }
                try db.execute(sql: "UPDATE native_preferences SET status = 'active', updated_at = ? WHERE id = ? AND status = 'removed'",
                               arguments: [stamp, id])
            case .none:
                return false
            }
            try db.execute(sql: "UPDATE native_preference_captures SET outcome = 'none' WHERE turn_id = ?", arguments: [turnID])
            return true
        }
    }

    func recordNoCapture(_ key: NativePreferenceCaptureKey, now: Date = Date()) throws {
        try database.write { db in
            try Self.insertCapture(db, key, outcome: .none, preferenceID: nil, now: now)
        }
    }

    func saveCaptured(_ proposal: NativePreferenceProposal, quote: String, key: NativePreferenceCaptureKey, now: Date = Date(),
                      stillCurrent: (Database) throws -> Bool = { _ in true }) throws -> String {
        guard let clean = Self.cleanStatement(proposal.statement) else { throw NativePreferenceStoreError(reason: .empty) }
        return try database.write { db in
            guard try stillCurrent(db) else { throw NativePreferenceStoreError(reason: .stopped) }
            let saved = try Self.upsert(db, statement: clean, kind: proposal.kind, strength: proposal.strength, check: proposal.check,
                                        quote: quote, sourceTurnID: key.turnID, now: now)
            try Self.insertCapture(db, key, outcome: .saved, preferenceID: saved.id, createdNew: saved.prior == nil, prior: saved.prior, now: now)
            return saved.id
        }
    }

    func removeCaptured(preferenceID: String, key: NativePreferenceCaptureKey, now: Date = Date(),
                        stillCurrent: (Database) throws -> Bool = { _ in true }) throws {
        try database.write { db in
            guard try stillCurrent(db) else { throw NativePreferenceStoreError(reason: .stopped) }
            try db.execute(sql: "UPDATE native_preferences SET status = 'removed', updated_at = ? WHERE id = ? AND status = 'active'",
                           arguments: [now.timeIntervalSince1970, preferenceID])
            guard db.changesCount == 1 else { throw NativePreferenceStoreError(reason: .missing) }
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
        "please don't", "no more", "prefer", "i'd prefer", "i would prefer", "i'd rather", "i would rather", "avoid", "keep",
        "i want you to", "i'd like you to", "i would like you to", "i like it when", "i hate it when", "i don't like it when",
        "please always", "please never", "call me", "refer to me as", "address me as", "going forward", "in the future",
        "from here on", "every time", "whenever you", "instead of", "rather than", "be more", "be less", "stop being",
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
        } || value.range(of: "(?<![a-z'])use(?![a-z']).*(?<![a-z'])instead(?![a-z'])", options: .regularExpression) != nil
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
    private static let chatNegators = ["never", "don't", "dont", "do not", "stop", "no more", "quit"]
    private static let settingsNegators = chatNegators + ["no", "avoid", "without"]
    private static let verbs = ["respond with", "responding with", "reply with", "replying with", "answer with", "use", "using", "say",
                                "saying", "add", "adding", "put", "putting", "write", "writing", "include", "including", "type", "typing", "with"]
    private static let phraseVerbs: Set<String> = ["say", "saying", "use", "using", "write", "writing", "type", "typing"]

    private static let instructionStarts = [
        "always", "never", "don't", "dont", "do not", "use", "using", "please", "stop", "no more", "quit", "also", "avoid", "keep",
        "write", "say", "add", "make", "be", "try", "give", "answer", "reply", "respond", "call", "put", "include", "start", "end",
        "from now on", "only", "skip", "leave", "stick", "instead", "rather", "otherwise",
    ]

    static func named(_ statement: String) -> String {
        var value = statement
        let context = "(?i)(\\b(?:use|using|avoid|avoiding|no|without|with|the|any|add|adding|put|putting|write|writing|type|typing|include|including)\\s+)"
        let open = "[\"'\u{201C}\u{2018}]"
        let close = "[\"'\u{201D}\u{2019}]"
        for (character, name) in [(emDash, "em dashes"), (enDash, "en dashes"), ("!", "exclamation marks")] {
            let escaped = NSRegularExpression.escapedPattern(for: character)
            value = value.replacingOccurrences(of: context + open + "?" + escaped + "+" + close + "?", with: "$1" + name, options: .regularExpression)
            value = value.replacingOccurrences(of: open + escaped + "+" + close, with: name, options: .regularExpression)
            if character != "!" {
                value = value.replacingOccurrences(of: "(?i)(\\b(?:never|stop|don't|dont|not|quit|ban|more)\\s+)" + escaped + "+(\\s*[.!?]?\\s*)$",
                                                   with: "$1" + name + "$2", options: .regularExpression)
            }
        }
        value = value.replacingOccurrences(of: "(?<=[0-9])" + enDash + "(?=[0-9])", with: "-", options: .regularExpression)
        for character in [emDash, enDash] {
            value = value.replacingOccurrences(of: "\\s*" + character + "+\\s*", with: ", ", options: .regularExpression)
        }
        value = value.replacingOccurrences(of: "(,\\s*){2,}", with: ", ", options: .regularExpression)
        value = value.replacingOccurrences(of: ",\\s*([.!?;:)])", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "^\\s*,\\s*|\\s*,\\s*$", with: "", options: .regularExpression)
        return value.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
    }

    struct Prohibition: Equatable, Sendable {
        let negator: String
        let verb: String?
        let object: String
    }

    static func clauses(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "(?<=[A-Za-z])\u{2019}(?=[A-Za-z])", with: "'", options: .regularExpression)
        var result: [String] = []
        func keep(_ clause: String) {
            let trimmed = clause.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        let joiners: [(match: String, drop: Int)] = [(" but ", 5), (" and always ", 5), (" and use ", 5), (" and instead ", 5),
                                                     (" and rather ", 5), (" and otherwise ", 5)]
        func startsInstruction(_ characters: [Character], from index: Int) -> Bool {
            guard index < characters.count else { return false }
            let rest = String(characters[index...]).trimmingCharacters(in: .whitespaces).lowercased()
            return instructionStarts.contains { start in
                rest.hasPrefix(start) && (rest.count == start.count || !rest[rest.index(rest.startIndex, offsetBy: start.count)].isLetter)
            }
        }
        for line in normalized.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let characters = Array(line.trimmingCharacters(in: .whitespaces))
            if characters.first == ">" { continue }
            var current = ""
            var closing: Character?
            var skip = 0
            for (index, character) in characters.enumerated() {
                if skip > 0 {
                    skip -= 1
                    continue
                }
                let previous: Character = index > 0 ? characters[index - 1] : " "
                let next: Character = index + 1 < characters.count ? characters[index + 1] : " "
                if let close = closing {
                    current.append(character)
                    if character == close && (close != "'" || !next.isLetter) { closing = nil }
                    continue
                }
                switch character {
                case "\"": closing = "\""
                case "\u{201C}": closing = "\u{201D}"
                case "\u{2018}": closing = "\u{2019}"
                case "'" where !previous.isLetter: closing = "'"
                case ".", "?", "!" where next.isWhitespace || index + 1 == characters.count:
                    if character != "?" { keep(current) }
                    current = ""
                    continue
                case "," where startsInstruction(characters, from: index + 1) || String(characters[(index + 1)...]).lowercased().hasPrefix(" but "),
                     ";" where startsInstruction(characters, from: index + 1):
                    keep(current)
                    current = ""
                    continue
                case " ":
                    let ahead = String(characters[index...].prefix(16)).lowercased()
                    if let joiner = joiners.first(where: { ahead.hasPrefix($0.match) }),
                       joiner.match == " but " || startsInstruction(characters, from: index + joiner.drop) {
                        keep(current)
                        current = ""
                        skip = joiner.drop - 1
                        continue
                    }
                default: break
                }
                current.append(character)
            }
            keep(current)
        }
        return result
    }

    static func prohibitions(in text: String, settings: Bool = false) -> [Prohibition] {
        let negators = (settings ? settingsNegators : chatNegators).sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let lead = "^(?:(?:please|and|also|ok|okay|so|now|from now on)[\\s,]+)*(" + negators + ")(?:\\s+(?:ever|again|please))*\\s+(.+)$"
        guard let expression = try? NSRegularExpression(pattern: lead, options: [.caseInsensitive]) else { return [] }
        var found: [Prohibition] = []
        for clause in clauses(text) {
            guard let match = expression.firstMatch(in: clause, range: NSRange(clause.startIndex..., in: clause)),
                  let negatorRange = Range(match.range(at: 1), in: clause), let restRange = Range(match.range(at: 2), in: clause) else { continue }
            let negator = clause[negatorRange].lowercased()
            let rest = String(clause[restRange])
            if let (verb, object) = splitVerb(rest) {
                found.append(Prohibition(negator: negator, verb: verb, object: object))
            } else {
                found.append(Prohibition(negator: negator, verb: nil, object: rest))
            }
        }
        return found
    }

    private static func splitVerb(_ rest: String) -> (String, String)? {
        for verb in verbs.sorted(by: { $0.count > $1.count }) {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: verb) + "(?![A-Za-z'])\\s*(.*)$"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let range = Range(match.range(at: 1), in: rest) else { continue }
            return (verb, String(rest[range]))
        }
        return nil
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let quotedSpan = "(?:^|(?<=[\\s(]))[\"\u{201C}\u{2018}']([^\"\u{201C}\u{201D}\\n]{1,120}?)[\"\u{201D}\u{2019}'](?=$|[\\s.,;:!?)])"

    private static func quotedSpans(_ object: String) -> [(Range<String.Index>, String)] {
        guard let expression = try? NSRegularExpression(pattern: quotedSpan) else { return [] }
        return expression.matches(in: object, range: NSRange(object.startIndex..., in: object)).compactMap { match in
            guard let whole = Range(match.range, in: object), let inner = Range(match.range(at: 1), in: object) else { return nil }
            return (whole, object[inner].trimmingCharacters(in: .whitespaces))
        }
    }

    private static let itemStart = "^(?:the |any |those |these |all |more |your )?(?:em[- ]?dash|en[- ]?dash|long dash|dashes|exclamation|emoji|emoticon|[\"\u{201C}\u{2018}']|\u{2014}|\u{2013}|!)"
    private static let singles: Set<String> = [emDash, enDash, "!"]

    static func check(for text: String, settings: Bool = false) -> NativePreferenceCheck? {
        var chars: [String] = []
        var emoji = false
        var phrases: [String] = []
        func addChar(_ value: String) { if !chars.contains(value) { chars.append(value) } }
        for prohibition in prohibitions(in: text, settings: settings) {
            if prohibition.verb == nil, !matches(prohibition.object, itemStart) { continue }
            let spans = quotedSpans(prohibition.object)
            var bare = prohibition.object
            for (range, inner) in spans.reversed() where !singles.contains(inner) { bare.replaceSubrange(range, with: " ") }
            let genericDashes = matches(bare, "(?<!em )(?<!en )(?<!em-)(?<!en-)(?<!long )\\bdashes\\b")
            if genericDashes || matches(bare, "\\b(?:em[- ]?|long )dash(?:es)?\\b") || bare.contains(emDash) { addChar(emDash) }
            if genericDashes || matches(bare, "\\ben[- ]?dash(?:es)?\\b") || bare.contains(enDash) { addChar(enDash) }
            if matches(bare, "\\bexclamation") || bare.contains("!") { addChar("!") }
            if matches(bare, "\\bemojis?\\b|\\bemoticons?\\b") { emoji = true }
            if let verb = prohibition.verb, phraseVerbs.contains(verb.lowercased()) {
                for (_, inner) in spans where !inner.isEmpty && !singles.contains(inner) && !phrases.contains(inner)
                    && phrases.count < NativePreferenceCheck.maximumItems && inner.count <= NativePreferenceCheck.maximumPhraseCharacters {
                    phrases.append(inner)
                }
            }
        }
        var check = NativePreferenceCheck()
        if !chars.isEmpty { check.forbidChars = chars }
        if emoji { check.forbidEmoji = true }
        if !phrases.isEmpty { check.forbidPhrases = phrases }
        return check.isEmpty || !check.isValid ? nil : check
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

    static let fallbackCharacters = 160
    private static let quoteCharacters: Set<Character> = ["\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "`"]

    static let temporaryScopes = [
        "this time", "for now", "today", "tonight", "this once", "just once", "just this once", "right now", "in this reply",
        "in this message", "here", "for this one", "this answer", "for this conversation",
    ]

    static func hasTemporaryScope(_ text: String) -> Bool {
        let value = NativePreferenceDetector.folded(text).replacingOccurrences(of: "from here on", with: " ")
        return temporaryScopes.contains { scope in
            value.range(of: "(?<![a-z'])" + NSRegularExpression.escapedPattern(for: scope) + "(?![a-z'])", options: .regularExpression) != nil
        }
    }

    static func fallback(for text: String) -> NativePreferenceProposal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= fallbackCharacters, !trimmed.contains(where: \.isNewline),
              !trimmed.contains("```"), let first = clauses(trimmed).first,
              let lead = prohibitions(in: first).first, lead.object == prohibitions(in: trimmed).first?.object,
              !hasTemporaryScope(trimmed), let check = check(for: trimmed) else { return nil }
        var unquoted = trimmed.replacingOccurrences(of: "(?<=[A-Za-z])[\u{2019}'](?=[A-Za-z])", with: "", options: .regularExpression)
        for phrase in (check.forbidPhrases ?? []) + (check.forbidChars ?? []) {
            for (open, close) in [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}")] {
                unquoted = unquoted.replacingOccurrences(of: open + phrase + close, with: " ")
            }
        }
        guard !unquoted.contains(where: { quoteCharacters.contains($0) }) else { return nil }
        return proposal(for: trimmed, check: check)
    }

    static func proposal(for text: String, check: NativePreferenceCheck) -> NativePreferenceProposal? {
        guard let statement = statement(for: check) else { return nil }
        let negators = Set(prohibitions(in: text).map(\.negator))
        let hard = !negators.isDisjoint(with: ["never", "don't", "dont", "do not", "stop", "no more"])
        return NativePreferenceProposal(statement: statement, kind: .style, strength: hard ? .hard : .standing, check: check)
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        if items.count == 2 { return items[0] + " or " + items[1] }
        return items.dropLast().joined(separator: ", ") + ", or " + (items.last ?? "")
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
            Reject anything that is not a lasting preference about the assistant. These are not preferences: "I never thought about it", "don't worry about it", "stop, I need to think", and a one-off instruction about this message only, such as "don't include an intro this time". Anything limited to a moment is one-off, for example "this time", "for now", "today", "tonight", "this once", "just this once", "right now", "in this reply", "in this message", "here", "for this one", "this answer" or "for this conversation". Statements about the person's own life are not preferences either.
            """
        let body = "Message:\n" + String(text.prefix(excerptLimit))
        return [NativeChatMessage(role: "system", content: system), NativeChatMessage(role: "user", content: body)]
    }

    enum Classification: Equatable, Sendable {
        case preference(NativePreferenceProposal)
        case rejected
        case tooLong
        case invalid
    }

    static func classify(_ raw: String?) -> Classification {
        guard let raw, let object = jsonObject(raw), object.count == 1, object.keys.first == "preference",
              let value = object["preference"] else { return .invalid }
        if value is NSNull { return .rejected }
        guard let fields = fields(value) else { return .invalid }
        guard let clean = NativePreferenceStore.cleanStatement(fields.statement) else {
            return NativePreferenceStore.collapsed(fields.statement).count > NativePreferenceStore.maximumStatementCharacters ? .tooLong : .invalid
        }
        return .preference(NativePreferenceProposal(statement: clean, kind: fields.kind, strength: fields.strength, check: fields.check))
    }

    static func parse(_ raw: String?) -> NativePreferenceProposal? {
        guard case .preference(let proposal) = classify(raw) else { return nil }
        return proposal
    }

    private static func fields(_ value: Any) -> NativePreferenceProposal? {
        guard let preference = value as? [String: Any],
              Set(preference.keys).isSubset(of: ["statement", "kind", "strength", "check"]),
              let statement = preference["statement"] as? String,
              let kindRaw = preference["kind"] as? String, let kind = NativePreferenceKind(rawValue: kindRaw),
              let strengthRaw = preference["strength"] as? String, let strength = NativePreferenceStrength(rawValue: strengthRaw),
              let check = NativePreferenceCheck.validated(preference["check"]) else { return nil }
        return NativePreferenceProposal(statement: NativePreferenceRecognizer.named(statement), kind: kind, strength: strength, check: check)
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
    case full
    case tooLong
    case unavailable
    case removed(String)
    case removalFailed

    var note: String? {
        switch self {
        case .none: return nil
        case .saved(let statement):
            return "The person just set a preference and it is saved: \(NativePreferencePrompt.sentence(statement)) Follow it from now on. Acknowledge it in a few words."
        case .failed:
            return "The person asked for a preference but it could not be saved. Tell them plainly it was not saved."
        case .full:
            return "The person asked for a preference but it was not saved because their preference list is full. Tell them the list is full and they can remove one in Settings."
        case .tooLong:
            return "The person asked for a preference but it was too long to save as one. Tell them it was not saved and suggest saying it more briefly or adding it in Settings."
        case .unavailable:
            return "The person asked for a preference but it couldn't be saved right now. Tell them plainly it was not saved and they can try again or add it in Settings."
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
                    classify: @Sendable (String) async -> String?,
                    isCurrent: @Sendable () async -> Bool = { true },
                    stillCurrent: @escaping @Sendable (Database) throws -> Bool = { _ in true }) async -> NativePreferenceCaptureOutcome {
        let key = request.key
        if let existing = try? store.capture(turnID: key.turnID, userMessageID: key.userMessageID) {
            return replayed(existing, store: store)
        }
        if NativePreferenceDetector.isUndo(request.text) {
            guard let previous = request.previousUserMessageID,
                  let earlier = try? store.capture(conversationID: key.conversationID, userMessageID: previous),
                  earlier.outcome == .saved, let preferenceID = earlier.preferenceID,
                  let target = try? store.preference(id: preferenceID), target.status == .active else { return .none }
            guard !Task.isCancelled, await isCurrent() else { return .none }
            do {
                try store.removeCaptured(preferenceID: preferenceID, key: key, stillCurrent: stillCurrent)
            } catch let error as NativePreferenceStoreError where error.reason == .stopped {
                return .none
            } catch {
                return .removalFailed
            }
            guard let after = try? store.preference(id: preferenceID), after.status == .removed else { return .removalFailed }
            return .removed(target.statement)
        }
        guard NativePreferenceDetector.hits(request.text) else { return .none }
        let raw = await classify(request.text)
        guard !Task.isCancelled, await isCurrent() else { return .none }
        var proposal: NativePreferenceProposal
        switch NativePreferenceClassifier.classify(raw) {
        case .preference(let classified):
            proposal = classified
            proposal.check = NativePreferenceCheck.merge(
                deterministic: NativePreferenceRecognizer.check(for: classified.statement, settings: true), classifier: classified.check)
        case .rejected:
            try? store.recordNoCapture(key)
            return .none
        case .tooLong:
            return .tooLong
        case .invalid:
            guard let fallback = NativePreferenceRecognizer.fallback(for: request.text) else { return .unavailable }
            proposal = fallback
        }
        let id: String
        do {
            id = try store.saveCaptured(proposal, quote: request.text, key: key, stillCurrent: stillCurrent)
        } catch let error as NativePreferenceStoreError where error.reason == .stopped {
            return .none
        } catch let error as NativePreferenceStoreError where error.reason == .full {
            return .full
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
    static let maximumCharacters = header.count
        + NativePreferenceStore.maximumActive * (NativePreferenceStore.maximumStatementCharacters + 3)

    static func section(_ statements: [String]) -> String? {
        let lines = statements.compactMap { NativePreferenceStore.cleanStatement($0) }
            .prefix(NativePreferenceStore.maximumActive)
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
