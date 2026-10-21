import Foundation

struct NativeTaskWorker: Sendable {
    let timeoutSeconds: Double
    let step: @Sendable (NativeTaskRecord) async throws -> NativeTaskStepResult
}

actor NativeTaskDispatcher {
    let store: NativeTaskStore
    let pollSeconds: Double
    let graceSeconds: Double
    private(set) var workers: [String: NativeTaskWorker] = [:]
    private(set) var failure: String?
    private var loop: Task<Void, Never>?
    private var active: Task<NativeTaskStepResult, Error>?
    private var shuttingDown = false

    init(store: NativeTaskStore, workers: [String: NativeTaskWorker] = [:], pollSeconds: Double = 0.1, graceSeconds: Double = 1) {
        self.store = store
        self.workers = workers
        self.pollSeconds = pollSeconds
        self.graceSeconds = graceSeconds
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

    func start() throws {
        guard loop == nil else { return }
        try store.recover()
        shuttingDown = false
        failure = nil
        loop = Task { [weak self] in await self?.dispatch() }
    }

    func stop() async {
        shuttingDown = true
        loop?.cancel()
        if let loop { await loop.value }
        loop = nil
        if let active {
            active.cancel()
            let grace = graceSeconds
            let finished = await withTaskGroup(of: Bool.self) { group in
                group.addTask { _ = try? await active.value; return true }
                group.addTask { try? await Task.sleep(for: .seconds(grace)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !finished { failure = "Background work is paused until the running step exits." }
            self.active = nil
        }
        try? store.recover()
    }

    private func dispatch() async {
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
        let step = Task { try await worker.step(task) }
        active = step
        defer { if active == step { active = nil } }
        let timeout = worker.timeoutSeconds
        let outcome: NativeTaskStepResult
        do {
            outcome = try await withThrowingTaskGroup(of: NativeTaskStepResult?.self) { group in
                group.addTask { try await withTaskCancellationHandler { try await step.value } onCancel: { step.cancel() } }
                group.addTask { try await Task.sleep(for: .seconds(timeout)); return nil }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                guard let result = first else { throw NativeTaskDispatcherTimeout() }
                return result
            }
        } catch is NativeTaskDispatcherTimeout {
            step.cancel()
            outcome = .failed(checkpoint: task.checkpoint, reason: "step_timeout")
        } catch is CancellationError {
            step.cancel()
            if shuttingDown { return }
            outcome = .failed(checkpoint: task.checkpoint, reason: "step_canceled")
        } catch {
            outcome = .failed(checkpoint: task.checkpoint, reason: "worker_error")
        }
        guard !shuttingDown else { return }
        await persist(task, outcome)
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

struct NativeTaskDispatcherTimeout: Error {}
