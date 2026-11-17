import Foundation

@MainActor
final class NativeTaskConfiguration {
    let settings: () -> NativeChatSettings
    let savedTemplate: () -> String?
    let credential: (String) -> String?
    let generationOptions: NativeChatRequestOptions?

    init(settings: @escaping () -> NativeChatSettings,
         savedTemplate: @escaping () -> String? = { nil },
         generationOptions: NativeChatRequestOptions? = nil,
         credential: @escaping (String) -> String? = {
             AppLocations.credentialStore(allowsInteraction: false).value(for: $0)
         }) {
        self.generationOptions = generationOptions
        self.settings = settings
        self.savedTemplate = savedTemplate
        self.credential = credential
    }

    func enroll(config: NativeChatConfig, limits: NativeTaskGenerationLimits? = nil,
                fixtureExecutionModel: String? = nil) throws -> NativeTaskProfileBinding {
        guard let profile = settings().activeProfile,
              let url = URL(string: profile.baseURL),
              let provider = try? NativeTaskEngineIdentity(url),
              provider == (try? NativeTaskEngineIdentity(config.baseURL)),
              profile.selectedModel == config.model, !profile.selectedModel.isEmpty else {
            throw NativeTaskError.invalidRequest("Choose a saved model profile before starting background research.")
        }
        let executionModel = fixtureExecutionModel ?? profile.selectedModel
        return NativeTaskProfileBinding(id: UUID().uuidString, profileID: profile.id,
            provider: provider, savedModel: profile.selectedModel,
            executionModel: executionModel,
            limits: try limits ?? NativeTaskGenerationLimits(),
            requiresCredential: config.apiKey?.isEmpty == false,
            reasoning: Self.reasoningOn(options(profileID: profile.id, model: executionModel)))
    }

    static func reasoningOn(_ options: NativeChatRequestOptions) -> Bool {
        guard let entry = options.topLevel.first(where: { $0.key == "reasoning" }),
              case .object(let values) = entry.value else { return false }
        if case .bool(let enabled) = values["enabled"] { return enabled }
        if case .string(let effort) = values["effort"] { return ["minimal", "low", "medium", "high"].contains(effort) }
        return false
    }

    private func options(profileID: String, model: String) -> NativeChatRequestOptions {
        let current = settings()
        let capability = current.resolveCapabilities(model: model).profile
        return generationOptions ?? NativeChatRequestOptions.resolve(
            overrides: current.parameterOverrides(profileID: profileID, model: model),
            profile: capability, savedTemplateKwargs: savedTemplate(), environmentTemplateKwargs: nil)
    }

    func matches(_ binding: NativeTaskProfileBinding) -> Bool {
        guard let profile = settings().profiles.first(where: { $0.id == binding.profileID }),
              let url = URL(string: profile.baseURL),
              (try? NativeTaskEngineIdentity(url)) == binding.provider else { return false }
        return profile.selectedModel == binding.savedModel
    }

    func isAvailable(_ binding: NativeTaskProfileBinding) -> Bool {
        guard matches(binding) else { return false }
        return !binding.requiresCredential || credential(binding.profileID)?.isEmpty == false
    }

    func load(_ binding: NativeTaskProfileBinding) throws -> NativeChatConfig {
        guard matches(binding) else { throw NativeTaskGenerationFailure(code: "profile_changed") }
        let key = credential(binding.profileID)
        guard !binding.requiresCredential || key?.isEmpty == false else {
            throw NativeTaskGenerationFailure(code: "credential_unavailable")
        }
        let resolved = options(profileID: binding.profileID, model: binding.executionModel)
        return NativeChatConfig(baseURL: binding.provider.base, apiKey: key,
            model: binding.executionModel, chatTemplateKwargs: savedTemplate(), streaming: false, options: resolved)
    }
}

final class NativeTaskEngineSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?

    init(_ value: URL?) { self.value = value }

    var base: URL? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: URL?) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}
