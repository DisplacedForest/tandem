import Foundation
import GRDB

final class NativeTurnCurrencyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

struct NativeTurnCurrencyHold: Sendable {
    static let ceilingSeconds = 120
    let gate: DispatchSemaphore
    let task: Task<Void, Error>

    func release() async throws {
        gate.signal()
        try await task.value
    }
}

@MainActor
final class NativeTurnCurrencyProbe {
    static let stallLimit: Duration = .milliseconds(200)
    static let waitFloor: Duration = .milliseconds(200)
    static let retryLimit: Duration = .seconds(1)
    static let tickLimit: Duration = .milliseconds(1_500)
    private(set) var started = false
    private(set) var finished = false
    private var startedAt: ContinuousClock.Instant?

    var responsive: Bool {
        guard let startedAt else { return false }
        return !finished && startedAt.duration(to: .now) < Self.stallLimit
    }

    static func prompt(_ body: () -> Void) -> Bool {
        let start = ContinuousClock.now
        body()
        return start.duration(to: .now) < stallLimit
    }

    func run<Value: Sendable>(_ work: @escaping @MainActor () async -> Value) -> Task<Value, Never> {
        Task { @MainActor in
            self.startedAt = .now
            self.started = true
            let value = await work()
            self.finished = true
            return value
        }
    }

    func untilStarted() async throws {
        for _ in 0..<100_000 where !started { await Task.yield() }
        guard started else { throw NativeTaskFixture.Failure.assertion("The probed call never started") }
    }
}

final class NativeSteppedTransport: NativeChatTransport, @unchecked Sendable {
    let first = NativeSessionGate()
    let second = NativeSessionGate()
    private let lock = NSLock()
    private var stage = 0
    var reached: Int { lock.withLock { stage } }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(NativeChatStreamSnapshot(content: "Part one.", toolCalls: [], finishReason: nil))
                self.advance(to: 1)
                await self.first.wait()
                continuation.yield(NativeChatStreamSnapshot(content: "Part one. Part two.", toolCalls: [], finishReason: nil))
                self.advance(to: 2)
                await self.second.wait()
                continuation.yield(NativeChatStreamSnapshot(content: "Part one. Part two. Part three.", toolCalls: [], finishReason: "stop"))
                self.advance(to: 3)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func advance(to value: Int) { lock.withLock { stage = value } }
}

@MainActor
enum NativeTurnCurrencyFixture {
    static func run() async throws {
        try await classification()
        try await queueContention()
        try await storageLock()
        try await transientRead()
        try await checkpointContention()
        try await finalizationContention()
        try await dispatchContention()
        try await dispatchRevocation()
        try await claimContention()
        try await releaseContention()
        try await completionRelocation()
        try await completionReconciliation()
        try await completionReplacement()
        try await checkpointReplacement()
        print("TURN CURRENCY OK (confirmed supersession, off-main checks, transient storage failures keep streaming, checkpoint, finalization, dispatch and claim writes off main with their gates re-checked afterwards)")
    }

    static func lockedRepository() throws -> (URL, LocalChatRepository, ChatStore, NativeConversationTurn) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("chat.sqlite")
        let repository = try LocalChatRepository(url: url)
        let (store, pending) = try pendingTurn(repository)
        let turn = try repository.claimTurn(pending.id, attempt: UUID())!
        store.turnExecutions[turn.id] = NativeTurnExecution(turn)
        return (url, repository, store, turn)
    }

    static func controlConnection(_ url: URL, stage: String = #function) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.busyMode = .timeout(2)
        do { return try DatabaseQueue(path: url.path, configuration: configuration) }
        catch {
            print("FAIL: turn currency control connection at \(stage): \(error)")
            throw error
        }
    }

    static func holdExclusive(_ url: URL, seconds: TimeInterval, exclusive: Bool = true) async throws -> Task<Void, Error> {
        let other = try controlConnection(url)
        let held = NativeTurnCurrencyFlag()
        let holder = Task.detached {
            try other.writeWithoutTransaction { db in
                try db.execute(sql: exclusive ? "BEGIN EXCLUSIVE" : "BEGIN IMMEDIATE")
                held.raise()
                Thread.sleep(forTimeInterval: seconds)
                try db.execute(sql: "ROLLBACK")
            }
        }
        try await NativeSessionFixture.eventually("Another connection holds the lock") { held.value }
        return holder
    }

    static func hold(_ url: URL, exclusive: Bool = true,
                     finish: @escaping @Sendable (Database) throws -> Void = { try $0.execute(sql: "ROLLBACK") }) async throws -> NativeTurnCurrencyHold {
        let other = try controlConnection(url)
        let held = NativeTurnCurrencyFlag()
        let gate = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try other.writeWithoutTransaction { db in
                try db.execute(sql: exclusive ? "BEGIN EXCLUSIVE" : "BEGIN IMMEDIATE")
                held.raise()
                guard gate.wait(timeout: .now() + .seconds(NativeTurnCurrencyHold.ceilingSeconds)) == .success else {
                    try db.execute(sql: "ROLLBACK")
                    throw NativeTaskFixture.Failure.assertion("A held lock was never released by its check")
                }
                try finish(db)
            }
        }
        try await NativeSessionFixture.eventually("Another connection holds the lock") { held.value }
        return NativeTurnCurrencyHold(gate: gate, task: task)
    }

    static func checkpointContention() async throws {
        let require = NativeTaskFixture.require
        let (url, repository, store, turn) = try lockedRepository()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard let location = store.turnLocation(turn) else { throw NativeTaskFixture.Failure.assertion("The claimed turn has a location") }
        var message = store.conversations[location.conversation].messages[location.reply]
        message.text = "Checkpoint under contention"
        let holder = try await hold(url)
        let scheduled = NativeTurnCurrencyProbe.prompt { store.scheduleTurnCheckpoint(turn, message: message, ordinal: location.reply) }
        try require(scheduled && store.turnExecutions[turn.id]?.checkpoint != nil && store.turnExecutions[turn.id]?.checkpointFailingSince == nil,
                    "Scheduling a checkpoint must not block the main actor while the database is locked")
        await Task.yield()
        let noted = NativeTurnCurrencyProbe.prompt { store.setTurnStatus("Working on this answer", turn: turn) }
        try require(noted && store.turnStatuses[turn.assistantMessageID] == "Working on this answer"
                    && store.turnExecutions[turn.id]?.checkpoint != nil && store.turnExecutions[turn.id]?.checkpointFailingSince == nil,
                    "Status updates must not wait behind a checkpoint write")
        try await NativeSessionFixture.eventually("A checkpoint that met the lock is remembered for retry") {
            store.turnExecutions[turn.id]?.checkpointFailingSince != nil && store.turnExecutions[turn.id]?.checkpoint == nil
        }
        try require(store.conversations[location.conversation].messages[location.reply].state == .streaming
                    && store.turnExecutions[turn.id]?.task == nil && store.turnOwned(turn),
                    "A failed checkpoint never interrupts the answer")
        try await holder.release()
        let released = ContinuousClock.now
        message.text = "Checkpoint after release"
        store.scheduleTurnCheckpoint(turn, message: message, ordinal: location.reply)
        guard let retry = store.turnExecutions[turn.id]?.checkpoint else {
            throw NativeTaskFixture.Failure.assertion("The retried checkpoint is scheduled at once")
        }
        await retry.value
        let landed = released.duration(to: .now)
        try require(try repository.messages(conversationID: turn.conversationID)[location.reply].text == "Checkpoint after release"
                    && landed < NativeTurnCurrencyProbe.retryLimit,
                    "The retried checkpoint lands promptly after release")
        try require(store.turnExecutions[turn.id]?.checkpointFailingSince == nil, "The failure window clears")
        store.turnExecutions = [:]
        store.conversationTurnLoop?.cancel()
    }

    static func finalizationContention() async throws {
        let require = NativeTaskFixture.require
        let (url, repository, store, turn) = try lockedRepository()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard let location = store.turnLocation(turn) else { throw NativeTaskFixture.Failure.assertion("The claimed turn has a location") }
        var message = store.conversations[location.conversation].messages[location.reply]
        message.text = "Finished under contention"
        message.state = .complete
        store.turnExecutions[turn.id]?.finalization = (.complete, message, location.reply)
        store.suspendsTurnScheduling = false
        let holder = try await hold(url)
        let scheduled = NativeTurnCurrencyProbe.prompt { store.scheduleConversationTurns() }
        try require(scheduled && store.isSchedulingTurns && store.turnExecutions[turn.id]?.finalization != nil,
                    "Finalization must not block the main actor while the database is locked")
        await Task.yield()
        let noted = NativeTurnCurrencyProbe.prompt { store.setTurnStatus("Working on this answer", turn: turn) }
        try require(noted && store.turnStatuses[turn.assistantMessageID] == "Working on this answer" && store.isSchedulingTurns,
                    "Status updates must not wait behind finalization")
        try await NativeSessionFixture.eventually("The locked tick settles") { !store.isSchedulingTurns }
        try require(store.turnExecutions[turn.id]?.finalization != nil, "A finalization that met the lock stays pending")
        try await holder.release()
        let released = ContinuousClock.now
        store.scheduleConversationTurns()
        try await NativeSessionFixture.eventually("The tick after release settles") { !store.isSchedulingTurns }
        try require(released.duration(to: .now) < NativeTurnCurrencyProbe.tickLimit && store.turnExecutions[turn.id] == nil
                    && (try repository.conversationTurns()).first(where: { $0.id == turn.id })?.state == .complete,
                    "Finalization completes on the first tick after release")
        try require(try repository.messages(conversationID: turn.conversationID)[location.reply].text == "Finished under contention",
                    "The finalized message is saved in full")
        let (url2, repository2, store2, turn2) = try lockedRepository()
        defer { try? FileManager.default.removeItem(at: url2.deletingLastPathComponent()) }
        guard let location2 = store2.turnLocation(turn2) else { throw NativeTaskFixture.Failure.assertion("The second claimed turn has a location") }
        var stale = store2.conversations[location2.conversation].messages[location2.reply]
        stale.text = "Stale finalization"
        stale.state = .complete
        store2.turnExecutions[turn2.id]?.finalization = (.complete, stale, location2.reply)
        store2.suspendsTurnScheduling = false
        let stoppedID = turn2.id.uuidString
        let superseder = try await hold(url2) { db in
            try db.execute(sql: "UPDATE native_conversation_turns SET state='stopped' WHERE id=?", arguments: [stoppedID])
            try db.execute(sql: "COMMIT")
        }
        store2.scheduleConversationTurns()
        try await NativeSessionFixture.eventually("The locked tick settles") { !store2.isSchedulingTurns }
        try require(store2.turnExecutions[turn2.id]?.finalization != nil, "A tick that met the lock keeps the execution")
        try await superseder.release()
        store2.scheduleConversationTurns()
        try await NativeSessionFixture.eventually("The stale tick releases the superseded execution") {
            !store2.isSchedulingTurns && store2.turnExecutions[turn2.id] == nil
        }
        let savedState = try await repository2.database.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM native_conversation_turns WHERE id=?", arguments: [turn2.id.uuidString])
        }
        try require(savedState == NativeConversationTurn.State.stopped.rawValue,
                    "A turn superseded during the detached phase is not finished by the stale tick")
        store.conversationTurnLoop?.cancel()
        store2.conversationTurnLoop?.cancel()
    }

    static func dispatchContention() async throws {
        let require = NativeTaskFixture.require
        let (url, repository, store, turn) = try lockedRepository()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard let location = store.turnLocation(turn) else { throw NativeTaskFixture.Failure.assertion("The claimed turn has a location") }
        let activity = NativeToolActivity(id: "dispatch-under-lock", toolID: "apple-reminders", name: "apple_reminders_list",
            title: "List reminders", round: 1, request: "{}", result: nil, state: .pending, confirmationRequired: false)
        let holder = try await hold(url)
        let probe = NativeTurnCurrencyProbe()
        let marking = probe.run { await store.markTurnDispatchOffMain(activity, turn: turn) }
        try await probe.untilStarted()
        try require(probe.responsive, "Marking a dispatch must not block the main actor while the database is locked")
        let noted = NativeTurnCurrencyProbe.prompt { store.setTurnStatus("Working on this answer", turn: turn) }
        try require(noted && store.turnStatuses[turn.assistantMessageID] == "Working on this answer" && !probe.finished,
                    "Status updates must not wait behind the dispatch marker")
        let marked = await marking.value
        try require(!marked, "A dispatch marker that cannot land declines the tool call instead of running it unmarked")
        guard let attempt = turn.attempt else { throw NativeTaskFixture.Failure.assertion("The claimed turn has an attempt") }
        let turnID = turn.id
        let waited = await Task.detached { () -> Duration? in
            let start = ContinuousClock.now
            do {
                try repository.markTurnDispatch(turnID, attempt: attempt, activity: activity)
                return nil
            } catch {
                return start.duration(to: .now)
            }
        }.value
        try require(waited.map { $0 >= NativeTurnCurrencyProbe.waitFloor } == true,
                    "A dispatch marker that meets the lock waits for it before giving up")
        try await holder.release()
        let released = ContinuousClock.now
        try require(try repository.messages(conversationID: turn.conversationID)[location.reply].toolActivities.isEmpty,
                    "A declined dispatch leaves no marker behind")
        let again = await store.markTurnDispatchOffMain(activity, turn: turn)
        try require(again && released.duration(to: .now) < NativeTurnCurrencyProbe.retryLimit, "The marker lands promptly once storage frees")
        try require(try repository.messages(conversationID: turn.conversationID)[location.reply].toolActivities.contains { $0.id == activity.id },
                    "The dispatch marker is saved before the tool runs")
        store.turnExecutions[turn.id] = nil
        let gone = await store.markTurnDispatchOffMain(activity, turn: turn)
        try require(!gone, "A marker for a turn no longer owned is declined after the write")
        store.conversationTurnLoop?.cancel()
    }

    static func fileRepository() throws -> (URL, LocalChatRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("chat.sqlite")
        return (url, try LocalChatRepository(url: url))
    }

    static func dispatchRevocation() async throws {
        let require = NativeTaskFixture.require
        let (url, base) = try fileRepository()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = NativeSessionReadFailureRepository(base)
        repository.lock.withLock { repository.failReadsAfterAcceptance = false }
        let store = NativeSessionFixture.store(repository, transport: NativeSessionFixtureTransport(), gate: NativeSessionGate())
        store.suspendsTurnScheduling = true
        store.sendText("check the reference")
        let pending = try base.conversationTurns()[0]
        guard let turn = try base.claimTurn(pending.id, attempt: UUID()) else {
            throw NativeTaskFixture.Failure.assertion("The pending turn can be claimed")
        }
        store.turnExecutions[turn.id] = NativeTurnExecution(turn)
        guard let location = store.turnLocation(turn) else { throw NativeTaskFixture.Failure.assertion("The claimed turn has a location") }
        let consented = NativeToolActivity(id: "dispatch-consented", toolID: "hold", name: "hold", title: "Check the reference",
            round: 1, request: "{}", result: nil, state: .pending, confirmationRequired: false)
        let allowed = await store.prepareTurnDispatch(consented, turn: turn)
        try require(allowed, "A consented tool dispatches once its marker lands")
        let revoked = NativeToolActivity(id: "dispatch-revoked", toolID: "hold", name: "hold", title: "Check the reference",
            round: 2, request: "{}", result: nil, state: .pending, confirmationRequired: false)
        let release = DispatchSemaphore(value: 0)
        repository.lock.withLock { repository.dispatchGate = release }
        let marking = Task { await store.prepareTurnDispatch(revoked, turn: turn) }
        try await NativeSessionFixture.eventually("The marker write is waiting") { repository.dispatchWaiting.value }
        try require(try !base.messages(conversationID: turn.conversationID)[location.reply].toolActivities.contains { $0.id == revoked.id },
                    "The marker has not landed while its write waits")
        store.updateNativeToolConsent([])
        release.signal()
        let dispatched = await marking.value
        let activities = try base.messages(conversationID: turn.conversationID)[location.reply].toolActivities
        try require(activities.contains { $0.id == revoked.id }, "The marker landed after storage freed")
        try require(!dispatched, "A tool whose consent was revoked while its marker waited never runs")
        store.turnExecutions = [:]
        store.conversationTurnLoop?.cancel()
    }

    static func claimContention() async throws {
        let require = NativeTaskFixture.require
        let base = try LocalChatRepository(inMemory: true)
        let repository = NativeSessionReadFailureRepository(base)
        repository.failReadsAfterAcceptance = false
        repository.claimHold = 0.2
        let transport = NativeSessionFixtureTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
            repository: repository, artifactPersistenceEnabled: false)
        store.newConversation()
        store.suspendsTurnScheduling = true
        store.sendText("saved with original model")
        let pending = try base.conversationTurns()[0]
        store.suspendsTurnScheduling = false
        store.scheduleConversationTurns()
        try await NativeSessionFixture.eventually("The claim is written and waiting to return") { repository.claimLanded.value }
        try require(try base.conversationTurns()[0].state == .running, "The claim has landed while the tick waits for it")
        repository.failTurnWrites = true
        store.applyNativeOptions(.init(baseURL: NativeSessionFixture.config.baseURL, apiKey: nil,
            model: "changed-model", chatTemplateKwargs: nil))
        try await NativeSessionFixture.eventually("The rejected claim is retained when its interruption cannot save") {
            !store.isSchedulingTurns && store.turnExecutions[pending.id]?.finalization?.state == .interrupted
        }
        try require(try base.conversationTurns()[0].state == .running && transport.histories.isEmpty,
                    "A rejected claim whose interruption failed keeps its slot without running")
        repository.failTurnWrites = false
        store.scheduleConversationTurns()
        try await NativeSessionFixture.eventually("The claim tick settles") {
            !store.isSchedulingTurns && store.conversationTurns.first?.state == .interrupted && store.turnExecutions.isEmpty
        }
        let saved = try base.conversationTurns().first { $0.id == pending.id }
        try require(transport.histories.isEmpty && store.turnExecutions.isEmpty,
                    "A turn claimed while its settings change never sends under the new settings")
        try require(saved?.state == .interrupted && saved?.attempt != nil, "The rejected claim is finalized instead of left running")
        try require(store.selected?.messages.last?.failure?.contains("original settings") == true,
                    "The rejected claim explains that the saved message needs its original settings")
        store.conversationTurnLoop?.cancel()
    }

    static func releaseContention() async throws {
        let require = NativeTaskFixture.require
        let base = try LocalChatRepository(inMemory: true)
        let repository = NativeSessionReadFailureRepository(base)
        repository.failReadsAfterAcceptance = false
        repository.claimHold = 0.2
        let transport = NativeSessionFixtureTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
            repository: repository, artifactPersistenceEnabled: false)
        store.newConversation()
        store.suspendsTurnScheduling = true
        store.sendText("claimed then held back")
        let pending = try base.conversationTurns()[0]
        store.suspendsTurnScheduling = false
        store.scheduleConversationTurns()
        try await NativeSessionFixture.eventually("The claim is written and waiting to return") { repository.claimLanded.value }
        store.suspendsTurnScheduling = true
        repository.failTurnWrites = true
        try await NativeSessionFixture.eventually("The claim that cannot start is retained for release") {
            !store.isSchedulingTurns && store.turnExecutions[pending.id]?.finalization?.state == .pending
        }
        try require(try base.conversationTurns()[0].state == .running && transport.histories.isEmpty,
                    "A claim that cannot start and cannot be released keeps its slot without running")
        repository.failTurnWrites = false
        store.suspendsTurnScheduling = false
        store.scheduleConversationTurns()
        try await NativeSessionFixture.eventually("The released claim runs on a later tick") {
            !store.isSchedulingTurns && store.turnExecutions.isEmpty
                && (try? base.conversationTurns().first { $0.id == pending.id }?.state) == .complete
        }
        try require(transport.histories.count == 1 && store.turnExecutions.isEmpty, "The released turn ran exactly once")
        store.conversationTurnLoop?.cancel()
    }

    static func completionReconciliation() async throws {
        let require = NativeTaskFixture.require
        let base = try LocalChatRepository(inMemory: true)
        let repository = NativeSessionReadFailureRepository(base)
        repository.failReadsAfterAcceptance = false
        repository.completeHold = 0.3
        let transport = NativeSessionFixtureTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
            repository: repository, artifactPersistenceEnabled: false)
        store.generatesConversationTitles = true
        store.newConversation()
        store.sendText("finish while the scheduler reconciles")
        guard let conversationID = store.selectedID else { throw NativeTaskFixture.Failure.assertion("The sent message has a conversation") }
        try await NativeSessionFixture.eventually("The completion has committed and is held open") { repository.completeLanded.value }
        store.scheduleConversationTurns()
        try await NativeSessionFixture.eventually("A scheduler tick runs while the completion is held") { !store.isSchedulingTurns }
        try require(store.turnExecutions.count == 1, "Reconciliation keeps the execution that committed its own completion")
        try await NativeSessionFixture.eventually("The completion effects run after the commit returns") {
            store.conversations.first(where: { $0.id == conversationID })?.titleSource == .generated
        }
        try await NativeSessionFixture.eventually("The finished execution is released") { store.turnExecutions.isEmpty }
        try require(transport.histories.count == 2, "The answer and its title request each ran exactly once")
        try require(try base.conversationTurns().first?.state == .complete, "The finished turn is saved")
        store.conversationTurnLoop?.cancel()
    }

    static func completionReplacement() async throws {
        let require = NativeTaskFixture.require
        let base = try LocalChatRepository(inMemory: true)
        let repository = NativeSessionReadFailureRepository(base)
        repository.failReadsAfterAcceptance = false
        let staleFailure = DispatchSemaphore(value: 0)
        repository.completeFailGate = staleFailure
        repository.completeHold = 0.3
        let transport = NativeSessionFixtureTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
            repository: repository, artifactPersistenceEnabled: false)
        store.generatesConversationTitles = true
        store.newConversation()
        store.sendText("replace the attempt while the first completion fails")
        guard let conversationID = store.selectedID else { throw NativeTaskFixture.Failure.assertion("The sent message has a conversation") }
        try await NativeSessionFixture.eventually("The first attempt enters completion") {
            store.turnExecutions.values.contains { $0.completing != nil }
        }
        guard let messageID = store.selected?.messages.last?.id else { throw NativeTaskFixture.Failure.assertion("The answer exists") }
        store.stopAnswer(messageID)
        store.retryAnswer(messageID)
        try await NativeSessionFixture.eventually("The replacement attempt commits its completion") { repository.completeLanded.value }
        staleFailure.signal()
        try await Task.sleep(for: .milliseconds(60))
        store.scheduleConversationTurns()
        try await NativeSessionFixture.eventually("A scheduler tick runs while the replacement is held") { !store.isSchedulingTurns }
        try require(store.turnExecutions.count == 1 && store.turnExecutions.values.first?.completing == .complete,
                    "A stale attempt's late failure leaves the replacement's completion marker alone")
        try await NativeSessionFixture.eventually("The replacement's completion effects run") {
            store.conversations.first(where: { $0.id == conversationID })?.titleSource == .generated
        }
        try await NativeSessionFixture.eventually("The replacement execution is released") { store.turnExecutions.isEmpty }
        try require(try base.conversationTurns().first?.state == .complete, "The replacement turn is saved complete")
        store.conversationTurnLoop?.cancel()
    }

    static func checkpointReplacement() async throws {
        let require = NativeTaskFixture.require
        let base = try LocalChatRepository(inMemory: true)
        let repository = NativeSessionReadFailureRepository(base)
        repository.failReadsAfterAcceptance = false
        let staleFailure = DispatchSemaphore(value: 0)
        repository.checkpointFailGate = staleFailure
        repository.checkpointHold = 0.4
        let transport = NativeSteppedTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
            repository: repository, artifactPersistenceEnabled: false)
        store.newConversation()
        store.sendText("replace the attempt while its checkpoint is stale")
        guard let conversationID = store.selectedID else { throw NativeTaskFixture.Failure.assertion("The sent message has a conversation") }
        try await NativeSessionFixture.eventually("The first attempt's checkpoint is in flight") {
            store.turnExecutions.values.contains { $0.checkpoint != nil }
        }
        guard let messageID = store.selected?.messages.last?.id else { throw NativeTaskFixture.Failure.assertion("The answer exists") }
        store.stopAnswer(messageID)
        store.retryAnswer(messageID)
        try await NativeSessionFixture.eventually("The replacement attempt's checkpoint commits and holds") { repository.checkpointLanded.value }
        guard let replacement = store.turnExecutions.values.first, let handle = replacement.checkpoint else {
            throw NativeTaskFixture.Failure.assertion("The replacement attempt owns an active checkpoint")
        }
        staleFailure.signal()
        try await Task.sleep(for: .milliseconds(80))
        try require(store.turnExecutions.values.first === replacement && replacement.checkpoint == handle,
                    "A stale attempt's late checkpoint return leaves the replacement's checkpoint handle alone")
        await transport.first.release()
        await transport.second.release()
        try await NativeSessionFixture.eventually("The replacement completes after its checkpoint") {
            store.conversations.first(where: { $0.id == conversationID })?.messages.last?.state == .complete && store.turnExecutions.isEmpty
        }
        try require(try base.messages(conversationID: conversationID).last?.text == "Part one. Part two. Part three.",
                    "The replacement's full answer is saved in order")
        store.conversationTurnLoop?.cancel()
    }

    static func completionRelocation() async throws {
        let require = NativeTaskFixture.require
        let (url, repository) = try fileRepository()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = NativeSteppedTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
            repository: repository, artifactPersistenceEnabled: false)
        store.newConversation()
        store.sendText("finish while another chat opens")
        guard let conversationID = store.selectedID else { throw NativeTaskFixture.Failure.assertion("The sent message has a conversation") }
        try await NativeSessionFixture.eventually("The answer streams") { transport.reached >= 1 }
        await transport.first.release()
        try await NativeSessionFixture.eventually("The second part streams") { transport.reached >= 2 }
        let holder = try await holdExclusive(url, seconds: 0.2, exclusive: false)
        await transport.second.release()
        try await NativeSessionFixture.eventually("The final part streams") { transport.reached >= 3 }
        try await Task.sleep(for: .milliseconds(30))
        store.newConversation()
        let front = store.conversations.first
        try require(front?.id != conversationID && front?.messages.isEmpty == true,
                    "A new chat opens at the front while the answer waits to save")
        store.toggleMemoryExclusion(conversationID)
        try await holder.value
        try await NativeSessionFixture.eventually("The answer completes after storage frees") {
            let original = store.conversations.first(where: { $0.id == conversationID })
            return original?.messages.last?.state == .complete && store.turnExecutions.isEmpty
        }
        let original = store.conversations.first(where: { $0.id == conversationID })
        let opened = store.conversations.first(where: { $0.id != conversationID })
        let fullAnswer = "Part one. Part two. Part three."
        try require(original?.messages.last?.text == fullAnswer, "The relocated conversation keeps its finished answer")
        try require(opened?.messages.isEmpty == true, "The chat opened during the save is untouched by the finishing answer")
        let savedTurn = try repository.conversationTurns().first
        try require(savedTurn?.state == .complete, "The finished turn is saved")
        let savedMessages = try repository.messages(conversationID: conversationID)
        try require(savedMessages.last?.text == fullAnswer, "The full answer is saved to its own conversation")
        let savedConversation = try repository.listConversations().first(where: { $0.id == conversationID })
        try require(savedConversation?.memoryExcluded == true && original?.memoryExcluded == true,
                    "A setting changed while the answer waited to save survives completion")
        store.conversationTurnLoop?.cancel()
    }

    static func pendingTurn(_ repository: LocalChatRepository) throws -> (ChatStore, NativeConversationTurn) {
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(),
            repository: repository, artifactPersistenceEnabled: false)
        store.newConversation()
        store.suspendsTurnScheduling = true
        store.sendText("check whether this answer is current")
        return (store, try repository.conversationTurns()[0])
    }

    static func classification() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let (store, pending) = try pendingTurn(repository)
        try require(repository.turnCurrency(pending.id, attempt: UUID()) == .superseded, "A pending turn is not current")
        let first = try repository.claimTurn(pending.id, attempt: UUID())!
        let firstAttempt = first.attempt!
        try require(repository.turnCurrency(first.id, attempt: firstAttempt) == .current, "The running attempt is current")
        try require(repository.turnCurrency(first.id, attempt: UUID()) == .superseded, "A mismatched attempt is not current")
        store.turnExecutions[first.id] = NativeTurnExecution(first)
        let owned = await store.turnCurrency(first)
        try require(owned == .current, "The store confirms its own running attempt")
        var stale = first
        stale.attempt = UUID()
        let fenced = await store.turnCurrency(stale)
        try require(fenced == .superseded, "A result for an attempt the store no longer owns is ignored")
        var reply = try repository.messages(conversationID: first.conversationID)[1]
        reply.state = .interrupted
        try repository.finishTurn(first.id, attempt: firstAttempt, state: .stopped, message: reply, ordinal: 1)
        try require(repository.turnCurrency(first.id, attempt: firstAttempt) == .superseded, "A stopped attempt is not current")
        let stopped = await store.turnCurrency(first)
        try require(stopped == .superseded, "The store reports a stopped attempt as superseded")
        try repository.retryTurn(first.id, profile: first.profile)
        let second = try repository.claimTurn(first.id, attempt: UUID())!
        try require(repository.turnCurrency(first.id, attempt: firstAttempt) == .superseded, "A replaced attempt is not current")
        try require(repository.turnCurrency(second.id, attempt: second.attempt!) == .current, "The newer attempt is current")
        try repository.deleteConversation(second.conversationID)
        try require(repository.turnCurrency(second.id, attempt: second.attempt!) == .superseded, "A deleted turn is not current")
        store.turnExecutions = [:]
        store.conversationTurnLoop?.cancel()
    }

    static func queueContention() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let (store, pending) = try pendingTurn(repository)
        let turn = try repository.claimTurn(pending.id, attempt: UUID())!
        store.turnExecutions[turn.id] = NativeTurnExecution(turn)
        for fenceDuringRead in [false, true] {
            let held = NativeTurnCurrencyFlag()
            let gate = DispatchSemaphore(value: 0)
            let holder = Task.detached {
                try repository.database.write { _ in
                    held.raise()
                    guard gate.wait(timeout: .now() + .seconds(NativeTurnCurrencyHold.ceilingSeconds)) == .success else {
                        throw NativeTaskFixture.Failure.assertion("The held database queue was never released by its check")
                    }
                }
            }
            try await NativeSessionFixture.eventually("The database queue is held") { held.value }
            let probe = NativeTurnCurrencyProbe()
            let check = probe.run { await store.turnCurrency(turn) }
            try await probe.untilStarted()
            try require(probe.responsive, "The currency check must not block the main actor while the database queue is busy")
            let status = fenceDuringRead ? "Still working on this answer" : "Working on this answer"
            let noted = NativeTurnCurrencyProbe.prompt { store.setTurnStatus(status, turn: turn) }
            try require(noted && store.turnStatuses[turn.assistantMessageID] == status && !probe.finished,
                        "Status updates must not wait on the database queue")
            if fenceDuringRead { store.turnExecutions[turn.id] = nil }
            gate.signal()
            try await holder.value
            let currency = await check.value
            try require(currency == (fenceDuringRead ? .superseded : .current),
                        fenceDuringRead ? "A check that outlives its attempt must not report it current"
                                        : "The check confirms the attempt once the queue frees")
        }
        store.turnExecutions = [:]
        store.conversationTurnLoop?.cancel()
    }

    static func storageLock() async throws {
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chat.sqlite")
        let repository = try LocalChatRepository(url: url)
        let (store, pending) = try pendingTurn(repository)
        let turn = try repository.claimTurn(pending.id, attempt: UUID())!
        store.turnExecutions[turn.id] = NativeTurnExecution(turn)
        let holder = try await hold(url)
        let probe = NativeTurnCurrencyProbe()
        let check = probe.run { await store.turnCurrency(turn) }
        try await probe.untilStarted()
        try require(probe.responsive, "The currency check must not block the main actor while another connection holds the lock")
        let currency = await check.value
        try require(currency == .unconfirmed, "A locked database is unconfirmed, not a stopped or replaced answer")
        try await holder.release()
        let recovered = await store.turnCurrency(turn)
        try require(recovered == .current, "The same attempt is current once storage frees")
        store.turnExecutions = [:]
        store.conversationTurnLoop?.cancel()
    }

    static func transientRead() async throws {
        let require = NativeTaskFixture.require
        let base = try LocalChatRepository(inMemory: true)
        let repository = NativeSessionReadFailureRepository(base)
        repository.lock.withLock { repository.failReadsAfterAcceptance = false }
        let transport = NativeSteppedTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
            repository: repository, artifactPersistenceEnabled: false)
        store.newConversation()
        store.sendText("answer in three parts")
        try await NativeSessionFixture.eventually("The first part streams") {
            transport.reached == 1 && store.selected?.messages.last?.text == "Part one."
        }
        store.suspendsTurnScheduling = true
        let turn = try base.conversationTurns()[0]
        repository.lock.withLock { repository.failCurrencyReads = true }
        await transport.first.release()
        try await NativeSessionFixture.eventually("A transient storage failure must not interrupt the answer") {
            store.selected?.messages.last?.text == "Part one. Part two."
        }
        try require(repository.lock.withLock { repository.currencyReadFailures } > 0,
                    "The snapshot check met the storage failure")
        try require(store.selected?.messages.last?.state == .streaming && store.turnExecutions[turn.id]?.task != nil,
                    "The answer keeps streaming after a transient storage failure")
        repository.lock.withLock { repository.failCurrencyReads = false }
        var reply = try base.messages(conversationID: turn.conversationID)[1]
        reply.state = .interrupted
        try base.finishTurn(turn.id, attempt: turn.attempt, state: .stopped, message: reply, ordinal: 1)
        await transport.second.release()
        try await NativeSessionFixture.eventually("Confirmed supersession still stops the answer") {
            transport.reached == 3 && store.turnExecutions[turn.id]?.task == nil
        }
        try require(store.selected?.messages.last?.text.contains("Part three") == false,
                    "A superseded attempt must not apply later snapshots")
        store.suspendsTurnScheduling = false
        store.conversationTurnLoop?.cancel()
    }
}
