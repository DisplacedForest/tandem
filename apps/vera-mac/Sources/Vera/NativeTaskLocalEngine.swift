import Foundation
import GRDB

struct NativeTaskLocalStatus: Error, Sendable {
    let code: Int
    let detail: String
}

final class NativeTaskEngineLock: @unchecked Sendable {
    private static let registry = NSLock()
    nonisolated(unsafe) private static var owners: Set<String> = []
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var registered = false
    let key: String
    let path: String?

    init(database: DatabaseQueue) {
        let databasePath = database.path
        let inMemory = databasePath.isEmpty || databasePath == ":memory:" || databasePath.hasPrefix("file::memory:")
        path = inMemory ? nil : databasePath + ".engine.lock"
        key = inMemory ? "memory:\(ObjectIdentifier(database).hashValue)" : "file:" + databasePath
    }

    func acquire() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        Self.registry.lock()
        let inserted = Self.owners.insert(key).inserted
        Self.registry.unlock()
        guard inserted else { throw NativeTaskStoreError.conflict("Another engine already runs for this database") }
        if let path {
            let handle = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard handle >= 0, flock(handle, LOCK_EX | LOCK_NB) == 0 else {
                if handle >= 0 { close(handle) }
                Self.registry.lock()
                Self.owners.remove(key)
                Self.registry.unlock()
                throw NativeTaskStoreError.conflict("Another process already runs the task engine for this database")
            }
            descriptor = handle
        }
        registered = true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard registered else { return }
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
        Self.registry.lock()
        Self.owners.remove(key)
        Self.registry.unlock()
        registered = false
    }

    var isHeld: Bool { lock.withLock { registered } }
}

private actor NativeTaskEngineOwnership {
    private(set) var owned = false

    func start(lock: NativeTaskEngineLock, store: NativeTaskStore, dispatcher: NativeTaskDispatcher) async throws {
        guard !owned else { return }
        try lock.acquire()
        do {
            try await store.database.write { db in
                try db.execute(sql: """
                    UPDATE native_task_generations SET state = 'failed', failure = 'previous_request_uncertain', response = NULL
                    WHERE state = 'reserved'
                    """)
            }
            try await dispatcher.start()
            owned = true
        } catch {
            lock.release()
            throw error
        }
    }

    func stop(lock: NativeTaskEngineLock, dispatcher: NativeTaskDispatcher) async {
        guard owned else { return }
        owned = false
        if await dispatcher.stop() { lock.release() }
    }

    func abandon(lock: NativeTaskEngineLock, dispatcher: NativeTaskDispatcher) async {
        guard owned else { return }
        owned = false
        await dispatcher.abandon()
        lock.release()
    }
}

final class NativeTaskLocalEngine: Sendable {
    static let identity = try! NativeTaskEngineIdentity(URL(string: "http://localhost/tandem-engine")!)
    static let pollSeconds: Double = 0.25

    let store: NativeTaskStore
    let exchange: NativeTaskGenerationExchange
    let dispatcher: NativeTaskDispatcher
    let lock: NativeTaskEngineLock
    private let ownership = NativeTaskEngineOwnership()

    func start() async throws {
        try await ownership.start(lock: lock, store: store, dispatcher: dispatcher)
    }

    func stop() async {
        await ownership.stop(lock: lock, dispatcher: dispatcher)
    }

    func abandon() async {
        await ownership.abandon(lock: lock, dispatcher: dispatcher)
    }

    init(database: DatabaseQueue, admission: @escaping @Sendable () -> NativeInferenceAdmission? = { .configured() },
         pollSeconds: Double = 0.1, graceSeconds: Double = 1,
         workers: (NativeTaskGenerationExchange) -> [String: NativeTaskWorker] = { _ in [:] }) {
        let store = NativeTaskStore(database: database)
        let exchange = NativeTaskGenerationExchange(store: store, admission: admission)
        let lock = NativeTaskEngineLock(database: database)
        self.store = store
        self.exchange = exchange
        self.lock = lock
        dispatcher = NativeTaskDispatcher(store: store, workers: workers(exchange), pollSeconds: pollSeconds,
                                          graceSeconds: graceSeconds, onRetire: { lock.release() })
    }

    static func research(database: DatabaseQueue, search: NativeResearchSearch,
                         ownerName: @escaping @Sendable () -> String?) -> NativeTaskLocalEngine {
        NativeTaskLocalEngine(database: database, workers: { exchange in
            ["research": NativeResearchWorker.make(exchange: exchange, search: search, ownerName: ownerName)]
        })
    }

    var client: NativeTaskClient {
        NativeTaskClient { [self] method, url, body, _ in
            do { return try await handle(method: method, path: url.path, body: body) }
            catch let status as NativeTaskLocalStatus {
                return (try NativeTaskStore.canonical(["detail": status.detail]), status.code)
            } catch NativeTaskStoreError.notFound {
                return (try NativeTaskStore.canonical(["detail": "Task not found"]), 404)
            } catch NativeTaskStoreError.conflict(let detail) {
                return (try NativeTaskStore.canonical(["detail": detail]), 409)
            } catch NativeTaskStoreError.invalid(let detail) {
                return (try NativeTaskStore.canonical(["detail": detail]), 422)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw NativeTaskHTTPError.unavailable
            }
        }
    }

    var transport: NativeTaskEventTransport {
        let store = self.store
        return NativeTaskEventTransport { engine, cursor in
            AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
                let operation = Task {
                    do {
                        guard engine == Self.identity else { throw NativeTaskHTTPError.status(404) }
                        var after = max(0, cursor)
                        guard try after <= store.latestEventID() else { throw NativeTaskHTTPError.status(409) }
                        while !Task.isCancelled {
                            let events = try store.events(after: after)
                            for event in events {
                                after = event.id
                                switch continuation.yield(NativeTaskEvent(id: event.id, taskID: event.taskID)) {
                                case .enqueued: break
                                case .dropped: throw NativeTaskHTTPError.unavailable
                                case .terminated: return
                                @unknown default: throw NativeTaskHTTPError.unavailable
                                }
                            }
                            try await Task.sleep(for: .seconds(Self.pollSeconds))
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch let error as NativeTaskHTTPError {
                        continuation.finish(throwing: error)
                    } catch {
                        continuation.finish(throwing: NativeTaskHTTPError.unavailable)
                    }
                }
                continuation.onTermination = { _ in operation.cancel() }
            }
        }
    }

    func handle(method: String, path: String, body: Data?) async throws -> (Data, Int) {
        let prefix = Self.identity.base.path
        guard path.hasPrefix(prefix) else { throw NativeTaskLocalStatus(code: 404, detail: "Not found") }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard parts.first == "tasks" else { throw NativeTaskLocalStatus(code: 404, detail: "Not found") }
        switch (method, parts.count, parts.dropFirst().first, parts.last) {
        case ("POST", 1, _, _):
            return (try await create(body ?? Data()).snapshotJSON(), 201)
        case ("GET", 2, let id?, _):
            return (try store.get(id).snapshotJSON(), 200)
        case ("POST", 3, let id?, "cancel"):
            return (try store.cancel(id).snapshotJSON(), 200)
        case ("POST", 3, let id?, "decision"):
            return (try decision(id, body ?? Data()).snapshotJSON(), 200)
        case ("POST", 4, let id?, "ready") where parts[2] == "native":
            let binding = try decode(NativeTaskAdmissionBinding.self, body)
            guard let job = try await exchange.ready(taskID: id, binding: binding) else { return (Data(), 204) }
            return (try nativeTaskEncoded(job), 200)
        case ("POST", 4, let id?, "result") where parts[2] == "native":
            try await exchange.result(taskID: id, body: try decode(NativeTaskGenerationResponse.self, body))
            return (Data(), 204)
        default:
            throw NativeTaskLocalStatus(code: 404, detail: "Not found")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: Data?) throws -> T {
        guard let body, let value = try? JSONDecoder().decode(type, from: body) else {
            throw NativeTaskLocalStatus(code: 422, detail: "The request body is not valid")
        }
        return value
    }

    private func create(_ body: Data) async throws -> NativeTaskRecord {
        let object = try NativeTaskStore.object(body)
        guard let workerType = object["worker_type"] as? String, let payload = object["payload"] as? [String: Any],
              let key = object["idempotency_key"] as? String else {
            throw NativeTaskLocalStatus(code: 422, detail: "A worker type, payload and idempotency key are required")
        }
        guard await dispatcher.workers[workerType] != nil else {
            throw NativeTaskLocalStatus(code: 503, detail: "This task worker is not configured")
        }
        let payloadData = try NativeTaskStore.canonical(payload)
        if workerType == "research" {
            guard (try? JSONDecoder().decode(NativeResearchTaskPayload.self, from: payloadData)) != nil else {
                throw NativeTaskLocalStatus(code: 422, detail: "The research request is not valid")
            }
        }
        return try store.create(workerType: workerType, payload: payloadData, idempotencyKey: key)
    }

    private func decision(_ id: String, _ body: Data) throws -> NativeTaskRecord {
        let object = try NativeTaskStore.object(body)
        guard let decisionID = object["decision_id"] as? String, (1...80).contains(decisionID.utf8.count),
              let key = object["idempotency_key"] as? String, let reply = object["reply"] as? [String: Any] else {
            throw NativeTaskLocalStatus(code: 422, detail: "A decision id, idempotency key and reply are required")
        }
        return try store.respond(id, decisionID: decisionID, replyKey: key, reply: try NativeTaskStore.canonical(reply))
    }
}
