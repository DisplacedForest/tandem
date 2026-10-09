import Foundation

@MainActor
enum NativePiCredentialRetrySelftest {
    static func config(_ credentials: NativeCredentialFixtureStore, writer: @escaping ([String: Any]) throws -> Void = { _ in }) -> ConfigStore {
        var settings = NativeChatSettings.fresh
        settings.profiles = ["selected", "other"].map {
            NativeEndpointProfile(id: $0, name: $0, baseURL: "https://openrouter.ai/api/v1", discoveredModels: [],
                selectedModel: "qwen/qwen3.8-flash", selectionBasis: .user, lastDiscoveryAt: nil)
        }
        settings.activeProfileID = "selected"
        return ConfigStore(credentialStore: credentials, readConfiguration: {
            settings.merging(into: ["pi_profile_revisions": ["selected": "d1cb632a-fba0-470f-8675-7e241c10b04a"]])
        }, writeConfiguration: writer)
    }

    static func rejected(_ expected: ConfigStore.PiConnectionError, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch let error as ConfigStore.PiConnectionError { try piCheck(error == expected); return }
        throw PiBrokerError.invalid
    }

    static func rules() throws {
        let credentials = NativeCredentialFixtureStore()
        credentials.values = ["selected": PiCandidateCredentials.key, "other": "other-synthetic", ConfigStore.visionBridgeCredentialID: "bridge-synthetic"]
        var writes = 0
        let owner = config(credentials, writer: { _ in writes += 1 })
        let original = try owner.piSelectedProfileBinding()
        credentials.reads = []; credentials.startupReads = []
        owner.nativeSettings.profiles[0].selectedModel = "unsaved"
        try rejected(.profile) { _ = try owner.piConnectSelectedProfile() }
        try piCheck(credentials.reads.isEmpty)
        owner.nativeSettings.profiles[0].selectedModel = original.model
        owner.apiKeyBinding().wrappedValue = "unsaved-synthetic"
        try rejected(.profile) { _ = try owner.piConnectSelectedProfile() }
        try piCheck(credentials.reads.isEmpty)
        owner.apiKeyBinding().wrappedValue = PiCandidateCredentials.key
        credentials.denied.insert("selected")
        try rejected(.credentialAccess) { _ = try owner.piConnectSelectedProfile() }
        try piCheck(owner.activeNativeAPIKey.isEmpty && owner.credentialError != nil)
        try piCheck((try? owner.piSelectedProfileBinding()) == nil)
        credentials.denied.remove("selected")
        credentials.values.removeValue(forKey: "selected")
        try rejected(.credentialMissing) { _ = try owner.piConnectSelectedProfile() }
        credentials.values["selected"] = "malformed\nsynthetic"
        try rejected(.credentialFormat) { _ = try owner.piConnectSelectedProfile() }
        credentials.values["selected"] = PiCandidateCredentials.key
        try piCheck(try owner.piConnectSelectedProfile() == original)
        try piCheck(try owner.piSelectedProfileBinding() == original)
        try piCheck(owner.credentialError == nil && credentials.reads == Array(repeating: "selected", count: 4)
            && credentials.startupReads == credentials.reads && credentials.writes.isEmpty && writes == 0)
    }


    static func changedCredential(admission: NativeInferenceAdmission, root: URL) async throws {
        for deniedFirst in [false, true] {
            let credentials = NativeCredentialFixtureStore()
            credentials.values = ["selected": "synthetic-A"]
            var failConfiguration = false
            let owner = config(credentials, writer: { _ in
                if failConfiguration { throw PiBrokerError.storage }
            })
            let original = try owner.piSelectedProfileBinding()
            let accounting = try PiSharedAccounting(root: root.appendingPathComponent("credential-identity-\(deniedFirst)"), baselineNanos: 0)
            let operation = try owner.piSelectedProfileOperation(binding: original, admission: admission, accounting: accounting,
                transport: { _, _ in throw PiBrokerError.invalid })
            try await operation.validate()
            if deniedFirst {
                credentials.denied.insert("selected")
                try rejected(.credentialAccess) { _ = try owner.piConnectSelectedProfile() }
                credentials.denied.remove("selected")
            }
            credentials.values["selected"] = "synthetic-B"
            try rejected(.credentialChanged) { _ = try owner.piConnectSelectedProfile() }
            try piCheck(owner.activeNativeAPIKey.isEmpty && credentials.writes.isEmpty)
            try await NativePiProviderSelftest.reject { try await operation.validate() }
            owner["appearance"] = "dark"
            try owner.save()
            try rejected(.credentialChanged) { _ = try owner.piConnectSelectedProfile() }
            credentials.values["selected"] = "synthetic-A"
            try piCheck(try owner.piConnectSelectedProfile() == original)
            try await operation.validate()
            owner.apiKeyBinding().wrappedValue = "synthetic-B"
            failConfiguration = true
            try await NativePiProviderSelftest.reject { try owner.save() }
            try rejected(.profile) { _ = try owner.piConnectSelectedProfile() }
            try await NativePiProviderSelftest.reject { try await operation.validate() }
            failConfiguration = false
            try owner.save()
            let updated = try owner.piConnectSelectedProfile()
            try piCheck(updated != original && credentials.writes == ["update"])
            try await NativePiProviderSelftest.reject { try await operation.validate() }
        }
        print("PASS: changed credentials reject obsolete operations, retain identity after denial, and require a committed explicit save")
    }

    static func recovery(_ arguments: [String], http: PiProviderHTTP, admission: NativeInferenceAdmission, root: URL) async throws {
        try rules()
        print("Credential retry fixture: rules passed")
        try await changedCredential(admission: admission, root: root)
        let root = root.appendingPathComponent("credential-retry")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let policy = NativePiSpendingPolicy.State(schema: 1, id: UUID(), ceilingNanos: 200_000_000_000,
            historicalHoldsNanos: 0, allowanceNanos: 1_000_000_000, observedUsageNanos: 0)
        let file = root.appendingPathComponent("spending.json")
        try JSONEncoder().encode(policy).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let credentials = NativeCredentialFixtureStore()
        credentials.values = ["selected": PiCandidateCredentials.key, "other": "other-synthetic"]
        credentials.denied.insert("selected")
        var writes = 0
        let owner = config(credentials, writer: { _ in writes += 1 })
        credentials.reads = []; credentials.startupReads = []
        var memory = NativeMemorySettings.fresh
        memory.enabled = false
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil,
            repository: try LocalChatRepository(url: root.appendingPathComponent("focused.sqlite")), nativeMemorySettings: memory)
        let presentation = NativePiProduction.presentation(config: owner, store: store, root: root, http: http, admission: admission, arguments: arguments)
        PiProviderFixtureProtocol.state.configure("production")
        await presentation.connect()
        try piCheck(presentation.session == nil && presentation.canConnect && presentation.failure?.contains("macOS couldn't access") == true
            && PiProviderFixtureProtocol.state.calls().isEmpty && credentials.startupReads == ["selected"])
        owner.nativeSettings.profiles[0].selectedModel = "unsaved"
        await presentation.connect()
        try piCheck(presentation.failure?.contains("model configuration") == true && credentials.startupReads == ["selected"]
            && PiProviderFixtureProtocol.state.calls().isEmpty)
        owner.nativeSettings.profiles[0].selectedModel = "qwen/qwen3.8-flash"
        credentials.denied.remove("selected")
        try piCheck(presentation.session == nil && credentials.startupReads == ["selected"])
        await presentation.connect()
        do {
            try piCheck(presentation.session != nil && presentation.failure == nil
                && credentials.startupReads == ["selected", "selected"] && credentials.reads == credentials.startupReads
                && credentials.writes.isEmpty && writes == 0 && !PiProviderFixtureProtocol.state.calls().contains("completions"))
            await presentation.stop()
        } catch { await presentation.stop(); throw error }
        print("PASS: explicit selected-credential retry, denied then recovered without restart, distinct profile/access failures, no credential writes or real calls")
    }
}
