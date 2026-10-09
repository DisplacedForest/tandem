import Foundation
import CryptoKit

enum NativePreparedInvocationError: Error, Equatable {
    case invalidBinding
    case unavailable
    case invalidReceipt
    case scopeMismatch
    case decisionUnavailable
}

struct NativePreparedInvocationScope: Codable, Equatable, Sendable {
    let hostOriginID: String
    let assistantID: String
    let conversationID: String
}

struct NativePreparedToolInvocation: Codable, Equatable, Sendable {
    let hostOriginID: String
    let operationID: String
    let assistantID: String
    let conversationID: String
    let serverID: String
    let endpoint: String
    let tool: String
    let schemaJSON: String
    let argumentsJSON: String
    let permissionRevision: String
    let authorizationGeneration: String
    let expiresAtMilliseconds: Int64

    var scope: NativePreparedInvocationScope {
        .init(hostOriginID: hostOriginID, assistantID: assistantID, conversationID: conversationID)
    }

    var digest: String {
        let fields = ["hostOriginID": hostOriginID, "operationID": operationID, "assistantID": assistantID, "conversationID": conversationID, "serverID": serverID, "endpoint": endpoint, "tool": tool, "schemaJSON": schemaJSON, "argumentsJSON": argumentsJSON, "permissionRevision": permissionRevision, "authorizationGeneration": authorizationGeneration, "expiresAtMilliseconds": String(expiresAtMilliseconds)]
        var data = Data()
        for key in fields.keys.sorted() {
            let value = Data(fields[key]!.utf8)
            data.append(Data("\(value.count):".utf8))
            data.append(value)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        try NativeTaskJSON.validate(Data(schemaJSON.utf8), maximumBytes: 8192)
        try NativeTaskJSON.validate(Data(argumentsJSON.utf8), maximumBytes: 8192)
        let identifiers = [hostOriginID, operationID, assistantID, conversationID, serverID, tool, permissionRevision, authorizationGeneration]
        guard identifiers.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 && !$0.unicodeScalars.contains(where: { $0.value < 32 }) }),
              endpoint.utf8.count <= 2048,
              let destination = URLComponents(string: endpoint), destination.scheme == "https",
              destination.host?.isEmpty == false, destination.user == nil, destination.password == nil,
              destination.fragment == nil, expiresAtMilliseconds > 0,
              schemaJSON.utf8.count <= 8192, argumentsJSON.utf8.count <= 8192,
              let schema = try JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) as? [String: Any],
              schema["type"] as? String == "object",
              try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) is [String: Any]
        else { throw NativePreparedInvocationError.invalidBinding }
    }
}

struct NativePreparedInvocationResult: Codable, Equatable, Sendable {
    let status: String
    let summary: String
}

struct NativePreparedInvocationReceipt: Codable, Equatable, Sendable {
    let taskID: String
    let binding: NativePreparedToolInvocation
    let bindingDigest: String
    let state: String
    let phase: String
    let decisionID: String?
    let result: NativePreparedInvocationResult?

    func validate(scope: NativePreparedInvocationScope, expected: NativePreparedToolInvocation? = nil) throws {
        try binding.validate()
        guard binding.scope == scope else { throw NativePreparedInvocationError.scopeMismatch }
        guard expected == nil || expected == binding else { throw NativePreparedInvocationError.invalidReceipt }
        guard !taskID.isEmpty, taskID.utf8.count <= 200,
              bindingDigest == binding.digest,
              ["queued", "running", "blocked", "needs_decision", "completed", "failed", "canceled"].contains(state),
              ["awaiting_decision", "ready", "preparing", "stale", "effect_completed", "effect_uncertain", "declined", "canceled"].contains(phase),
              (state == "needs_decision") == (decisionID != nil),
              decisionID.map({ !$0.isEmpty && $0.utf8.count <= 200 }) ?? true,
              result.map({ $0.status == "completed" && $0.summary.utf8.count <= 4096 }) ?? true
        else { throw NativePreparedInvocationError.invalidReceipt }
        let consistent: Bool
        switch phase {
        case "awaiting_decision": consistent = state == "needs_decision" && result == nil
        case "ready": consistent = state == "blocked" && result == nil
        case "preparing": consistent = ["queued", "running", "blocked"].contains(state) && result == nil
        case "stale": consistent = ["queued", "running", "blocked", "needs_decision"].contains(state) && result == nil
        case "declined": consistent = state == "failed" && result == nil
        case "canceled": consistent = state == "canceled" && result == nil
        case "effect_uncertain": consistent = ["blocked", "canceled"].contains(state) && result == nil
        case "effect_completed": consistent = ["blocked", "queued", "running", "completed", "canceled"].contains(state) && result != nil
        default: consistent = false
        }
        guard consistent else { throw NativePreparedInvocationError.invalidReceipt }
    }
}

protocol NativePreparedInvocationRepository: Sendable {
    func prepare(_ binding: NativePreparedToolInvocation) async throws -> NativePreparedInvocationReceipt
    func inspect(scope: NativePreparedInvocationScope, taskID: String) async throws -> NativePreparedInvocationReceipt
    func cancel(scope: NativePreparedInvocationScope, taskID: String) async throws -> NativePreparedInvocationReceipt
}

protocol NativePreparedInvocationDecisionHost: Sendable {
    func respond(review: NativePreparedInvocationReceipt, replyID: String, approved: Bool) async throws -> NativePreparedInvocationReceipt
}

actor NativePreparedInvocationCoordinator {
    private let repository: any NativePreparedInvocationRepository
    private let scope: NativePreparedInvocationScope
    private var bindings: [String: NativePreparedToolInvocation] = [:]

    init(repository: any NativePreparedInvocationRepository, scope: NativePreparedInvocationScope) {
        self.repository = repository
        self.scope = scope
    }

    func prepare(_ binding: NativePreparedToolInvocation) async throws -> NativePreparedInvocationReceipt {
        try Task.checkCancellation()
        try binding.validate()
        guard binding.scope == scope else { throw NativePreparedInvocationError.scopeMismatch }
        let receipt = try await repository.prepare(binding)
        try receipt.validate(scope: scope, expected: binding)
        guard bindings[receipt.taskID] == nil || bindings[receipt.taskID] == binding else { throw NativePreparedInvocationError.invalidReceipt }
        bindings[receipt.taskID] = binding
        if Task.isCancelled {
            _ = try? await repository.cancel(scope: scope, taskID: receipt.taskID)
            throw CancellationError()
        }
        return receipt
    }

    func inspect(taskID: String) async throws -> NativePreparedInvocationReceipt {
        try Task.checkCancellation()
        let receipt = try await repository.inspect(scope: scope, taskID: taskID)
        try Task.checkCancellation()
        guard receipt.taskID == taskID else { throw NativePreparedInvocationError.invalidReceipt }
        try receipt.validate(scope: scope, expected: bindings[taskID])
        bindings[taskID] = receipt.binding
        return receipt
    }

    func respond(review: NativePreparedInvocationReceipt, replyID: String, approved: Bool, host: any NativePreparedInvocationDecisionHost) async throws -> NativePreparedInvocationReceipt {
        try Task.checkCancellation()
        try review.validate(scope: scope, expected: bindings[review.taskID])
        guard review.state == "needs_decision", review.phase == "awaiting_decision", review.decisionID != nil,
              !replyID.isEmpty, replyID.utf8.count <= 200,
              let expected = bindings[review.taskID], expected == review.binding
        else { throw NativePreparedInvocationError.decisionUnavailable }
        let repository = repository
        let scope = scope
        do {
            let receipt = try await withTaskCancellationHandler {
                try await host.respond(review: review, replyID: replyID, approved: approved)
            } onCancel: {
                Task { _ = try? await repository.cancel(scope: scope, taskID: review.taskID) }
            }
            try Task.checkCancellation()
            guard receipt.taskID == review.taskID else { throw NativePreparedInvocationError.invalidReceipt }
            try receipt.validate(scope: scope, expected: expected)
            return receipt
        } catch {
            _ = try? await repository.cancel(scope: scope, taskID: review.taskID)
            throw error
        }
    }

    func cancel(taskID: String) async throws -> NativePreparedInvocationReceipt {
        let receipt = try await repository.cancel(scope: scope, taskID: taskID)
        guard receipt.taskID == taskID else { throw NativePreparedInvocationError.invalidReceipt }
        try receipt.validate(scope: scope, expected: bindings[taskID])
        return receipt
    }
}

struct NativePreparedFocusedFixtureConsumer: Sendable {
    let coordinator: NativePreparedInvocationCoordinator

    func submit(hostPrepared binding: NativePreparedToolInvocation) async throws -> NativePreparedInvocationReceipt {
        try await coordinator.prepare(binding)
    }
}

struct NativePreparedPiFixtureConsumer: Sendable {
    let coordinator: NativePreparedInvocationCoordinator

    func submit(hostPrepared binding: NativePreparedToolInvocation) async throws -> NativePreparedInvocationReceipt {
        try await coordinator.prepare(binding)
    }
}
