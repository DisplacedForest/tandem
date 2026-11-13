import Foundation
import GRDB

final class NativeInstructionSpentDevice: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    private var held = false
    private var entered = false

    var count: Int { lock.withLock { runs } }
    var started: Bool { lock.withLock { entered } }
    func hold(_ value: Bool) { lock.withLock { held = value; entered = false } }

    func run() async throws -> NativeJSONValue {
        let waits = lock.withLock { () -> Bool in
            entered = true
            return held
        }
        if waits { try await Task.sleep(for: .seconds(60)) }
        lock.withLock { runs += 1 }
        return .object(["level": .string("3")])
    }
}

extension SelfTest {
    @MainActor
    static func runInstructionSpent() async throws {
        try await NativeInstructionSpentFixture.run()
    }
}

@MainActor
enum NativeInstructionSpentFixture {
    nonisolated static let typed = "Turn on the bedroom air purifier to 3"
    nonisolated static let other = "Could you look after the bedroom air tonight?"
    nonisolated static let argumentsJSON = "{\"device\":\"bedroom air purifier\",\"level\":\"3\"}"

    struct Chat {
        let repository: LocalChatRepository
        let store: ChatStore
        var turn: NativeConversationTurn
        let rules: NativeRuleSource
        let grants: NativeFolderGrantSource
        let device: NativeInstructionSpentDevice
    }

    static func run() async throws {
        try await storeRules()
        try await replyThenWork()
        try await workThenReply()
        try await twoWorks()
        try await resumedWork()
        try await writtenAssignment()
        try await oldWork()
        try await stoppedReply()
        try await concurrentAdmissions()
        try await unresolvedOrigin()
        try await lapsedDuringCheck()
        print("  instruction spent once OK (store, removal, fails closed, reply then work, work then reply, two works, resumed work, written assignment, old work, stopped and admitted replies, concurrent admissions, unknown origin asks, lapsed during check asks)")
    }

    nonisolated static func device(_ box: NativeInstructionSpentDevice) -> NativeToolDefinition {
        let text: NativeJSONValue = .object(["type": .string("string")])
        var made = NativeToolDefinition(id: "fixture-home", name: "set_device", title: "Set a device", description: "Fixture",
                                        parameters: .object(["type": .string("object"), "properties": .object(["device": text, "level": text])]),
                                        confirmation: .none, effect: .write, action: .otherChanges, isAvailable: { true },
                                        execute: { _ in try await box.run() })
        made.verbs = ["turn on"]
        made.instructionNames = { arguments in
            [arguments["device"], arguments["level"]].compactMap { if case .string(let value)? = $0 { value } else { nil } }
        }
        return made
    }

    static func chat(_ text: String = typed, rules choices: [NativeActionClass: NativeRuleChoice] = [.otherChanges: .ask]) throws -> Chat {
        let repository = try LocalChatRepository(inMemory: true)
        let store = ChatStore(nativeConfig: SelfTest.chatLedgerConfig, nativeTransport: ScriptedNativeToolTransport(rounds: []), repository: repository,
                              nativeEnabledToolIDs: [], nativeToolRegistry: NativeToolRegistry(definitions: []), artifactPersistenceEnabled: false)
        store.newConversation()
        store.suspendsTurnScheduling = true
        store.sendText(text, fromComposer: true)
        guard let pending = try repository.conversationTurns().last, let turn = try repository.claimTurn(pending.id, attempt: UUID()) else {
            throw NativeTaskFixture.Failure.assertion("A reply can be claimed")
        }
        return Chat(repository: repository, store: store, turn: turn, rules: SelfTest.chatLedgerRules(choices),
                    grants: NativeFolderGrantSource(), device: NativeInstructionSpentDevice())
    }

    static func retry(_ chat: inout Chat) throws {
        guard let attempt = chat.turn.attempt else { throw NativeTaskFixture.Failure.assertion("The reply has an attempt") }
        try chat.repository.releaseTurn(chat.turn.id, attempt: attempt)
        guard let again = try chat.repository.claimTurn(chat.turn.id, attempt: UUID()) else {
            throw NativeTaskFixture.Failure.assertion("The reply can be tried again")
        }
        chat.turn = again
    }

    static func rows(_ chat: Chat) throws -> [String] {
        try chat.repository.database.read { db in try String.fetchAll(db, sql: "SELECT holder FROM native_instruction_uses ORDER BY created_at, rowid") }
    }

    static func reply(_ chat: Chat, cards: NativeChatRulesCounter, check: @escaping NativeInstructionAnswerer = { _, _ in true })
        async throws -> NativeToolTurnSnapshot? {
        let turn = chat.turn
        guard let attempt = turn.attempt else { throw NativeTaskFixture.Failure.assertion("The reply has an attempt") }
        let words = chat.store.typedWords(for: turn)
        try NativeTaskFixture.require(words.said == typed || words.said == other, "The message counts as typed: \(words.said)")
        let uses = chat.store.turnInstructionUses(for: turn)
        let tool = ChatStore.ruled(device(chat.device), rules: chat.rules, store: nil, conversationID: turn.conversationID,
                                   requestText: words.said, typed: words, uses: uses)
        let ledger = NativeEffectLedgerStore(database: chat.repository.database)
        let effects = NativeChatEffectLedger(ledger: ledger, rules: chat.rules, grants: chat.grants, records: nil, conversationID: turn.conversationID,
                                             turnID: turn.id.uuidString, attempt: attempt.uuidString, userMessageID: turn.userMessageID)
        let hook = NativeChatEffectHook(
            revisions: { effects.revisions() },
            propose: { await effects.propose($0) },
            admit: { await effects.admit($0, decision: $1, answer: $2) },
            decline: { await effects.decline($0, answer: $1) },
            confirm: { _, _ in cards.hit(); return NativeCardAnswer(kind: .decline, byPerson: true) },
            answered: { _, _ in },
            settle: { await effects.settle($0, $1) })
        let rounds = [[NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: "set-1", name: "set_device", arguments: argumentsJSON)],
                                                finishReason: "tool_calls")],
                      [NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")]]
        let loop = NativeToolLoop(transport: ScriptedNativeToolTransport(rounds: rounds), registry: NativeToolRegistry(definitions: [tool]),
                                  executionTimeout: .seconds(5), instructionCheck: check, instructionTimeout: .seconds(5),
                                  said: words.said, effects: hook)
        var final: NativeToolTurnSnapshot?
        for try await snapshot in loop.stream(messages: [NativeChatMessage(role: "user", content: words.said)], model: "local-model",
                                              enabledToolIDs: [tool.id]) {
            final = snapshot
        }
        return final
    }

    static func ranWithoutCard(_ snapshot: NativeToolTurnSnapshot?, cards: NativeChatRulesCounter) -> Bool {
        guard let step = snapshot?.activities.first else { return false }
        return cards.count == 0 && step.state == .succeeded && step.ranBecause == .instruction
    }

    static func asked(_ snapshot: NativeToolTurnSnapshot?, cards: NativeChatRulesCounter) -> Bool {
        guard let step = snapshot?.activities.first else { return false }
        return cards.count == 1 && step.state == .failed && step.confirmationRequired
    }

    static func environment(_ chat: Chat, tools: [NativeToolDefinition]) -> NativeCompanionWorkerEnvironment {
        let rules = chat.rules
        let grants = chat.grants
        let thread = chat.turn.conversationID
        var made = NativeCompanionWorkerEnvironment(
            context: { _, _ in NativeCompanionWorkerContext(assistantName: nil, threadID: thread, tools: tools) },
            authority: { conversation, request in
                NativeCompanionWorkerAuthority(resolver: rules.resolver(for: conversation, requestText: request,
                                                                        typed: NativeTypedWords(typed: request.isEmpty ? nil : request)),
                                               grantsRevision: grants.revision)
            },
            ledger: NativeEffectLedgerStore(database: chat.repository.database), tasks: NativeTaskStore(database: chat.repository.database),
            pause: { _ in }, defaultToolSeconds: 2)
        made.instructionUses = NativeInstructionUseStore(database: chat.repository.database)
        return made
    }

    static func model(calls: Int = 1) -> NativeCompanionScriptedModel {
        let made = NativeCompanionScriptedModel { messages in
            let results = NativeCompanionScriptedModel.toolResults(messages).count
            if results < calls { return NativeCompanionScriptedModel.call("set_device", argumentsJSON, id: "call-\(results + 1)") }
            return NativeCompanionScriptedModel.text("Done.")
        }
        made.checks { .text("{\"run\": true}") }
        return made
    }

    static func work(_ chat: Chat, index: Int, assignment: String = typed, said: String?, mode: String = "manual") throws -> String {
        let origin = NativeTaskOrigin(conversationID: chat.turn.conversationID, userMessageID: chat.turn.userMessageID,
                                      assistantMessageID: chat.turn.assistantMessageID, index: index)
        let dot = try NativeCompanionTaskPayload(assignment: assignment, mode: mode, said: said)
        let request = try NativeResearchTaskRequest(dot: dot)
        guard let base = URL(string: "https://engine.test") else { throw NativeTaskFixture.Failure.assertion("The engine address parses") }
        let reference = try chat.repository.prepareTaskReference(origin: origin, engine: try NativeTaskEngineIdentity(base), request: request, profile: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try NativeTaskStore.canonical(try encoder.encode(NativeResearchTaskPayload(request: request)))
        return try NativeTaskStore(database: chat.repository.database).create(workerType: "companion", payload: payload,
                                                                              idempotencyKey: reference.id.uuidString).id
    }

    static func settle(_ environment: NativeCompanionWorkerEnvironment, _ model: NativeCompanionScriptedModel) async throws -> NativeTaskRecord {
        var last: NativeTaskRecord?
        for _ in 0..<12 {
            guard let claimed = try environment.tasks.claim(workerTypes: ["companion"]) else { break }
            let result = try await NativeCompanionWorker.step(claimed, environment: environment) { phase, attempt, _, messages, tools, _ in
                try model.complete(phase, attempt, messages, tools)
            }
            let record = try environment.tasks.commitStep(claimed.id, generation: claimed.generation, step: result)
            last = record
            if record.state != .queued { return record }
        }
        guard let last else { throw NativeTaskFixture.Failure.assertion("The work ran") }
        return last
    }

    static func storeRules() async throws {
        let require = NativeTaskFixture.require
        let chat = try chat()
        let store = NativeInstructionUseStore(database: chat.repository.database)
        let message = chat.turn.userMessageID
        let conversation = chat.turn.conversationID
        try require(store.take(message, conversationID: conversation, signature: "s", holder: "one"), "The first take wins")
        try require(!store.take(message, conversationID: conversation, signature: "s", holder: "two"), "Another holder is refused")
        try require(store.take(message, conversationID: conversation, signature: "s", holder: "one"), "The same holder takes it again")
        try require(store.take(message, conversationID: conversation, signature: "x", holder: "")
                        && !store.take(message, conversationID: conversation, signature: "x", holder: ""),
                    "An empty holder never takes the same instruction twice")
        try require(!store.used(message, signature: "s", excluding: "one") && store.used(message, signature: "s", excluding: "two")
                        && store.used(message, signature: "s", excluding: nil) && !store.used(message, signature: "other", excluding: nil),
                    "Used ignores the holder's own row and nothing else")
        let backed = NativeInstructionUses(store: store, messageID: message, conversationID: conversation, holder: "two")
        try require(backed.used("s") && !backed.used("other") && backed.take("other") && backed.used("other") && !backed.take("other")
                        && !store.used(message, signature: "other", excluding: nil),
                    "Uses read the saved record and only spend in memory")
        try require(NativeInstructionUses().take("s") && !NativeInstructionUses().used("s"), "Uses without a record behave as before")
        chat.store.deleteConversation(conversation)
        try require(try rows(chat).isEmpty && !store.used(message, signature: "s", excluding: nil), "Deleting the conversation removes its rows")

        let companion = try CompanionAskedWorkFixture.harness { _, _, _ in CompanionAskedWorkTransport.say("Hello.") }
        defer { companion.store.conversationTurnLoop?.cancel() }
        let spentHere = NativeInstructionUseStore(database: companion.repository.database)
        let kept = UUID()
        try require(spentHere.take(kept, conversationID: companion.threadID, signature: "s", holder: "one"), "The companion conversation spends")
        companion.store.discardVeraThread()
        try require(!spentHere.used(kept, signature: "s", excluding: nil), "Starting the companion over removes its rows")

        let broken = NativeInstructionUseStore(database: try DatabaseQueue())
        try require(!broken.take(message, conversationID: conversation, signature: "s", holder: "one")
                        && broken.used(message, signature: "s", excluding: "one")
                        && NativeInstructionUses(store: broken, messageID: message, conversationID: conversation, holder: "one").used("s"),
                    "A broken record never lets an instruction through")
    }

    static func replyThenWork() async throws {
        let require = NativeTaskFixture.require
        let chat = try chat()
        let cards = NativeChatRulesCounter()
        let first = try await reply(chat, cards: cards)
        try require(ranWithoutCard(first, cards: cards) && chat.device.count == 1, "The typed instruction runs in the reply with no card")
        try require(try rows(chat).count == 1, "The reply's run is saved")
        let environment = environment(chat, tools: [device(chat.device)])
        let id = try work(chat, index: 1, said: typed)
        let done = try await settle(environment, model())
        try require(done.state == .needsDecision && chat.device.count == 1
                        && (try environment.ledger.records(taskID: id)).allSatisfy { $0.state != .completed },
                    "Work from the same message asks with a card: \(done.state)")
    }

    static func workThenReply() async throws {
        let require = NativeTaskFixture.require
        var chat = try chat()
        let environment = environment(chat, tools: [device(chat.device)])
        let id = try work(chat, index: 1, said: typed)
        let done = try await settle(environment, model())
        try require(done.state == .completed && chat.device.count == 1
                        && (try environment.ledger.records(taskID: id)).filter { $0.state == .completed }.count == 1,
                    "Work started from the typed message runs once with no card: \(done.state)")
        try retry(&chat)
        let cards = NativeChatRulesCounter()
        let again = try await reply(chat, cards: cards)
        try require(asked(again, cards: cards) && chat.device.count == 1, "A new reply to the same message asks")
    }

    static func twoWorks() async throws {
        let require = NativeTaskFixture.require
        let chat = try chat()
        let environment = environment(chat, tools: [device(chat.device)])
        _ = try work(chat, index: 1, said: typed)
        let first = try await settle(environment, model())
        _ = try work(chat, index: 2, said: typed)
        let second = try await settle(environment, model())
        try require(first.state == .completed && second.state == .needsDecision && chat.device.count == 1,
                    "Of two pieces of work from one message, the first runs and the second asks: \(first.state) \(second.state)")
    }

    static func resumedWork() async throws {
        let require = NativeTaskFixture.require
        let chat = try chat()
        let environment = environment(chat, tools: [device(chat.device)])
        let id = try work(chat, index: 1, said: typed)
        let model = model(calls: 2)
        chat.device.hold(true)
        guard let claimed = try environment.tasks.claim(workerTypes: ["companion"]) else { throw NativeTaskFixture.Failure.assertion("Claimed") }
        let crashing = Task {
            try await NativeCompanionWorker.step(claimed, environment: environment) { phase, attempt, _, messages, tools, _ in
                try model.complete(phase, attempt, messages, tools)
            }
        }
        for _ in 0..<400 where !chat.device.started { try await Task.sleep(for: .milliseconds(5)) }
        try require(chat.device.started && (try rows(chat)).count == 1, "The action took the instruction when it was admitted")
        crashing.cancel()
        _ = try? await crashing.value
        try await chat.repository.database.write { db in
            try db.execute(sql: "UPDATE native_effect_ledger SET state = 'expired' WHERE task_id = ?", arguments: [id])
        }
        _ = try environment.tasks.recover()
        chat.device.hold(false)
        let done = try await settle(environment, model)
        let effects = try environment.ledger.records(taskID: id)
        try require(chat.device.count == 1 && effects.filter { $0.state == .completed }.count == 1 && (try rows(chat)).count == 1,
                    "Resuming the same action runs it once and its own record does not block it")
        try require(done.state == .needsDecision, "A different action with the same instruction asks: \(done.state)")
    }

    static func writtenAssignment() async throws {
        let require = NativeTaskFixture.require
        let chat = try chat(other)
        let environment = environment(chat, tools: [device(chat.device)])
        _ = try work(chat, index: 1, said: other)
        let done = try await settle(environment, model())
        try require(done.state == .needsDecision && chat.device.count == 0 && (try rows(chat)).isEmpty,
                    "An assignment the model wrote that the person never typed asks: \(done.state)")
    }

    static func oldWork() async throws {
        let require = NativeTaskFixture.require
        let legacy = try chat()
        let legacyEnvironment = environment(legacy, tools: [device(legacy.device)])
        _ = try work(legacy, index: 1, said: nil)
        let legacyDone = try await settle(legacyEnvironment, model())
        try require(legacyDone.state == .completed && legacy.device.count == 1, "Old work without the message runs on its own assignment as before")
        let silent = try chat()
        let silentEnvironment = environment(silent, tools: [device(silent.device)])
        _ = try work(silent, index: 1, said: "")
        let silentDone = try await settle(silentEnvironment, model())
        try require(silentDone.state == .needsDecision && silent.device.count == 0 && (try rows(silent)).isEmpty,
                    "Old work saved with nothing typed asks as before")
    }

    static func stoppedReply() async throws {
        let require = NativeTaskFixture.require
        var chat = try chat()
        let entered = NativeChatRulesCounter()
        let cards = NativeChatRulesCounter()
        let stopped = chat
        let running = Task {
            try await reply(stopped, cards: cards) { _, _ in
                entered.hit()
                try? await Task.sleep(for: .seconds(30))
                return true
            }
        }
        for _ in 0..<400 where entered.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        running.cancel()
        _ = try? await running.value
        try require(entered.count == 1 && chat.device.count == 0 && (try rows(chat)).isEmpty, "A reply stopped before its action ran leaves nothing saved")
        try retry(&chat)
        let retried = try await reply(chat, cards: cards)
        try require(ranWithoutCard(retried, cards: cards) && chat.device.count == 1, "Retrying it runs the instruction with no card")
        try retry(&chat)
        let again = try await reply(chat, cards: cards)
        try require(asked(again, cards: cards) && chat.device.count == 1, "Retrying a reply whose action ran asks")
    }

    static func concurrentAdmissions() async throws {
        let require = NativeTaskFixture.require
        let chat = try chat()
        guard let attempt = chat.turn.attempt?.uuidString else { throw NativeTaskFixture.Failure.assertion("The reply has an attempt") }
        let ledger = NativeEffectLedgerStore(database: chat.repository.database)
        func proposed(_ key: String) throws -> NativeEffectRecord {
            try ledger.propose(NativeEffectProposal(id: UUID().uuidString.lowercased(), taskID: NativeEffectProposal.turnTaskID(chat.turn.id.uuidString),
                                                    generation: 0, toolID: "fixture-home", function: "set_device", argumentsJSON: argumentsJSON,
                                                    target: nil, action: .otherChanges, rulesRevision: 0, grantsRevision: 0,
                                                    conversationID: chat.turn.conversationID, expiresAtMilliseconds: NativeEffectProposal.expiry(from: Date()),
                                                    idempotencyKey: key, turnID: chat.turn.id.uuidString, turnAttempt: attempt))
        }
        let message = chat.turn.userMessageID
        let conversation = chat.turn.conversationID
        func spend(_ holder: String) -> NativeInstructionSpend {
            NativeInstructionSpend(messageID: message, conversationID: conversation, signature: "s", holder: holder)
        }
        let one = try proposed("one")
        let two = try proposed("two")
        let admit: @Sendable (String, String) async throws -> NativeEffectAdmission = { digest, holder in
            try await Task.detached {
                try ledger.admit(digest: digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .act(.instruction), decisionID: nil,
                                 reply: nil, instruction: NativeInstructionSpend(messageID: message, conversationID: conversation, signature: "s", holder: holder))
            }.value
        }
        async let first = admit(one.digest, "one")
        async let second = admit(two.digest, "two")
        let outcomes = try await [first, second]
        let admitted = outcomes.filter { if case .admitted = $0 { true } else { false } }.count
        try require(admitted == 1 && outcomes.contains(.refused(.instructionSpent)) && (try rows(chat)).count == 1,
                    "Of two admissions racing for one instruction exactly one is admitted: \(outcomes)")
        let winner = outcomes[0] == .refused(.instructionSpent) ? "two" : "one"
        let loser = winner == "one" ? two : one
        try require(try ledger.record(digest: loser.digest)?.state == .proposed, "The refused action stays waiting to ask")
        let repeatOne = try proposed("three")
        guard case .admitted = try ledger.admit(digest: repeatOne.digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .act(.instruction),
                                                decisionID: nil, reply: nil, instruction: spend(winner)) else {
            throw NativeTaskFixture.Failure.assertion("The holder that spent it admits again")
        }
    }

    static func unresolvedOrigin() async throws {
        let require = NativeTaskFixture.require
        let chat = try chat()
        let environment = environment(chat, tools: [device(chat.device)])
        let dot = try NativeCompanionTaskPayload(assignment: typed, mode: "manual", said: typed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try NativeTaskStore.canonical(try encoder.encode(NativeResearchTaskPayload(request: try NativeResearchTaskRequest(dot: dot))))
        let id = try environment.tasks.create(workerType: "companion", payload: payload, idempotencyKey: UUID().uuidString).id
        let done = try await settle(environment, model())
        try require(done.state == .needsDecision && chat.device.count == 0 && (try rows(chat)).isEmpty
                        && (try environment.ledger.records(taskID: id)).allSatisfy { $0.state != .completed },
                    "Work whose message can't be found asks with a card and saves nothing: \(done.state)")
    }

    static func lapsedDuringCheck() async throws {
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spent-beside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = try FolderGrant.make(url: directory)
        let draft = grant.path + "/draft.md"
        let readme = grant.path + "/README.md"
        let message = "Update README to match draft.md"
        try Data("old".utf8).write(to: URL(fileURLWithPath: draft))
        let chat = try chat(message, rules: [.fileEdits: .ask])
        let rules = chat.rules
        let thread = chat.turn.conversationID
        let tools = NativeFolderTools.definitions(grants: { [grant] }, ledger: NativeFileChangeLedger(), edits: .ask, trash: .ask, live: { action in
            rules.resolver(for: thread, requestText: "").decision(for: action)
        })
        let environment = environment(chat, tools: tools)
        func writer() -> NativeCompanionScriptedModel {
            NativeCompanionScriptedModel { messages in
                if NativeCompanionScriptedModel.toolResults(messages).isEmpty {
                    return NativeCompanionScriptedModel.call(NativeFolderTools.writeName, "{\"path\":\"\(draft)\",\"content\":\"new\"}")
                }
                return NativeCompanionScriptedModel.text("Updated it.")
            }
        }
        let checked = NativeChatRulesCounter()
        let first = writer()
        first.checks {
            checked.hit()
            try Data().write(to: URL(fileURLWithPath: readme))
            return .text("{\"run\": true}")
        }
        _ = try work(chat, index: 1, assignment: message, said: message)
        let asked = try await settle(environment, first)
        let unchanged = String(decoding: try Data(contentsOf: URL(fileURLWithPath: draft)), as: UTF8.self)
        try require(checked.count == 1 && asked.state == .needsDecision && unchanged == "old" && (try rows(chat)).isEmpty,
                    "An instruction that stops qualifying during the check asks, changes nothing and is not spent: \(asked.state)")
        try FileManager.default.removeItem(atPath: readme)
        let second = writer()
        second.checks { .text("{\"run\": true}") }
        _ = try work(chat, index: 2, assignment: message, said: message)
        let ran = try await settle(environment, second)
        let changed = String(decoding: try Data(contentsOf: URL(fileURLWithPath: draft)), as: UTF8.self)
        try require(ran.state == .completed && changed == "new" && (try rows(chat)).count == 1,
                    "The unspent instruction still runs once for the next piece of work: \(ran.state)")
    }
}
