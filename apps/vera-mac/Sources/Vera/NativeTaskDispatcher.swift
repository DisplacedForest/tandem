import Foundation

struct NativeTaskWorker: Sendable {
    let timeoutSeconds: Double
    let step: @Sendable (NativeTaskRecord) async throws -> NativeTaskStepResult
}

struct NativeTaskDispatcherTimeout: Error {}

private actor NativeTaskStepSignal {
    private var outcome: Result<NativeTaskStepResult, Error>?
    private var waiters: [UUID: CheckedContinuation<Result<NativeTaskStepResult, Error>, Error>] = [:]

    func settle(_ result: Result<NativeTaskStepResult, Error>) {
        guard outcome == nil else { return }
        outcome = result
        for waiter in waiters.values { waiter.resume(returning: result) }
        waiters = [:]
    }

    var isSettled: Bool { outcome != nil }

    func wait() async throws -> Result<NativeTaskStepResult, Error> {
        if let outcome { return outcome }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let outcome { continuation.resume(returning: outcome) } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

actor NativeTaskDispatcher {
    let store: NativeTaskStore
    let pollSeconds: Double
    let graceSeconds: Double
    private(set) var workers: [String: NativeTaskWorker] = [:]
    private(set) var failure: String?
    private(set) var owned = false
    private var loop: Task<Void, Never>?
    private var active: (task: Task<Void, Never>, signal: NativeTaskStepSignal)?
    private var retirement: Task<Void, Never>?
    private var shuttingDown = false
    private let onRetire: @Sendable () -> Void

    init(store: NativeTaskStore, workers: [String: NativeTaskWorker] = [:], pollSeconds: Double = 0.1,
         graceSeconds: Double = 1, onRetire: @escaping @Sendable () -> Void = {}) {
        self.store = store
        self.workers = workers
        self.pollSeconds = pollSeconds
        self.graceSeconds = graceSeconds
        self.onRetire = onRetire
    }

    func register(_ workerType: String, _ worker: NativeTaskWorker) throws {
        guard loop == nil, workers[workerType] == nil else {
            throw NativeTaskStoreError.invalid("Register each worker once before starting the dispatcher")
        }
        guard !workerType.isEmpty, workerType.utf8.count <= 80, worker.timeoutSeconds.isFinite, worker.timeoutSeconds > 0 else {
            throw NativeTaskStoreError.invalid("Worker name and a finite positive step timeout are required")
        }
        workers[workerType] = worker
    }

    var isRunning: Bool { loop != nil }
    var isRetiring: Bool { retirement != nil }

    func start() throws {
        guard loop == nil else { return }
        guard active == nil, retirement == nil else {
            throw NativeTaskStoreError.conflict("A previous step still owns the task storage")
        }
        try store.recover()
        owned = true
        shuttingDown = false
        failure = nil
        loop = Task { [weak self] in await self?.dispatch() }
    }

    @discardableResult
    func stop() async -> Bool {
        shuttingDown = true
        loop?.cancel()
        if let loop { await loop.value }
        loop = nil
        if let active {
            active.task.cancel()
            let settled = await settledWithinGrace(active.signal)
            if !settled {
                failure = "Background work is paused until the running step exits."
                if retirement == nil { retirement = Task { [weak self] in await self?.retire(active) } }
                return false
            }
            self.active = nil
        }
        if let retirement {
            await retirement.value
            self.retirement = nil
        }
        if owned {
            try? store.recover()
            owned = false
        }
        return true
    }

    func abandon() {
        shuttingDown = true
        loop?.cancel()
        loop = nil
        active?.task.cancel()
        active = nil
        owned = false
    }

    private func settledWithinGrace(_ signal: NativeTaskStepSignal) async -> Bool {
        let grace = graceSeconds
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await signal.wait()) != nil }
            group.addTask { try? await Task.sleep(for: .seconds(grace)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func retire(_ entry: (task: Task<Void, Never>, signal: NativeTaskStepSignal)) async {
        _ = try? await entry.signal.wait()
        if active?.signal === entry.signal { active = nil }
        if owned {
            try? store.recover()
            owned = false
        }
        retirement = nil
        onRetire()
    }

    private func dispatch() async {
        defer { if !shuttingDown { loop = nil } }
        while !Task.isCancelled && failure == nil {
            let claimed: NativeTaskRecord?
            do { claimed = try store.claim(workerTypes: Set(workers.keys)) }
            catch {
                failure = "Background work is paused until the task storage recovers."
                return
            }
            guard let task = claimed else {
                do { try await Task.sleep(for: .seconds(pollSeconds)) } catch { return }
                continue
            }
            guard !Task.isCancelled else { return }
            await runStep(task)
        }
    }

    private func runStep(_ task: NativeTaskRecord) async {
        guard let worker = workers[task.workerType] else {
            await persist(task, .failed(checkpoint: task.checkpoint, reason: "worker_missing"))
            return
        }
        let signal = NativeTaskStepSignal()
        let step = Task {
            do { await signal.settle(.success(try await worker.step(task))) }
            catch { await signal.settle(.failure(error)) }
        }
        active = (step, signal)
        let timeout = worker.timeoutSeconds
        let outcome: NativeTaskStepResult
        var settled = true
        do {
            let result = try await withThrowingTaskGroup(of: Result<NativeTaskStepResult, Error>?.self) { group in
                group.addTask { try await signal.wait() }
                group.addTask { try await Task.sleep(for: .seconds(timeout)); return nil }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                guard let result = first else { throw NativeTaskDispatcherTimeout() }
                return result
            }
            switch result {
            case .success(let value): outcome = value
            case .failure(let error) where error is CancellationError:
                if shuttingDown { return }
                outcome = .failed(checkpoint: task.checkpoint, reason: "step_canceled")
            case .failure: outcome = .failed(checkpoint: task.checkpoint, reason: "worker_error")
            }
        } catch is NativeTaskDispatcherTimeout {
            step.cancel()
            settled = false
            outcome = .failed(checkpoint: task.checkpoint, reason: "step_timeout")
        } catch {
            step.cancel()
            return
        }
        guard !shuttingDown else { return }
        await persist(task, outcome)
        if !settled {
            if await settledWithinGrace(signal) {
                active = nil
            } else {
                failure = "Background work is paused until the running step exits."
                if retirement == nil { retirement = Task { [weak self] in await self?.retire((step, signal)) } }
            }
            return
        }
        active = nil
    }

    private func persist(_ task: NativeTaskRecord, _ outcome: NativeTaskStepResult) async {
        var current = outcome
        for attempt in 0..<3 {
            do {
                _ = try store.commitStep(task.id, generation: task.generation, step: current)
                return
            } catch NativeTaskStoreError.conflict {
                guard let record = try? store.get(task.id), record.state == .running, record.generation == task.generation else { return }
                current = .failed(checkpoint: task.checkpoint, reason: "invalid_step_result")
            } catch NativeTaskStoreError.invalid {
                current = .failed(checkpoint: task.checkpoint, reason: "invalid_step_result")
            } catch {
                if attempt == 2 { failure = "Background work is paused until the task storage recovers."; return }
                do { try await Task.sleep(for: .seconds(pollSeconds)) } catch { return }
            }
        }
    }
}
