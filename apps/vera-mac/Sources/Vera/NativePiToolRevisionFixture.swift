import Foundation

actor PiToolDispatchGate {
    var entered = false
    var released = false
    var sends = 0
    func wait() async throws {
        entered = true
        while !released { try await Task.sleep(for: .milliseconds(5)) }
    }
    func release() { released = true }
    func send() { sends += 1 }
}

actor PiHostToolHeldExecutor: PiMockModelExecutor {
    var waiting = false
    var calls = 0
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    func holdNext() { hold = true }
    func validateRequest(_ request: PiModelRequest) async throws {
        try await request.validateHostTools()
        guard hold else { return }
        hold = false
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func complete(_ request: PiModelRequest) async throws -> PiValue {
        calls += 1
        return try await PiFixtureModel().complete(request)
    }
}

enum NativePiToolRevisionFixture {
    static func exercise(_ root: URL) async throws {
        let service = PiToolFixtureService()
        let ledger = try PiModelLedger(root: root.appendingPathComponent("broker"), manifest: "epoch-fixture")
        let model = PiCountingFixture()
        let broker = NativePiModelBroker(ledger: ledger, channel: "tools-channel", executor: model, tools: service)
        let binding = NativePiModelBrokerFixture.binding()
        let scope = try await broker.authorize(binding)
        let modelWire = NativePiModelBrokerFixture.request(scope, channel: "tools-channel")
        let toolWire = NativePiRuntimeToolFixture.operation(scope)
        _ = try await broker.complete(modelWire)
        _ = try await broker.complete(modelWire)
        _ = try await broker.toolOperation(toolWire)
        _ = try await broker.toolOperation(toolWire)
        await service.configure(enabled: false)
        await service.configure(enabled: true)
        try await NativePiRuntimeToolFixture.refuses { _ = try await broker.complete(modelWire) }
        try await NativePiRuntimeToolFixture.refuses { _ = try await broker.toolOperation(toolWire) }
        try await NativePiRuntimeToolFixture.refuses { _ = try await broker.toolOperation(NativePiRuntimeToolFixture.operation(scope, callID: "not-yet-dispatched")) }
        try NativePiModelBrokerFixture.check(await service.calls == 1)
        try NativePiModelBrokerFixture.check(await model.calls == 1)
        await broker.close()
        let reopened = NativePiModelBroker(ledger: ledger, channel: "tools-channel", executor: model, tools: service)
        let repeated = try await reopened.authorize(binding)
        try await NativePiRuntimeToolFixture.refuses {
            _ = try await reopened.complete(NativePiModelBrokerFixture.request(repeated, channel: "tools-channel", id: modelWire.pi("id").piString!))
        }
        try await NativePiRuntimeToolFixture.refuses { _ = try await reopened.toolOperation(NativePiRuntimeToolFixture.operation(repeated)) }
        let fresh = try await reopened.authorize(NativePiModelBrokerFixture.binding())
        _ = try await reopened.toolOperation(NativePiRuntimeToolFixture.operation(fresh))
        await service.reconnect()
        try await NativePiRuntimeToolFixture.refuses { _ = try await reopened.toolOperation(NativePiRuntimeToolFixture.operation(fresh)) }
        let racing = try await reopened.authorize(NativePiModelBrokerFixture.binding())
        await service.changeCatalogRevision()
        try await NativePiRuntimeToolFixture.refuses { _ = try await reopened.toolCatalog(racing) }
        await reopened.close()
        try await heldDispatch(root.appendingPathComponent("dispatch"))
        try await heldOwnerEntry(root.appendingPathComponent("owner-entry"))
        try await memoryDigest(root.appendingPathComponent("memory"))
        try await heldHostToolDispatch(root.appendingPathComponent("held-tools"))
    }
    static func heldHostToolDispatch(_ root: URL) async throws {
        for pass in 0..<2 {
            let service = PiToolFixtureService()
            let ledger = try PiModelLedger(root: root, manifest: "epoch-fixture")
            let model = PiHostToolHeldExecutor()
            let broker = NativePiModelBroker(ledger: ledger, channel: "tools-channel", executor: model, tools: service)
            if pass == 0 {
                let scope = try await broker.authorize(NativePiModelBrokerFixture.binding())
                await model.holdNext()
                let running = Task { try await broker.complete(NativePiModelBrokerFixture.request(scope, channel: "tools-channel")) }
                let deadline = ContinuousClock.now + .seconds(3)
                while await !model.waiting {
                    guard ContinuousClock.now < deadline else { running.cancel(); throw PiBrokerError.invalid }
                    try await Task.sleep(for: .milliseconds(5))
                }
                await service.reconnect()
                await model.release()
                do {
                    _ = try await running.value
                    throw PiBrokerError.invalid
                } catch PiBrokerError.unauthorized { }
                try NativePiModelBrokerFixture.check(await model.calls == 0)
            }
            try NativePiModelBrokerFixture.check(try ledger.snapshot().piArray?.contains { $0.pi("status").piString == "uncertain" } == false)
            let fresh = try await broker.authorize(NativePiModelBrokerFixture.binding())
            _ = try await broker.complete(NativePiModelBrokerFixture.request(fresh, channel: "tools-channel"))
            try NativePiModelBrokerFixture.check(await model.calls == 1)
            try NativePiModelBrokerFixture.check(try ledger.snapshot().piArray?.contains { $0.pi("status").piString == "uncertain" } == false)
            await broker.close()
        }
    }
    static func heldDispatch(_ root: URL) async throws {
        let service = PiToolFixtureService()
        let scope = try PiModelScope(NativePiModelBrokerFixture.binding(), profile: "fixture")
        let snapshot = try await PiRuntimeToolSnapshot.capture(scope: scope, authority: service)
        let request = try PiModelRequest(NativePiModelBrokerFixture.request(scope, channel: "held"), scope: scope, channel: "held", hostTools: snapshot.schemas, hostToolRevision: snapshot.revision, hostToolAuthority: service)
        let gate = PiToolDispatchGate()
        let binding = try PiSelectedProfileBinding(profileID: "fixture", revision: UUID().uuidString.lowercased(), endpoint: "https://openrouter.ai/api/v1", model: "qwen/qwen3.8-flash")
        let admission = PiAdmissionFixtureProtocol.admission()
        defer { admission.session.invalidateAndCancel() }
        let accounting = try PiSharedAccounting(root: root, baselineNanos: 0)
        let operation = PiSelectedProfileOperation(binding: binding, admission: admission, accounting: accounting, validate: { try await gate.wait() }, send: { _, _ in
            await gate.send()
            throw PiBrokerError.invalid
        })
        let running = Task { try await operation.complete(request) }
        while await !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        await service.configure(enabled: false)
        await service.configure(enabled: true)
        await gate.release()
        try await NativePiRuntimeToolFixture.refuses { _ = try await running.value }
        try NativePiModelBrokerFixture.check(await gate.sends == 0)
    }
    @MainActor
    static func heldOwnerEntry(_ root: URL) async throws {
        let service = PiToolFixtureService()
        let scope = try PiModelScope(NativePiModelBrokerFixture.binding(), profile: "fixture")
        let snapshot = try await PiRuntimeToolSnapshot.capture(scope: scope, authority: service)
        let request = try PiModelRequest(NativePiModelBrokerFixture.request(scope, channel: "owner-entry"), scope: scope, channel: "owner-entry", hostTools: snapshot.schemas, hostToolRevision: snapshot.revision, hostToolAuthority: service)
        let profileID = UUID().uuidString.lowercased()
        let config = NativePiCandidateSelftest.config(PiCandidateCredentials(profile: profileID), profileID: profileID)
        let binding = try config.piSelectedProfileBinding()
        let admission = PiAdmissionFixtureProtocol.admission()
        defer { admission.session.invalidateAndCancel() }
        let accounting = try PiSharedAccounting(root: root, baselineNanos: 0)
        let counter = PiToolDispatchGate()
        let operation = try config.piSelectedProfileOperation(binding: binding, admission: admission, accounting: accounting) { _, _ in
            await counter.send()
            throw PiBrokerError.invalid
        }
        let body = try PiProviderCodec.body(request, model: binding.model).piData()
        let entry = PiToolDispatchGate()
        let running = Task.detached {
            try await operation.validateRequest(request)
            try await entry.wait()
            return try await operation.send(request, body)
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while await !entry.entered {
            guard ContinuousClock.now < deadline else { running.cancel(); throw PiBrokerError.invalid }
            try await Task.sleep(for: .milliseconds(5))
        }
        await service.configure(enabled: false)
        await service.configure(enabled: true)
        await entry.release()
        var rejected = false
        do { _ = try await running.value } catch { rejected = true }
        try NativePiModelBrokerFixture.check(rejected)
        let sends = await counter.sends
        if sends != 0 { print("FAIL: owner fixture transport ran after revocation") }
        try NativePiModelBrokerFixture.check(sends == 0)
    }
    @MainActor
    static func memoryDigest(_ root: URL) async throws {
        let repository = try LocalChatRepository(url: root.appendingPathExtension("sqlite"))
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository)
        let memory = NativeRuntimeMemoryBridge(store: store)
        let service = PiToolFixtureService()
        let scope = try PiModelScope(NativePiModelBrokerFixture.binding(), profile: "fixture")
        let wire = NativePiModelBrokerFixture.request(scope, channel: "memory")
        let first = try await PiRuntimeToolSnapshot.capture(scope: scope, authority: service)
        let request = try PiModelRequest(wire, scope: scope, channel: "memory", hostTools: first.schemas, hostToolRevision: first.revision, hostToolAuthority: service)
        let context = NativeRuntimeMemoryContext(authority: UUID(), binding: scope.wire, generation: scope.subject, selected: [], prompt: "Fixture memory", digest: "fixture-context")
        let augmented = try request.withMemoryContext(context, authority: memory)
        try NativePiModelBrokerFixture.check(augmented.hostToolRevision == request.hostToolRevision && augmented.hostTools == request.hostTools)
        try await augmented.validateHostTools()
        await service.reconnect()
        let next = try await PiRuntimeToolSnapshot.capture(scope: scope, authority: service)
        let changed = try PiModelRequest(wire, scope: scope, channel: "memory", hostTools: next.schemas, hostToolRevision: next.revision, hostToolAuthority: service)
        let changedMemory = try changed.withMemoryContext(context, authority: memory)
        try NativePiModelBrokerFixture.check(request.digest != changed.digest && augmented.digest != changedMemory.digest)
        var rejected = false
        do { try await augmented.validateHostTools() } catch { rejected = true }
        try NativePiModelBrokerFixture.check(rejected)
    }
}
