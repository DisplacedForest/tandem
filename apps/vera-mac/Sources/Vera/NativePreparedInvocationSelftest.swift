import Foundation

enum NativePreparedInvocationSelftest {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "PreparedInvocationSelftest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func binding(operationID: String = "operation-one", arguments: String = "{\"value\":\"Synthetic café / value\"}") -> NativePreparedToolInvocation {
        .init(hostOriginID: "explicit-chat-origin", operationID: operationID, assistantID: "assistant", conversationID: "conversation", serverID: "synthetic", endpoint: "https://fixture.invalid/mcp", tool: "fixture.record", schemaJSON: "{\"additionalProperties\":false,\"properties\":{\"value\":{\"maxLength\":200,\"type\":\"string\"}},\"required\":[\"value\"],\"type\":\"object\"}", argumentsJSON: arguments, permissionRevision: "permission-one", authorizationGeneration: "authorization-one", expiresAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000) + 60_000)
    }

    static func run() async throws {
        let binding = binding()
        let repository = NativePreparedInvocationMemoryFixture()
        let coordinator = NativePreparedInvocationCoordinator(repository: repository, scope: binding.scope)
        let focused = NativePreparedFocusedFixtureConsumer(coordinator: coordinator)
        let pi = NativePreparedPiFixtureConsumer(coordinator: coordinator)
        let clock = ContinuousClock()
        let start = clock.now
        let first = try await focused.submit(hostPrepared: binding)
        let second = try await pi.submit(hostPrepared: binding)
        try require(first == second && first.phase == "awaiting_decision", "Shared consumers must retain one pending identity")
        try require(start.duration(to: clock.now) < .seconds(2), "Preparation must not wait for a decision")
        let independent = try await coordinator.prepare(Self.binding(operationID: "foreground-second"))
        try require(independent.taskID != first.taskID, "A pending decision must not block a second foreground request")
        let approved = try await coordinator.respond(review: first, replyID: "host-reply", approved: true, host: repository)
        try require(approved.phase == "ready", "Explicit host approval should unlock only its prepared invocation")
        let canceled = try await coordinator.cancel(taskID: approved.taskID)
        try require(canceled.phase == "canceled", "Cancel should retain task identity")
        var changed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as! [String: Any]
        changed["argumentsJSON"] = "{\"value\":\"changed\"}"
        let mutation = try JSONDecoder().decode(NativePreparedToolInvocation.self, from: JSONSerialization.data(withJSONObject: changed))
        do {
            _ = try await coordinator.prepare(mutation)
            throw NSError(domain: "PreparedInvocationSelftest", code: 2)
        } catch NativePreparedInvocationError.invalidBinding {}
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        for (state, phase, result) in [("completed", "ready", false), ("canceled", "ready", false), ("needs_decision", "effect_completed", true), ("blocked", "effect_completed", false)] {
            object["state"] = state
            object["phase"] = phase
            object["decisionID"] = state == "needs_decision" ? first.decisionID! : NSNull()
            object["result"] = result ? ["status": "completed", "summary": "synthetic"] : NSNull()
            let malformed = try JSONDecoder().decode(NativePreparedInvocationReceipt.self, from: JSONSerialization.data(withJSONObject: object))
            do {
                try malformed.validate(scope: binding.scope)
                throw NSError(domain: "PreparedInvocationSelftest", code: 3)
            } catch NativePreparedInvocationError.invalidReceipt {}
        }
        let held = try await coordinator.prepare(Self.binding(operationID: "held-approval"))
        await repository.holdNextApproval()
        let operation = Task { try await coordinator.respond(review: held, replyID: "held-reply", approved: true, host: repository) }
        try await waitForAcceptance(repository)
        operation.cancel()
        let cancellationDeadline = ContinuousClock.now + .seconds(5)
        while try await repository.inspect(scope: held.binding.scope, taskID: held.taskID).phase != "canceled" {
            guard ContinuousClock.now < cancellationDeadline else { throw NativePreparedInvocationError.unavailable }
            try await Task.sleep(for: .milliseconds(5))
        }
        await repository.releaseApproval()
        do {
            _ = try await operation.value
            throw NSError(domain: "PreparedInvocationSelftest", code: 4)
        } catch is CancellationError {}
        let afterCancellation = try await coordinator.inspect(taskID: held.taskID)
        try require(afterCancellation.phase == "canceled", "An accepted but canceled approval must cancel the durable task")
        let failure = try await coordinator.prepare(Self.binding(operationID: "approval-response-lost"))
        await repository.failNextApprovalResponse()
        do {
            _ = try await coordinator.respond(review: failure, replyID: "lost-reply", approved: true, host: repository)
            throw NSError(domain: "PreparedInvocationSelftest", code: 5)
        } catch NativePreparedInvocationError.unavailable {}
        let afterFailure = try await coordinator.inspect(taskID: failure.taskID)
        try require(afterFailure.phase == "canceled", "A failed approval response must not leave an executable task")
        print("PASS prepared invocation coordinator, shared consumers, immutable receipts, and approval cancellation")
    }

    private static func waitForAcceptance(_ repository: NativePreparedInvocationMemoryFixture) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await repository.approvalAccepted) {
            guard ContinuousClock.now < deadline else { throw NativePreparedInvocationError.unavailable }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor NativePreparedInvocationMemoryFixture: NativePreparedInvocationRepository, NativePreparedInvocationDecisionHost {
    private var receipts: [String: NativePreparedInvocationReceipt] = [:]
    private var hold = false
    private var fail = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var approvalAccepted = false

    func holdNextApproval() { hold = true; approvalAccepted = false }
    func failNextApprovalResponse() { fail = true }
    func releaseApproval() { continuation?.resume(); continuation = nil }

    func prepare(_ binding: NativePreparedToolInvocation) throws -> NativePreparedInvocationReceipt {
        if let prior = receipts.values.first(where: { $0.binding.operationID == binding.operationID }) {
            guard prior.binding == binding else { throw NativePreparedInvocationError.invalidBinding }
            return prior
        }
        let receipt = NativePreparedInvocationReceipt(taskID: UUID().uuidString, binding: binding, bindingDigest: binding.digest, state: "needs_decision", phase: "awaiting_decision", decisionID: UUID().uuidString, result: nil)
        receipts[receipt.taskID] = receipt
        return receipt
    }

    func inspect(scope: NativePreparedInvocationScope, taskID: String) throws -> NativePreparedInvocationReceipt {
        guard let receipt = receipts[taskID], receipt.binding.scope == scope else { throw NativePreparedInvocationError.scopeMismatch }
        return receipt
    }

    func cancel(scope: NativePreparedInvocationScope, taskID: String) throws -> NativePreparedInvocationReceipt {
        let current = try inspect(scope: scope, taskID: taskID)
        let receipt = NativePreparedInvocationReceipt(taskID: taskID, binding: current.binding, bindingDigest: current.bindingDigest, state: "canceled", phase: "canceled", decisionID: nil, result: nil)
        receipts[taskID] = receipt
        return receipt
    }

    func respond(review: NativePreparedInvocationReceipt, replyID: String, approved: Bool) async throws -> NativePreparedInvocationReceipt {
        guard receipts[review.taskID] == review else { throw NativePreparedInvocationError.decisionUnavailable }
        let receipt = NativePreparedInvocationReceipt(taskID: review.taskID, binding: review.binding, bindingDigest: review.bindingDigest, state: approved ? "blocked" : "failed", phase: approved ? "ready" : "declined", decisionID: nil, result: nil)
        receipts[review.taskID] = receipt
        approvalAccepted = true
        if hold {
            hold = false
            await withCheckedContinuation { continuation = $0 }
        }
        if fail { fail = false; throw NativePreparedInvocationError.unavailable }
        return receipt
    }
}
