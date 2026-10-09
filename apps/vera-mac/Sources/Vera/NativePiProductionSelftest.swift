import Foundation

@MainActor
enum NativePiProductionSelftest {
    static func run(_ arguments: [String], config: ConfigStore, http: PiProviderHTTP, admission: NativeInferenceAdmission, root: URL) async throws {
        print("Production fixture: spending policy")
        let root = root.appendingPathComponent("production")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let state = NativePiSpendingPolicy.State(schema: 1, id: UUID(), ceilingNanos: 200_000_000_000,
            historicalHoldsNanos: 5_000_000_000, allowanceNanos: 1_000_000_000, observedUsageNanos: 0)
        let file = root.appendingPathComponent("spending.json")
        try JSONEncoder().encode(state).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let policy = try NativePiSpendingPolicy(root: root)
        try policy.observe(500_000_000)
        try policy.observe(250_000_000)
        try piCheck(policy.state.observedUsageNanos == 500_000_000)
        try await NativePiProviderSelftest.reject { try policy.observe(199_000_000_000) }
        try piCheck(policy.state.observedUsageNanos == 500_000_000)
        try await unsentRecovery(config: config, http: http, admission: admission, policy: policy, root: root)
        var runtime: [String] = []
        for index in stride(from: 0, to: arguments.count, by: 2) where arguments[index] != "--root" {
            runtime += [arguments[index], arguments[index + 1]]
        }
        let taskID = try await phase(root: root, config: config, http: http, admission: admission, arguments: runtime, reopen: nil)
        _ = try await phase(root: root, config: config, http: http, admission: admission, arguments: runtime, reopen: taskID)
        let saved = try NativePiSpendingPolicy(root: root)
        try piCheck(saved.binding == policy.binding && saved.state.observedUsageNanos == 500_000_000)
        print("PASS: ordinary production factory, persistent allowance, thirteen replies, document and restart without new inference; injected HTTP only")
    }
    static func unsentRecovery(config: ConfigStore, http: PiProviderHTTP, admission: NativeInferenceAdmission, policy: NativePiSpendingPolicy, root: URL) async throws {
        PiProviderFixtureProtocol.state.configure("production")
        let binding = try config.piSelectedProfileBinding()
        let provider = try await PiPreparedProvider.production(owner: config, binding: binding, policy: policy,
            accountingRoot: root.appendingPathComponent("unsent-accounting"), admission: admission, http: http)
        let ledger = try PiModelLedger(root: root.appendingPathComponent("unsent-broker"), manifest: "production-test", requestLimit: 1000)
        let broker = NativePiModelBroker(ledger: ledger, channel: "test", executor: provider.executor)
        let scope = try await broker.authorize(NativePiModelBrokerFixture.binding())
        let request = NativePiModelBrokerFixture.request(scope, channel: "test")
        PiProviderFixtureProtocol.state.configure("status")
        try await NativePiProviderSelftest.reject { _ = try await broker.complete(request) }
        try piCheck(try ledger.snapshot().piArray!.isEmpty)
        try piCheck(try await provider.accounting.snapshot().piArray!.isEmpty)
        PiProviderFixtureProtocol.state.configure("production")
        _ = try await broker.complete(request)
        try piCheck(try ledger.snapshot().piArray!.count == 1)
        let refused = try await broker.authorize(NativePiModelBrokerFixture.binding())
        PiAdmissionFixtureProtocol.state.setUnavailable(true)
        defer { PiAdmissionFixtureProtocol.state.setUnavailable(false) }
        try await NativePiProviderSelftest.reject { _ = try await broker.complete(NativePiModelBrokerFixture.request(refused, channel: "test")) }
        let refusedRows = try ledger.snapshot().piArray!
        try piCheck(refusedRows.count == 2 && refusedRows.last?.pi("status") == .string("not_sent") && refusedRows.last?.pi("charged") == .number(0))
        try piCheck(try await provider.accounting.snapshot().piArray!.count == 1)
        PiAdmissionFixtureProtocol.state.setUnavailable(false)
        let resumed = try await broker.authorize(NativePiModelBrokerFixture.binding())
        _ = try await broker.complete(NativePiModelBrokerFixture.request(resumed, channel: "test"))
        let changed = try await broker.authorize(NativePiModelBrokerFixture.binding())
        PiProviderFixtureProtocol.state.configure("checkpoint")
        try await NativePiProviderSelftest.reject { _ = try await broker.complete(NativePiModelBrokerFixture.request(changed, channel: "test")) }
        try piCheck(try ledger.snapshot().piArray!.count == 3)
        await broker.close()
    }
    static func phase(root: URL, config: ConfigStore, http: PiProviderHTTP, admission: NativeInferenceAdmission,
                      arguments: [String], reopen: String?) async throws -> String {
        PiProviderFixtureProtocol.state.configure("production")
        let repository = try LocalChatRepository(url: root.appendingPathComponent("focused.sqlite"))
        var memory = NativeMemorySettings.fresh
        memory.enabled = false
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeMemorySettings: memory)
        let presentation = NativePiProduction.presentation(config: config, store: store, root: root, http: http, admission: admission, arguments: arguments)
        try piCheck(presentation.canConnect)
        await presentation.connect()
        do {
            guard let session = presentation.session else {
                print("Production fixture startup: \(presentation.failure ?? "unknown")")
                throw PiBrokerError.unavailable
            }
            if let reopen {
                try piCheck(session.tasks.count == 1 && session.tasks[0].id == reopen && session.tasks[0].state == "completed")
                try piCheck(session.output(taskID: reopen, index: 0) != nil)
                try piCheck(PiProviderFixtureProtocol.state.calls().filter { $0 == "completions" }.isEmpty)
                await presentation.stop()
                return reopen
            }
            print("Production fixture: connected")
            for number in 1...13 {
                session.setDraft("Short reply \(number)")
                await session.send()
                if session.pendingID != nil || !session.canCreateDocument { print("Production fixture reply \(number): \(session.error ?? "unknown")") }
                try piCheck(session.pendingID == nil && session.canCreateDocument)
            }
            print("Production fixture: document")
            await session.createDocument(title: "Ordinary launch document", brief: "Summarize supplied notes.", inputs: "Prepare and discuss.")
            let task = try await NativePiTaskStreamFixture.task(session, state: "completed")
            print("Production fixture: completed")
            try piCheck(task.outputs.count == 1 && session.output(taskID: task.id, index: 0) != nil)
            try piCheck(PiProviderFixtureProtocol.state.calls().filter { $0 == "completions" }.count == 16)
            await presentation.stop()
            return task.id
        } catch { print("Production fixture: calls \(PiProviderFixtureProtocol.state.calls())"); await presentation.stop(); throw error }
    }
}
