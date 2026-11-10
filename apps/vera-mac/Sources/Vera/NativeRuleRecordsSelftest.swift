import Foundation
import GRDB

final class NativeRuleRecordsCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}

@MainActor
enum NativeRuleRecordsSelftest {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func run() async throws {
        let counter = NativeRuleRecordsCounter()
        let require: (Bool, String) throws -> Void = { condition, name in
            try NativeTaskFixture.require(condition, name)
            counter.bump()
        }
        try roundTrip(require)
        try migrationOnV34(require)
        try validation(require)
        try duplicates(require)
        try precedence(require)
        try scopes(require)
        try inactive(require)
        try sensitiveAndText(require)
        try limitedUse(require)
        try await consumeOnce(require)
        try sourceRevisions(require)
        try restart(require)
        try targets(require)
        try unboundedCounter(require)
        try durableVersions(require)
        try await commandToolID(require)
        try await typedTargets(require)
        try await realFolderTargets(require)
        try await foregroundBoundary(require)
        try await everySubject(require)
        try targetKinds(require)
        try await footprints(require)
        try await lateConfirmation(require)
        try await caseAndForm(require)
        try await boundFootprint(require)
        try await creationRace(require)
        try await significantWhitespace(require)
        try prefixApprovalShortcut(require)
        try await commandValidationFirst(require)
        try await rememberedApprovals(require)
        try await longNames(require)
        try useLimits(require)
        try strictReload(require)
        try projectMap(require)
        try await storeScenario(require)
        print("NATIVE RULE RECORDS SELFTEST OK (\(counter.value) checks)")
    }

    static func store(_ repository: LocalChatRepository, clock: NativeEffectTestClock) -> NativeRuleRecordStore {
        NativeRuleRecordStore(database: repository.database, now: { clock.now })
    }

    static func resolver(_ records: [NativeRuleRecord], context: NativeRuleContext? = NativeRuleContext(conversationID: "c1"),
                         global: NativeRules = .defaults, now: Date = start) -> NativeRuleResolver {
        NativeRuleResolver(global: global, conversation: NativeConversationRules(), requestText: "", records: records, context: context, now: now)
    }

    static func record(_ effect: NativeRuleEffect, _ action: NativeActionClass? = .networkSends, scope: NativeRuleScope = .everywhere,
                       tool: String? = nil, target: NativeRuleTarget? = nil, uses: Int? = nil, expires: Date? = nil,
                       status: NativeRuleStatus = .active, updated: Date = start, statement: String = "A saved rule") -> NativeRuleRecord {
        NativeRuleRecord(scope: scope, action: action, toolID: tool, target: target, effect: effect, statement: statement,
                         remainingUses: uses, expiresAt: expires, status: status, createdAt: start, updatedAt: updated)
    }

    static func recipient(_ value: String) -> NativeRuleTarget { NativeRuleTarget.make(.recipient, value)! }

    private static func roundTrip(_ require: (Bool, String) throws -> Void) throws {
        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(start)
        let first = store(repository, clock: clock)
        let second = store(repository, clock: clock)
        let scopes: [NativeRuleScope] = [.everywhere, .project("p1"), .conversation("c1"), .task("t1"), .schedule("s1")]
        var saved: [NativeRuleRecord] = []
        for effect in NativeRuleEffect.allCases {
            for scope in scopes {
                saved.append(try first.add(NativeRuleRecord(scope: scope, action: .networkSends, toolID: "mail", target: recipient(" Alice@Example.com "),
                                                            effect: effect, statement: "  Send to Alice  ", origin: .chat,
                                                            originConversationID: "c1", quote: "you can email alice", reason: "asked in chat",
                                                            remainingUses: effect == .allow ? 3 : nil, expiresAt: start.addingTimeInterval(3600))))
            }
        }
        let read = try second.all()
        try require(read.count == 20 && Set(read.map(\.effect)) == Set(NativeRuleEffect.allCases)
                    && Set(read.map(\.scope.kind)) == ["everywhere", "project", "conversation", "task", "schedule"],
                    "Every effect and every scope kind is stored")
        for record in saved {
            try require(try second.record(id: record.id) == record, "A record reads back identically through a second store: \(record.effect.rawValue) \(record.scope.kind)")
        }
        try require(saved.allSatisfy { $0.statement == "Send to Alice" && $0.target?.value == "alice@example.com" && $0.status == .active
                        && $0.createdAt == start && $0.updatedAt == start },
                    "The store trims the statement, normalizes the target and stamps the record")
        let textOnly = try first.add(NativeRuleRecord(action: nil, effect: .ask, statement: "Check with me before booking travel"))
        try require(try second.all().contains(textOnly) && (try second.active()).contains(textOnly), "A text-only rule is stored and listed")
        let encoded = try JSONEncoder().encode(saved[7])
        try require(try JSONDecoder().decode(NativeRuleRecord.self, from: encoded) == saved[7], "A record round-trips through Codable")
    }

    private static func migrationOnV34(_ require: (Bool, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rule-records-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vera.sqlite")
        do {
            let repository = try LocalChatRepository(url: url, artifactDirectory: directory.appendingPathComponent("artifacts"),
                                                     projectsDirectory: directory.appendingPathComponent("projects"))
            try repository.database.write { db in
                try db.execute(sql: "DROP TABLE native_rule_records")
                try db.execute(sql: "DROP TABLE native_rule_version")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'nativeRuleRecordsV35'")
            }
            let state = try repository.database.read { db in
                (try db.tableExists("native_preferences"), try db.tableExists("native_rule_records"),
                 try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
            }
            try require(state.0 && !state.1 && state.2.contains("nativePreferencesV34") && !state.2.contains("nativeRuleRecordsV35"),
                        "The fixture database is at V34")
        }
        let reopened = try LocalChatRepository(url: url, artifactDirectory: directory.appendingPathComponent("artifacts"),
                                               projectsDirectory: directory.appendingPathComponent("projects"))
        let migrated = try reopened.database.read { db in
            (try db.tableExists("native_rule_records"), try Int.fetchOne(db, sql: "SELECT value FROM native_rule_version WHERE id = 1"),
             try db.columns(in: "native_rule_records").map(\.name))
        }
        try require(migrated.0 && migrated.1 == 0, "V35 applies on top of a V34 database with the rules version at zero")
        try require(Set(migrated.2) == ["id", "scope_kind", "scope_id", "action", "tool_id", "target_kind", "target_value", "effect", "statement",
                                        "origin", "origin_conversation_id", "origin_message_id", "quote", "reason", "remaining_uses", "expires_at",
                                        "status", "created_at", "updated_at", "revoked_at"], "The rule record table has its columns")
        var rejected = false
        do {
            try reopened.database.write { db in
                try db.execute(sql: """
                    INSERT INTO native_rule_records(id, scope_kind, effect, statement, origin, status, created_at, updated_at)
                    VALUES('x', 'everywhere', 'maybe', 's', 'settings', 'active', 0, 0)
                    """)
            }
        } catch { rejected = true }
        try require(rejected, "The table rejects an unknown effect")
    }

    private static func validation(_ require: (Bool, String) throws -> Void) throws {
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let invalid: [(NativeRuleRecord, NativeRuleRecordError, String)] = [
            (record(.allow, statement: "   \n"), .emptyStatement, "An empty statement is rejected"),
            (record(.allow, statement: String(repeating: "a", count: 301)), .statementTooLong, "An over-long statement is rejected"),
            (record(.allow, nil, target: recipient("alice")), .missingAction, "A target without an action is rejected"),
            (record(.allow, nil, tool: "mail"), .missingAction, "A tool without an action is rejected"),
            (record(.allow, uses: 0), .invalidUses, "Zero uses is rejected"),
            (record(.allow, scope: .task("  ")), .emptyScope, "An empty scope id is rejected"),
        ]
        for (candidate, expected, name) in invalid {
            var caught: NativeRuleRecordError?
            do { try records.add(candidate) } catch let error as NativeRuleRecordError { caught = error }
            try require(caught == expected, name)
        }
        try require(NativeRuleTarget.make(.recipient, "   ") == nil && NativeRuleTarget.make(.folder, "relative/path") == nil,
                    "An empty or relative target never normalizes")
        try require(try records.all().isEmpty, "No rejected record reaches the table")
        try require(record(.allow, statement: String(repeating: "a", count: 300)).statement.count == 300
                    && (try? NativeRuleRecord.validated(record(.allow, statement: String(repeating: "a", count: 300)), creating: true)) != nil,
                    "A statement of exactly 300 characters is allowed")
        let saved = try records.add(record(.allow))
        var updateRejected = false
        do { try records.update(id: saved.id) { $0.statement = "" } } catch { updateRejected = true }
        try require(updateRejected && (try records.record(id: saved.id))?.statement == "A saved rule", "An update is validated too")
    }

    private static func duplicates(_ require: (Bool, String) throws -> Void) throws {
        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(start)
        let records = store(repository, clock: clock)
        var first = record(.allow, statement: "Email Alice without asking")
        first.originMessageID = "message-1"
        let saved = try records.add(first)
        clock.advance(5)
        var replay = record(.forbid, statement: "Something else")
        replay.originMessageID = "message-1"
        let again = try records.add(replay)
        try require(again == saved && (try records.all()).count == 1 && (try records.record(originMessageID: "message-1")) == saved,
                    "A duplicate origin message returns the first record and saves nothing new")
    }

    private static func precedence(_ require: (Bool, String) throws -> Void) throws {
        let alice = recipient("alice@example.com")
        let bob = recipient("bob@example.com")
        let toAlice = NativeRuleQuery(action: .networkSends, toolID: "mail", targets: [alice])
        let toBob = NativeRuleQuery(action: .networkSends, toolID: "mail", targets: [bob])

        let narrow = resolver([record(.allow, target: alice)])
        try require(narrow.resolve(toAlice, honoringLimitedUse: false).decision == .act(.grant), "A recipient allow acts for that recipient")
        let other = narrow.resolve(toBob, honoringLimitedUse: false)
        try require(other.decision == .handOff && other.resolution == nil, "Another recipient falls back to the class default")
        try require(narrow.decision(for: .networkSends) == .handOff, "A class-level decision ignores the recipient allow")

        let forbid = record(.forbid)
        let override = resolver([forbid, record(.allow, target: alice)])
        let allowed = override.resolve(toAlice, honoringLimitedUse: false)
        try require(allowed.decision == .act(.grant) && allowed.resolution?.overridden == [forbid],
                    "A narrower allow beats a broader forbid for its own target and lists the forbid as overridden")
        let blocked = override.resolve(toBob, honoringLimitedUse: false)
        try require(blocked.decision == .handOff && blocked.resolution?.decidedBy.effect == .forbid,
                    "The broader forbid still holds for everyone else, and the caller can tell it is a forbid")

        let sameSubject = resolver([record(.allow, target: alice, updated: start.addingTimeInterval(60)), record(.forbid, target: alice)])
        let tied = sameSubject.resolve(toAlice, honoringLimitedUse: false)
        try require(tied.decision == .handOff && tied.resolution?.decidedBy.effect == .forbid && tied.resolution?.overridden == [],
                    "Forbid and allow on the same subject resolve to forbid even when the allow is newer")

        let newer = resolver([record(.ask, target: alice), record(.ask, target: alice, updated: start.addingTimeInterval(60), statement: "Newer")])
        try require(newer.resolve(toAlice, honoringLimitedUse: false).resolution?.decidedBy.statement == "Newer",
                    "On a full tie the most recently updated record decides")

        let carveOut = resolver([record(.allow), record(.forbid, target: alice)])
        try require(carveOut.resolve(toAlice, honoringLimitedUse: false).resolution?.decidedBy.effect == .forbid
                    && carveOut.resolve(toBob, honoringLimitedUse: false).decision == .act(.grant),
                    "A narrower forbid blocks its target while a broader allow covers the rest")

        let tooled = resolver([record(.forbid), record(.allow, tool: "mail")])
        try require(tooled.resolve(NativeRuleQuery(action: .networkSends, toolID: "mail"), honoringLimitedUse: false).decision == .act(.grant)
                    && tooled.resolve(NativeRuleQuery(action: .networkSends, toolID: "chat"), honoringLimitedUse: false).decision == .handOff,
                    "A tool-level record beats a class-level one")

        let both = resolver([record(.forbid, target: alice), record(.allow, tool: "mail", target: alice)])
        let exact = both.resolve(toAlice, honoringLimitedUse: false)
        try require(exact.decision == .act(.grant) && exact.resolution?.decidedBy.specificity == 3,
                    "A target plus tool record beats the target alone")
        try require(both.resolve(NativeRuleQuery(action: .networkSends, toolID: "chat", targets: [alice]), honoringLimitedUse: false)
                        .resolution?.decidedBy.effect == .forbid, "Without the tool, the target-only record decides")

        let classAllow = resolver([record(.allow, .trash)])
        try require(classAllow.decision(for: .trash) == .act(.grant), "A class-level standing allow applies through decision(for:)")
        let classAsk = resolver([record(.ask, .fileEdits)])
        try require(classAsk.decision(for: .fileEdits) == .ask, "A class-level ask tightens a class that acts by default")

        let prefix = resolver([record(.allow, .commands, target: NativeRuleTarget.make(.commandPrefix, "swift   build --verbose"))])
        try require(prefix.decision(forCommand: "swift build --configuration release") == .act(.grant),
                    "A command prefix record lets matching simple commands run")
        try require(prefix.decision(forCommand: "swift build; rm -rf x") == .ask && prefix.decision(forCommand: "swift test") == .ask,
                    "A compound or different command falls back to the class default")
        let chatPrefix = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(approvedCommandPrefixes: ["make check"]),
                                            requestText: "", records: [], context: NativeRuleContext(conversationID: "c1"))
        try require(chatPrefix.decision(forCommand: "make check") == .act(.conversationPrefix), "Without records the chat prefix logic is unchanged")
    }

    private static func scopes(_ require: (Bool, String) throws -> Void) throws {
        let cases: [(NativeRuleScope, NativeRuleContext, NativeRuleContext, String)] = [
            (.task("t1"), NativeRuleContext(conversationID: "c1", taskID: "t1"), NativeRuleContext(conversationID: "c1"), "task"),
            (.conversation("c9"), NativeRuleContext(conversationID: "c9"), NativeRuleContext(conversationID: "c1"), "conversation"),
            (.project("p1"), NativeRuleContext(conversationID: "c1", projectID: "p1"), NativeRuleContext(conversationID: "c1", projectID: "p2"), "project"),
            (.schedule("s1"), NativeRuleContext(conversationID: "c1", scheduleID: "s1"), NativeRuleContext(conversationID: "c1"), "schedule"),
        ]
        for (scope, inside, outside, name) in cases {
            let records = [record(.allow, .trash, scope: scope)]
            try require(resolver(records, context: inside).decision(for: .trash) == .act(.grant), "A \(name)-scoped allow applies inside its \(name)")
            try require(resolver(records, context: outside).decision(for: .trash) == .ask, "A \(name)-scoped allow does not apply outside its \(name)")
        }
        try require(resolver([record(.allow, .trash, scope: .task("t1"))], context: nil).decision(for: .trash) == .ask,
                    "A scoped record never applies without a context")
        try require(resolver([record(.allow, .trash)], context: nil).decision(for: .trash) == .act(.grant), "An everywhere record applies without a context")
    }

    private static func inactive(_ require: (Bool, String) throws -> Void) throws {
        let records = [record(.allow, .trash, expires: start), record(.allow, .trash, expires: start.addingTimeInterval(-1)),
                       record(.allow, .trash, status: .disabled), record(.allow, .trash, status: .revoked)]
        try require(resolver(records).decision(for: .trash) == .ask, "Expired, disabled and revoked records never affect a decision")
        try require(resolver([record(.allow, .trash, expires: start.addingTimeInterval(1))]).decision(for: .trash) == .act(.grant),
                    "A record that has not expired yet still applies")
        try require(resolver([record(.allow, .trash, uses: 2)]).resolve(NativeRuleQuery(action: .trash), honoringLimitedUse: true).decision == .act(.grant)
                    && resolver([record(.allow, .trash, uses: 1)]).resolve(NativeRuleQuery(action: .trash), honoringLimitedUse: true).decision == .act(.grant),
                    "A limited record with uses left applies when limited use is honored")
        var spent = record(.allow, .trash, uses: 1)
        spent.remainingUses = 0
        try require(resolver([spent]).resolve(NativeRuleQuery(action: .trash), honoringLimitedUse: true).resolution == nil,
                    "A spent record never matches")
    }

    private static func sensitiveAndText(_ require: (Bool, String) throws -> Void) throws {
        let sensitive = resolver([record(.allow, .sensitive), record(.allow, .sensitive, tool: "vault")])
        let resolved = sensitive.resolve(NativeRuleQuery(action: .sensitive, toolID: "vault"), honoringLimitedUse: true)
        try require(sensitive.decision(for: .sensitive) == .handOff && resolved.decision == .handOff && resolved.resolution == nil,
                    "A record on the sensitive class changes nothing")
        let text = resolver([record(.allow, nil, statement: "You can always trash my downloads")])
        try require(text.decision(for: .trash) == .ask && text.resolve(NativeRuleQuery(action: .trash), honoringLimitedUse: true).resolution == nil,
                    "A text-only record never matches")
    }

    private static func limitedUse(_ require: (Bool, String) throws -> Void) throws {
        let limited = resolver([record(.allow, .trash, uses: 3)])
        try require(limited.decision(for: .trash) == .ask, "decision(for:) ignores limited-use records")
        let honored = limited.resolve(NativeRuleQuery(action: .trash), honoringLimitedUse: true)
        try require(honored.decision == .act(.grant) && honored.resolution?.decidedBy.remainingUses == 3,
                    "resolve honoring limited use lets a limited record decide")
        try require(limited.resolve(NativeRuleQuery(action: .trash), honoringLimitedUse: false).resolution == nil,
                    "resolve without honoring limited use ignores it")
    }

    private static func consumeOnce(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(start)
        let records = store(repository, clock: clock)
        let single = try records.add(record(.allow, .trash, uses: 1))
        try require(try records.consume(id: single.id), "A one-use record is consumed once")
        try require(try !records.consume(id: single.id) && (try records.record(id: single.id))?.remainingUses == 0,
                    "A second consume fails and the count stays at zero")
        let unlimited = try records.add(record(.allow, .trash))
        try require(try !records.consume(id: unlimited.id) && !(try records.consume(id: "missing")),
                    "An unlimited or missing record cannot be consumed")
        let disabled = try records.add(record(.allow, .trash, uses: 2))
        try records.disable(id: disabled.id)
        try require(try !records.consume(id: disabled.id), "A disabled record cannot be consumed")
        let expiring = try records.add(record(.allow, .trash, uses: 2, expires: start.addingTimeInterval(10)))
        clock.advance(10)
        try require(try !records.consume(id: expiring.id), "An expired record cannot be consumed")

        for round in 0..<5 {
            let contested = try records.add(record(.allow, .trash, uses: 1, statement: "Contested \(round)"))
            let barrier = NativeEffectBarrier()
            let one = Task.detached { () throws -> Bool in await barrier.wait(); return try records.consume(id: contested.id) }
            let two = Task.detached { () throws -> Bool in await barrier.wait(); return try records.consume(id: contested.id) }
            barrier.open()
            let outcomes = [try await one.value, try await two.value]
            try require(outcomes.filter { $0 }.count == 1 && (try records.record(id: contested.id))?.remainingUses == 0,
                        "Two concurrent consumes of a one-use record succeed exactly once (round \(round))")
        }
    }

    private static func sourceRevisions(_ require: (Bool, String) throws -> Void) throws {
        let fresh = NativeRuleSource()
        fresh.setRecords([])
        try require(fresh.revision == 0, "With no records the in-memory revision starts at zero")
        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(start)
        let records = store(repository, clock: clock)
        let source = NativeRuleSource()
        let reload = { () throws -> Int in
            source.setRecords(try records.active())
            return source.revision
        }
        var last = source.revision
        let added = try records.add(record(.allow, .trash, uses: 2, expires: start.addingTimeInterval(30)))
        try require(try reload() > last, "Adding a record raises the revision")
        last = source.revision
        clock.advance(1)
        try records.update(id: added.id) { $0.statement = "Trash old downloads" }
        try require(try reload() > last, "Updating a record raises the revision")
        last = source.revision
        _ = try records.consume(id: added.id)
        try require(try reload() > last, "Consuming a use raises the revision")
        last = source.revision
        try records.disable(id: added.id)
        try require(try reload() > last, "Disabling a record raises the revision")
        last = source.revision
        try records.enable(id: added.id)
        try require(try reload() > last, "Enabling a record raises the revision")
        last = source.revision
        clock.advance(60)
        try require(try records.expireDue() == 1, "Expiry sweeps the due record")
        try require(try reload() > last, "Expiring a record raises the revision")
        last = source.revision
        let second = try records.add(record(.ask, .trash))
        try require(try reload() > last, "Adding another record raises the revision")
        last = source.revision
        try records.revoke(id: second.id)
        try require(try reload() > last, "Revoking a record raises the revision")
        last = source.revision
        try require(try !records.enable(id: second.id) && (try records.record(id: second.id))?.status == .revoked
                    && (try records.record(id: second.id))?.revokedAt != nil, "Revoked is terminal and keeps its time")
        var stuck = false
        do { try records.update(id: second.id) { $0.statement = "Back again" } } catch { stuck = true }
        try require(stuck, "A revoked record cannot be updated")
        let steady = try reload()
        try require(steady == last, "Reloading unchanged records does not raise the revision")
        let resolverRevision = source.resolver(for: "c1", requestText: "").revision
        try require(resolverRevision == source.revision, "A resolver carries the source revision")
    }

    private static func restart(_ require: (Bool, String) throws -> Void) throws {
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let first = NativeRuleSource()
        ChatStore.prepareRules(first, from: records)
        for index in 0..<10 { first.setGlobal(NativeRules(choices: [.trash: index % 2 == 0 ? .act : .ask])) }
        let highest = first.revision
        try require(highest == (try records.version()), "Every change on a launched source advances the durable version")
        let second = NativeRuleSource()
        ChatStore.prepareRules(second, from: records)
        try require(second.revision > highest, "A second launch on the same database never shares a version with the first")
    }

    private static func targets(_ require: (Bool, String) throws -> Void) throws {
        let folder = NativeRuleTarget.make(.folder, "/a/b/")
        try require(folder?.value == "/a/b" && NativeRuleTarget.make(.folder, "/a/./c/../b")?.value == "/a/b",
                    "A folder target is a standardized absolute path without a trailing slash")
        let candidates = ["/a/b", "/a/b/c", "/a/bc", "/a"].map { NativeRuleTarget.make(.folder, $0)! }
        try require(candidates.map { folder!.isSatisfied(by: $0) } == [true, true, false, false],
                    "Folder containment uses path components, so /a/b does not contain /a/bc")
        try require(NativeRuleTarget.make(.service, "  GitHub ")?.value == "github" && NativeRuleTarget.make(.recipient, "Bob@Example.COM")?.value == "bob@example.com",
                    "Recipients and services are trimmed and lowercased")
        try require(NativeRuleTarget.make(.commandPrefix, "  git   status --short")?.value == "git status", "A command prefix keeps its first two words")
        let recipientRecord = record(.allow, target: recipient("alice"))
        try require(!recipientRecord.matches(NativeRuleQuery(action: .networkSends, targets: [NativeRuleTarget.make(.service, "alice")!]), at: start),
                    "A target only matches a candidate of the same kind")
    }



    private static func unboundedCounter(_ require: (Bool, String) throws -> Void) throws {
        let source = NativeRuleSource()
        let one = [record(.ask, .trash)]
        var last = source.revision
        var rising = true
        for index in 0..<1_000_001 {
            source.setRecords(index % 2 == 0 ? one : [])
            let next = source.revision
            if next <= last { rising = false; break }
            last = next
        }
        try require(rising && last == 1_000_001, "1,000,001 changes each change the in-memory revision")
    }

    private static func strictReload(_ require: (Bool, String) throws -> Void) throws {
        let mixed = NativeRuleEffect.allCases.map { record($0, .trash, target: NativeRuleTarget.make(.folder, "/a/\($0.rawValue)")) }
        try require(NativeRuleRecord.strictFallback(mixed).map(\.effect) == [.ask, .handOff, .forbid], "The strict fallback drops every allow and keeps the rest")
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let allow = try records.add(record(.allow, .trash))
        let forbid = try records.add(record(.forbid, .networkSends, target: recipient("alice")))
        let source = NativeRuleSource()
        ChatStore.prepareRules(source, from: records)
        try require(Set(source.currentRecords.map(\.id)) == [allow.id, forbid.id] && source.resolver(for: "c1", requestText: "").decision(for: .trash) == .act(.grant),
                    "A working reload serves every active record")
        let before = source.revision
        try repository.database.write { db in try db.execute(sql: "DROP TABLE native_rule_records") }
        ChatStore.reloadRules(source, from: records)
        let after = source.revision
        try require(source.hasFailed && source.currentRecords == [forbid] && after != before && source.revision != after
                    && source.resolver(for: "c1", requestText: "").decision(for: .trash) == .ask,
                    "A failed reload fails closed: allows are dropped, restrictions stay and no revision ever repeats")
        let launchRepository = try LocalChatRepository(inMemory: true)
        try launchRepository.database.write { db in try db.execute(sql: "DROP TABLE native_rule_version") }
        let failedLaunch = NativeRuleSource()
        failedLaunch.setRecords([record(.allow, .trash)])
        ChatStore.prepareRules(failedLaunch, from: store(launchRepository, clock: NativeEffectTestClock(start)))
        try require(failedLaunch.hasFailed && failedLaunch.currentRecords.isEmpty && failedLaunch.revision != failedLaunch.revision,
                    "A launch that cannot advance the version fails closed")
    }

    private static func projectMap(_ require: (Bool, String) throws -> Void) throws {
        let source = NativeRuleSource()
        source.setRecords([record(.allow, .trash, scope: .project("p1"))])
        source.replaceProjects([("c1", "p1"), ("c2", nil), ("c3", "p2")])
        try require(source.resolver(for: "c1", requestText: "").decision(for: .trash) == .act(.grant),
                    "A project-scoped allow applies through the source for a chat in that project")
        try require(source.resolver(for: "c2", requestText: "").decision(for: .trash) == .ask
                    && source.resolver(for: "c3", requestText: "").decision(for: .trash) == .ask,
                    "It does not apply to a chat outside the project")
        try require(source.resolver(for: "c3", requestText: "", projectID: "p1").decision(for: .trash) == .act(.grant),
                    "A caller-supplied project still wins")
        let before = source.revision
        source.replaceProjects([("c1", "p1"), ("c2", nil), ("c3", "p2")])
        try require(source.revision == before, "An unchanged project map does not bump the revision")
        source.setProject(nil, for: "c1")
        try require(source.revision > before && source.resolver(for: "c1", requestText: "").decision(for: .trash) == .ask,
                    "Moving the chat out of the project stops the allow and bumps the revision")
        let moved = source.revision
        source.setProject("p1", for: "c2")
        try require(source.revision > moved && source.resolver(for: "c2", requestText: "").decision(for: .trash) == .act(.grant),
                    "Moving a chat into the project applies the allow and bumps the revision")
    }

    private static func storeScenario(_ require: (Bool, String) throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rule-records-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifacts = directory.appendingPathComponent("artifacts")
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: artifacts)
        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
        let first = ChatStore(nativeConfig: config, nativeTransport: SelfTestNativeTransport(), repository: repository,
                              attachmentStore: NativeAttachmentStore(directory: artifacts))
        let launched = first.nativeRuleSource.revision
        try require(launched == 1 && first.nativeRuleSource.isDurable, "Opening the store advances the durable version once")
        try require(first.nativeRuleSource.resolver(for: "c1", requestText: "").decision(for: .trash) == .ask, "Trash asks by default")
        guard let saved = first.addRuleRecord(record(.allow, .trash, statement: "Trash my old downloads")) else {
            throw NativeTaskFixture.Failure.assertion("The store saves a rule record")
        }
        let added = first.nativeRuleSource.revision
        try require(added > launched && first.nativeRuleSource.resolver(for: "c1", requestText: "").decision(for: .trash) == .act(.grant)
                    && first.ruleRecords.map(\.id) == [saved.id], "Adding a record raises the revision and changes the decision")
        try require(first.revokeRuleRecord(id: saved.id) && first.nativeRuleSource.revision > added
                    && first.nativeRuleSource.resolver(for: "c1", requestText: "").decision(for: .trash) == .ask,
                    "Revoking it raises the revision and the decision returns to asking")
        try require(!first.revokeRuleRecord(id: saved.id) && first.addRuleRecord(record(.allow, .trash, statement: " ")) == nil,
                    "A second revoke or an invalid record changes nothing")
        let kept = first.addRuleRecord(record(.ask, .fileEdits, statement: "Ask before editing"))
        let reached = first.nativeRuleSource.revision
        let second = ChatStore(nativeConfig: config, nativeTransport: SelfTestNativeTransport(), repository: repository,
                               attachmentStore: NativeAttachmentStore(directory: artifacts))
        try require(second.nativeRuleSource.revision > reached && second.nativeRuleSource.currentRecords.map(\.id) == [kept?.id].compactMap { $0 }
                    && second.nativeRuleSource.resolver(for: "c1", requestText: "").decision(for: .fileEdits) == .ask,
                    "A relaunch on the same database starts above the last revision and loads the saved records")
    }

    private static func durableVersions(_ require: (Bool, String) throws -> Void) throws {
        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(start)
        let records = store(repository, clock: clock)
        var last = try records.version()
        func moved(_ name: String, _ require: (Bool, String) throws -> Void) throws {
            let next = try records.version()
            try require(next == last + 1, name)
            last = next
        }
        var tagged = record(.allow, .trash, uses: 2, expires: start.addingTimeInterval(30))
        tagged.originMessageID = "message-9"
        let saved = try records.add(tagged)
        try moved("Adding a record advances the durable version", require)
        _ = try records.add(tagged)
        try require(try records.version() == last, "A replayed add does not advance the version")
        try records.update(id: saved.id) { $0.statement = "Trash old downloads" }
        try moved("Updating a record advances the durable version", require)
        try records.disable(id: saved.id)
        try moved("Disabling advances the durable version", require)
        try records.disable(id: saved.id)
        try require(try records.version() == last, "A no-op transition does not advance the version")
        try records.enable(id: saved.id)
        try moved("Enabling advances the durable version", require)
        _ = try records.consume(id: saved.id)
        try moved("Consuming a use advances the durable version", require)
        try require(try records.expireDue() == 0 && (try records.version()) == last, "An expiry sweep that changes nothing leaves the version alone")
        clock.advance(31)
        try require(try records.expireDue() == 1, "The due record expires")
        try moved("An expiry that changes a row advances the durable version", require)
        let other = try records.add(record(.ask, .trash))
        try moved("Adding another record advances the durable version", require)
        try records.revoke(id: other.id)
        try moved("Revoking advances the durable version", require)

        let source = NativeRuleSource()
        ChatStore.prepareRules(source, from: records)
        try moved("A launch advances the durable version once", require)
        try require(source.isDurable && source.revision == last, "A launched source's revision is the durable version")
        source.setGlobal(NativeRules(choices: [.trash: .act]))
        try moved("A global rules change advances the durable version through the allocator", require)
        source.set(NativeConversationRules(choices: [.trash: .handOff]), for: "c1")
        try moved("A conversation rules change advances the durable version", require)
        source.setProject("p1", for: "c1")
        try moved("A project move advances the durable version", require)
        try require(source.revision == last, "The source revision follows every allocation")

        let allow = try records.add(record(.allow, .fileEdits, statement: "Edit freely"))
        let newer = try records.snapshot()
        try require(source.publish(newer.records, version: newer.version) && source.revision == newer.version, "A newer snapshot is published")
        try records.revoke(id: allow.id)
        let newest = try records.snapshot()
        try require(source.publish(newest.records, version: newest.version), "The snapshot without the allow is published")
        try require(!source.publish(newer.records, version: newer.version) && source.revision == newest.version
                    && source.resolver(for: "c2", requestText: "").decision(for: .fileEdits) == .act(.rule)
                    && !source.currentRecords.contains(where: { $0.id == allow.id }),
                    "An older snapshot published after a newer one never restores a revoked allow")
    }

    static func folderFixture() throws -> (root: String, grant: FolderGrant, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rule-records-folder-" + UUID().uuidString)
        for name in ["locked", "open"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let grant = try FolderGrant.make(url: directory)
        return (grant.path, grant, directory)
    }

    private static func commandToolID(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for (tool, blocks) in [(NativeCommandTools.toolID, true), ("another-tool", false)] {
            let source = NativeRuleSource()
            source.setGlobal(NativeRules(choices: [.commands: .act]))
            source.setRecords([record(.forbid, .commands, tool: tool)])
            let run = NativeCommandTools.definitions(grants: { [fixture.grant] }, decision: .ask, reason: { _ in nil }, record: { _ in })[0]
            let arguments: [String: NativeJSONValue] = ["command": .string("swift build")]
            let worker = NativeCompanionWorker.ruleDecision(run, arguments, resolver: source.resolver(for: "c1", requestText: ""), honoringLimitedUse: true)
            try require(worker.decision == (blocks ? .handOff : .act(.rule)),
                        blocks ? "A commands forbid on the command tool blocks swift build in the worker" : "A forbid for another tool does not block the command tool in the worker")
            let asking = NativeRuleSource()
            asking.setGlobal(NativeRules(choices: [.commands: .ask]))
            asking.setRecords([record(.forbid, .commands, tool: tool)])
            let foreground = NativeCommandTools.definitions(grants: { [fixture.grant] }, decision: .act(.rule), reason: { _ in nil }, record: { _ in },
                                                            liveTargets: { command, action, subjects in
                ChatStore.commandDecision(asking, conversationID: "c1", requestText: "", command: command, action: action, subjects: subjects)
            })[0]
            var message = ""
            do { _ = try await foreground.execute(arguments) } catch { message = error.localizedDescription }
            try require(blocks ? message == NativeRuleResolver.handOffMessage(.commands) : message == NativeRuleResolver.changedMessage,
                        blocks ? "The same forbid hands off swift build in foreground chat" : "A forbid for another tool leaves foreground chat on the ordinary rules")
        }
    }

    private static func typedTargets(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let locked = fixture.root + "/locked"
        let source = NativeRuleSource()
        source.setGlobal(NativeRules(choices: [.fileEdits: .act]))
        source.setRecords([record(.forbid, .fileEdits, target: NativeRuleTarget.folder(locked))])
        let chat = NativeFolderTools.definitions(grants: { [fixture.grant] }, ledger: NativeFileChangeLedger(), edits: .act(.rule),
                                                 liveTargets: { action, subjects in
            ChatStore.folderDecision(source, conversationID: "c1", requestText: "", action: action, subjects: subjects)
        })
        let write = chat.first { $0.name == NativeFolderTools.writeName }!
        let move = chat.first { $0.name == NativeFolderTools.moveName }!
        func outcome(_ definition: NativeToolDefinition, _ arguments: [String: NativeJSONValue]) async -> String {
            do { _ = try await definition.execute(arguments); return "ran" } catch { return error.localizedDescription }
        }
        let inside: [String: NativeJSONValue] = ["path": .string(locked + "/a.txt"), "content": .string("x")]
        let sibling: [String: NativeJSONValue] = ["path": .string(fixture.root + "/open/a.txt"), "content": .string("x")]
        let intoLocked: [String: NativeJSONValue] = ["from": .string(fixture.root + "/open/a.txt"), "to": .string(locked + "/b.txt")]
        let handed = NativeRuleResolver.handOffMessage(.fileEdits)
        try require(await outcome(write, inside) == handed, "A folder forbid blocks a write inside it in chat")
        try require(await outcome(write, sibling) == "ran", "A sibling path still acts in chat")
        try require(await outcome(move, intoLocked) == handed && FileManager.default.fileExists(atPath: fixture.root + "/open/a.txt"),
                    "A move whose destination is inside the forbidden folder is blocked in chat")
        let resolver = source.resolver(for: "c1", requestText: "")
        try require(NativeCompanionWorker.ruleDecision(write, inside, resolver: resolver, honoringLimitedUse: true).decision == .handOff,
                    "The folder forbid blocks the same write in the worker")
        try require(NativeCompanionWorker.ruleDecision(write, sibling, resolver: resolver, honoringLimitedUse: true).decision == .act(.rule),
                    "The sibling write still acts in the worker")
        try require(NativeCompanionWorker.ruleDecision(move, intoLocked, resolver: resolver, honoringLimitedUse: true).decision == .handOff,
                    "The move into the forbidden folder is blocked in the worker")
        try require(write.ruleSubjects?(inside) == [[NativeRuleTarget.folder(locked + "/a.txt")!]]
                    && move.ruleSubjects?(intoLocked).count == 2, "File tools declare one subject for every affected path")

        var send = NativeToolDefinition(id: "mail", name: "send_mail", title: "Send mail", description: "Send mail",
                                        parameters: .object(["type": .string("object")]), confirmation: .required,
                                        isAvailable: { true }, execute: { _ in .null })
        send.effect = .write
        send.action = .networkSends
        let spoof: [String: NativeJSONValue] = ["path": .string("alice@example.com"), "destination": .string("bob@example.com")]
        let allowing = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "",
                                          records: [record(.allow, target: recipient("alice@example.com"))], context: NativeRuleContext(conversationID: "c1"), now: start)
        let spoofed = NativeCompanionWorker.ruleDecision(send, spoof, resolver: allowing, honoringLimitedUse: true)
        try require(spoofed.decision == .handOff && spoofed.authorizedBy.isEmpty && NativeCompanionWorker.ruleQuery(send, spoof, action: .networkSends).targets.isEmpty,
                    "A path that looks like a recipient never satisfies a recipient allow")
        let acting = NativeRules(choices: [.networkSends: .act])
        let restricted = NativeRuleResolver(global: acting, conversation: NativeConversationRules(), requestText: "",
                                            records: [record(.forbid, target: recipient("alice@example.com"))], context: NativeRuleContext(conversationID: "c1"), now: start)
        try require(NativeCompanionWorker.ruleDecision(send, [:], resolver: restricted, honoringLimitedUse: true).decision == .ask,
                    "A send tool with no declared targets asks when a recipient forbid exists")
        let open = NativeRuleResolver(global: acting, conversation: NativeConversationRules(), requestText: "", records: [],
                                      context: NativeRuleContext(conversationID: "c1"), now: start)
        try require(NativeCompanionWorker.ruleDecision(send, [:], resolver: open, honoringLimitedUse: true).decision == .act(.rule),
                    "With no recipient restriction the send tool behaves as before")
    }

    private static func useLimits(_ require: (Bool, String) throws -> Void) throws {
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        for effect in [NativeRuleEffect.ask, .handOff, .forbid] {
            var caught: NativeRuleRecordError?
            do { try records.add(record(effect, .trash, uses: 2)) } catch let error as NativeRuleRecordError { caught = error }
            try require(caught == .invalidUses, "A use limit on a \(effect.rawValue) record is rejected at add")
        }
        let forbid = try records.add(record(.forbid, .trash))
        var updateCaught: NativeRuleRecordError?
        do { try records.update(id: forbid.id) { $0.remainingUses = 3 } } catch let error as NativeRuleRecordError { updateCaught = error }
        try require(updateCaught == .invalidUses && (try records.record(id: forbid.id))?.remainingUses == nil, "A use limit on a restriction is rejected at update")
        var spent = record(.forbid, .trash)
        spent.remainingUses = 0
        let matcher = resolver([spent], global: NativeRules(choices: [.trash: .act]))
        try require(matcher.decision(for: .trash) == .handOff && matcher.resolve(NativeRuleQuery(action: .trash), honoringLimitedUse: true).decision == .handOff,
                    "A restriction is never dropped because of a use count")
    }

    private static func realFolderTargets(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("rule-records-link-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let spelled = NativeRuleTarget.make(.folder, link.path + "/locked")
        let saved = try records.add(record(.forbid, .fileEdits, target: spelled))
        let real = NativeRuleTarget.realFolder(fixture.root + "/locked")
        try require(saved.target?.value == real && saved.target?.value != spelled?.value && real?.hasPrefix("/") == true,
                    "A folder target saved through a symlink is stored as its real path")
        let dotted = try records.add(record(.forbid, .fileEdits, target: NativeRuleTarget.make(.folder, fixture.root + "/open/../locked/./")))
        try require(dotted.target?.value == real, "A dot-dot folder target is normalized before it is stored")
        try require(NativeRuleTarget.make(.folder, "relative/locked") == nil && NativeRuleTarget.realFolder("relative/locked") == nil
                    && NativeRuleTarget.folder("../locked") == nil, "A folder target that is not an absolute path can never be built")
        var updated = false
        do {
            let moved = try records.update(id: dotted.id) { $0.target = NativeRuleTarget.make(.folder, link.path + "/open") }
            updated = moved.target?.value == NativeRuleTarget.realFolder(fixture.root + "/open")
        } catch {}
        try require(updated, "An update normalizes a folder target the same way")
        try records.revoke(id: dotted.id)
        let source = NativeRuleSource()
        source.setGlobal(NativeRules(choices: [.fileEdits: .act]))
        source.setRecords(try records.active())
        let chat = NativeFolderTools.definitions(grants: { [fixture.grant] }, ledger: NativeFileChangeLedger(), edits: .act(.rule),
                                                 liveTargets: { action, subjects in
            ChatStore.folderDecision(source, conversationID: "c1", requestText: "", action: action, subjects: subjects)
        })
        let write = chat.first { $0.name == NativeFolderTools.writeName }!
        let handed = NativeRuleResolver.handOffMessage(.fileEdits)
        for path in [fixture.root + "/locked/a.txt", link.path + "/locked/b.txt"] {
            var message = ""
            do { _ = try await write.execute(["path": .string(path), "content": .string("x")]) } catch { message = error.localizedDescription }
            try require(message == handed && !FileManager.default.fileExists(atPath: fixture.root + "/locked/" + URL(fileURLWithPath: path).lastPathComponent),
                        "The symlink-spelled forbid blocks a write addressed as \(path == fixture.root + "/locked/a.txt" ? "the real path" : "the symlink")")
        }
        var sibling = ""
        do { _ = try await write.execute(["path": .string(fixture.root + "/open/c.txt"), "content": .string("x")]); sibling = "ran" } catch { sibling = error.localizedDescription }
        try require(sibling == "ran", "The sibling folder still acts")
    }

    static func chatFolders(_ source: NativeRuleSource, store records: NativeRuleRecordStore?, grant: FolderGrant) -> [String: NativeToolDefinition] {
        let definitions = NativeFolderTools.definitions(grants: { [grant] }, ledger: NativeFileChangeLedger(), edits: .act(.rule),
                                                        liveTargets: { action, subjects in
            ChatStore.folderDecision(source, store: records, conversationID: "c1", requestText: "", action: action, subjects: subjects)
        })
        return Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
    }

    static func run(_ definition: NativeToolDefinition, _ arguments: [String: NativeJSONValue]) async -> String {
        do { _ = try await definition.execute(arguments); return "ran" } catch { return error.localizedDescription }
    }

    private static func foregroundBoundary(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let open = fixture.root + "/open"
        let changed = NativeRuleResolver.changedMessage

        let brokenRepository = try LocalChatRepository(inMemory: true)
        try await brokenRepository.database.write { db in try db.execute(sql: "DROP TABLE native_rule_version") }
        let brokenStore = store(brokenRepository, clock: NativeEffectTestClock(start))
        let broken = NativeRuleSource()
        broken.setGlobal(NativeRules(choices: [.fileEdits: .act]))
        ChatStore.prepareRules(broken, from: brokenStore)
        let brokenTools = chatFolders(broken, store: brokenStore, grant: fixture.grant)
        let attempt: [String: NativeJSONValue] = ["path": .string(open + "/failed.txt"), "content": .string("x")]
        try require(await run(brokenTools[NativeFolderTools.writeName]!, attempt) == changed && !FileManager.default.fileExists(atPath: open + "/failed.txt"),
                    "After a failed launch a foreground write never runs without approval")
        try require(NativeCompanionWorker.ruleDecision(brokenTools[NativeFolderTools.writeName]!, attempt,
                                                       resolver: broken.resolver(for: "c1", requestText: ""), honoringLimitedUse: true).decision == .ask,
                    "After a failed launch the worker asks instead of acting")

        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(start)
        let records = store(repository, clock: clock)
        let source = NativeRuleSource()
        ChatStore.prepareRules(source, from: records)
        source.setGlobal(NativeRules(choices: [.fileEdits: .ask, .commands: .ask]))
        let folderAllow = try records.add(record(.allow, .fileEdits, target: NativeRuleTarget.folder(open)))
        let commandAllow = try records.add(record(.allow, .commands))
        ChatStore.reloadRules(source, from: records)
        let tools = chatFolders(source, store: records, grant: fixture.grant)
        let command = NativeCommandTools.definitions(grants: { [fixture.grant] }, decision: .act(.rule), reason: { _ in nil }, record: { _ in },
                                                     liveTargets: { command, action, subjects in
            ChatStore.commandDecision(source, store: records, conversationID: "c1", requestText: "", command: command, action: action, subjects: subjects)
        })[0]
        try records.revoke(id: folderAllow.id)
        try records.revoke(id: commandAllow.id)
        try require(source.resolver(for: "c1", requestText: "").tool(NativeFolderTools.toolID, targets: [NativeRuleTarget.folder(open + "/r.txt")!])
                        .decision(for: .fileEdits) == .act(.grant), "The in-memory source still holds the revoked allow")
        try require(await run(tools[NativeFolderTools.writeName]!, ["path": .string(open + "/revoked.txt"), "content": .string("x")]) == changed
                    && !FileManager.default.fileExists(atPath: open + "/revoked.txt"),
                    "A revoke committed but not yet reloaded stops a foreground write")
        try require(await run(command, ["command": .string("swift build"), "directory": .string(open)]) == changed,
                    "A revoke committed but not yet reloaded stops a foreground command")

        ChatStore.reloadRules(source, from: records)
        _ = try records.add(record(.allow, .fileEdits, target: NativeRuleTarget.folder(open), uses: 1))
        ChatStore.reloadRules(source, from: records)
        let once = try records.active().first { $0.remainingUses != nil }!
        let first = await run(tools[NativeFolderTools.writeName]!, ["path": .string(open + "/once.txt"), "content": .string("x")])
        let second = await run(tools[NativeFolderTools.writeName]!, ["path": .string(open + "/twice.txt"), "content": .string("x")])
        try require(first == "ran" && second == changed && FileManager.default.fileExists(atPath: open + "/once.txt")
                    && !FileManager.default.fileExists(atPath: open + "/twice.txt") && (try records.record(id: once.id))?.remainingUses == 0,
                    "A one-use allow is consumed by exactly one foreground action")
    }

    private static func everySubject(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let open = fixture.root + "/open"
        let locked = fixture.root + "/locked"
        try "x".write(toFile: open + "/a.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: locked + "/z.txt", atomically: true, encoding: .utf8)
        let source = NativeRuleSource()
        source.setRecords([record(.forbid, .fileEdits), record(.allow, .fileEdits, target: NativeRuleTarget.folder(open))])
        let tools = chatFolders(source, store: nil, grant: fixture.grant)
        let move = tools[NativeFolderTools.moveName]!
        let resolver = source.resolver(for: "c1", requestText: "")
        let out: [String: NativeJSONValue] = ["from": .string(open + "/a.txt"), "to": .string(locked + "/a.txt")]
        let back: [String: NativeJSONValue] = ["from": .string(locked + "/z.txt"), "to": .string(open + "/z.txt")]
        let inside: [String: NativeJSONValue] = ["from": .string(open + "/a.txt"), "to": .string(open + "/b.txt")]
        let handed = NativeRuleResolver.handOffMessage(.fileEdits)
        let outRun = await run(move, out)
        try require(NativeCompanionWorker.ruleDecision(move, out, resolver: resolver, honoringLimitedUse: true).decision == .handOff
                    && outRun == handed && FileManager.default.fileExists(atPath: open + "/a.txt"),
                    "A move from the allowed folder into the forbidden one is blocked")
        let backRun = await run(move, back)
        try require(NativeCompanionWorker.ruleDecision(move, back, resolver: resolver, honoringLimitedUse: true).decision == .handOff
                    && backRun == handed && FileManager.default.fileExists(atPath: locked + "/z.txt"),
                    "The reverse move is blocked")
        let insideDecision = NativeCompanionWorker.ruleDecision(move, inside, resolver: resolver, honoringLimitedUse: true)
        let insideRun = await run(move, inside)
        try require(insideDecision.decision == .act(.grant) && insideDecision.authorizedBy.count == 1 && insideRun == "ran",
                    "A move entirely inside the allowed folder acts under one authorizing record")

    }


    private static func targetKinds(_ require: (Bool, String) throws -> Void) throws {
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let prefix = NativeRuleTarget.make(.commandPrefix, "swift build")
        let folder = NativeRuleTarget.folder("/tmp")
        let invalid: [(NativeRuleRecord, String)] = [
            (record(.forbid, .commands, target: prefix), "a restrictive command prefix"),
            (record(.ask, .commands, target: prefix), "an asking command prefix"),
            (record(.allow, .fileEdits, target: prefix), "a command prefix outside commands"),
            (record(.forbid, .commands, target: folder), "a folder on commands"),
            (record(.allow, .networkSends, target: folder), "a folder on sends"),
            (record(.forbid, .fileEdits, target: recipient("alice")), "a recipient outside sends"),
            (record(.allow, .trash, target: NativeRuleTarget.make(.service, "github")), "a service outside sends"),
        ]
        for (candidate, name) in invalid {
            var caught: NativeRuleRecordError?
            do { try records.add(candidate) } catch let error as NativeRuleRecordError { caught = error }
            try require(caught == .invalidTarget, "The store rejects \(name) at add")
        }
        let valid = [record(.allow, .commands, target: prefix), record(.forbid, .fileEdits, target: folder), record(.ask, .trash, target: folder),
                     record(.forbid, .networkSends, target: recipient("alice")), record(.forbid, .commands), record(.forbid, .commands, tool: "run")]
        for candidate in valid { _ = try records.add(candidate) }
        try require(try records.all().count == valid.count, "Allowed target kinds and class or tool records of any effect are accepted")
        let allowPrefix = try records.all().first { $0.target?.kind == .commandPrefix }!
        var updateCaught: NativeRuleRecordError?
        do { try records.update(id: allowPrefix.id) { $0.effect = .forbid } } catch let error as NativeRuleRecordError { updateCaught = error }
        try require(updateCaught == .invalidTarget && (try records.record(id: allowPrefix.id))?.effect == .allow, "The store rejects an invalid combination at update")
        let rows: [(String, String, String, String)] = [("commands", "forbid", "command_prefix", "swift build"), ("commands", "allow", "folder", "/tmp"),
                                                        ("file_edits", "forbid", "recipient", "alice"), ("trash", "allow", "command_prefix", "ls")]
        for (action, effect, kind, value) in rows {
            var rejected = false
            do {
                try repository.database.write { db in
                    try db.execute(sql: """
                        INSERT INTO native_rule_records(id, scope_kind, action, target_kind, target_value, effect, statement, origin, status, created_at, updated_at)
                        VALUES(?, 'everywhere', ?, ?, ?, ?, 'x', 'settings', 'active', 0, 0)
                        """, arguments: [UUID().uuidString, action, kind, value, effect])
                }
            } catch { rejected = true }
            try require(rejected, "The database CHECK rejects \(effect) \(kind) on \(action)")
        }
    }

    private static func footprints(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let project = fixture.root + "/open/project"
        let protected = project + "/protected"
        try FileManager.default.createDirectory(atPath: protected, withIntermediateDirectories: true)
        try "x".write(toFile: protected + "/secret.txt", atomically: true, encoding: .utf8)
        let source = NativeRuleSource()
        source.setGlobal(NativeRules(choices: [.fileEdits: .act, .trash: .act]))
        source.setRecords([record(.forbid, .fileEdits, target: NativeRuleTarget.folder(protected)),
                           record(.forbid, .trash, target: NativeRuleTarget.folder(protected))])
        let tools = chatFolders(source, store: nil, grant: fixture.grant)
        let resolver = source.resolver(for: "c1", requestText: "")
        let moveParent: [String: NativeJSONValue] = ["from": .string(project), "to": .string(fixture.root + "/locked/project")]
        let trashParent: [String: NativeJSONValue] = ["path": .string(project)]
        try require(NativeCompanionWorker.ruleDecision(tools[NativeFolderTools.moveName]!, moveParent, resolver: resolver, honoringLimitedUse: true).decision == .handOff,
                    "A forbid on a protected descendant blocks moving its parent")
        try require(NativeCompanionWorker.ruleDecision(tools[NativeFolderTools.trashName]!, trashParent, resolver: resolver, honoringLimitedUse: true).decision == .handOff,
                    "A forbid on a protected descendant blocks trashing its parent")
        let moveRun = await run(tools[NativeFolderTools.moveName]!, moveParent)
        try require(moveRun == NativeRuleResolver.handOffMessage(.fileEdits) && FileManager.default.fileExists(atPath: protected + "/secret.txt"),
                    "The parent move is refused in chat and nothing moves")
        try "y".write(toFile: fixture.root + "/open/loose.txt", atomically: true, encoding: .utf8)
        let sibling: [String: NativeJSONValue] = ["from": .string(fixture.root + "/open/loose.txt"), "to": .string(fixture.root + "/open/moved.txt")]
        try require(NativeCompanionWorker.ruleDecision(tools[NativeFolderTools.moveName]!, sibling, resolver: resolver, honoringLimitedUse: true).decision == .act(.rule),
                    "A move with no restricted descendant still acts")

        let creating = NativeRuleSource()
        let leaf = fixture.root + "/open/new/leaf"
        creating.setRecords([record(.forbid, .fileEdits), record(.allow, .fileEdits, target: NativeRuleTarget.folder(leaf))])
        let mkdir = chatFolders(creating, store: nil, grant: fixture.grant)[NativeFolderTools.mkdirName]!
        let make: [String: NativeJSONValue] = ["path": .string(leaf)]
        try require(mkdir.ruleSubjects?(make).count == 2, "Creating a folder declares every missing parent plus the leaf")
        let decided = NativeCompanionWorker.ruleDecision(mkdir, make, resolver: creating.resolver(for: "c1", requestText: ""), honoringLimitedUse: true)
        let made = await run(mkdir, make)
        try require(decided.decision == .handOff && made == NativeRuleResolver.handOffMessage(.fileEdits)
                    && !FileManager.default.fileExists(atPath: fixture.root + "/open/new"),
                    "An allow on the leaf does not authorize creating its missing parent under a class-wide forbid")
        let insideAllowed = NativeRuleSource()
        let allowed = fixture.root + "/open"
        insideAllowed.setRecords([record(.forbid, .fileEdits), record(.allow, .fileEdits, target: NativeRuleTarget.folder(allowed))])
        try require(NativeCompanionWorker.ruleDecision(tools[NativeFolderTools.moveName]!, sibling, resolver: insideAllowed.resolver(for: "c1", requestText: ""),
                                                       honoringLimitedUse: true).decision == .act(.grant),
                    "A move entirely inside an allowed folder with no restricted descendant acts")
    }

    private static func lateConfirmation(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let open = fixture.root + "/open"
        try "hello".write(toFile: open + "/note.txt", atomically: true, encoding: .utf8)
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let source = NativeRuleSource()
        ChatStore.prepareRules(source, from: records)
        source.setGlobal(NativeRules(choices: [.fileEdits: .ask]))
        let once = try records.add(record(.allow, .fileEdits, target: NativeRuleTarget.folder(open), uses: 1))
        ChatStore.reloadRules(source, from: records)
        let tools = chatFolders(source, store: records, grant: fixture.grant)
        let missing = await run(tools[NativeFolderTools.editName]!, ["path": .string(open + "/note.txt"), "old_text": .string("absent"), "new_text": .string("x")])
        try require(missing.contains("old_text was not found") && (try records.record(id: once.id))?.remainingUses == 1,
                    "An edit whose old_text is absent leaves a one-use allow unspent")
        let huge = String(repeating: "a", count: NativeFolderTools.maximumWriteBytes + 1)
        let oversized = await run(tools[NativeFolderTools.writeName]!, ["path": .string(open + "/big.txt"), "content": .string(huge)])
        try require(oversized.contains("1 MB") && (try records.record(id: once.id))?.remainingUses == 1, "An oversized write leaves a one-use allow unspent")
        var readOnly = fixture.grant
        readOnly.readOnly = true
        let readOnlyTools = chatFolders(source, store: records, grant: readOnly)
        let blocked = await run(readOnlyTools[NativeFolderTools.writeName]!, ["path": .string(open + "/ro.txt"), "content": .string("x")])
        try require(blocked != "ran" && (try records.record(id: once.id))?.remainingUses == 1 && !FileManager.default.fileExists(atPath: open + "/ro.txt"),
                    "A read-only destination leaves a one-use allow unspent")
        let done = await run(tools[NativeFolderTools.editName]!, ["path": .string(open + "/note.txt"), "old_text": .string("hello"), "new_text": .string("bye")])
        try require(done == "ran" && (try records.record(id: once.id))?.remainingUses == 0, "The use is spent only by the edit that happens")
    }

    private static func caseAndForm(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let open = fixture.root + "/open"
        let insensitive = NativeFolderCase.sensitivity(near: open) == false
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let forbid = try records.add(record(.forbid, .fileEdits, target: NativeRuleTarget.make(.folder, open + "/Locked")))
        let deep = try records.add(record(.forbid, .fileEdits, target: NativeRuleTarget.make(.folder, open + "/Vault/deep")))
        let source = NativeRuleSource()
        source.setGlobal(NativeRules(choices: [.fileEdits: .act]))
        source.setRecords([forbid, deep])
        let tools = chatFolders(source, store: nil, grant: fixture.grant)
        let mkdir = tools[NativeFolderTools.mkdirName]!
        let resolver = source.resolver(for: "c1", requestText: "")
        if insensitive {
            try require(NativeCompanionWorker.ruleDecision(mkdir, ["path": .string(open + "/locked/inner")], resolver: resolver, honoringLimitedUse: true).decision == .handOff,
                        "A differently cased path inside a forbidden folder is blocked on a case-insensitive volume")
            try require(NativeCompanionWorker.ruleDecision(mkdir, ["path": .string(open + "/vault")], resolver: resolver, honoringLimitedUse: true).decision == .handOff,
                        "A differently cased folder holding a forbidden descendant is blocked on a case-insensitive volume")
            let made = await run(mkdir, ["path": .string(open + "/locked")])
            try require(made == NativeRuleResolver.handOffMessage(.fileEdits) && !FileManager.default.fileExists(atPath: open + "/locked"),
                        "Creating the differently cased folder in chat is refused and nothing is created")
        }
        let restrict = NativeRuleTarget.make(.folder, "/volume/Locked")!
        let allowTarget = NativeRuleTarget.make(.folder, "/volume/Open")!
        let lower = NativeRuleTarget.make(.folder, "/volume/locked/a")!
        let lowerOpen = NativeRuleTarget.make(.folder, "/volume/open/a")!
        let parent = NativeRuleTarget.make(.folder, "/volume")!
        let sensitiveRestricts = NativeFolderCase.$probe.withValue({ _ in true }) { restrict.isSatisfied(by: lower, restricting: true) }
        let insensitiveRestricts = NativeFolderCase.$probe.withValue({ _ in false }) { restrict.isSatisfied(by: lower, restricting: true) }
        let insensitiveReverse = NativeFolderCase.$probe.withValue({ _ in false }) {
            NativeRuleTarget.make(.folder, "/volume/Locked/deep")!.isSatisfied(by: NativeRuleTarget.make(.folder, "/volume/locked")!, restricting: true)
        }
        try require(!sensitiveRestricts && insensitiveRestricts && insensitiveReverse,
                    "An injected case-sensitive volume keeps cases distinct, an insensitive one folds them in both directions")
        let unknownRestricts = NativeFolderCase.$probe.withValue({ _ in nil }) { restrict.isSatisfied(by: lower, restricting: true) }
        let unknownAllows = NativeFolderCase.$probe.withValue({ _ in nil }) { allowTarget.isSatisfied(by: lowerOpen, restricting: false) }
        let unknownExact = NativeFolderCase.$probe.withValue({ _ in nil }) { allowTarget.isSatisfied(by: NativeRuleTarget.make(.folder, "/volume/Open/a")!) }
        try require(unknownRestricts && !unknownAllows && unknownExact,
                    "With unknown sensitivity a restriction folds case while an allow never widens across case")
        let boundary = NativeFolderCase.$probe.withValue({ _ in false }) {
            restrict.isSatisfied(by: NativeRuleTarget.make(.folder, "/volume/lockedness")!, restricting: true)
                || restrict.isSatisfied(by: parent, restricting: false)
        }
        try require(!boundary, "Case folding keeps component boundaries")
        let composed = NativeRuleTarget.make(.folder, "/volume/Caf\u{e9}")!
        let decomposed = NativeRuleTarget.make(.folder, "/volume/Cafe\u{301}/menu")!
        let unicode = NativeFolderCase.$probe.withValue({ _ in true }) { composed.isSatisfied(by: decomposed, restricting: true) }
        try require(unicode, "A precomposed folder name matches its decomposed spelling")
    }

    private static func boundFootprint(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let open = fixture.root + "/open"
        try FileManager.default.createDirectory(atPath: open + "/keep", withIntermediateDirectories: true)
        try "x".write(toFile: open + "/file.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: open + "/from.txt", atomically: true, encoding: .utf8)
        try "y".write(toFile: open + "/taken.txt", atomically: true, encoding: .utf8)
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let source = NativeRuleSource()
        ChatStore.prepareRules(source, from: records)
        source.setGlobal(NativeRules(choices: [.fileEdits: .ask]))
        let once = try records.add(record(.allow, .fileEdits, target: NativeRuleTarget.folder(open), uses: 1))
        ChatStore.reloadRules(source, from: records)
        let tools = chatFolders(source, store: records, grant: fixture.grant)
        let mkdir = tools[NativeFolderTools.mkdirName]!
        let keep = open + "/keep"
        let removed = await NativeFolderTools.$afterDeclaring.withValue({ try? FileManager.default.removeItem(atPath: keep) }) {
            await run(mkdir, ["path": .string(keep + "/leaf")])
        }
        try require(removed.contains("changed after this request was checked") && !FileManager.default.fileExists(atPath: keep)
                    && (try records.record(id: once.id))?.remainingUses == 1,
                    "A parent removed after the footprint was declared is not recreated and the use is not spent")
        let declared = mkdir.ruleSubjects?(["path": .string(keep + "/leaf")]).flatMap { $0.map(\.value) } ?? []
        try FileManager.default.createDirectory(atPath: keep, withIntermediateDirectories: true)
        let admittedDeclared = mkdir.ruleSubjects?(["path": .string(keep + "/leaf")]).flatMap { $0.map(\.value) } ?? []
        try FileManager.default.removeItem(atPath: keep)
        let workerRun = await NativeRuleAdmission.$footprint.withValue(admittedDeclared) {
            await NativeRuleAdmission.$admitted.withValue(true) { await run(mkdir, ["path": .string(keep + "/leaf")]) }
        }
        try require(declared.count == 2 && admittedDeclared.count == 1 && workerRun.contains("changed after this request was checked")
                    && !FileManager.default.fileExists(atPath: keep),
                    "An admitted worker call creates only the components it declared as missing")
        let intoFile = await run(mkdir, ["path": .string(open + "/file.txt/sub")])
        try require(intoFile != "ran" && (try records.record(id: once.id))?.remainingUses == 1,
                    "Creating a folder under an existing regular file fails before the use is spent")
        let onto = await run(tools[NativeFolderTools.moveName]!, ["from": .string(open + "/from.txt"), "to": .string(open + "/taken.txt")])
        try require(onto.contains("already exists") && (try records.record(id: once.id))?.remainingUses == 1
                    && (try? String(contentsOfFile: open + "/taken.txt", encoding: .utf8)) == "y",
                    "A move onto an existing destination fails before the use is spent")
    }

    private static func creationRace(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rule-records-outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let open = fixture.root + "/open"
        let keep = open + "/keep"
        try FileManager.default.createDirectory(atPath: keep, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: open + "/link", withDestinationPath: outside.path)
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let source = NativeRuleSource()
        ChatStore.prepareRules(source, from: records)
        source.setGlobal(NativeRules(choices: [.fileEdits: .ask]))
        let raced = try records.add(record(.allow, .fileEdits, target: NativeRuleTarget.folder(open), uses: 1))
        ChatStore.reloadRules(source, from: records)
        let mkdir = chatFolders(source, store: records, grant: fixture.grant)[NativeFolderTools.mkdirName]!
        let outcome = await NativeFolderTools.$afterCommit.withValue({ try? FileManager.default.removeItem(atPath: keep) }) {
            await run(mkdir, ["path": .string(keep + "/leaf")])
        }
        try require(outcome.contains("changed after this request was checked") && !FileManager.default.fileExists(atPath: keep),
                    "A parent removed after confirmation is never recreated by the creation walk")
        try require(try records.record(id: raced.id)?.remainingUses == 0, "A use confirmed before the race is spent, because admission happened")
        let fresh = try records.add(record(.allow, .fileEdits, target: NativeRuleTarget.folder(open), uses: 1))
        ChatStore.reloadRules(source, from: records)
        let linked = await run(mkdir, ["path": .string(open + "/link/sub")])
        let outsideEntries = (try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? ["?"]
        try require(linked != "ran" && outsideEntries.isEmpty && (try records.record(id: fresh.id))?.remainingUses == 1,
                    "Creating beneath a symlink to a folder outside the grant refuses before the use is spent")
    }

    private static func significantWhitespace(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let spaced = fixture.root + "/open/private "
        let protected = spaced + "/protected"
        try FileManager.default.createDirectory(atPath: protected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: fixture.root + "/open ", withIntermediateDirectories: true)
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let editForbid = try records.add(record(.forbid, .fileEdits, target: NativeRuleTarget.make(.folder, protected)))
        let trashForbid = try records.add(record(.forbid, .trash, target: NativeRuleTarget.make(.folder, protected)))
        try require(editForbid.target?.value.hasSuffix("/private /protected") == true, "A folder target keeps its trailing space through the store")
        let source = NativeRuleSource()
        source.setGlobal(NativeRules(choices: [.fileEdits: .act, .trash: .act]))
        source.setRecords([editForbid, trashForbid])
        let tools = chatFolders(source, store: nil, grant: fixture.grant)
        let resolver = source.resolver(for: "c1", requestText: "")
        let move: [String: NativeJSONValue] = ["from": .string(spaced), "to": .string(fixture.root + "/locked/moved")]
        try require(NativeCompanionWorker.ruleDecision(tools[NativeFolderTools.moveName]!, move, resolver: resolver, honoringLimitedUse: true).decision == .handOff,
                    "Moving a trailing-space parent that holds a restricted descendant is blocked")
        try require(NativeCompanionWorker.ruleDecision(tools[NativeFolderTools.trashName]!, ["path": .string(spaced)], resolver: resolver,
                                                       honoringLimitedUse: true).decision == .handOff,
                    "Trashing a trailing-space parent that holds a restricted descendant is blocked")
        let moved = await run(tools[NativeFolderTools.moveName]!, move)
        try require(moved == NativeRuleResolver.handOffMessage(.fileEdits) && FileManager.default.fileExists(atPath: protected),
                    "The trailing-space move is refused in chat and nothing moves")

        let allowing = NativeRuleSource()
        allowing.setGlobal(NativeRules(choices: [.fileEdits: .ask]))
        allowing.setRecords([try records.add(record(.allow, .fileEdits, target: NativeRuleTarget.folder(fixture.root + "/open")))])
        let write = tools[NativeFolderTools.writeName]!
        let sibling = NativeCompanionWorker.ruleDecision(write, ["path": .string(fixture.root + "/open /a.txt"), "content": .string("x")],
                                                         resolver: allowing.resolver(for: "c1", requestText: ""), honoringLimitedUse: true)
        let inside = NativeCompanionWorker.ruleDecision(write, ["path": .string(fixture.root + "/open/a.txt"), "content": .string("x")],
                                                        resolver: allowing.resolver(for: "c1", requestText: ""), honoringLimitedUse: true)
        let bare = NativeCompanionWorker.ruleDecision(tools[NativeFolderTools.trashName]!, ["path": .string(fixture.root + "/open ")],
                                                      resolver: allowing.resolver(for: "c1", requestText: ""), honoringLimitedUse: true)
        try require(sibling.decision == .ask && inside.decision == .act(.grant) && bare.decision != .act(.grant),
                    "An allow on a folder does not match its trailing-space sibling")

        for name in [" lead", "two  spaces", "tab\tend"] {
            let path = fixture.root + "/open/" + name
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let saved = try records.add(record(.forbid, .fileEdits, target: NativeRuleTarget.make(.folder, path)))
            let reread = try records.record(id: saved.id)
            let expected = NativeRuleTarget.realFolder(path)
            let child = NativeRuleTarget.folder(path + "/child.txt")!
            try require(reread?.target?.value == expected && expected?.hasSuffix("/" + name) == true
                        && reread?.target?.isSatisfied(by: NativeRuleTarget.folder(path)!, restricting: true) == true
                        && reread?.target?.isSatisfied(by: child, restricting: true) == true,
                        "A folder named \(name.debugDescription) round-trips through the store unchanged and matches itself")
        }
    }

    private static func prefixApprovalShortcut(_ require: (Bool, String) throws -> Void) throws {
        func source() -> NativeRuleSource {
            let source = NativeRuleSource()
            source.setGlobal(NativeRules(choices: [.commands: .ask]))
            source.set(NativeConversationRules(approvedCommandPrefixes: ["echo hello"]), for: "c1")
            return source
        }
        let plain = source()
        try require(ChatStore.prefixApprovalAnswers(plain, conversationID: "c1", requestText: "", command: "echo hello"),
                    "With zero records a prefix approved earlier in the chat still answers the confirmation without a card")
        try require(!ChatStore.prefixApprovalAnswers(plain, conversationID: "c1", requestText: "", command: "echo goodbye"),
                    "A command outside the approved prefix still presents a confirmation")
        let asking = source()
        asking.setRecords([record(.ask, .commands, statement: "Always ask before any command")])
        try require(!ChatStore.prefixApprovalAnswers(asking, conversationID: "c1", requestText: "", command: "echo hello"),
                    "A prefix approved earlier plus a saved ask record presents a confirmation")
        let broken = source()
        broken.fail()
        try require(!ChatStore.prefixApprovalAnswers(broken, conversationID: "c1", requestText: "", command: "echo hello"),
                    "A prefix approved earlier in failed mode presents a confirmation")
        let preapproved = NativeRuleSource()
        preapproved.setGlobal(NativeRules(choices: [.commands: .actIfPreapproved]))
        preapproved.setRecords([record(.ask, .commands)])
        try require(preapproved.resolver(for: "c1", requestText: "Go ahead and run it, no need to ask.").decision(forCommand: "echo hello") == .ask,
                    "A saved ask record also overrides a request pre-approval")
        let failedPreapproval = NativeRuleSource()
        failedPreapproval.setGlobal(NativeRules(choices: [.commands: .actIfPreapproved]))
        failedPreapproval.fail()
        try require(failedPreapproval.resolver(for: "c1", requestText: "Go ahead and run it, no need to ask.").decision(forCommand: "echo hello") == .ask,
                    "Failed mode also overrides a request pre-approval")
    }

    private static func commandValidationFirst(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let source = NativeRuleSource()
        ChatStore.prepareRules(source, from: records)
        source.setGlobal(NativeRules(choices: [.commands: .ask]))
        let once = try records.add(record(.allow, .commands, uses: 1))
        ChatStore.reloadRules(source, from: records)
        let command = NativeCommandTools.definitions(grants: { [fixture.grant] }, decision: .act(.rule), reason: { _ in nil }, record: { _ in },
                                                     liveTargets: { command, action, subjects in
            ChatStore.commandDecision(source, store: records, conversationID: "c1", requestText: "", command: command, action: action, subjects: subjects)
        })[0]
        let outcome = await run(command, ["command": .string("echo hi\u{0}there")])
        try require(outcome != "ran" && (try records.record(id: once.id))?.remainingUses == 1,
                    "A command with an embedded NUL is refused before a one-use allow is spent")
        var runnerRefused = false
        do { try NativeCommandRunner.validate("echo hi\u{0}there") } catch { runnerRefused = true }
        try require(runnerRefused, "The runner uses the same validator")
    }

    private static func rememberedApprovals(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        func source() -> NativeRuleSource {
            let source = NativeRuleSource()
            source.setGlobal(NativeRules(choices: [.commands: .ask]))
            source.set(NativeConversationRules(approvedCommandPrefixes: ["echo hello"]), for: "c1")
            return source
        }
        func tool(_ source: NativeRuleSource, reason: NativeRuleReason?) -> NativeToolDefinition {
            let closures = ChatStore.commandLive(source, store: nil, conversationID: "c1", requestText: "")
            return NativeCommandTools.definitions(grants: { [fixture.grant] }, decision: .ask, reason: { _ in reason }, record: { _ in },
                                                  live: closures.live, liveTargets: closures.liveTargets)[0]
        }
        func answers(_ source: NativeRuleSource, _ command: String) -> Bool {
            ChatStore.prefixApprovalAnswers(source, conversationID: "c1", requestText: "", command: command, grants: [fixture.grant])
        }
        let plain: [String: NativeJSONValue] = ["command": .string("echo hello")]
        let nonPlain: [String: NativeJSONValue] = ["command": .string("echo hello time")]
        let changed = NativeRuleResolver.changedMessage

        let healthy = source()
        let silent = tool(healthy, reason: nil)
        let silentRun = await run(silent, plain)
        try require(answers(healthy, "echo hello") && silent.confirmationFor?(plain) == false && silentRun == "ran",
                    "A plain command matching an approved prefix still runs without a card, as before")
        let remembered = await run(tool(healthy, reason: .conversationPrefix), nonPlain)
        try require(!answers(healthy, "echo hello time") && silent.confirmationFor?(nonPlain) == true && remembered == changed,
                    "A non-plain command is never answered by a remembered prefix")

        let failing = source()
        let answeredBeforeFailure = answers(failing, "echo hello")
        failing.fail()
        let afterFailure = await run(tool(failing, reason: .conversationPrefix), plain)
        try require(answeredBeforeFailure && afterFailure == changed,
                    "A remembered prefix answered before failed mode is refused at execution and nothing runs")
        let asking = source()
        let answeredBeforeRecord = answers(asking, "echo hello")
        asking.setRecords([record(.ask, .commands, statement: "Always ask before any command")])
        let afterRecord = await run(tool(asking, reason: .conversationPrefix), plain)
        try require(answeredBeforeRecord && afterRecord == changed,
                    "A remembered prefix answered before a saved ask record is refused at execution")
        let approvedUnderAsk = await run(tool(asking, reason: .userApproved), plain)
        let approvedFailed = await run(tool(failing, reason: .userApproved), plain)
        try require(approvedUnderAsk == "ran" && approvedFailed == "ran", "A real approval in this turn still runs under a saved ask and in failed mode")
        for reason in [NativeRuleReason.rule, .requestPreapproval, .conversationPrefix, .grant] {
            try require(!NativeCommandTools.approvedThisTurn(reason), "\(reason.rawValue) is a remembered reason, not an approval")
        }
        try require(NativeCommandTools.approvedThisTurn(.userApproved), "A click in this turn is a real approval")
    }

    private static func longNames(_ require: (Bool, String) throws -> Void) async throws {
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let open = fixture.root + "/open"
        try "x".write(toFile: open + "/from.txt", atomically: true, encoding: .utf8)
        let repository = try LocalChatRepository(inMemory: true)
        let records = store(repository, clock: NativeEffectTestClock(start))
        let source = NativeRuleSource()
        ChatStore.prepareRules(source, from: records)
        source.setGlobal(NativeRules(choices: [.fileEdits: .ask]))
        let once = try records.add(record(.allow, .fileEdits, target: NativeRuleTarget.folder(open), uses: 1))
        ChatStore.reloadRules(source, from: records)
        let tools = chatFolders(source, store: records, grant: fixture.grant)
        let long = String(repeating: "n", count: 300)
        let made = await run(tools[NativeFolderTools.mkdirName]!, ["path": .string(open + "/" + long)])
        try require(made != "ran" && (try records.record(id: once.id))?.remainingUses == 1, "A folder name longer than the volume allows is refused before the use is spent")
        let written = await run(tools[NativeFolderTools.writeName]!, ["path": .string(open + "/" + long), "content": .string("x")])
        try require(written != "ran" && (try records.record(id: once.id))?.remainingUses == 1, "A file name longer than the volume allows is refused before the use is spent")
        let moved = await run(tools[NativeFolderTools.moveName]!, ["from": .string(open + "/from.txt"), "to": .string(open + "/" + long)])
        try require(moved != "ran" && (try records.record(id: once.id))?.remainingUses == 1 && FileManager.default.fileExists(atPath: open + "/from.txt"),
                    "A move destination name longer than the volume allows is refused before the use is spent")
    }
}
