import Foundation
import VeraAssistantUI

private actor NativeRuntimeRetryRequests {
    var workerPrepares = 0
    func shouldCorrect() -> Bool { workerPrepares += 1; return workerPrepares == 2 }
}

private struct NativeRuntimeRetryModel: PiMockModelExecutor {
    let base: PiSelectedProfileOperation
    let state: NativeRuntimeRetryRequests
    let correct: @MainActor @Sendable () throws -> Void
    func validateOwner() async throws { try await base.validateOwner() }
    func validateRequest(_ request: PiModelRequest) async throws { try await base.validateRequest(request) }
    func prepareRequest(_ request: PiModelRequest) async throws -> PiModelRequest {
        if request.scope.role == "worker", request.memoryContext == nil, await state.shouldCorrect() { try await correct() }
        return try await base.prepareRequest(request)
    }
    func complete(_ request: PiModelRequest) async throws -> PiValue { try await base.complete(request) }
}

private actor NativeRuntimeRetryHTTP {
    var accepted = false
    private var decisions = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let response = try await PiOwnedHTTP.send(request)
        if request.url?.path.hasSuffix("/decision") == true, response.1 == 200 {
            decisions += 1
            if decisions == 2 {
                accepted = true
                await withCheckedContinuation { continuation = $0 }
            }
        }
        return response
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
enum NativeRuntimeMemoryRetryContract {
    static func run(_ arguments: [String], config: ConfigStore, binding: PiSelectedProfileBinding,
                    admission: NativeInferenceAdmission, root: URL) async throws {
        let repository = try LocalChatRepository(url: root.appendingPathComponent("retry-native.sqlite"))
        let memory = try NativeRuntimeMemorySelftest.fixture(repository)
        var settings = NativeMemorySettings.fresh
        settings.enabled = true; settings.bankScope = "farm"
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeMemorySettings: settings)
        let bridge = NativeRuntimeMemoryBridge(store: store)
        let accounting = try PiSharedAccounting(root: root.appendingPathComponent("retry-accounting"), baselineNanos: 0)
        let provider = NativeRuntimeRetryProvider(), requests = NativeRuntimeRetryRequests(), http = NativeRuntimeRetryHTTP()
        var operation = try config.piSelectedProfileOperation(binding: binding, admission: admission, accounting: accounting) { outgoing, request in
            try await provider.send(outgoing, request: request)
        }
        operation.memoryBridge = bridge
        let executor = NativeRuntimeRetryModel(base: operation, state: requests) {
            var corrected = memory
            corrected.summary = "Current livestock: nine hens"; corrected.details = [corrected.summary]
            try repository.saveMemory(corrected, decision: .edited, note: "Synthetic interrupted-task correction", expected: memory)
        }
        var runtime = arguments
        if let index = runtime.firstIndex(of: "--root") { runtime[index + 1] += "-memory-retry" }
        let owner = try NativePiAppOwner(arguments: runtime, executor: executor, ownerBinding: binding.digest,
            memoryBridge: bridge, httpTransport: { request in try await http.send(request) })
        do {
            let ready = try await owner.start()
            guard case .number(let port) = ready.pi("port") else { throw PiBrokerError.invalid }
            let workspace = try AssistantWorkspace(dataRoot: root.appendingPathComponent("retry-ui"),
                endpoint: URL(string: "http://127.0.0.1:\(Int(port))")!,
                workspaceRoot: owner.session.ledger.owner.url.appendingPathComponent("runtime/workspaces"),
                runtimeIdentity: "shared-memory-retry-fixture") { request in try await owner.http(request) }
            try await owner.bindAssistant(workspace.assistantID)
            let session = workspace.session
            session.select()
            await session.refresh()
            session.setDraft("/task Current livestock?")
            await session.send()
            let first = try await NativePiNativeContract.task(session, state: "needs_decision")
            guard let firstDecision = first.decisionID else { throw PiBrokerError.invalid }
            try piCheck(await requests.workerPrepares == 0)
            await session.reply(taskID: first.id, decisionID: firstDecision, approved: true)
            var retry: AssistantSessionTask?
            for _ in 0..<100 {
                await session.refresh()
                retry = session.tasks.first { $0.id == first.id && $0.state == "needs_decision" && $0.decisionID != firstDecision }
                if retry != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let retry, let retryDecision = retry.decisionID else { throw PiBrokerError.unavailable }
            let before = await provider.calls()
            let approval = Task { await session.reply(taskID: retry.id, decisionID: retryDecision, approved: true) }
            for _ in 0..<200 {
                if await http.accepted, await requests.workerPrepares >= 3 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let accepted = await http.accepted, workerPrepares = await requests.workerPrepares
            try piCheck(accepted && workerPrepares >= 3)
            try piCheck(await provider.calls() == before)
            await http.release()
            await approval.value
            let finished = try await NativePiNativeContract.task(session, state: "completed")
            try piCheck(finished.id == first.id && session.output(taskID: finished.id, index: 0) != nil)
            let contexts = await provider.memoryContexts()
            try piCheck(contexts.suffix(3).count == 3 && contexts.suffix(3).allSatisfy { $0.contains("nine hens") && !$0.contains("ten hens") })
            let sources = bridge.sources(conversation: session.id.uuidString.lowercased(), message: "task:" + first.id)
            try piCheck(sources.count == 1 && NativeMemoryCitation.revision(sources[0].url) == 2)
            await owner.stop()
            print("PASS: actual TaskStore same-task retry, accepted decision response held, zero early model dispatch, corrected memory and grounded output")
        } catch {
            await http.release()
            await owner.stop()
            throw error
        }
    }
}

private actor NativeRuntimeRetryProvider {
    private let normal = PiCandidateProviderFixture()
    private var count = 0
    private var contexts: [String] = []
    func calls() -> Int { count }
    func memoryContexts() -> [String] { contexts }
    func send(_ outgoing: URLRequest, request: PiModelRequest) async throws -> (Data, Int) {
        count += 1
        let prompt = request.memoryContext?.prompt ?? ""
        contexts.append(prompt)
        if request.scope.role != "worker" || request.toolCount != 0 || !prompt.contains("nine hens") {
            return try await normal.send(outgoing, request: request)
        }
        try piCheck(outgoing.value(forHTTPHeaderField: "Authorization") == "Bearer " + PiCandidateCredentials.key)
        let calls: [PiValue] = try ["read_file", "write_file"].map { name in
            var args: [String: PiValue] = ["path": .string("sum.py")]
            if name == "write_file" { args["content"] = .string("def add(a, b):\n    return a + b\n") }
            return .object(["id": .string(UUID().uuidString.lowercased()), "type": .string("function"),
                "function": .object(["name": .string(name), "arguments": .string(String(decoding: try PiValue.object(args).piData(), as: UTF8.self))])])
        }
        return (try PiValue.object(["model": .string("qwen/qwen3.8-flash"), "choices": .array([.object([
            "finish_reason": .string("tool_calls"), "message": .object(["role": .string("assistant"), "content": .null, "tool_calls": .array(calls)])])]),
            "usage": .object(["prompt_tokens": .number(20), "completion_tokens": .number(4), "cost": .number(0.000028)])]).piData(), 200)
    }
}
