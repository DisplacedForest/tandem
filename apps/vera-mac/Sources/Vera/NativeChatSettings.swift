import Foundation
import Security
import LocalAuthentication

enum ModelSelectionBasis: String, Codable, Equatable, Sendable {
    case user
    case recommended
    case restored

    var explanation: String {
        switch self {
        case .user: return "You chose this model."
        case .recommended: return "Vera selected the first model returned alphabetically."
        case .restored: return "This model was restored from your saved configuration."
        }
    }
}

enum NativeOnboardingState: String, Codable, Equatable, Sendable {
    case notStarted
    case inProgress
    case skipped
    case complete
}

struct NativeEndpointProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var discoveredModels: [String]
    var selectedModel: String
    var selectionBasis: ModelSelectionBasis?
    var lastDiscoveryAt: Date?

    static func empty() -> NativeEndpointProfile {
        NativeEndpointProfile(
            id: UUID().uuidString,
            name: "New endpoint",
            baseURL: "",
            discoveredModels: [],
            selectedModel: "",
            selectionBasis: nil,
            lastDiscoveryAt: nil)
    }
}

struct NativeDiscoveryConfiguration: Equatable, Sendable {
    let baseURL: String
    let apiKey: String
}

enum NativeChatConfigurationResolver {
    static func discovery(
        profile: NativeEndpointProfile?,
        apiKey: String,
        environment: [String: String]
    ) -> NativeDiscoveryConfiguration {
        NativeDiscoveryConfiguration(
            baseURL: environment["VERA_MODEL_BASE"]?.nonblank ?? profile?.baseURL.nonblank ?? "",
            apiKey: environment["VERA_MODEL_API_KEY"]?.nonblank ?? apiKey.nonblank ?? "")
    }
}

struct NativeChatSettings: Codable, Equatable, Sendable {
    static let defaultSystemPrompt = """
    You are a personal assistant running locally on your user's own hardware, working only with this machine and the services it is connected to.
    Tell the truth, including about yourself and your limits. When you are unsure, say so plainly instead of guessing.
    Be warm and direct. Write naturally and concisely, like a thoughtful person; skip filler and hedging.
    Push back respectfully when you disagree or a request looks like a mistake.
    What one household member shares with you stays private from the others unless they ask you to pass it on.
    If something is unavailable or outside what this request provides, say so instead of improvising.
    """

    var version: Int
    var profiles: [NativeEndpointProfile]
    var activeProfileID: String?
    var systemPrompt: String
    var activePersonaID: String?
    var enabledToolIDs: Set<String>
    var onboardingState: NativeOnboardingState
    var onboardingStep: Int
    var memory: NativeMemorySettings
    var capabilityOverrides: [String: ModelCapabilityProfile]
    var visionBridge: VisionBridgeSettings
    var parameterOverrides: [String: [String: ModelParameterOverrides]]

    static var fresh: NativeChatSettings {
        NativeChatSettings(
            version: 3,
            profiles: [],
            activeProfileID: nil,
            systemPrompt: defaultSystemPrompt,
            activePersonaID: nil,
            enabledToolIDs: [],
            onboardingState: .notStarted,
            onboardingStep: 0,
            memory: .fresh,
            capabilityOverrides: [:],
            visionBridge: .fresh,
            parameterOverrides: [:])
    }

    var activeProfile: NativeEndpointProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    var hasValidConfiguration: Bool {
        guard let profile = activeProfile else { return false }
        let base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = profile.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && url.lastPathComponent == "v1"
            && !model.isEmpty
    }

    static func load(from raw: [String: Any]) -> NativeChatSettings {
        if let object = raw["native_chat"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: object),
           var decoded = try? JSONDecoder().decode(NativeChatSettings.self, from: data),
           (1...3).contains(decoded.version) {
            decoded.version = 3
            if decoded.activeProfile == nil { decoded.activeProfileID = decoded.profiles.first?.id }
            if decoded.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                decoded.systemPrompt = defaultSystemPrompt
            }
            return decoded
        }
        let base = (raw["model_base"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = (raw["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !base.isEmpty || !model.isEmpty else { return .fresh }
        let profile = NativeEndpointProfile(
            id: "default",
            name: "My model endpoint",
            baseURL: base,
            discoveredModels: [],
            selectedModel: model,
            selectionBasis: model.isEmpty ? nil : .restored,
            lastDiscoveryAt: nil)
        var settings = fresh
        settings.profiles = [profile]
        settings.activeProfileID = profile.id
        settings.onboardingState = settings.hasValidConfiguration ? .complete : .notStarted
        return settings
    }

    enum CodingKeys: String, CodingKey {
        case version, profiles, activeProfileID, systemPrompt, activePersonaID, enabledToolIDs
        case onboardingState, onboardingStep, memory, capabilityOverrides, visionBridge
        case parameterOverrides
    }

    init(
        version: Int, profiles: [NativeEndpointProfile], activeProfileID: String?,
        systemPrompt: String, activePersonaID: String? = nil,
        enabledToolIDs: Set<String>, onboardingState: NativeOnboardingState,
        onboardingStep: Int, memory: NativeMemorySettings,
        capabilityOverrides: [String: ModelCapabilityProfile] = [:],
        visionBridge: VisionBridgeSettings = .fresh,
        parameterOverrides: [String: [String: ModelParameterOverrides]] = [:]
    ) {
        self.version = version
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.systemPrompt = systemPrompt
        self.activePersonaID = activePersonaID
        self.enabledToolIDs = enabledToolIDs
        self.onboardingState = onboardingState
        self.onboardingStep = onboardingStep
        self.memory = memory
        self.capabilityOverrides = capabilityOverrides
        self.visionBridge = visionBridge
        self.parameterOverrides = parameterOverrides
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profiles = try values.decodeIfPresent([NativeEndpointProfile].self, forKey: .profiles) ?? []
        activeProfileID = try values.decodeIfPresent(String.self, forKey: .activeProfileID)
        systemPrompt = try values.decodeIfPresent(String.self, forKey: .systemPrompt) ?? Self.defaultSystemPrompt
        activePersonaID = try values.decodeIfPresent(String.self, forKey: .activePersonaID)
        enabledToolIDs = try values.decodeIfPresent(Set<String>.self, forKey: .enabledToolIDs) ?? []
        onboardingState = try values.decodeIfPresent(NativeOnboardingState.self, forKey: .onboardingState) ?? .notStarted
        onboardingStep = try values.decodeIfPresent(Int.self, forKey: .onboardingStep) ?? 0
        memory = try values.decodeIfPresent(NativeMemorySettings.self, forKey: .memory) ?? .fresh
        capabilityOverrides = try values.decodeIfPresent(
            [String: ModelCapabilityProfile].self, forKey: .capabilityOverrides) ?? [:]
        visionBridge = try values.decodeIfPresent(
            VisionBridgeSettings.self, forKey: .visionBridge) ?? .fresh
        parameterOverrides = try values.decodeIfPresent(
            [String: [String: ModelParameterOverrides]].self, forKey: .parameterOverrides) ?? [:]
    }

    func merging(into raw: [String: Any]) -> [String: Any] {
        var merged = raw
        if let data = try? JSONEncoder().encode(self),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            merged["native_chat"] = object
        }
        if let profile = activeProfile {
            merged["model_base"] = profile.baseURL
            merged["model"] = profile.selectedModel
        } else {
            merged.removeValue(forKey: "model_base")
            merged.removeValue(forKey: "model")
        }
        merged.removeValue(forKey: "model_api_key")
        return merged
    }

    mutating func resetSystemPrompt() {
        systemPrompt = Self.defaultSystemPrompt
    }

    mutating func addProfile() {
        let profile = NativeEndpointProfile.empty()
        profiles.append(profile)
        activeProfileID = profile.id
    }

    mutating func updateActiveProfile(_ update: (inout NativeEndpointProfile) -> Void) {
        guard let activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        update(&profiles[index])
    }

    mutating func cacheModels(_ models: [String], at date: Date = Date()) {
        let sorted = Array(Set(models.filter { !$0.isEmpty })).sorted()
        updateActiveProfile {
            $0.discoveredModels = sorted
            $0.lastDiscoveryAt = date
            if $0.selectedModel.isEmpty, let first = sorted.first {
                $0.selectedModel = first
                $0.selectionBasis = .recommended
            }
        }
    }

    mutating func selectModel(_ model: String, basis: ModelSelectionBasis) {
        updateActiveProfile {
            $0.selectedModel = model
            $0.selectionBasis = basis
        }
    }

    func resolveCapabilities(model: String) -> ModelCapabilityCatalog.Resolution {
        ModelCapabilityCatalog.resolve(model: model, overrides: capabilityOverrides)
    }

    mutating func setCapabilityOverride(model: String, profile: ModelCapabilityProfile) {
        capabilityOverrides[model] = profile
    }

    mutating func clearCapabilityOverride(model: String) {
        capabilityOverrides.removeValue(forKey: model)
    }

    func parameterOverrides(profileID: String?, model: String) -> ModelParameterOverrides {
        guard let profileID, !model.isEmpty else { return .empty }
        return parameterOverrides[profileID]?[model] ?? .empty
    }

    mutating func updateParameterOverrides(
        profileID: String, model: String, _ update: (inout ModelParameterOverrides) -> Void
    ) {
        guard !model.isEmpty else { return }
        var overrides = parameterOverrides[profileID]?[model] ?? .empty
        update(&overrides)
        if overrides.isEmpty {
            parameterOverrides[profileID]?.removeValue(forKey: model)
            if parameterOverrides[profileID]?.isEmpty == true {
                parameterOverrides.removeValue(forKey: profileID)
            }
        } else {
            parameterOverrides[profileID, default: [:]][model] = overrides
        }
    }
}

enum ModelDiscoveryState: Equatable {
    case idle
    case loading
    case models([String])
    case empty
    case noUsableModels
    case authenticationFailed
    case networkFailed
    case malformed
    case failed(String)

    static func classify(_ error: Error) -> ModelDiscoveryState {
        if let client = error as? NativeChatClient.ClientError {
            switch client {
            case .http(let status, _):
                return status == 401 || status == 403 ? .authenticationFailed : .failed(client.localizedDescription)
            case .invalidResponse, .malformedEvent: return .malformed
            case .noUsableModels: return .noUsableModels
            case .server, .interrupted: return .failed(client.localizedDescription)
            }
        }
        if error is URLError { return .networkFailed }
        return .failed(error.localizedDescription)
    }
}

struct NativeChatToolDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let available: Bool
    let setup: String
}

enum NativeChatToolCatalog {
    static var tools: [NativeChatToolDescriptor] {
        tools(veraAPIConfigured: VeraAPIClient.resolvedBase() != nil)
    }

    static func tools(
        veraAPIConfigured: Bool, declarations: [NativeToolDeclaration] = []
    ) -> [NativeChatToolDescriptor] {
        builtIn(veraAPIConfigured: veraAPIConfigured)
            + NativeCapabilityTools.descriptors(declarations, veraAPIConfigured: veraAPIConfigured)
    }

    private static func builtIn(veraAPIConfigured: Bool) -> [NativeChatToolDescriptor] {
        [
            NativeChatToolDescriptor(
                id: "apple-reminders",
                name: "Apple Reminders",
                summary: "Reads and updates reminder lists after you grant access.",
                available: true,
                setup: "Enable this tool to grant Reminders access for explicit chat requests."),
            NativeChatToolDescriptor(
                id: "web-search",
                name: "Web search",
                summary: "Searches the web through your vera-api and answers from the results.",
                available: veraAPIConfigured,
                setup: "Set the vera-api base URL in the Connection tab to enable web search."),
            NativeChatToolDescriptor(
                id: "deep-research",
                name: "Deep research",
                summary: "Runs a multi-step research pass through your vera-api and cites its sources.",
                available: veraAPIConfigured,
                setup: "Set the vera-api base URL in the Connection tab to enable deep research."),
        ]
    }

    static func exposed(enabledIDs: Set<String>) -> [NativeChatToolDescriptor] {
        tools.filter { $0.available && enabledIDs.contains($0.id) }
    }
}

enum NativeCredentialError: Error, LocalizedError {
    case read, format, write, removal, migrationConflict

    var errorDescription: String? {
        switch self {
        case .read: return "A saved API key couldn't be read. It remains unchanged in Keychain."
        case .format: return "The saved API key has an unsupported format. It remains unchanged in Keychain."
        case .write: return "The API key couldn't be saved. Your edit is still here; try Save again."
        case .removal: return "The API key couldn't be removed. Try Save again."
        case .migrationConflict: return "A saved API key already exists. Reopen settings before changing it."
        }
    }
}

struct NativeKeychainOperations {
    var authenticationContext: () -> LAContext = { LAContext() }
    var interactionAllowed: () -> (OSStatus, Bool) = {
        var allowed = DarwinBoolean(false)
        return (SecKeychainGetUserInteractionAllowed(&allowed), allowed.boolValue)
    }
    var setInteraction: (Bool) -> OSStatus = { SecKeychainSetUserInteractionAllowed($0) }
    var read: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { SecItemCopyMatching($0, $1) }
    var update: (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) }
    var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { SecItemAdd($0, $1) }
    var delete: (CFDictionary) -> OSStatus = { SecItemDelete($0) }
}

protocol NativeCredentialStore {
    func read(for profileID: String) throws -> String?
    @MainActor func readForStartup(for profileID: String) throws -> String?
    func value(for profileID: String) -> String?
    func set(_ value: String?, for profileID: String) throws
    func addIfAbsent(_ value: String, for profileID: String) throws
}

extension NativeCredentialStore {
    @MainActor func readForStartup(for profileID: String) throws -> String? { try read(for: profileID) }
    func value(for profileID: String) -> String? { try? read(for: profileID) }
}

struct KeychainNativeCredentialStore: NativeCredentialStore {
    var allowsInteraction = true
    var operations = NativeKeychainOperations()
    private let service = "org.displacedforest.vera.native-chat"

    private func query(for profileID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: profileID]
    }

    @MainActor func readForStartup(for profileID: String) throws -> String? {
        let (status, prior) = operations.interactionAllowed()
        guard status == errSecSuccess else { throw NativeCredentialError.read }
        let disabled = operations.setInteraction(false)
        let (verified, allowed) = operations.interactionAllowed()
        let result: Result<String?, Error>
        if disabled != errSecSuccess || verified != errSecSuccess || allowed {
            result = .failure(NativeCredentialError.read)
        } else {
            var startup = self
            startup.allowsInteraction = false
            let read = operations.read
            startup.operations.read = { query, value in
                var dictionary = query as! [String: Any]
                guard let context = dictionary[kSecUseAuthenticationContext as String] as? LAContext,
                      context.interactionNotAllowed else { return errSecInteractionNotAllowed }
                dictionary[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
                return read(dictionary as CFDictionary, value)
            }
            do { result = .success(try startup.read(for: profileID)) }
            catch { result = .failure(error) }
        }
        let restored = operations.setInteraction(prior)
        let (restoreStatus, restoredValue) = operations.interactionAllowed()
        guard restored == errSecSuccess, restoreStatus == errSecSuccess, restoredValue == prior else {
            throw NativeCredentialError.read
        }
        return try result.get()
    }

    func read(for profileID: String) throws -> String? {
        var query = query(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsInteraction {
            let context = operations.authenticationContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = operations.read(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NativeCredentialError.read }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw NativeCredentialError.format }
        return value
    }

    func set(_ value: String?, for profileID: String) throws {
        let query = query(for: profileID)
        guard let value, !value.isEmpty else {
            let status = operations.delete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeCredentialError.removal }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = operations.update(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { try addIfAbsent(value, for: profileID) }
        else if status != errSecSuccess { throw NativeCredentialError.write }
    }

    func addIfAbsent(_ value: String, for profileID: String) throws {
        var item = query(for: profileID)
        item[kSecValueData as String] = Data(value.utf8)
        let status = operations.add(item as CFDictionary, nil)
        if status == errSecDuplicateItem { throw NativeCredentialError.migrationConflict }
        guard status == errSecSuccess else { throw NativeCredentialError.write }
    }
}

private extension String {
    var nonblank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
