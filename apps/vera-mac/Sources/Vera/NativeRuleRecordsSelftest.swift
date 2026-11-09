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
                                                            remainingUses: 3, expiresAt: start.addingTimeInterval(3600))))
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
                try db.execute(sql: "DROP TABLE native_rule_epoch")
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
            (try db.tableExists("native_rule_records"), try Int.fetchOne(db, sql: "SELECT value FROM native_rule_epoch WHERE id = 1"),
             try db.columns(in: "native_rule_records").map(\.name))
        }
        try require(migrated.0 && migrated.1 == 0, "V35 applies on top of a V34 database with the epoch at zero")
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
        try require(fresh.revision == 0, "With epoch zero and no records the revision starts at zero")
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
        let firstEpoch = try records.advanceEpoch()
        let secondEpoch = try records.advanceEpoch()
        try require(firstEpoch == 1 && secondEpoch == 2, "Advancing the epoch twice gives increasing values")
        let before = NativeRuleSource()
        before.setEpoch(firstEpoch)
        for index in 0..<1000 {
            before.setGlobal(NativeRules(choices: [.trash: index % 2 == 0 ? .act : .ask]))
        }
        let highest = before.revision
        try require(highest == firstEpoch * NativeRuleSource.epochStride + 1000, "A thousand bumps under the first epoch are all counted")
        let after = NativeRuleSource()
        after.setEpoch(secondEpoch)
        try require(after.revision > highest, "A source seeded with the next epoch starts above anything the previous launch reached")
        after.setGlobal(NativeRules(choices: [.trash: .act]))
        try require(after.revision == secondEpoch * NativeRuleSource.epochStride + 1, "The same in-memory counter under a new epoch is a different revision")
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
}
