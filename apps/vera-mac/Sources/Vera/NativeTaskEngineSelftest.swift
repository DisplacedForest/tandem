import Foundation
import GRDB

private actor NativeTaskEngineCounter {
    private var counts: [String: Int] = [:]
    func bump(_ key: String) { counts[key, default: 0] += 1 }
    func count(_ key: String) -> Int { counts[key] ?? 0 }
}

private struct NativeTaskEngineHarness {
    let repository: LocalChatRepository
    let engine: NativeTaskLocalEngine
    let service: NativeTaskHandoffService
    let tracker: NativeTaskTracker
    let broker: NativeTaskGenerationBroker
    let counter: NativeTaskEngineCounter
    let profile: NativeTaskProfileBinding
    private let loops: NativeTaskEngineLoops

    private final class NativeTaskEngineLoops: @unchecked Sendable {
        var tasks: [Task<Void, Never>] = []
    }

    static func make(repository: LocalChatRepository, counter: NativeTaskEngineCounter,
                     generate: @escaping @Sendable (NativeTaskGenerationJob) async throws -> String) throws -> NativeTaskEngineHarness {
        let arbiter = NativeInferenceArbiter(cooldown: 0)
        let search = NativeResearchSearch { query, _ in
            await counter.bump("search")
            return [NativeResearchSource(n: 0, title: "Fictional moon guide", url: "https://fictional.test/\(query.count)",
                                         content: "The fictional moon Luma is blue. Asked: \(query)")]
        }
        let engine = NativeTaskLocalEngine(database: repository.database, admission: { .local(arbiter) }, pollSeconds: 0.05,
            workers: { exchange in ["research": NativeResearchWorker.make(exchange: exchange, search: search, ownerName: { "Jordan" })] })
        let base: @Sendable () -> URL? = { NativeTaskLocalEngine.identity.base }
        let service = NativeTaskHandoffService(repository: repository, client: engine.client, configuredBase: base)
        let tracker = NativeTaskTracker(repository: repository, client: engine.client, service: service,
                                        transport: engine.transport, configuredBase: base)
        let profile = NativeTaskProfileBinding(id: UUID().uuidString, profileID: "fixture-profile",
            provider: try NativeTaskEngineIdentity(URL(string: "https://provider.test/v1")!),
            savedModel: "fixture-model", executionModel: "fixture-model", limits: try NativeTaskGenerationLimits(maximumRequests: 4))
        let broker = NativeTaskGenerationBroker(repository: repository, client: engine.client, configuredBase: base,
            isProfileAvailable: { _ in true }, generate: { _, job in
                await counter.bump("generate:\(job.phase)")
                return try await generate(job)
            })
        return NativeTaskEngineHarness(repository: repository, engine: engine, service: service, tracker: tracker,
                                       broker: broker, counter: counter, profile: profile, loops: NativeTaskEngineLoops())
    }

    func start() async throws {
        try await engine.start()
        let tracker = self.tracker
        let broker = self.broker
        let service = self.service
        loops.tasks = [
            Task { while !Task.isCancelled { await tracker.tick(); try? await Task.sleep(for: .milliseconds(40)) } },
            Task { while !Task.isCancelled { await broker.poll(); try? await Task.sleep(for: .milliseconds(40)) } },
            Task { while !Task.isCancelled { await service.recoverPending(); try? await Task.sleep(for: .milliseconds(200)) } },
        ]
    }

    func stop() async {
        loops.tasks.forEach { $0.cancel() }
        loops.tasks = []
        await tracker.stop()
        await engine.stop()
    }

    func crash() async {
        loops.tasks.forEach { $0.cancel() }
        loops.tasks = []
        await engine.abandon()
    }

    func submit(_ objective: String) async throws -> NativeTaskReference {
        let origin = try NativeTaskFixture.origin(repository)
        let request = try NativeResearchTaskRequest(objective: objective, deliverables: ["A cited answer"])
        return try await service.submit(origin: origin, request: request, profile: profile)
    }

    func state(_ reference: NativeTaskReference) throws -> NativeTaskState? {
        try repository.taskProjection(id: reference.id)?.snapshot?.state
    }

    @MainActor
    func wait(seconds: Double = 10, _ condition: @MainActor () throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try condition()
    }

    @MainActor
    func waitAsync(seconds: Double = 10, _ condition: @MainActor () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try await condition()
    }
}

@MainActor
extension SelfTest {
    static func runTaskEngine() async throws {
        try await taskStoreContract()
        try await taskDispatcherContract()
        try await taskExchangeContract()
        try await taskRouterContract()
        try await taskEndToEnd()
        try await taskArbiterContract()
        print("  task engine OK (store, dispatcher, exchange, router, cards end to end, cancel, retry, relaunch, admission)")
    }

    private static func researchPayload(_ query: String = "What color is the fictional moon Luma?") throws -> Data {
        let request = try NativeResearchTaskRequest(objective: query, deliverables: ["A cited answer"])
        let binding = NativeTaskAdmissionBinding(id: "binding-1", admissionBase: URL(string: "https://provider.test/v1")!,
                                                 enrollmentDigest: String(repeating: "a", count: 64))
        return try nativeTaskEncoded(NativeResearchTaskPayload(request: request, nativeBinding: binding))
    }

    private static func taskStoreContract() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let store = NativeTaskStore(database: repository.database)
        let payload = try researchPayload()
        let created = try store.create(workerType: "research", payload: payload, idempotencyKey: "key-1")
        try require(created.state == .queued && created.generation == 0, "A new task is queued")
        try require(try store.create(workerType: "research", payload: payload, idempotencyKey: "key-1").id == created.id, "The same key and data return the same task")
        do {
            _ = try store.create(workerType: "research", payload: try researchPayload("Other question"), idempotencyKey: "key-1")
            throw NativeTaskFixture.Failure.assertion("Different data under a used key must conflict")
        } catch NativeTaskStoreError.conflict {}
        do { _ = try store.get("missing"); throw NativeTaskFixture.Failure.assertion("Missing task must be not found") }
        catch NativeTaskStoreError.notFound {}
        let snapshot = try JSONDecoder().decode(NativeTaskSnapshot.self, from: try created.snapshotJSON())
        try require(snapshot.id == created.id && snapshot.state == .queued && snapshot.payload.query == "What color is the fictional moon Luma?", "Snapshots decode with the card model")
        try require(try store.events().count == 1 && (try store.events().first?.kind) == "created", "Creation writes one event")
        try require(try store.latestEventID() == 1, "The latest event id follows the log")

        let claimed = try store.claim(workerTypes: ["research"])
        try require(claimed?.state == .running && claimed?.generation == 1, "Claiming runs the task with a new generation")
        try require(try store.claim(workerTypes: ["research"]) == nil, "Only one task runs at a time")
        do {
            _ = try store.commitStep(created.id, generation: 0, step: NativeTaskStepResult())
            throw NativeTaskFixture.Failure.assertion("A stale generation must not commit")
        } catch NativeTaskStoreError.conflict {}
        let checkpoint = try NativeTaskStore.canonical(["phase": "gather"])
        let progressed = try store.commitStep(created.id, generation: 1, step: NativeTaskStepResult(state: .queued, checkpoint: checkpoint))
        try require(progressed.state == .queued && progressed.checkpoint == checkpoint, "A step commits its checkpoint")

        let running = try store.claim(workerTypes: ["research"])!
        let requested = try store.cancel(created.id)
        try require(requested.state == .running && requested.cancelRequested, "Canceling a running task requests the cancel")
        let finished = try store.commitStep(created.id, generation: running.generation, step: NativeTaskStepResult(state: .queued, checkpoint: checkpoint))
        try require(finished.state == .canceled, "The next commit finishes the cancel")
        try require(try store.cancel(created.id).state == .canceled, "Canceling a terminal task is a no-op")

        let second = try store.create(workerType: "research", payload: payload, idempotencyKey: "key-2")
        try require(try store.cancel(second.id).state == .canceled, "Canceling a queued task finishes immediately")

        let third = try store.create(workerType: "research", payload: payload, idempotencyKey: "key-3")
        let claimedThird = try store.claim(workerTypes: ["research"])!
        try require(claimedThird.id == third.id, "The next queued task is claimed in order")
        let decision = try NativeTaskStore.canonical(["prompt": "Retry this step?", "choices": ["retry"]])
        let waiting = try store.commitStep(third.id, generation: claimedThird.generation,
            step: NativeTaskStepResult(state: .needsDecision, checkpoint: checkpoint, decision: decision))
        let decisionID = waiting.decisionID()!
        try require(waiting.state == .needsDecision && !decisionID.isEmpty, "A decision pause records a decision id")
        let reply = try NativeTaskStore.canonical(["action": "retry"])
        do {
            _ = try store.respond(third.id, decisionID: "other", replyKey: "r1", reply: reply)
            throw NativeTaskFixture.Failure.assertion("A reply to another decision must conflict")
        } catch NativeTaskStoreError.conflict {}
        let resumed = try store.respond(third.id, decisionID: decisionID, replyKey: "r1", reply: reply)
        try require(resumed.state == .queued && resumed.decisionReply == reply, "A reply queues the task with the reply saved")
        try require(try store.respond(third.id, decisionID: decisionID, replyKey: "r1", reply: reply).state == .queued, "The same reply replays")
        do {
            _ = try store.respond(third.id, decisionID: decisionID, replyKey: "r2", reply: reply)
            throw NativeTaskFixture.Failure.assertion("A different reply key must conflict")
        } catch NativeTaskStoreError.conflict {}
        try require(try store.events(taskID: third.id).map(\.kind) == ["created", "started", "progress", "decision_received"], "The decision is in the event log")
        let answer = try NativeTaskStore.object(try store.events(taskID: third.id).last!.data)
        try require(answer["decision_id"] as? String == decisionID && (answer["reply"] as? [String: Any])?["action"] as? String == "retry", "The answer itself is recorded in the event log")

        do { _ = try store.resume(third.id); throw NativeTaskFixture.Failure.assertion("Only blocked tasks resume") }
        catch NativeTaskStoreError.conflict {}
        let claimedAgain = try store.claim(workerTypes: ["research"])!
        _ = try store.commitStep(third.id, generation: claimedAgain.generation, step: NativeTaskStepResult(state: .blocked,
            checkpoint: try NativeTaskStore.canonical(["native_unavailable": "binding-1"])))
        do {
            _ = try store.resume(third.id, checkpointMatch: ["native_unavailable": "other"])
            throw NativeTaskFixture.Failure.assertion("A different block reason must not resume")
        } catch NativeTaskStoreError.conflict {}
        try require(try store.resume(third.id, checkpointMatch: ["native_unavailable": "binding-1"]).state == .queued, "A matching block reason resumes")

        let fresh = NativeTaskStore(database: try LocalChatRepository(inMemory: true).database)
        let fourth = try fresh.create(workerType: "research", payload: payload, idempotencyKey: "key-4")
        try require(try fresh.claim(workerTypes: ["research"])?.generation == 1, "The fresh task is claimed")
        let recovered = try fresh.recover()
        let afterRecover = try fresh.get(fourth.id)
        try require(recovered == 1 && afterRecover.state == .queued && afterRecover.generation == 2, "Recovery requeues a running task with a new generation")
        try require(try fresh.events(taskID: fourth.id).map(\.kind) == ["created", "started", "recovered"], "Recovery is logged")
        _ = try fresh.claim(workerTypes: ["research"])
        _ = try fresh.cancel(fourth.id)
        try require(try fresh.recover() == 1 && (try fresh.get(fourth.id)).state == .canceled, "Recovery finishes a requested cancel")
        try require(try store.get(third.id).state == .queued, "Other tasks keep their records")
        do {
            try await repository.database.write { db in try db.execute(sql: "UPDATE native_engine_task_events SET kind = 'x'") }
            throw NativeTaskFixture.Failure.assertion("Events must be append-only")
        } catch let error as DatabaseError where error.message?.contains("append-only") == true {}
    }

    private static func taskDispatcherContract() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let store = NativeTaskStore(database: repository.database)
        let payload = try researchPayload()
        let dispatcher = NativeTaskDispatcher(store: store, workers: [
            "slow": NativeTaskWorker(timeoutSeconds: 0.2) { _ in try await Task.sleep(for: .seconds(5)); return NativeTaskStepResult() },
            "broken": NativeTaskWorker(timeoutSeconds: 5) { _ in throw NativeTaskStoreError.invalid("boom") },
            "effect": NativeTaskWorker(timeoutSeconds: 5) { task in
                let checkpoint = (try? NativeTaskStore.object(task.checkpoint)) ?? [:]
                let effects = (checkpoint["effects"] as? Int ?? 0) + 1
                if effects >= 2 { return NativeTaskStepResult(state: .completed, checkpoint: try NativeTaskStore.canonical(["effects": effects]),
                                                            result: try NativeTaskStore.canonical(["effects": effects]), event: "completed") }
                return NativeTaskStepResult(state: .queued, checkpoint: try NativeTaskStore.canonical(["effects": effects]))
            },
        ], pollSeconds: 0.02, graceSeconds: 0.2)
        let slow = try store.create(workerType: "slow", payload: payload, idempotencyKey: "slow")
        let broken = try store.create(workerType: "broken", payload: payload, idempotencyKey: "broken")
        try await dispatcher.start()
        let settled = try await poll(seconds: 5) { try store.get(slow.id).state == .failed && (try store.get(broken.id)).state == .failed }
        try require(settled, "Timed out and failing steps both end failed")
        let reasons = try [slow, broken].map { try NativeTaskStore.object(try store.events(taskID: $0.id).last!.data)["reason"] as? String }
        try require(reasons == ["step_timeout", "worker_error"], "Failure reasons are recorded in the event log")
        await dispatcher.stop()

        let effect = try store.create(workerType: "effect", payload: payload, idempotencyKey: "effect")
        let first = NativeTaskDispatcher(store: store, workers: [
            "effect": NativeTaskWorker(timeoutSeconds: 5) { task in
                try await Task.sleep(for: .milliseconds(150))
                return NativeTaskStepResult(state: .queued, checkpoint: try NativeTaskStore.canonical(["effects": 1]))
            },
        ], pollSeconds: 0.02, graceSeconds: 0.5)
        try await first.start()
        _ = try await poll(seconds: 2) { try store.get(effect.id).state == .running }
        await first.stop()
        let afterKill = try store.get(effect.id)
        try require(afterKill.state == .queued && afterKill.generation == 2, "Stopping mid-step leaves the task queued for a relaunch")
        try require(try NativeTaskStore.object(afterKill.checkpoint).isEmpty, "An interrupted step commits nothing")
        try await dispatcher.start()
        try require(try await poll(seconds: 5) { try store.get(effect.id).state == .completed }, "A relaunch resumes the task")
        try require(try NativeTaskStore.object(try store.get(effect.id).result!)["effects"] as? Int == 2, "The resumed task counts only its own completed steps")
        await dispatcher.stop()

        let stubborn = NativeTaskLocalEngine(database: try LocalChatRepository(inMemory: true).database, admission: { nil }, pollSeconds: 0.02, graceSeconds: 0.2, workers: { _ in
            ["resistant": NativeTaskWorker(timeoutSeconds: 0.2) { _ in
                let until = ContinuousClock.now.advanced(by: .seconds(2.5))
                while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(20)) }
                return NativeTaskStepResult()
            }]
        })
        let stuck = try stubborn.store.create(workerType: "resistant", payload: payload, idempotencyKey: "stuck")
        try await stubborn.start()
        let timedOut = ContinuousClock.now
        try require(try await poll(seconds: 2) { try stubborn.store.get(stuck.id).state == .failed }, "A step that ignores cancellation still times out")
        try require(nativeTaskSeconds(timedOut.duration(to: .now)) < 0.9, "The timeout is recorded before the step exits")
        try require(try NativeTaskStore.object(try stubborn.store.events(taskID: stuck.id).last!.data)["reason"] as? String == "step_timeout", "The reason is step_timeout")
        try await Task.sleep(for: .milliseconds(300))
        try require(await stubborn.dispatcher.failure != nil, "The dispatcher pauses while the step lingers")
        await stubborn.stop()
        try require(stubborn.lock.isHeld, "Ownership is retained until the lingering step exits")
        do { try await stubborn.start(); throw NativeTaskFixture.Failure.assertion("A restart during retirement must be refused") }
        catch NativeTaskStoreError.conflict {}
        let rival = NativeTaskLocalEngine(database: stubborn.store.database, admission: { nil })
        do { try await rival.start(); throw NativeTaskFixture.Failure.assertion("A rival cannot start while a step lingers") }
        catch NativeTaskStoreError.conflict {}
        try require(try await poll(seconds: 5) { !stubborn.lock.isHeld }, "Ownership is released once the step exits")
        try await stubborn.start()
        try require(await stubborn.isRunning, "The engine restarts after retirement")
        await stubborn.stop()

        let relaunching = NativeTaskLocalEngine(database: try LocalChatRepository(inMemory: true).database, admission: { nil }, pollSeconds: 0.02, graceSeconds: 0.2, workers: { _ in
            ["resistant": NativeTaskWorker(timeoutSeconds: 0.2) { _ in
                let until = ContinuousClock.now.advanced(by: .seconds(0.8))
                while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(20)) }
                return NativeTaskStepResult()
            }, "quick": NativeTaskWorker(timeoutSeconds: 5) { _ in NativeTaskStepResult(state: .completed, event: "completed") }]
        })
        let lingering = try relaunching.store.create(workerType: "resistant", payload: payload, idempotencyKey: "lingering")
        try await relaunching.start()
        try require(try await poll(seconds: 2) { try relaunching.store.get(lingering.id).state == .failed }, "The lingering step times out")
        let quick = try relaunching.store.create(workerType: "quick", payload: payload, idempotencyKey: "quick")
        try require(try await poll(seconds: 4) { try relaunching.store.get(quick.id).state == .completed }, "Dispatch resumes on its own once the lingering step exits")
        try require(relaunching.lock.isHeld, "The engine keeps ownership across an automatic relaunch")
        await relaunching.stop()
        try require(!relaunching.lock.isHeld, "Stop releases ownership after the relaunch")

        for _ in 0..<4 {
            let racing = NativeTaskLocalEngine(database: try LocalChatRepository(inMemory: true).database, admission: { nil }, pollSeconds: 0.02, graceSeconds: 0.15, workers: { _ in
                ["resistant": NativeTaskWorker(timeoutSeconds: 0.1) { _ in
                    let until = ContinuousClock.now.advanced(by: .seconds(0.3))
                    while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(10)) }
                    return NativeTaskStepResult()
                }]
            })
            _ = try racing.store.create(workerType: "resistant", payload: payload, idempotencyKey: "racing")
            try await racing.start()
            try await Task.sleep(for: .milliseconds(120))
            await racing.stop()
            try require(try await poll(seconds: 3) { !racing.lock.isHeld }, "A retirement that lands during stop still releases the lock")
            try await racing.start()
            try require(await racing.isRunning, "The engine restarts after a retirement that raced its stop")
            await racing.stop()
        }

        weak var disposedDispatcher: NativeTaskDispatcher?
        weak var disposedStore: NativeTaskStore?
        do {
            let disposable = NativeTaskLocalEngine(database: try LocalChatRepository(inMemory: true).database, admission: { nil }, pollSeconds: 0.02)
            disposedDispatcher = disposable.dispatcher
            disposedStore = disposable.store
            try await disposable.start()
            await disposable.stop()
        }
        for _ in 0..<20 where disposedDispatcher != nil { try await Task.sleep(for: .milliseconds(20)) }
        try require(disposedDispatcher == nil && disposedStore == nil, "A stopped engine is released with its dispatcher and store")

        let contended = NativeTaskLocalEngine(database: try LocalChatRepository(inMemory: true).database, admission: { nil }, pollSeconds: 0.02)
        for _ in 0..<5 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<3 { group.addTask { try await contended.start() } }
                group.addTask { await contended.stop() }
                group.addTask { try await contended.start() }
                try await group.waitForAll()
            }
            await contended.stop()
            try require(!contended.lock.isHeld, "Overlapping starts and stops settle to a clean stop")
            try require(await !contended.dispatcher.isRunning, "The dispatcher is stopped after overlapping calls")
        }
        try await contended.start()
        try require(await contended.isRunning && contended.lock.isHeld, "The engine starts cleanly after contention")
        await contended.stop()
    }

    private static func poll(seconds: Double, _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try condition()
    }

    private static func taskExchangeContract() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let store = NativeTaskStore(database: repository.database)
        let arbiter = NativeInferenceArbiter(cooldown: 0)
        let exchange = NativeTaskGenerationExchange(store: store, admission: { .local(arbiter) })
        let task = try store.claim(workerTypes: ["research"]) ?? {
            _ = try store.create(workerType: "research", payload: try researchPayload(), idempotencyKey: "x")
            return try store.claim(workerTypes: ["research"])!
        }()
        let binding = NativeTaskGenerationExchange.binding(of: task)!
        let messages = [NativeTaskGenerationMessage(role: "user", content: "Plan")]
        do {
            _ = try await exchange.complete(task: task, binding: binding, phase: "plan", attempt: "initial", ordinal: 0, messages: messages)
            throw NativeTaskFixture.Failure.assertion("Without presence a model call must not be issued")
        } catch is NativeTaskExecutorUnavailable {}
        do {
            _ = try await exchange.ready(taskID: task.id, binding: NativeTaskAdmissionBinding(id: "other", admissionBase: binding.admissionBase, enrollmentDigest: binding.enrollmentDigest))
            throw NativeTaskFixture.Failure.assertion("A mismatched binding must be refused")
        } catch let status as NativeTaskLocalStatus { try require(status.code == 409, "Binding mismatch is a conflict") }
        let idle = try await exchange.ready(taskID: task.id, binding: binding)
        try require(idle == nil, "Ready without a pending job delivers nothing")
        do {
            _ = try await exchange.complete(task: task, binding: binding, phase: "plan", attempt: "initial", ordinal: 4, messages: messages)
            throw NativeTaskFixture.Failure.assertion("The per-step request limit holds")
        } catch let failure as NativeTaskGenerationFailure { try require(failure.code == "request_limit", "Over the limit is request_limit") }
        let worker = Task { try await exchange.complete(task: task, binding: binding, phase: "plan", attempt: "initial", ordinal: 0, messages: messages) }
        var job: NativeTaskGenerationJob?
        for _ in 0..<40 where job == nil {
            try await Task.sleep(for: .milliseconds(25))
            job = try await exchange.ready(taskID: task.id, binding: binding)
        }
        try require(job != nil && job?.phase == "plan" && job?.attempt == "initial-0" && job?.messages == messages, "The broker receives the pending job")
        let wrong = NativeTaskGenerationResponse(jobID: job!.id, bindingID: job!.bindingID, generation: job!.generation + 1,
                                                 messagesDigest: job!.messagesDigest, response: "late", failure: nil)
        do { try await exchange.result(taskID: task.id, body: wrong); throw NativeTaskFixture.Failure.assertion("A stale generation result is refused") }
        catch let status as NativeTaskLocalStatus { try require(status.code == 409, "Stale result is a conflict") }
        try await exchange.result(taskID: task.id, body: NativeTaskGenerationResponse(jobID: job!.id, bindingID: job!.bindingID,
            generation: job!.generation, messagesDigest: job!.messagesDigest, response: "{\"subquestions\":[\"Q\"]}", failure: nil))
        let delivered = try await worker.value
        try require(delivered == "{\"subquestions\":[\"Q\"]}", "The worker receives the delivered text")
    }

    private static func taskRouterContract() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let engine = NativeTaskLocalEngine(database: repository.database, admission: { nil }, workers: { _ in
            ["research": NativeTaskWorker(timeoutSeconds: 1) { _ in NativeTaskStepResult() }]
        })
        let base = NativeTaskLocalEngine.identity.base
        let body = try NativeTaskStore.canonical(["worker_type": "research", "payload": try NativeTaskStore.object(try researchPayload()), "idempotency_key": "r1"])
        let (created, status) = try await engine.client.request("POST", base.appendingPathComponent("tasks"), body, 5)
        try require(status == 201, "Creation answers 201")
        let snapshot = try JSONDecoder().decode(NativeTaskSnapshot.self, from: created)
        let (fetched, fetchStatus) = try await engine.client.request("GET", base.appendingPathComponent("tasks/\(snapshot.id)"), nil, 5)
        try require(fetchStatus == 200 && (try JSONDecoder().decode(NativeTaskSnapshot.self, from: fetched)).id == snapshot.id, "Fetch answers the snapshot")
        try require(try await engine.client.request("GET", base.appendingPathComponent("tasks/nope"), nil, 5).1 == 404, "Unknown tasks are 404")
        try require(try await engine.client.request("POST", base.appendingPathComponent("tasks"), Data("{}".utf8), 5).1 == 422, "Invalid bodies are 422")
        try require(try await engine.client.request("POST", base.appendingPathComponent("tasks"), try NativeTaskStore.canonical(["worker_type": "document", "payload": [:], "idempotency_key": "d"]), 5).1 == 503, "Unregistered workers are 503")
        try require(try await engine.client.request("POST", base.appendingPathComponent("tasks/\(snapshot.id)/decision"), try NativeTaskStore.canonical(["decision_id": "x", "idempotency_key": "k", "reply": ["action": "retry"]]), 5).1 == 409, "A reply without a pending decision is 409")
        try require(try await engine.client.request("GET", base.appendingPathComponent("other"), nil, 5).1 == 404, "Unknown routes are 404")
        let (canceled, cancelStatus) = try await engine.client.request("POST", base.appendingPathComponent("tasks/\(snapshot.id)/cancel"), Data("{}".utf8), 5)
        try require(cancelStatus == 200 && (try JSONDecoder().decode(NativeTaskSnapshot.self, from: canceled)).state == .canceled, "Cancel answers the canceled snapshot")
        var received: [Int64] = []
        for try await event in engine.transport.events(NativeTaskLocalEngine.identity, 0) {
            received.append(event.id)
            if received.count == 2 { break }
        }
        try require(received == [1, 2], "The event stream replays from the cursor")
        do {
            for try await _ in engine.transport.events(NativeTaskLocalEngine.identity, 50) { break }
            throw NativeTaskFixture.Failure.assertion("A cursor ahead of the log must fail")
        } catch NativeTaskHTTPError.status(409) {}
    }

    private static func taskEndToEnd() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let harness = try NativeTaskEngineHarness.make(repository: repository, counter: counter) { job in
            job.phase == "plan" ? "{\"subquestions\": [\"What is Luma?\", \"Why is Luma blue?\"]}"
                : "Luma is a blue moon [1].\n\nFindings: it stays blue [2].\n\nSources\n[1] Fictional moon guide\n[2] Fictional moon guide"
        }
        try await harness.start()
        let reference = try await harness.submit("What color is the fictional moon Luma?")
        try require(reference.deliveryState == .accepted && reference.remoteTaskID != nil, "The handoff is accepted by the local engine")
        try require(try await harness.wait { try harness.state(reference) == .completed }, "The research task completes through the cards")
        let projection = try repository.taskProjection(id: reference.id)!
        try require(projection.snapshot?.result?.report.contains("[1]") == true && projection.snapshot?.result?.sources.count == 2, "The card holds the cited report")
        let plans = await counter.count("generate:plan")
        let syntheses = await counter.count("generate:synthesize")
        let searches = await counter.count("search")
        try require(plans == 1 && syntheses == 1 && searches == 2, "One plan, two searches, one synthesis")
        let message = try repository.messages(conversationID: reference.origin.conversationID).last!
        let kinds = message.displayBlocks.map { block -> String in
            switch block {
            case .taskCard: return "card"
            case .artifact: return "artifact"
            case .link: return "link"
            }
        }
        try require(message.id == reference.origin.assistantMessageID && kinds == ["card", "artifact"], "The original reply carries the card and the report")
        let repeated = try await harness.service.submit(origin: reference.origin, request: reference.request, profile: harness.profile)
        try require(repeated.id == reference.id, "A repeated handoff reuses its task")
        await harness.stop()

        let cancelRepository = try LocalChatRepository(inMemory: true)
        let cancelHarness = try NativeTaskEngineHarness.make(repository: cancelRepository, counter: NativeTaskEngineCounter()) { _ in
            try await Task.sleep(for: .seconds(30))
            return ""
        }
        try await cancelHarness.start()
        let stopped = try await cancelHarness.submit("Slow research")
        try require(try await cancelHarness.wait { try cancelHarness.state(stopped) == .running }, "The slow task starts")
        let started = ContinuousClock.now
        await cancelHarness.tracker.cancel(stopped.id)
        try require(try await cancelHarness.wait(seconds: 5) { try cancelHarness.state(stopped) == .canceled }, "Cancel from the card ends the task")
        try require(nativeTaskSeconds(started.duration(to: .now)) < 5, "Cancel lands within the step")
        await cancelHarness.stop()

        let retryRepository = try LocalChatRepository(inMemory: true)
        let retryCounter = NativeTaskEngineCounter()
        let retryHarness = try NativeTaskEngineHarness.make(repository: retryRepository, counter: retryCounter) { job in
            if job.phase == "plan", await retryCounter.count("generate:plan") == 1 { throw NativeTaskGenerationFailure(code: "provider_quota") }
            return job.phase == "plan" ? "{\"subquestions\": [\"Q\"]}" : "Blue [1].\n\nSources\n[1] guide"
        }
        try await retryHarness.start()
        let paused = try await retryHarness.submit("Quota research")
        try require(try await retryHarness.wait { try retryHarness.state(paused) == .needsDecision }, "A provider failure pauses for a decision")
        let card = try retryRepository.taskProjection(id: paused.id)!.snapshot!
        try require(card.decision?.choices == ["retry"] && card.decision?.prompt.contains("usage limit") == true, "The card asks a plain retry question")
        await retryHarness.tracker.retry(paused.id)
        try require(try await retryHarness.wait { try retryHarness.state(paused) == .completed }, "Retry resumes and completes the task")
        let engineTask = try retryHarness.engine.store.get(paused.remoteTaskID!)
        try require(try retryHarness.engine.store.events(taskID: engineTask.id).map(\.kind).contains("decision_received"), "The answer is in the event log")
        await retryHarness.stop()

        let relaunchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let relaunchURL = relaunchDirectory.appendingPathComponent("chat.sqlite")
        let relaunchCounter = NativeTaskEngineCounter()
        let gate = NativeTaskEngineCounter()
        let firstRun = try NativeTaskEngineHarness.make(repository: try LocalChatRepository(url: relaunchURL), counter: relaunchCounter) { job in
            if job.phase == "synthesize" { await gate.bump("synthesize-seen"); try await Task.sleep(for: .seconds(30)) }
            return "{\"subquestions\": [\"Q\"]}"
        }
        try await firstRun.start()
        let survivor = try await firstRun.submit("Relaunch research")
        let reached = try await firstRun.waitAsync { await gate.count("synthesize-seen") >= 1 }
        try require(reached, "The first run reaches synthesis")
        await firstRun.crash()
        let interrupted = try firstRun.engine.store.get(survivor.remoteTaskID!)
        try require(interrupted.state == .running, "A crash leaves the task running in storage")
        let relaunchRepository = try LocalChatRepository(url: relaunchURL)
        let secondRun = try NativeTaskEngineHarness.make(repository: relaunchRepository, counter: relaunchCounter) { job in
            job.phase == "plan" ? "{\"subquestions\": [\"unexpected\"]}" : "Blue [1].\n\nSources\n[1] guide"
        }
        try await secondRun.start()
        try require(try await secondRun.wait { try secondRun.state(survivor) == .needsDecision }, "A relaunch during a model request pauses for an explicit retry")
        let pausedCard = try relaunchRepository.taskProjection(id: survivor.id)!.snapshot!
        try require(pausedCard.decision?.choices == ["retry"] && pausedCard.checkpoint.phase == "synthesize", "The pause keeps the saved step and asks to retry")
        await secondRun.tracker.retry(survivor.id)
        try require(try await secondRun.wait { try secondRun.state(survivor) == .completed }, "The retry finishes the task")
        let relaunchPlans = await relaunchCounter.count("generate:plan")
        let relaunchSearches = await relaunchCounter.count("search")
        try require(relaunchPlans == 1 && relaunchSearches == 1, "Finished steps are not repeated after a relaunch")
        await secondRun.stop()
        try? FileManager.default.removeItem(at: relaunchDirectory)

        for inMemory in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let shared = inMemory ? try LocalChatRepository(inMemory: true) : try LocalChatRepository(url: directory.appendingPathComponent("chat.sqlite"))
            let owner = NativeTaskLocalEngine(database: shared.database, admission: { nil }, workers: { _ in
                ["research": NativeTaskWorker(timeoutSeconds: 5) { _ in try await Task.sleep(for: .seconds(5)); return NativeTaskStepResult() }]
            })
            let rival = NativeTaskLocalEngine(database: shared.database, admission: { nil })
            try await owner.start()
            try await owner.start()
            let busy = try owner.store.create(workerType: "research", payload: try researchPayload(), idempotencyKey: "busy")
            try require(try await poll(seconds: 2) { try owner.store.get(busy.id).state == .running }, "The owner runs the task")
            do { try await rival.start(); throw NativeTaskFixture.Failure.assertion("A second engine on the same database must be refused") }
            catch NativeTaskStoreError.conflict {}
            await rival.stop()
            let afterRivalStop = try owner.store.get(busy.id)
            try require(afterRivalStop.state == .running && afterRivalStop.generation == 1, "A refused engine never recovers the owner's running task")
            await owner.stop()
            try require(try owner.store.get(busy.id).state == .queued, "The owner's stop recovers its own task")
            try await rival.start()
            await rival.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let reservationRepository = try LocalChatRepository(inMemory: true)
        let reservationEngine = NativeTaskLocalEngine(database: reservationRepository.database, admission: { nil })
        let origin = try NativeTaskFixture.origin(reservationRepository)
        let profile = NativeTaskProfileBinding(id: UUID().uuidString, profileID: "fixture-profile",
            provider: try NativeTaskEngineIdentity(URL(string: "https://provider.test/v1")!),
            savedModel: "fixture-model", executionModel: "fixture-model", limits: try NativeTaskGenerationLimits(maximumRequests: 2))
        let reserved = try reservationRepository.prepareTaskReference(origin: origin, engine: NativeTaskLocalEngine.identity,
            request: try NativeResearchTaskRequest(objective: "Reservation", deliverables: ["Report"]), profile: profile, options: .standard)
        let remote = UUID().uuidString.lowercased()
        _ = try reservationRepository.acknowledgeTaskReference(id: reserved.id, snapshot: try JSONDecoder().decode(NativeTaskSnapshot.self, from: try NativeTaskFixture.snapshot(reserved, id: remote)))
        let binding = reserved.createRequest.payload.nativeBinding!
        let messages = [NativeTaskGenerationMessage(role: "user", content: "Reservation")]
        let job = NativeTaskGenerationJob(id: UUID().uuidString, taskID: remote, bindingID: binding.id,
            enrollmentDigest: binding.enrollmentDigest, admissionBase: binding.admissionBase, phase: "plan", attempt: "initial-0",
            messages: messages, messagesDigest: NativeTaskGenerationJob.digest(messages), deadlineSeconds: 60, generation: 1)
        try await reservationEngine.start()
        try require(try reservationRepository.reserveTaskGeneration(referenceID: reserved.id, job: job) == .execute, "A live reservation is taken")
        try await reservationEngine.start()
        try require(try reservationRepository.reserveTaskGeneration(referenceID: reserved.id, job: job) == .pending, "A repeated start leaves a live reservation alone")
        await reservationEngine.stop()
        try await reservationEngine.start()
        try require(try reservationRepository.reserveTaskGeneration(referenceID: reserved.id, job: job) == .unavailable("previous_request_uncertain"), "A fresh start marks the old reservation uncertain")
        await reservationEngine.stop()
    }

    private static func taskArbiterContract() async throws {
        let require = NativeTaskFixture.require
        try require(NativeResearchWorker.citations(in: "A [1] and [01] and [12]").numbers == [1, 12], "Citations normalize leading zeros")
        try require(!NativeResearchWorker.citations(in: "A [1] and [999999999999999999999999999999]").valid, "An overflowing citation is invalid rather than ignored")
        try require(NativeResearchWorker.citations(in: "No [x] citations [ ]").numbers.isEmpty, "Non-numeric brackets are not citations")
        let arbiter = NativeInferenceArbiter(cooldown: 0.2, pollSeconds: 0.01)
        let resource = "endpoint"
        let foreground = try await arbiter.acquire(resource: resource, priority: .foreground, queueSeconds: 1)
        let waiting = Task { try await arbiter.acquire(resource: resource, priority: .background, queueSeconds: 5) }
        try await Task.sleep(for: .milliseconds(100))
        let whileActive = await arbiter.activeCounts(resource: resource)
        try require(whileActive == (1, false), "Background waits while a foreground turn is active")
        let secondForeground = try await arbiter.acquire(resource: resource, priority: .foreground, queueSeconds: 1)
        let twoForeground = await arbiter.activeCounts(resource: resource)
        try require(twoForeground.foreground == 2, "Foreground turns never wait")
        await arbiter.release(foreground)
        await arbiter.release(secondForeground)
        let released = ContinuousClock.now
        let lease = try await waiting.value
        let waited = nativeTaskSeconds(released.duration(to: .now))
        try require(waited >= 0.15 && waited < 2, "Background is admitted after the cooldown")
        let blocked = Task { try await arbiter.acquire(resource: resource, priority: .background, queueSeconds: 0.2) }
        do { _ = try await blocked.value; throw NativeTaskFixture.Failure.assertion("A second background call must wait and give up") }
        catch NativeInferenceAdmission.AdmissionError.deadline {}
        await arbiter.release(lease)
        let cleared = await arbiter.activeCounts(resource: resource)
        try require(cleared == (0, false), "Release clears the lease")
        let admission = NativeInferenceAdmission.local(arbiter)
        let endpoint = URL(string: "https://provider.test/v1")!
        let value: String = try await admission.perform(endpoint: endpoint, priority: .foreground, requestedSeconds: 2) { _ in "ok" }
        let afterWrapper = await arbiter.activeCounts(resource: try NativeInferenceAdmission.resource(for: endpoint))
        try require(value == "ok" && afterWrapper == (0, false), "The admission wrapper releases after the operation")
        do {
            let _: String = try await admission.perform(endpoint: endpoint, priority: .background, requestedSeconds: 0.3) { _ in
                try await Task.sleep(for: .seconds(2)); return "late"
            }
            throw NativeTaskFixture.Failure.assertion("A background operation past its window must fail")
        } catch NativeInferenceAdmission.AdmissionError.deadline {}
        let endpointResource = try NativeInferenceAdmission.resource(for: endpoint)
        var releasedAfterCancel = false
        for _ in 0..<50 where !releasedAfterCancel {
            releasedAfterCancel = !(await arbiter.activeCounts(resource: endpointResource)).background
            if !releasedAfterCancel { try await Task.sleep(for: .milliseconds(50)) }
        }
        try require(releasedAfterCancel, "A canceled operation releases its lease once it stops")

        let holder = Task {
            let _: String = try await admission.perform(endpoint: endpoint, priority: .background, requestedSeconds: 5) { _ in
                let until = ContinuousClock.now.advanced(by: .seconds(0.6))
                while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(20)) }
                return "held"
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let chatStarted = ContinuousClock.now
        let chat: String = try await admission.perform(endpoint: endpoint, priority: .foreground, requestedSeconds: 2) { _ in "answer" }
        try require(chat == "answer" && nativeTaskSeconds(chatStarted.duration(to: .now)) < 0.3, "A chat turn is answered while a background call holds the endpoint")
        let heldWhileRunning = await arbiter.activeCounts(resource: endpointResource)
        try require(heldWhileRunning.background, "The background lease stays held while its operation runs")
        _ = try? await holder.value
        let afterHolder = await arbiter.activeCounts(resource: endpointResource)
        try require(!afterHolder.background, "The lease is released when the operation ends")
    }
}
