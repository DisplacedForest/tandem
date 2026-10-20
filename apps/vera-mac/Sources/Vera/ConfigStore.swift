import SwiftUI

/// Reads and writes `~/.vera/config.json` — the single on-disk config the app and its clients
/// share. Values are flat string keys; unknown keys in the file are preserved on save.
/// Environment variables always win over file values at resolve time (the file is the editable
/// layer underneath).
enum ConfigFile {
    /// `~/.vera/config.json`, or `$VERA_CONFIG_DIR/config.json` when set — the override
    /// supports test sandboxes and non-standard layouts without touching the real config.
    static var defaultURL: URL {
        if let dir = ProcessInfo.processInfo.environment["VERA_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("config.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vera/config.json")
    }

    static func read(at url: URL = defaultURL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// Atomic write, creating the parent directory if needed.
    static func write(_ raw: [String: Any], at url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    /// Raw file contents. String values are editable in Settings; unknown keys are preserved.
    @Published private(set) var raw: [String: Any]
    @Published var showOnboarding: Bool
    @Published var nativeSettings: NativeChatSettings {
        didSet { nativeMCP.setEnabled(nativeSettings.enabledToolIDs) }
    }
    let nativeMCP: NativeMCPManager
    @Published private var nativeAPIKeys: [String: String]
    @Published var visionBridgeAPIKey: String {
        didSet {
            if oldValue != visionBridgeAPIKey { queueCredential(visionBridgeAPIKey, for: Self.visionBridgeCredentialID) }
        }
    }
    @Published private(set) var credentialError: String?
    @Published private(set) var capabilityTools: NativeCapabilityToolCatalog
    private let credentialStore: any NativeCredentialStore
    private let writeConfiguration: ([String: Any]) throws -> Void
    private var savedCredentials: [String: String]
    private var piCommittedSettings: NativeChatSettings
    private var piCommittedCredentials: [String: String]
    private var piCredentialIdentities: [String: String]
    private var piCommitValid = true
    private var unavailableCredentials: Set<String>
    private var pendingCredentials: [String: String] = [:]
    private var legacyCredentials: [String: String] = [:]
    private var blockedLegacyMigrationID: String?

    static let visionBridgeCredentialID = "vision-bridge"
    static let memoryCredentialID = "memory-endpoint"
    private var memoryCredentialLoaded = false
    private var memoryCredentialReadFailed = false
    private var memoryMigrationAwaitingCredential = false
    @Published var memoryEndpointAPIKey: String {
        didSet {
            if oldValue != memoryEndpointAPIKey { queueCredential(memoryEndpointAPIKey, for: Self.memoryCredentialID) }
        }
    }

    static let envNames: [String: String] = [
        "model_base": "VERA_MODEL_BASE", "model_api_key": "VERA_MODEL_API_KEY",
        "model": "VERA_MODEL", "completions_url": "VERA_COMPLETIONS_URL",
        "voice_base": "VERA_VOICE_BASE", "vera_api_base": "VERA_API_BASE",
        "owner_name": "VERA_OWNER_NAME", "assistant_name": "VERA_ASSISTANT_NAME",
        "chat_template_kwargs": "VERA_CHAT_TEMPLATE_KWARGS",
        NativeImageTools.configKey: NativeImageTools.envName,
    ]

    init(credentialStore: any NativeCredentialStore = KeychainNativeCredentialStore(),
         readConfiguration: () -> [String: Any] = { ConfigFile.read() },
         nativeMCP injectedMCP: NativeMCPManager? = nil,
         writeConfiguration: @escaping ([String: Any]) throws -> Void = { try ConfigFile.write($0) }) {
        let loaded = readConfiguration()
        let settings = NativeChatSettings.load(from: loaded)
        var keys: [String: String] = [:]
        var unavailable: Set<String> = []
        let memoryEndpointWanted = settings.memoryEndpoint.isConfigured
            || ProcessInfo.processInfo.environment["VERA_MEMORY_BASE"]?.isEmpty == false
        let startupCredentialIDs = settings.profiles.map(\.id) + [Self.visionBridgeCredentialID]
            + (memoryEndpointWanted ? [Self.memoryCredentialID] : [])
        for id in Set(startupCredentialIDs) {
            do { if let value = try credentialStore.readForStartup(for: id) { keys[id] = value } }
            catch { unavailable.insert(id) }
        }
        let retiredKeys = ["base", "api_key", "owui_email", "owui_password"]
        var cleaned = loaded
        for key in retiredKeys { cleaned.removeValue(forKey: key) }
        let migratedMemoryEndpoint = NativeChatSettings.needsMemoryEndpointMigration(loaded) && settings.memoryEndpoint.isConfigured
        if cleaned.count != loaded.count { try? writeConfiguration(cleaned) }
        raw = cleaned
        nativeMCP = injectedMCP ?? NativeMCPManager(raw: cleaned, enabled: settings.enabledToolIDs)
        nativeSettings = settings
        nativeAPIKeys = keys
        savedCredentials = keys
        piCommittedCredentials = keys
        piCredentialIdentities = keys.mapValues { piHash(Data($0.utf8)) }
        piCommittedSettings = settings
        unavailableCredentials = unavailable
        visionBridgeAPIKey = keys[Self.visionBridgeCredentialID] ?? ""
        memoryEndpointAPIKey = keys[Self.memoryCredentialID] ?? ""
        capabilityTools = NativeCapabilityTools.catalog(reservedNames: ChatStore.builtInToolNames)
        self.credentialStore = credentialStore
        self.writeConfiguration = writeConfiguration
        credentialError = unavailable.isEmpty ? nil : NativeCredentialError.read.localizedDescription
        showOnboarding = !settings.hasValidConfiguration
            && settings.onboardingState != .skipped
            && settings.onboardingState != .complete
        if let profile = settings.activeProfile, keys[profile.id] == nil,
           let legacy = loaded["model_api_key"] as? String, !legacy.isEmpty {
            if unavailable.contains(profile.id) { blockedLegacyMigrationID = profile.id }
            else {
                nativeAPIKeys[profile.id] = legacy
                legacyCredentials[profile.id] = legacy
            }
        }
        if migratedMemoryEndpoint, keys[Self.memoryCredentialID] == nil {
            if let profile = settings.activeProfile, let chatKey = nativeAPIKeys[profile.id], !chatKey.isEmpty,
               !unavailable.contains(Self.memoryCredentialID) {
                nativeAPIKeys[Self.memoryCredentialID] = chatKey
                legacyCredentials[Self.memoryCredentialID] = chatKey
                memoryEndpointAPIKey = chatKey
            } else if let profile = settings.activeProfile, unavailable.contains(profile.id) || unavailable.contains(Self.memoryCredentialID) {
                memoryMigrationAwaitingCredential = true
            }
        }
        memoryCredentialLoaded = memoryEndpointWanted && !unavailable.contains(Self.memoryCredentialID)
        memoryCredentialReadFailed = memoryEndpointWanted && unavailable.contains(Self.memoryCredentialID)
    }

    subscript(_ key: String) -> String {
        get { (raw[key] as? String) ?? "" }
        set {
            if newValue.isEmpty { raw.removeValue(forKey: key) } else { raw[key] = newValue }
        }
    }

    /// A SwiftUI binding onto one file key (edits are in-memory until `save()`).
    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self[key] }, set: { self[key] = $0 })
    }

    /// The app-wide appearance override from the `appearance` key: `"light"`/`"dark"` pin a
    /// scheme, anything else follows the system (nil).
    var colorSchemeOverride: ColorScheme? {
        switch self["appearance"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// The active environment override for a key, if one is set (it wins over the file value).
    func envOverride(_ key: String) -> String? {
        guard let name = Self.envNames[key] else { return nil }
        let env = ProcessInfo.processInfo.environment
        if let v = env[name], !v.isEmpty { return name }
        return nil
    }

    /// Persist the current values to disk.
    private func queueCredential(_ value: String, for id: String) {
        if !unavailableCredentials.contains(id), value == (savedCredentials[id] ?? "") {
            pendingCredentials.removeValue(forKey: id)
        } else { pendingCredentials[id] = value }
        legacyCredentials.removeValue(forKey: id)
        if id == blockedLegacyMigrationID { blockedLegacyMigrationID = nil }
    }

    func save() throws {
        piCommitValid = false
        let piCredentialsChanged = Set(pendingCredentials.keys).union(legacyCredentials.keys)
        do {
            if blockedLegacyMigrationID != nil { throw NativeCredentialError.read }
            for id in pendingCredentials.keys.sorted() {
                guard let value = pendingCredentials[id] else { continue }
                try credentialStore.set(value.isEmpty ? nil : value, for: id)
                savedCredentials[id] = value
                piCredentialIdentities[id] = value.isEmpty ? nil : piHash(Data(value.utf8))
                unavailableCredentials.remove(id)
                pendingCredentials.removeValue(forKey: id)
            }
            for id in legacyCredentials.keys.sorted() {
                guard let value = legacyCredentials[id] else { continue }
                try credentialStore.addIfAbsent(value, for: id)
                savedCredentials[id] = value
                piCredentialIdentities[id] = value.isEmpty ? nil : piHash(Data(value.utf8))
                legacyCredentials.removeValue(forKey: id)
            }
            credentialError = unavailableCredentials.isEmpty ? nil : NativeCredentialError.read.localizedDescription
        } catch {
            credentialError = (error as? NativeCredentialError)?.localizedDescription ?? NativeCredentialError.write.localizedDescription
            throw (error as? NativeCredentialError) ?? NativeCredentialError.write
        }
        var merged = nativeSettings.merging(into: raw)
        if memoryMigrationAwaitingCredential, savedCredentials[Self.memoryCredentialID] == nil {
            if var nativeChat = merged["native_chat"] as? [String: Any] {
                nativeChat.removeValue(forKey: "memoryEndpoint")
                merged["native_chat"] = nativeChat
            }
        } else {
            memoryMigrationAwaitingCredential = false
        }
        var revisions = raw["pi_profile_revisions"] as? [String: String] ?? [:]
        for profile in nativeSettings.profiles {
            let previous = piCommittedSettings.profiles.first { $0.id == profile.id }
            if revisions[profile.id] == nil || previous?.baseURL != profile.baseURL || previous?.selectedModel != profile.selectedModel || piCredentialsChanged.contains(profile.id) || piCommittedCredentials[profile.id] != savedCredentials[profile.id] {
                revisions[profile.id] = UUID().uuidString.lowercased()
            }
        }
        merged["pi_profile_revisions"] = revisions
        try writeConfiguration(merged)
        piCommittedSettings = nativeSettings
        piCommittedCredentials = savedCredentials
        piCommitValid = true
        raw = merged
        capabilityTools = NativeCapabilityTools.catalog(reservedNames: ChatStore.builtInToolNames)
    }

    enum PiConnectionError: Error, Equatable {
        case profile, credentialAccess, credentialMissing, credentialFormat, credentialChanged
    }

    func piConnectSelectedProfile() throws -> PiSelectedProfileBinding {
        let binding: PiSelectedProfileBinding
        do { binding = try piSelectedProfileConfiguration() }
        catch { throw PiConnectionError.profile }
        let id = binding.profileID
        let credential: String?
        do { credential = try credentialStore.readForStartup(for: id) }
        catch NativeCredentialError.format {
            piClearCachedCredential(id, unavailable: true)
            throw PiConnectionError.credentialFormat
        } catch {
            piClearCachedCredential(id, unavailable: true)
            throw PiConnectionError.credentialAccess
        }
        guard let credential, !credential.isEmpty else {
            piClearCachedCredential(id, unavailable: false)
            throw PiConnectionError.credentialMissing
        }
        guard credential.utf8.count <= 4096, !credential.contains("\r"), !credential.contains("\n") else {
            piClearCachedCredential(id, unavailable: true)
            throw PiConnectionError.credentialFormat
        }
        let identity = piHash(Data(credential.utf8))
        if let expected = piCredentialIdentities[id], expected != identity {
            piClearCachedCredential(id, unavailable: true)
            throw PiConnectionError.credentialChanged
        }
        piCredentialIdentities[id] = identity
        nativeAPIKeys[id] = credential
        savedCredentials[id] = credential
        piCommittedCredentials[id] = credential
        unavailableCredentials.remove(id)
        credentialError = unavailableCredentials.isEmpty ? nil : NativeCredentialError.read.localizedDescription
        return binding
    }

    private func piClearCachedCredential(_ id: String, unavailable: Bool) {
        nativeAPIKeys.removeValue(forKey: id)
        savedCredentials.removeValue(forKey: id)
        piCommittedCredentials.removeValue(forKey: id)
        if unavailable { unavailableCredentials.insert(id) }
        else { unavailableCredentials.remove(id) }
        credentialError = unavailableCredentials.isEmpty ? nil : NativeCredentialError.read.localizedDescription
    }

    private func piSelectedProfileConfiguration() throws -> PiSelectedProfileBinding {
        guard piCommitValid, let committed = piCommittedSettings.activeProfile,
              let current = nativeSettings.activeProfile,
              committed.id == current.id, committed.baseURL == current.baseURL,
              piCommittedSettings.profiles.filter({ $0.id == committed.id }).count == 1,
              nativeSettings.profiles.filter({ $0.id == current.id }).count == 1,
              committed.selectedModel == current.selectedModel,
              pendingCredentials[committed.id] == nil, legacyCredentials[committed.id] == nil,
              blockedLegacyMigrationID != committed.id else { throw PiBrokerError.unauthorized }
        let initial = Array(piHash(Data([committed.id, committed.baseURL, committed.selectedModel].joined(separator: "\n").utf8)).prefix(32))
        let derived = [String(initial[0..<8]), String(initial[8..<12]), String(initial[12..<16]), String(initial[16..<20]), String(initial[20..<32])].joined(separator: "-")
        let revision = (raw["pi_profile_revisions"] as? [String: String])?[committed.id] ?? derived
        return try PiSelectedProfileBinding(profileID: committed.id, revision: revision, endpoint: committed.baseURL, model: committed.selectedModel)
    }

    func piSelectedProfileBinding() throws -> PiSelectedProfileBinding {
        let binding = try piSelectedProfileConfiguration()
        let id = binding.profileID
        guard !unavailableCredentials.contains(id),
              let key = piCommittedCredentials[id], !key.isEmpty,
              key == savedCredentials[id], key == nativeAPIKeys[id],
              key.utf8.count <= 4096, !key.contains("\r"), !key.contains("\n") else { throw PiBrokerError.unauthorized }
        return binding
    }

    func piSelectedProfileOperation(binding: PiSelectedProfileBinding, admission: NativeInferenceAdmission,
                                    accounting: PiSharedAccounting, transport: @escaping PiProviderSend) throws -> PiSelectedProfileOperation {
        try piCheck(try piSelectedProfileBinding() == binding, .unauthorized)
        return PiSelectedProfileOperation(binding: binding, admission: admission, accounting: accounting, validate: { [weak self] in
            guard let self else { throw PiBrokerError.unavailable }
            try await self.piValidate(binding)
        }) { [weak self] request, body in
            guard let self else { throw PiNoSpendRejection(error: PiBrokerError.unavailable) }
            return try await self.piSend(binding: binding, request: request, body: body, transport: transport)
        }
    }

    private func piValidate(_ binding: PiSelectedProfileBinding) throws {
        try piCheck(try piSelectedProfileBinding() == binding, .unauthorized)
    }

    private func piSend(binding: PiSelectedProfileBinding, request: PiModelRequest, body: Data,
                        transport: @escaping PiProviderSend) async throws -> (Data, Int) {
        try await request.validateHostTools()
        let key: String
        do {
            try piCheck(try piSelectedProfileBinding() == binding, .unauthorized)
            guard let committed = piCommittedCredentials[binding.profileID] else { throw PiBrokerError.unauthorized }
            key = committed
            try piCheck(!piContainsCredential(body, key: key), .unauthorized)
        } catch { throw PiNoSpendRejection(error: error) }
        var outgoing = URLRequest(url: binding.endpoint.appendingPathComponent("chat/completions"))
        outgoing.httpMethod = "POST"
        outgoing.httpBody = body
        outgoing.timeoutInterval = 30
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        outgoing.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        do { try await request.memoryAuthority?.validate(request) } catch where !(error is CancellationError) { throw PiNoSpendRejection(error: error) }
        try Task.checkCancellation()
        let response = try await transport(outgoing, request)
        try piCheck(try piSelectedProfileBinding() == binding, .unauthorized)
        try piCheck(!piContainsCredential(response.0, key: key), .unauthorized)
        if response.1 == 200 {
            let typed = try PiProviderCodec.reply(PiValue.piRead(response.0), request: request, model: binding.model)
            try piCheck(!piContainsCredential(typed.piData(), key: key), .unauthorized)
        }
        return response
    }

    private func piContainsCredential(_ data: Data, key: String) -> Bool {
        if data.range(of: Data(key.utf8)) != nil { return true }
        func contains(_ value: Any, depth: Int = 0) -> Bool {
            if let text = value as? String {
                if text.contains(key) { return true }
                if depth < 4, let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) { return contains(nested, depth: depth + 1) }
            }
            if let list = value as? [Any] { return list.contains { contains($0, depth: depth) } }
            if let object = value as? [String: Any] { return object.contains { $0.key.contains(key) || contains($0.value, depth: depth) } }
            return false
        }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return false }
        return contains(value)
    }

    func piProviderMetadata(binding: PiSelectedProfileBinding, path: String, http: PiProviderHTTP) async throws -> Data {
        try piValidate(binding)
        try piCheck(["models", "key"].contains(path), .unauthorized)
        guard let key = piCommittedCredentials[binding.profileID] else { throw PiBrokerError.unauthorized }
        var outgoing = URLRequest(url: binding.endpoint.appendingPathComponent(path))
        outgoing.httpMethod = "GET"
        outgoing.timeoutInterval = 30
        outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
        outgoing.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let (data, _) = try await http.send(outgoing)
        try piValidate(binding)
        try piCheck(!piContainsCredential(data, key: key), .unauthorized)
        return data
    }

    func reloadCapabilityTools() {
        capabilityTools = NativeCapabilityTools.catalog(reservedNames: ChatStore.builtInToolNames)
    }

    var nativeResolved: NativeChatConfig? {
        let env = ProcessInfo.processInfo.environment
        let profile = nativeSettings.activeProfile
        let rawBase = env["VERA_MODEL_BASE"]?.nilIfBlank ?? profile?.baseURL.nilIfBlank
        let model = env["VERA_MODEL"]?.nilIfBlank ?? profile?.selectedModel.nilIfBlank
        guard let rawBase,
              let base = URL(string: rawBase),
              base.scheme == "http" || base.scheme == "https",
              base.lastPathComponent == "v1",
              let model else { return nil }
        let apiKey = env["VERA_MODEL_API_KEY"]?.nilIfBlank
            ?? profile.flatMap { nativeAPIKeys[$0.id]?.nilIfBlank }
        let kwargs = env["VERA_CHAT_TEMPLATE_KWARGS"]?.nilIfBlank
            ?? self["chat_template_kwargs"].nilIfBlank
        let capability = nativeSettings.resolveCapabilities(model: model).profile
        let options = NativeChatRequestOptions.resolve(
            overrides: nativeSettings.parameterOverrides(profileID: profile?.id, model: model),
            profile: capability,
            savedTemplateKwargs: self["chat_template_kwargs"].nilIfBlank,
            environmentTemplateKwargs: env["VERA_CHAT_TEMPLATE_KWARGS"]?.nilIfBlank)
        return NativeChatConfig(
            baseURL: base, apiKey: apiKey, model: model, chatTemplateKwargs: kwargs,
            streaming: capability.supportsStreaming && (options.streamingOverride ?? true),
            options: options)
    }

    var activeNativeProfile: NativeEndpointProfile? { nativeSettings.activeProfile }
    var activeNativeAPIKey: String {
        guard let id = nativeSettings.activeProfileID else { return "" }
        return nativeAPIKeys[id] ?? ""
    }
    var nativeDiscoveryConfiguration: NativeDiscoveryConfiguration {
        NativeChatConfigurationResolver.discovery(
            profile: activeNativeProfile,
            apiKey: activeNativeAPIKey,
            environment: ProcessInfo.processInfo.environment)
    }

    var visionBridgeResolved: VisionBridgeConfig? {
        VisionBridgeConfig.resolve(
            settings: nativeSettings.visionBridge,
            apiKey: visionBridgeAPIKey,
            environment: ProcessInfo.processInfo.environment)
    }

    var memoryEndpointResolved: NativeMemoryEndpointConfig? {
        loadMemoryCredentialIfNeeded()
        return NativeMemoryEndpointConfig.resolve(
            endpoint: nativeSettings.memoryEndpoint, memory: nativeSettings.memory,
            apiKey: memoryEndpointAPIKey, environment: ProcessInfo.processInfo.environment)
    }

    var nativeMemoryService: NativeMemoryService? {
        guard let config = memoryEndpointResolved else { return nil }
        return NativeMemoryService(configuration: NativeMemoryServiceConfiguration(
            baseURL: config.baseURL, apiKey: config.apiKey,
            embeddingsModel: config.embeddingsModel,
            extractionModel: config.extractionModel,
            rerankModel: config.rerankModel), admission: .configured())
    }

    func memoryEndpointBinding(_ keyPath: WritableKeyPath<NativeMemoryEndpointSettings, String>) -> Binding<String> {
        Binding(
            get: { self.nativeSettings.memoryEndpoint[keyPath: keyPath] },
            set: { value in
                self.nativeSettings.memoryEndpoint[keyPath: keyPath] = value
                self.loadMemoryCredentialIfNeeded()
            })
    }

    func loadMemoryCredentialIfNeeded(retry: Bool = false) {
        guard !memoryCredentialLoaded, nativeSettings.memoryEndpoint.isConfigured,
              pendingCredentials[Self.memoryCredentialID] == nil, memoryEndpointAPIKey.isEmpty,
              retry || !memoryCredentialReadFailed else { return }
        do {
            let stored = try credentialStore.read(for: Self.memoryCredentialID)
            memoryCredentialLoaded = true
            memoryCredentialReadFailed = false
            unavailableCredentials.remove(Self.memoryCredentialID)
            credentialError = unavailableCredentials.isEmpty ? nil : NativeCredentialError.read.localizedDescription
            guard let stored, !stored.isEmpty else { return }
            nativeAPIKeys[Self.memoryCredentialID] = stored
            savedCredentials[Self.memoryCredentialID] = stored
            memoryEndpointAPIKey = stored
        } catch {
            memoryCredentialReadFailed = true
            unavailableCredentials.insert(Self.memoryCredentialID)
            credentialError = NativeCredentialError.read.localizedDescription
        }
    }

    var memoryCredentialNeedsRetry: Bool { memoryCredentialReadFailed && !memoryCredentialLoaded }

    func cacheMemoryModels(_ models: [String]) {
        nativeSettings.memoryEndpoint.discoveredModels = Array(Set(models)).sorted()
        nativeSettings.memoryEndpoint.lastDiscoveryAt = Date()
    }

    var memoryEndpointEnvironmentOverride: String? {
        let env = ProcessInfo.processInfo.environment
        return (env["VERA_MEMORY_BASE"]?.isEmpty == false) ? "VERA_MEMORY_BASE" : nil
    }

    func activeProfileBinding(_ keyPath: WritableKeyPath<NativeEndpointProfile, String>) -> Binding<String> {
        Binding(
            get: { self.activeNativeProfile?[keyPath: keyPath] ?? "" },
            set: { value in self.updateActiveNativeProfile { $0[keyPath: keyPath] = value } })
    }

    func selectProfile(_ id: String) {
        var updated = nativeSettings
        updated.activeProfileID = id
        nativeSettings = updated
    }

    func addNativeProfile() {
        var updated = nativeSettings
        updated.addProfile()
        nativeSettings = updated
    }

    func updateActiveNativeProfile(_ update: (inout NativeEndpointProfile) -> Void) {
        var updated = nativeSettings
        updated.updateActiveProfile(update)
        nativeSettings = updated
    }

    func cacheDiscoveredModels(_ models: [String]) {
        var updated = nativeSettings
        updated.cacheModels(models)
        nativeSettings = updated
    }

    func selectNativeModel(_ model: String) {
        var updated = nativeSettings
        updated.selectModel(model, basis: .user)
        nativeSettings = updated
    }

    func apiKeyBinding() -> Binding<String> {
        Binding(
            get: {
                guard let id = self.nativeSettings.activeProfileID else { return "" }
                return self.nativeAPIKeys[id] ?? ""
            },
            set: { value in
                guard let id = self.nativeSettings.activeProfileID else { return }
                guard value != (self.nativeAPIKeys[id] ?? "") else { return }
                self.nativeAPIKeys[id] = value
                self.queueCredential(value, for: id)
            })
    }

    func systemPromptBinding() -> Binding<String> {
        Binding(
            get: { self.nativeSettings.systemPrompt },
            set: { value in
                var updated = self.nativeSettings
                updated.systemPrompt = value
                self.nativeSettings = updated
            })
    }

    func resetSystemPrompt() {
        var updated = nativeSettings
        updated.resetSystemPrompt()
        nativeSettings = updated
    }

    func setNativeTool(_ id: String, enabled: Bool) {
        var updated = nativeSettings
        if enabled { updated.enabledToolIDs.insert(id) } else { updated.enabledToolIDs.remove(id) }
        nativeSettings = updated
        if enabled, id == "apple-reminders" {
            Task { _ = await RemindersBridge.shared.nativeRequestAccess() }
        }
    }

    func visionBridgeBinding(_ keyPath: WritableKeyPath<VisionBridgeSettings, String>) -> Binding<String> {
        Binding(
            get: { self.nativeSettings.visionBridge[keyPath: keyPath] },
            set: { value in
                var updated = self.nativeSettings
                updated.visionBridge[keyPath: keyPath] = value
                self.nativeSettings = updated
            })
    }

    func updateCapability(model: String, _ update: (inout ModelCapabilityProfile) -> Void) {
        var updated = nativeSettings
        var profile = updated.resolveCapabilities(model: model).profile
        update(&profile)
        updated.setCapabilityOverride(model: model, profile: profile)
        nativeSettings = updated
    }

    func clearCapabilityOverride(model: String) {
        var updated = nativeSettings
        updated.clearCapabilityOverride(model: model)
        nativeSettings = updated
    }

    func activeParameterOverrides(model: String) -> ModelParameterOverrides {
        nativeSettings.parameterOverrides(
            profileID: nativeSettings.activeProfileID, model: model)
    }

    func updateParameterOverrides(
        model: String, _ update: (inout ModelParameterOverrides) -> Void
    ) {
        guard let profileID = nativeSettings.activeProfileID else { return }
        var updated = nativeSettings
        updated.updateParameterOverrides(profileID: profileID, model: model, update)
        nativeSettings = updated
    }

    func setParameter(model: String, id: ModelParameterID, value: ModelParameterValue) {
        updateParameterOverrides(model: model) { $0.values[id] = value }
    }

    func clearParameter(model: String, id: ModelParameterID) {
        updateParameterOverrides(model: model) { $0.values.removeValue(forKey: id) }
    }

    func clearParameterGroup(model: String, group: ModelParameterGroup) {
        let ids = ModelParameterCatalog.all.filter { $0.group == group }.map(\.id)
        updateParameterOverrides(model: model) { overrides in
            for id in ids { overrides.values.removeValue(forKey: id) }
            if group == .provider { overrides.custom = [] }
        }
    }

    func clearRejectedParameter(model: String, rejection: ModelParameterRejection) {
        updateParameterOverrides(model: model) { overrides in
            if let id = rejection.parameterID {
                overrides.values.removeValue(forKey: id)
            }
            if rejection.isCustom {
                overrides.custom.removeAll { $0.trimmedKey == rejection.key }
            }
        }
    }

    func updateMemory(_ update: (inout NativeMemorySettings) -> Void) {
        var settings = nativeSettings
        update(&settings.memory)
        nativeSettings = settings
    }

    func memoryStringBinding(_ keyPath: WritableKeyPath<NativeMemorySettings, String>) -> Binding<String> {
        Binding(
            get: { self.nativeSettings.memory[keyPath: keyPath] },
            set: { value in self.updateMemory { $0[keyPath: keyPath] = value } })
    }

    func memoryBinding<Value>(_ keyPath: WritableKeyPath<NativeMemorySettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.nativeSettings.memory[keyPath: keyPath] },
            set: { value in self.updateMemory { $0[keyPath: keyPath] = value } })
    }

    func liveMemoryBinding<Value>(_ keyPath: WritableKeyPath<NativeMemorySettings, Value>, store: ChatStore) -> Binding<Value> {
        Binding(
            get: { self.nativeSettings.memory[keyPath: keyPath] },
            set: { value in self.applyMemorySetting(to: store) { $0[keyPath: keyPath] = value } })
    }

    func applyMemorySetting(to store: ChatStore, _ update: (inout NativeMemorySettings) -> Void) {
        updateMemory(update)
        let saved = (try? save()) != nil
        store.updateNativeMemory(settings: nativeSettings.memory, service: nativeMemoryService)
        store.memorySettingsNotice = saved ? nil : "This change applies now, but it couldn't be saved for the next launch."
    }

    var memoryEndpointLocation: String? {
        guard let host = memoryEndpointResolved?.baseURL.host, !host.isEmpty else { return nil }
        return "Memory endpoint: \(host), \(Self.isLoopbackHost(host) ? "on this Mac" : "remote")."
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return normalized == "localhost" || normalized.hasSuffix(".localhost")
            || normalized == "::1" || normalized.hasPrefix("127.")
    }

    func memoryBoolBinding(_ keyPath: WritableKeyPath<NativeMemorySettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { self.nativeSettings.memory[keyPath: keyPath] },
            set: { value in self.updateMemory { $0[keyPath: keyPath] = value } })
    }

    func beginOnboarding(at step: Int? = nil) {
        var updated = nativeSettings
        let target = step ?? updated.onboardingStep
        updated.onboardingState = .inProgress
        updated.onboardingStep = target
        nativeSettings = updated
        showOnboarding = true
        try? save()
    }

    func updateOnboarding(step: Int) {
        var updated = nativeSettings
        updated.onboardingState = .inProgress
        updated.onboardingStep = step
        nativeSettings = updated
        try? save()
    }

    func skipOnboarding() {
        var updated = nativeSettings
        updated.onboardingState = .skipped
        nativeSettings = updated
        showOnboarding = false
        try? save()
    }

    func completeOnboarding() {
        var updated = nativeSettings
        updated.onboardingState = .complete
        updated.onboardingStep = 0
        nativeSettings = updated
        showOnboarding = false
        try? save()
    }

    var veraAPIBase: URL? {
        VeraAPIClient.resolvedBase()
    }

    var imageBase: URL? {
        NativeImageTools.resolvedBase()
    }

    var voiceBase: URL? {
        let env = ProcessInfo.processInfo.environment["VERA_VOICE_BASE"]
        let v = (env?.isEmpty == false ? env : nil) ?? (raw["voice_base"] as? String)
        let trimmed = v?.trimmingCharacters(in: .whitespaces)
        return (trimmed?.isEmpty == false) ? URL(string: trimmed!) : nil
    }

    /// The person's name — drives the greeting and the sidebar chip. Nil when unset.
    var ownerName: String? {
        let env = ProcessInfo.processInfo.environment["VERA_OWNER_NAME"]
        let v = (env?.isEmpty == false ? env : nil) ?? (raw["owner_name"] as? String)
        let trimmed = v?.trimmingCharacters(in: .whitespaces)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    static let defaultAssistantName = "Vera"

    var assistantName: String {
        let env = ProcessInfo.processInfo.environment["VERA_ASSISTANT_NAME"]
        let v = (env?.isEmpty == false ? env : nil) ?? (raw["assistant_name"] as? String)
        let trimmed = v?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? Self.defaultAssistantName : trimmed
    }
}

/// One-shot connectivity checks used by Settings and onboarding. Each returns a short
/// human-readable success line or throws with a human-readable failure.
enum ConnectionTest {
    enum TestError: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let m): return m } }
    }

    static func models(base: String, apiKey: String) async throws -> [String] {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == "http" || url.scheme == "https",
              url.lastPathComponent == "v1" else {
            throw TestError.message("Enter a valid model endpoint ending in /v1")
        }
        let config = NativeChatConfig(
            baseURL: url,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            model: "discovery",
            chatTemplateKwargs: nil)
        return try await NativeChatClient(config: config).discoverModels()
    }

    /// Probe a service health endpoint — any 2xx counts as alive.
    static func http(base: String, path: String, label: String) async throws -> String {
        guard let url = URL(string: base)?.appendingPathComponent(path), url.scheme != nil else {
            throw TestError.message("Enter a valid \(label) URL first")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw TestError.message("\(label) answered HTTP \(code)")
        }
        return "\(label) is reachable"
    }

    /// Probe the voice host by opening (and closing) a Wyoming ASR connection.
    static func voice(base: String) async throws -> String {
        guard let url = URL(string: base), url.host != nil else {
            throw TestError.message("Enter a valid voice URL first")
        }
        guard await VoiceClient(base: url).health() else {
            throw TestError.message("Voice host not answering on the Wyoming port")
        }
        return "Voice service is reachable"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
