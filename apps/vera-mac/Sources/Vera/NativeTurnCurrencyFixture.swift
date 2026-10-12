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
        print("TURN CURRENCY OK (confirmed supersession, off-main checks, transient storage failures keep streaming)")
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
