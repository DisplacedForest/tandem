import Foundation

private actor NativeRuntimeMemoryProvider {
    private(set) var requests: [PiModelRequest] = []
    func send(_ request: PiModelRequest, _ body: Data) throws -> (Data, Int) {
        try piCheck(try PiValue.piRead(body) == PiProviderCodec.body(request, model: "qwen/qwen3.8-flash"))
        requests.append(request)
        return (try PiValue.object(["model": .string("qwen/qwen3.8-flash"),
            "choices": .array([.object(["finish_reason": .string("stop"), "message": .object([
                "role": .string("assistant"), "content": .string("Synthetic answer [10001]")])])]),
            "usage": .object(["prompt_tokens": .number(80), "completion_tokens": .number(8), "cost": .number(0.000028)])]).piData(), 200)
    }
}

@MainActor
enum NativeRuntimeMemorySelftest {
    static func fixture(_ repository: LocalChatRepository) throws -> NativeMemoryRecord {
        let now = Date()
        let source = Message(role: .user, text: "Current livestock: ten hens. Vaccination is planned, not completed.")
        try repository.saveConversation(Conversation(id: "shared-source", title: "Synthetic source", messages: [], updatedAt: now))
        try repository.saveMessage(source, conversationID: "shared-source", ordinal: 0)
        let record = NativeMemoryRecord(id: "shared-livestock", title: "Current livestock", summary: source.text,
            details: [source.text], group: .areas, category: .project, bank: "farm", durability: .durable,
            expiry: nil, status: .approved, embedding: nil, sourceConversationID: "shared-source",
            sourceMessageID: source.id.uuidString, createdAt: now, updatedAt: now)
        try repository.saveMemory(record, decision: .accepted, note: "Synthetic user approval")
        var privateRecord = record
        privateRecord.id = "other-bank"; privateRecord.bank = "private"; privateRecord.title = "Private livestock"
        privateRecord.summary = "Other-bank-only evidence"; privateRecord.details = [privateRecord.summary]
        try repository.saveMemory(privateRecord, decision: .accepted, note: "Synthetic scoped fixture")
        return record
    }

    static func binding(_ assistant: String, role: String = "foreground", mode: String = "assistant",
                        subject: String = UUID().uuidString.lowercased(), conversation: String = UUID().uuidString.lowercased()) -> PiValue {
        .object(["subject": .string(subject), "assistant": .string(assistant), "conversation": .string(conversation),
            "role": .string(role), "mode": .string(mode)])
    }

    static func request(_ binding: PiValue, profile: String = "fixture", id: String = UUID().uuidString.lowercased()) throws -> PiModelRequest {
        let scope = try PiModelScope(binding, profile: profile)
        return try PiModelRequest(NativePiModelBrokerFixture.request(scope, channel: "fixture", id: id, text: "Current livestock?"), scope: scope, channel: "fixture")
    }

    static func rejected(_ block: () async throws -> Void) async throws {
        do { try await block() } catch { return }
        throw NSError(domain: "SharedMemoryTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected request rejection"])
    }

    static func run() async throws {
        umask(0o077)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-memory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LocalChatRepository(url: root.appendingPathComponent("native.sqlite"))
        let record = try fixture(repository)
        var settings = NativeMemorySettings.fresh
        settings.enabled = true; settings.bankScope = "farm"
        let model = SelfTestNativeTransport(), service = SelfTestMemoryService()
        let store = ChatStore(nativeConfig: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!,
            apiKey: nil, model: "local-model", chatTemplateKwargs: nil), nativeTransport: model,
            repository: repository, nativeMemorySettings: settings, nativeMemoryService: service)
        store.newConversation()
        store.sendText("Current livestock?")
        for _ in 0..<200 where store.generating { try await Task.sleep(for: .milliseconds(10)) }
        let focusedSources = store.selected?.messages.last?.sources ?? []
        try piCheck(focusedSources.count == 1 && NativeMemoryCitation.recordID(focusedSources[0].url) == record.id)
        let assistant = UUID().uuidString.lowercased()
        let bridge = NativeRuntimeMemoryBridge(store: store)
        try bridge.bindAssistant(assistant)
        var prepared: [PiModelRequest] = []
        for (role, mode) in [("foreground", "focused"), ("foreground", "assistant"), ("worker", "assistant")] {
            let scope = binding(assistant, role: role, mode: mode)
            try bridge.authorize(scope, query: "Current livestock?")
            let value = try await bridge.prepare(request(scope))
            try piCheck(value.memoryContext?.selected.map(\.id) == [record.id])
            let prompt = value.messages.first!.pi("content").piString!
            try piCheck(prompt.contains("ten hens") && prompt.contains("planned, not completed") && !prompt.contains("Other-bank-only"))
            try piCheck(value.digest != request(scope, id: value.id).digest)
            let first = try PiProviderCodec.body(value, model: "synthetic-model-one").pi("messages")
            let second = try PiProviderCodec.body(value, model: "synthetic-model-two").pi("messages")
            try piCheck(first == second)
            let delivery = role == "worker" ? "task:" + value.scope.subject : UUID().uuidString.lowercased()
            try bridge.recordDelivery(subject: value.scope.subject, messageID: delivery)
            try piCheck(bridge.sources(conversation: value.scope.conversation, message: delivery) == focusedSources)
            let reopened = try LocalChatRepository(url: root.appendingPathComponent("native.sqlite"))
            try piCheck(try reopened.runtimeMemorySources(assistant: assistant, conversation: value.scope.conversation, message: delivery) == focusedSources)
            try piCheck(try reopened.runtimeMemorySources(assistant: UUID().uuidString.lowercased(), conversation: value.scope.conversation, message: delivery).isEmpty)
            let restoredStore = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: reopened, nativeMemorySettings: settings)
            let restored = NativeRuntimeMemoryBridge(store: restoredStore)
            try restored.bindAssistant(assistant)
            try restored.authorize(scope, query: "Current livestock?")
            let recoveredDelivery = UUID().uuidString.lowercased()
            try restored.recordDelivery(subject: value.scope.subject, messageID: recoveredDelivery)
            try piCheck(restored.sources(conversation: value.scope.conversation, message: recoveredDelivery) == focusedSources)
            prepared.append(value)
        }
        print("  shared memory: focused, persistent, worker, provider-independent payload and source reopen PASS")
        try piCheck(service.embedCalls == 0 && service.extractionCalls == 0)
        for key in ["subject", "assistant", "conversation", "role", "mode"] {
            let original = prepared[0].memoryContext!.binding
            let changed = NativePiModelBrokerFixture.changed(original, key, .string(key == "role" ? "worker" : key == "mode" ? "assistant" : UUID().uuidString.lowercased()))
            try await rejected { _ = try await bridge.prepare(request(changed)) }
        }
        try await rejected { try bridge.authorize(binding(UUID().uuidString.lowercased()), query: "Current livestock?") }
        let worker = prepared[2]
        bridge.revoke(worker.scope.subject)
        try await rejected { try bridge.validate(worker) }
        try await rejected { try bridge.authorize(worker.memoryContext!.binding, query: "Current livestock?") }
        settings.enabled = false
        store.updateNativeMemory(settings: settings, service: service)
        try await rejected { try bridge.validate(prepared[0]) }
        let offBinding = binding(assistant)
        try bridge.authorize(offBinding, query: "Current livestock?")
        let off = try await bridge.prepare(request(offBinding))
        try piCheck(off.memoryContext?.selected.isEmpty == true && !off.messages.first!.pi("content").piString!.contains("USER-APPROVED MEMORY CONTEXT"))
        try piCheck(service.embedCalls == 0 && service.extractionCalls == 0)
        settings.enabled = true
        store.updateNativeMemory(settings: settings, service: nil)
        print("  shared memory: scope rejection, cancellation and disabled behavior PASS")
        try await accounting(root, store: store, assistant: assistant, record: record, repository: repository)
        print("  shared memory: durable accounting replay and correction PASS")
        try await dispatch(root, store: store, assistant: assistant)
        try await brokerLifecycle(root)
        try await brokerValidationLifecycle(root)
        try await workerRetry(root)
        try await settledContextChange(root)
        try await heldContextRejection(root, stage: "prepare", holdAt: 2)
        try await heldContextRejection(root, stage: "grant", holdAt: 3)
        try await sendGuardNoSpend(root)
        bridge.close()
        try await rejected { _ = try await bridge.prepare(request(offBinding)) }
        print("shared-runtime-memory: PASS (one store, focused/persistent/worker identity, model-independent context, sources/reopen, scope isolation, memory off, cancellation, replay and queued dispatch; synthetic only)")
    }

    private static func accounting(_ root: URL, store: ChatStore, assistant: String, record: NativeMemoryRecord,
                                   repository: LocalChatRepository) async throws {
        let scopeBinding = binding(assistant)
        let id = UUID().uuidString.lowercased()
        var first: PiValue?
        for pass in 0..<2 {
            let bridge = NativeRuntimeMemoryBridge(store: store)
            try bridge.bindAssistant(assistant)
            try bridge.authorize(scopeBinding, query: "Current livestock?")
            let ledger = try PiModelLedger(root: root.appendingPathComponent("replay-broker"), manifest: "shared-memory")
            let accounting = try PiSharedAccounting(root: root.appendingPathComponent("replay-provider"), baselineNanos: 0)
            let provider = NativeRuntimeMemoryProvider()
            let admission = PiAdmissionFixtureProtocol.admission()
            defer { admission.session.invalidateAndCancel() }
            let profile = try PiSelectedProfileBinding(profileID: "fixture", revision: UUID().uuidString.lowercased(),
                endpoint: "https://openrouter.ai/api/v1", model: "qwen/qwen3.8-flash")
            var operation = PiSelectedProfileOperation(binding: profile, admission: admission, accounting: accounting,
                validate: {}, send: { request, body in try await provider.send(request, body) })
            operation.memoryBridge = bridge
            let broker = NativePiModelBroker(ledger: ledger, channel: "fixture", executor: operation)
            let scope = try await broker.authorize(scopeBinding)
            let wire = NativePiModelBrokerFixture.request(scope, channel: "fixture", id: id, text: "Current livestock?")
            let reply = try await broker.complete(wire)
            if pass == 0 { first = reply } else { try piCheck(reply == first) }
            try piCheck(await provider.requests.count == (pass == 0 ? 1 : 0))
            if pass == 1 {
                var correction = record
                correction.summary = "Current livestock: nine hens"; correction.details = [correction.summary]
                try repository.saveMemory(correction, decision: .edited, note: "Synthetic correction", expected: record)
                try await rejected { _ = try await broker.complete(wire) }
            }
            await broker.close()
            bridge.close()
        }
        let fresh = NativeRuntimeMemoryBridge(store: store)
        try fresh.bindAssistant(assistant)
        let retryBinding = binding(assistant, conversation: scopeBinding.pi("conversation").piString!)
        try fresh.authorize(retryBinding, query: "Current livestock?")
        let retry = try await fresh.prepare(request(retryBinding))
        try piCheck(retry.messages.first!.pi("content").piString!.contains("nine hens"))
    }

    private static func brokerValidationLifecycle(_ root: URL) async throws {
        for cached in [false, true] {
            let ledger = try PiModelLedger(root: root.appendingPathComponent("validation-" + String(cached)), manifest: "shared-memory")
            let executor = NativeRuntimeHeldValidation()
            let broker = NativePiModelBroker(ledger: ledger, channel: "fixture", executor: executor)
            let scope = try await broker.authorize(NativePiModelBrokerFixture.binding())
            let wire = NativePiModelBrokerFixture.request(scope, channel: "fixture")
            if cached { _ = try await broker.complete(wire) }
            await executor.holdNextDelivery()
            let running = Task { try await broker.complete(wire) }
            for _ in 0..<200 where !(await executor.waiting) { try await Task.sleep(for: .milliseconds(5)) }
            try piCheck(await executor.waiting)
            await broker.close()
            await executor.release()
            try await rejected { _ = try await running.value }
            try piCheck(await executor.calls == 1)
            if !cached { try piCheck(try ledger.snapshot().piArray?.first?.pi("status").piString == "uncertain") }
        }
    }

    private static func workerRetry(_ root: URL) async throws {
        let repository = try LocalChatRepository(url: root.appendingPathComponent("retry.sqlite"))
        let memory = try fixture(repository)
        var settings = NativeMemorySettings.fresh
        settings.enabled = true; settings.bankScope = "farm"
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeMemorySettings: settings)
        let bridge = NativeRuntimeMemoryBridge(store: store)
        let assistant = UUID().uuidString.lowercased(), initial = UUID().uuidString.lowercased(), retry = UUID().uuidString.lowercased()
        try bridge.bindAssistant(assistant)
        let bound = binding(assistant, role: "worker")
        try bridge.authorize(bound, query: "Current livestock?", generation: initial)
        let first = try await bridge.prepare(request(bound))
        var corrected = memory
        corrected.summary = "Current livestock: nine hens"; corrected.details = [corrected.summary]
        try repository.saveMemory(corrected, decision: .edited, note: "Synthetic retry correction", expected: memory)
        try bridge.authorize(bound, query: "Current livestock?", generation: initial)
        try await rejected { try bridge.validate(first) }
        try bridge.authorize(bound, query: "Current livestock?", generation: retry)
        let second = try await bridge.prepare(request(bound))
        try piCheck(second.scope.subject == first.scope.subject && second.memoryContext?.selected.first?.revision == 2)
        try piCheck(second.messages.first!.pi("content").piString!.contains("nine hens"))
        try piCheck(bridge.sources(conversation: second.scope.conversation, message: "task:" + second.scope.subject).first.map { NativeMemoryCitation.revision($0.url) } == 2)
        try await rejected { try bridge.validate(first) }
        try bridge.authorize(bound, query: "Current livestock?", generation: retry)
        let duplicate = try await bridge.prepare(request(bound))
        try piCheck(duplicate.memoryContext?.digest == second.memoryContext?.digest)
    }

    private static func settledContextChange(_ root: URL) async throws {
        let repository = try LocalChatRepository(url: root.appendingPathComponent("settled.sqlite"))
        let memory = try fixture(repository)
        var settings = NativeMemorySettings.fresh
        settings.enabled = true; settings.bankScope = "farm"
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeMemorySettings: settings)
        let bridge = NativeRuntimeMemoryBridge(store: store)
        let assistant = UUID().uuidString.lowercased()
        try bridge.bindAssistant(assistant)
        let provider = NativeRuntimeMemoryProvider()
        let gate = NativeRuntimeMemoryReplyGate()
        let ledger = try PiModelLedger(root: root.appendingPathComponent("settled-broker"), manifest: "shared-memory")
        let accounting = try PiSharedAccounting(root: root.appendingPathComponent("settled-provider"), baselineNanos: 0)
        let admission = PiAdmissionFixtureProtocol.admission()
        defer { admission.session.invalidateAndCancel() }
        let profile = try PiSelectedProfileBinding(profileID: "fixture", revision: UUID().uuidString.lowercased(),
            endpoint: "https://openrouter.ai/api/v1", model: "qwen/qwen3.8-flash")
        var operation = PiSelectedProfileOperation(binding: profile, admission: admission, accounting: accounting,
            validate: {}, send: { request, body in await gate.hold(); return try await provider.send(request, body) })
        operation.memoryBridge = bridge
        let broker = NativePiModelBroker(ledger: ledger, channel: "fixture", executor: operation, timeout: .seconds(10))
        let first = binding(assistant)
        try bridge.authorize(first, query: "Current livestock?")
        let firstScope = try await broker.authorize(first)
        let running = Task { try await broker.complete(NativePiModelBrokerFixture.request(firstScope, channel: "fixture", text: "Current livestock?")) }
        for _ in 0..<400 where !(await gate.waiting) { try await Task.sleep(for: .milliseconds(5)) }
        try piCheck(await gate.waiting)
        var corrected = memory
        corrected.summary = "Current livestock: nine hens"; corrected.details = [corrected.summary]
        try repository.saveMemory(corrected, decision: .edited, note: "Synthetic in-flight correction", expected: memory)
        await gate.release()
        try await rejected { _ = try await running.value }
        try piCheck(try await accounting.snapshot().piArray?.allSatisfy { $0.pi("status").piString == "completed" } == true)
        try piCheck(try ledger.snapshot().piArray?.allSatisfy { $0.pi("status").piString == "completed" } == true)
        let second = binding(assistant)
        try bridge.authorize(second, query: "Current livestock?")
        let secondScope = try await broker.authorize(second)
        let reply = try await broker.complete(NativePiModelBrokerFixture.request(secondScope, channel: "fixture", text: "Current livestock?"))
        try piCheck(reply.pi("content").piArray?.isEmpty == false)
        let sent = await provider.requests
        try piCheck(sent.count == 2 && sent[1].messages.first!.pi("content").piString!.contains("nine hens"))
        await broker.close()
        bridge.close()
        print("  shared memory: settled reply after context change rejected alone, accounting certain, next request served PASS")
    }

    private static func sendGuardNoSpend(_ root: URL) async throws {
        let repository = try LocalChatRepository(url: root.appendingPathComponent("send-guard.sqlite"))
        _ = try fixture(repository)
        var settings = NativeMemorySettings.fresh
        settings.enabled = true; settings.bankScope = "farm"
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeMemorySettings: settings)
        let assistant = UUID().uuidString.lowercased()
        let bridge = NativeRuntimeMemoryBridge(store: store)
        try bridge.bindAssistant(assistant)
        let profileID = UUID().uuidString.lowercased()
        let credentials = PiCandidateCredentials(profile: profileID)
        let owner = NativePiCandidateSelftest.config(credentials, profileID: profileID)
        let profile = try owner.piSelectedProfileBinding()
        let accounting = try PiSharedAccounting(root: root.appendingPathComponent("send-guard-accounting"), baselineNanos: 0)
        let admission = PiAdmissionFixtureProtocol.admission()
        defer { admission.session.invalidateAndCancel() }
        let transport = NativeRuntimeSendCounter()
        var operation = try owner.piSelectedProfileOperation(binding: profile, admission: admission, accounting: accounting) { _, _ in
            await transport.record()
            throw PiBrokerError.invalid
        }
        operation.memoryBridge = bridge
        let bound = binding(assistant)
        try bridge.authorize(bound, query: "Current livestock?")
        let scope = try PiModelScope(bound, profile: UUID().uuidString.lowercased())
        let request = try PiModelRequest(NativePiModelBrokerFixture.request(scope, channel: "fixture", text: "Current livestock?"), scope: scope, channel: "fixture")
        let prepared = try await bridge.prepare(request)
        try bridge.validate(prepared)
        bridge.close()
        do {
            _ = try await operation.send(prepared, Data("{}".utf8))
            throw NSError(domain: "SharedMemoryTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Send guard let a stale context through"])
        } catch let noSpend as PiNoSpendRejection {
            try piCheck((noSpend.error as? PiBrokerError) == .unauthorized)
        }
        let calls = await transport.calls
        try piCheck(calls == 0)
        print("  shared memory: stale context at the app send guard is a no-spend rejection with no transport call PASS")
    }

    private static func heldContextRejection(_ root: URL, stage: String, holdAt: Int) async throws {
        let repository = try LocalChatRepository(url: root.appendingPathComponent("held-\(stage).sqlite"))
        var memory = try fixture(repository)
        var settings = NativeMemorySettings.fresh
        settings.enabled = true; settings.bankScope = "farm"
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeMemorySettings: settings)
        let assistant = UUID().uuidString.lowercased()
        let profile = try PiSelectedProfileBinding(profileID: "fixture", revision: UUID().uuidString.lowercased(),
            endpoint: "https://openrouter.ai/api/v1", model: "qwen/qwen3.8-flash")
        for pass in 0..<2 {
            let bridge = NativeRuntimeMemoryBridge(store: store)
            try bridge.bindAssistant(assistant)
            let provider = NativeRuntimeMemoryProvider()
            let gate = NativeRuntimeMemoryGrantGate()
            let ledger = try PiModelLedger(root: root.appendingPathComponent("held-\(stage)-broker"), manifest: "shared-memory")
            let accounting = try PiSharedAccounting(root: root.appendingPathComponent("held-\(stage)-provider"), baselineNanos: 0)
            let admission = PiAdmissionFixtureProtocol.admission()
            defer { admission.session.invalidateAndCancel() }
            var operation = PiSelectedProfileOperation(binding: profile, admission: admission, accounting: accounting,
                validate: { await gate.wait() }, send: { request, body in try await provider.send(request, body) })
            operation.memoryBridge = bridge
            let broker = NativePiModelBroker(ledger: ledger, channel: "fixture", executor: operation, timeout: .seconds(10))
            if pass == 0 {
                let held = binding(assistant)
                try bridge.authorize(held, query: "Current livestock?")
                let scope = try await broker.authorize(held)
                await gate.hold(at: holdAt)
                let running = Task { try await broker.complete(NativePiModelBrokerFixture.request(scope, channel: "fixture", text: "Current livestock?")) }
                for _ in 0..<400 where !(await gate.waiting) { try await Task.sleep(for: .milliseconds(5)) }
                try piCheck(await gate.waiting)
                var corrected = memory
                corrected.summary = "Current livestock: nine hens"; corrected.details = [corrected.summary]
                try repository.saveMemory(corrected, decision: .edited, note: "Synthetic correction during admission", expected: memory)
                memory = corrected
                await gate.release()
                do {
                    _ = try await running.value
                    throw NSError(domain: "SharedMemoryTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Held grant served stale context"])
                } catch PiBrokerError.unauthorized { }
                try piCheck(await provider.requests.isEmpty)
            }
            for snapshot in [try ledger.snapshot(), try await accounting.snapshot()] {
                try piCheck(snapshot.piArray?.contains { $0.pi("status").piString == "uncertain" } == false)
            }
            let fresh = binding(assistant)
            try bridge.authorize(fresh, query: "Current livestock?")
            let scope = try await broker.authorize(fresh)
            let reply = try await broker.complete(NativePiModelBrokerFixture.request(scope, channel: "fixture", text: "Current livestock?"))
            try piCheck(reply.pi("content").piArray?.isEmpty == false)
            let sent = await provider.requests
            try piCheck(sent.count == 1 && sent[0].messages.first!.pi("content").piString!.contains("nine hens"))
            for snapshot in [try ledger.snapshot(), try await accounting.snapshot()] {
                try piCheck(snapshot.piArray?.contains { $0.pi("status").piString == "uncertain" } == false)
            }
            await broker.close()
            bridge.close()
        }
        print("  shared memory: context change during \(stage) rejected with no spend, broker and reopened ledger keep serving PASS")
    }

    private static func brokerLifecycle(_ root: URL) async throws {
        for reason in ["close", "expiry"] {
            let ledger = try PiModelLedger(root: root.appendingPathComponent("lifecycle-" + reason), manifest: "shared-memory")
            let executor = NativeRuntimeHeldPreparation()
            let broker = NativePiModelBroker(ledger: ledger, channel: "fixture", executor: executor,
                expires: Date().addingTimeInterval(reason == "expiry" ? 0.15 : 10))
            let scope = try await broker.authorize(NativePiModelBrokerFixture.binding())
            let wire = NativePiModelBrokerFixture.request(scope, channel: "fixture")
            let running = Task { try await broker.complete(wire) }
            for _ in 0..<200 where !(await executor.waiting) { try await Task.sleep(for: .milliseconds(5)) }
            try piCheck(await executor.waiting)
            if reason == "close" { await broker.close() }
            else { try await Task.sleep(for: .milliseconds(180)) }
            await executor.release()
            try await rejected { _ = try await running.value }
            try piCheck(await executor.calls == 0)
            try piCheck(try ledger.snapshot().piArray?.isEmpty == true)
            await broker.close()
        }
    }

    private static func dispatch(_ root: URL, store: ChatStore, assistant: String) async throws {
        let bridge = NativeRuntimeMemoryBridge(store: store)
        try bridge.bindAssistant(assistant)
        let bound = binding(assistant, role: "worker")
        try bridge.authorize(bound, query: "Current livestock?")
        let provider = NativeRuntimeMemoryProvider()
        let gate = NativeRuntimeMemoryDispatchGate()
        let accounting = try PiSharedAccounting(root: root.appendingPathComponent("dispatch"), baselineNanos: 0)
        let admission = PiAdmissionFixtureProtocol.admission()
        defer { admission.session.invalidateAndCancel() }
        let profile = try PiSelectedProfileBinding(profileID: "fixture", revision: UUID().uuidString.lowercased(), endpoint: "https://openrouter.ai/api/v1", model: "qwen/qwen3.8-flash")
        var operation = PiSelectedProfileOperation(binding: profile, admission: admission, accounting: accounting,
            validate: { await gate.wait() }, send: { request, body in try await provider.send(request, body) })
        operation.memoryBridge = bridge
        let ready = try request(bound)
        let task = Task { try await operation.complete(ready) }
        for _ in 0..<200 where !(await gate.waiting) { try await Task.sleep(for: .milliseconds(5)) }
        try piCheck(await gate.waiting)
        bridge.revoke(ready.scope.subject)
        await gate.release()
        try await rejected { _ = try await task.value }
        try piCheck(await provider.requests.isEmpty)
    }
}

private actor NativeRuntimeMemoryDispatchGate {
    var waiting = false
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        calls += 1
        if calls == 2 { waiting = true; await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor NativeRuntimeMemoryReplyGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        guard !waiting else { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor NativeRuntimeMemoryGrantGate {
    var waiting = false
    private var calls = 0
    private var holdAt: Int?
    private var continuation: CheckedContinuation<Void, Never>?
    func hold(at call: Int) { holdAt = calls + call }
    func wait() async {
        calls += 1
        if calls == holdAt { waiting = true; await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor NativeRuntimeHeldPreparation: PiMockModelExecutor {
    var waiting = false
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func prepareRequest(_ request: PiModelRequest) async throws -> PiModelRequest {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
        return request
    }
    func release() { continuation?.resume(); continuation = nil }
    func complete(_ request: PiModelRequest) async throws -> PiValue {
        calls += 1
        return try await PiFixtureModel().complete(request)
    }
}

private actor NativeRuntimeHeldValidation: PiMockModelExecutor {
    var waiting = false
    var calls = 0
    private var validations = 0
    private var holdAt: Int?
    private var continuation: CheckedContinuation<Void, Never>?
    func holdNextDelivery() { holdAt = validations + 2 }
    func validateRequest(_ request: PiModelRequest) async throws {
        validations += 1
        if validations == holdAt { waiting = true; await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
    func complete(_ request: PiModelRequest) async throws -> PiValue {
        calls += 1
        return try await PiFixtureModel().complete(request)
    }
}

private actor NativeRuntimeSendCounter {
    var calls = 0
    func record() { calls += 1 }
}
