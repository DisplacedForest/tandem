import Foundation
import GRDB

enum NativeRuleScope: Codable, Equatable, Hashable, Sendable {
    case everywhere
    case project(String)
    case conversation(String)
    case task(String)
    case schedule(String)

    var kind: String {
        switch self {
        case .everywhere: return "everywhere"
        case .project: return "project"
        case .conversation: return "conversation"
        case .task: return "task"
        case .schedule: return "schedule"
        }
    }

    var scopeID: String? {
        switch self {
        case .everywhere: return nil
        case .project(let id), .conversation(let id), .task(let id), .schedule(let id): return id
        }
    }

    init?(kind: String, id: String?) {
        switch (kind, id) {
        case ("everywhere", nil): self = .everywhere
        case ("project", let id?): self = .project(id)
        case ("conversation", let id?): self = .conversation(id)
        case ("task", let id?): self = .task(id)
        case ("schedule", let id?): self = .schedule(id)
        default: return nil
        }
    }

    func applies(in context: NativeRuleContext?) -> Bool {
        switch self {
        case .everywhere: return true
        case .project(let id): return context?.projectID == id
        case .conversation(let id): return context?.conversationID == id
        case .task(let id): return context?.taskID == id
        case .schedule(let id): return context?.scheduleID == id
        }
    }
}

enum NativeRuleTargetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case recipient
    case service
    case commandPrefix = "command_prefix"
    case folder
}

struct NativeRuleTarget: Codable, Equatable, Hashable, Sendable {
    let kind: NativeRuleTargetKind
    let value: String

    private init(kind: NativeRuleTargetKind, value: String) {
        self.kind = kind
        self.value = value
    }

    static func normalize(_ value: String, kind: NativeRuleTargetKind) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .recipient, .service:
            return trimmed.lowercased()
        case .commandPrefix:
            return NativeCommandPrefix.normalize(trimmed)
        case .folder:
            guard value.hasPrefix("/") else { return "" }
            var parts: [Substring] = []
            for part in value.split(separator: "/") {
                if part == "." { continue }
                if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
                parts.append(part)
            }
            return "/" + parts.joined(separator: "/")
        }
    }

    static func make(_ kind: NativeRuleTargetKind, _ value: String) -> NativeRuleTarget? {
        let normalized = normalize(value, kind: kind)
        guard !normalized.isEmpty else { return nil }
        return NativeRuleTarget(kind: kind, value: normalized)
    }

    static func folder(_ root: String, contains path: String, restricting: Bool = false) -> Bool {
        let detected = NativeFolderCase.probe.map { $0(path) } ?? NativeFolderCase.sensitivity(near: path)
        let sensitive = detected ?? !restricting
        let rootParts = NativeFolderCase.components(root, sensitive: sensitive)
        let pathParts = NativeFolderCase.components(path, sensitive: sensitive)
        return pathParts.count >= rootParts.count && Array(pathParts.prefix(rootParts.count)) == rootParts
    }

    static func allowed(_ kind: NativeRuleTargetKind, action: NativeActionClass, effect: NativeRuleEffect) -> Bool {
        switch kind {
        case .commandPrefix: return action == .commands && effect == .allow
        case .folder: return action == .fileEdits || action == .trash
        case .recipient, .service: return action == .networkSends
        }
    }

    static func realFolder(_ value: String) -> String? {
        guard value.hasPrefix("/"), let real = NativeCommandClassifier.resolved(value, working: nil), real.hasPrefix("/") else { return nil }
        return real
    }

    static func folder(_ value: String) -> NativeRuleTarget? {
        realFolder(value).flatMap { make(.folder, $0) }
    }

    static func candidate(_ kind: NativeRuleTargetKind, _ value: String) -> NativeRuleTarget? {
        guard kind == .commandPrefix else { return make(kind, value) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NativeRuleTarget(kind: kind, value: trimmed)
    }

    func isSatisfied(by candidate: NativeRuleTarget, restricting: Bool = false) -> Bool {
        guard candidate.kind == kind else { return false }
        switch kind {
        case .recipient, .service:
            return candidate.value == value
        case .commandPrefix:
            return NativeCommandPrefix.isSimple(candidate.value) && NativeCommandPrefix.matches(command: candidate.value, prefix: value)
        case .folder:
            if Self.folder(value, contains: candidate.value, restricting: restricting) { return true }
            return restricting && Self.folder(candidate.value, contains: value, restricting: true)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(NativeRuleTargetKind.self, forKey: .kind)
        let raw = try container.decode(String.self, forKey: .value)
        guard let made = Self.make(kind, raw) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "empty target")
        }
        self = made
    }
}

enum NativeFolderCase {
    @TaskLocal static var probe: (@Sendable (String) -> Bool?)?

    static func components(_ path: String, sensitive: Bool) -> [String] {
        path.split(separator: "/").map { part -> String in
            let canonical = String(part).precomposedStringWithCanonicalMapping
            return sensitive ? canonical : canonical.folding(options: [.caseInsensitive], locale: nil)
        }
    }

    static func sensitivity(near path: String) -> Bool? {
        var url = URL(fileURLWithPath: path)
        while true {
            if FileManager.default.fileExists(atPath: url.path) {
                return (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }
}

enum NativeRuleEffect: String, Codable, CaseIterable, Hashable, Sendable {
    case allow
    case ask
    case handOff = "hand_off"
    case forbid

    var restricts: Bool { self != .allow }

    var strictness: Int {
        switch self {
        case .allow: return 0
        case .ask: return 1
        case .handOff: return 2
        case .forbid: return 3
        }
    }
}

enum NativeRuleOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case settings
    case confirmCard = "confirm_card"
    case chat
    case modelCard = "model_card"
    case migration
}

enum NativeRuleStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case disabled
    case revoked
}

enum NativeRuleRecordError: Error, Equatable, Sendable {
    case emptyStatement
    case statementTooLong
    case missingAction
    case emptyTarget
    case invalidUses
    case invalidTarget
    case emptyScope
    case notFound
    case revoked
}

struct NativeRuleRecord: Codable, Equatable, Identifiable, Sendable {
    static let maximumStatementCharacters = 300

    var id: String
    var scope: NativeRuleScope
    var action: NativeActionClass?
    var toolID: String?
    var target: NativeRuleTarget?
    var effect: NativeRuleEffect
    var statement: String
    var origin: NativeRuleOrigin
    var originConversationID: String?
    var originMessageID: String?
    var originToolCallID: String?
    var quote: String?
    var reason: String?
    var remainingUses: Int?
    var expiresAt: Date?
    var status: NativeRuleStatus
    var createdAt: Date
    var updatedAt: Date
    var revokedAt: Date?

    init(id: String = UUID().uuidString.lowercased(), scope: NativeRuleScope = .everywhere, action: NativeActionClass?,
         toolID: String? = nil, target: NativeRuleTarget? = nil, effect: NativeRuleEffect, statement: String,
         origin: NativeRuleOrigin = .settings, originConversationID: String? = nil, originMessageID: String? = nil, originToolCallID: String? = nil,
         quote: String? = nil, reason: String? = nil, remainingUses: Int? = nil, expiresAt: Date? = nil,
         status: NativeRuleStatus = .active, createdAt: Date = Date(), updatedAt: Date? = nil, revokedAt: Date? = nil) {
        self.id = id
        self.scope = scope
        self.action = action
        self.toolID = toolID
        self.target = target
        self.effect = effect
        self.statement = statement
        self.origin = origin
        self.originConversationID = originConversationID
        self.originMessageID = originMessageID
        self.originToolCallID = originToolCallID
        self.quote = quote
        self.reason = reason
        self.remainingUses = remainingUses
        self.expiresAt = expiresAt
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.revokedAt = revokedAt
    }

    static func validated(_ record: NativeRuleRecord, creating: Bool) throws -> NativeRuleRecord {
        var clean = record
        clean.statement = record.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.statement.isEmpty else { throw NativeRuleRecordError.emptyStatement }
        guard clean.statement.count <= maximumStatementCharacters else { throw NativeRuleRecordError.statementTooLong }
        if let scopeID = clean.scope.scopeID, scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NativeRuleRecordError.emptyScope
        }
        if let toolID = clean.toolID, toolID.isEmpty { clean.toolID = nil }
        if clean.action == nil && clean.target != nil { throw NativeRuleRecordError.missingAction }
        if clean.action == nil && clean.toolID != nil && clean.effect == .allow { throw NativeRuleRecordError.missingAction }
        if clean.originToolCallID != nil && clean.originMessageID == nil { clean.originToolCallID = nil }
        if let action = clean.action, !NativeRuleRecordStore.storedActions.contains(action.rawValue) { throw NativeRuleRecordError.missingAction }
        if let target = clean.target, let action = clean.action {
            guard NativeRuleTarget.allowed(target.kind, action: action, effect: clean.effect) else { throw NativeRuleRecordError.invalidTarget }
            let value = target.kind == .folder ? NativeRuleTarget.realFolder(target.value) : target.value
            guard let value, let normalized = NativeRuleTarget.make(target.kind, value) else { throw NativeRuleRecordError.emptyTarget }
            clean.target = normalized
        }
        if let uses = clean.remainingUses {
            guard clean.effect == .allow, uses >= (creating ? 1 : 0) else { throw NativeRuleRecordError.invalidUses }
        }
        return clean
    }

    static func strictFallback(_ records: [NativeRuleRecord]) -> [NativeRuleRecord] {
        records.filter { $0.effect != .allow }
    }

    var specificity: Int {
        switch (target != nil, toolID != nil) {
        case (true, true): return 3
        case (true, false): return 2
        case (false, true): return 1
        case (false, false): return 0
        }
    }

    func isLive(at now: Date) -> Bool {
        guard status == .active else { return false }
        if let expiresAt, expiresAt <= now { return false }
        if effect == .allow, let remainingUses, remainingUses <= 0 { return false }
        return true
    }

    func applies(to query: NativeRuleQuery, at now: Date) -> Bool {
        guard isLive(at: now) else { return false }
        if let action {
            guard action == query.action else { return false }
        } else {
            guard toolID != nil, effect.restricts else { return false }
        }
        if let toolID, toolID != query.toolID { return false }
        return true
    }

    func matches(_ query: NativeRuleQuery, at now: Date) -> Bool {
        guard applies(to: query, at: now) else { return false }
        if let target, !query.targets.contains(where: { target.isSatisfied(by: $0, restricting: effect.restricts) }) { return false }
        return true
    }
}

struct NativeRuleContext: Codable, Equatable, Hashable, Sendable {
    var conversationID: String
    var projectID: String?
    var taskID: String?
    var scheduleID: String?

    init(conversationID: String, projectID: String? = nil, taskID: String? = nil, scheduleID: String? = nil) {
        self.conversationID = conversationID
        self.projectID = projectID
        self.taskID = taskID
        self.scheduleID = scheduleID
    }
}

struct NativeRuleQuery: Equatable, Sendable {
    var action: NativeActionClass
    var toolID: String?
    var subjects: [[NativeRuleTarget]]

    var targets: [NativeRuleTarget] { subjects.flatMap { $0 } }

    init(action: NativeActionClass, toolID: String? = nil, targets: [NativeRuleTarget] = []) {
        self.action = action
        self.toolID = toolID
        subjects = targets.isEmpty ? [] : [targets]
    }

    init(action: NativeActionClass, toolID: String?, subjects: [[NativeRuleTarget]]) {
        self.action = action
        self.toolID = toolID
        self.subjects = subjects.filter { !$0.isEmpty }
    }

    var parts: [NativeRuleQuery] {
        guard !subjects.isEmpty else { return [self] }
        let split = action == .networkSends ? subjects.flatMap { $0.map { [$0] } } : subjects
        return split.map { NativeRuleQuery(action: action, toolID: toolID, targets: $0) }
    }
}

struct NativeRuleResolution: Equatable, Sendable {
    let decidedBy: NativeRuleRecord
    let overridden: [NativeRuleRecord]
}

enum NativeRuleMatcher {
    static func precedes(_ lhs: NativeRuleRecord, _ rhs: NativeRuleRecord) -> Bool {
        if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
        if lhs.effect.strictness != rhs.effect.strictness { return lhs.effect.strictness > rhs.effect.strictness }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    static func resolve(_ records: [NativeRuleRecord], query: NativeRuleQuery, context: NativeRuleContext?, at now: Date,
                        honoringLimitedUse: Bool) -> NativeRuleResolution? {
        let matching = records.filter { record in
            if !honoringLimitedUse && record.effect == .allow && record.remainingUses != nil { return false }
            return record.scope.applies(in: context) && record.matches(query, at: now)
        }
        guard let winner = matching.sorted(by: precedes).first else { return nil }
        let overridden = matching.filter { $0.specificity < winner.specificity && $0.effect != winner.effect }.sorted(by: precedes)
        return NativeRuleResolution(decidedBy: winner, overridden: overridden)
    }

    static func restrictsUntargeted(_ records: [NativeRuleRecord], query: NativeRuleQuery, context: NativeRuleContext?, at now: Date) -> Bool {
        records.contains { record in
            guard record.effect.restricts, let target = record.target, record.scope.applies(in: context),
                  record.applies(to: query, at: now) else { return false }
            return !query.targets.contains { $0.kind == target.kind }
        }
    }
}

struct NativeRuleRecordStore: Sendable {
    let database: DatabaseQueue
    let now: @Sendable () -> Date

    init(database: DatabaseQueue, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    static let originalActions = ["file_edits", "commands", "trash", "network_sends", "sensitive"]
    static let storedActions = ["file_edits", "commands", "trash", "network_sends", "risky_commands", "reminders", "service_changes", "other_changes",
                                "credential_entry", "payments", "permanent_deletion"]

    static func tableSQL(name: String, actions: [String], cards: Bool = false) -> String {
        let list = actions.map { "'\($0)'" }.joined(separator: ", ")
        let toolCall = cards ? "\n                origin_tool_call_id TEXT," : ""
        let toolWide = cards ? "\n                CHECK(action IS NOT NULL OR tool_id IS NULL OR effect != 'allow'),\n                CHECK(origin_tool_call_id IS NULL OR origin_message_id IS NOT NULL)," : ""
        return """
            CREATE TABLE \(name) (
                id TEXT PRIMARY KEY NOT NULL,
                scope_kind TEXT NOT NULL CHECK(scope_kind IN ('everywhere', 'project', 'conversation', 'task', 'schedule')),
                scope_id TEXT,
                action TEXT CHECK(action IS NULL OR action IN (\(list))),
                tool_id TEXT,
                target_kind TEXT CHECK(target_kind IS NULL OR target_kind IN ('recipient', 'service', 'command_prefix', 'folder')),
                target_value TEXT,
                effect TEXT NOT NULL CHECK(effect IN ('allow', 'ask', 'hand_off', 'forbid')),
                statement TEXT NOT NULL,
                origin TEXT NOT NULL CHECK(origin IN ('settings', 'confirm_card', 'chat', 'model_card', 'migration')),
                origin_conversation_id TEXT,
                origin_message_id TEXT,\(toolCall)
                quote TEXT,
                reason TEXT,
                remaining_uses INTEGER CHECK(remaining_uses IS NULL OR (remaining_uses >= 0 AND effect = 'allow')),
                expires_at DOUBLE,
                status TEXT NOT NULL CHECK(status IN ('active', 'disabled', 'revoked')),
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL,
                revoked_at DOUBLE,
                CHECK((scope_kind = 'everywhere') = (scope_id IS NULL)),
                CHECK((target_kind IS NULL) = (target_value IS NULL)),\(toolWide)
                CHECK(target_kind IS NULL
                      OR (target_kind = 'command_prefix' AND action = 'commands' AND effect = 'allow')
                      OR (target_kind = 'folder' AND action IN ('file_edits', 'trash'))
                      OR (target_kind IN ('recipient', 'service') AND action = 'network_sends'))
            );
            """
    }

    static let indexSQL = """
            CREATE INDEX native_rule_records_status_action ON native_rule_records(status, action);
            CREATE UNIQUE INDEX native_rule_records_origin_message ON native_rule_records(origin_message_id) WHERE origin_message_id IS NOT NULL;
            """

    static func migrate(_ db: Database) throws {
        try db.execute(sql: tableSQL(name: "native_rule_records", actions: originalActions))
        try db.execute(sql: indexSQL)
        try db.execute(sql: """
            CREATE TABLE native_rule_version (
                id INTEGER PRIMARY KEY CHECK(id = 1),
                value INTEGER NOT NULL
            );
            INSERT INTO native_rule_version(id, value) VALUES(1, 0);
            """)
    }

    static func migrateActions(_ db: Database) throws {
        let kept = storedActions.map { "'\($0)'" }.joined(separator: ", ")
        let dropped = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_rule_records WHERE action IS NOT NULL AND action NOT IN (\(kept))") ?? 0
        try db.execute(sql: tableSQL(name: "native_rule_records_next", actions: storedActions))
        try db.execute(sql: """
            INSERT INTO native_rule_records_next(\(originalColumns))
            SELECT \(originalColumns) FROM native_rule_records WHERE action IS NULL OR action IN (\(kept));
            DROP TABLE native_rule_records;
            ALTER TABLE native_rule_records_next RENAME TO native_rule_records;
            """)
        try db.execute(sql: indexSQL)
        if dropped > 0 { _ = try advanceVersion(db) }
    }

    static let cardIndexSQL = """
            CREATE INDEX native_rule_records_status_action ON native_rule_records(status, action);
            CREATE UNIQUE INDEX native_rule_records_origin_message ON native_rule_records(origin_message_id, COALESCE(origin_tool_call_id, ''))
                WHERE origin_message_id IS NOT NULL;
            """

    static func migrateCards(_ db: Database) throws {
        try db.execute(sql: tableSQL(name: "native_rule_records_next", actions: storedActions, cards: true))
        try db.execute(sql: """
            INSERT INTO native_rule_records_next(\(originalColumns))
            SELECT \(originalColumns) FROM native_rule_records;
            DROP TABLE native_rule_records;
            ALTER TABLE native_rule_records_next RENAME TO native_rule_records;
            """)
        try db.execute(sql: cardIndexSQL)
    }

    static func migratePrefixes(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, rules_json FROM conversations WHERE rules_json IS NOT NULL")
        let stamp = Date()
        var inserted = 0
        for row in rows {
            guard let conversationID: String = row["id"], let raw: String = row["rules_json"], let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any],
                  let listed = json["approved_command_prefixes"] else { continue }
            var prefixes: [NativeRuleTarget] = []
            var lost = false
            for value in (listed as? [Any]) ?? [] {
                guard let text = value as? String, !text.isEmpty, let target = NativeRuleTarget.make(.commandPrefix, text),
                      !prefixes.contains(target) else { continue }
                prefixes.append(target)
            }
            for prefix in prefixes {
                let named = "In this chat, allow commands that start with \(prefix.value)"
                let draft = NativeRuleRecord(scope: .conversation(conversationID), action: .commands, toolID: NativeCommandTools.toolID,
                                             target: prefix, effect: .allow,
                                             statement: named.count <= NativeRuleRecord.maximumStatementCharacters ? named : "In this chat, allow a command you approved earlier",
                                             origin: .migration, originConversationID: conversationID,
                                             reason: "Carried over from an approval you gave in this chat.", createdAt: stamp)
                guard let record = try? NativeRuleRecord.validated(draft, creating: true) else { lost = true; continue }
                try write(db, record, inserting: true)
                inserted += 1
            }
            if lost { continue }
            let kept = NativeConversationRules.encode(NativeConversationRules.decode(raw))
            try db.execute(sql: "UPDATE conversations SET rules_json = ? WHERE id = ?", arguments: [kept, conversationID])
        }
        if inserted > 0 { _ = try advanceVersion(db) }
    }

    private static let originalColumns = """
        id, scope_kind, scope_id, action, tool_id, target_kind, target_value, effect, statement, origin, origin_conversation_id,
        origin_message_id, quote, reason, remaining_uses, expires_at, status, created_at, updated_at, revoked_at
        """

    private static let columns = originalColumns + ", origin_tool_call_id"

    private static func decode(_ row: Row) -> NativeRuleRecord? {
        guard let id: String = row["id"], let scopeKind: String = row["scope_kind"],
              let scope = NativeRuleScope(kind: scopeKind, id: row["scope_id"]),
              let effect = NativeRuleEffect(rawValue: row["effect"] ?? ""),
              let origin = NativeRuleOrigin(rawValue: row["origin"] ?? ""),
              let status = NativeRuleStatus(rawValue: row["status"] ?? ""),
              let statement: String = row["statement"] else { return nil }
        let rawAction: String? = row["action"]
        let action = rawAction.flatMap(NativeActionClass.init(rawValue:))
        if rawAction != nil && action == nil { return nil }
        var target: NativeRuleTarget?
        if let kindRaw: String = row["target_kind"], let value: String = row["target_value"] {
            guard let kind = NativeRuleTargetKind(rawValue: kindRaw), let made = NativeRuleTarget.make(kind, value) else { return nil }
            target = made
        }
        let expires: Double? = row["expires_at"]
        let revoked: Double? = row["revoked_at"]
        let created: Double = row["created_at"] ?? 0
        let updated: Double = row["updated_at"] ?? 0
        return NativeRuleRecord(id: id, scope: scope, action: action, toolID: row["tool_id"], target: target, effect: effect,
                                statement: statement, origin: origin, originConversationID: row["origin_conversation_id"],
                                originMessageID: row["origin_message_id"], originToolCallID: row["origin_tool_call_id"], quote: row["quote"], reason: row["reason"],
                                remainingUses: row["remaining_uses"], expiresAt: expires.map(Date.init(timeIntervalSince1970:)),
                                status: status, createdAt: Date(timeIntervalSince1970: created),
                                updatedAt: Date(timeIntervalSince1970: updated), revokedAt: revoked.map(Date.init(timeIntervalSince1970:)))
    }

    private static func fetch(_ db: Database, id: String) throws -> NativeRuleRecord? {
        try Row.fetchOne(db, sql: "SELECT \(columns) FROM native_rule_records WHERE id = ?", arguments: [id]).flatMap(decode)
    }

    private static func fetch(_ db: Database, originMessageID: String, originToolCallID: String? = nil) throws -> NativeRuleRecord? {
        try Row.fetchOne(db, sql: "SELECT \(columns) FROM native_rule_records WHERE origin_message_id = ? AND COALESCE(origin_tool_call_id, '') = ?",
                         arguments: [originMessageID, originToolCallID ?? ""])
            .flatMap(decode)
    }

    private static func write(_ db: Database, _ record: NativeRuleRecord, inserting: Bool) throws {
        let arguments: StatementArguments = [
            record.scope.kind, record.scope.scopeID, record.action?.rawValue, record.toolID, record.target?.kind.rawValue,
            record.target?.value, record.effect.rawValue, record.statement, record.origin.rawValue, record.originConversationID,
            record.originMessageID, record.quote, record.reason, record.remainingUses, record.expiresAt?.timeIntervalSince1970,
            record.status.rawValue, record.createdAt.timeIntervalSince1970, record.updatedAt.timeIntervalSince1970,
            record.revokedAt?.timeIntervalSince1970, record.originToolCallID, record.id,
        ]
        if inserting {
            try db.execute(sql: """
                INSERT INTO native_rule_records(scope_kind, scope_id, action, tool_id, target_kind, target_value, effect, statement, origin,
                    origin_conversation_id, origin_message_id, quote, reason, remaining_uses, expires_at, status, created_at, updated_at,
                    revoked_at, origin_tool_call_id, id)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: arguments)
        } else {
            try db.execute(sql: """
                UPDATE native_rule_records SET scope_kind = ?, scope_id = ?, action = ?, tool_id = ?, target_kind = ?, target_value = ?,
                    effect = ?, statement = ?, origin = ?, origin_conversation_id = ?, origin_message_id = ?, quote = ?, reason = ?,
                    remaining_uses = ?, expires_at = ?, status = ?, created_at = ?, updated_at = ?, revoked_at = ?,
                    origin_tool_call_id = ?
                WHERE id = ?
                """, arguments: arguments)
        }
    }

    @discardableResult
    func add(_ record: NativeRuleRecord) throws -> NativeRuleRecord {
        var clean = try NativeRuleRecord.validated(record, creating: true)
        let stamp = now()
        clean.status = .active
        clean.createdAt = stamp
        clean.updatedAt = stamp
        clean.revokedAt = nil
        let prepared = clean
        return try database.write { db in
            if let message = prepared.originMessageID,
               let existing = try Self.fetch(db, originMessageID: message, originToolCallID: prepared.originToolCallID) { return existing }
            try Self.write(db, prepared, inserting: true)
            _ = try Self.advanceVersion(db)
            guard let stored = try Self.fetch(db, id: prepared.id) else { throw NativeRuleRecordError.notFound }
            return stored
        }
    }

    @discardableResult
    func update(id: String, _ mutate: (inout NativeRuleRecord) -> Void) throws -> NativeRuleRecord {
        let stamp = now()
        return try database.write { db in
            guard let current = try Self.fetch(db, id: id) else { throw NativeRuleRecordError.notFound }
            guard current.status != .revoked else { throw NativeRuleRecordError.revoked }
            var next = current
            mutate(&next)
            next.id = current.id
            next.status = current.status
            next.createdAt = current.createdAt
            next.revokedAt = current.revokedAt
            next.updatedAt = stamp
            let clean = try NativeRuleRecord.validated(next, creating: false)
            try Self.write(db, clean, inserting: false)
            _ = try Self.advanceVersion(db)
            guard let stored = try Self.fetch(db, id: id) else { throw NativeRuleRecordError.notFound }
            return stored
        }
    }

    private func transition(id: String, to status: NativeRuleStatus, from allowed: [NativeRuleStatus]) throws -> Bool {
        let stamp = now().timeIntervalSince1970
        let placeholders = allowed.map { _ in "?" }.joined(separator: ", ")
        var arguments: StatementArguments = [status.rawValue, stamp, status == .revoked ? stamp : nil, id]
        arguments += StatementArguments(allowed.map(\.rawValue))
        let sql: String = "UPDATE native_rule_records SET status = ?, updated_at = ?, revoked_at = COALESCE(?, revoked_at) WHERE id = ? AND status IN (\(placeholders))"
        return try database.write { db in
            try db.execute(sql: sql, arguments: arguments)
            guard db.changesCount == 1 else { return false }
            _ = try Self.advanceVersion(db)
            return true
        }
    }

    @discardableResult
    func disable(id: String) throws -> Bool { try transition(id: id, to: .disabled, from: [.active]) }

    @discardableResult
    func enable(id: String) throws -> Bool { try transition(id: id, to: .active, from: [.disabled]) }

    @discardableResult
    func revoke(id: String) throws -> Bool { try transition(id: id, to: .revoked, from: [.active, .disabled]) }

    static func consume(_ db: Database, id: String, at date: Date) throws -> Bool {
        try db.execute(sql: """
            UPDATE native_rule_records SET remaining_uses = remaining_uses - 1
            WHERE id = ? AND status = 'active' AND remaining_uses IS NOT NULL AND remaining_uses > 0
                AND (expires_at IS NULL OR expires_at > ?)
            """, arguments: [id, date.timeIntervalSince1970])
        guard db.changesCount == 1 else { return false }
        _ = try advanceVersion(db)
        return true
    }

    enum Authorization: Equatable, Sendable {
        case authorized
        case spent
        case stale
    }

    static func authorize(_ db: Database, id: String, at date: Date) throws -> Authorization {
        guard let record = try fetch(db, id: id) else { return .spent }
        guard record.status == .active, record.effect == .allow else { return .stale }
        if let expires = record.expiresAt, expires <= date { return .stale }
        guard let uses = record.remainingUses else { return .authorized }
        guard uses > 0 else { return .spent }
        return try consume(db, id: id, at: date) ? .authorized : .spent
    }

    static func version(_ db: Database) throws -> Int {
        guard let value = try Int.fetchOne(db, sql: "SELECT value FROM native_rule_version WHERE id = 1") else {
            throw NativeRuleRecordError.notFound
        }
        return value
    }

    static func advanceVersion(_ db: Database) throws -> Int {
        try db.execute(sql: "INSERT INTO native_rule_version(id, value) VALUES(1, 1) ON CONFLICT(id) DO UPDATE SET value = value + 1")
        return try version(db)
    }

    func confirm(revision: Int, authorizing ids: [String]) throws -> Authorization {
        try database.write { db in
            guard try Self.version(db) == revision else { return .stale }
            let current = now()
            var outcome = Authorization.authorized
            try db.inSavepoint {
                for id in Set(ids).sorted() {
                    let result = try Self.authorize(db, id: id, at: current)
                    if result != .authorized {
                        outcome = result
                        return .rollback
                    }
                }
                return .commit
            }
            return outcome
        }
    }

    func consume(id: String) throws -> Bool {
        let stamp = now()
        return try database.write { db in try Self.consume(db, id: id, at: stamp) }
    }

    @discardableResult
    func expireDue() throws -> Int {
        let stamp = now().timeIntervalSince1970
        return try database.write { db in
            try db.execute(sql: """
                UPDATE native_rule_records SET status = 'revoked', revoked_at = ?, updated_at = ?
                WHERE status = 'active' AND expires_at IS NOT NULL AND expires_at <= ?
                """, arguments: [stamp, stamp, stamp])
            let count = db.changesCount
            if count > 0 { _ = try Self.advanceVersion(db) }
            return count
        }
    }

    func all() throws -> [NativeRuleRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.columns) FROM native_rule_records ORDER BY created_at, id").compactMap(Self.decode)
        }
    }

    func active() throws -> [NativeRuleRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.columns) FROM native_rule_records WHERE status = 'active' ORDER BY created_at, id")
                .compactMap(Self.decode)
        }
    }

    func record(id: String) throws -> NativeRuleRecord? {
        try database.read { db in try Self.fetch(db, id: id) }
    }

    func record(originMessageID: String) throws -> NativeRuleRecord? {
        try database.read { db in try Self.fetch(db, originMessageID: originMessageID) }
    }

    func advanceVersion() throws -> Int {
        try database.write { db in try Self.advanceVersion(db) }
    }

    func version() throws -> Int {
        try database.read { db in try Self.version(db) }
    }

    func snapshot() throws -> (records: [NativeRuleRecord], version: Int) {
        try database.read { db in
            let records = try Row.fetchAll(db, sql: "SELECT \(Self.columns) FROM native_rule_records WHERE status = 'active' ORDER BY created_at, id")
                .compactMap(Self.decode)
            return (records, try Self.version(db))
        }
    }
}
