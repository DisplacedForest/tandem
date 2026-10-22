import Foundation

struct NativeTaskExecutorUnavailable: Error, Sendable {}

actor NativeTaskGenerationExchange {
    static let failures: Set<String> = ["provider_unavailable", "provider_auth", "provider_quota", "provider_response",
        "canceled", "request_timeout", "profile_changed", "credential_unavailable", "request_conflict",
        "previous_request_uncertain", "request_limit", "input_limit"]
    static let presenceSeconds: Double = 3
    static let maximumPending = 200

    private struct Presence {
        let binding: NativeTaskAdmissionBinding
        let expiry: ContinuousClock.Instant
    }

    private final class Pending {
        let job: NativeTaskGenerationJob
        let deadline: ContinuousClock.Instant
        var delivered = false
        var outcome: NativeTaskGenerationResponse?
        var canceled = false
        init(job: NativeTaskGenerationJob, deadline: ContinuousClock.Instant) {
            self.job = job
            self.deadline = deadline
        }
    }

    let store: NativeTaskStore
    let admission: @Sendable () -> NativeInferenceAdmission?
    private var presence: [String: Presence] = [:]
    private var pending: [String: Pending] = [:]
    private var issued: [String: Pending] = [:]

    init(store: NativeTaskStore, admission: @escaping @Sendable () -> NativeInferenceAdmission?) {
        self.store = store
        self.admission = admission
    }

    static func binding(of task: NativeTaskRecord) -> NativeTaskAdmissionBinding? {
        guard let payload = try? JSONDecoder().decode(NativeResearchTaskPayload.self, from: task.payload) else { return nil }
        return payload.nativeBinding
    }

    private func checkBinding(_ task: NativeTaskRecord, _ body: NativeTaskAdmissionBinding) throws {
        guard NativeResearchTaskRequest.workerTypes.contains(task.workerType), Self.binding(of: task) == body else {
            throw NativeTaskLocalStatus(code: 409, detail: "Native task binding does not match")
        }
        guard !task.cancelRequested, ![.completed, .failed, .canceled, .needsDecision].contains(task.state) else {
            throw NativeTaskLocalStatus(code: 409, detail: "This task cannot request native generation")
        }
    }

    func ready(taskID: String, binding: NativeTaskAdmissionBinding) throws -> NativeTaskGenerationJob? {
        let task = try store.get(taskID)
        try checkBinding(task, binding)
        let now = ContinuousClock.now
        presence = presence.filter { $0.value.expiry > now }
        if presence.count >= Self.maximumPending, presence[taskID] == nil {
            throw NativeTaskLocalStatus(code: 503, detail: "Native generation capacity is full")
        }
        presence[taskID] = Presence(binding: binding, expiry: now.advanced(by: .seconds(Self.presenceSeconds)))
        if task.state == .blocked {
            let checkpoint = (try? NativeTaskStore.object(task.checkpoint)) ?? [:]
            guard (checkpoint["native_unavailable"] as? String) == binding.id else {
                throw NativeTaskLocalStatus(code: 409, detail: "This task is blocked for another reason")
            }
            _ = try store.resume(taskID, expectedGeneration: task.generation, checkpointMatch: ["native_unavailable": binding.id])
        }
        guard let job = pending[taskID], job.deadline > now else { return nil }
        let current = try store.get(taskID)
        guard !current.cancelRequested, current.state == .running, current.generation == job.job.generation else {
            throw NativeTaskLocalStatus(code: 409, detail: "This generation is no longer active")
        }
        let remaining = nativeTaskSeconds(ContinuousClock.now.duration(to: job.deadline))
        guard pending[taskID] === job, remaining > 0, job.outcome == nil else { return nil }
        job.delivered = true
        return NativeTaskGenerationJob(id: job.job.id, taskID: job.job.taskID, bindingID: job.job.bindingID,
            enrollmentDigest: job.job.enrollmentDigest, admissionBase: job.job.admissionBase, phase: job.job.phase,
            attempt: job.job.attempt, messages: job.job.messages, messagesDigest: job.job.messagesDigest,
            deadlineSeconds: remaining, generation: job.job.generation)
    }

    func result(taskID: String, body: NativeTaskGenerationResponse) throws {
        guard (body.response == nil) != (body.failure == nil) else {
            throw NativeTaskLocalStatus(code: 422, detail: "Exactly one generation outcome is required")
        }
        if let failure = body.failure, !Self.failures.contains(failure) {
            throw NativeTaskLocalStatus(code: 422, detail: "Unknown generation failure")
        }
        if let response = body.response, response.utf8.count > 262144 {
            throw NativeTaskLocalStatus(code: 422, detail: "Generation output exceeds its limit")
        }
        let task = try store.get(taskID)
        guard let job = pending[taskID], job.deadline > .now, !task.cancelRequested, task.state == .running,
              task.generation == body.generation, job.job.id == body.jobID, job.job.bindingID == body.bindingID,
              job.job.generation == body.generation, job.job.messagesDigest == body.messagesDigest else {
            throw NativeTaskLocalStatus(code: 409, detail: "This generation is no longer active")
        }
        if let existing = job.outcome {
            guard existing.response == body.response, existing.failure == body.failure else {
                throw NativeTaskLocalStatus(code: 409, detail: "This generation already has a different result")
            }
            return
        }
        job.outcome = body
    }

    func hasPresence(_ taskID: String, binding: NativeTaskAdmissionBinding) -> Bool {
        guard let entry = presence[taskID] else { return false }
        return entry.binding == binding && entry.expiry > .now
    }

    func complete(task: NativeTaskRecord, binding: NativeTaskAdmissionBinding, phase: String, attempt: String,
                  ordinal: Int, messages: [NativeTaskGenerationMessage]) async throws -> String {
        guard ordinal <= 3 else { throw NativeTaskGenerationFailure(code: "request_limit") }
        guard (1...8).contains(messages.count),
              messages.allSatisfy({ ["system", "user", "assistant"].contains($0.role) }) else {
            throw NativeTaskGenerationFailure(code: "provider_response")
        }
        let encoded = try JSONSerialization.data(withJSONObject: messages.map { ["role": $0.role, "content": $0.content] })
        guard encoded.count <= 65536 else { throw NativeTaskGenerationFailure(code: "input_limit") }
        guard hasPresence(task.id, binding: binding) else { throw NativeTaskExecutorUnavailable() }
        let admission = admission() ?? .local()
        issued[task.id] = nil
        defer { issued[task.id] = nil }
        do {
            return try await admission.perform(endpoint: binding.admissionBase, priority: .background, requestedSeconds: 90) { budget in
                try await self.operation(task: task, binding: binding, phase: phase, attempt: "\(attempt)-\(ordinal)",
                                         messages: messages, seconds: min(budget.seconds, 90))
            }
        } catch is NativeInferenceAdmission.AdmissionError {
            if issued[task.id]?.delivered == true { throw NativeTaskGenerationFailure(code: "request_timeout") }
            throw NativeTaskExecutorUnavailable()
        }
    }

    private func operation(task: NativeTaskRecord, binding: NativeTaskAdmissionBinding, phase: String, attempt: String,
                           messages: [NativeTaskGenerationMessage], seconds: Double) async throws -> String {
        guard hasPresence(task.id, binding: binding) else { throw NativeTaskExecutorUnavailable() }
        let job = NativeTaskGenerationJob(id: UUID().uuidString.lowercased(), taskID: task.id, bindingID: binding.id,
            enrollmentDigest: binding.enrollmentDigest, admissionBase: binding.admissionBase, phase: phase,
            attempt: attempt, messages: messages, messagesDigest: NativeTaskGenerationJob.digest(messages),
            deadlineSeconds: seconds, generation: task.generation)
        let entry = Pending(job: job, deadline: .now.advanced(by: .seconds(seconds)))
        issued[task.id] = entry
        pending[task.id] = entry
        defer {
            if pending[task.id] === entry { pending[task.id] = nil }
            entry.canceled = true
        }
        while ContinuousClock.now < entry.deadline {
            try Task.checkCancellation()
            let current = try store.get(task.id)
            guard !current.cancelRequested, current.state == .running, current.generation == task.generation else {
                throw CancellationError()
            }
            if let outcome = entry.outcome {
                if let failure = outcome.failure { throw NativeTaskGenerationFailure(code: failure) }
                return outcome.response ?? ""
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if entry.delivered { throw NativeTaskGenerationFailure(code: "request_timeout") }
        throw NativeTaskExecutorUnavailable()
    }
}
