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
        try floorAndText(require)
        try floorResolution(require)
        try actionMigration(require)
        try prefixMigration(require)
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

    static func commandSubject(_ command: String, action: NativeActionClass = .commands) -> NativeCardSubject {
        NativeCardSubject(action: action, toolID: NativeCommandTools.toolID, toolTitle: "Run a command", command: command)
    }

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
        try require(other.decision == .ask && other.resolution == nil, "Another recipient falls back to the class default")
        try require(narrow.decision(for: .networkSends) == .ask, "A class-level decision ignores the recipient allow")

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

        func tightened(_ own: NativeRuleChoice, over base: NativeRuleChoice, _ records: [NativeRuleRecord], request: String = "") -> NativeRuleResolver {
            var global = NativeRules.defaults
            global.set(base, for: .networkSends)
            return NativeRuleResolver(global: global, conversation: NativeConversationRules(choices: [.networkSends: own]), requestText: request,
                                      records: records, context: NativeRuleContext(conversationID: "c1"), now: start)
        }
        let plain = NativeRuleQuery(action: .networkSends, toolID: "mail", targets: [])
        let hereAllow = record(.allow, scope: .conversation("c1"), statement: "Always allow sending in this chat")
        let leftHere = tightened(.handOff, over: .ask, [hereAllow])
        let leftWhy = leftHere.tool("mail", targets: []).explain(for: .networkSends)
        try require(leftHere.resolve(plain, honoringLimitedUse: false).decision == .handOff
                        && leftWhy?.kind == .unsaved && leftWhy?.source == .chat && leftWhy?.choice == .handOff && leftWhy?.handsOff == true,
                    "A chat set to leave a kind to you is not loosened by an allow for that whole kind in the chat: \(String(describing: leftWhy))")
        for kindWide in [hereAllow, record(.allow)] {
            let asking = tightened(.ask, over: .act, [kindWide])
            let askWhy = asking.tool("mail", targets: []).explain(for: .networkSends)
            try require(asking.resolve(plain, honoringLimitedUse: false).decision == .ask && askWhy?.source == .chat && askWhy?.choice == .ask,
                        "A chat set to ask first is not loosened by an allow for that whole kind, wherever it was saved")
        }
        let spare = tightened(.handOff, over: .ask, [record(.allow, scope: .conversation("c1"), uses: 1)]).resolve(plain, honoringLimitedUse: true)
        try require(spare.decision == .handOff && spare.authorizedBy.isEmpty, "A one-use allow that did not decide is not relied on")
        try require(tightened(.handOff, over: .ask, [record(.allow, scope: .conversation("c1"), tool: "mail")]).resolve(plain, honoringLimitedUse: false).decision == .act(.grant),
                    "An allow for one tool is more specific than the chat's choice and still wins")
        var namedAlice = tightened(.handOff, over: .ask, [record(.allow, scope: .conversation("c1"), target: alice)])
        namedAlice.typed = NativeTypedWords(typed: "Send it to alice@example.com")
        try require(namedAlice.resolve(toAlice, honoringLimitedUse: false).decision == .act(.grant)
                        && namedAlice.resolve(toBob, honoringLimitedUse: false).decision == .handOff,
                    "An allow for one recipient still wins for that recipient only")
        try require(tightened(.ask, over: .ask, [hereAllow]).resolve(plain, honoringLimitedUse: false).decision == .act(.grant)
                        && tightened(.act, over: .ask, [hereAllow]).resolve(plain, honoringLimitedUse: false).decision == .act(.grant)
                        && resolver([hereAllow]).resolve(plain, honoringLimitedUse: false).decision == .act(.grant),
                    "A chat that is not stricter than Settings leaves saved allows as they were")
        try require(tightened(.handOff, over: .ask, [record(.ask), hereAllow]).resolve(plain, honoringLimitedUse: false).decision == .ask,
                    "A saved ask for the whole kind still decides as before")

        let carveOut = resolver([record(.allow), record(.forbid, target: alice)])
        var carveOutNamed = carveOut
        carveOutNamed.typed = NativeTypedWords(typed: "Send the notes to bob@example.com")
        try require(carveOut.resolve(toAlice, honoringLimitedUse: false).resolution?.decidedBy.effect == .forbid
                    && carveOutNamed.resolve(toBob, honoringLimitedUse: false).decision == .act(.grant),
                    "A narrower forbid blocks its target while a broader allow covers the rest")
        try require(carveOut.resolve(toBob, honoringLimitedUse: false).decision == .ask,
                    "A broader allow never covers a recipient that was not typed")

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
        let chatAllow = NativeCardChoices.records(.allowHere, subject: commandSubject("make check"), place: .chat(conversationID: "c1"), originMessageID: nil)
        try require(resolver(chatAllow).tool(NativeCommandTools.toolID, targets: []).decision(forCommand: "make check") == .act(.grant)
                    && resolver(chatAllow, context: NativeRuleContext(conversationID: "c2")).tool(NativeCommandTools.toolID, targets: []).decision(forCommand: "make check") == .ask
                    && NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "").decision(forCommand: "make check") == .ask,
                    "A chat's saved prefix allow runs only in that chat and nothing runs without a record")
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

    private static func floorAndText(_ require: (Bool, String) throws -> Void) throws {
        let held = resolver([record(.allow, .payments), record(.allow, .payments, tool: "vault")])
        let resolved = held.resolve(NativeRuleQuery(action: .payments, toolID: "vault"), honoringLimitedUse: true)
        try require(held.decision(for: .payments) == .handOff && resolved.decision == .handOff && resolved.resolution == nil,
                    "A record on a held floor class changes nothing")
        let text = resolver([record(.allow, nil, statement: "You can always trash my downloads")])
        try require(text.decision(for: .trash) == .ask && text.resolve(NativeRuleQuery(action: .trash), honoringLimitedUse: true).resolution == nil,
                    "A text-only record never matches")
    }

    private static func floorResolution(_ require: (Bool, String) throws -> Void) throws {
        for action in [NativeActionClass.credentialEntry, .payments, .permanentDeletion] {
            guard let item = action.floorItem else { throw NativeTaskFixture.Failure.assertion("\(action.rawValue) is a floor class") }
            try require(resolver([]).decision(for: action) == .handOff, "\(action.rawValue) hands off with nothing lifted")
            let allowed = resolver([record(.allow, action)])
            try require(allowed.decision(for: action) == .handOff && allowed.resolve(NativeRuleQuery(action: action), honoringLimitedUse: true).decision == .handOff,
                        "An everywhere allow never opens a held \(action.rawValue)")
            let tooled = resolver([record(.allow, action, tool: "vault")]).resolve(NativeRuleQuery(action: action, toolID: "vault"), honoringLimitedUse: true)
            try require(tooled.decision == .handOff && tooled.resolution == nil && tooled.authorizedBy.isEmpty, "A tool allow never opens a held \(action.rawValue)")
            var asking = NativeRules.defaults
            asking.lift(item, choice: .ask)
            try require(resolver([], global: asking).decision(for: action) == .ask, "A lifted \(action.rawValue) set to ask asks")
            var acting = asking
            acting.set(.act, for: action)
            try require(resolver([], global: acting).decision(for: action) == .act(.rule), "A lifted \(action.rawValue) set to act acts")
            try require(resolver([record(.allow, action)], global: asking).decision(for: action) == .act(.grant), "A lifted \(action.rawValue) honors an allow record")
            var chat = NativeConversationRules()
            chat.tighten(.act, for: action, global: asking)
            let loosened = NativeRuleResolver(global: asking, conversation: NativeConversationRules(choices: [action: .act]), requestText: "",
                                              context: NativeRuleContext(conversationID: "c1"), now: start)
            try require(chat.isEmpty && loosened.decision(for: action) == .ask, "A chat cannot loosen a lifted \(action.rawValue) below the global choice")
        }
    }

    private static func prefixMigration(_ require: (Bool, String) throws -> Void) throws {
        func prepared() throws -> DatabaseQueue {
            let queue = try DatabaseQueue()
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE conversations (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, rules_json TEXT)")
                try NativeRuleRecordStore.migrate(db)
                try NativeRuleRecordStore.migrateActions(db)
                try NativeRuleRecordStore.migrateCards(db)
            }
            return queue
        }
        func version(_ queue: DatabaseQueue) throws -> Int { try queue.read { try NativeRuleRecordStore.version($0) } }
        func stored(_ queue: DatabaseQueue, _ id: String) throws -> String? {
            try queue.read { try String.fetchOne($0, sql: "SELECT rules_json FROM conversations WHERE id = ?", arguments: [id]) }
        }
        let queue = try prepared()
        let malformed = "{\"choices\": {\"commands\": \"hand_off\"}, \"approved_command_prefixes\": [\"git status\""
        let rows: [(String, String?)] = [
            ("two", "{\"choices\":{\"trash\":\"hand_off\"},\"approved_command_prefixes\":[\"swift build\",\"make check\"]}"),
            ("messy", "{\"choices\":{},\"approved_command_prefixes\":[\"npm test\",\"\",\"npm   test\",\"git log --oneline\"]}"),
            ("choices", "{\"choices\":{\"commands\":\"hand_off\"}}"),
            ("empty", nil),
            ("broken", malformed),
        ]
        try queue.write { db in
            for (id, rules) in rows {
                try db.execute(sql: "INSERT INTO conversations(id, title, rules_json) VALUES(?, ?, ?)", arguments: [id, "Chat " + id, rules])
            }
        }
        let before = try version(queue)
        try queue.write { try NativeRuleRecordStore.migratePrefixes($0) }
        let records = try NativeRuleRecordStore(database: queue).all()
        let origins = try queue.read { try String.fetchAll($0, sql: "SELECT origin FROM native_rule_records") }
        func values(_ chat: String) -> Set<String> { Set(records.filter { $0.scope == .conversation(chat) }.compactMap(\.target?.value)) }
        try require(records.count == 4 && values("two") == ["swift build", "make check"] && values("messy") == ["npm test", "git log"],
                    "Each distinct saved prefix becomes one record in its chat, normalized to two words")
        try require(records.allSatisfy { $0.action == .commands && $0.toolID == NativeCommandTools.toolID && $0.effect == .allow && $0.origin == .migration
                        && $0.target?.kind == .commandPrefix && $0.originMessageID == nil && $0.status == .active
                        && $0.originConversationID == $0.scope.scopeID && $0.statement.hasPrefix("In this chat, allow commands that start with ") }
                    && Set(origins) == ["migration"], "Migrated prefixes are active chat-scoped command allows from the migration")
        try require(values("choices").isEmpty && values("empty").isEmpty && values("broken").isEmpty, "Chats without prefixes get no records")
        try require(NativeConversationRules.decode(try stored(queue, "two")).choices == [.trash: .handOff]
                    && NativeConversationRules.decode(try stored(queue, "choices")).choices == [.commands: .handOff]
                    && (try stored(queue, "messy")) == nil && (try stored(queue, "empty")) == nil,
                    "Chat rules keep their choices and an emptied rule set stores nothing")
        try require(try ["two", "choices"].allSatisfy { try stored(queue, $0)?.contains("approved_command_prefixes") == false },
                    "No prefix list is left in the stored chat rules")
        try require((try stored(queue, "broken")) == malformed, "Malformed chat rules are left untouched")
        try require(try version(queue) == before + 1, "The rules version advances exactly once")
        try queue.write { try NativeRuleRecordStore.migratePrefixes($0) }
        try require(try version(queue) == before + 1 && (try NativeRuleRecordStore(database: queue).all()).count == 4,
                    "Running again without prefixes leaves the records and the version alone")
        let quiet = try prepared()
        try quiet.write { db in
            try db.execute(sql: "INSERT INTO conversations(id, title, rules_json) VALUES(?, ?, ?)", arguments: ["plain", "Plain", "{\"choices\":{}}"])
        }
        let quietBefore = try version(quiet)
        try quiet.write { try NativeRuleRecordStore.migratePrefixes($0) }
        try require(try version(quiet) == quietBefore, "A database with no prefixes keeps its version")
        let empty = try prepared()
        try empty.write { try NativeRuleRecordStore.migratePrefixes($0) }
        try require(try NativeRuleRecordStore(database: empty).all().isEmpty, "An empty conversation table migrates cleanly")
        let lengthy = try prepared()
        let longWord = String(repeating: "a", count: 280)
        try lengthy.write { db in
            try db.execute(sql: "INSERT INTO conversations(id, title, rules_json) VALUES(?, ?, ?)",
                           arguments: ["long", "Long", "{\"choices\":{},\"approved_command_prefixes\":[\"echo \(longWord)\",\"git status\"]}"])
        }
        try lengthy.write { try NativeRuleRecordStore.migratePrefixes($0) }
        let carried = try NativeRuleRecordStore(database: lengthy).all()
        try require(carried.count == 2 && carried.contains { $0.target?.value == "echo " + longWord && $0.statement == "In this chat, allow a command you approved earlier" }
                    && carried.allSatisfy { $0.statement.count <= NativeRuleRecord.maximumStatementCharacters },
                    "A very long approved prefix is carried over with a short sentence, never dropped")
        let longRules = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "", records: carried,
                                           context: NativeRuleContext(conversationID: "long")).tool(NativeCommandTools.toolID, targets: [])
        try require(longRules.decision(forCommand: "echo " + longWord) == .act(.grant), "The long approval still runs without asking")
        func decision(_ chat: String) -> NativeRuleDecision {
            NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "", records: records,
                               context: NativeRuleContext(conversationID: chat)).tool(NativeCommandTools.toolID, targets: []).decision(forCommand: "swift build -c release")
        }
        try require(decision("two") == .act(.grant) && decision("messy") == .ask, "A migrated chat still runs its approved prefix and another chat asks")
    }

    private static func actionMigration(_ require: (Bool, String) throws -> Void) throws {
        try require(Set(NativeRuleRecordStore.storedActions) == Set(NativeActionClass.allCases.map(\.rawValue)), "Every action class can be stored")
        let insert = """
            INSERT INTO native_rule_records(id, scope_kind, scope_id, action, tool_id, target_kind, target_value, effect, statement, origin,
                origin_conversation_id, origin_message_id, quote, reason, remaining_uses, expires_at, status, created_at, updated_at, revoked_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        func row(_ id: String, scope: String = "everywhere", scopeID: String? = nil, action: String?, tool: String? = nil, targetKind: String? = nil,
                 targetValue: String? = nil, effect: String, origin: String = "settings", conversation: String? = nil, message: String? = nil,
                 uses: Int? = nil, expires: Double? = nil, status: String = "active", revoked: Double? = nil) -> StatementArguments {
            [id, scope, scopeID, action, tool, targetKind, targetValue, effect, "Rule " + id, origin, conversation, message,
             "a quote", "a reason", uses, expires, status, 1_800_000_000.25, 1_800_000_100.5, revoked]
        }
        func snapshot(_ db: Database) throws -> [String: [String: DatabaseValue]] {
            var rows: [String: [String: DatabaseValue]] = [:]
            for found in try Row.fetchAll(db, sql: "SELECT * FROM native_rule_records") {
                let values = Dictionary(uniqueKeysWithValues: found.columnNames.map { ($0, found[$0] as DatabaseValue) })
                rows[found["id"] as String] = values
            }
            return rows
        }
        func version(_ db: Database) throws -> Int { try Int.fetchOne(db, sql: "SELECT value FROM native_rule_version WHERE id = 1") ?? -1 }
        func rejects(_ queue: DatabaseQueue, _ arguments: StatementArguments) -> Bool {
            do { try queue.write { try $0.execute(sql: insert, arguments: arguments) }; return false } catch { return true }
        }

        let queue = try DatabaseQueue()
        try queue.write { db in
            try NativeRuleRecordStore.migrate(db)
            try db.execute(sql: insert, arguments: row("allow-send", action: "network_sends", tool: "mail", targetKind: "recipient", targetValue: "alice@example.com",
                                                       effect: "allow", origin: "chat", conversation: "c1", message: "m1", uses: 3, expires: 1_800_003_600.75))
            try db.execute(sql: insert, arguments: row("ask-trash", scope: "conversation", scopeID: "c1", action: "trash", effect: "ask"))
            try db.execute(sql: insert, arguments: row("hand-commands", scope: "project", scopeID: "p1", action: "commands", effect: "hand_off", status: "revoked", revoked: 1_800_000_200))
            try db.execute(sql: insert, arguments: row("forbid-folder", action: "file_edits", targetKind: "folder", targetValue: "/Volumes/Notes/Locked", effect: "forbid"))
            try db.execute(sql: insert, arguments: row("allow-prefix", action: "commands", targetKind: "command_prefix", targetValue: "swift build", effect: "allow"))
            try db.execute(sql: insert, arguments: row("text-only", action: nil, effect: "ask", origin: "chat"))
            try db.execute(sql: insert, arguments: row("old-one", action: "sensitive", effect: "allow"))
            try db.execute(sql: insert, arguments: row("old-two", action: "sensitive", tool: "vault", effect: "hand_off", message: "m2"))
        }
        let before = try queue.read { db in (try snapshot(db), try version(db)) }
        try queue.write { try NativeRuleRecordStore.migrateActions($0) }
        let after = try queue.read { db in
            (try snapshot(db), try version(db),
             Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'native_rule_records' AND sql IS NOT NULL")))
        }
        var expected = before.0
        expected.removeValue(forKey: "old-one")
        expected.removeValue(forKey: "old-two")
        try require(expected.count == 6 && after.0 == expected, "Every row outside the old class survives byte for byte")
        try require(after.0["old-one"] == nil && after.0["old-two"] == nil, "Rows on the old class are dropped")
        try require(after.1 > before.1, "Dropping rows advances the rules version")
        try require(after.2 == ["native_rule_records_status_action", "native_rule_records_origin_message"], "Both indexes exist after the rebuild")
        try require(!rejects(queue, row("pay", action: "payments", effect: "allow")), "A payments row can be stored")
        try require(rejects(queue, row("old-three", action: "sensitive", effect: "allow")), "A row on the old class is rejected")
        try require(rejects(queue, row("uses-ask", action: "trash", effect: "ask", uses: 2)), "Remaining uses on a non-allow are rejected")
        try require(rejects(queue, row("prefix-forbid", action: "commands", targetKind: "command_prefix", targetValue: "rm", effect: "forbid")),
                    "A command prefix forbid is rejected")
        try require(rejects(queue, row("folder-commands", action: "commands", targetKind: "folder", targetValue: "/Volumes/Notes", effect: "forbid")),
                    "A folder target on commands is rejected")
        try require(rejects(queue, row("duplicate-message", action: "trash", effect: "ask", message: "m1")), "A duplicate origin message is rejected")

        let beforeCards = try queue.read { db in (try snapshot(db), try version(db)) }
        try queue.write { try NativeRuleRecordStore.migrateCards($0) }
        let afterCards = try queue.read { db in
            (try snapshot(db), try version(db),
             Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'native_rule_records' AND sql IS NOT NULL")))
        }
        var trimmed = afterCards.0
        for key in trimmed.keys { trimmed[key]?.removeValue(forKey: "origin_tool_call_id") }
        try require(trimmed == beforeCards.0 && afterCards.0.values.allSatisfy { $0["origin_tool_call_id"] == .some(.null) },
                    "The card rebuild keeps every row byte for byte and adds an empty tool call column")
        try require(afterCards.1 == beforeCards.1, "The card rebuild leaves the rules version alone")
        try require(afterCards.2 == ["native_rule_records_status_action", "native_rule_records_origin_message"], "Both indexes exist after the card rebuild")
        let cardInsert = """
            INSERT INTO native_rule_records(id, scope_kind, scope_id, action, tool_id, target_kind, target_value, effect, statement, origin,
                origin_conversation_id, origin_message_id, origin_tool_call_id, status, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, NULL, NULL, ?, 'Rule', 'confirm_card', 'c', ?, ?, 'active', 1, 1)
            """
        func cardRejects(_ id: String, scope: String = "conversation", scopeID: String? = "c", action: String?, tool: String?, effect: String,
                         message: String?, call: String?) -> Bool {
            do { try queue.write { try $0.execute(sql: cardInsert, arguments: [id, scope, scopeID, action, tool, effect, message, call]) }; return false }
            catch { return true }
        }
        try require(rejects(queue, row("uses-ask-two", action: "trash", effect: "ask", uses: 2))
                    && rejects(queue, row("prefix-forbid-two", action: "commands", targetKind: "command_prefix", targetValue: "rm", effect: "forbid"))
                    && rejects(queue, row("folder-commands-two", action: "commands", targetKind: "folder", targetValue: "/Volumes/Notes", effect: "forbid"))
                    && rejects(queue, row("old-four", action: "sensitive", effect: "allow"))
                    && rejects(queue, row("duplicate-message-two", action: "trash", effect: "ask", message: "m1")),
                    "Every earlier constraint still holds after the card rebuild")
        try require(!cardRejects("card-one", action: "commands", tool: "folder-commands", effect: "allow", message: "m9", call: "call-1")
                    && !cardRejects("card-two", action: "commands", tool: "folder-commands", effect: "allow", message: "m9", call: "call-2"),
                    "Two cards on one message each keep their rule")
        try require(cardRejects("card-three", action: "commands", tool: "folder-commands", effect: "allow", message: "m9", call: "call-1"),
                    "The same card on the same message is stored once")
        try require(cardRejects("card-four", action: "trash", tool: nil, effect: "ask", message: "m1", call: nil)
                    && !cardRejects("card-five", action: "trash", tool: nil, effect: "ask", message: "m1", call: "call-1"),
                    "A captured rule still owns its message, and a card on that message is separate")
        try require(cardRejects("card-six", action: "trash", tool: nil, effect: "ask", message: nil, call: "call-1"), "A tool call without a message is rejected")
        try require(!cardRejects("wide-never", action: nil, tool: "folder-commands", effect: "forbid", message: nil, call: nil)
                    && !cardRejects("wide-ask", action: nil, tool: "folder-commands", effect: "ask", message: nil, call: nil)
                    && !cardRejects("wide-hand", action: nil, tool: "folder-commands", effect: "hand_off", message: nil, call: nil),
                    "A tool-wide rule with no kind can ask, hand off or forbid")
        try require(cardRejects("wide-allow", action: nil, tool: "folder-commands", effect: "allow", message: nil, call: nil),
                    "The database rejects a tool-wide allow with no kind")
        let wideAllow = NativeRuleRecord(action: nil, toolID: NativeCommandTools.toolID, effect: .allow, statement: "Allow the tool")
        try require((try? NativeRuleRecord.validated(wideAllow, creating: true)) == nil
                    && (try? NativeRuleRecord.validated(NativeRuleRecord(action: nil, toolID: NativeCommandTools.toolID, effect: .forbid, statement: "Never"), creating: true)) != nil
                    && (try? NativeRuleRecord.validated(NativeRuleRecord(action: nil, target: NativeRuleTarget.make(.commandPrefix, "git status"), effect: .forbid, statement: "Never"), creating: true)) == nil,
                    "Validation rejects a tool-wide allow with no kind and a target with no kind, and accepts a tool-wide never")
        var liftedRules = NativeRules.defaults
        for action in NativeActionClass.configurable { liftedRules.set(.act, for: action) }
        for item in NativeFloorItem.allCases { liftedRules.lift(item, choice: .act) }
        let wideNever = NativeRuleRecord(scope: .conversation("c"), action: nil, toolID: NativeCommandTools.toolID, effect: .forbid, statement: "Never run commands in this chat")
        let prefixAllow = NativeRuleRecord(action: .commands, toolID: NativeCommandTools.toolID, target: NativeRuleTarget.make(.commandPrefix, "git status"), effect: .allow, statement: "Always allow git status")
        let kindAllow = NativeRuleRecord(action: .riskyCommands, toolID: NativeCommandTools.toolID, effect: .allow, statement: "Allow risky commands")
        func decided(_ records: [NativeRuleRecord], _ action: NativeActionClass, conversation: String = "c", tool: String = NativeCommandTools.toolID, command: String? = nil) -> NativeRuleDecision {
            let base = NativeRuleResolver(global: liftedRules, conversation: NativeConversationRules(), requestText: "", records: records,
                                          context: NativeRuleContext(conversationID: conversation))
            let scoped = base.tool(tool, subjects: command.map { NativeCommandTools.ruleSubjects(command: $0) } ?? [])
            return command != nil && action == .commands ? scoped.decision(forCommand: command!) : scoped.decision(for: action)
        }
        for action in [NativeActionClass.commands, .riskyCommands, .networkSends, .permanentDeletion] {
            try require(decided([wideNever], action) == .handOff, "A tool-wide never stops \(action.rawValue) from the command tool, a lifted floor kind included")
            try require(decided([wideNever], action, conversation: "other") != .handOff, "A tool-wide never in one chat leaves \(action.rawValue) alone in another")
        }
        try require(decided([wideNever], .fileEdits, tool: NativeFolderTools.toolID) != .handOff, "A tool-wide never on one tool leaves other tools alone")
        try require(decided([wideNever, kindAllow], .riskyCommands) == .handOff, "At tool level a never beats an allow that names a kind")
        try require(decided([wideNever, prefixAllow], .commands, command: "git status -s") == .act(.grant)
                    && decided([wideNever, prefixAllow], .commands, command: "git push") == .handOff,
                    "A narrower allow beats a tool-wide never for its own prefix only")

        let clean = try DatabaseQueue()
        try clean.write { db in
            try NativeRuleRecordStore.migrate(db)
            try db.execute(sql: insert, arguments: row("allow-send", action: "network_sends", effect: "allow"))
        }
        let cleanBefore = try clean.read { try version($0) }
        try clean.write { try NativeRuleRecordStore.migrateActions($0) }
        let cleanAfter = try clean.read { db in (try version(db), try snapshot(db).count) }
        try require(cleanAfter.0 == cleanBefore && cleanAfter.1 == 1, "A database without old rows keeps its rules version")
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
        try require(source.hasFailed && source.currentRecords == [forbid] && after != before && after < 0 && source.revision == after
                    && source.resolver(for: "c1", requestText: "").decision(for: .trash) == .ask,
                    "A failed reload fails closed: allows are dropped, restrictions stay and the revision is a stable negative one")
        let launchRepository = try LocalChatRepository(inMemory: true)
        try launchRepository.database.write { db in try db.execute(sql: "DROP TABLE native_rule_version") }
        let failedLaunch = NativeRuleSource()
        failedLaunch.setRecords([record(.allow, .trash)])
        ChatStore.prepareRules(failedLaunch, from: store(launchRepository, clock: NativeEffectTestClock(start)))
        try require(failedLaunch.hasFailed && failedLaunch.currentRecords.isEmpty && failedLaunch.revision < 0 && failedLaunch.revision == failedLaunch.revision,
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
            do { _ = try await foreground.execute(arguments) } catch { message = outcomeText(error) }
            try require(blocks ? message == refusedText(.rule, .commands) : message == NativeRuleResolver.changedMessage,
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
            do { _ = try await definition.execute(arguments); return "ran" } catch { return outcomeText(error) }
        }
        let inside: [String: NativeJSONValue] = ["path": .string(locked + "/a.txt"), "content": .string("x")]
        let sibling: [String: NativeJSONValue] = ["path": .string(fixture.root + "/open/a.txt"), "content": .string("x")]
        let intoLocked: [String: NativeJSONValue] = ["from": .string(fixture.root + "/open/a.txt"), "to": .string(locked + "/b.txt")]
        let handed = refusedText(.rule, .fileEdits)
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
                                        parameters: .object(["type": .string("object")]), confirmation: .none,
                                        isAvailable: { true }, execute: { _ in .null })
        send.effect = .write
        send.action = .networkSends
        let spoof: [String: NativeJSONValue] = ["path": .string("alice@example.com"), "destination": .string("bob@example.com")]
        let allowing = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "",
                                          records: [record(.allow, target: recipient("alice@example.com"))], context: NativeRuleContext(conversationID: "c1"), now: start)
        let spoofed = NativeCompanionWorker.ruleDecision(send, spoof, resolver: allowing, honoringLimitedUse: true)
        try require(spoofed.decision == .ask && spoofed.authorizedBy.isEmpty && NativeCompanionWorker.ruleQuery(send, spoof, action: .networkSends).targets.isEmpty,
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
        let handed = refusedText(.rule, .fileEdits)
        for path in [fixture.root + "/locked/a.txt", link.path + "/locked/b.txt"] {
            var message = ""
            do { _ = try await write.execute(["path": .string(path), "content": .string("x")]) } catch { message = outcomeText(error) }
            try require(message == handed && !FileManager.default.fileExists(atPath: fixture.root + "/locked/" + URL(fileURLWithPath: path).lastPathComponent),
                        "The symlink-spelled forbid blocks a write addressed as \(path == fixture.root + "/locked/a.txt" ? "the real path" : "the symlink")")
        }
        var sibling = ""
        do { _ = try await write.execute(["path": .string(fixture.root + "/open/c.txt"), "content": .string("x")]); sibling = "ran" } catch { sibling = outcomeText(error) }
        try require(sibling == "ran", "The sibling folder still acts")
    }

    static func chatFolders(_ source: NativeRuleSource, store records: NativeRuleRecordStore?, grant: FolderGrant) -> [String: NativeToolDefinition] {
        let definitions = NativeFolderTools.definitions(grants: { [grant] }, ledger: NativeFileChangeLedger(), edits: .act(.rule),
                                                        liveTargets: { action, subjects in
            ChatStore.folderDecision(source, store: records, conversationID: "c1", requestText: "", action: action, subjects: subjects)
        })
        return Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
    }

    static func outcomeText(_ error: Error) -> String {
        guard let refusal = error as? NativeRuleRefusal else { return error.localizedDescription }
        return refusedText(refusal.why.kind, refusal.why.action)
    }

    static func refusedText(_ kind: NativeRuleWhy.Kind, _ action: NativeActionClass) -> String {
        "refused \(kind.rawValue) \(action.rawValue)"
    }

    static func run(_ definition: NativeToolDefinition, _ arguments: [String: NativeJSONValue]) async -> String {
        do { _ = try await definition.execute(arguments); return "ran" } catch { return outcomeText(error) }
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
        let handed = refusedText(.rule, .fileEdits)
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
        try require(moveRun == refusedText(.rule, .fileEdits) && FileManager.default.fileExists(atPath: protected + "/secret.txt"),
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
        try require(decided.decision == .handOff && made == refusedText(.rule, .fileEdits)
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
            try require(made == refusedText(.rule, .fileEdits) && !FileManager.default.fileExists(atPath: open + "/locked"),
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
        try require(moved == refusedText(.rule, .fileEdits) && FileManager.default.fileExists(atPath: protected),
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
        let fixture = try folderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let saved = NativeCardChoices.records(.allowHere, subject: commandSubject("echo hello"), place: .chat(conversationID: "c1"), originMessageID: nil)
        func source(_ extra: [NativeRuleRecord] = []) -> NativeRuleSource {
            let source = NativeRuleSource()
            source.setGlobal(NativeRules(choices: [.commands: .ask]))
            source.setRecords(saved + extra)
            return source
        }
        func asks(_ source: NativeRuleSource, _ command: String, conversation: String = "c1") -> Bool {
            let closures = ChatStore.commandLive(source, store: nil, conversationID: conversation, requestText: "")
            let tool = NativeCommandTools.definitions(grants: { [fixture.grant] }, decision: .ask, reason: { _ in nil }, record: { _ in },
                                                      live: closures.live, liveTargets: closures.liveTargets)[0]
            return tool.confirmationFor?(["command": .string(command)]) ?? true
        }
        let plain = source()
        try require(saved.count == 1 && !asks(plain, "echo hello"), "A plain command under a prefix saved in this chat needs no card")
        try require(asks(plain, "echo goodbye"), "A command outside the saved prefix still presents a confirmation")
        try require(asks(plain, "echo hello", conversation: "c2"), "A prefix saved in one chat still presents a confirmation in another")
        try require(asks(plain, "echo hello | cat") && asks(plain, "FOO=1 echo hello") && asks(plain, "echo hello \"x\""),
                    "A non-plain command is never answered by a saved prefix")
        let asking = source([record(.ask, .commands, statement: "Always ask before any command")])
        try require(!asks(asking, "echo hello") && asks(asking, "echo goodbye") && asks(asking, "echo hello", conversation: "c2"),
                    "A saved prefix outranks a broader ask record, which still asks for everything the prefix does not cover")
        let pinned = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "",
                                        records: saved + [record(.ask, .commands, statement: "Always ask before any command")],
                                        context: NativeRuleContext(conversationID: "c1")).tool(NativeCommandTools.toolID, targets: [])
        try require(pinned.decision(forCommand: "echo hello") == .act(.grant) && pinned.decision(forCommand: "echo goodbye") == .ask,
                    "A chat-scoped prefix allow beats an everywhere class-level ask for that prefix only")
        let broken = source()
        broken.fail()
        try require(asks(broken, "echo hello"), "A saved prefix allow in failed mode presents a confirmation")
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
        let saved = NativeCardChoices.records(.allowHere, subject: commandSubject("echo hello"), place: .chat(conversationID: "c1"), originMessageID: nil)
        func source() -> NativeRuleSource {
            let source = NativeRuleSource()
            source.setGlobal(NativeRules(choices: [.commands: .ask]))
            source.setRecords(saved)
            return source
        }
        func tool(_ source: NativeRuleSource, reason: NativeRuleReason?) -> NativeToolDefinition {
            let closures = ChatStore.commandLive(source, store: nil, conversationID: "c1", requestText: "")
            return NativeCommandTools.definitions(grants: { [fixture.grant] }, decision: .ask, reason: { _ in reason }, record: { _ in },
                                                  live: closures.live, liveTargets: closures.liveTargets)[0]
        }
        func answers(_ source: NativeRuleSource, _ command: String) -> Bool {
            tool(source, reason: nil).confirmationFor?(["command": .string(command)]) == false
        }
        let plain: [String: NativeJSONValue] = ["command": .string("echo hello")]
        let nonPlain: [String: NativeJSONValue] = ["command": .string("echo hello time")]
        let changed = NativeRuleResolver.changedMessage

        let healthy = source()
        let silent = tool(healthy, reason: nil)
        let silentRun = await run(silent, plain)
        try require(answers(healthy, "echo hello") && silent.confirmationFor?(plain) == false && silentRun == "ran",
                    "A plain command matching a saved prefix allow runs without a card")
        let remembered = await run(tool(healthy, reason: .rule), nonPlain)
        try require(!answers(healthy, "echo hello time") && silent.confirmationFor?(nonPlain) == true && remembered == changed,
                    "A non-plain command is never answered by a saved prefix")

        let failing = source()
        let answeredBeforeFailure = answers(failing, "echo hello")
        failing.fail()
        let afterFailure = await run(tool(failing, reason: .rule), plain)
        try require(answeredBeforeFailure && afterFailure == changed,
                    "A saved prefix answered before failed mode is refused at execution and nothing runs")
        let asking = source()
        let answeredBeforeRecord = answers(asking, "echo hello")
        asking.setRecords([record(.ask, .commands, statement: "Always ask before any command")])
        let afterRecord = await run(tool(asking, reason: .rule), plain)
        try require(answeredBeforeRecord && afterRecord == changed,
                    "A saved prefix answered before it was replaced by an ask record is refused at execution")
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
        let wide = String(repeating: "\u{4e2d}", count: 100)
        let plain = chatFolders(NativeRuleSource(), store: nil, grant: fixture.grant)
        let madeWide = await run(plain[NativeFolderTools.mkdirName]!, ["path": .string(open + "/" + wide)])
        let nestedWide = await run(plain[NativeFolderTools.mkdirName]!, ["path": .string(open + "/fresh/" + wide)])
        let wroteWide = await run(plain[NativeFolderTools.writeName]!, ["path": .string(open + "/" + wide + ".txt"), "content": .string("x")])
        let movedWide = await run(plain[NativeFolderTools.moveName]!, ["from": .string(open + "/from.txt"), "to": .string(open + "/moved-" + wide)])
        try require(madeWide == "ran" && FileManager.default.fileExists(atPath: open + "/" + wide), "A long multibyte folder name the volume accepts is created")
        try require(nestedWide == "ran" && FileManager.default.fileExists(atPath: open + "/fresh/" + wide), "A long multibyte name is accepted as a nested new component")
        try require(wroteWide == "ran" && FileManager.default.fileExists(atPath: open + "/" + wide + ".txt"), "A long multibyte file name the volume accepts is written")
        try require(movedWide == "ran" && FileManager.default.fileExists(atPath: open + "/moved-" + wide), "A long multibyte move destination the volume accepts is used")
    }
}
