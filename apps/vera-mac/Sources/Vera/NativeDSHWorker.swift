import Foundation
import CryptoKit

struct NativeDSHStart: Encodable, Sendable {
    let type = "start"
    let snapshot: NativeTaskPlainJSON?
    let toolResults: [NativeTaskGenerationMessage]
    let systemPrompt: String
    let prompt: String
    let tools: [NativeToolSchema]
    let contextTokens: Int
    let outputTokens: Int
}

struct NativeDSHModelRequest: Decodable, Sendable {
    let id: String
    let messages: [NativeTaskGenerationMessage]
    let tools: [NativeToolSchema]?
    let toolChoice: String?
}

struct NativeDSHModelResult: Encodable, Sendable {
    let type = "model_result"
    let id: String
    let content: String
    let tool_calls: [NativeTaskGenerationToolCall]
    let finish_reason: String
}

struct NativeDSHBoundary: Decodable, Sendable {
    let type: String
    let snapshot: NativeTaskPlainJSON
    let toolCalls: [NativeTaskGenerationToolCall]?
    let content: String?
}

final class NativeDSHOrdinal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

enum NativeDSHWorker {
    static let unavailableMessage = "Some Tandem files are missing or damaged. Reinstall Tandem, then start this work again."
    static let stoppedMessage = "This work stopped before finishing. Earlier confirmed changes are saved."
    typealias Driver = @Sendable (Data, @escaping @Sendable (Data) async throws -> Data) async throws -> Data

    static func generationAttempt(_ attempt: String, nonce: String) -> String {
        SHA256.hash(data: Data((attempt + "|" + nonce).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func containsUnexecutedCall(_ content: String) -> Bool {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("<tool_call>") || text.hasPrefix("<tool_calls>")
    }

    static func defaultOutputTokens(contextTokens: Int?) -> Int {
        min(65536, max(1, (contextTokens ?? 131072) / 2))
    }

    static func drive(_ request: Data, model: @escaping @Sendable (Data) async throws -> Data) async throws -> Data {
        let paths: (executable: URL, script: URL)
        do { paths = try NativeDSHRuntimePaths.resolve() }
        catch { throw NativeDSHFailure(code: "unavailable") }
        return try await NativeDSHProcess().run(request, executable: paths.executable, script: paths.script, model: model)
    }

    static func restored(_ data: Data) throws -> NativeCompanionCheckpoint {
        if try NativeTaskStore.object(data).isEmpty { return NativeCompanionCheckpoint() }
        return try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: data)
    }

    static func make(exchange: NativeTaskGenerationExchange, environment: NativeCompanionWorkerEnvironment) -> NativeTaskWorker {
        NativeTaskWorker(timeoutSeconds: NativeCompanionWorker.stepTimeoutSeconds) { task in
            let checkpoint = try restored(task.checkpoint)
            if checkpoint.dsh != true, !checkpoint.transcript.isEmpty || checkpoint.pending != nil || checkpoint.rounds > 0 {
                return try await NativeCompanionWorker.make(exchange: exchange, environment: environment).step(task)
            }
            return try await step(task, environment: environment) { phase, attempt, ordinal, messages, tools, choice in
                guard let binding = try JSONDecoder().decode(NativeResearchTaskPayload.self, from: task.payload).nativeBinding else {
                    throw NativeTaskExecutorUnavailable()
                }
                return try await exchange.completeTurn(task: task, binding: binding, phase: phase, attempt: attempt,
                    ordinal: ordinal, messages: messages, tools: tools, toolChoice: tools == nil ? nil : choice)
            }
        }
    }

    static func step(_ task: NativeTaskRecord, environment: NativeCompanionWorkerEnvironment,
                     driver: @escaping Driver = drive, model: @escaping NativeCompanionWorker.Model) async throws -> NativeTaskStepResult {
        try await NativeToolCallContext.$instructionHolder.withValue(nil) {
            try await unbound(task, environment: environment, driver: driver, model: model)
        }
    }

    private static func unbound(_ task: NativeTaskRecord, environment: NativeCompanionWorkerEnvironment,
                                driver: @escaping Driver, model: @escaping NativeCompanionWorker.Model) async throws -> NativeTaskStepResult {
        let payload = try JSONDecoder().decode(NativeResearchTaskPayload.self, from: task.payload)
        guard let dot = payload.dot else { return .failed(checkpoint: task.checkpoint, reason: "worker_error") }
        var checkpoint = try restored(task.checkpoint)
        checkpoint.dsh = true
        _ = try environment.ledger.abandonAdmitted(taskID: task.id)
        guard let context = await environment.context(dot.mode, dot.connectedToolIDs) else {
            return try NativeCompanionWorker.fail(&checkpoint, code: "companion_missing", message: "The conversation is unavailable, so this work stopped.")
        }
        if let thread = checkpoint.threadID, thread != context.threadID {
            return try NativeCompanionWorker.fail(&checkpoint, code: "companion_reset", message: "The conversation started over, so this work stopped.")
        }
        checkpoint.threadID = context.threadID
        checkpoint.nativeUnavailable = nil
        if checkpoint.sources == nil { checkpoint.sources = dot.carried?.sources }
        let modelAttempt = checkpoint.dshAttempt ?? "initial"
        let wrappedModel: NativeCompanionWorker.Model = { phase, attempt, ordinal, messages, tools, choice in
            try await model(phase, generationAttempt(attempt, nonce: modelAttempt), ordinal, messages, tools, choice)
        }
        let run = NativeCompanionRun(task: task, dot: dot, context: context, environment: environment, model: wrappedModel)
        let prior = checkpoint
        do {
            if let pending = checkpoint.pending {
                checkpoint.pending = nil
                if let result = try await run.resolve(pending, &checkpoint) { return result }
            }
            if let result = try await run.reconcileUncertain(&checkpoint) { return result }
            if !checkpoint.outstandingCalls.isEmpty {
                if let result = try await run.answerOutstanding(&checkpoint) { return result }
                return try run.progress(checkpoint)
            }
            if checkpoint.finishing == true {
                return try NativeCompanionWorker.fail(&checkpoint, code: "provider_response", message: "A step kept failing validation. Earlier results are saved, but this work isn't finished.")
            }
            let states = NativeDSHStateStore(database: environment.tasks.database)
            let snapshot = try checkpoint.dshRevision.map { try JSONDecoder().decode(NativeTaskPlainJSON.self, from: states.load($0, taskID: task.id)) }
            let contextTokens = payload.nativeBinding?.contextTokens ?? 131072
            let outputTokens = payload.nativeBinding?.outputTokens ?? defaultOutputTokens(contextTokens: contextTokens)
            let offered = run.offered
            let start = NativeDSHStart(snapshot: snapshot,
                toolResults: checkpoint.transcript.filter { $0.role == "tool" },
                systemPrompt: run.systemPrompt(finishing: false),
                prompt: "Assignment:\n" + dot.assignment + NativeCompanionWorker.carriedSection(dot.carried),
                tools: offered, contextTokens: contextTokens, outputTokens: outputTokens)
            let round = checkpoint.rounds
            let attempt = checkpoint.attempt
            let ordinal = NativeDSHOrdinal()
            let data = try await driver(nativeTaskEncoded(start)) { raw in
                let request = try JSONDecoder().decode(NativeDSHModelRequest.self, from: raw)
                guard !request.id.isEmpty else { throw NativeDSHFailure(code: "protocol") }
                let tools = request.tools.flatMap { $0.isEmpty ? nil : $0 }
                if let tools {
                    guard tools == offered else { throw NativeDSHFailure(code: "tool_inventory") }
                }
                let result = try await wrappedModel("work-\(round)", attempt, ordinal.next(), request.messages,
                    tools, tools == nil ? "none" : request.toolChoice ?? "auto")
                guard ["stop", "tool_calls"].contains(result.finishReason) else { throw NativeDSHFailure(code: "incomplete") }
                return try nativeTaskEncoded(NativeDSHModelResult(id: request.id, content: result.content,
                    tool_calls: result.toolCalls, finish_reason: result.finishReason))
            }
            let boundary = try JSONDecoder().decode(NativeDSHBoundary.self, from: data)
            let calls = boundary.toolCalls ?? []
            guard calls.allSatisfy(NativeTaskGenerationJob.validCall), Set(calls.map(\.id)).count == calls.count,
                  calls.count <= 64 else { throw NativeDSHFailure(code: "protocol") }
            if boundary.type == "boundary" {
                guard !calls.isEmpty else { throw NativeDSHFailure(code: "protocol") }
            } else if boundary.type == "final" {
                guard calls.isEmpty, let content = boundary.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !containsUnexecutedCall(content) else { throw NativeDSHFailure(code: "incomplete") }
            } else { throw NativeDSHFailure(code: "protocol") }
            checkpoint.dshRevision = try states.save(nativeTaskEncoded(boundary.snapshot), task: task)
            checkpoint.rounds += 1
            checkpoint.automaticRetryRound = nil
            checkpoint.transcript = calls.isEmpty ? [] : [.init(role: "assistant", content: "", toolCalls: calls)]
            if let content = boundary.content, !content.isEmpty {
                checkpoint.note = NativeTaskNote(text: NativeCompanionWorker.cut(content, scalars: NativeCompanionWorker.noteScalars), at: environment.now().timeIntervalSince1970)
            }
            if boundary.type == "final" { return try await run.conclude(&checkpoint, text: boundary.content ?? "") }
            return try run.progress(checkpoint)
        } catch is CancellationError where run.heldProbe() {
            var paused = prior
            paused.dshAttempt = NativeCompanionCheckpoint.freshAttempt()
            var result = try run.progress(paused)
            result.keepsReply = prior.pending != nil
            return result
        } catch is NativeTaskExecutorUnavailable {
            checkpoint.nativeUnavailable = payload.nativeBinding?.id
            return NativeTaskStepResult(state: .blocked, checkpoint: try checkpoint.encoded(), event: "progress",
                data: try NativeTaskStore.canonical(["message": "Open Tandem with the saved model profile to continue this work."]))
        } catch let failure as NativeTaskGenerationFailure {
            if NativeTaskWorkerFailures.terminalCodes.contains(failure.code) {
                return try NativeCompanionWorker.fail(&checkpoint, code: failure.code,
                    message: NativeTaskWorkerFailures.terminalMessage(failure.code, work: "assignment"))
            }
            if NativeTaskWorkerFailures.retriesAutomatically(failure.code), checkpoint.automaticRetryRound != checkpoint.rounds {
                checkpoint.automaticRetryRound = checkpoint.rounds
                checkpoint.dshAttempt = NativeCompanionCheckpoint.freshAttempt()
                return try run.progress(checkpoint)
            }
            checkpoint.dshAttempt = NativeCompanionCheckpoint.freshAttempt()
            checkpoint.pending = NativeCompanionPending(kind: "retry")
            return try NativeCompanionWorker.decide(checkpoint, NativeTaskWorkerFailures.retryPrompt(NativeTaskWorkerFailures.pauseMessage(failure.code)), ["retry"])
        } catch let failure as NativeDSHFailure {
            if AppLocations.isHeadless { print("DSH diagnostic: \(failure.code)") }
            checkpoint.failureReason = failure.code == "unavailable" ? "execution_unavailable" : "execution_failed"
            let message = failure.code == "unavailable" ? unavailableMessage : stoppedMessage
            return try NativeCompanionWorker.fail(&checkpoint, code: "worker_error", message: message)
        }
    }
}
