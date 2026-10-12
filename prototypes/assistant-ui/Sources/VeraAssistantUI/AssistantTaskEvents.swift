import Foundation

public struct AssistantTaskEvent: Equatable, Sendable {
    public let id: Int64
    public let taskID: String

    public init(id: Int64, taskID: String) {
        self.id = id
        self.taskID = taskID
    }
}

public enum AssistantTaskEventError: Error, Equatable, Sendable {
    case cursorReset
}

@MainActor
final class AssistantTaskEventTracking {
    private weak var store: PrototypeStore?
    private let events: @Sendable (Int64) async throws -> AsyncThrowingStream<AssistantTaskEvent, Error>
    private var lifecycle: UUID?
    private var token: UUID?
    private var loop: Task<Void, Never>?
    private var reader: Task<Void, Error>?
    private var drain: Task<Void, Never>?
    private var received: Int64 = 0
    private var pending: Int64?
    private(set) var healthy = false

    init(store: PrototypeStore,
         events: @escaping @Sendable (Int64) async throws -> AsyncThrowingStream<AssistantTaskEvent, Error>) {
        self.store = store
        self.events = events
    }

    func accepts(_ value: UUID) -> Bool { token == value && lifecycle != nil }

    func start() {
        guard loop == nil, store != nil else { return }
        let generation = UUID()
        lifecycle = generation
        loop = Task { [weak self] in await self?.run(generation) }
    }

    func stop() async {
        lifecycle = nil
        if let token { store?.retireTaskEventRefresh(token) }
        token = nil
        healthy = false
        pending = nil
        let previousLoop = loop
        let previousReader = reader
        let previousDrain = drain
        loop = nil
        reader = nil
        drain = nil
        previousLoop?.cancel()
        previousReader?.cancel()
        previousDrain?.cancel()
        await withCheckedContinuation { continuation in
            let waiter = TaskEventStopWaiter(continuation)
            let timeout = Task {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                waiter.finish()
            }
            Task {
                await previousLoop?.value
                _ = await previousReader?.result
                await previousDrain?.value
                timeout.cancel()
                waiter.finish()
            }
        }
    }

    private func run(_ generation: UUID) async {
        var reset = false
        while lifecycle == generation && !Task.isCancelled {
            guard let store else { break }
            let connection = UUID()
            token = connection
            received = reset ? 0 : (store.saved.taskEventCursor ?? 0)
            pending = nil
            do {
                guard try await store.reconcileTaskEvents(cursor: received, token: connection) else {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                reset = false
                let source = try await events(received)
                guard accepts(connection), !Task.isCancelled else { break }
                healthy = true
                let operation = Task { [weak self] in
                    for try await event in source {
                        try Task.checkCancellation()
                        guard let self, self.accepts(connection) else { return }
                        guard event.id > 0, UUID(uuidString: event.taskID) != nil else { throw PrototypeError.invalidResponse }
                        if event.id <= self.received { continue }
                        self.received = event.id
                        self.pending = event.id
                        self.scheduleDrain(connection)
                    }
                }
                reader = operation
                try await operation.value
            } catch AssistantTaskEventError.cursorReset {
                reset = true
            } catch { }
            guard lifecycle == generation else { return }
            healthy = false
            store.retireTaskEventRefresh(connection)
            token = nil
            reader?.cancel()
            reader = nil
            drain?.cancel()
            drain = nil
            pending = nil
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func scheduleDrain(_ connection: UUID) {
        guard drain == nil else { return }
        drain = Task { [weak self] in
            guard let self else { return }
            defer { if self.accepts(connection) { self.drain = nil } }
            do {
                while self.accepts(connection), !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(40))
                    guard let cursor = self.pending, let store = self.store else { return }
                    self.pending = nil
                    if try await !store.reconcileTaskEvents(cursor: cursor, token: connection) {
                        guard self.accepts(connection), !Task.isCancelled else { return }
                        self.pending = max(cursor, self.pending ?? cursor)
                    }
                    if self.pending == nil { return }
                }
            } catch {
                guard self.accepts(connection), !Task.isCancelled else { return }
                self.healthy = false
                self.reader?.cancel()
            }
        }
    }
}

@MainActor
private final class TaskEventStopWaiter {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
