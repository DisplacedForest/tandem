import Foundation
import GRDB

@MainActor
enum NativeDSHSelftest {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NativeTaskFixture.Failure.assertion(message) }
    }

    static func step(_ harness: NativeCompanionHarness, commit: Bool = true,
                     driver: @escaping NativeDSHWorker.Driver = NativeDSHWorker.drive) async throws -> NativeTaskRecord {
        guard let task = try harness.store.claim(workerTypes: ["companion"]) else { throw NativeTaskFixture.Failure.assertion("A step is queued") }
        let model = harness.model
        let result = try await NativeDSHWorker.step(task, environment: harness.environment, driver: driver) { phase, attempt, ordinal, messages, tools, _ in
            try model.complete(phase, attempt + "-\(ordinal)", messages, tools)
        }
        return commit ? try harness.store.commitStep(task.id, generation: task.generation, step: result) : task
    }

    static func settle(_ harness: NativeCompanionHarness) async throws -> NativeTaskRecord {
        for _ in 0..<20 {
            let record = try await step(harness)
            if record.state != .queued { return record }
        }
        throw NativeTaskFixture.Failure.assertion("The scripted work finishes")
    }

    nonisolated static func garden(_ messages: [NativeTaskGenerationMessage]) -> NativeTaskGenerationCompletion {
        let replies = messages.filter { $0.role == "tool" }
        if replies.isEmpty { return NativeCompanionScriptedModel.call("garden_status", "{}", id: "lookup") }
        if !replies.contains(where: { $0.toolCallID == "water" }) {
            return NativeCompanionScriptedModel.call("water_bed", "{\"bed\":\"north\"}", id: "water")
        }
        return .text("The lookup and requested decision are recorded.")
    }

    static func run() async throws {
        try NativeDSHRuntimePathsSelftest.run()
        try require(NativeDSHWorker.defaultOutputTokens(contextTokens: 32768) == 16384, "Small contexts retain input capacity")
        try require(NativeDSHWorker.defaultOutputTokens(contextTokens: 262144) == 65536, "Large contexts retain the full output allowance")
        try require(NativeDSHWorker.generationAttempt(String(repeating: "a", count: 70), nonce: NativeCompanionCheckpoint.freshAttempt()).count == 32, "Renewed authorization requests fit the generation key contract")
        let messages = [NativeTaskGenerationMessage(role: "user", content: "Check the saved allowance")]
        let job = NativeTaskGenerationJob(id: UUID().uuidString, taskID: UUID().uuidString, bindingID: "wire",
            enrollmentDigest: String(repeating: "a", count: 64), admissionBase: URL(string: "https://live.reasoning.test/v1")!,
            phase: "work-0", attempt: "initial", messages: messages, messagesDigest: NativeTaskGenerationJob.digest(messages), deadlineSeconds: 20, generation: 1)
        for context in [32768, 262144] {
            let binding = NativeTaskProfileBinding(id: "wire", profileID: "wire", provider: try NativeTaskEngineIdentity(URL(string: "https://live.reasoning.test/v1")!),
                savedModel: "wire-model", executionModel: "wire-model", limits: try NativeTaskGenerationLimits(), contextTokens: context)
            var options = NativeChatRequestOptions.none
            options.topLevel.append(.init(key: "reasoning_effort", value: .string("xhigh"), source: .saved))
            let config = NativeChatConfig(baseURL: binding.provider.base, apiKey: nil, model: binding.executionModel, chatTemplateKwargs: nil, options: options)
            TaskReasoningWire.reset(cutFirst: false)
            _ = try await NativeTaskProvider.completion(config: config, binding: binding, job: job, protocolClasses: [TaskReasoningWire.self], diagnostics: { _ in })
            let body = try JSONSerialization.jsonObject(with: TaskReasoningWire.seen[0]) as! [String: Any]
            try require(body["max_tokens"] as? Int == NativeDSHWorker.defaultOutputTokens(contextTokens: context)
                && body["reasoning_effort"] as? String == "xhigh" && body["thinking_budget"] == nil,
                "The provider receives the effective allowance and effort without a separate thinking cap")
        }
        let denied = try NativeCompanionHarness(rules: [.networkSends: .ask], script: garden)
        _ = try denied.create()
        let waiting = try await settle(denied)
        try require(waiting.state == .needsDecision, "An injected tool result cannot authorize a write")
        try require(denied.service.count("garden_status") == 1 && denied.service.appliedCount == 0, "The read runs and the write waits")
        try denied.reply(waiting, "decline")
        let declined = try await settle(denied)
        try require(declined.state == .completed && denied.service.appliedCount == 0, "Declining stops work without executing the write")
        let checkpoint = try NativeDSHWorker.restored(declined.checkpoint)
        try require(checkpoint.dsh == true && checkpoint.dshRevision != nil, "The actual DSH session is retained")

        let approved = try NativeCompanionHarness(rules: [.networkSends: .ask], withReconcile: true, script: garden)
        _ = try approved.create()
        let question = try await settle(approved)
        try approved.reply(question, "approve", digest: try approved.decision(question)["digest"] as? String)
        _ = try await step(approved, commit: false)
        try require(approved.service.appliedCount == 1, "The approved action ran before the simulated process loss")
        _ = try approved.store.recover()
        let recovered = try await settle(approved)
        try require(NativeDSHWorker.restored(recovered.checkpoint).transcript.isEmpty, "The completed checkpoint does not duplicate the execution transcript")
        try require(recovered.state == .completed && approved.service.count("water_bed") == 1, "Recovery uses the persisted effect receipt without repeating the action")

        var paused = try NativeCompanionHarness(rules: [.networkSends: .act], withReconcile: true) { messages in
            if !messages.contains(where: { $0.role == "tool" }) {
                return NativeTaskGenerationCompletion(content: "", toolCalls: [
                    .init(id: "water", name: "water_bed", arguments: "{\"bed\":\"north\"}"),
                    .init(id: "read", name: "garden_status", arguments: "{}")], finishReason: "tool_calls")
            }
            return .text("The requested action and verification finished.")
        }
        let pausedID = try paused.create()
        let pausedService = paused.service
        let pausedStore = paused.store
        var pausedTools = NativeCompanionHarness.tools(pausedService, reconcile: true)
        pausedTools[0].execute = { _ in
            pausedService.bump("garden_status")
            if pausedService.count("garden_status") == 1 {
                _ = try pausedStore.pause(pausedID)
                throw CancellationError()
            }
            return .object(["verified": .bool(true)])
        }
        let toolsAfterPause = pausedTools
        paused.environment.context = { _, _ in
            NativeCompanionWorkerContext(assistantName: "Ada", threadID: "companion-thread-1", tools: toolsAfterPause)
        }
        _ = try await step(paused)
        let held = try await step(paused)
        try require(held.state == .paused && pausedService.appliedCount == 1, "Pause interrupts the batch after its confirmed write: \(held.state) held=\(held.pauseRequested) applied=\(pausedService.appliedCount) read=\(pausedService.count("garden_status"))")
        _ = try pausedStore.unpause(pausedID)
        let resumed = try await settle(paused)
        try require(resumed.state == .completed && pausedService.count("water_bed") == 1, "Pause recovery preserves the write receipt while renewing model requests")

        let malformed = try NativeCompanionHarness(rules: [:]) { messages in
            if NativeCompanionScriptedModel.toolResults(messages).isEmpty {
                return NativeCompanionScriptedModel.call("garden_status", "{broken", id: "broken")
            }
            return .text("The invalid arguments were rejected.")
        }
        _ = try malformed.create()
        let fixed = try await settle(malformed)
        try require(fixed.state == .completed && malformed.service.count("garden_status") == 0, "Malformed arguments receive corrective tool feedback without execution")

        let unavailable = try NativeCompanionHarness(rules: [:]) { _ in .text("unused") }
        _ = try unavailable.create()
        let failed = try await step(unavailable, driver: { _, _ in throw NativeDSHFailure(code: "unavailable") })
        try require(failed.state == .failed, "A missing runtime does not silently use the previous backend")
        let missingRequest = try NativeResearchTaskRequest(dot: NativeCompanionTaskPayload(assignment: "Water the north bed", mode: "manual"))
        var missingReference = try unavailable.repository.prepareTaskReference(origin: NativeTaskFixture.origin(unavailable.repository),
            engine: NativeTaskLocalEngine.identity, request: missingRequest, profile: nil)
        missingReference.remoteTaskID = failed.id
        let missingSnapshot = try JSONDecoder().decode(NativeTaskSnapshot.self, from: failed.snapshotJSON())
        let missingCard = try NativeTaskProjection.display(reference: missingReference, snapshot: missingSnapshot).card
        try require(missingCard.milestone == NativeDSHWorker.unavailableMessage, "Missing or damaged files show the recovery action in the conversation")


        let falseFinal = try NativeCompanionHarness(rules: [:]) { _ in .text("unused") }
        _ = try falseFinal.create()
        let invalid = try await step(falseFinal, driver: { _, _ in
            Data("{\"type\":\"final\",\"snapshot\":{},\"content\":\"<tool_call>not executed</tool_call>\"}".utf8)
        })
        try require(invalid.state == .failed, "Unexecuted tool envelopes cannot become successful answers")

        try require(!NativeDSHWorker.containsUnexecutedCall("Example:\n```xml\n<tool_call>example</tool_call>\n```"), "Quoted syntax is ordinary explanatory text")

        let retry = try NativeCompanionHarness(rules: [:]) { _ in .text("Recovered after retry.") }
        _ = try retry.create()
        let first = try retry.store.claim(workerTypes: ["companion"])!
        let firstResult = try await NativeDSHWorker.step(first, environment: retry.environment) { _, _, _, _, _, _ in
            throw NativeTaskGenerationFailure(code: "provider_unavailable")
        }
        let retryRecord = try retry.store.commitStep(first.id, generation: first.generation, step: firstResult)
        let retryCheckpoint = try NativeDSHWorker.restored(retryRecord.checkpoint)
        try require(retryCheckpoint.dshAttempt != nil && retryCheckpoint.attempt == "initial", "Model retries renew their cache identity without changing effect keys")
        if retryRecord.state == .needsDecision { try retry.reply(retryRecord, "retry") }
        let retried = try await settle(retry)
        try require(retried.state == .completed, "The real DSH loop can recover after model failure")

        let fullText = String(repeating: "A complete paragraph with verified details.\n\n", count: 24000)
        let large = try NativeCompanionHarness(rules: [:]) { _ in .text(fullText) }
        _ = try large.create()
        let largeResult = try await settle(large)
        let report = try largeResult.result.map(NativeTaskStore.object)?["report"] as? String
        try require(report == fullText.trimmingCharacters(in: .whitespacesAndNewlines), "Long final answers survive the DSH loop, checkpoint and result storage without clipping")
        let wire = try largeResult.snapshotJSON()
        try NativeTaskJSON.validate(wire, maximumBytes: NativeTaskStore.maximumSnapshotBytes)
        let decoded = try JSONDecoder().decode(NativeTaskSnapshot.self, from: wire)
        try require(decoded.state == .completed, "Long results survive the app snapshot boundary")
        let request = try NativeResearchTaskRequest(dot: NativeCompanionTaskPayload(assignment: "Water the north bed", mode: "manual"))
        var reference = try large.repository.prepareTaskReference(origin: NativeTaskFixture.origin(large.repository),
            engine: NativeTaskLocalEngine.identity, request: request, profile: nil)
        reference.remoteTaskID = largeResult.id
        let shown = try NativeTaskProjection.display(reference: reference, snapshot: decoded)
        try require((shown.card.answer ?? shown.artifact?.report) == report, "The complete long answer reaches the conversation projection")


        let cancellation = Task {
            let paths = try NativeDSHRuntimePaths.resolve()
            let request = try nativeTaskEncoded(NativeDSHStart(snapshot: nil, toolResults: [], systemPrompt: "Test", prompt: "Wait", tools: [], contextTokens: 131072, outputTokens: 65536))
            return try await NativeDSHProcess().run(request, executable: paths.executable, script: paths.script) { _ in
                try await Task.sleep(for: .seconds(60))
                return Data()
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        cancellation.cancel()
        do { _ = try await cancellation.value; throw NativeTaskFixture.Failure.assertion("Cancellation must stop the sidecar") }
        catch is CancellationError {}

        let silentDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: silentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: silentDirectory) }
        let silentScript = silentDirectory.appendingPathComponent("silent.mjs")
        try Data("process.stdin.resume()\n".utf8).write(to: silentScript)
        let bundledPaths = try NativeDSHRuntimePaths.resolve()
        let silent = Task {
            try await NativeDSHProcess().run(Data("{}".utf8), executable: bundledPaths.executable, script: silentScript) { _ in Data() }
        }
        try await Task.sleep(for: .milliseconds(200))
        silent.cancel()
        do { _ = try await silent.value; throw NativeTaskFixture.Failure.assertion("A silent process must cancel") }
        catch is CancellationError {}

        let saved = NativeDSHStateStore(database: approved.repository.database)
        let done = try NativeDSHWorker.restored(recovered.checkpoint)
        let data = try saved.load(done.dshRevision!, taskID: recovered.id)
        try require(!data.isEmpty, "A restartable DSH snapshot is stored separately")
        do { _ = try saved.load(done.dshRevision!, taskID: declined.id); throw NativeTaskFixture.Failure.assertion("Snapshots are scoped to their owner") }
        catch NativeTaskStoreError.invalid {}
        print("DSH SELFTEST OK: real loop, host authority, decline, effect recovery, malformed calls, missing runtime, truthful finish, cancellation, snapshot isolation")
    }
}
