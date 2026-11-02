import Foundation
import GRDB

final class NativeTurnCurrencyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
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
        try await completionRelocation()
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

    static func holdExclusive(_ url: URL, seconds: TimeInterval, exclusive: Bool = true) async throws -> Task<Void, Error> {
        let other = try DatabaseQueue(path: url.path)
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

    static func checkpointContention() async throws {
        let require = NativeTaskFixture.require
        let (url, repository, store, turn) = try lockedRepository()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard let location = store.turnLocation(turn) else { throw NativeTaskFixture.Failure.assertion("The claimed turn has a location") }
        var message = store.conversations[location.conversation].messages[location.reply]
        message.text = "Checkpoint under contention"
        let holder = try await holdExclusive(url, seconds: 0.9)
        let start = ContinuousClock.now
        store.scheduleTurnCheckpoint(turn, message: message, ordinal: location.reply)
        try require(elapsed(since: start) < .milliseconds(50), "Scheduling a checkpoint must not block the main actor while the database is locked")
        let statusStart = ContinuousClock.now
        store.setTurnStatus("Working on this answer", turn: turn)
        try require(elapsed(since: statusStart) < .milliseconds(50), "Status updates must not wait behind a checkpoint write")
        try await holder.value
        try require(store.turnExecutions[turn.id]?.checkpointFailingSince != nil,
                    "A checkpoint that met the lock is remembered for retry")
        try require(store.conversations[location.conversation].messages[location.reply].state == .streaming
                    && store.turnExecutions[turn.id]?.task == nil && store.turnOwned(turn),
                    "A failed checkpoint never interrupts the answer")
        let released = ContinuousClock.now
        message.text = "Checkpoint after release"
        store.scheduleTurnCheckpoint(turn, message: message, ordinal: location.reply)
        try await NativeSessionFixture.eventually("The retried checkpoint lands once storage frees") {
            (try? repository.messages(conversationID: turn.conversationID))?[location.reply].text == "Checkpoint after release"
        }
        try require(elapsed(since: released) < .milliseconds(150), "The retried checkpoint lands promptly after release")
        try await NativeSessionFixture.eventually("The failure window clears") { store.turnExecutions[turn.id]?.checkpointFailingSince == nil }
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
        let holder = try await holdExclusive(url, seconds: 0.9)
        let start = ContinuousClock.now
        store.scheduleConversationTurns()
        try require(elapsed(since: start) < .milliseconds(50), "Finalization must not block the main actor while the database is locked")
        let statusStart = ContinuousClock.now
        store.setTurnStatus("Working on this answer", turn: turn)
        try require(elapsed(since: statusStart) < .milliseconds(50), "Status updates must not wait behind finalization")
        try await holder.value
        let released = ContinuousClock.now
        store.scheduleConversationTurns()
        try await NativeSessionFixture.eventually("Finalization lands once storage frees") {
            !store.isSchedulingTurns && store.turnExecutions[turn.id] == nil
                && (try? repository.conversationTurns())?.first(where: { $0.id == turn.id })?.state == .complete
        }
        try require(elapsed(since: released) < .milliseconds(1_500), "Finalization completes on the first tick after release")
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
        let other = try DatabaseQueue(path: url2.path)
        let held = NativeTurnCurrencyFlag()
        let superseder = Task.detached {
            try other.writeWithoutTransaction { db in
                try db.execute(sql: "BEGIN EXCLUSIVE")
                held.raise()
                Thread.sleep(forTimeInterval: 0.6)
                try db.execute(sql: "UPDATE native_conversation_turns SET state='stopped' WHERE id=?", arguments: [turn2.id.uuidString])
                try db.execute(sql: "COMMIT")
            }
        }
        try await NativeSessionFixture.eventually("The superseding connection holds the lock") { held.value }
        store2.scheduleConversationTurns()
        try await superseder.value
        try await NativeSessionFixture.eventually("The locked tick settles") { !store2.isSchedulingTurns }
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
        let holder = try await holdExclusive(url, seconds: 0.9)
        let start = ContinuousClock.now
        let marking = Task { await store.markTurnDispatchOffMain(activity, turn: turn) }
        try await Task.sleep(for: .milliseconds(20))
        try require(elapsed(since: start) < .milliseconds(150), "Marking a dispatch must not block the main actor while the database is locked")
        let statusStart = ContinuousClock.now
        store.setTurnStatus("Working on this answer", turn: turn)
        try require(elapsed(since: statusStart) < .milliseconds(50), "Status updates must not wait behind the dispatch marker")
        let marked = await marking.value
        try require(!marked, "A dispatch marker that cannot land declines the tool call instead of running it unmarked")
        try await holder.value
        let released = ContinuousClock.now
        try require(try repository.messages(conversationID: turn.conversationID)[location.reply].toolActivities.isEmpty,
                    "A declined dispatch leaves no marker behind")
        let again = await store.markTurnDispatchOffMain(activity, turn: turn)
        try require(again && elapsed(since: released) < .milliseconds(150), "The marker lands promptly once storage frees")
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
        let (url, repository) = try fileRepository()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = NativeSessionFixture.store(repository, transport: NativeSessionFixtureTransport(), gate: NativeSessionGate())
        store.suspendsTurnScheduling = true
        store.sendText("check the reference")
        let pending = try repository.conversationTurns()[0]
        guard let turn = try repository.claimTurn(pending.id, attempt: UUID()) else {
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
        let holder = try await holdExclusive(url, seconds: 0.2, exclusive: false)
        let marking = Task { await store.prepareTurnDispatch(revoked, turn: turn) }
        try await Task.sleep(for: .milliseconds(20))
        store.updateNativeToolConsent([])
        let dispatched = await marking.value
        try await holder.value
        let activities = try repository.messages(conversationID: turn.conversationID)[location.reply].toolActivities
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
        store.applyNativeOptions(.init(baseURL: NativeSessionFixture.config.baseURL, apiKey: nil,
            model: "changed-model", chatTemplateKwargs: nil))
        try await NativeSessionFixture.eventually("The claim tick settles") {
            !store.isSchedulingTurns && store.conversationTurns.first?.state == .interrupted
        }
        let saved = try base.conversationTurns().first { $0.id == pending.id }
        try require(transport.histories.isEmpty && store.turnExecutions.isEmpty,
                    "A turn claimed while its settings change never sends under the new settings")
        try require(saved?.state == .interrupted && saved?.attempt != nil, "The rejected claim is finalized instead of left running")
        try require(store.selected?.messages.last?.failure?.contains("original settings") == true,
                    "The rejected claim explains that the saved message needs its original settings")
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

    static func elapsed(since start: ContinuousClock.Instant) -> Duration { start.duration(to: .now) }

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
            let holder = Task.detached {
                try repository.database.write { _ in
                    held.raise()
                    Thread.sleep(forTimeInterval: 0.35)
                }
            }
            try await NativeSessionFixture.eventually("The database queue is held") { held.value }
            let statusStart = ContinuousClock.now
            store.setTurnStatus("Working on this answer", turn: turn)
            try require(elapsed(since: statusStart) < .milliseconds(50), "Status updates must not wait on the database queue")
            let start = ContinuousClock.now
            let check = Task { await store.turnCurrency(turn) }
            try await Task.sleep(for: .milliseconds(20))
            try require(elapsed(since: start) < .milliseconds(150),
                        "The currency check must not block the main actor while the database queue is busy")
            if fenceDuringRead { store.turnExecutions[turn.id] = nil }
            let currency = await check.value
            try await holder.value
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
        let other = try DatabaseQueue(path: url.path)
        let held = NativeTurnCurrencyFlag()
        let holder = Task.detached {
            try other.writeWithoutTransaction { db in
                try db.execute(sql: "BEGIN EXCLUSIVE")
                held.raise()
                Thread.sleep(forTimeInterval: 0.6)
                try db.execute(sql: "ROLLBACK")
            }
        }
        try await NativeSessionFixture.eventually("Another connection holds an exclusive lock") { held.value }
        let start = ContinuousClock.now
        let check = Task { await store.turnCurrency(turn) }
        try await Task.sleep(for: .milliseconds(20))
        try require(elapsed(since: start) < .milliseconds(150),
                    "The currency check must not block the main actor while another connection holds the lock")
        let currency = await check.value
        try require(currency == .unconfirmed, "A locked database is unconfirmed, not a stopped or replaced answer")
        try await holder.value
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
