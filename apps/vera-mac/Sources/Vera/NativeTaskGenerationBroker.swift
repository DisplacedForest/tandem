import Foundation

extension NativeTaskClient {
    func nextGeneration(_ reference: NativeTaskReference) async throws -> NativeTaskGenerationJob? {
        guard let id = reference.remoteTaskID, let binding = reference.createRequest.payload.nativeBinding else { return nil }
        let deliveryStarted = ContinuousClock.now
        let (data, status) = try await request(
            "POST", reference.engine.base.appendingPathComponent("tasks/\(id)/native/ready"),
            try nativeTaskEncoded(binding), 5)
        if status == 204 { return nil }
        guard status == 200 else { throw NativeTaskHTTPError.status(status) }
        let job = try NativeTaskGenerationJob.decode(data)
        try job.validate(reference: reference, enforceInputLimit: false)
        return try job.reducingDeadline(by: nativeTaskSeconds(deliveryStarted.duration(to: .now)))
    }

    func returnGeneration(_ reference: NativeTaskReference, job: NativeTaskGenerationJob,
                          response: String?, failure: String?, toolCalls: [NativeTaskGenerationToolCall]? = nil) async throws {
        let body = NativeTaskGenerationResponse(jobID: job.id, bindingID: job.bindingID,
            generation: job.generation, messagesDigest: job.messagesDigest, response: response, failure: failure,
            toolCalls: toolCalls)
        let (_, status) = try await request(
            "POST", reference.engine.base.appendingPathComponent("tasks/\(job.taskID)/native/result"),
            try nativeTaskEncoded(body), 5)
        guard (200..<300).contains(status) else { throw NativeTaskHTTPError.status(status) }
    }
}

struct NativeTaskGenerationFailure: Error, Sendable {
    let code: String
}

actor NativeTaskGenerationBroker {
    let repository: any NativeTaskGenerationRepository
    let client: NativeTaskClient
    let configuredBase: @Sendable () -> URL?
    let isProfileAvailable: @Sendable (NativeTaskProfileBinding) async -> Bool
    let generate: @Sendable (NativeTaskProfileBinding, NativeTaskGenerationJob) async throws -> NativeTaskGenerationCompletion
    private var active: Set<UUID> = []
    private var decisionRefresh: [UUID: ContinuousClock.Instant] = [:]

    init(repository: any NativeTaskGenerationRepository, client: NativeTaskClient = .live,
         configuredBase: @escaping @Sendable () -> URL?,
         isProfileAvailable: @escaping @Sendable (NativeTaskProfileBinding) async -> Bool,
         complete: @escaping @Sendable (NativeTaskProfileBinding, NativeTaskGenerationJob) async throws -> NativeTaskGenerationCompletion) {
        self.repository = repository
        self.client = client
        self.configuredBase = configuredBase
        self.isProfileAvailable = isProfileAvailable
        self.generate = complete
    }

    init(repository: any NativeTaskGenerationRepository, client: NativeTaskClient = .live,
         configuredBase: @escaping @Sendable () -> URL?,
         isProfileAvailable: @escaping @Sendable (NativeTaskProfileBinding) async -> Bool,
         generate: @escaping @Sendable (NativeTaskProfileBinding, NativeTaskGenerationJob) async throws -> String) {
        self.init(repository: repository, client: client, configuredBase: configuredBase,
                  isProfileAvailable: isProfileAvailable, complete: { profile, job in
                      .text(try await generate(profile, job))
                  })
    }

    func poll() async {
        guard let references = try? repository.taskReferences(conversationID: nil) else { return }
        for reference in references {
            guard !Task.isCancelled else { return }
            if reference.snapshot?.state == .needsDecision {
                if let next = decisionRefresh[reference.id], next > .now { continue }
                decisionRefresh[reference.id] = .now.advanced(by: .seconds(5))
                if let base = configuredBase(), (try? NativeTaskEngineIdentity(base)) == reference.engine,
                   let snapshot = try? await client.fetch(reference) {
                    _ = try? repository.acknowledgeTaskReference(id: reference.id, snapshot: snapshot)
                }
                continue
            }
            guard reference.remoteTaskID != nil, !reference.cancelRequested,
                  reference.snapshot?.state.isTerminal != true, reference.snapshot?.state != .paused, reference.deliveryState == .accepted,
                  !active.contains(reference.id), let profile = reference.profile,
                  let base = configuredBase(), (try? NativeTaskEngineIdentity(base)) == reference.engine,
                  await isProfileAvailable(profile) else { continue }
            active.insert(reference.id)
            await process(reference, profile: profile)
            active.remove(reference.id)
        }
    }

    private func execute(reference: NativeTaskReference, profile: NativeTaskProfileBinding,
                         job: NativeTaskGenerationJob) async throws -> NativeTaskGenerationCompletion {
        let generate = self.generate
        let repository = self.repository
        let configuredBase = self.configuredBase
        let execution = try job.reducingDeadline(by: min(2, job.deadlineSeconds / 10))
        let operation = Task {
            try await NativeInferenceDeadline.run(seconds: job.deadlineSeconds) {
                try await generate(profile, execution)
            }
        }
        let watcher = Task {
            while !Task.isCancelled {
                guard let current = try? repository.taskReference(id: reference.id),
                      !current.cancelRequested, current.snapshot?.state.isTerminal != true, current.snapshot?.held != true,
                      let base = configuredBase(), (try? NativeTaskEngineIdentity(base)) == current.engine else {
                    operation.cancel()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { watcher.cancel() }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
            watcher.cancel()
        }
    }

    private func process(_ reference: NativeTaskReference, profile: NativeTaskProfileBinding) async {
        do {
            guard let delivered = try await client.nextGeneration(reference) else { return }
            let deliveryFinished = ContinuousClock.now
            guard !Task.isCancelled,
                  let current = try repository.taskReference(id: reference.id), !current.cancelRequested,
                  let base = configuredBase(), (try? NativeTaskEngineIdentity(base)) == current.engine,
                  await isProfileAvailable(profile) else { return }
            let job = try delivered.reducingDeadline(by: nativeTaskSeconds(deliveryFinished.duration(to: .now)))
            let started = ContinuousClock.now
            do { try job.validate(reference: current) }
            catch let error as NativeTaskGenerationFailure {
                try await client.returnGeneration(current, job: job, response: nil, failure: error.code)
                return
            }
            let live = try await client.fetch(current)
            guard !live.held, !live.cancelRequested, live.state == .running else { return }
            let reservation = try repository.reserveTaskGeneration(referenceID: reference.id, job: job)
            let completion: NativeTaskGenerationCompletion?
            let failure: String?
            switch reservation {
            case .pending:
                return
            case .completed(let text):
                if let restored = try? NativeTaskGenerationCompletion.restored(text, job: job) {
                    completion = restored
                    failure = nil
                } else {
                    completion = nil
                    failure = "previous_request_uncertain"
                }
            case .unavailable(let reason):
                completion = nil
                failure = reason
            case .execute:
                do {
                    let execution = try job.reducingDeadline(by: nativeTaskSeconds(started.duration(to: .now)))
                    let result = try await execute(reference: reference, profile: profile, job: execution).validated(for: job)
                    guard !Task.isCancelled else { throw CancellationError() }
                    let stored = try result.stored(for: job)
                    guard started.duration(to: .now) < .seconds(job.deadlineSeconds),
                          stored.utf8.count <= 262144 else {
                        throw NativeTaskGenerationFailure(code: "request_timeout")
                    }
                    try repository.finishTaskGeneration(referenceID: reference.id, job: job, response: stored, failure: nil)
                    completion = result
                    failure = nil
                } catch {
                    let code: String
                    if error is CancellationError { code = "canceled" }
                    else if let known = error as? NativeTaskGenerationFailure { code = known.code }
                    else if error is NativeInferenceAdmission.AdmissionError { code = "request_timeout" }
                    else { code = "provider_unavailable" }
                    try repository.finishTaskGeneration(referenceID: reference.id, job: job, response: nil, failure: code)
                    completion = nil
                    failure = code
                }
            }
            guard let current = try repository.taskReference(id: reference.id), !current.cancelRequested,
                  let base = configuredBase(), (try? NativeTaskEngineIdentity(base)) == current.engine else { return }
            try await client.returnGeneration(current, job: job, response: completion?.content, failure: failure,
                                              toolCalls: job.tools == nil ? nil : completion?.toolCalls)
        } catch NativeTaskHTTPError.status(409) {
            if let snapshot = try? await client.fetch(reference) {
                _ = try? repository.acknowledgeTaskReference(id: reference.id, snapshot: snapshot)
            }
        } catch {}
    }
}

func nativeTaskSeconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}
