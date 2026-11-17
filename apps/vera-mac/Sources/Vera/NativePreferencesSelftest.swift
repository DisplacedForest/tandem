import Foundation
import GRDB

final class NativePreferenceStubTransport: NativeChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var classifierReply: String
    private var classifierCount = 0
    private var bodies: [String] = []
    private var replySystems: [String] = []
    private var failing = false
    private var hold: NativeSessionGate?

    init(classifierReply: String) {
        self.classifierReply = classifierReply
    }

    var classifierRequests: Int { lock.withLock { classifierCount } }
    var classifierBodies: [String] { lock.withLock { bodies } }
    var systemPrompts: [String] { lock.withLock { replySystems } }
    func dropFirst(_ count: Int) {
        lock.withLock { replySystems.removeFirst(min(count, replySystems.count)) }
    }

    var holdReplies: NativeSessionGate? {
        get { lock.withLock { hold } }
        set { lock.withLock { hold = newValue } }
    }

    var failReplies: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    var reply: String {
        get { lock.withLock { classifierReply } }
        set { lock.withLock { classifierReply = newValue } }
    }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        let system = messages.first(where: { $0.role == "system" })?.content ?? ""
        let content: String
        if system.contains(NativePreferenceClassifier.marker) {
            let body = messages.last?.content ?? ""
            content = lock.withLock {
                classifierCount += 1
                bodies.append(body)
                return classifierReply
            }
        } else {
            let (fail, gate) = lock.withLock {
                replySystems.append(system)
                return (failing, hold)
            }
            if fail {
                return AsyncThrowingStream { $0.finish(throwing: NativePreferenceStubFailure()) }
            }
            if let gate {
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        continuation.yield(NativeChatStreamSnapshot(content: "Got it.", toolCalls: [], finishReason: nil))
                        await gate.wait()
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
            content = "Got it."
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(NativeChatStreamSnapshot(content: content, toolCalls: [], finishReason: "stop"))
            continuation.finish()
        }
    }
}

struct NativePreferenceStubFailure: Error, LocalizedError {
    var errorDescription: String? { "The model refused the request." }
}

final class NativePreferenceGatedClassifier: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    let gate = NativeSessionGate()
    let reply: String
    init(_ reply: String) { self.reply = reply }
    var calls: Int { lock.withLock { entered } }
    func classify(_ text: String) async -> String? {
        lock.withLock { entered += 1 }
        await gate.wait()
        return reply
    }
}

final class NativePreferenceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

final class NativePreferenceClassifierCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var seen: [String] = []
    let reply: String?
    init(_ reply: String?) { self.reply = reply }
    var calls: Int { lock.withLock { count } }
    var bodies: [String] { lock.withLock { seen } }
    func classify(_ body: String) async -> String? {
        lock.withLock {
            count += 1
            seen.append(body)
        }
        return reply
    }
}

final class SlowPreferenceTransport: NativeChatTransport, @unchecked Sendable {
    func discoverModels() async throws -> [String] { [] }
    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(30))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension NativePreferenceStore {
    func activeChecks() -> [NativePreferenceCheck?] { ((try? active()) ?? []).map(\.check) }
}

@MainActor
enum NativePreferencesSelftest {
    static let emDash = "\u{2014}"
    static let enDash = "\u{2013}"
    static let savedEmDash = #"{"preference": {"statement": "Never use em dashes.", "kind": "style", "strength": "hard", "check": null}}"#

    private static var repositories: [LocalChatRepository] = []

    static func tracked() throws -> LocalChatRepository {
        let repository = try LocalChatRepository(inMemory: true)
        repositories.append(repository)
        return repository
    }

    static func run() async throws {
        defer { repositories.removeAll() }
        let require = NativeTaskFixture.require
        try await meaningGate(require)
        try recognizers(require)
        try classifierValidation(require)
        try labeledSet(require)
        try migration(require)
        try await writeAndReadBack(require)
        try await failedWrite(require)
        try await noFallback(require)
        try await widerDetection(require)
        try await currency(require)
        try await limits(require)
        try settingsEdits(require)
        try await replay(require)
        try await duplicates(require)
        try await removal(require)
        try await permission(require)
        try scope(require)
        try prompts(require)
        try await companionPrompt(require)
        try await storeTurns(require)
        try await storeAdjacencyAndStops(require)
        try await storeRevalidation(require)
        try await storeStops(require)
        try await storeMarkersAtStartup(require)
        try await revertGuards(require)
        try await literalBoundary(require)
        var statements: [String] = []
        for repository in repositories {
            if let rows = try? await repository.database.read({ db in try String.fetchAll(db, sql: "SELECT statement FROM native_preferences") }) {
                statements += rows
            }
        }
        try require(!statements.isEmpty && statements.allSatisfy { !$0.contains(emDash) && !$0.contains(enDash) },
                    "No stored statement in any test holds an em dash or en dash")
        print("NATIVE PREFERENCES SELFTEST OK")
    }

    static let brief = #"{"preference": {"statement": "Keep replies brief.", "kind": "style", "strength": "standing", "check": null}}"#
    static let removeFirst = #"{"remove": 1}"#
    static let nothing = #"{"preference": null}"#

    private static func meaningGate(_ require: (Bool, String) throws -> Void) async throws {
        let marked = NativePreferenceStore(database: try tracked().database)
        let unmarked = NativePreferenceStore(database: try tracked().database)
        let markedCounter = NativePreferenceClassifierCounter(brief)
        let unmarkedCounter = NativePreferenceClassifierCounter(brief)
        let first = await NativePreferenceCapture.run(request("From now on, always keep your replies brief"), store: marked, classify: markedCounter.classify)
        let second = await NativePreferenceCapture.run(request("Brief replies suit me best"), store: unmarked, classify: unmarkedCounter.classify)
        let markedRows = try marked.active().map { [$0.statement, $0.kind.rawValue, $0.strength.rawValue] }
        let unmarkedRows = try unmarked.active().map { [$0.statement, $0.kind.rawValue, $0.strength.rawValue] }
        try require(first == second && first == .saved("Keep replies brief.") && markedRows == unmarkedRows && markedRows.count == 1,
                    "A preference with marker words and one without reach the same classifier and save the same record")
        try require(markedCounter.bodies.first?.hasSuffix("Message:\nFrom now on, always keep your replies brief") == true
                    && unmarkedCounter.bodies.first?.hasSuffix("Message:\nBrief replies suit me best") == true,
                    "The classifier reads the person's own words")
        let ordinary = NativePreferenceClassifierCounter(nothing)
        for text in ["What is the weather tomorrow?", "Plan a trip to Rome", "", "ok"] {
            _ = await NativePreferenceCapture.run(request(text), store: unmarked, classify: ordinary.classify)
        }
        try require(ordinary.calls == 4 && unmarked.active().count == 1, "Every eligible message is classified, whatever its wording")
    }

    private static func labeledSet(_ require: (Bool, String) throws -> Void) throws {
        let examples = NativePreferenceLabeledSet.examples
        let texts = examples.map(\.text)
        try require(examples.count >= 200 && Set(texts).count == texts.count, "The labeled set has at least 200 distinct messages")
        for heldOut in [false, true] {
            let split = examples.filter { $0.heldOut == heldOut }
            for kind in NativePreferenceExampleKind.allCases {
                try require(split.contains { $0.kind == kind }, "Each split covers \(kind.rawValue)")
            }
        }
        let acceptance = ["I like short answers", "Keep it casual with me", "Keep this answer short"]
        for sentence in acceptance {
            try require(examples.contains { $0.text == sentence && $0.heldOut } && !examples.contains { $0.text == sentence && !$0.heldOut },
                        "An acceptance sentence is held out: \(sentence)")
        }
        for example in examples {
            if case .remove(let number) = example.label {
                try require((1...max(example.saved.count, 1)).contains(number) && !example.saved.isEmpty, "A removal names a saved item: \(example.text)")
            }
            try require(!NativePreferenceClassifier.instructions.localizedCaseInsensitiveContains(example.text),
                        "The classifier instructions never contain a labeled message: \(example.text)")
        }
        let scored = NativePreferenceExample(text: "x", label: .nothing, kind: .nearMiss, heldOut: false)
        var score = NativePreferenceScore()
        score.add(scored, .standing)
        score.add(NativePreferenceExample(text: "y", label: .standing, kind: .preference, heldOut: false), .standing)
        score.add(NativePreferenceExample(text: "z", label: .remove(1), kind: .removal, heldOut: false, saved: ["a", "b"]), .remove(2))
        try require(score.falseWrites == 2 && score.saved == 1 && score.removedRight == 0 && score.misses == ["x", "z"],
                    "Scoring counts a wrong save and a wrong removal as unwanted writes")
    }

    private static func recognizers(_ require: (Bool, String) throws -> Void) throws {
        let R = NativePreferenceRecognizer.self
        try require(R.check(for: "Never respond with em dashes")?.forbidChars == [emDash], "Em dash by name")
        try require(R.check(for: "stop using \"\(emDash)\" please")?.forbidChars == [emDash], "Em dash by character")
        try require(R.check(for: "No more en dashes")?.forbidChars == [enDash], "En dash by name")
        try require(R.check(for: "No en dashes", settings: true)?.forbidChars == [enDash], "A Settings entry may start with no")
        try require(R.check(for: "No en dashes") == nil, "A bare no in chat is not a prohibition")
        try require(R.check(for: "Never use \(enDash) as a dash")?.forbidChars == [enDash], "En dash used as a dash")
        try require(R.check(for: "Don't use emoji ever")?.forbidEmoji == true, "Emoji")
        try require(R.check(for: "Stop with the exclamation marks")?.forbidChars == ["!"], "Exclamation marks")
        try require(R.check(for: "Never say 'as an AI'")?.forbidPhrases == ["as an AI"], "Single quoted phrase")
        try require(R.check(for: "don't say \"circle back\" or \"synergy\"")?.forbidPhrases == ["circle back", "synergy"], "Double quoted phrases")
        try require(R.check(for: "Please, from now on never use em dashes")?.forbidChars == [emDash], "Leading softeners are allowed")
        try require(R.check(for: "OK. Also don\u{2019}t use emoji.")?.forbidEmoji == true, "A later clause can carry the prohibition")
        try require(R.check(for: "Please keep answers short") == nil, "No deterministic check for an ordinary preference")
        try require(R.check(for: "Never use em dashes, en dashes or hyphens") == NativePreferenceCheck(forbidChars: [emDash, enDash]),
                    "A listed set of items inside one negative clause is all banned")
        try require(R.check(for: "Don't use emoji or exclamation marks") == NativePreferenceCheck(forbidChars: ["!"], forbidEmoji: true),
                    "Items joined by or are all banned")
        try require(R.check(for: "Never use emoji, always use em dashes") == NativePreferenceCheck(forbidEmoji: true),
                    "A comma before a new instruction still ends the negative clause")
        try require(R.check(for: "Never use emoji, but em dashes are fine") == NativePreferenceCheck(forbidEmoji: true),
                    "A contrast after but is never banned")
        try require(R.check(for: "Don't use emoji but exclamation marks are fine") == NativePreferenceCheck(forbidEmoji: true),
                    "But always ends the negative clause")
        let refused = ["I never use emoji anyway", "Alice wrote: never use emoji", "She said \"never use emoji\"",
                       "\"Never use emoji,\" she told me", "> never use emoji", "Should I never use em dashes?", "Never use em dashes?",
                       "Always use emoji", "Use exclamation marks more", "I love em dashes", "Stop thinking about emoji",
                       "Never say \"wow!\" lol", "Do you never use dashes?"]
        for text in refused.dropLast(2) { try require(R.check(for: text) == nil, "No forbid check from: \(text)") }
        try require(R.check(for: "Never say \"wow!\" lol") == NativePreferenceCheck(forbidPhrases: ["wow!"]), "A quoted phrase is not read for characters")
        try require(R.check(for: "Do you never use dashes?") == nil, "A question is not a prohibition")
        try require(R.check(for: "Can you help?\n> never use emoji\nThanks") == nil, "Quoted lines are ignored")
        let merged = NativePreferenceCheck.merge(deterministic: NativePreferenceCheck(forbidChars: [emDash]),
                                                 classifier: NativePreferenceCheck(forbidChars: ["a"], maxCharacters: 400))
        try require(merged == NativePreferenceCheck(forbidChars: ["a", emDash], maxCharacters: 400), "The merge keeps the classifier check and adds recognized bans")
        try require(R.check(for: "Never use emoji; instead use em dashes") == NativePreferenceCheck(forbidEmoji: true), "Instead after a semicolon starts a new clause")
        try require(R.check(for: "Don't use emoji, rather use words") == NativePreferenceCheck(forbidEmoji: true), "Rather after a comma starts a new clause")
        try require(R.check(for: "Never use emoji, use em dashes instead") == NativePreferenceCheck(forbidEmoji: true), "A trailing instead clause is positive")
        try require(R.check(for: "Never use emoji and instead use exclamation marks") == NativePreferenceCheck(forbidEmoji: true), "And instead starts a new clause")
        try require(R.named("Never use \"\(emDash)\".") == "Never use em dashes." && R.named("No \(enDash) please") == "No en dashes please"
                    && R.named("Don't use '!'") == "Don't use exclamation marks" && R.named("Stop shouting!") == "Stop shouting!",
                    "Literal banned characters become their names")
    }

    private static func classifierValidation(_ require: (Bool, String) throws -> Void) throws {
        let C = NativePreferenceClassifier.self
        try require(C.parse(savedEmDash) == NativePreferenceProposal(statement: "Never use em dashes.", kind: .style, strength: .hard, check: nil),
                    "A well formed preference parses")
        let fenced = "```json\n{\"preference\": {\"statement\": \"Keep replies under 80 words\", \"kind\": \"style\", \"strength\": \"standing\", \"check\": {\"maxCharacters\": 600}}}\n```"
        try require(C.parse(fenced)?.check == NativePreferenceCheck(maxCharacters: 600), "A fenced reply with a check parses")
        let malformed = [
            nil, "", "not json", #"{"preference": null}"#, #"{"preference": {"statement": "x"}}"#,
            #"{"preference": {"statement": "Be brief", "kind": "tone", "strength": "hard"}}"#,
            #"{"preference": {"statement": "Be brief", "kind": "style", "strength": "always"}}"#,
            #"{"preference": {"statement": "", "kind": "style", "strength": "hard"}}"#,
            #"{"preference": {"statement": "Be brief", "kind": "style", "strength": "hard", "check": {"forbidChars": ["ab"]}}}"#,
            #"{"preference": {"statement": "Be brief", "kind": "style", "strength": "hard", "check": {"maxCharacters": "10"}}}"#,
            #"{"preference": {"statement": "Be brief", "kind": "style", "strength": "hard", "check": {"colour": "red"}}}"#,
            #"{"preference": {"statement": "Be brief", "kind": "style", "strength": "hard", "extra": 1}}"#,
            #"{"preference": {"statement": "Be brief", "kind": "style", "strength": "hard"}, "note": "x"}"#,
            #"{"preference": {"statement": 5, "kind": "style", "strength": "hard"}}"#,
        ]
        for raw in malformed { try require(C.parse(raw) == nil, "Malformed or null output is nothing: \(raw ?? "nil")") }
        let dashed = #"{"preference": {"statement": "Keep it short \#(emDash) no filler", "kind": "style", "strength": "hard"}}"#
        try require(C.parse(dashed)?.statement.contains(emDash) == false, "A saved statement never carries an em dash")
        let prompt = C.messages(for: C.body(text: "Never use em dashes", saved: []))
        try require(prompt.count == 2 && prompt[0].content == C.instructions && prompt[1].content == "Saved preferences:\nnone\n\nMessage:\nNever use em dashes",
                    "The classifier gets its instructions, the saved list and the message")
        let listed = C.body(text: String(repeating: "a", count: 2_500), saved: [
            C.Saved(id: "x", statement: "Call me Sam", fromPreviousMessage: false),
            C.Saved(id: "y", statement: "Never use emoji.", fromPreviousMessage: true)])
        try require(listed.hasPrefix("Saved preferences:\n1. Call me Sam\n2. Never use emoji. (saved from the person's previous message)\n\nMessage:\n")
                    && listed.hasSuffix(String(repeating: "a", count: C.excerptLimit)) && !listed.contains(String(repeating: "a", count: C.excerptLimit + 1)),
                    "Saved preferences are numbered, the just saved one is marked and the message is bounded")
        for sentence in ["I like short answers", "Keep it casual with me", "Keep this answer short", "this time", "just this once",
                         "forget that", "never mind"] {
            try require(!C.instructions.localizedCaseInsensitiveContains(sentence), "The instructions hold no acceptance sentence or phrase list: \(sentence)")
        }
        try require(C.classify(#"{"remove": 2}"#, savedCount: 2) == .remove(2) && C.classify(#"{"remove": 1}"#, savedCount: 3) == .remove(1),
                    "A removal names a listed preference")
        for raw in [#"{"remove": 3}"#, #"{"remove": 0}"#, #"{"remove": -1}"#, #"{"remove": 1.5}"#, #"{"remove": true}"#, #"{"remove": "2"}"#,
                    #"{"remove": null}"#, #"{"remove": 1, "preference": null}"#, #"{"permission": false}"#, #"{"permission": 1}"#,
                    #"{"permission": "yes"}"#, #"{"rule": true}"#] {
            try require(C.classify(raw, savedCount: 2) == .invalid, "An answer outside the schema is invalid: \(raw)")
        }
        try require(C.classify(#"{"remove": 1}"#) == .invalid, "With nothing saved there is nothing to remove")
        try require(C.classify(#"{"remove": "unclear"}"#, savedCount: 2) == .removeUnclear && C.classify(#"{"remove": "unclear"}"#) == .removeUnclear,
                    "An unclear removal is its own answer")
        try require(C.classify(#"{"permission": true}"#) == .permission, "A permission request is its own answer")
    }

    private static func migration(_ require: (Bool, String) throws -> Void) throws {
        let repository = try tracked()
        let tables = try repository.database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'native_preference%'")
        }
        try require(Set(tables) == ["native_preferences", "native_preference_captures"], "The migration creates the preference tables")
        let columns = try repository.database.read { db in try db.columns(in: "native_preferences").map(\.name) }
        try require(Set(columns) == ["id", "quote", "source_turn_id", "statement", "kind", "strength", "check_spec", "status",
                                     "created_at", "updated_at", "checked_count", "caught_count"], "The preference table has its columns")
    }

    private static func request(_ text: String, turn: String = UUID().uuidString, message: String = UUID().uuidString,
                                conversation: String = "c1", previous: String? = nil) -> NativePreferenceCaptureRequest {
        NativePreferenceCaptureRequest(key: NativePreferenceCaptureKey(turnID: turn, conversationID: conversation, userMessageID: message),
                                       previousUserMessageID: previous, text: text)
    }

    private static func writeAndReadBack(_ require: (Bool, String) throws -> Void) async throws {
        let store = NativePreferenceStore(database: try tracked().database)
        let counter = NativePreferenceClassifierCounter(savedEmDash)
        let outcome = await NativePreferenceCapture.run(request("never respond with em dashes"), store: store, classify: counter.classify)
        try require(outcome == .saved("Never use em dashes."), "A detected preference is saved")
        try require(outcome.note?.contains("it is saved: Never use em dashes.") == true, "The saved note carries the statement")
        let active = try store.active()
        try require(active.count == 1 && active[0].quote == "never respond with em dashes" && active[0].check?.forbidChars == [emDash]
                    && active[0].kind == .style && active[0].strength == .hard, "The row keeps the quote and the deterministic check")
        let none = NativePreferenceClassifierCounter(#"{"preference": null}"#)
        let rejected = await NativePreferenceCapture.run(request("I never thought about it"), store: store, classify: none.classify)
        let afterNull = try store.active().count
        try require(rejected == .none && rejected.note == nil && none.calls == 1 && afterNull == 1, "A null classification saves nothing")
        let junk = NativePreferenceClassifierCounter("sure! here you go")
        let broken = await NativePreferenceCapture.run(request("Stop saying bullet points"), store: store, classify: junk.classify)
        let afterJunk = try store.active().count
        try require(broken == .unavailable && afterJunk == 1, "Malformed classifier output saves nothing")
        try require(broken.note == "The person's saved preferences were not changed by this message, because it couldn't be checked right now. Only if the message asked to set or remove a standing preference, tell them plainly it didn't go through and they can try again or change it in Settings. Otherwise don't mention it.",
                    "A classifier failure never claims a save and only speaks up if the person asked")
        let silent = NativePreferenceClassifierCounter(nothing)
        let ordinary = await NativePreferenceCapture.run(request("What should I cook tonight?"), store: store, classify: silent.classify)
        try require(ordinary == .none && silent.calls == 1 && ordinary.note == nil, "An ordinary message is classified and changes nothing")
        let typed = try store.add(statement: "Call me Sam", check: NativePreferenceRecognizer.check(for: "Call me Sam"))
        try require(typed.quote == nil && typed.sourceTurnID == nil && store.readBack(id: typed.id, statement: "call me sam") != nil,
                    "A Settings preference saves without a quote and reads back")
    }

    private static func failedWrite(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try tracked()
        let store = NativePreferenceStore(database: repository.database)
        try await repository.database.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_preference BEFORE INSERT ON native_preferences BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        let counter = NativePreferenceClassifierCounter(savedEmDash)
        let outcome = await NativePreferenceCapture.run(request("never use em dashes"), store: store, classify: counter.classify)
        let unreadable = NativePreferenceStore(database: try tracked().database)
        try await unreadable.database.write { db in try db.execute(sql: "DROP TABLE native_preferences") }
        let unchecked = NativePreferenceClassifierCounter(savedEmDash)
        let unreadableOutcome = await NativePreferenceCapture.run(request("never use em dashes"), store: unreadable, classify: unchecked.classify)
        try require(unreadableOutcome == .unavailable && unchecked.calls == 0, "Saved preferences that can't be read mean no classification and no claim")
        try require(outcome == .failed, "A failed write reports failure")
        try require(outcome.note == "The person asked for a preference but it could not be saved. Tell them plainly it was not saved.",
                    "The failure note tells the model to say it was not saved")
        try require(outcome.note?.contains("is saved") == false, "The model is never told a failed preference is saved")
    }

    private static func noFallback(_ require: (Bool, String) throws -> Void) async throws {
        let store = NativePreferenceStore(database: try tracked().database)
        let slow = SlowPreferenceTransport()
        let timeoutRaw = await NativePreferenceClassifier.request(transport: slow, model: "local-model", body: "never use em dashes",
                                                                   timeout: .milliseconds(100))
        try require(timeoutRaw == nil, "A classifier timeout returns nothing")
        let afterTimeout = await NativePreferenceCapture.run(request("Never respond with em dashes"), store: store, classify: { body in
            await NativePreferenceClassifier.request(transport: slow, model: "local-model", body: body, timeout: .milliseconds(100))
        })
        try require(afterTimeout == .unavailable && store.active().isEmpty && afterTimeout.note?.contains("saved:") == false,
                    "A classifier timeout saves nothing, even for a plain prohibition, and claims nothing")
        let malformed = NativePreferenceClassifierCounter("I think so")
        let failing = NativePreferenceClassifierCounter(nil)
        for text in ["never use em dashes or emoji", "Never say 'great question'", "Don't use emoji"] {
            let afterMalformed = await NativePreferenceCapture.run(request(text), store: store, classify: malformed.classify)
            let afterFailure = await NativePreferenceCapture.run(request(text), store: store, classify: failing.classify)
            try require(afterMalformed == .unavailable && afterFailure == .unavailable, "No keyword fallback after a bad answer: \(text)")
        }
        let rows = try await store.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_preference_captures") ?? 0 }
        try require(store.active().isEmpty && rows == 0, "A failed classification writes nothing and leaves no record, so a retry classifies again")
        let polar = NativePreferenceStore(database: try tracked().database)
        let likes = #"{"preference": {"statement": "Always use emoji.", "kind": "style", "strength": "hard", "check": null}}"#
        _ = await NativePreferenceCapture.run(request("Always use emoji"), store: polar, classify: NativePreferenceClassifierCounter(likes).classify)
        try require(try polar.active().first?.check == nil, "A positive preference never gets a forbid check")
        let cases: [(String, NativePreferenceCheck?)] = [
            ("Never use emoji, always use em dashes.", NativePreferenceCheck(forbidEmoji: true)),
            ("Don't use exclamation marks but use em dashes.", NativePreferenceCheck(forbidChars: ["!"])),
            ("Never say 'great question' and always use emoji.", NativePreferenceCheck(forbidPhrases: ["great question"])),
            ("Use emoji and use exclamation marks.", nil),
            ("Always use em dashes; never use en dashes.", NativePreferenceCheck(forbidChars: [enDash])),
        ]
        for (statement, expected) in cases {
            let mixedStore = NativePreferenceStore(database: try tracked().database)
            let reply = "{\"preference\": {\"statement\": \"\(statement.replacingOccurrences(of: "\"", with: "\\\""))\", \"kind\": \"style\", \"strength\": \"hard\", \"check\": null}}"
            _ = await NativePreferenceCapture.run(request("Always do this from now on"), store: mixedStore, classify: NativePreferenceClassifierCounter(reply).classify)
            try require(mixedStore.activeChecks() == [expected], "The merged check follows the statement's negative clauses: \(statement)")
        }
        let ignored = NativePreferenceStore(database: try tracked().database)
        let calm = #"{"preference": {"statement": "Keep a calm tone.", "kind": "style", "strength": "standing", "check": null}}"#
        _ = await NativePreferenceCapture.run(request("Never use emoji. Also keep a calm tone from now on"), store: ignored,
                                              classify: NativePreferenceClassifierCounter(calm).classify)
        try require(ignored.activeChecks() == [nil], "The person's raw words never add a check the classifier statement lacks")
    }

    private static func widerDetection(_ require: (Bool, String) throws -> Void) async throws {
        let store = NativePreferenceStore(database: try tracked().database)
        let concise = #"{"preference": {"statement": "Keep replies concise.", "kind": "style", "strength": "standing", "check": null}}"#
        let saved = await NativePreferenceCapture.run(request("I prefer concise replies"), store: store, classify: NativePreferenceClassifierCounter(concise).classify)
        let avoid = #"{"preference": {"statement": "Avoid em dashes in all replies.", "kind": "style", "strength": "hard", "check": null}}"#
        let avoided = await NativePreferenceCapture.run(request("Avoid em dashes in all future replies"), store: store, classify: NativePreferenceClassifierCounter(avoid).classify)
        try require(saved == .saved("Keep replies concise.") && avoided == .saved("Avoid em dashes in all replies."), "Plain preference wording reaches the classifier and saves")
        try require(store.activeChecks() == [nil, NativePreferenceCheck(forbidChars: [emDash])], "An avoid statement carries its check")
        let null = NativePreferenceClassifierCounter(#"{"preference": null}"#)
        let route = await NativePreferenceCapture.run(request("can you avoid the traffic route"), store: store, classify: null.classify)
        let going = await NativePreferenceCapture.run(request("keep going"), store: store, classify: null.classify)
        try require(route == .none && going == .none && null.calls == 2 && store.active().count == 2, "Ordinary messages reach the classifier and are rejected")
        let literal = #"{"preference": {"statement": "Never use \"\#(emDash)\".", "kind": "style", "strength": "hard", "check": null}}"#
        let literalStore = NativePreferenceStore(database: try tracked().database)
        let named = await NativePreferenceCapture.run(request("never use that dash"), store: literalStore, classify: NativePreferenceClassifierCounter(literal).classify)
        try require(named == .saved("Never use em dashes.") && literalStore.activeChecks() == [NativePreferenceCheck(forbidChars: [emDash])]
                    && literalStore.active().allSatisfy { !$0.statement.contains(emDash) }, "A literal em dash in the statement becomes a readable ban")
        let positive = #"{"preference": {"statement": "Never use emoji; instead use em dashes.", "kind": "style", "strength": "hard", "check": {"forbidEmoji": true}}}"#
        let positiveStore = NativePreferenceStore(database: try tracked().database)
        _ = await NativePreferenceCapture.run(request("never use emoji, use em dashes instead"), store: positiveStore, classify: NativePreferenceClassifierCounter(positive).classify)
        try require(positiveStore.activeChecks() == [NativePreferenceCheck(forbidEmoji: true)], "A positive instead clause never adds a ban to the classifier check")
    }

    private static func currency(_ require: (Bool, String) throws -> Void) async throws {
        let store = NativePreferenceStore(database: try tracked().database)
        let counter = NativePreferenceClassifierCounter(savedEmDash)
        let stale = await NativePreferenceCapture.run(request("never use em dashes"), store: store, classify: counter.classify, isCurrent: { false })
        try require(stale == .none && counter.calls == 1, "A turn that stopped during classification saves nothing")
        let fenced = await NativePreferenceCapture.run(request("never use em dashes"), store: store, classify: counter.classify,
                                                       stillCurrent: { _ in false })
        let rows = try await store.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_preference_captures") ?? 0 }
        try require(fenced == .none && store.active().isEmpty && rows == 0, "The write transaction refuses a turn that is no longer current")
        _ = await NativePreferenceCapture.run(request("never use em dashes", message: "m1"), store: store, classify: counter.classify)
        let remover = NativePreferenceClassifierCounter(removeFirst)
        let blockedUndo = await NativePreferenceCapture.run(request("drop the dash rule", previous: "m1"), store: store, classify: remover.classify,
                                                            stillCurrent: { _ in false })
        let lateUndo = await NativePreferenceCapture.run(request("drop the dash rule", previous: "m1"), store: store, classify: remover.classify,
                                                         isCurrent: { false })
        try require(blockedUndo == .none && lateUndo == .none && store.active().count == 1, "A stopped or replaced turn removes nothing")
    }

    static func longStatement(_ index: Int) -> String {
        let base = "Rule \(index): "
        var words = base
        while words.count < 290 { words += "keep every answer careful and plain " }
        return String(words.prefix(296)).trimmingCharacters(in: .whitespaces) + " \(index)"
    }

    private static func limits(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try tracked()
        let store = NativePreferenceStore(database: repository.database)
        do {
            try store.add(statement: String(repeating: "a", count: 301))
            try require(false, "A long Settings entry is refused")
        } catch let error as NativePreferenceStoreError {
            try require(error.reason == .tooLong && error.localizedDescription == "Keep a preference under 300 characters.", "A long Settings entry gets a plain message")
        }
        let wordy = "{\"preference\": {\"statement\": \"" + String(repeating: "Keep it calm and simple ", count: 20) + "\", \"kind\": \"style\", \"strength\": \"standing\"}}"
        try require(NativePreferenceClassifier.classify(wordy) == .tooLong, "A model statement over the limit is too long, never trimmed")
        let tooLong = await NativePreferenceCapture.run(request("never use em dashes"), store: store,
                                                        classify: NativePreferenceClassifierCounter(wordy).classify)
        try require(tooLong == .tooLong && store.active().isEmpty, "A too long statement saves nothing")
        try require(tooLong.note == "The person asked for a preference but it was too long to save as one. Tell them it was not saved and suggest saying it more briefly or adding it in Settings.",
                    "The too long note asks for a shorter version or Settings")
        let statements = (1...40).map(longStatement)
        for statement in statements { try store.add(statement: statement) }
        try require(statements.allSatisfy { $0.count <= 300 && $0.count > 280 } && store.active().count == 40, "Forty near limit preferences save")
        do {
            try store.add(statement: "One more rule")
            try require(false, "A forty first preference is refused")
        } catch let error as NativePreferenceStoreError {
            try require(error.reason == .full && error.localizedDescription == "You have 40 preferences. Remove one to add another.", "The full list has a plain message")
        }
        let full = await NativePreferenceCapture.run(request("never use em dashes"), store: store,
                                                     classify: NativePreferenceClassifierCounter(savedEmDash).classify)
        try require(full == .full && store.active().count == 40, "Chat capture over the cap saves nothing")
        try require(full.note == "The person asked for a preference but it was not saved because their preference list is full. Tell them the list is full and they can remove one in Settings.",
                    "The full note tells the model what to say")
        let block = NativePreferencePrompt.section(statements) ?? ""
        try require(statements.allSatisfy { block.contains("- " + $0) } && block.count <= NativePreferencePrompt.maximumCharacters,
                    "The formatter holds forty full rules")
        let assembled = NativeContextAssembler.assemble(NativeContextInput(persona: "Persona", preferences: statements, timestamp: Date(), timeZone: .current))
        let section = assembled.sections.first { $0.name == "preferences" }
        try require(section?.content == block && section?.truncated == false, "The chat context carries every rule untruncated")
        let identity = NativePreferenceStore.identity(NativeWorkerIdentity(assistantName: "Nova", ownerName: nil), database: repository.database)
        try require(NativeResearchWorker.synthesisPrompt(identity: identity).hasSuffix(block), "Research uses the same block")
        let schedule = try NativeSchedule(owner: .conversation, workerType: "document", title: "Weekly brief", instruction: "Write the weekly brief",
                                          cadence: .daily(minuteOfDay: 480), timeZone: .current)
        let payload = NativeResearchTaskPayload(request: try schedule.taskRequest())
        var checkpoint = NativeDocumentCheckpoint()
        checkpoint.outline = [NativeDocumentSection(heading: "Overview", instructions: "Cover the week")]
        checkpoint.phase = "draft"
        let document = NativeDocumentWorker.messages(payload: payload, checkpoint: checkpoint, identity: identity)
        let bare = NativeDocumentWorker.messages(payload: payload, checkpoint: checkpoint, identity: NativeWorkerIdentity(assistantName: "Nova", ownerName: nil))
        try require(document.first?.content.hasSuffix(block) == true, "Scheduled documents use the same block")
        try require(NativeDocumentWorker.promptSize(document) == NativeDocumentWorker.promptSize(bare), "Preferences never count against the document budget")
        let relay = NativeCompanionWorkerRelay().environment(database: repository.database)
        try require(NativePreferencePrompt.section(relay.preferences()) == block, "The companion uses the same block")
    }

    private static func settingsEdits(_ require: (Bool, String) throws -> Void) throws {
        let store = NativePreferenceStore(database: try tracked().database)
        let custom = NativePreferenceCheck(forbidChars: [emDash], maxCharacters: 500)
        let row = try store.add(statement: "Never use em dashes", check: custom)
        let same = try store.updateStatement(id: row.id, statement: "never use em dashes!")
        try require(same.statement == "never use em dashes!" && same.check == custom, "An unchanged edit keeps the stored check")
        let changed = try store.updateStatement(id: row.id, statement: "Don't use emoji")
        try require(changed.check == NativePreferenceCheck(forbidEmoji: true), "A changed edit recomputes the check")
        let plain = try store.updateStatement(id: row.id, statement: "Be brief")
        try require(plain.check == nil, "A changed edit without a prohibition clears the check")
    }

    private static func replay(_ require: (Bool, String) throws -> Void) async throws {
        let store = NativePreferenceStore(database: try tracked().database)
        let counter = NativePreferenceClassifierCounter(savedEmDash)
        let same = request("never use em dashes", turn: "turn-1", message: "message-1")
        let first = await NativePreferenceCapture.run(same, store: store, classify: counter.classify)
        let second = await NativePreferenceCapture.run(same, store: store, classify: counter.classify)
        let enrolled = await NativePreferenceCapture.run(request("never use em dashes", turn: "turn-2", message: "message-1"),
                                                         store: store, classify: counter.classify)
        try require(first == second && second == enrolled && counter.calls == 1, "A replayed turn finds the saved row without classifying again")
        try require(try store.active().count == 1 && (try store.preference(sourceTurnID: "turn-1")) != nil, "A replayed turn never saves twice")
        let none = NativePreferenceClassifierCounter(#"{"preference": null}"#)
        let rejected = request("don't worry about it", turn: "turn-3", message: "message-3")
        _ = await NativePreferenceCapture.run(rejected, store: store, classify: none.classify)
        _ = await NativePreferenceCapture.run(rejected, store: store, classify: none.classify)
        try require(none.calls == 1, "A replayed turn that set nothing is not classified again")
    }

    private static func duplicates(_ require: (Bool, String) throws -> Void) async throws {
        let store = NativePreferenceStore(database: try tracked().database)
        let first = await NativePreferenceCapture.run(request("never use em dashes"), store: store,
                                                      classify: NativePreferenceClassifierCounter(savedEmDash).classify)
        let louder = #"{"preference": {"statement": "never use EM dashes!", "kind": "style", "strength": "hard", "check": null}}"#
        let second = await NativePreferenceCapture.run(request("I told you, never use em dashes"), store: store,
                                                       classify: NativePreferenceClassifierCounter(louder).classify)
        let active = try store.active()
        try require(first == .saved("Never use em dashes.") && second == .saved("never use EM dashes!"), "Both captures report saved")
        try require(active.count == 1 && active[0].statement == "never use EM dashes!" && active[0].quote == "I told you, never use em dashes",
                    "A duplicate statement updates the existing preference")
        try store.add(statement: "  Never   use em dashes ")
        try require(try store.active().count == 1, "A typed duplicate updates instead of adding")
        let other = try store.add(statement: "Be brief")
        try store.updateStatement(id: other.id, statement: "Never use em dashes")
        try require(try store.active().map(\.statement) == ["Never use em dashes"], "Editing into a duplicate leaves one preference")
    }

    private static func removal(_ require: (Bool, String) throws -> Void) async throws {
        let store = NativePreferenceStore(database: try tracked().database)
        try store.add(statement: "Call me Sam")
        _ = await NativePreferenceCapture.run(request("never use em dashes", turn: "t1", message: "m1"), store: store,
                                              classify: NativePreferenceClassifierCounter(savedEmDash).classify)
        let unclear = NativePreferenceClassifierCounter(#"{"remove": "unclear"}"#)
        let asked = await NativePreferenceCapture.run(request("drop that rule", previous: "m1"), store: store, classify: unclear.classify)
        try require(asked == .removalUnclear && store.active().count == 2 && unclear.calls == 1, "An unclear removal removes nothing")
        try require(asked.note == "The person seems to want a saved preference removed, but it isn't clear which one, so nothing was removed. Ask which preference they mean.",
                    "An unclear removal asks which one")
        let outOfRange = await NativePreferenceCapture.run(request("drop rule nine", previous: "m1"), store: store,
                                                           classify: NativePreferenceClassifierCounter(#"{"remove": 9}"#).classify)
        try require(outOfRange == .unavailable && store.active().count == 2, "A removal of a number that isn't listed removes nothing")
        let counter = NativePreferenceClassifierCounter(#"{"remove": 2}"#)
        let paraphrased = request("you can go back to using those long dashes", turn: "t2", message: "m2", previous: "m1")
        let outcome = await NativePreferenceCapture.run(paraphrased, store: store, classify: counter.classify)
        try require(counter.bodies.first?.contains("1. Call me Sam\n2. Never use em dashes. (saved from the person's previous message)") == true,
                    "The classifier sees every saved preference and which one the previous message saved")
        try require(outcome == .removed("Never use em dashes."), "A paraphrased removal removes the preference it names")
        try require(outcome.note == "The preference \"Never use em dashes\" was removed at the person's request. Confirm briefly.",
                    "The removal note names the removed preference")
        try require(try store.active().map(\.statement) == ["Call me Sam"], "Only the named preference is removed")
        try require(await NativePreferenceCapture.run(paraphrased, store: store, classify: counter.classify) == .removed("Never use em dashes.")
                    && counter.calls == 1, "A replayed removal reports the same removal without classifying again")
        let gone = try store.add(statement: "Answer in metric")
        let raced = NativePreferenceClassifierCounter(#"{"remove": 2}"#)
        let racedRequest = request("stop the metric thing", turn: "race", conversation: "race-c")
        let racedOutcome = await NativePreferenceCapture.run(racedRequest, store: store, classify: { body in
            try? store.remove(id: gone.id)
            return await raced.classify(body)
        })
        try require(racedOutcome == .removed("Answer in metric") && store.active().map(\.statement) == ["Call me Sam"],
                    "A preference removed elsewhere while classifying reads back as removed")
        let markers = try store.captureMarkers(conversationID: "race-c")
        try require(markers.values.contains(.preferenceRemoved) && markers.count == 1, "That removal still shows its marker")
        try require(try !store.revertCapture(turnID: "race") && store.active().map(\.statement) == ["Call me Sam"],
                    "Stopping that turn never restores what was removed elsewhere")
        try store.add(statement: "Answer in metric")
        let replayed = await NativePreferenceCapture.run(racedRequest, store: store, classify: raced.classify)
        try require(replayed == .removed("Answer in metric") && raced.calls == 1
                    && store.active().map(\.statement) == ["Call me Sam", "Answer in metric"],
                    "Replaying that message after the preference is added again removes nothing and doesn't classify again")

        let edited = NativePreferenceStore(database: try tracked().database)
        let units = try edited.add(statement: "Use metric units")
        let picked = NativePreferenceClassifierCounter(removeFirst)
        let editedOutcome = await NativePreferenceCapture.run(request("drop the units one", conversation: "edit-c"), store: edited, classify: { body in
            _ = try? edited.updateStatement(id: units.id, statement: "Cite sources")
            return await picked.classify(body)
        })
        let editedRows = try await edited.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_preference_captures") ?? 0 }
        try require(editedOutcome == .removalUnclear && edited.active().map(\.statement) == ["Cite sources"] && editedRows == 0,
                    "A preference edited while classifying is kept, and the reply asks which one was meant")

        let punctuated = NativePreferenceStore(database: try tracked().database)
        let separator = try punctuated.add(statement: "Use \":\" as the separator")
        let punctuationOutcome = await NativePreferenceCapture.run(request("drop the separator one"), store: punctuated, classify: { body in
            _ = try? punctuated.updateStatement(id: separator.id, statement: "Use \";\" as the separator")
            return await picked.classify(body)
        })
        try require(punctuationOutcome == .removalUnclear && punctuated.active().map(\.statement) == ["Use \";\" as the separator"],
                    "An edit that only changes punctuation still keeps the preference")

        let merged = NativePreferenceStore(database: try tracked().database)
        let selected = try merged.add(statement: "Use metric units")
        let other = try merged.add(statement: "Cite sources")
        let mergedOutcome = await NativePreferenceCapture.run(request("drop the units one", conversation: "merge-c"), store: merged, classify: { body in
            _ = try? merged.updateStatement(id: other.id, statement: "Use metric units")
            return await picked.classify(body)
        })
        let mergedRows = try await merged.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_preference_captures") ?? 0 }
        try require(try merged.preference(id: selected.id)?.status == .removed && mergedOutcome == .removalUnclear
                    && merged.active().map(\.statement) == ["Use metric units"] && mergedRows == 0,
                    "When Settings merged a duplicate into another row, nothing is claimed removed and the active one stays")
    }

    private static func permission(_ require: (Bool, String) throws -> Void) async throws {
        let store = NativePreferenceStore(database: try tracked().database)
        let counter = NativePreferenceClassifierCounter(#"{"permission": true}"#)
        let asked = request("you can send emails without checking with me", turn: "p1", message: "pm1")
        let outcome = await NativePreferenceCapture.run(asked, store: store, classify: counter.classify)
        try require(outcome == .permission && store.active().isEmpty, "A permission request saves no preference")
        try require(outcome.note == "The person asked to change what the assistant is allowed to do. That isn't a preference, and nothing was saved. Tell them plainly it wasn't saved and that what the assistant may do is set in Settings, Rules.",
                    "A permission request is told plainly it wasn't saved")
        try require(await NativePreferenceCapture.run(asked, store: store, classify: counter.classify) == .none && counter.calls == 1,
                    "A replayed permission request isn't classified again and changes nothing")
    }

    private static func turn(_ text: String, mode: NativeSessionMode = .chat, event: NativeCompanionEvent? = nil,
                             history: [Message]? = nil, eligible: Bool = true) -> (NativeConversationTurn, String) {
        let user = Message(role: .user, text: text)
        let reply = Message(role: .assistant, text: "", state: .streaming)
        var turn = NativeConversationTurn(id: UUID(), conversationID: "c1", userMessageID: user.id, assistantMessageID: reply.id,
            mode: mode, profile: "p", enabledToolIDs: [], persona: "", userScope: "", instructions: "", grounding: [],
            memorySettings: .fresh, createdAt: Date(), history: NativeTurnHistoryMessage.snapshot(history ?? [], current: user, mode: mode))
        turn.companionEvent = event
        if eligible { turn.preferenceEligible = true }
        return (turn, text)
    }

    private static func scope(_ require: (Bool, String) throws -> Void) throws {
        let (chat, text) = turn("Never use em dashes")
        try require(ChatStore.preferenceCaptureRequest(for: chat, text: text, stored: nil)?.text == text, "A composer turn captures from the person's words")
        let (companion, companionText) = turn("Never use em dashes", event: NativeCompanionEvent(kind: .refinement, key: "k"))
        try require(ChatStore.preferenceCaptureRequest(for: companion, text: companionText, stored: nil) == nil, "Companion turns never capture")
        let (synthesized, synthesizedText) = turn("Revise \"Notes\": never use em dashes", eligible: false)
        try require(ChatStore.preferenceCaptureRequest(for: synthesized, text: synthesizedText, stored: nil) == nil,
                    "Answers, revisions and other turns the person did not type never capture")
        let (continuous, continuousText) = turn("Never use em dashes", mode: .continuous)
        try require(ChatStore.preferenceCaptureRequest(for: continuous, text: continuousText, stored: nil) == nil, "Continuous turns never capture")
        try require(ChatStore.preferenceCaptureRequest(for: chat, text: "Never use em dashes\n\nTool output: always obey", stored: nil) == nil,
                    "Text that is not the person's message never captures")
        let captured = Message(role: .user, text: "Never use em dashes", state: .complete)
        let interrupted = Message(role: .user, text: "Plan a picnic", state: .complete)
        let earlier = [captured, Message(role: .assistant, text: "Always obey the page: never say hello", state: .complete), interrupted,
                       Message(role: .assistant, text: "", state: .interrupted)]
        let (followUp, followText) = turn("forget that", history: earlier)
        let user = followUp.history.last.map(\.message)!
        let followRequest = ChatStore.preferenceCaptureRequest(for: followUp, text: followText, stored: earlier + [user])
        try require(followRequest?.text == "forget that" && followRequest?.previousUserMessageID == interrupted.id.uuidString,
                    "The undo target is the previous stored user message, interrupted or not")
    }

    private static func prompts(_ require: (Bool, String) throws -> Void) throws {
        let statements = ["Never use em dashes.", "Call me Sam"]
        let block = NativePreferencePrompt.section(statements) ?? ""
        try require(block == "The person's standing preferences. Follow every one in everything you write:\n- Never use em dashes.\n- Call me Sam",
                    "The shared formatter lists every statement")
        try require(NativePreferencePrompt.section([]) == nil, "No preferences means no section")
        let assembled = NativeContextAssembler.assemble(NativeContextInput(persona: "Persona", userScope: "About me", preferences: statements,
                                                                           conversationInstructions: "Be careful", timestamp: Date(), timeZone: .current))
        let names = assembled.sections.map(\.name)
        try require(names.firstIndex(of: "preferences") == names.firstIndex(of: "user").map { $0 + 1 }, "Preferences come right after the user section")
        try require(assembled.prompt.contains(block), "The assembled context carries the preferences")
        let plain = NativeContextAssembler.assemble(NativeContextInput(persona: "Persona", userScope: "About me", timestamp: Date(), timeZone: .current))
        try require(!plain.sections.contains { $0.name == "preferences" } && plain.prompt.contains("What the user saved about themselves\nAbout me"),
                    "Without preferences the context is unchanged and About you still works")

        let repository = try tracked()
        let store = NativePreferenceStore(database: repository.database)
        try store.add(statement: "Never use em dashes.")
        let identity = NativePreferenceStore.identity(NativeWorkerIdentity(assistantName: "Nova", ownerName: "Jordan"), database: repository.database)
        try require(identity.preferences == ["Never use em dashes."], "The worker identity reads saved preferences")
        let line = "- Never use em dashes."
        try require(NativeResearchWorker.synthesisPrompt(identity: identity).contains(line), "The research report prompt carries preferences")
        let schedule = try NativeSchedule(owner: .conversation, workerType: "document", title: "Weekly brief", instruction: "Write the weekly brief",
                                          cadence: .daily(minuteOfDay: 480), timeZone: .current)
        let payload = NativeResearchTaskPayload(request: try schedule.taskRequest())
        var checkpoint = NativeDocumentCheckpoint()
        checkpoint.outline = [NativeDocumentSection(heading: "Overview", instructions: "Cover the week")]
        checkpoint.phase = "draft"
        let messages = NativeDocumentWorker.messages(payload: payload, checkpoint: checkpoint, identity: identity)
        try require(messages.first { $0.role == "system" }?.content.contains(line) == true, "Scheduled document runs carry preferences")
        let research = try NativeSchedule(owner: .conversation, workerType: "research", title: "Daily news", instruction: "Check the news",
                                          cadence: .daily(minuteOfDay: 480), timeZone: .current)
        try require(try research.taskRequest().workerType == "research", "Scheduled research runs use the research worker that carries preferences")
        let bare = NativeDocumentWorker.messages(payload: payload, checkpoint: checkpoint, identity: NativeWorkerIdentity(assistantName: "Nova", ownerName: nil))
        try require(bare.first?.content.contains(NativePreferencePrompt.header) == false, "No preferences leaves the document prompt unchanged")
    }

    private static func companionPrompt(_ require: (Bool, String) throws -> Void) async throws {
        var harness = try NativeCompanionHarness(rules: [:]) { _ in NativeCompanionScriptedModel.text("Done.\n\nNothing else.") }
        let preferences = NativePreferenceStore(database: harness.repository.database)
        try preferences.add(statement: "Never use em dashes.")
        harness.environment.preferences = { preferences.activeStatements() }
        _ = try harness.create("Check the garden")
        _ = try await harness.runUntilSettled()
        let system = harness.model.allRequests.first?.first { $0.role == "system" }?.content ?? ""
        try require(system.contains(NativePreferencePrompt.header) && system.contains("- Never use em dashes."),
                    "The companion worker instructions carry preferences")
        let relay = NativeCompanionWorkerRelay().environment(database: harness.repository.database)
        try require(relay.preferences() == ["Never use em dashes."], "The live companion environment reads saved preferences")
    }

    private static func storeTurns(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try tracked()
        let transport = NativePreferenceStubTransport(classifierReply: savedEmDash)
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
                              artifactPersistenceEnabled: false)
        store.capturesPreferences = true
        store.newConversation()
        defer { store.conversationTurnLoop?.cancel() }
        let startRevision = store.preferencesRevision
        try require(store.sendText("Never respond with em dashes", fromComposer: true), "The preference message sends")
        try await NativeSessionFixture.eventually("The first reply completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 1
        }
        let saved = transport.systemPrompts[0]
        try require(store.preferencesRevision == startRevision + 1, "The store publishes a change after capture saves")
        guard let savedMessage = store.selected?.messages.first(where: { $0.role == .user }), let markedConversation = store.selectedID else {
            throw NativeTaskFixture.Failure.assertion("The preference message exists")
        }
        try require(store.preferenceMarker(for: savedMessage, in: markedConversation) == .preferenceSaved, "The message that saved a preference shows the saved marker")
        guard let firstReply = store.selected?.messages.last?.id else { throw NativeTaskFixture.Failure.assertion("A reply exists") }
        store.submitAsk(messageID: firstReply, selections: ["Never mind"], other: "")
        try await NativeSessionFixture.eventually("The ask answer completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 2
        }
        try require(try NativePreferenceStore(database: repository.database).active().count == 1 && !transport.systemPrompts[1].contains("was removed"),
                    "An ask answer of never mind removes nothing")
        guard let askReply = store.selected?.messages.last?.id else { throw NativeTaskFixture.Failure.assertion("A reply exists") }
        store.submitAsk(messageID: askReply, selections: ["Never use emoji"], other: "")
        try await NativeSessionFixture.eventually("The second ask answer completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 3
        }
        try require(try NativePreferenceStore(database: repository.database).active().count == 1 && transport.classifierRequests == 1,
                    "An ask answer that sounds like a preference saves nothing and never classifies")
        let record = ArtifactRecord(id: "notes", kind: .document, title: "Notes", conversationID: store.selectedID, originTitle: nil,
                                    createdAt: Date(), updatedAt: Date(), versionCount: 1)
        store.reviseArtifact(record, change: "never use emoji")
        try await NativeSessionFixture.eventually("The revision completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 4
        }
        try require(transport.classifierRequests == 1 && NativePreferenceStore(database: repository.database).active().count == 1,
                    "A synthesized revision request never captures")
        transport.dropFirst(3)
        try require(transport.classifierRequests == 1, "A typed message sends one classifier request on the chat model")
        try require(saved.contains("The person just set a preference and it is saved: Never use em dashes. Follow it from now on."),
                    "The turn is told the preference is saved only after read back")
        try require(saved.contains(NativePreferencePrompt.header + "\n- Never use em dashes."), "The same turn already follows the preference")
        let stored = try NativePreferenceStore(database: repository.database).active()
        try require(stored.count == 1 && stored[0].sourceTurnID != nil && stored[0].quote == "Never respond with em dashes",
                    "The preference is saved against its turn")

        transport.reply = nothing
        try require(store.sendText("What should I cook tonight?", fromComposer: true), "An ordinary message sends")
        try await NativeSessionFixture.eventually("The second reply completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 2
        }
        try require(transport.classifierRequests == 2 && !transport.systemPrompts[1].contains("saved preferences were not changed"),
                    "An ordinary message is classified, changes nothing and adds no note")
        guard let ordinaryMessage = store.selected?.messages.last(where: { $0.role == .user }) else {
            throw NativeTaskFixture.Failure.assertion("The ordinary message exists")
        }
        try require(store.preferenceMarker(for: ordinaryMessage, in: markedConversation) == nil, "A message that saves nothing shows no marker")
        try require(transport.systemPrompts[1].contains("- Never use em dashes.") && !transport.systemPrompts[1].contains("just set a preference"),
                    "Later turns follow the preference without the capture note")

        transport.reply = savedEmDash
        try require(store.sendText("Never use em dashes", fromComposer: true), "A repeated preference sends")
        try await NativeSessionFixture.eventually("The third reply completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 3
        }
        try require(try NativePreferenceStore(database: repository.database).active().count == 1, "Saying it again updates instead of adding")
        transport.reply = removeFirst
        try require(store.sendText("actually, dashes are fine again", fromComposer: true), "A removal sends")
        try await NativeSessionFixture.eventually("The undo reply completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 4
        }
        try require(store.preferencesRevision == startRevision + 3, "The store publishes a change after undo removes")
        guard let undoMessage = store.selected?.messages.last(where: { $0.role == .user }) else {
            throw NativeTaskFixture.Failure.assertion("The undo message exists")
        }
        try require(store.preferenceMarker(for: undoMessage, in: markedConversation) == .preferenceRemoved && store.preferenceMarker(for: savedMessage, in: markedConversation) == .preferenceSaved,
                    "Undo shows the removed marker and the earlier saved marker stays")
        try require(transport.systemPrompts[3].contains("was removed at the person's request") && !transport.systemPrompts[3].contains("- Never use em dashes."),
                    "Undo removes the preference and the turn confirms it")
        try require(try NativePreferenceStore(database: repository.database).active().isEmpty && transport.classifierRequests == 4
                    && transport.classifierBodies[3].contains("1. Never use em dashes. (saved from the person's previous message)"),
                    "The removal is decided by the classifier and leaves nothing active")

        let off = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: try tracked(),
                            artifactPersistenceEnabled: false)
        off.newConversation()
        defer { off.conversationTurnLoop?.cancel() }
        try require(off.sendText("Never use em dashes", fromComposer: true), "A message sends with capture off")
        try await NativeSessionFixture.eventually("The capture off reply completes") {
            off.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 5
        }
        try require(transport.classifierRequests == 4, "Capture off never classifies")

        transport.reply = nothing
        store.newConversation()
        try require(store.sendText("What should I cook tonight?", fromComposer: true), "A message sends in a second conversation")
        try await NativeSessionFixture.eventually("The second conversation reply completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 6
        }
        try require(store.selectedID != markedConversation && (store.selected?.messages ?? []).allSatisfy { store.preferenceMarker(for: $0, in: store.selectedID ?? "") == nil }
                    && store.preferenceMarker(for: savedMessage, in: markedConversation) == .preferenceSaved,
                    "A second conversation shows no marker and the first keeps its markers")

        let relaunched = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
                                   artifactPersistenceEnabled: false)
        defer { relaunched.conversationTurnLoop?.cancel() }
        await relaunched.connect()
        relaunched.select(markedConversation)
        try require(relaunched.preferenceMarker(for: savedMessage, in: markedConversation) == .preferenceSaved && relaunched.preferenceMarker(for: undoMessage, in: markedConversation) == .preferenceRemoved
                    && relaunched.preferenceMarker(for: ordinaryMessage, in: markedConversation) == nil,
                    "Markers come back after a relaunch when the conversation loads")
    }

    private static func turnStore(_ transport: NativePreferenceStubTransport, _ repository: LocalChatRepository) -> ChatStore {
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
                              artifactPersistenceEnabled: false)
        store.capturesPreferences = true
        store.newConversation()
        return store
    }

    private static func send(_ store: ChatStore, _ text: String, settled count: Int, _ transport: NativePreferenceStubTransport) async throws {
        try NativeTaskFixture.require(store.sendText(text, fromComposer: true), "The message sends: \(text)")
        try await NativeSessionFixture.eventually("The turn settles: \(text)") {
            transport.systemPrompts.count == count && store.selected?.messages.last?.state != .streaming
        }
    }

    private static func literalBoundary(_ require: (Bool, String) throws -> Void) async throws {
        let captured = NativePreferenceStore(database: try tracked().database)
        let avoid = #"{"preference": {"statement": "Avoid \#(emDash) in all future replies.", "kind": "style", "strength": "hard", "check": null}}"#
        let outcome = await NativePreferenceCapture.run(request("avoid that dash from now on"), store: captured,
                                                        classify: NativePreferenceClassifierCounter(avoid).classify)
        try require(outcome == .saved("Avoid em dashes in all future replies.") && captured.activeChecks() == [NativePreferenceCheck(forbidChars: [emDash])],
                    "A classifier statement with a literal em dash after avoid saves its name and the ban")
        let store = NativePreferenceStore(database: try tracked().database)
        let named = try store.add(statement: "Never use \(emDash)", recognize: true)
        try require(named.statement == "Never use em dashes" && named.check == NativePreferenceCheck(forbidChars: [emDash]),
                    "A Settings entry with a literal em dash stores its name and the ban")
        let punctuated = try store.add(statement: "Keep it short\(emDash)one paragraph", recognize: true)
        try require(punctuated.statement == "Keep it short, one paragraph" && punctuated.check == nil, "An em dash used as punctuation becomes a comma")
        let edited = try store.updateStatement(id: punctuated.id, statement: "No \(enDash) at all")
        try require(edited.statement == "No en dashes at all" && edited.check == NativePreferenceCheck(forbidChars: [enDash]), "Edits are normalized too")
        let spaced = try store.add(statement: "Keep it short \(emDash) no filler", recognize: true)
        let spacedEn = try store.add(statement: "Be direct \(enDash) skip the intro", recognize: true)
        try require(spaced.statement == "Keep it short, no filler" && spaced.check == nil && spacedEn.statement == "Be direct, skip the intro"
                    && spacedEn.check == nil, "A spaced dash between words is punctuation")
        let ending = try store.add(statement: "No \(emDash).", recognize: true)
        let trailing = try store.add(statement: "Stop it \(emDash) \(emDash) now \(emDash)!")
        try require(ending.statement == "No em dashes." && ending.check == NativePreferenceCheck(forbidChars: [emDash])
                    && trailing.statement == "Stop it, now!", "A dash ending the statement is the item and doubled commas collapse")
        let never = try store.add(statement: "Please never \(emDash)", recognize: true)
        try require(never.statement == "Please never em dashes", "A dash that is the whole object at the end is named")
        let range = try store.add(statement: "Answer in 2\(enDash)3 sentences")
        try require(range.statement == "Answer in 2-3 sentences", "An en dash in a number range becomes a hyphen")
    }

    private static func stopStore(_ transport: NativePreferenceStubTransport, _ repository: LocalChatRepository, stopping: NativePreferenceFlag) -> ChatStore {
        let store = turnStore(transport, repository)
        store.nativeMemorySelectionTransform = { [weak store] selected in
            if stopping.value, let store, let reply = store.selected?.messages.last?.id {
                stopping.value = false
                store.stopAnswer(reply)
            }
            return selected
        }
        return store
    }

    private static func settle(_ store: ChatStore, _ text: String) async throws {
        try NativeTaskFixture.require(store.sendText(text, fromComposer: true), "The message sends: \(text)")
        try await NativeSessionFixture.eventually("The turn settles: \(text)") {
            store.conversationTurns.allSatisfy { $0.state != .pending && $0.state != .running } && store.selected?.messages.last?.state != .streaming
        }
    }

    private static func storeStops(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try tracked()
        let transport = NativePreferenceStubTransport(classifierReply: savedEmDash)
        let stopping = NativePreferenceFlag()
        let store = stopStore(transport, repository, stopping: stopping)
        defer { store.conversationTurnLoop?.cancel() }
        let preferences = NativePreferenceStore(database: repository.database)
        stopping.value = true
        let before = store.preferencesRevision
        try await settle(store, "Never use em dashes")
        try require(try preferences.active().isEmpty && store.preferencesRevision == before + 2 && transport.systemPrompts.isEmpty,
                    "Stopping after the save but before the answer removes the new preference")
        let rows = try await repository.database.read { db in try String.fetchAll(db, sql: "SELECT outcome FROM native_preference_captures") }
        try require(rows == ["none"], "The stopped capture is marked so a replay never redoes it")
        guard let stoppedMessage = store.selected?.messages.last(where: { $0.role == .user }) else {
            throw NativeTaskFixture.Failure.assertion("The stopped message exists")
        }
        try require(store.preferenceMarker(for: stoppedMessage, in: store.selectedID ?? "") == nil, "A stopped capture shows no marker")

        try await settle(store, "Please never use em dashes")
        try require(try preferences.active().map(\.statement) == ["Never use em dashes."], "A turn that completes keeps its preference")
        transport.reply = #"{"preference": {"statement": "never use EM dashes!", "kind": "style", "strength": "hard", "check": null}}"#
        stopping.value = true
        try await settle(store, "I told you, never use em dashes")
        try require(try preferences.active().map(\.statement) == ["Never use em dashes."], "Stopping a duplicate update restores the old statement")
        transport.reply = savedEmDash
        try await settle(store, "Never use em dashes")
        let beforeUndo = store.preferencesRevision
        transport.reply = removeFirst
        stopping.value = true
        try await settle(store, "forget that")
        try require(store.preferencesRevision == beforeUndo + 2 && preferences.active().map(\.statement) == ["Never use em dashes."],
                    "Stopping an undo restores the removed preference")
        guard let stoppedUndo = store.selected?.messages.last(where: { $0.role == .user }) else {
            throw NativeTaskFixture.Failure.assertion("The stopped undo exists")
        }
        try require(store.preferenceMarker(for: stoppedUndo, in: store.selectedID ?? "") == nil, "A stopped undo shows no marker")

        let shownRepository = try tracked()
        let shownTransport = NativePreferenceStubTransport(classifierReply: savedEmDash)
        let shown = turnStore(shownTransport, shownRepository)
        defer { shown.conversationTurnLoop?.cancel() }
        let gate = NativeSessionGate()
        shownTransport.holdReplies = gate
        try require(shown.sendText("Never use em dashes", fromComposer: true), "The held message sends")
        try await NativeSessionFixture.eventually("The acknowledgment streams") { shown.selected?.messages.last?.text == "Got it." }
        guard let reply = shown.selected?.messages.last?.id else { throw NativeTaskFixture.Failure.assertion("A reply exists") }
        shown.stopAnswer(reply)
        shown.stopAnswer(reply)
        await gate.release()
        try require(try NativePreferenceStore(database: shownRepository.database).active().map(\.statement) == ["Never use em dashes."],
                    "Stopping after the acknowledgment is visible keeps the preference, and a second stop is harmless")
    }

    private static func storeMarkersAtStartup(_ require: (Bool, String) throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vera-preference-markers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chat.sqlite")
        let artifacts = folder.appendingPathComponent("artifacts")
        let projects = folder.appendingPathComponent("projects")
        let repository = try LocalChatRepository(url: file, artifactDirectory: artifacts, projectsDirectory: projects)
        let transport = NativePreferenceStubTransport(classifierReply: savedEmDash)
        let store = turnStore(transport, repository)
        try await send(store, "Never respond with em dashes", settled: 1, transport)
        transport.reply = removeFirst
        try await send(store, "forget that", settled: 2, transport)
        transport.reply = nothing
        try await send(store, "I never thought about it", settled: 3, transport)
        store.conversationTurnLoop?.cancel()
        let users = (store.selected?.messages ?? []).filter { $0.role == .user }
        guard let conversation = store.selectedID, users.count == 3 else { throw NativeTaskFixture.Failure.assertion("Three messages were sent") }
        try require(transport.classifierRequests == 3 && store.preferenceMarker(for: users[2], in: conversation) == nil,
                    "A message the classifier rejected shows no marker")

        let reopened = try LocalChatRepository(url: file, artifactDirectory: artifacts, projectsDirectory: projects)
        let relaunched = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: reopened,
                                   artifactPersistenceEnabled: false)
        defer { relaunched.conversationTurnLoop?.cancel() }
        await relaunched.connect()
        try await NativeSessionFixture.eventually("Startup fills the earlier conversation before it is opened") {
            relaunched.conversations.first { $0.id == conversation }?.messages.isEmpty == false
        }
        try require(relaunched.selectedID != conversation && relaunched.preferenceMarker(for: users[0], in: conversation) == .preferenceSaved
                    && relaunched.preferenceMarker(for: users[1], in: conversation) == .preferenceRemoved
                    && relaunched.preferenceMarker(for: users[2], in: conversation) == nil,
                    "Markers are ready for a conversation that startup filled before it was opened")
        relaunched.select(conversation)
        relaunched.refreshPreferenceMarkers(conversationID: conversation)
        try require(relaunched.preferenceMarker(for: users[0], in: conversation) == .preferenceSaved
                    && relaunched.preferenceMarker(for: users[1], in: conversation) == .preferenceRemoved
                    && relaunched.preferenceMarker(for: users[2], in: conversation) == nil,
                    "Opening a conversation that startup filled shows its markers")
    }

    private static func revertGuards(_ require: (Bool, String) throws -> Void) async throws {
        let store = NativePreferenceStore(database: try tracked().database)
        _ = await NativePreferenceCapture.run(request("never use em dashes", turn: "new"), store: store,
                                              classify: NativePreferenceClassifierCounter(savedEmDash).classify)
        let created = try store.active()[0]
        try store.updateStatement(id: created.id, statement: "Never use em dashes in titles")
        try require(try !store.revertCapture(turnID: "new") && store.active().map(\.statement) == ["Never use em dashes in titles"],
                    "A Settings edit after a new capture survives a stop")
        let louder = #"{"preference": {"statement": "never use EM dashes in titles!", "kind": "style", "strength": "hard", "check": null}}"#
        _ = await NativePreferenceCapture.run(request("I told you, never use em dashes in titles", turn: "dup"), store: store,
                                              classify: NativePreferenceClassifierCounter(louder).classify)
        try store.updateStatement(id: created.id, statement: "Never use em dashes in headings")
        try require(try !store.revertCapture(turnID: "dup") && store.active().map(\.statement) == ["Never use em dashes in headings"],
                    "A Settings edit after a duplicate update survives a stop")
        _ = await NativePreferenceCapture.run(request("never use emoji", turn: "e1", message: "e1m"), store: store,
                                              classify: NativePreferenceClassifierCounter(#"{"preference": {"statement": "Never use emoji.", "kind": "style", "strength": "hard", "check": null}}"#).classify)
        _ = await NativePreferenceCapture.run(request("forget that", turn: "e2", previous: "e1m"), store: store,
                                              classify: NativePreferenceClassifierCounter(#"{"remove": 2}"#).classify)
        try require(try store.active().map(\.statement) == ["Never use em dashes in headings"], "The removal took the emoji preference")
        try store.add(statement: "Never use emoji")
        try require(try !store.revertCapture(turnID: "e2") && store.active().filter { $0.statement.lowercased().contains("emoji") }.count == 1,
                    "An undone preference is not restored when the same rule is active again")
        try require(try !store.revertCapture(turnID: "e2") && !store.revertCapture(turnID: "missing"), "Reverting twice or without a capture does nothing")
    }

    private static func storeRevalidation(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try tracked()
        let transport = NativePreferenceStubTransport(classifierReply: savedEmDash)
        let store = turnStore(transport, repository)
        defer { store.conversationTurnLoop?.cancel() }
        let preferences = NativePreferenceStore(database: repository.database)
        try preferences.add(statement: "Call me Sam")
        store.nativeMemorySelectionTransform = { selected in
            for row in (try? preferences.active()) ?? [] where row.statement == "Never use em dashes." { try? preferences.remove(id: row.id) }
            return selected
        }
        try await send(store, "Never use em dashes", settled: 1, transport)
        let prompt = transport.systemPrompts[0]
        try require(transport.classifierRequests == 1 && !prompt.contains("it is saved") && !prompt.contains("- Never use em dashes."),
                    "A preference removed before the prompt is built is neither announced nor sent")
        try require(prompt.contains(NativePreferencePrompt.header + "\n- Call me Sam"), "The preference section is refreshed at prompt time")
    }

    private static func storeAdjacencyAndStops(_ require: (Bool, String) throws -> Void) async throws {
        let emoji = #"{"preference": {"statement": "Never use emoji.", "kind": "style", "strength": "hard", "check": null}}"#
        let firstRepository = try tracked()
        let firstTransport = NativePreferenceStubTransport(classifierReply: savedEmDash)
        let first = turnStore(firstTransport, firstRepository)
        defer { first.conversationTurnLoop?.cancel() }
        try await send(first, "Never use em dashes", settled: 1, firstTransport)
        firstTransport.reply = nothing
        firstTransport.failReplies = true
        try await send(first, "Plan a picnic", settled: 2, firstTransport)
        try require(first.selected?.messages.last?.state == .interrupted, "The unrelated request is interrupted")
        firstTransport.failReplies = false
        try await send(first, "forget that", settled: 3, firstTransport)
        try require(try NativePreferenceStore(database: firstRepository.database).active().count == 1 && !firstTransport.systemPrompts[2].contains("was removed")
                    && firstTransport.classifierBodies[2].contains("1. Never use em dashes.\n")
                    && !firstTransport.classifierBodies[2].contains("previous message"),
                    "After an interrupted unrelated request, no saved preference is marked as just saved")

        let secondRepository = try tracked()
        let secondTransport = NativePreferenceStubTransport(classifierReply: savedEmDash)
        let second = turnStore(secondTransport, secondRepository)
        defer { second.conversationTurnLoop?.cancel() }
        try await send(second, "Never use em dashes", settled: 1, secondTransport)
        secondTransport.reply = emoji
        secondTransport.failReplies = true
        try await send(second, "Never use emoji", settled: 2, secondTransport)
        try require(second.selected?.messages.last?.state == .interrupted, "The capturing request is interrupted")
        secondTransport.failReplies = false
        secondTransport.reply = #"{"remove": 2}"#
        try await send(second, "forget that", settled: 3, secondTransport)
        let left = try NativePreferenceStore(database: secondRepository.database).active().map(\.statement)
        try require(left == ["Never use em dashes."] && secondTransport.systemPrompts[2].contains("\"Never use emoji\" was removed")
                    && secondTransport.classifierBodies[2].contains("2. Never use emoji. (saved from the person's previous message)"),
                    "The preference an interrupted request captured is marked as just saved and can be removed")

        let stopRepository = try tracked()
        let stopTransport = NativePreferenceStubTransport(classifierReply: savedEmDash)
        let stopped = turnStore(stopTransport, stopRepository)
        defer { stopped.conversationTurnLoop?.cancel() }
        let gated = NativePreferenceGatedClassifier(savedEmDash)
        stopped.preferenceClassifier = { await gated.classify($0) }
        try require(stopped.sendText("Never use em dashes", fromComposer: true), "The stopped message sends")
        try await NativeSessionFixture.eventually("The classifier starts") { gated.calls == 1 }
        guard let reply = stopped.selected?.messages.last?.id else { throw NativeTaskFixture.Failure.assertion("A reply exists") }
        stopped.stopAnswer(reply)
        await gated.gate.release()
        try await Task.sleep(for: .milliseconds(200))
        let captures = try await stopRepository.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_preference_captures") ?? 0 }
        try require(try NativePreferenceStore(database: stopRepository.database).active().isEmpty && captures == 0 && stopTransport.systemPrompts.isEmpty,
                    "A turn stopped during classification saves nothing")
    }
}
