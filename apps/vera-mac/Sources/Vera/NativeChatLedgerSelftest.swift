import CryptoKit
import Foundation
import GRDB

final class NativeChatLedgerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
    func count(_ entry: String) -> Int { lock.withLock { entries.filter { $0 == entry }.count } }
}

@MainActor
extension SelfTest {
    static func runNativeChatLedger() async throws {
        try await runChatLedgerTurnRows()
        try runChatLedgerMigration()
        try await runChatLedgerLoopKinds()
        try await runChatLedgerLoopAnswers()
        try await runChatLedgerStaleAnswers()
        try await runChatLedgerBoundary()
        try await runChatLedgerToolBoundaries()
        try await runChatLedgerStore()
        try await runChatLedgerRelaunch()
        print("  chat ledger OK (turn rows, migration, every write kind, answers, stale answers, store, relaunch)")
    }

    static let chatLedgerConfig = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model",
                                                   chatTemplateKwargs: nil)

    static func chatLedgerTurn(_ repository: LocalChatRepository) throws -> (ChatStore, NativeConversationTurn) {
        let store = ChatStore(nativeConfig: chatLedgerConfig, nativeTransport: ScriptedNativeToolTransport(rounds: []), repository: repository,
                              nativeEnabledToolIDs: [], nativeToolRegistry: NativeToolRegistry(definitions: []), artifactPersistenceEnabled: false)
        store.newConversation()
        store.suspendsTurnScheduling = true
        store.sendText("Look after the garden")
        guard let pending = try repository.conversationTurns().last, let turn = try repository.claimTurn(pending.id, attempt: UUID()) else {
            throw NativeTaskFixture.Failure.assertion("A chat turn can be claimed for the ledger")
        }
        return (store, turn)
    }

    static func chatLedgerProposal(_ clock: NativeEffectTestClock, turn: NativeConversationTurn, attempt: UUID? = nil, key: String,
                                   rules: Int = 0, grants: Int = 0) -> NativeEffectProposal {
        NativeEffectProposal(id: UUID().uuidString.lowercased(), taskID: NativeEffectProposal.turnTaskID(turn.id.uuidString), generation: 0,
                             toolID: NativeFolderTools.toolID, function: "write_file",
                             argumentsJSON: NativeEffectProposal.canonicalArguments(.object(["path": .string("notes/plan.txt")])),
                             target: "notes/plan.txt", action: .fileEdits, rulesRevision: rules, grantsRevision: grants,
                             conversationID: turn.conversationID, expiresAtMilliseconds: NativeEffectProposal.expiry(from: clock.now),
                             idempotencyKey: key, turnID: turn.id.uuidString, turnAttempt: (attempt ?? turn.attempt)?.uuidString)
    }

    private static func runChatLedgerTurnRows() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let ledger = NativeEffectLedgerStore(database: repository.database, now: { clock.now })
        let (_, turn) = try chatLedgerTurn(repository)
        let turnID = turn.id.uuidString

        let pinned = NativeEffectProposal(id: "pinned", taskID: "task-1", generation: 1, toolID: NativeFolderTools.toolID, function: "write_file",
                                          argumentsJSON: NativeEffectProposal.canonicalArguments(.object(["path": .string("notes/plan.txt"),
                                                                                                          "content": .string("Water the beds")])),
                                          target: "notes/plan.txt", action: .fileEdits, rulesRevision: 0, grantsRevision: 0,
                                          conversationID: "conversation-1", expiresAtMilliseconds: NativeEffectProposal.expiry(from: clock.now),
                                          idempotencyKey: "call-1")
        let earlier = [pinned.taskID, "1", NativeFolderTools.toolID, "write_file", pinned.argumentsJSON, "notes/plan.txt", NativeActionClass.fileEdits.rawValue,
                       "0", "0", "conversation-1", String(pinned.expiresAtMilliseconds), "call-1"]
        var framed = Data()
        for field in earlier {
            let value = Data(field.utf8)
            framed.append(Data("\(value.count):".utf8))
            framed.append(value)
        }
        try require(pinned.digest == SHA256.hash(data: framed).map { String(format: "%02x", $0) }.joined(),
                    "A task proposal's digest is unchanged by turn identity")
        var turned = pinned
        turned.turnID = turnID
        turned.turnAttempt = turn.attempt?.uuidString
        try require(turned.digest != pinned.digest, "A turn proposal's digest also covers the turn")
        var reattempted = turned
        reattempted.turnAttempt = UUID().uuidString
        try require(reattempted.digest != turned.digest, "A turn proposal's digest also covers the attempt")

        let proposed = try ledger.propose(chatLedgerProposal(clock, turn: turn, key: "act"))
        try require(proposed.state == .proposed && proposed.proposal.turnID == turnID && proposed.proposal.turnAttempt == turn.attempt?.uuidString
                    && proposed.proposal.taskID == "turn:" + turnID && proposed.proposal.generation == 0,
                    "A chat proposal is saved with its turn and attempt in a separate task space")
        guard case .admitted = try ledger.admit(digest: proposed.digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .act(.rule),
                                                decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("A running turn admits an act proposal")
        }
        try require(try ledger.hasAdmitted(turnID: turnID), "The turn has an admitted row")
        try ledger.settle(digest: proposed.digest, receipt: .object(["ok": .bool(true)]), modelClaim: nil)
        try require(try ledger.record(digest: proposed.digest)?.state == .completed && !(try ledger.hasAdmitted(turnID: turnID)),
                    "A settled chat row is completed")

        let asked = try ledger.propose(chatLedgerProposal(clock, turn: turn, key: "ask"))
        let other = try ledger.propose(chatLedgerProposal(clock, turn: turn, key: "ask-other"))
        try require(try ledger.admit(digest: asked.digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .ask, decisionID: "card",
                                     reply: .object(["action": .string("approve"), "digest": .string(other.digest)])) == .refused(.ruleAsks),
                    "An answer bound to a different proposal is refused")
        guard case .admitted = try ledger.admit(digest: asked.digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .ask,
                                                decisionID: "card", reply: .object(["action": .string("approve"), "digest": .string(asked.digest)])) else {
            throw NativeTaskFixture.Failure.assertion("An ask admits with an answer bound to its digest")
        }
        try ledger.settle(digest: asked.digest, receipt: nil, modelClaim: nil)
        try ledger.decline(digest: other.digest, decisionID: "card", reply: nil)
        try require(try ledger.admit(digest: other.digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .ask, decisionID: "card",
                                     reply: .object(["digest": .string(other.digest)])) == .refused(.declined),
                    "A declined chat row never admits")

        let stale = try ledger.propose(chatLedgerProposal(clock, turn: turn, key: "stale-rules"))
        try require(try ledger.admit(digest: stale.digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .act(.rule), decisionID: nil,
                                     reply: nil, live: { (rules: 1, grants: 0) }) == .refused(.staleRules), "Changed rules refuse a chat row")
        try require(try ledger.admit(digest: stale.digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .act(.rule), decisionID: nil,
                                     reply: nil, live: { (rules: 0, grants: 1) }) == .refused(.staleGrants), "Changed folders refuse a chat row")

        let elsewhere = try ledger.propose(chatLedgerProposal(clock, turn: turn, attempt: UUID(), key: "other-attempt"))
        try require(try ledger.admit(digest: elsewhere.digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .act(.rule),
                                     decisionID: nil, reply: nil) == .refused(.taskInactive), "A row from another attempt never admits")

        clock.advance(3600)
        let late = try ledger.propose(chatLedgerProposal(clock, turn: turn, key: "late"))
        clock.advance(NativeEffectProposal.lifetime * 6)
        guard case .admitted = try ledger.admit(digest: late.digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .act(.rule),
                                                decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("A chat proposal older than ten minutes still admits")
        }
        try require(try ledger.expireStale() == 0, "The sweep never expires a chat row")

        try seedRunningTask(repository)
        let task = try ledger.propose(NativeEffectProposal(id: UUID().uuidString.lowercased(), taskID: "task-1", generation: 1,
                                                           toolID: NativeFolderTools.toolID, function: "write_file", argumentsJSON: "{}", target: nil,
                                                           action: .fileEdits, rulesRevision: 0, grantsRevision: 0, conversationID: "conversation-1",
                                                           expiresAtMilliseconds: NativeEffectProposal.expiry(from: clock.now), idempotencyKey: "task"))
        _ = try ledger.admit(digest: task.digest, generation: 1, rulesRevision: 0, grantsRevision: 0, decision: .act(.rule), decisionID: nil, reply: nil)
        try require(try ledger.abandonAdmitted(taskID: "task-1") == 1 && (try ledger.record(digest: late.digest))?.state == .admitted,
                    "Abandoning a task's rows never touches a chat row")
        let recovered = try ledger.recoverAtBringUp()
        try require(recovered.isEmpty && (try ledger.record(digest: late.digest))?.state == .admitted,
                    "Engine bring-up leaves an admitted chat row alone")
        try require(try ledger.interruptTurn(turnID) == 1 && (try ledger.record(digest: late.digest))?.state == .uncertain
                    && (try ledger.record(digest: late.digest))?.receipt == .object(["reason": .string("interrupted")]),
                    "An interrupted turn's admitted row becomes uncertain")

        let records = NativeRuleRecordStore(database: repository.database, now: { clock.now })
        let source = NativeRuleSource()
        ChatStore.prepareRules(source, from: records)
        let grant = try records.add(NativeRuleRecord(action: .fileEdits, toolID: NativeFolderTools.toolID, effect: .allow,
                                                     statement: "Save the plan once", remainingUses: 1))
        ChatStore.reloadRules(source, from: records)
        let live: @Sendable () -> (rules: Int, grants: Int) = { (rules: source.revision, grants: 0) }
        let refusedFirst = try ledger.propose(chatLedgerProposal(clock, turn: turn, key: "grant-refused", rules: source.revision, grants: 1))
        try require(try ledger.admit(digest: refusedFirst.digest, generation: 0, rulesRevision: source.revision, grantsRevision: 1, decision: .act(.grant),
                                     decisionID: nil, reply: nil, live: live, rulesDurable: true, authorizedBy: [grant.id]) == .refused(.staleGrants)
                    && (try records.record(id: grant.id))?.remainingUses == 1, "A refused chat admission keeps the one use")
        let spends = try ledger.propose(chatLedgerProposal(clock, turn: turn, key: "grant-spends", rules: source.revision))
        guard case .admitted = try ledger.admit(digest: spends.digest, generation: 0, rulesRevision: source.revision, grantsRevision: 0,
                                                decision: .act(.grant), decisionID: nil, reply: nil, live: live, rulesDurable: true,
                                                authorizedBy: [grant.id]) else {
            throw NativeTaskFixture.Failure.assertion("A one-use allow admits one chat row")
        }
        ChatStore.reloadRules(source, from: records)
        let again = try ledger.propose(chatLedgerProposal(clock, turn: turn, key: "grant-again", rules: source.revision))
        try require(try ledger.admit(digest: again.digest, generation: 0, rulesRevision: source.revision, grantsRevision: 0, decision: .act(.grant),
                                     decisionID: nil, reply: nil, live: live, rulesDurable: true, authorizedBy: [grant.id]) == .refused(.grantSpent),
                    "The one use is consumed by exactly one chat admission")
        try records.revoke(id: grant.id)
        try ledger.settle(digest: spends.digest, receipt: .null, modelClaim: nil)
        try require(try ledger.record(digest: spends.digest)?.state == .completed, "A revoke after admission leaves the row to settle")

        try await repository.database.write { db in
            try db.execute(sql: "UPDATE native_conversation_turns SET state = 'stopped' WHERE id = ?", arguments: [turnID])
        }
        let stopped = try ledger.propose(chatLedgerProposal(clock, turn: turn, key: "stopped"))
        try require(try ledger.admit(digest: stopped.digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .act(.rule),
                                     decisionID: nil, reply: nil) == .refused(.taskInactive), "A stopped turn cannot admit")
        try await repository.database.write { db in
            try db.execute(sql: "UPDATE native_conversation_turns SET state = 'pending', attempt = NULL WHERE id = ?", arguments: [turnID])
        }
        try require(try ledger.admit(digest: stopped.digest, generation: 0, rulesRevision: 0, grantsRevision: 0, decision: .act(.rule),
                                     decisionID: nil, reply: nil) == .refused(.taskInactive), "A turn that is not running cannot admit")
    }

    private static func runChatLedgerMigration() throws {
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("vera.sqlite")
        let digest = "previous-schema-digest"
        do {
            let queue = try DatabaseQueue(path: url.path)
            try LocalChatRepository.migrator().migrate(queue, upTo: "nativeRuleOffersV38")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO native_engine_tasks(id, worker_type, payload, creation_key, state, generation, created_at, updated_at)
                    VALUES('task-old', 'dot', '{}', 'seed-old', 'running', 1, 0, 0)
                    """)
                try db.execute(sql: """
                    INSERT INTO native_effect_ledger(id, task_id, generation, tool_id, function, arguments_json, target, action, rules_revision,
                        grants_revision, conversation_id, expires_at, digest, state, idempotency_key, created_at, updated_at)
                    VALUES('old', 'task-old', 1, 'folder-files', 'write_file', '{}', NULL, 'file_edits', 0, 0, 'conversation-1', 99999999999,
                        ?, 'proposed', 'old-key', 1, 1)
                    """, arguments: [digest])
            }
        }
        let repository = try LocalChatRepository(url: url)
        let columns = try repository.database.read { db in try db.columns(in: "native_effect_ledger").map(\.name) }
        try require(columns.contains("turn_id") && columns.contains("turn_attempt"), "The upgrade adds the turn columns")
        let ledger = NativeEffectLedgerStore(database: repository.database)
        guard let record = try ledger.record(digest: digest) else { throw NativeTaskFixture.Failure.assertion("The old row survives the upgrade") }
        try require(record.state == .proposed && record.proposal.taskID == "task-old" && record.proposal.turnID == nil
                    && record.proposal.turnAttempt == nil, "The old row is intact with no turn")
        try require(try ledger.admit(digest: digest, generation: 1, rulesRevision: 0, grantsRevision: 0, decision: .act(.rule), decisionID: nil,
                                     reply: nil) == .refused(.digestMismatch), "The old row is checked as before")
        let fresh = NativeEffectProposal(id: "fresh", taskID: "task-old", generation: 1, toolID: "folder-files", function: "write_file",
                                         argumentsJSON: "{}", target: nil, action: .fileEdits, rulesRevision: 0, grantsRevision: 0,
                                         conversationID: "conversation-1", expiresAtMilliseconds: NativeEffectProposal.expiry(from: Date()),
                                         idempotencyKey: "fresh-key")
        let proposed = try ledger.propose(fresh)
        guard case .admitted = try ledger.admit(digest: proposed.digest, generation: 1, rulesRevision: 0, grantsRevision: 0, decision: .act(.rule),
                                                decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("A task row admits after the upgrade as before")
        }
    }

    static func chatLedgerHook(_ ledger: NativeEffectLedgerStore, turn: NativeConversationTurn, rules: NativeRuleSource, grants: NativeFolderGrantSource,
                               log: NativeChatLedgerLog, answer: @escaping @Sendable (NativeToolActivity) async -> NativeCardAnswer)
        -> NativeChatEffectHook {
        let chat = NativeChatEffectLedger(ledger: ledger, rules: rules, grants: grants, records: nil, conversationID: turn.conversationID,
                                          turnID: turn.id.uuidString, attempt: turn.attempt?.uuidString ?? "")
        return NativeChatEffectHook(
            revisions: { chat.revisions() },
            propose: { await chat.propose($0) },
            admit: { await chat.admit($0, decision: $1, answer: $2) },
            decline: { await chat.decline($0, answer: $1) },
            confirm: { activity, _ in log.add("card:" + activity.name); return await answer(activity) },
            answered: { activity, answer in
                let admitted = ((try? ledger.records(turnID: turn.id.uuidString)) ?? []).contains { $0.state == .admitted && $0.proposal.function == activity.name }
                log.add("answered:" + activity.name + ":" + answer.kind.rawValue + (admitted ? ":after" : ":before"))
            },
            settle: { await chat.settle($0, $1) })
    }

    static func chatLedgerLoop(_ definitions: [NativeToolDefinition], calls: [[NativeChatToolCall]], hook: NativeChatEffectHook?,
                               instructionCheck: NativeInstructionAnswerer? = nil) async throws -> NativeToolTurnSnapshot? {
        let rounds = calls.map { [NativeChatStreamSnapshot(content: "", toolCalls: $0, finishReason: "tool_calls")] }
            + [[NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")]]
        let loop = NativeToolLoop(transport: ScriptedNativeToolTransport(rounds: rounds), registry: NativeToolRegistry(definitions: definitions),
                                  executionTimeout: .seconds(5), instructionCheck: instructionCheck, instructionTimeout: .seconds(2),
                                  said: "Look after the garden", effects: hook)
        var final: NativeToolTurnSnapshot?
        for try await snapshot in loop.stream(messages: [NativeChatMessage(role: "user", content: "Look after the garden")], model: "local-model",
                                              enabledToolIDs: Set(definitions.map(\.id))) {
            final = snapshot
        }
        return final
    }

    static func chatLedgerFixture(id: String, name: String, action: NativeActionClass?, confirmation: NativeToolConfirmation = .none,
                                  effect: NativeToolEffect = .write, log: NativeChatLedgerLog,
                                  run: (@Sendable () async throws -> NativeJSONValue)? = nil) -> NativeToolDefinition {
        NativeToolDefinition(id: id, name: name, title: "Garden " + name, description: "Garden fixture " + name,
                             parameters: .object(["type": .string("object"), "properties": .object(["path": .object(["type": .string("string")])])]),
                             confirmation: confirmation, effect: effect, action: action, isAvailable: { true },
                             execute: { _ in
                                 log.add("ran:" + name)
                                 if let run { return try await run() }
                                 return .object(["ok": .bool(true)])
                             })
    }

    static func chatLedgerRules(_ choices: [NativeActionClass: NativeRuleChoice]) -> NativeRuleSource {
        var rules = NativeRules.defaults
        for (action, choice) in choices { rules.set(choice, for: action) }
        let source = NativeRuleSource()
        source.setGlobal(rules)
        return source
    }

    static func chatLedgerRows(_ ledger: NativeEffectLedgerStore, _ turn: NativeConversationTurn, _ name: String) throws -> [NativeEffectRecord] {
        try ledger.records(turnID: turn.id.uuidString).filter { $0.proposal.function == name }
    }

    private static func runChatLedgerLoopKinds() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let ledger = NativeEffectLedgerStore(database: repository.database)
        let (_, turn) = try chatLedgerTurn(repository)
        let log = NativeChatLedgerLog()
        let rules = chatLedgerRules([.fileEdits: .act, .trash: .act, .commands: .act, .reminders: .act, .networkSends: .act,
                                     .serviceChanges: .act, .otherChanges: .act])
        let grants = NativeFolderGrantSource()
        let hook = chatLedgerHook(ledger, turn: turn, rules: rules, grants: grants, log: log) { _ in NativeCardAnswer(kind: .allowOnce, byPerson: true) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Old".write(to: directory.appendingPathComponent("trash-me.txt"), atomically: true, encoding: .utf8)
        let grant = try FolderGrant.make(url: directory)
        let folder = NativeFolderTools.definitions(grants: { [grant] }, ledger: NativeFileChangeLedger(), edits: .act(.rule), trash: .act(.rule))
        let command = NativeCommandTools.definitions(grants: { [grant] }, decision: .act(.rule), reason: { _ in nil }, record: { _ in },
                                                     live: { _, _ in .act(.rule) })
        let conversationID = turn.conversationID
        let ruled: (NativeToolDefinition) -> NativeToolDefinition = {
            ChatStore.ruled($0, rules: rules, store: nil, conversationID: conversationID, requestText: "Look after the garden")
        }
        let reminder = ruled(chatLedgerFixture(id: "apple-reminders", name: "apple_reminders_create", action: .reminders, log: log))
        let send = ruled(chatLedgerFixture(id: "capability-garden_log", name: "garden_log", action: .networkSends, log: log))
        let image = ruled(chatLedgerFixture(id: NativeImageTools.toolID, name: NativeImageTools.toolName, action: .fileEdits, log: log))
        let schedule = ruled(chatLedgerFixture(id: NativeScheduleTools.toolID, name: "schedule_garden", action: .otherChanges, confirmation: .required, log: log))
        let service = ruled(chatLedgerFixture(id: "mcp_" + String(repeating: "a1", count: 20), name: "water_bed", action: .serviceChanges, log: log))
        var profile = chatLedgerFixture(id: NativeCompanionProfileTools.toolID, name: "update_companion_profile", action: nil, log: log)
        profile.confirmationFor = { _ in false }
        let reading = chatLedgerFixture(id: "garden-read", name: "read_garden", action: nil, effect: .read, log: log)
        let search = chatLedgerFixture(id: NativeWebTools.searchToolID, name: NativeWebTools.searchToolName, action: nil, effect: .read, log: log)
        let path = grant.path
        let first = try await chatLedgerLoop(folder + command + [reminder, send, image], calls: [[
            NativeChatToolCall(id: "k-command", name: NativeCommandTools.runName, arguments: "{\"command\":\"echo watered\",\"directory\":\"\(path)\"}"),
            NativeChatToolCall(id: "k-write", name: "write_file", arguments: "{\"path\":\"\(path)/plan.txt\",\"content\":\"Water the beds\"}"),
            NativeChatToolCall(id: "k-trash", name: "move_to_trash", arguments: "{\"path\":\"\(path)/trash-me.txt\"}"),
        ], [
            NativeChatToolCall(id: "k-reminder", name: "apple_reminders_create", arguments: "{\"path\":\"Water\"}"),
            NativeChatToolCall(id: "k-send", name: "garden_log", arguments: "{\"path\":\"log\"}"),
            NativeChatToolCall(id: "k-image", name: NativeImageTools.toolName, arguments: "{\"path\":\"bed\"}"),
        ]], hook: hook)
        try require(first?.activities.allSatisfy { $0.state == .succeeded } == true,
                    "Every write of the first batch runs: \(first?.activities.map { "\($0.name) \($0.state) \($0.result ?? "")" } ?? [])")
        let expected: [(String, NativeActionClass)] = [(NativeCommandTools.runName, .commands), ("write_file", .fileEdits), ("move_to_trash", .trash),
                                                       ("apple_reminders_create", .reminders), ("garden_log", .networkSends),
                                                       (NativeImageTools.toolName, .fileEdits)]
        for (name, action) in expected {
            let rows = try chatLedgerRows(ledger, turn, name)
            try require(rows.count == 1 && rows[0].state == .completed && rows[0].proposal.action == action && rows[0].decisionID == nil,
                        "\(name) leaves one completed act row: \(rows.map { "\($0.state) \($0.proposal.action)" })")
        }
        try require(try chatLedgerRows(ledger, turn, "write_file")[0].proposal.target == "\(path)/plan.txt", "The row records the target")

        let second = try await chatLedgerLoop([schedule, service, profile, reading, search], calls: [[
            NativeChatToolCall(id: "k-schedule", name: "schedule_garden", arguments: "{\"path\":\"weekly\"}"),
            NativeChatToolCall(id: "k-service", name: "water_bed", arguments: "{\"path\":\"north\"}"),
            NativeChatToolCall(id: "k-profile", name: "update_companion_profile", arguments: "{\"path\":\"name\"}"),
            NativeChatToolCall(id: "k-read", name: "read_garden", arguments: "{\"path\":\"north\"}"),
            NativeChatToolCall(id: "k-search", name: NativeWebTools.searchToolName, arguments: "{\"path\":\"roses\"}"),
        ], [
            NativeChatToolCall(id: "k-search-again", name: NativeWebTools.searchToolName, arguments: "{\"path\":\"roses\"}"),
        ]], hook: hook)
        try require(second?.activities.allSatisfy { $0.state == .succeeded } == true, "Every call of the second batch runs")
        let scheduled = try chatLedgerRows(ledger, turn, "schedule_garden")
        try require(scheduled.count == 1 && scheduled[0].state == .completed && scheduled[0].decisionID == "k-schedule"
                    && NativeEffectProposal.bindsReply(scheduled[0].decisionReply, to: scheduled[0].digest) && log.count("card:schedule_garden") == 1,
                    "A schedule still asks and its row is admitted with the bound answer")
        let serviced = try chatLedgerRows(ledger, turn, "water_bed")
        try require(serviced.count == 1 && serviced[0].state == .completed && serviced[0].proposal.action == .serviceChanges,
                    "A connected-service write leaves a completed row")
        let profiled = try chatLedgerRows(ledger, turn, "update_companion_profile")
        try require(profiled.count == 1 && profiled[0].state == .completed && profiled[0].proposal.action == .otherChanges,
                    "A companion profile change leaves a completed row")
        try require(try chatLedgerRows(ledger, turn, "read_garden").isEmpty && (try chatLedgerRows(ledger, turn, NativeWebTools.searchToolName)).isEmpty
                    && log.count("ran:" + NativeWebTools.searchToolName) == 1, "A read and a cached search create no rows")

        var handOffRules = NativeRules.defaults
        handOffRules.set(.handOff, for: .networkSends)
        rules.setGlobal(handOffRules)
        let handed = try await chatLedgerLoop([send], calls: [[NativeChatToolCall(id: "k-handoff", name: "garden_log", arguments: "{\"path\":\"log\"}")]],
                                              hook: hook)
        try require(handed?.activities.first?.state == .failed && handed?.activities.first?.why?.handsOff == true
                    && log.count("ran:garden_log") == 1 && (try chatLedgerRows(ledger, turn, "garden_log")).count == 1,
                    "A hand-off refuses with its reason and creates no admitted row")
        let noHook = try await chatLedgerLoop([send], calls: [[NativeChatToolCall(id: "k-plain", name: "garden_log", arguments: "{\"path\":\"log\"}")]],
                                              hook: nil)
        try require(noHook?.activities.first?.state == .failed && noHook?.activities.first?.why?.handsOff == true,
                    "Without the hook a hand-off reads the same")
    }

    private static func runChatLedgerLoopAnswers() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let ledger = NativeEffectLedgerStore(database: repository.database)
        let (_, turn) = try chatLedgerTurn(repository)
        let log = NativeChatLedgerLog()
        let rules = chatLedgerRules([.networkSends: .ask])
        let grants = NativeFolderGrantSource()
        let conversationID = turn.conversationID
        let send = ChatStore.ruled(chatLedgerFixture(id: "capability-garden_log", name: "garden_log", action: .networkSends, log: log),
                                   rules: rules, store: nil, conversationID: conversationID, requestText: "")
        let call: (String) -> NativeChatToolCall = { NativeChatToolCall(id: $0, name: "garden_log", arguments: "{\"path\":\"log\"}") }

        let approving = chatLedgerHook(ledger, turn: turn, rules: rules, grants: grants, log: log) { _ in NativeCardAnswer(kind: .allowOnce, byPerson: true) }
        let approved = try await chatLedgerLoop([send], calls: [[call("a-approve")]], hook: approving)
        let approvedRows = try chatLedgerRows(ledger, turn, "garden_log")
        try require(approved?.activities.first?.state == .succeeded && approvedRows.count == 1 && approvedRows[0].state == .completed
                    && approvedRows[0].decisionID == "a-approve" && log.count("answered:garden_log:approve:after") == 1,
                    "An approved card admits with its answer, then runs and completes")

        let declining = chatLedgerHook(ledger, turn: turn, rules: rules, grants: grants, log: log) { _ in NativeCardAnswer(kind: .decline, byPerson: true) }
        let declined = try await chatLedgerLoop([send], calls: [[call("a-decline")], [call("a-decline-again")]], hook: declining)
        let declinedRows = try chatLedgerRows(ledger, turn, "garden_log").filter { $0.decisionID?.hasPrefix("a-decline") == true }
        try require(declined?.activities.count == 2 && declined?.activities.allSatisfy {
                        $0.state == .failed && ($0.result ?? "").contains("The user did not approve this call")
                    } == true && declinedRows.count == 2 && declinedRows.allSatisfy { $0.state == .declined } && log.count("ran:garden_log") == 1,
                    "A declined card is recorded declined and the tool never runs")

        let stopping = chatLedgerHook(ledger, turn: turn, rules: rules, grants: grants, log: log) { _ in NativeCardAnswer(kind: .decline, byPerson: false) }
        _ = try await chatLedgerLoop([send], calls: [[call("a-stop")]], hook: stopping)
        try require(try chatLedgerRows(ledger, turn, "garden_log").contains { $0.proposal.idempotencyKey ==
                        NativeChatEffects.idempotencyKey(turnID: turn.id.uuidString, attempt: turn.attempt?.uuidString ?? "", round: 1, call: "a-stop")
                        && $0.state == .proposed },
                    "A card closed by a stop leaves its row proposed, not declined")

        let always = chatLedgerHook(ledger, turn: turn, rules: rules, grants: grants, log: log) { _ in NativeCardAnswer(kind: .allowAlways, byPerson: true) }
        var saving = always
        saving.answered = { activity, answer in
            await always.answered(activity, answer)
            var opened = NativeRules.defaults
            opened.set(.act, for: .networkSends)
            rules.setGlobal(opened)
        }
        let before = log.count("card:garden_log")
        let ranBefore = log.count("ran:garden_log")
        let saved = try await chatLedgerLoop([send], calls: [[call("a-always")], [call("a-always-next")]], hook: saving)
        try require(saved?.activities.allSatisfy { $0.state == .succeeded } == true && log.count("card:garden_log") == before + 1
                    && log.count("answered:garden_log:allow_always:after") == 1 && log.count("ran:garden_log") == ranBefore + 2,
                    "Always allow admits first, saves the rule after, and the next call runs with no card")

        var instructed = chatLedgerFixture(id: "garden-instructed", name: "plant_bulbs", action: .otherChanges, log: log)
        let refusedSignatures = NativeChatLedgerLog()
        instructed.confirmationFor = { _ in false }
        instructed.instructionFor = { _ in NativeInstructionPending(signature: "plant", about: "plant the bulbs", refuse: { refusedSignatures.add("plant") }) }
        let yes = try await chatLedgerLoop([instructed], calls: [[NativeChatToolCall(id: "i-yes", name: "plant_bulbs", arguments: "{}")]],
                                           hook: declining, instructionCheck: { _, _ in true })
        let no = try await chatLedgerLoop([instructed], calls: [[NativeChatToolCall(id: "i-no", name: "plant_bulbs", arguments: "{}")]],
                                          hook: declining, instructionCheck: { _, _ in false })
        let planted = try chatLedgerRows(ledger, turn, "plant_bulbs")
        try require(yes?.activities.first?.state == .succeeded && no?.activities.first?.state == .failed && refusedSignatures.count("plant") == 1
                    && planted.count == 2 && planted.contains { $0.state == .completed && $0.decisionID == nil }
                    && planted.contains { $0.state == .declined && $0.decisionID == "i-no" },
                    "A typed instruction yes runs as the instruction and a no falls to the card")

        var slow = chatLedgerFixture(id: "garden-slow", name: "slow_water", action: .otherChanges, log: log) {
            try await Task.sleep(for: .seconds(3))
            return .object(["ok": .bool(true)])
        }
        slow.confirmationFor = { _ in false }
        slow.timeout = .milliseconds(200)
        var invalid = chatLedgerFixture(id: "garden-invalid", name: "bad_water", action: .otherChanges, log: log) {
            throw NativeToolError.invalidArguments("The bed name is missing")
        }
        invalid.confirmationFor = { _ in false }
        _ = try await chatLedgerLoop([slow, invalid], calls: [[NativeChatToolCall(id: "t-slow", name: "slow_water", arguments: "{}"),
                                                               NativeChatToolCall(id: "t-bad", name: "bad_water", arguments: "{}")]], hook: declining)
        let timedOut = try chatLedgerRows(ledger, turn, "slow_water")
        let refused = try chatLedgerRows(ledger, turn, "bad_water")
        try require(timedOut.count == 1 && timedOut[0].state == .uncertain && timedOut[0].receipt == .object(["reason": .string("timeout")]),
                    "A timeout is left uncertain")
        try require(refused.count == 1 && refused[0].state == .uncertain && refused[0].receipt == .object(["observed": .string("absent")]),
                    "A validation failure is recorded as not having happened")
    }

    private static func runChatLedgerBoundary() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let ledger = NativeEffectLedgerStore(database: repository.database)
        let (_, turn) = try chatLedgerTurn(repository)
        let log = NativeChatLedgerLog()
        let rules = chatLedgerRules([.fileEdits: .act, .otherChanges: .act])
        let grants = NativeFolderGrantSource()
        let hook = chatLedgerHook(ledger, turn: turn, rules: rules, grants: grants, log: log) { _ in NativeCardAnswer(kind: .allowOnce, byPerson: true) }
        let conversationID = turn.conversationID
        let ruled: (NativeToolDefinition) -> NativeToolDefinition = {
            ChatStore.ruled($0, rules: rules, store: nil, conversationID: conversationID, requestText: "Look after the garden")
        }
        let absent: NativeJSONValue = .object(["observed": .string("absent")])

        let failing = ruled(chatLedgerFixture(id: "capability-garden_token", name: "post_token", action: .otherChanges, log: log) {
            .object(["ok": .bool(false), "error": .string("unknown or expired token")])
        })
        let tokenCall = [[NativeChatToolCall(id: "b-token", name: "post_token", arguments: "{}")]]
        let withHook = try await chatLedgerLoop([failing], calls: tokenCall, hook: hook)
        let withoutHook = try await chatLedgerLoop([failing], calls: tokenCall, hook: nil)
        let tokenRows = try chatLedgerRows(ledger, turn, "post_token")
        try require(tokenRows.count == 1 && tokenRows[0].state == .uncertain && tokenRows[0].receipt == .object(["reason": .string("failed_result")]),
                    "A tool that returns a failed result leaves an uncertain row, never completed")
        try require(withHook?.activities.first?.state == .failed && withHook?.activities.first?.state == withoutHook?.activities.first?.state
                    && withHook?.activities.first?.result == withoutHook?.activities.first?.result,
                    "A returned failure reads exactly as it does without the ledger")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-ledger-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = try FolderGrant.make(url: directory)
        let file = URL(fileURLWithPath: grant.path).appendingPathComponent("notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let folder = NativeFolderTools.definitions(grants: { [grant] }, ledger: NativeFileChangeLedger(), edits: .act(.rule), trash: .act(.rule))
        let edited = try await chatLedgerLoop(folder, calls: [[NativeChatToolCall(id: "b-edit", name: "edit_file",
            arguments: "{\"path\":\"\(file.path)\",\"old_text\":\"missing\",\"new_text\":\"found\"}")]], hook: hook)
        let editRows = try chatLedgerRows(ledger, turn, "edit_file")
        try require(edited?.activities.first?.state == .failed && editRows.count == 1 && editRows[0].state == .uncertain
                    && editRows[0].receipt == absent && (try String(contentsOf: file, encoding: .utf8)) == "hello",
                    "An edit whose old text is missing never reached its write and is recorded as not having happened")

        let started = ruled(chatLedgerFixture(id: "capability-garden_flood", name: "flood_bed", action: .otherChanges, log: log) {
            NativeToolCallContext.effectStarts()
            throw NativeToolError.failed("The bed flooded halfway")
        })
        _ = try await chatLedgerLoop([started], calls: [[NativeChatToolCall(id: "b-flood", name: "flood_bed", arguments: "{}")]], hook: hook)
        let floodRows = try chatLedgerRows(ledger, turn, "flood_bed")
        try require(floodRows.count == 1 && floodRows[0].state == .uncertain && floodRows[0].receipt == .object(["reason": .string("no_receipt")]),
                    "A write that started and then failed is left uncertain")

        var checked = chatLedgerFixture(id: "capability-garden_check", name: "check_bed", action: .otherChanges, log: log)
        checked.preflight = { _ in throw NativeToolError.failed("The bed token is missing") }
        _ = try await chatLedgerLoop([ruled(checked)], calls: [[NativeChatToolCall(id: "b-check", name: "check_bed", arguments: "{}")]], hook: hook)
        let checkRows = try chatLedgerRows(ledger, turn, "check_bed")
        try require(checkRows.count == 1 && checkRows[0].state == .uncertain && checkRows[0].receipt == absent && log.count("ran:check_bed") == 0,
                    "A preflight failure in a ruled tool is recorded as not having happened")
    }

    private static func runChatLedgerToolBoundaries() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(Date(timeIntervalSince1970: 1_803_000_000))
        let ledger = NativeEffectLedgerStore(database: repository.database, now: { clock.now })
        let (_, turn) = try chatLedgerTurn(repository)
        let log = NativeChatLedgerLog()
        let rules = chatLedgerRules([.fileEdits: .act, .otherChanges: .act, .reminders: .act, .networkSends: .act])
        let grants = NativeFolderGrantSource()
        let conversationID = turn.conversationID
        let ruled: (NativeToolDefinition) -> NativeToolDefinition = {
            ChatStore.ruled($0, rules: rules, store: nil, conversationID: conversationID, requestText: "Look after the garden")
        }
        let absent: NativeJSONValue = .object(["observed": .string("absent")])
        let unknown: NativeJSONValue = .object(["reason": .string("no_receipt")])
        func row(_ call: String) throws -> NativeEffectRecord? {
            try ledger.records(turnID: turn.id.uuidString).first { $0.decisionID == call || $0.proposal.idempotencyKey ==
                NativeChatEffects.idempotencyKey(turnID: turn.id.uuidString, attempt: turn.attempt?.uuidString ?? "", round: 1, call: call) }
        }
        let utc = TimeZone(identifier: "UTC") ?? .current
        let schedule = ruled(NativeScheduleTools.definition(searchAvailable: { true }, now: { clock.now }, timeZone: { utc }, save: { draft in
            log.add("saved")
            return try NativeSchedule(owner: draft.owner, workerType: draft.workerType, title: draft.title, instruction: draft.instruction,
                                      cadence: draft.cadence, timeZone: utc)
        }))
        let lateCard = chatLedgerHook(ledger, turn: turn, rules: rules, grants: grants, log: log) { _ in
            clock.advance(5 * 86_400)
            return NativeCardAnswer(kind: .allowOnce, byPerson: true)
        }
        let late = try await chatLedgerLoop([schedule], calls: [[NativeChatToolCall(id: "tb-once", name: NativeScheduleTools.toolName,
            arguments: "{\"title\":\"Garden brief\",\"worker_type\":\"document\",\"instruction\":\"Write the garden brief\",\"repeat\":\"once\",\"at\":\"2027-02-22T09:00\"}")]],
            hook: lateCard)
        try require(late?.activities.first?.state == .failed && log.count("saved") == 0 && (try row("tb-once"))?.state == .uncertain
                    && (try row("tb-once"))?.receipt == absent,
                    "A one-time schedule approved after its time passed is recorded as not having happened and nothing is saved")
        let approving = chatLedgerHook(ledger, turn: turn, rules: rules, grants: grants, log: log) { _ in NativeCardAnswer(kind: .allowOnce, byPerson: true) }
        let daily = try await chatLedgerLoop([schedule], calls: [[NativeChatToolCall(id: "tb-daily", name: NativeScheduleTools.toolName,
            arguments: "{\"title\":\"Garden brief\",\"worker_type\":\"document\",\"instruction\":\"Write the garden brief\",\"repeat\":\"daily\",\"time\":\"09:00\"}")]],
            hook: approving)
        try require(daily?.activities.first?.state == .succeeded && log.count("saved") == 1 && (try row("tb-daily"))?.state == .completed,
                    "A schedule that saves is completed")

        let service = SelfTestRemindersService()
        let reminders = NativeRemindersTools.definitions(service: service).map(ruled)
        _ = try await chatLedgerLoop(reminders, calls: [[NativeChatToolCall(id: "tb-remind", name: "apple_reminders_create",
            arguments: "{\"list\":\"Garden\",\"title\":\"Water the beds\"}")]], hook: approving)
        try require(service.createCalls == 0 && (try row("tb-remind"))?.state == .uncertain && (try row("tb-remind"))?.receipt == absent,
                    "A reminder refused before it is created is recorded as not having happened")
        service.shouldFail = true
        _ = try await chatLedgerLoop(reminders, calls: [[NativeChatToolCall(id: "tb-complete", name: "apple_reminders_complete",
            arguments: "{\"id\":\"open\"}")]], hook: approving)
        try require((try row("tb-complete"))?.state == .uncertain && (try row("tb-complete"))?.receipt == unknown,
                    "A reminder change that fails after it was sent is left uncertain")

        let declaration = try NativeCapabilityTools.parse(data: Data("""
            {"name": "post_garden_note", "title": "Post a garden note", "description": "Post a note to the garden log",
             "parameters": {"type": "object", "properties": {"note": {"type": "string"}, "extra_json": {"type": "string"}},
                            "required": ["note"], "additionalProperties": false},
             "json_fields": {"extra_json": "extra"}, "endpoint": "/garden/notes", "method": "POST", "confirmation": "none"}
            """.utf8), source: "garden")
        let sends = NativeChatLedgerLog()
        let client = NativeHTTPToolClient { _, _, _, _ in
            sends.add("sent")
            throw URLError(.networkConnectionLost)
        }
        let capability = ruled(NativeCapabilityTools.definition(declaration, base: { URL(string: "https://tools.example") }, client: client))
        _ = try await chatLedgerLoop([capability], calls: [[NativeChatToolCall(id: "tb-bad-note", name: "post_garden_note",
            arguments: "{\"note\":\"Watered\",\"extra_json\":\"not an object\"}")]], hook: approving)
        try require(sends.count("sent") == 0 && (try row("tb-bad-note"))?.state == .uncertain && (try row("tb-bad-note"))?.receipt == absent,
                    "A tool-file call refused before its request is recorded as not having happened")
        _ = try await chatLedgerLoop([capability], calls: [[NativeChatToolCall(id: "tb-note", name: "post_garden_note",
            arguments: "{\"note\":\"Watered\"}")]], hook: approving)
        try require(sends.count("sent") == 1 && (try row("tb-note"))?.state == .uncertain && (try row("tb-note"))?.receipt == unknown,
                    "A tool-file call whose request was sent and then failed is left uncertain")

        let attachmentDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-ledger-images-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: attachmentDirectory) }
        let attachments = NativeAttachmentStore(directory: attachmentDirectory)
        let requests = NativeChatLedgerLog()
        let transport = ComfyUITransport(request: { _, _, _, _ in
            requests.add("request")
            return (Data("{}".utf8), 500)
        }, events: { _ in nil })
        let broken = NativeImageTools.definitions(base: { URL(string: "http://images.example") }, attachments: attachments, transport: transport,
                                                  graph: { throw NativeToolError.failed("The image workflow could not be read") },
                                                  pollInterval: .milliseconds(10)).map(ruled)
        _ = try await chatLedgerLoop(broken, calls: [[NativeChatToolCall(id: "tb-image-broken", name: NativeImageTools.toolName,
            arguments: "{\"prompt\":\"A tidy vegetable bed\"}")]], hook: approving)
        try require(requests.count("request") == 0 && (try row("tb-image-broken"))?.state == .uncertain
                    && (try row("tb-image-broken"))?.receipt == absent,
                    "An image refused before generation starts is recorded as not having happened")
        let failing = NativeImageTools.definitions(base: { URL(string: "http://images.example") }, attachments: attachments, transport: transport,
                                                   pollInterval: .milliseconds(10)).map(ruled)
        _ = try await chatLedgerLoop(failing, calls: [[NativeChatToolCall(id: "tb-image", name: NativeImageTools.toolName,
            arguments: "{\"prompt\":\"A tidy vegetable bed\"}")]], hook: approving)
        try require(requests.count("request") >= 1 && (try row("tb-image"))?.state == .uncertain && (try row("tb-image"))?.receipt == unknown,
                    "An image whose generation request was sent and then failed is left uncertain")
    }

    private static func runChatLedgerStaleAnswers() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let ledger = NativeEffectLedgerStore(database: repository.database, now: { clock.now })
        let (_, turn) = try chatLedgerTurn(repository)
        let log = NativeChatLedgerLog()
        let rules = chatLedgerRules([.networkSends: .ask])
        let grants = NativeFolderGrantSource()
        let send = ChatStore.ruled(chatLedgerFixture(id: "capability-garden_log", name: "garden_log", action: .networkSends, log: log),
                                   rules: rules, store: nil, conversationID: turn.conversationID, requestText: "")
        let reset: @Sendable () -> Void = {
            var asking = NativeRules.defaults
            asking.set(.ask, for: .networkSends)
            rules.setGlobal(asking)
            rules.setRecords([])
        }
        func card(_ change: @escaping @Sendable () -> Void) -> NativeChatEffectHook {
            chatLedgerHook(ledger, turn: turn, rules: rules, grants: grants, log: log) { _ in
                clock.advance(NativeEffectProposal.lifetime + 120)
                change()
                return NativeCardAnswer(kind: .allowOnce, byPerson: true)
            }
        }
        let unrelated: @Sendable () -> Void = {
            var changed = rules.resolver(for: "", requestText: "").global
            changed.set(changed.choice(for: .reminders) == .act ? .ask : .act, for: .reminders)
            rules.setGlobal(changed)
        }
        let late = try await chatLedgerLoop([send], calls: [[NativeChatToolCall(id: "s-late", name: "garden_log", arguments: "{}")]],
                                            hook: card(unrelated))
        let lateRows = try chatLedgerRows(ledger, turn, "garden_log")
        let lateRan: Bool = late?.activities.first?.state == .succeeded
        let lateOnce: Bool = log.count("ran:garden_log") == 1
        let lateCompleted: Int = lateRows.filter { $0.state == .completed }.count
        let lateProposed: Int = lateRows.filter { $0.state == .proposed }.count
        let lateSettled: Bool = lateRows.count == 2 && lateCompleted == 1 && lateProposed == 1
        try require(lateRan && lateOnce && lateSettled,
                    "Under deciding again, a card approved long after it was shown runs after an unrelated change")
        let handOff: @Sendable () -> Void = {
            var changed = NativeRules.defaults
            changed.set(.handOff, for: .networkSends)
            rules.setGlobal(changed)
        }
        reset()
        let blockedCards = log.count("card:garden_log")
        let blocked = try await chatLedgerLoop([send], calls: [[NativeChatToolCall(id: "s-blocked", name: "garden_log", arguments: "{}")]],
                                               hook: card(handOff))
        try require(blocked?.activities.first?.state == .failed && blocked?.activities.first?.why?.handsOff == true && log.count("ran:garden_log") == 1
                    && log.count("card:garden_log") == blockedCards + 1
                    && !(try chatLedgerRows(ledger, turn, "garden_log")).contains { $0.decisionID == "s-blocked" },
                    "Under deciding again, a card whose action was handed off while it sat open does not run")
        let never: @Sendable () -> Void = {
            var changed = NativeRules.defaults
            changed.set(.ask, for: .networkSends)
            rules.setGlobal(changed)
            rules.setRecords([NativeRuleRecord(action: .networkSends, toolID: "capability-garden_log", effect: .forbid, statement: "Never post")])
        }
        reset()
        let cardsBefore = log.count("card:garden_log")
        let forbidden = try await chatLedgerLoop([send], calls: [[NativeChatToolCall(id: "s-never", name: "garden_log", arguments: "{}")]],
                                                 hook: card(never))
        try require(forbidden?.activities.first?.state == .failed && log.count("ran:garden_log") == 1 && log.count("card:garden_log") == cardsBefore + 1,
                    "Under deciding again, a card whose action became never does not run")
        reset()
        let refusedCards = log.count("card:garden_log")
        var refusing = card(unrelated)
        refusing.staleAnswers = .refuse
        let refusedOld = try await chatLedgerLoop([send], calls: [[NativeChatToolCall(id: "s-refuse", name: "garden_log", arguments: "{}")]],
                                                  hook: refusing)
        try require(refusedOld?.activities.first?.state == .failed && (refusedOld?.activities.first?.result ?? "").contains("rules changed while this answer")
                    && log.count("ran:garden_log") == 1 && log.count("card:garden_log") == refusedCards + 1, "Under refusing, a stale answer is not run and the model is told the rules changed")
        reset()
        let fresh = try await chatLedgerLoop([send], calls: [[NativeChatToolCall(id: "s-fresh", name: "garden_log", arguments: "{}")]],
                                             hook: card({}))
        try require(fresh?.activities.first?.state == .succeeded && log.count("ran:garden_log") == 2,
                    "A card approved long after it was shown with no change still runs")
    }

    static func chatLedgerStore(_ repository: LocalChatRepository, rounds: [[NativeChatStreamSnapshot]], log: NativeChatLedgerLog,
                                gate: NativeEffectBarrier? = nil) async -> ChatStore {
        let send = NativeToolDefinition(id: "capability-garden_log", name: "garden_log", title: "Post to the garden log",
            description: "Post a line to the garden log",
            parameters: .object(["type": .string("object"), "properties": .object(["line": .object(["type": .string("string")])]),
                                 "required": .array([.string("line")])]),
            confirmation: .none, action: .networkSends, isAvailable: { true },
            execute: { _ in
                log.add("ran")
                if let gate { await gate.wait() }
                return .object(["posted": .bool(true)])
            }, fixedDestination: true)
        let store = ChatStore(nativeConfig: chatLedgerConfig, nativeTransport: ScriptedNativeToolTransport(rounds: rounds), repository: repository,
                              nativeEnabledToolIDs: [send.id], nativeRules: .defaults, nativeToolRegistry: NativeToolRegistry(definitions: [send]),
                              artifactPersistenceEnabled: false)
        await store.connect()
        store.newConversation()
        return store
    }

    static func chatLedgerCard(_ store: ChatStore) async throws -> (UUID, NativeToolConfirmationRequest) {
        var waited = 0
        while store.turnConfirmations.isEmpty && waited < 500 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        guard let found = store.turnConfirmations.first else { throw NativeTaskFixture.Failure.assertion("The posting tool shows a card") }
        return (found.key, found.value)
    }

    static func chatLedgerSettle(_ store: ChatStore) async throws {
        var waited = 0
        try await Task.sleep(nanoseconds: 20_000_000)
        while store.generating && waited < 500 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
    }

    private static func runChatLedgerStore() async throws {
        let require = NativeTaskFixture.require
        let call: (String) -> NativeChatStreamSnapshot = {
            NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: $0, name: "garden_log", arguments: "{\"line\":\"Watered the beans\"}")],
                                     finishReason: "tool_calls")
        }
        let done = NativeChatStreamSnapshot(content: "Posted.", toolCalls: [], finishReason: "stop")

        let repository = try LocalChatRepository(inMemory: true)
        let ledger = NativeEffectLedgerStore(database: repository.database)
        let log = NativeChatLedgerLog()
        let approving = await chatLedgerStore(repository, rounds: [[call("st-approve")], [done]], log: log)
        approving.sendText("Post the note to the garden log", fromComposer: true)
        let (messageID, request) = try await chatLedgerCard(approving)
        guard let turn = approving.conversationTurns.first(where: { $0.assistantMessageID == messageID }) else {
            throw NativeTaskFixture.Failure.assertion("The card belongs to a turn")
        }
        let shown = try chatLedgerRows(ledger, turn, "garden_log")
        try require(shown.count == 1 && shown[0].state == .proposed && request.digest == shown[0].digest,
                    "The card carries the proposal's digest while the row waits")
        approving.resolveTurnConfirmation(messageID, decision: .allowOnce, requestID: request.id, token: approving.turnConfirmationTokens[messageID])
        try await chatLedgerSettle(approving)
        let ran = try chatLedgerRows(ledger, turn, "garden_log")
        try require(log.count("ran") == 1 && ran.count == 1 && ran[0].state == .completed && ran[0].decisionID == "st-approve"
                    && approving.selected?.messages.last?.toolActivities.first?.state == .succeeded,
                    "Approving from the composer admits the row, runs once and completes")

        let declineRepository = try LocalChatRepository(inMemory: true)
        let declineLedger = NativeEffectLedgerStore(database: declineRepository.database)
        let declineLog = NativeChatLedgerLog()
        let declining = await chatLedgerStore(declineRepository, rounds: [[call("st-decline")], [call("st-decline-again")], [done]], log: declineLog)
        declining.sendText("Post the note to the garden log", fromComposer: true)
        let (declineMessage, declineRequest) = try await chatLedgerCard(declining)
        guard let declineTurn = declining.conversationTurns.first(where: { $0.assistantMessageID == declineMessage }) else {
            throw NativeTaskFixture.Failure.assertion("The declined card belongs to a turn")
        }
        declining.resolveTurnConfirmation(declineMessage, decision: .decline, requestID: declineRequest.id,
                                          token: declining.turnConfirmationTokens[declineMessage])
        try await chatLedgerSettle(declining)
        let declinedRows = try chatLedgerRows(declineLedger, declineTurn, "garden_log")
        let activities = declining.selected?.messages.last?.toolActivities ?? []
        try require(declineLog.count("ran") == 0 && declinedRows.count == 2 && declinedRows.allSatisfy { $0.state == .declined }
                    && activities.count == 2 && activities.allSatisfy { ($0.result ?? "").contains("The user did not approve this call") },
                    "A declined card and its identical repeat are both declined with no second card and nothing runs")

        let stopRepository = try LocalChatRepository(inMemory: true)
        let stopLedger = NativeEffectLedgerStore(database: stopRepository.database)
        let stopLog = NativeChatLedgerLog()
        let stopping = await chatLedgerStore(stopRepository, rounds: [[call("st-stop")], [done]], log: stopLog)
        stopping.sendText("Post the note to the garden log", fromComposer: true)
        let (stopMessage, _) = try await chatLedgerCard(stopping)
        guard let stopTurn = stopping.conversationTurns.first(where: { $0.assistantMessageID == stopMessage }) else {
            throw NativeTaskFixture.Failure.assertion("The stopped card belongs to a turn")
        }
        stopping.stopAnswer(stopMessage)
        try await chatLedgerSettle(stopping)
        let stoppedReply = stopping.selected?.messages.first { $0.id == stopMessage }
        let stoppedRows = try chatLedgerRows(stopLedger, stopTurn, "garden_log")
        try require(stopLog.count("ran") == 0 && stoppedReply?.failure == "Stopped." && stoppedReply?.state == .interrupted
                    && stopping.turnConfirmations.isEmpty && stoppedRows.count == 1 && stoppedRows[0].state == .proposed,
                    "Stopping with a card open reads as before and leaves the row proposed, not declined: \(stoppedRows.map(\.state))")
        approving.conversationTurnLoop?.cancel()
        declining.conversationTurnLoop?.cancel()
        stopping.conversationTurnLoop?.cancel()
    }

    static func chatLedgerKill(_ repository: LocalChatRepository, turnID: UUID) throws {
        try repository.database.write { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT record_json FROM native_conversation_turns WHERE id = ?", arguments: [turnID.uuidString]) else {
                return
            }
            var turn = try JSONDecoder().decode(NativeConversationTurn.self, from: Data(raw.utf8))
            turn.ownerBirth = "a process that is gone"
            try LocalChatRepository.writeTurn(turn, db: db)
        }
    }

    private static func runChatLedgerRelaunch() async throws {
        let require = NativeTaskFixture.require
        let call = NativeChatStreamSnapshot(content: "", toolCalls: [
            NativeChatToolCall(id: "rl-call", name: "garden_log", arguments: "{\"line\":\"Watered the beans\"}")], finishReason: "tool_calls")
        let done = NativeChatStreamSnapshot(content: "Posted.", toolCalls: [], finishReason: "stop")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-ledger-relaunch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vera.sqlite")
        let repository = try LocalChatRepository(url: url)
        let log = NativeChatLedgerLog()
        let gate = NativeEffectBarrier()
        let running = await chatLedgerStore(repository, rounds: [[call], [done]], log: log, gate: gate)
        running.sendText("Post the note to the garden log", fromComposer: true)
        let (messageID, request) = try await chatLedgerCard(running)
        guard let turn = running.conversationTurns.first(where: { $0.assistantMessageID == messageID }) else {
            throw NativeTaskFixture.Failure.assertion("The relaunch card belongs to a turn")
        }
        running.resolveTurnConfirmation(messageID, decision: .allowOnce, requestID: request.id, token: running.turnConfirmationTokens[messageID])
        var waited = 0
        while log.count("ran") == 0 && waited < 500 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        let ledger = NativeEffectLedgerStore(database: repository.database)
        try require(log.count("ran") == 1 && (try chatLedgerRows(ledger, turn, "garden_log")).first?.state == .admitted,
                    "The row is admitted while the tool runs")
        running.suspendsTurnScheduling = true
        try chatLedgerKill(repository, turnID: turn.id)
        let relaunched = try LocalChatRepository(url: url)
        let relaunchedLedger = NativeEffectLedgerStore(database: relaunched.database)
        let recovered = try chatLedgerRows(relaunchedLedger, turn, "garden_log")
        let reply = try relaunched.messages(conversationID: turn.conversationID).first { $0.id == messageID }
        try require(recovered.count == 1 && recovered[0].state == .uncertain && recovered[0].receipt == .object(["reason": .string("interrupted")]),
                    "A relaunch marks the admitted row that never settled uncertain")
        try require(reply?.failure == "Tandem closed before this answer finished. An action already sent may have completed; check it before trying again.",
                    "The interrupted turn says the action may have completed")
        var retried = false
        do { try relaunched.retryTurn(turn.id, profile: turn.profile); retried = true } catch {}
        try require(!retried, "An interrupted turn with an unsettled admitted row cannot be retried")
        gate.open()
        running.conversationTurnLoop?.cancel()

        let beforeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-ledger-before-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: beforeDirectory) }
        let beforeURL = beforeDirectory.appendingPathComponent("vera.sqlite")
        let beforeRepository = try LocalChatRepository(url: beforeURL)
        let beforeLog = NativeChatLedgerLog()
        let waiting = await chatLedgerStore(beforeRepository, rounds: [[call], [done]], log: beforeLog)
        waiting.sendText("Post the note to the garden log", fromComposer: true)
        let (beforeMessage, _) = try await chatLedgerCard(waiting)
        guard let beforeTurn = waiting.conversationTurns.first(where: { $0.assistantMessageID == beforeMessage }) else {
            throw NativeTaskFixture.Failure.assertion("The second relaunch card belongs to a turn")
        }
        waiting.suspendsTurnScheduling = true
        try chatLedgerKill(beforeRepository, turnID: beforeTurn.id)
        let reopened = try LocalChatRepository(url: beforeURL)
        let reopenedRows = try chatLedgerRows(NativeEffectLedgerStore(database: reopened.database), beforeTurn, "garden_log")
        let beforeReply = try reopened.messages(conversationID: beforeTurn.conversationID).first { $0.id == beforeMessage }
        try require(reopenedRows.allSatisfy { $0.state == .proposed } && beforeLog.count("ran") == 0
                    && beforeReply?.failure == "Tandem closed before this answer finished. You can retry it.",
                    "A kill before admission leaves nothing admitted and the turn retryable")
        try reopened.retryTurn(beforeTurn.id, profile: beforeTurn.profile)
        waiting.conversationTurnLoop?.cancel()
    }
}
