import Foundation

@MainActor
enum NativePiProviderSelftest {
    static func reject(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch { return }
        throw PiBrokerError.invalid
    }
    static func permit(_ binding: PiSelectedProfileBinding, other: Int64 = 4_000_000_000, usage: Int64 = 250_000_000, holds: Int64 = 1_000_000_000, reservations: Int64 = 500_000_000, allowance: Int64 = 10_000_000, expires: Date = Date().addingTimeInterval(300), exclusive: Bool = true) throws -> PiCumulativeBudget {
        try PiCumulativeBudget(id: UUID().uuidString.lowercased(), ownerBinding: binding.digest, otherTestSpend: other, priorProviderUsage: usage, uncertaintyHolds: holds, externalReservations: reservations, runAllowance: allowance, expires: expires, exclusiveOwner: exclusive)
    }
    static func rules(_ binding: PiSelectedProfileBinding) async throws {
        let policy = try permit(binding)
        try piCheck(try policy.baseline(observedProviderUsage: 250_000_000) == 5_750_000_000)
        try await reject { _ = try policy.baseline(observedProviderUsage: 249_999_999) }
        try await reject { _ = try permit(binding, other: 199_000_000_000) }
        try await reject { _ = try permit(binding, allowance: 1_000_000_001) }
        try await reject { _ = try permit(binding, expires: .distantPast) }
        try await reject { _ = try permit(binding, exclusive: false) }
        try await reject { try policy.validate(binding, now: .distantFuture) }
        for value in ["1x", "", "-1", "nan", "0.01junk", "201", " 0.1", "1\n"] {
            try await reject { _ = try PiProviderPreflight.amount(.string(value)) }
        }
        try piCheck(try PiProviderPreflight.nanos(.string("0.0000000001")) == 1)
        try PiProviderPreflight.catalog(PiProviderFixtureState.catalog.piData(), model: binding.model)
        let largeCatalog = try PiProviderFixtureState.catalog.piData() + Data(repeating: 32, count: 1_100_000)
        try PiProviderPreflight.catalog(largeCatalog, model: binding.model)
        try await reject { try NativeTaskJSON.validate(largeCatalog) }
        let selected = PiProviderFixtureState.catalog.pi("data").piArray![0]
        var variants: [PiValue] = [NativePiModelBrokerFixture.changed(selected, "alias_target", .string("other")), NativePiModelBrokerFixture.changed(selected, "reasoning", .object(["mandatory": .bool(true)])), NativePiModelBrokerFixture.changed(selected, "supported_parameters", .array([]))]
        for (name, value) in [("prompt", "0.1"), ("completion", "0.1"), ("request", "0.001"), ("input_cache_write", "0.1"), ("future_charge", "0.1")] {
            let pricing = NativePiModelBrokerFixture.changed(selected.pi("pricing"), name, .string(value))
            variants.append(NativePiModelBrokerFixture.changed(selected, "pricing", pricing))
        }
        for invalid in variants {
            try await reject { try PiProviderPreflight.catalog(PiValue.object(["data": .array([invalid])]).piData(), model: binding.model) }
        }
        try await reject { try PiProviderPreflight.catalog(PiValue.object(["data": .array([selected, selected])]).piData(), model: binding.model) }
        let http = PiProviderFixtureProtocol.http()
        var request = URLRequest(url: binding.endpoint.appendingPathComponent("key"))
        request.setValue("Bearer " + PiCandidateCredentials.key, forHTTPHeaderField: "Authorization")
        request.httpMethod = "GET"
        PiProviderFixtureProtocol.state.configure("normal")
        for url in ["http://openrouter.ai/api/v1/key", "https://openrouter.ai/api/v1/key?x=y", "https://forbidden.invalid/api/v1/key"] {
            var bad = request; bad.url = URL(string: url)
            try await reject { _ = try await http.send(bad) }
        }
        var bad = request; bad.setValue("extra", forHTTPHeaderField: "X-Unsafe")
        try await reject { _ = try await http.send(bad) }
        bad = request; bad.httpBody = Data([1])
        try await reject { _ = try await http.send(bad) }
        try piCheck(PiProviderFixtureProtocol.state.calls().isEmpty)
        for behavior in ["status", "redirect", "oversize", "declared", "timeout"] {
            PiProviderFixtureProtocol.state.configure(behavior)
            try await reject { _ = try await http.send(request) }
            try piCheck(PiProviderFixtureProtocol.state.calls() == ["key"])
        }
        PiProviderFixtureProtocol.state.configure("normal")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: [:])!
        try piCheck(await http.urlSession(session, task: session.dataTask(with: request), willPerformHTTPRedirection: response, newRequest: request) == nil)
    }
    static func run(_ arguments: [String]) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-provider-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            umask(0o077)
            let profile = UUID().uuidString.lowercased(), credentials = PiCandidateCredentials(profile: UUID().uuidString.lowercased())
            let fixtureCredentials = PiCandidateCredentials(profile: profile)
            let config = NativePiCandidateSelftest.config(fixtureCredentials, profileID: profile)
            let binding = try config.piSelectedProfileBinding()
            try await rules(binding)
            let permit = try permit(binding)
            let http = PiProviderFixtureProtocol.http(), admission = PiAdmissionFixtureProtocol.admission()
            defer { admission.session.invalidateAndCancel() }
            PiProviderFixtureProtocol.state.configure("normal")
            try await reject { _ = try await PiPreparedProvider.prepare(owner: config, admission: nil, permit: permit, accountingRoot: root.appendingPathComponent("absent"), http: http, transport: .providerFixture) }
            try piCheck(PiProviderFixtureProtocol.state.calls().isEmpty)
            config.nativeSettings.profiles[0].selectedModel = "unsaved"
            try await reject { _ = try await PiPreparedProvider.prepare(owner: config, admission: admission, permit: permit, accountingRoot: root.appendingPathComponent("dirty"), http: http, transport: .providerFixture) }
            try piCheck(PiProviderFixtureProtocol.state.calls().isEmpty)
            config.nativeSettings.profiles[0].selectedModel = binding.model
            for behavior in ["echo", "metadata-echo", "malformed"] {
                PiProviderFixtureProtocol.state.configure(behavior)
                try await reject { _ = try await PiPreparedProvider.prepare(owner: config, admission: admission, permit: permit, accountingRoot: root.appendingPathComponent(behavior), http: http, transport: .providerFixture) }
                try piCheck(PiProviderFixtureProtocol.state.calls() == ["models"])
            }
            PiProviderFixtureProtocol.state.configure("normal")
            let prepared = try await PiPreparedProvider.prepare(owner: config, admission: admission, permit: permit, accountingRoot: root.appendingPathComponent("accounting"), http: http, transport: .providerFixture)
            try piCheck(PiProviderFixtureProtocol.state.calls() == ["models", "key"])
            try piCheck(prepared.accounting.ledger.baseline == 5_750_000_000 && prepared.accounting.ledger.budget == 5_760_000_000)
            let ledger = try PiModelLedger(root: root.appendingPathComponent("broker"), manifest: "provider-fixture", transport: .providerFixture)
            let broker = NativePiModelBroker(ledger: ledger, channel: "fixture", executor: prepared.executor)
            let scope = try await broker.authorize(NativePiModelBrokerFixture.binding())
            let wire = NativePiModelBrokerFixture.request(scope, channel: "fixture")
            let first = try await broker.complete(wire), replay = try await broker.complete(wire)
            try piCheck(first == replay && PiProviderFixtureProtocol.state.calls() == ["models", "key", "completions"])
            config.nativeSettings.profiles[0].selectedModel = "unsaved"
            try await reject { _ = try await broker.complete(wire) }
            config.nativeSettings.profiles[0].selectedModel = binding.model
            let secret = NativePiModelBrokerFixture.request(scope, channel: "fixture", text: PiCandidateCredentials.key)
            try await reject { _ = try await broker.complete(secret) }
            try piCheck(PiProviderFixtureProtocol.state.calls().count == 3)
            let rows = try await prepared.accounting.snapshot().piArray!
            try piCheck(rows.count == 2 && rows.last?.pi("status").piString == "rejected")
            try piCheck(try broker.ledger.snapshot().piArray!.map { $0.pi("status").piString! } == ["completed", "rejected"])
            _ = try await broker.complete(NativePiModelBrokerFixture.request(scope, channel: "fixture"))
            try piCheck(PiProviderFixtureProtocol.state.calls().count == 4 && credentials.reads == 0)
            try await expiredReplay(config: config, binding: binding, http: http, root: root)
            try await failurePaths(config: config, binding: binding, http: http, admission: admission, root: root)
            try await documentRetry(config: config, binding: binding, http: http, admission: admission, root: root)
            if !arguments.isEmpty {
                try await NativePiProductionSelftest.run(arguments, config: config, http: http, admission: admission, root: root)
                try await workflow(arguments, config: config, binding: binding, http: http, admission: admission, root: root)
                try await memoryReplay(arguments, config: config, binding: binding, http: http, admission: admission, root: root)
                try await NativeRuntimeMemoryRetryContract.run(arguments, config: config, binding: binding, admission: admission, root: root)
            }
            try NativePiCandidate.verifyNoCredentialFiles(root)
            print("PASS: provider HTTP fixtures, preflight, cumulative allowance, admission, secret boundary, replay and quarantine; no real provider or credential calls")
        } catch {
            FileHandle.standardError.write(Data("Provider wiring fixture failed: \(type(of: error)) \(error)\n".utf8))
            exit(1)
        }
    }
    static func documentRetry(config: ConfigStore, binding: PiSelectedProfileBinding, http: PiProviderHTTP,
                              admission: NativeInferenceAdmission, root: URL) async throws {
        PiProviderFixtureProtocol.state.configure("normal")
        let provider = try await PiPreparedProvider.prepare(owner: config, admission: admission, permit: permit(binding),
            accountingRoot: root.appendingPathComponent("document-accounting"), http: http, transport: .providerFixture)
        let ledger = try PiModelLedger(root: root.appendingPathComponent("document-broker"), manifest: "fixture")
        let broker = NativePiModelBroker(ledger: ledger, channel: "fixture", executor: provider.executor)
        let scope = try await broker.authorize(NativePiModelBrokerFixture.binding(role: "document"))
        let wire = NativePiModelBrokerFixture.request(scope, channel: "fixture")
        let request = try PiModelRequest(wire, scope: scope, channel: "fixture")
        try piCheck(PiProviderCodec.tools(scope).isEmpty && request.hostTools.isEmpty)
        try await reject { try PiModelRequest.arguments(.object([:]), name: "delegate", scope: scope) }
        PiProviderFixtureProtocol.state.configure("status")
        try await reject { _ = try await broker.complete(wire) }
        PiProviderFixtureProtocol.state.configure("normal")
        try await reject { _ = try await broker.complete(NativePiModelBrokerFixture.request(scope, channel: "fixture")) }
        try piCheck(PiProviderFixtureProtocol.state.calls().isEmpty)
        let foreground = try await broker.authorize(NativePiModelBrokerFixture.binding())
        _ = try await broker.complete(NativePiModelBrokerFixture.request(foreground, channel: "fixture"))
        try await broker.retryDocument(scope.subject)
        _ = try await broker.complete(NativePiModelBrokerFixture.request(scope, channel: "fixture"))
        let shared = try await provider.accounting.snapshot().piArray!
        let local = try ledger.snapshot().piArray!
        try piCheck(shared.count == 3 && local.count == 3)
        for rows in [shared, local] {
            try piCheck(rows[0].pi("status") == .string("abandoned") && rows[0].pi("reserved") == .number(1_000_000)
                && rows[0].pi("charged") == .null && rows[2].pi("status") == .string("completed"))
        }
        await broker.close()
    }
    static func expiredReplay(config: ConfigStore, binding: PiSelectedProfileBinding, http: PiProviderHTTP, root: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PiProviderDelayedAdmission.self]
        let admission = NativeInferenceAdmission(baseURL: URL(string: "https://admission.invalid")!, session: URLSession(configuration: configuration))
        defer { admission.session.invalidateAndCancel() }
        let policy = try permit(binding, expires: Date().addingTimeInterval(0.5))
        PiProviderFixtureProtocol.state.configure("normal")
        let provider = try await PiPreparedProvider.prepare(owner: config, admission: admission, permit: policy, accountingRoot: root.appendingPathComponent("expired-replay"), http: http, transport: .providerFixture)
        let ledger = try PiModelLedger(root: root.appendingPathComponent("expired-broker"), manifest: "fixture")
        let broker = NativePiModelBroker(ledger: ledger, channel: "fixture", executor: provider.executor)
        let scope = try await broker.authorize(NativePiModelBrokerFixture.binding())
        let wire = NativePiModelBrokerFixture.request(scope, channel: "fixture")
        let request = try PiModelRequest(wire, scope: scope, channel: "fixture")
        _ = try await provider.accounting.reserve(request)
        let reply = try await PiFixtureModel().complete(request)
        try await provider.accounting.settle(request, reply: reply)
        try policy.validate(binding)
        try await reject { _ = try await provider.executor.complete(request) }
        try piCheck(Date() >= policy.expires && PiProviderFixtureProtocol.state.calls() == ["models", "key"])
    }
    static func failurePaths(config: ConfigStore, binding: PiSelectedProfileBinding, http: PiProviderHTTP, admission: NativeInferenceAdmission, root: URL) async throws {
        for behavior in ["missing-cost", "escaped-echo", "nested-echo", "held"] {
            PiProviderFixtureProtocol.state.configure("normal")
            let provider = try await PiPreparedProvider.prepare(owner: config, admission: admission, permit: permit(binding), accountingRoot: root.appendingPathComponent("failure-" + behavior), http: http, transport: .providerFixture)
            let ledger = try PiModelLedger(root: root.appendingPathComponent("failure-broker-" + behavior), manifest: "fixture")
            let broker = NativePiModelBroker(ledger: ledger, channel: "fixture", executor: provider.executor)
            let scope = try await broker.authorize(NativePiModelBrokerFixture.binding())
            PiProviderFixtureProtocol.state.configure(behavior)
            let request = NativePiModelBrokerFixture.request(scope, channel: "fixture")
            if ["escaped-echo", "nested-echo"].contains(behavior) {
                let modelRequest = try PiModelRequest(request, scope: scope, channel: "fixture")
                var outgoing = URLRequest(url: binding.endpoint.appendingPathComponent("chat/completions"))
                outgoing.httpBody = try PiProviderCodec.body(modelRequest, model: binding.model).piData()
                outgoing.setValue("Bearer " + PiCandidateCredentials.key, forHTTPHeaderField: "Authorization")
                let (data, _, _, _) = try PiProviderFixtureProtocol.state.response(outgoing)
                try piCheck(data.range(of: Data(PiCandidateCredentials.key.utf8)) == nil)
                let decoded = try PiProviderCodec.reply(PiValue.piRead(data), request: modelRequest, model: binding.model)
                let block = decoded.pi("content").piArray![0]
                try piCheck((behavior == "escaped-echo" ? block.pi("text") : block.pi("arguments").pi("objective")) == .string(PiCandidateCredentials.key))
                PiProviderFixtureProtocol.state.configure(behavior)
            }
            if behavior == "held" {
                let running = Task { try await broker.complete(request) }
                for _ in 0..<100 {
                    if PiProviderFixtureProtocol.state.calls().count == 1 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try piCheck(PiProviderFixtureProtocol.state.calls().count == 1)
                await broker.cancel(request.pi("id").piString!)
                try await reject { _ = try await running.value }
                for _ in 0..<100 {
                    if PiProviderFixtureProtocol.state.stopCount() > 0 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try piCheck(PiProviderFixtureProtocol.state.stopCount() > 0)
            } else { try await reject { _ = try await broker.complete(request) } }
            try await reject { _ = try await broker.complete(NativePiModelBrokerFixture.request(scope, channel: "fixture")) }
            try piCheck(PiProviderFixtureProtocol.state.calls() == ["completions"])
            let rows = try await provider.accounting.snapshot().piArray!
            try piCheck(rows.count == 1 && rows[0].pi("status").piString == "uncertain")
        }
    }
    static func memoryReplay(_ arguments: [String], config: ConfigStore, binding: PiSelectedProfileBinding,
                             http: PiProviderHTTP, admission: NativeInferenceAdmission, root: URL) async throws {
        PiProviderFixtureProtocol.state.configure("normal")
        let provider = try await PiPreparedProvider.prepare(owner: config, admission: admission, permit: permit(binding),
            accountingRoot: root.appendingPathComponent("memory-replay-accounting"), http: http, transport: .providerFixture)
        let repository = try LocalChatRepository(url: root.appendingPathComponent("memory-replay.sqlite"))
        let record = try NativeRuntimeMemorySelftest.fixture(repository)
        var settings = NativeMemorySettings.fresh
        settings.enabled = true; settings.bankScope = "farm"
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeMemorySettings: settings)
        var runtime = arguments
        if let index = runtime.firstIndex(of: "--root") { runtime[index + 1] += "-memory-replay" }
        let initial = try await memoryReplayPhase(runtime, root: root, provider: provider, store: store, body: nil)
        try await repository.database.write { db in
            try db.execute(sql: "DELETE FROM runtime_memory_sources WHERE message NOT LIKE 'subject:%'")
        }
        let reopened = try LocalChatRepository(url: root.appendingPathComponent("memory-replay.sqlite"))
        let restored = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: reopened, nativeMemorySettings: settings)
        let repeated = try await memoryReplayPhase(runtime, root: root, provider: provider, store: restored, body: initial.0)
        try piCheck(initial.1 == repeated.1 && PiProviderFixtureProtocol.state.calls().filter { $0 == "completions" }.count == 1)
        let sources = try reopened.runtimeMemorySources(assistant: initial.0.pi("assistant_id").piString!,
            conversation: initial.0.pi("conversation_id").piString!, message: repeated.1.pi("reply_id").piString!)
        try piCheck(sources.count == 1 && NativeMemoryCitation.recordID(sources[0].url) == record.id)
        print("PASS: actual SDK completed HTTP replay after owner restart, crash-gap source recovery, one provider fixture request")
    }
    static func memoryReplayPhase(_ arguments: [String], root: URL, provider: PiPreparedProvider,
                                  store: ChatStore, body: PiValue?) async throws -> (PiValue, PiValue) {
        let session = try await NativePiPreparedSession.create(arguments: arguments, uiRoot: root.appendingPathComponent("memory-replay-ui"), provider: provider, store: store)
        do {
            let body = body ?? .object(["assistant_id": .string(session.workspace.assistantID.uuidString.lowercased()),
                "conversation_id": .string(session.workspace.session.id.uuidString.lowercased()),
                "message_id": .string(UUID().uuidString.lowercased()), "text": .string("Current livestock?"), "mode": .string("assistant")])
            var request = URLRequest(url: try await session.owner.endpoint().appendingPathComponent("assistant/messages"))
            request.httpMethod = "POST"; request.httpBody = try body.piData()
            let (data, status) = try await session.owner.http(request)
            try piCheck(status == 200)
            let reply = try PiValue.piRead(data)
            await session.owner.stop()
            return (body, reply)
        } catch { await session.owner.stop(); throw error }
    }

    static func workflow(_ arguments: [String], config: ConfigStore, binding: PiSelectedProfileBinding, http: PiProviderHTTP, admission: NativeInferenceAdmission, root: URL) async throws {
        PiProviderFixtureProtocol.state.configure("normal")
        let provider = try await PiPreparedProvider.prepare(owner: config, admission: admission, permit: permit(binding), accountingRoot: root.appendingPathComponent("workflow-accounting"), http: http, transport: .providerFixture)
        let memoryRepository = try LocalChatRepository(url: root.appendingPathComponent("shared-native.sqlite"))
        let memory = try NativeRuntimeMemorySelftest.fixture(memoryRepository)
        var relevant = memory
        relevant.title = "Isolated example"
        try memoryRepository.saveMemory(relevant, decision: .edited, note: "Synthetic task context", expected: memory)
        var memorySettings = NativeMemorySettings.fresh
        memorySettings.enabled = true; memorySettings.bankScope = "farm"
        let memoryStore = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: memoryRepository, nativeMemorySettings: memorySettings)
        let presentation = NativePiPresentation(factory: {
            try await NativePiConnection.prepared(arguments: arguments, uiRoot: root.appendingPathComponent("ui"), provider: provider, store: memoryStore)
        })
        do {
            await presentation.connect()
            guard let connection = presentation.connection, let session = presentation.session else { throw PiBrokerError.unavailable }
            try piCheck(session.connectionLabel == "Test runtime" && session.messages.isEmpty)
            let report = try PiValue.piRead(await connection.workspace.verifyWorkflow())
            await session.refresh()
            guard let projected = presentation.conversation, let completed = session.tasks.first(where: { $0.state == "completed" }) else { throw PiBrokerError.invalid }
            let resultID = NativePiPresentation.messageID(conversation: session.id, source: "task:" + completed.id)
            try piCheck(projected.messages.filter { $0.id == resultID }.count == 1
                && session.output(taskID: completed.id, index: 0) != nil)
            await presentation.stop()
            try piCheck(presentation.connection == nil && !presentation.canSend)
            try piCheck(report.pi("result_deliveries") == .number(1) && report.pi("foreground_while_worker_active") == .bool(true))
            let shared = PiProviderFixtureProtocol.state.sharedMemoryEvidence()
            try piCheck(shared.contains { $0.0 && $0.1 } && shared.contains { !$0.0 && $0.1 })
            let taskSources = projected.messages.first { $0.id == resultID }?.sources ?? []
            try piCheck(taskSources.count == 1 && NativeMemoryCitation.recordID(taskSources[0].url) == memory.id)
            let calls = PiProviderFixtureProtocol.state.calls()
            try piCheck(calls.count == 12 && calls.filter { $0 == "completions" }.count == 10)
            let rows = try await provider.accounting.snapshot().piArray!
            try piCheck(rows.count == 10 && rows.allSatisfy { $0.pi("status").piString == "completed" })
            try NativePiCandidate.verifyNoCredentialFiles(root)
            if let index = arguments.firstIndex(of: "--root"), index + 1 < arguments.count {
                try NativePiCandidate.verifyNoCredentialFiles(URL(fileURLWithPath: arguments[index + 1]))
            }
            print("PASS: actual SDK foreground and worker, prepared provider through native session adapter, HTTP provider fixture, approval and cancellation, ten accounted synthetic responses")
        } catch { await presentation.stop(); throw error }
    }
}
