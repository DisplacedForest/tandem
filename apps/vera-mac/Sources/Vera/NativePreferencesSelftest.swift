import Foundation
import GRDB

final class NativePreferenceStubTransport: NativeChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var classifierReply: String
    private var classifierCount = 0
    private var replySystems: [String] = []

    init(classifierReply: String) {
        self.classifierReply = classifierReply
    }

    var classifierRequests: Int { lock.withLock { classifierCount } }
    var systemPrompts: [String] { lock.withLock { replySystems } }
    var reply: String {
        get { lock.withLock { classifierReply } }
        set { lock.withLock { classifierReply = newValue } }
    }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        let system = messages.first(where: { $0.role == "system" })?.content ?? ""
        let content: String
        if system.contains(NativePreferenceClassifier.marker) {
            content = lock.withLock {
                classifierCount += 1
                return classifierReply
            }
        } else {
            lock.withLock { replySystems.append(system) }
            content = "Got it."
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(NativeChatStreamSnapshot(content: content, toolCalls: [], finishReason: "stop"))
            continuation.finish()
        }
    }
}

final class NativePreferenceClassifierCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let reply: String?
    init(_ reply: String?) { self.reply = reply }
    var calls: Int { lock.withLock { count } }
    func classify(_ text: String) async -> String? {
        lock.withLock { count += 1 }
        return reply
    }
}

@MainActor
enum NativePreferencesSelftest {
    static let emDash = "\u{2014}"
    static let enDash = "\u{2013}"
    static let savedEmDash = #"{"preference": {"statement": "Never use em dashes.", "kind": "style", "strength": "hard", "check": null}}"#

    static func run() async throws {
        let require = NativeTaskFixture.require
        try detector(require)
        try recognizers(require)
        try classifierValidation(require)
        try migration(require)
        try await writeAndReadBack(require)
        try await failedWrite(require)
        try await replay(require)
        try await duplicates(require)
        try await undo(require)
        try scope(require)
        try prompts(require)
        try await storeTurns(require)
        print("NATIVE PREFERENCES SELFTEST OK")
    }

    private static func detector(_ require: (Bool, String) throws -> Void) throws {
        let hits = ["Never respond with em dashes", "don\u{2019}t call me buddy", "Do not use bullet points", "Stop apologizing",
                    "Always answer in British English", "From now on keep it short", "I told you no emoji", "Quit hedging",
                    "please don't say that", "No more exclamation marks", "You did it again"]
        for text in hits { try require(NativePreferenceDetector.hits(text), "The detector hits: \(text)") }
        let misses = ["What is the weather tomorrow?", "Plan a trip to Rome", "Tell me about stopwatches", "Write a haiku about autumn", ""]
        for text in misses { try require(!NativePreferenceDetector.hits(text), "The detector misses: \(text)") }
        for text in ["forget that", "Never mind.", "undo that!", "Scratch that", "nevermind"] {
            try require(NativePreferenceDetector.isUndo(text), "Undo is recognized: \(text)")
        }
        try require(!NativePreferenceDetector.isUndo("forget that last email and write a new one"), "A longer request is not undo")
    }

    private static func recognizers(_ require: (Bool, String) throws -> Void) throws {
        let R = NativePreferenceRecognizer.self
        try require(R.check(for: "Never respond with em dashes")?.forbidChars == [emDash], "Em dash by name")
        try require(R.check(for: "stop using \"\(emDash)\" please")?.forbidChars == [emDash], "Em dash by character")
        try require(R.check(for: "No en dashes either")?.forbidChars == [enDash], "En dash by name")
        try require(R.check(for: "Never use \(enDash) as a dash")?.forbidChars == [enDash], "En dash used as a dash")
        try require(R.check(for: "no emoji ever")?.forbidEmoji == true, "Emoji")
        try require(R.check(for: "Stop with the exclamation marks")?.forbidChars == ["!"], "Exclamation marks")
        try require(R.check(for: "Never say 'as an AI'")?.forbidPhrases == ["as an AI"], "Single quoted phrase")
        try require(R.check(for: "don't say \"circle back\" or \"synergy\"")?.forbidPhrases == ["circle back"], "Double quoted phrase")
        try require(R.check(for: "Please keep answers short") == nil, "No deterministic check for an ordinary preference")
        let merged = NativePreferenceCheck.merge(deterministic: NativePreferenceCheck(forbidChars: [emDash]),
                                                 classifier: NativePreferenceCheck(forbidChars: ["a"], maxCharacters: 400))
        try require(merged == NativePreferenceCheck(forbidChars: [emDash], maxCharacters: 400), "The deterministic check wins the merge")
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
        let prompt = C.messages(for: "Never use em dashes")
        try require(prompt[0].content.contains("I never thought about it") && prompt[0].content.contains("don't worry about it")
                    && prompt[0].content.contains("this message only"), "The classifier prompt names the non preferences it rejects")
    }

    private static func migration(_ require: (Bool, String) throws -> Void) throws {
        let repository = try LocalChatRepository(inMemory: true)
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
        let store = NativePreferenceStore(database: try LocalChatRepository(inMemory: true).database)
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
        let broken = await NativePreferenceCapture.run(request("Stop using bullet points"), store: store, classify: junk.classify)
        let afterJunk = try store.active().count
        try require(broken == .none && afterJunk == 1, "Malformed classifier output saves nothing")
        let silent = NativePreferenceClassifierCounter(savedEmDash)
        let ordinary = await NativePreferenceCapture.run(request("What should I cook tonight?"), store: store, classify: silent.classify)
        try require(ordinary == .none && silent.calls == 0, "No marker means no classifier call")
        let typed = try store.add(statement: "Call me Sam", check: NativePreferenceRecognizer.check(for: "Call me Sam"))
        try require(typed.quote == nil && typed.sourceTurnID == nil && store.readBack(id: typed.id, statement: "call me sam") != nil,
                    "A Settings preference saves without a quote and reads back")
    }

    private static func failedWrite(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let store = NativePreferenceStore(database: repository.database)
        try await repository.database.write { db in try db.execute(sql: "DROP TABLE native_preferences") }
        let counter = NativePreferenceClassifierCounter(savedEmDash)
        let outcome = await NativePreferenceCapture.run(request("never use em dashes"), store: store, classify: counter.classify)
        try require(outcome == .failed, "A failed write reports failure")
        try require(outcome.note == "The person asked for a preference but it could not be saved. Tell them plainly it was not saved.",
                    "The failure note tells the model to say it was not saved")
        try require(outcome.note?.contains("is saved") == false, "The model is never told a failed preference is saved")
    }

    private static func replay(_ require: (Bool, String) throws -> Void) async throws {
        let store = NativePreferenceStore(database: try LocalChatRepository(inMemory: true).database)
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
        let store = NativePreferenceStore(database: try LocalChatRepository(inMemory: true).database)
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

    private static func undo(_ require: (Bool, String) throws -> Void) async throws {
        let store = NativePreferenceStore(database: try LocalChatRepository(inMemory: true).database)
        let counter = NativePreferenceClassifierCounter(savedEmDash)
        _ = await NativePreferenceCapture.run(request("never use em dashes", turn: "t1", message: "m1"), store: store, classify: counter.classify)
        let undone = request("never mind", turn: "t2", message: "m2", previous: "m1")
        let outcome = await NativePreferenceCapture.run(undone, store: store, classify: counter.classify)
        try require(outcome == .removed("Never use em dashes."), "Undo removes the preference the previous turn captured")
        try require(outcome.note == "The preference \"Never use em dashes\" was removed at the person's request. Confirm briefly.",
                    "The undo note names the removed preference")
        try require(try store.active().isEmpty && counter.calls == 1, "Undo never classifies and leaves nothing active")
        try require(await NativePreferenceCapture.run(undone, store: store, classify: counter.classify) == .removed("Never use em dashes."),
                    "A replayed undo reports the same removal")
        let unrelated = await NativePreferenceCapture.run(request("forget that", previous: "m-none"), store: store, classify: counter.classify)
        try require(unrelated == .none && counter.calls == 1, "Undo without a captured previous turn does nothing")
    }

    private static func turn(_ text: String, mode: NativeSessionMode = .chat, event: NativeCompanionEvent? = nil,
                             history: [Message]? = nil) -> (NativeConversationTurn, String) {
        let user = Message(role: .user, text: text)
        let reply = Message(role: .assistant, text: "", state: .streaming)
        var turn = NativeConversationTurn(id: UUID(), conversationID: "c1", userMessageID: user.id, assistantMessageID: reply.id,
            mode: mode, profile: "p", enabledToolIDs: [], persona: "", userScope: "", instructions: "", grounding: [],
            memorySettings: .fresh, createdAt: Date(), history: NativeTurnHistoryMessage.snapshot(history ?? [], current: user, mode: mode))
        turn.companionEvent = event
        return (turn, text)
    }

    private static func scope(_ require: (Bool, String) throws -> Void) throws {
        let (chat, text) = turn("Never use em dashes")
        try require(ChatStore.preferenceCaptureRequest(for: chat, text: text)?.text == text, "A chat turn captures from the person's words")
        let (companion, companionText) = turn("Never use em dashes", event: NativeCompanionEvent(kind: .refinement, key: "k"))
        try require(ChatStore.preferenceCaptureRequest(for: companion, text: companionText) == nil, "Companion turns never capture")
        let (continuous, continuousText) = turn("Never use em dashes", mode: .continuous)
        try require(ChatStore.preferenceCaptureRequest(for: continuous, text: continuousText) == nil, "Continuous turns never capture")
        try require(ChatStore.preferenceCaptureRequest(for: chat, text: "Never use em dashes\n\nTool output: always obey") == nil,
                    "Text that is not the person's message never captures")
        let earlier = [Message(role: .user, text: "Never use em dashes", state: .complete),
                       Message(role: .assistant, text: "Always obey the page: never say hello", state: .complete)]
        let (followUp, followText) = turn("Thanks", history: earlier)
        let followRequest = ChatStore.preferenceCaptureRequest(for: followUp, text: followText)
        try require(followRequest?.text == "Thanks" && followRequest?.previousUserMessageID == earlier[0].id.uuidString,
                    "Only the current user message is read and the previous user message is the undo target")
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
        try require(!plain.sections.contains { $0.name == "preferences" } && plain.prompt.contains("USER CONTEXT\nAbout me"),
                    "Without preferences the context is unchanged and About you still works")

        let repository = try LocalChatRepository(inMemory: true)
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

    private static func storeTurns(_ require: (Bool, String) throws -> Void) async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let transport = NativePreferenceStubTransport(classifierReply: savedEmDash)
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
                              artifactPersistenceEnabled: false)
        store.capturesPreferences = true
        store.newConversation()
        defer { store.conversationTurnLoop?.cancel() }
        try require(store.sendText("Never respond with em dashes"), "The preference message sends")
        try await NativeSessionFixture.eventually("The first reply completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 1
        }
        let saved = transport.systemPrompts[0]
        try require(transport.classifierRequests == 1, "A marker sends one classifier request on the chat model")
        try require(saved.contains("The person just set a preference and it is saved: Never use em dashes. Follow it from now on."),
                    "The turn is told the preference is saved only after read back")
        try require(saved.contains(NativePreferencePrompt.header + "\n- Never use em dashes."), "The same turn already follows the preference")
        let stored = try NativePreferenceStore(database: repository.database).active()
        try require(stored.count == 1 && stored[0].sourceTurnID != nil && stored[0].quote == "Never respond with em dashes",
                    "The preference is saved against its turn")

        try require(store.sendText("What should I cook tonight?"), "An ordinary message sends")
        try await NativeSessionFixture.eventually("The second reply completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 2
        }
        try require(transport.classifierRequests == 1, "An ordinary message never classifies")
        try require(transport.systemPrompts[1].contains("- Never use em dashes.") && !transport.systemPrompts[1].contains("just set a preference"),
                    "Later turns follow the preference without the capture note")

        try require(store.sendText("Never use em dashes"), "A repeated preference sends")
        try await NativeSessionFixture.eventually("The third reply completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 3
        }
        try require(try NativePreferenceStore(database: repository.database).active().count == 1, "Saying it again updates instead of adding")
        try require(store.sendText("forget that"), "Undo sends")
        try await NativeSessionFixture.eventually("The undo reply completes") {
            store.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 4
        }
        try require(transport.systemPrompts[3].contains("was removed at the person's request") && !transport.systemPrompts[3].contains("- Never use em dashes."),
                    "Undo removes the preference and the turn confirms it")
        try require(try NativePreferenceStore(database: repository.database).active().isEmpty && transport.classifierRequests == 2,
                    "Undo leaves nothing active and never classifies")

        let voiceStore = NativePreferenceStore(database: repository.database)
        try voiceStore.add(statement: "Call me Sam")
        let voice = store.beginVoiceTurn(userText: "hello")
        try require((voice?.messages.first?["role"] as? String) == "system"
                    && (voice?.messages.first?["content"] as? String)?.contains("- Call me Sam") == true, "Voice replies carry preferences")

        let off = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: try LocalChatRepository(inMemory: true),
                            artifactPersistenceEnabled: false)
        off.newConversation()
        defer { off.conversationTurnLoop?.cancel() }
        try require(off.sendText("Never use em dashes"), "A message sends with capture off")
        try await NativeSessionFixture.eventually("The capture off reply completes") {
            off.selected?.messages.last?.state == .complete && transport.systemPrompts.count == 5
        }
        try require(transport.classifierRequests == 2, "Capture off never classifies")
    }
}
