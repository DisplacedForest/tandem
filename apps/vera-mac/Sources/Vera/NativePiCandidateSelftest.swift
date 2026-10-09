import Foundation
import GRDB

@MainActor
enum NativePiCandidateSelftest {
    static func rejected(_ expected: PiBrokerError, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch let error as PiBrokerError { try piCheck(error == expected); return }
        throw PiBrokerError.invalid
    }
    static func config(_ credentials: PiCandidateCredentials, profileID: String, writer: @escaping ([String: Any]) throws -> Void = { _ in }) -> ConfigStore {
        var settings = NativeChatSettings.fresh
        settings.profiles = [NativeEndpointProfile(id: profileID, name: "Test", baseURL: "https://openrouter.ai/api/v1", discoveredModels: [], selectedModel: "qwen/qwen3.8-flash", selectionBasis: .user, lastDiscoveryAt: nil)]
        settings.activeProfileID = profileID
        let raw = settings.merging(into: [:])
        return ConfigStore(credentialStore: credentials, readConfiguration: { raw }, writeConfiguration: writer)
    }
    static func run(_ arguments: [String]) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-candidate-selftest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let profileID = UUID().uuidString.lowercased()
            let credentials = PiCandidateCredentials(profile: profileID)
            var failWrite = false
            let owner = config(credentials, profileID: profileID) { _ in if failWrite { throw PiBrokerError.storage } }
            let binding = try owner.piSelectedProfileBinding()
            let counter = PiCandidateProviderFixture()
            let accounting = try PiSharedAccounting(root: root.appendingPathComponent("accounting"), baselineNanos: 0)
            let admission = PiAdmissionFixtureProtocol.admission()
            defer { admission.session.invalidateAndCancel() }
            let operation = try owner.piSelectedProfileOperation(binding: binding, admission: admission, accounting: accounting) { outgoing, request in try await counter.send(outgoing, request: request) }
            let brokerLedger = try PiModelLedger(root: root.appendingPathComponent("broker"), manifest: "selftest", ownerBinding: binding.digest)
            let broker = NativePiModelBroker(ledger: brokerLedger, channel: "selftest", executor: operation)
            let scope = try await broker.authorize(NativePiModelBrokerFixture.binding())
            let wire = NativePiModelBrokerFixture.request(scope, channel: "selftest")
            let request = try PiModelRequest(wire, scope: scope, channel: "selftest")
            let first = try await broker.complete(wire)
            let replay = try await broker.complete(wire)
            let calls = await counter.calls()
            try piCheck(first == replay && calls == 1 && credentials.reads == 2)
            owner.nativeSettings.profiles[0].selectedModel = "unsaved"
            try await rejected(.unauthorized) { _ = try await operation.complete(request) }
            try await rejected(.unauthorized) { _ = try await broker.complete(wire) }
            try await rejected(.unauthorized) { _ = try owner.piSelectedProfileBinding() }
            owner.nativeSettings.profiles[0].selectedModel = binding.model
            owner.apiKeyBinding().wrappedValue = "changed-mock-credential"
            try await rejected(.unauthorized) { _ = try await operation.complete(request) }
            try await rejected(.unauthorized) { _ = try await broker.complete(wire) }
            try await rejected(.unauthorized) { _ = try owner.piSelectedProfileBinding() }
            failWrite = true
            try await rejected(.storage) { try owner.save() }
            try await rejected(.unauthorized) { _ = try await operation.complete(request) }
            try await rejected(.unauthorized) { _ = try await broker.complete(wire) }
            let unchangedCalls = await counter.calls()
            try piCheck(unchangedCalls == 1)
            try await rejected(.unauthorized) { _ = try owner.piSelectedProfileBinding() }
            failWrite = false
            try owner.save()
            try piCheck(try owner.piSelectedProfileBinding().revision != binding.revision)
            try await rejected(.unauthorized) { _ = try owner.piSelectedProfileOperation(binding: binding, admission: admission, accounting: accounting) { _, _ in throw PiBrokerError.invalid } }
            let exhausted = try PiSharedAccounting(root: root.appendingPathComponent("exhausted"), baselineNanos: 199_999_500_000)
            try await rejected(.budget) { _ = try await exhausted.reserve(request) }
            let result: PiValue = .object(["content": .array([.object(["type": .string("text"), "text": .string("fixture")])]), "usage": .object(["input": .number(71), "output": .number(13), "cost_usd": .number(0.0000412)])])
            try PiModelReply.validate(result)
            try piCheck(PiModelReply.costNanos(result) == 41200)
            let wrong = NativePiModelBrokerFixture.changed(result, "usage", .object(["input": .number(71), "output": .number(300), "cost_usd": .number(0.0000412)]))
            try await rejected(.invalid) { try PiModelReply.validate(wrong) }
            if arguments.first == "--scope-timeout" { try await scopeTimeout(Array(arguments.dropFirst())) }
            else if !arguments.isEmpty {
                try await refusedDecision(arguments)
                try await NativePiRuntimeToolFixture.contract(arguments)
            }
            print("PASS: selected profile, partial save, credential isolation, shared allowance, receipts and durable approval boundary")
        } catch {
            FileHandle.standardError.write(Data("Candidate selftest failed: \(type(of: error))\n".utf8))
            exit(1)
        }
    }
    static func scopeTimeout(_ arguments: [String]) async throws {
        let candidate = try await NativePiCandidate.create(arguments)
        do {
            let port = try await candidate.owner.endpoint()
            var request = URLRequest(url: port.appendingPathComponent("assistant/messages"))
            request.httpMethod = "POST"
            request.httpBody = try PiValue.object(["assistant_id": .string(candidate.workspace.assistantID.uuidString.lowercased()), "conversation_id": .string(UUID().uuidString.lowercased()), "message_id": .string(UUID().uuidString.lowercased()), "mode": .string("assistant"), "text": .string("scope timeout fixture")]).piData()
            let started = ContinuousClock.now
            try await rejected(.unavailable) { _ = try await candidate.owner.http(request) }
            try piCheck(started.duration(to: .now) < .seconds(5))
            let calls = await candidate.provider.calls()
            try piCheck(calls == 0)
            await candidate.stop()
        } catch { await candidate.stop(); throw error }
    }
    static func refusedDecision(_ arguments: [String]) async throws {
        let candidate = try await NativePiCandidate.create(arguments, httpTransport: { request in
            if request.url?.path.hasSuffix("/decision") == true { return (Data("{\"detail\":\"fixture refusal\"}".utf8), 409) }
            return try await PiOwnedHTTP.send(request)
        })
        do {
            let ready = try await candidate.owner.session.ledger.snapshot()
            try piCheck(ready.piArray?.isEmpty == true)
            let port = try await candidate.owner.endpoint()
            var request = URLRequest(url: port.appendingPathComponent("assistant/messages"))
            request.httpMethod = "POST"
            let conversation = UUID().uuidString.lowercased()
            request.httpBody = try PiValue.object(["assistant_id": .string(candidate.workspace.assistantID.uuidString.lowercased()), "conversation_id": .string(conversation), "message_id": .string(UUID().uuidString.lowercased()), "mode": .string("assistant"), "text": .string("/task approval refusal fixture")]).piData()
            let (accepted, status) = try await candidate.owner.http(request)
            try piCheck(status == 200)
            let taskID = try PiValue.piRead(accepted).pi("task_ids").piArray![0].piString!
            var task: PiValue = .null
            for _ in 0..<100 {
                let (data, _) = try await candidate.owner.http(URLRequest(url: port.appendingPathComponent("tasks")))
                task = try PiValue.piRead(data).pi("tasks").piArray!.first { $0.pi("id").piString == taskID } ?? .null
                if task.pi("state").piString == "needs_decision" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try piCheck(task.pi("state").piString == "needs_decision")
            var decision = URLRequest(url: port.appendingPathComponent("tasks/\(taskID)/decision"))
            decision.httpMethod = "POST"
            decision.httpBody = try PiValue.object(["decision_id": task.pi("decision").pi("id"), "idempotency_key": .string(UUID().uuidString.lowercased()), "reply": .object(["approved": .bool(true)])]).piData()
            let (_, refused) = try await candidate.owner.http(decision)
            try piCheck(refused == 409)
            let bindings = try await candidate.owner.session.ledger.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bindings")! }
            try piCheck(bindings == 1)
            let modelCalls = await candidate.provider.calls()
            try piCheck(modelCalls == 2)
            await candidate.stop()
        } catch { await candidate.stop(); throw error }
    }
}
