import Foundation

final class NativeEffectTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

final class NativeEffectBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

@MainActor
extension SelfTest {
    static func runNativeEffectLedger() async throws {
        try await runNativeEffectLedgerStore()
        try await runNativeEffectLedgerBarrier()
        try runNativeEffectLedgerFence()
        try runNativeToolEffects()
        try runNativeRuleRevisions()
        print("  effect ledger OK (canonical arguments, digest, admission refusals, ask binding, claim fence, observations, settle, recovery, expiry, barrier, tool effects, revisions)")
    }

    static func seedRunningTask(_ repository: LocalChatRepository, id: String = "task-1", generation: Int = 1) throws {
        try repository.database.write { db in
            try db.execute(sql: """
                INSERT INTO native_engine_tasks(id, worker_type, payload, creation_key, state, generation, created_at, updated_at)
                VALUES(?, 'dot', '{}', ?, 'running', ?, 0, 0)
                ON CONFLICT(id) DO UPDATE SET state = 'running', generation = excluded.generation, cancel_requested = 0
                """, arguments: [id, "seed-" + id, generation])
        }
    }

    private static func effectProposal(_ clock: NativeEffectTestClock, task: String = "task-1", generation: Int = 1,
                                       arguments: NativeJSONValue = .object(["path": .string("notes/plan.txt"), "content": .string("Water the beds")]),
                                       rules: Int = 0, grants: Int = 0, key: String = "call-1") -> NativeEffectProposal {
        NativeEffectProposal(id: UUID().uuidString.lowercased(), taskID: task, generation: generation, toolID: NativeFolderTools.toolID,
                             function: "write_file", argumentsJSON: NativeEffectProposal.canonicalArguments(arguments),
                             target: "notes/plan.txt", action: .fileEdits, rulesRevision: rules, grantsRevision: grants,
                             conversationID: "conversation-1", expiresAtMilliseconds: NativeEffectProposal.expiry(from: clock.now),
                             idempotencyKey: key)
    }

    private static func runNativeEffectLedgerStore() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let ledger = NativeEffectLedgerStore(database: repository.database, now: { clock.now })
        try seedRunningTask(repository)

        let nested: NativeJSONValue = .object(["b": .array([.number(1), .bool(true), .null]), "a": .string("x / y"), "c": .object(["z": .number(2.5), "y": .string("")])])
        let canonical = NativeEffectProposal.canonicalArguments(nested)
        try require(canonical == "{\"a\":\"x / y\",\"b\":[1,true,null],\"c\":{\"y\":\"\",\"z\":2.5}}", "Canonical arguments sort keys and drop insignificant whitespace")
        let reparsed = try NativeJSONValue(any: try JSONSerialization.jsonObject(with: Data(canonical.utf8)))
        try require(reparsed == nested, "The canonical form drops nothing but whitespace")

        let proposal = effectProposal(clock)
        let first = try ledger.propose(proposal)
        try require(first.state == .proposed && first.digest == proposal.digest, "A proposal is stored as proposed under its digest")
        let again = try ledger.propose(NativeEffectProposal(id: "another-id", taskID: proposal.taskID, generation: proposal.generation, toolID: proposal.toolID,
                                                            function: proposal.function, argumentsJSON: proposal.argumentsJSON, target: proposal.target,
                                                            action: proposal.action, rulesRevision: proposal.rulesRevision, grantsRevision: proposal.grantsRevision,
                                                            conversationID: proposal.conversationID, expiresAtMilliseconds: proposal.expiresAtMilliseconds,
                                                            idempotencyKey: proposal.idempotencyKey))
        try require(again == first && (try ledger.records(taskID: "task-1")).count == 1, "Proposing the same digest returns the existing row unchanged")
        let changed = effectProposal(clock, arguments: .object(["path": .string("notes/plan.txt"), "content": .string("Water the beds twice")]))
        try require(changed.digest != proposal.digest, "A changed argument gives a different digest")
        try require(effectProposal(clock, generation: 2).digest != proposal.digest && effectProposal(clock, rules: 1).digest != proposal.digest
                    && effectProposal(clock, grants: 1).digest != proposal.digest && effectProposal(clock, key: "call-2").digest != proposal.digest,
                    "Generation, revisions and the idempotency key are all part of the digest, so any change needs a new decision")

        guard case .refused(.staleRules) = try ledger.admit(digest: proposal.digest, generation: 1, rulesRevision: 1, grantsRevision: 0,
                                                            decision: .act(.rule), decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("A moved rules revision refuses admission")
        }
        guard case .refused(.staleGrants) = try ledger.admit(digest: proposal.digest, generation: 1, rulesRevision: 0, grantsRevision: 3,
                                                             decision: .act(.rule), decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("A moved grants revision refuses admission")
        }
        guard case .refused(.staleGeneration) = try ledger.admit(digest: proposal.digest, generation: 2, rulesRevision: 0, grantsRevision: 0,
                                                                 decision: .act(.rule), decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("A generation bump refuses admission")
        }
        guard case .refused(.notFound) = try ledger.admit(digest: "missing", generation: 1, rulesRevision: 0, grantsRevision: 0,
                                                          decision: .act(.rule), decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("An unknown digest is refused")
        }
        guard case .admitted(let admitted) = try ledger.admit(digest: proposal.digest, generation: 1, rulesRevision: 0, grantsRevision: 0,
                                                              decision: .act(.rule), decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("Matching revisions and generation under an act decision admit")
        }
        try require(admitted.state == .admitted, "The admitted row reads admitted")
        guard case .refused(.alreadySettled) = try ledger.admit(digest: proposal.digest, generation: 1, rulesRevision: 0, grantsRevision: 0,
                                                                decision: .act(.rule), decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("A second admission of the same digest is refused")
        }

        let asking = try ledger.propose(effectProposal(clock, key: "call-ask"))
        guard case .refused(.ruleAsks) = try ledger.admit(digest: asking.digest, generation: 1, rulesRevision: 0, grantsRevision: 0,
                                                          decision: .ask, decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("An ask decision without a reply refuses")
        }
        guard case .refused(.ruleAsks) = try ledger.admit(digest: asking.digest, generation: 1, rulesRevision: 0, grantsRevision: 0,
                                                          decision: .ask, decisionID: "decision-1", reply: .object(["digest": .string(proposal.digest), "approved": .bool(true)])) else {
            throw NativeTaskFixture.Failure.assertion("An ask decision with a reply bound to another digest refuses")
        }
        let reply: NativeJSONValue = .object(["digest": .string(asking.digest), "approved": .bool(true)])
        guard case .admitted(let approved) = try ledger.admit(digest: asking.digest, generation: 1, rulesRevision: 0, grantsRevision: 0,
                                                              decision: .ask, decisionID: "decision-1", reply: reply) else {
            throw NativeTaskFixture.Failure.assertion("An ask decision with a reply bound to this digest admits")
        }
        try require(approved.decisionID == "decision-1" && approved.decisionReply == reply, "The admitted row keeps the decision and its reply")

        let handed = try ledger.propose(effectProposal(clock, key: "call-hand-off"))
        guard case .refused(.ruleHandsOff) = try ledger.admit(digest: handed.digest, generation: 1, rulesRevision: 0, grantsRevision: 0,
                                                              decision: .handOff, decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("A hand-off decision refuses")
        }
        try ledger.decline(digest: handed.digest, decisionID: "decision-2", reply: .object(["digest": .string(handed.digest), "approved": .bool(false)]))
        guard case .refused(.declined) = try ledger.admit(digest: handed.digest, generation: 1, rulesRevision: 0, grantsRevision: 0,
                                                          decision: .act(.rule), decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("A declined proposal cannot be admitted")
        }

        let receipt: NativeJSONValue = .object(["bytes": .number(14), "path": .string("notes/plan.txt")])
        let claim: NativeJSONValue = .object(["summary": .string("Saved the plan")])
        try ledger.settle(digest: proposal.digest, receipt: receipt, modelClaim: claim)
        let settled = try ledger.record(digest: proposal.digest)
        try require(settled?.state == .completed && settled?.receipt == receipt && settled?.modelClaim == claim,
                    "Settling records the receipt and the model's claim separately")
        let pending = try ledger.propose(effectProposal(clock, key: "call-pending"))
        var settleRefused = false
        do { try ledger.settle(digest: pending.digest, receipt: receipt, modelClaim: nil) } catch { settleRefused = true }
        try require(settleRefused, "Settling a proposed row throws")

        let interrupted = try ledger.propose(effectProposal(clock, key: "call-interrupted"))
        guard case .admitted = try ledger.admit(digest: interrupted.digest, generation: 1, rulesRevision: 0, grantsRevision: 0,
                                                decision: .act(.rule), decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("The interrupted fixture admits")
        }
        let recovered = try ledger.recoverAtBringUp()
        try require(Set(recovered.map(\.digest)) == [interrupted.digest, asking.digest] && recovered.allSatisfy { $0.state == .uncertain }
                    && recovered.allSatisfy { $0.receipt == .object(["reason": .string("interrupted")]) },
                    "Bring-up turns every admitted row into uncertain with the reason")
        try require(try ledger.record(digest: proposal.digest)?.state == .completed && (try ledger.record(digest: pending.digest))?.state == .proposed,
                    "Bring-up leaves completed and proposed rows alone")
        try require(try ledger.recoverAtBringUp().isEmpty, "A second bring-up finds nothing admitted")

        let expiring = try ledger.propose(effectProposal(clock, key: "call-expiring"))
        let lingering = try ledger.propose(effectProposal(clock, key: "call-lingering"))
        clock.advance(NativeEffectProposal.lifetime - 1)
        guard case .admitted = try ledger.admit(digest: lingering.digest, generation: 1, rulesRevision: 0, grantsRevision: 0,
                                                decision: .act(.rule), decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("A proposal still inside ten minutes admits")
        }
        clock.advance(2)
        guard case .refused(.expired) = try ledger.admit(digest: expiring.digest, generation: 1, rulesRevision: 0, grantsRevision: 0,
                                                         decision: .act(.rule), decisionID: nil, reply: nil) else {
            throw NativeTaskFixture.Failure.assertion("A proposal past ten minutes refuses as expired")
        }
        try require(try ledger.record(digest: expiring.digest)?.state == .expired, "The expired proposal reads expired")
        try require(try ledger.expireStale() == 1 && (try ledger.record(digest: pending.digest))?.state == .expired,
                    "Sweeping expires the remaining stale proposal")
        try require(try ledger.record(digest: lingering.digest)?.state == .admitted, "Sweeping never touches an admitted row")
        try ledger.markUncertain(digest: lingering.digest, reason: "no receipt")
        try require(try ledger.record(digest: lingering.digest)?.receipt == .object(["reason": .string("no receipt")]), "An uncertain row keeps its reason in the receipt")
    }

    private static func runNativeEffectLedgerBarrier() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let ledger = NativeEffectLedgerStore(database: repository.database, now: { clock.now })
        try seedRunningTask(repository)
        let rules = NativeRuleSource()
        let grants = NativeFolderGrantSource()
        let relaxed = NativeRules(choices: [.fileEdits: .act, .commands: .act, .trash: .ask, .networkSends: .handOff])

        let early = try ledger.propose(effectProposal(clock, rules: rules.revision, grants: grants.revision, key: "barrier-bump-first"))
        let bumpFirst = NativeEffectBarrier()
        let admitting = Task.detached { () throws -> NativeEffectAdmission in
            await bumpFirst.wait()
            return try ledger.admit(digest: early.digest, generation: 1, rulesRevision: rules.revision, grantsRevision: grants.revision,
                                    decision: .act(.rule), decisionID: nil, reply: nil)
        }
        let bumping = Task.detached {
            rules.setGlobal(relaxed)
            bumpFirst.open()
        }
        await bumping.value
        try require(try await admitting.value == .refused(.staleRules), "A rules change that lands before admission refuses it")
        try require(try ledger.record(digest: early.digest)?.state == .proposed, "The refused proposal stays unadmitted")

        let late = try ledger.propose(effectProposal(clock, rules: rules.revision, grants: grants.revision, key: "barrier-admit-first"))
        let admitFirst = NativeEffectBarrier()
        let admittingFirst = Task.detached { () throws -> NativeEffectAdmission in
            defer { admitFirst.open() }
            return try ledger.admit(digest: late.digest, generation: 1, rulesRevision: rules.revision, grantsRevision: grants.revision,
                                    decision: .act(.rule), decisionID: nil, reply: nil)
        }
        let bumpingLater = Task.detached {
            await admitFirst.wait()
            rules.setGlobal(.defaults)
        }
        let outcome = try await admittingFirst.value
        await bumpingLater.value
        guard case .admitted(let admitted) = outcome else {
            throw NativeTaskFixture.Failure.assertion("Admission that lands before the rules change succeeds")
        }
        let after = try ledger.record(digest: late.digest)
        try require(after == admitted && after?.proposal.rulesRevision == late.proposal.rulesRevision && rules.revision == late.proposal.rulesRevision + 1,
                    "A later rules change cannot change the admitted row")
        try require(try ledger.admit(digest: late.digest, generation: 1, rulesRevision: rules.revision, grantsRevision: grants.revision,
                                     decision: .act(.rule), decisionID: nil, reply: nil) == .refused(.alreadySettled),
                    "Re-admitting under the new revision is refused as already settled")
    }

    private static func runNativeEffectLedgerFence() throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let clock = NativeEffectTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let ledger = NativeEffectLedgerStore(database: repository.database, now: { clock.now })
        try seedRunningTask(repository, generation: 3)

        let acting = try ledger.propose(effectProposal(clock, generation: 3, key: "fence-act"))
        try seedRunningTask(repository, generation: 4)
        try require(try ledger.admit(digest: acting.digest, generation: 4, rulesRevision: 0, grantsRevision: 0,
                                     decision: .act(.rule), decisionID: nil, reply: nil) == .refused(.staleGeneration),
                    "An act write proposed in an earlier claim is refused in a later one")
        try require(try ledger.admit(digest: acting.digest, generation: 3, rulesRevision: 0, grantsRevision: 0,
                                     decision: .act(.rule), decisionID: nil, reply: nil) == .refused(.staleGeneration),
                    "A caller holding an old claim is refused even when the proposal matches it")

        let asking = try ledger.propose(effectProposal(clock, generation: 3, key: "fence-ask"))
        let reply: NativeJSONValue = .object(["action": .string("approve"), "digest": .string(asking.digest)])
        guard case .admitted = try ledger.admit(digest: asking.digest, generation: 4, rulesRevision: 0, grantsRevision: 0,
                                                decision: .ask, decisionID: "decision-1", reply: reply) else {
            throw NativeTaskFixture.Failure.assertion("An approved ask write resumes in the claim that follows the decision")
        }
        let future = try ledger.propose(effectProposal(clock, generation: 9, key: "fence-future"))
        try require(try ledger.admit(digest: future.digest, generation: 4, rulesRevision: 0, grantsRevision: 0, decision: .ask, decisionID: "decision-2",
                                     reply: .object(["digest": .string(future.digest)])) == .refused(.staleGeneration),
                    "A proposal from a later claim than the caller's is refused")

        let canceling = try ledger.propose(effectProposal(clock, generation: 4, key: "fence-cancel"))
        try repository.database.write { db in try db.execute(sql: "UPDATE native_engine_tasks SET cancel_requested = 1 WHERE id = 'task-1'") }
        try require(try ledger.admit(digest: canceling.digest, generation: 4, rulesRevision: 0, grantsRevision: 0,
                                     decision: .act(.rule), decisionID: nil, reply: nil) == .refused(.taskInactive),
                    "A cancel request recorded before admission wins")
        try repository.database.write { db in try db.execute(sql: "UPDATE native_engine_tasks SET cancel_requested = 0, state = 'needs_decision' WHERE id = 'task-1'") }
        try require(try ledger.admit(digest: canceling.digest, generation: 4, rulesRevision: 0, grantsRevision: 0,
                                     decision: .act(.rule), decisionID: nil, reply: nil) == .refused(.taskInactive),
                    "A task that is not running cannot admit")
        try require(try ledger.admit(digest: canceling.digest, generation: 4, rulesRevision: 0, grantsRevision: 0, decision: .act(.rule),
                                     decisionID: nil, reply: nil) == .refused(.taskInactive) && (try ledger.record(digest: canceling.digest))?.state == .proposed,
                    "A refused admission leaves the proposal untouched")
        try seedRunningTask(repository, generation: 5)

        try require(try ledger.abandonAdmitted(taskID: "task-1") == 1 && (try ledger.record(digest: asking.digest))?.state == .uncertain,
                    "An admission left by an earlier step becomes uncertain at the next step")
        try ledger.observe(digest: asking.digest, .unknown)
        try require(try ledger.record(digest: asking.digest)?.state == .uncertain, "An unknown observation changes nothing")
        try ledger.observe(digest: asking.digest, .absent)
        let absent = try ledger.record(digest: asking.digest)
        try require(absent?.state == .uncertain && absent?.receipt == .object(["observed": .string("absent")]),
                    "An absent observation is recorded and the row stays uncertain")
        try ledger.observe(digest: asking.digest, .applied(.object(["id": .string("note-7")])))
        let applied = try ledger.record(digest: asking.digest)
        try require(applied?.state == .completed
                    && applied?.receipt == .object(["observed": .string("applied"), "receipt": .object(["id": .string("note-7")])]),
                    "An applied observation completes the row with the destination receipt")
        var observeRefused = false
        do { try ledger.observe(digest: canceling.digest, .absent) } catch { observeRefused = true }
        try require(observeRefused, "Only an uncertain row accepts an observation")

        try require(try ledger.record(taskID: "task-1", idempotencyKey: "fence-ask")?.digest == asking.digest
                    && (try ledger.record(taskID: "task-1", idempotencyKey: "missing")) == nil
                    && (try ledger.record(taskID: "task-2", idempotencyKey: "fence-ask")) == nil,
                    "A row is found by task and idempotency key, scoped to its task")
    }

    private static func runNativeToolEffects() throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let sample = [FolderGrant(id: "g", path: "/Volumes/Notes/Greenhouse", name: "Greenhouse", bookmark: nil)]
        let reading = try NativeCapabilityTools.parse(object: [
            "name": "garden_status", "title": "Garden status", "description": "Read the garden status",
            "parameters": ["type": "object", "properties": [String: Any]()], "endpoint": "https://example.com/status", "method": "GET", "confirmation": "none",
        ], source: "garden_status.json")
        let sending = try NativeCapabilityTools.parse(object: [
            "name": "garden_note", "title": "Garden note", "description": "Post a garden note",
            "parameters": ["type": "object", "properties": ["text": ["type": "string"]]], "endpoint": "https://example.com/note", "method": "POST", "confirmation": "required",
        ], source: "garden_note.json")
        try require(reading.method == .get && sending.method == .post, "The capability fixtures parse with their methods")
        let service = NativeTaskHandoffService(repository: repository, configuredBase: { nil })
        let origin = NativeTaskOrigin(conversationID: "conversation-1", userMessageID: UUID(), assistantMessageID: UUID())
        let commands = NativeCommandTools.definitions(grants: { sample }, decision: .ask, reason: { _ in nil }, record: { _ in })
        let definitions = ChatStore.buildToolRegistry([reading, sending]).definitions
            + NativeFolderTools.definitions(grants: { sample }, ledger: NativeFileChangeLedger())
            + commands
            + [NativeTaskTools.definition(service: service, origin: origin, profile: nil, didSave: { _ in })]
            + [NativeScheduleTools.definition(assistantName: { "Ada" }, save: { _ in throw NativeToolError.unavailable })]
        for definition in definitions {
            try require(definition.isDeclared, "\(definition.name) is either a read or a write with an action")
        }
        let effects = Dictionary(definitions.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for name in ["apple_reminders_get_lists", "apple_reminders_list", NativeWebTools.searchToolName, NativeWebTools.fetchToolName,
                     NativeFolderTools.listName, NativeFolderTools.readName, NativeFolderTools.searchName, "garden_status"] {
            try require(effects[name]?.effect == .read, "\(name) is declared a read")
        }
        for (name, action) in [("apple_reminders_create", NativeActionClass.networkSends), ("apple_reminders_complete", .networkSends),
                               (NativeFolderTools.writeName, .fileEdits), (NativeFolderTools.editName, .fileEdits), (NativeFolderTools.moveName, .fileEdits),
                               (NativeFolderTools.mkdirName, .fileEdits), (NativeFolderTools.trashName, .trash), (NativeCommandTools.runName, .commands),
                               (NativeImageTools.toolName, .fileEdits), (NativeScheduleTools.toolName, .networkSends), ("garden_note", .networkSends)] {
            try require(effects[name]?.effect == .write && effects[name]?.action == action, "\(name) is a write under \(action.rawValue)")
        }
        let run = commands[0]
        try require(run.actionClass(for: ["command": .string("swift build")]) == .commands
                    && run.actionClass(for: ["command": .string("npm publish")]) == .networkSends
                    && run.actionClass(for: ["command": .string("rm -rf ../Other")]) == .sensitive,
                    "A command's planned classification can raise its action per call")
        try require(effects[NativeWebTools.searchToolName]?.actionClass(for: [:]) == nil, "A read carries no action class")

        var replayable = 0
        for definition in definitions {
            let activity = NativeToolActivity(id: "a", toolID: definition.id, name: definition.name, title: definition.title, round: 0,
                                              request: "{}", result: nil, state: .succeeded, confirmationRequired: false)
            guard NativeTurnSafety.canReplay(activity) else { continue }
            replayable += 1
            try require(definition.effect == .read, "Replayable \(definition.name) is declared a read")
        }
        try require(replayable == 4, "Every replayable tool with a definition was checked")
        let reads = NativeToolDefinition.readOnly(definitions)
        try require(!reads.isEmpty && reads.allSatisfy { $0.effect == .read } && reads.count == definitions.filter { $0.effect == .read }.count,
                    "readOnly keeps every read and drops every write")
        let undeclared = NativeToolDefinition(id: "fixture", name: "fixture", title: "Fixture", description: "Fixture",
                                              parameters: .object(["type": .string("object")]), confirmation: .none,
                                              isAvailable: { true }, execute: { _ in .null })
        try require(undeclared.effect == .write && NativeToolDefinition.readOnly([undeclared]).isEmpty, "An undeclared tool never passes as a read")
    }

    private static func runNativeRuleRevisions() throws {
        let require = NativeTaskFixture.require
        let rules = NativeRuleSource()
        try require(rules.revision == 0, "A fresh rule source starts at revision zero")
        rules.setGlobal(NativeRules(choices: [.fileEdits: .ask]))
        try require(rules.revision == 1, "setGlobal bumps the rules revision once")
        rules.setGlobal(NativeRules(choices: [.fileEdits: .ask]))
        try require(rules.revision == 1, "Setting the same global rules is not a change")
        let resolver = rules.resolver(for: "conversation-1", requestText: "")
        rules.set(NativeConversationRules(choices: [.commands: .handOff]), for: "conversation-1")
        try require(rules.revision == 2 && resolver.revision == 1 && rules.resolver(for: "conversation-1", requestText: "").revision == 2,
                    "set bumps the rules revision once and a resolver keeps the revision it was created with")
        rules.set(NativeConversationRules(choices: [.commands: .handOff], approvedCommandPrefixes: ["swift build"]), for: "conversation-1")
        try require(rules.revision == 3, "A prefix change through the source bumps the rules revision")
        rules.replaceAll([("conversation-2", NativeConversationRules(choices: [.trash: .handOff]))])
        try require(rules.revision == 4, "replaceAll bumps the rules revision once")

        let grants = NativeFolderGrantSource()
        let grant = FolderGrant(id: "g", path: "/Volumes/Notes/Greenhouse", name: "Greenhouse", bookmark: nil)
        grants.set([grant], for: "conversation-1")
        try require(grants.revision == 1, "Granting a folder bumps the grants revision")
        grants.set([grant], for: "conversation-1")
        try require(grants.revision == 1, "Setting the same grants is not a change")
        grants.set([], for: "conversation-1")
        try require(grants.revision == 2, "Revoking a folder bumps the grants revision")
        grants.replaceAll([Conversation(id: "conversation-3", title: "Seeds", messages: [], updatedAt: Date(), grants: [grant])])
        try require(grants.revision == 3, "replaceAll bumps the grants revision once")
    }
}
