import Foundation
import Darwin

@MainActor
enum NativePiCheckpointSelftest {
    static func seed(_ path: URL, id: String) throws {
        let auth: PiValue = .object(["state": .string("ready"), "model": .string(PiCheckpointPricing.model), "prompt_digest": .string(PiCheckpointPricing.promptDigest), "exclusive_owner": .bool(true), "maximum_usd": .number(1), "uncertainty_holds_usd": .string("4"), "expires": .number(Date().addingTimeInterval(300).timeIntervalSince1970)])
        let value: PiValue = .object(["total_authorized_usd": .number(200), "prior_plus_cli_and_uncertainty_holds_usd": .string("5.676254486"), "last_known_prior_account_usage_usd": .string("0.008876486"), "code_review_cli": .object(["total_reported_cost_usd": .string("1.667378")]), "checkpoint_authorizations": .object([id: auth])])
        try value.piData().write(to: path)
    }
    static func run(_ arguments: [String]) async {
        if arguments == ["--watchdog"] {
            let watchdog = PiCheckpointDeadline(seconds: 0.1, code: 126)
            withExtendedLifetime(watchdog) { while true { pause() } }
        }
        if arguments.first == "--crash-stage", arguments.count == 4 {
            do {
                let ledger = try PiCheckpointLedger(path: URL(fileURLWithPath: arguments[1]), id: arguments[2])
                try ledger.consume()
                if arguments[3] == "reserved" {
                    try ledger.metadata("models"); try ledger.metadata("usage")
                    try ledger.reserve(baseline: 5_676_254_486, body: Data("synthetic".utf8))
                }
                _exit(70)
            } catch { print("REFUSED consumed or invalid checkpoint"); exit(71) }
        }
        let terminateAfterSend = arguments.first == "--crash-after-send"
        let arguments = terminateAfterSend ? Array(arguments.dropFirst()) : arguments
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-checkpoint-test-" + UUID().uuidString)
        do {
            umask(0o077)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID().uuidString.lowercased(), path = root.appendingPathComponent("ledger.json")
            try seed(path, id: id)
            do {
                let ledger = try PiCheckpointLedger(path: path, id: id)
                try await NativePiProviderSelftest.reject { _ = try PiCheckpointLedger(path: path, id: id) }
                try ledger.consume()
                try await NativePiProviderSelftest.reject { try ledger.consume() }
            }
            try await NativePiProviderSelftest.reject { _ = try PiCheckpointLedger(path: path, id: id) }
            do {
                let rollbackRoot = root.appendingPathComponent("rollback")
                try FileManager.default.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
                let rollbackID = UUID().uuidString.lowercased(), rollbackPath = rollbackRoot.appendingPathComponent("ledger.json")
                try seed(rollbackPath, id: rollbackID)
                let journal = try PiCheckpointLedger(path: rollbackPath, id: rollbackID)
                try journal.consume(); try journal.metadata("models"); try journal.metadata("usage")
                try piCheck(chmod(rollbackRoot.path, 0o500) == 0)
                try await NativePiProviderSelftest.reject { try journal.reserve(baseline: 5_676_254_486, body: Data("synthetic".utf8)) }
                try piCheck(chmod(rollbackRoot.path, 0o700) == 0)
                try piCheck(journal.report().pi("inference_requests") == .number(0) && journal.report().pi("stage") == .string("usage_pending"))
                let persisted = try PiValue.piRead(Data(contentsOf: rollbackPath)).pi("checkpoint_authorizations").pi(rollbackID)
                try piCheck(persisted.pi("inference_requests") == .number(0) && persisted.pi("stage") == .string("usage_pending"))
                try journal.reserve(baseline: 5_676_254_486, body: Data("synthetic".utf8))
                try piCheck(journal.report().pi("stage") == .string("inference_pending"))
            }
            var selectedReads: [String] = []
            let selected = UUID().uuidString.lowercased()
            let credentials = PiCheckpointCredentials(selected: selected) { profile in selectedReads.append(profile); return PiCandidateCredentials.key }
            _ = try credentials.read(for: "vision-bridge")
            _ = try credentials.read(for: "other")
            _ = try credentials.read(for: selected)
            try await NativePiProviderSelftest.reject { _ = try credentials.read(for: selected) }
            try piCheck(selectedReads == [selected])
            let catalog = try PiProviderFixtureState.checkpointCatalog.piData()
            let pricing = try PiCheckpointPricing(catalog: catalog)
            try piCheck(pricing.forecastNanos == 829440 && pricing.prompt == Decimal(string: "0.17")! && pricing.completion == Decimal(string: "0.52")!)
            try piCheck(pricing.ceilings.pi("prompt") == .number(0.17) && pricing.ceilings.pi("completion") == .number(0.52))
            let scope = try PiModelScope(NativePiModelBrokerFixture.binding(mode: "focused"), profile: UUID().uuidString.lowercased())
            let wire = NativePiModelBrokerFixture.changed(NativePiModelBrokerFixture.request(scope, channel: "fixture"), "messages", .array(PiCheckpointPricing.messages))
            let request = try PiModelRequest(wire, scope: scope, channel: "fixture")
            try piCheck(try pricing.body(request).count < 4096)
            let changed = NativePiModelBrokerFixture.changed(wire, "messages", .array([.object(["role": .string("user"), "content": .string("different")])]))
            try await NativePiProviderSelftest.reject { _ = try pricing.body(PiModelRequest(changed, scope: scope, channel: "fixture")) }
            var expensive = PiProviderFixtureState.checkpointCatalog.pi("data").piArray![0].piObject!
            expensive["pricing"] = .object(["prompt": .string("0.0001"), "completion": .string("0.0001")])
            try await NativePiProviderSelftest.reject { _ = try PiCheckpointPricing(catalog: PiValue.object(["data": .array([.object(expensive)])]).piData()) }
            if !arguments.isEmpty {
                let workflowPath = URL(fileURLWithPath: arguments[1]).deletingLastPathComponent().appendingPathComponent("workflow-ledger.json"), workflowID = UUID().uuidString.lowercased()
                try seed(workflowPath, id: workflowID)
                let journal = try PiCheckpointLedger(path: workflowPath, id: workflowID)
                try journal.consume()
                var configReads = 0
                let store = PiCheckpointCredentials(selected: selected) { _ in configReads += 1; return PiCandidateCredentials.key }
                var settings = NativeChatSettings.fresh
                settings.profiles = [NativeEndpointProfile(id: selected, name: "Fixture", baseURL: "https://openrouter.ai/api/v1", discoveredModels: [], selectedModel: PiCheckpointPricing.model, selectionBasis: .user, lastDiscoveryAt: nil)]
                settings.activeProfileID = selected
                let raw = settings.merging(into: [:])
                let config = ConfigStore(credentialStore: store, readConfiguration: { raw }, writeConfiguration: { _ in throw PiBrokerError.unauthorized })
                PiProviderFixtureProtocol.state.configure(terminateAfterSend ? "checkpoint-held" : "checkpoint")
                let admission = PiAdmissionFixtureProtocol.admission()
                defer { admission.session.invalidateAndCancel() }
                let runRoot = URL(fileURLWithPath: arguments[1])
                let result = try await NativePiCheckpoint.run(arguments: arguments, root: runRoot, config: config, ledger: journal, admission: admission, http: PiProviderFixtureProtocol.http(), transport: .providerFixture)
                try piCheck(result.pi("reply") == .string("OK") && configReads == 1)
                try piCheck(PiProviderFixtureProtocol.state.calls() == ["models", "key", "completions"])
                try piCheck(result.pi("checkpoint").pi("state") == .string("completed") && result.pi("checkpoint").pi("charged_nanos") == .number(28000))
                try await NativePiProviderSelftest.reject { try journal.reserve(baseline: 5_676_254_486, body: Data()) }
                try NativePiCandidate.verifyNoCredentialFiles(runRoot)
                print("PASS: exact one-inference SDK checkpoint, selected credential only, three intercepted provider requests, durable charge and no replay")
            }
            print("PASS: checkpoint pricing, exact prompt, durable authorization, selected-only credentials; no live calls")
        } catch {
            FileHandle.standardError.write(Data("Checkpoint fixture failed: \(error)\n".utf8)); exit(1)
        }
    }
}
