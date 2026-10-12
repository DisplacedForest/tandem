import Foundation

struct NativeTaskStreamBatch: Equatable, Sendable {
    let epoch: UInt64
    let cursor: Int64
    let tasks: [String: Int64]
}

struct NativeTaskStreamProgress: Sendable {
    private(set) var appliedCursor: Int64
    private(set) var receivedCursor: Int64
    private(set) var connectionEpoch: UInt64 = 0
    private var pending: [String: Int64] = [:]
    private var active: NativeTaskStreamBatch?
    private var unresolved: Set<String> = []
    private var epoch: UInt64 = 0

    init(cursor: Int64 = 0) {
        appliedCursor = max(0, cursor)
        receivedCursor = max(0, cursor)
    }

    mutating func replaceConnection() -> UInt64 {
        connectionEpoch &+= 1
        epoch &+= 1
        receivedCursor = appliedCursor
        pending = [:]
        active = nil
        unresolved = []
        return connectionEpoch
    }

    mutating func receive(_ event: NativeTaskEvent, enrolled: Bool, connection: UInt64) {
        guard connection == connectionEpoch else { return }
        guard event.id > receivedCursor else { return }
        receivedCursor = event.id
        if enrolled { pending[event.taskID] = event.id }
    }

    mutating func beginBatch() -> NativeTaskStreamBatch? {
        guard active == nil, receivedCursor > appliedCursor else { return nil }
        epoch &+= 1
        let batch = NativeTaskStreamBatch(epoch: epoch, cursor: receivedCursor, tasks: pending)
        active = batch
        unresolved = Set(pending.keys)
        pending = [:]
        return batch
    }

    func remaining(in batch: NativeTaskStreamBatch) -> [String: Int64] {
        guard active == batch else { return [:] }
        return batch.tasks.filter { unresolved.contains($0.key) }
    }

    mutating func acknowledge(taskID: String, in batch: NativeTaskStreamBatch) {
        guard active == batch else { return }
        unresolved.remove(taskID)
    }

    func canCommit(_ batch: NativeTaskStreamBatch) -> Bool {
        active == batch && unresolved.isEmpty
    }

    @discardableResult
    mutating func committed(_ batch: NativeTaskStreamBatch) -> Bool {
        guard canCommit(batch) else { return false }
        appliedCursor = batch.cursor
        active = nil
        return true
    }

    mutating func resetCursor() {
        appliedCursor = 0
        _ = replaceConnection()
    }
}
