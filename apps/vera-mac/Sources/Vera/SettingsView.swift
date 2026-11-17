import Carbon.HIToolbox
import SwiftUI

/// The Settings window (⌘,) — every endpoint and identity value editable in-app, written to
/// `~/.vera/config.json`. Env vars still win over file values; env-overridden fields carry
struct SettingsView: View {
    @EnvironmentObject var store: ChatStore
    var body: some View {
        TabView(selection: $store.settingsTab) {
            ConnectionTab().tabItem { Label("Endpoints", systemImage: "link") }.tag(SettingsTab.connection)
            ModelTab().tabItem { Label("Model", systemImage: "cpu") }.tag(SettingsTab.model)
            PersonaTab().tabItem { Label("Persona", systemImage: "text.quote") }.tag(SettingsTab.persona)
            NativeMemorySettingsTab().tabItem { Label("Memory", systemImage: "tray.full") }.tag(SettingsTab.memory)
            KnowledgeView().tabItem { Label("Knowledge", systemImage: "books.vertical") }.tag(SettingsTab.knowledge)
            NativeToolsTab().tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }.tag(SettingsTab.nativeTools)
            RulesSettingsTab().tabItem { Label("Rules", systemImage: "checklist") }.tag(SettingsTab.rules)
            ImageTab().tabItem { Label("Image", systemImage: "photo") }.tag(SettingsTab.image)
            SearchTab().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(SettingsTab.search)
            ServicesTab().tabItem { Label("Services", systemImage: "server.rack") }.tag(SettingsTab.services)
            PluginsView().tabItem { Label("Plugins", systemImage: "shippingbox") }.tag(SettingsTab.plugins)
            IdentityTab().tabItem { Label("Identity", systemImage: "person") }.tag(SettingsTab.identity)
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 860, height: 640)
    }
}

// MARK: - Tabs

struct ConnectionTab: View {
    @EnvironmentObject var config: ConfigStore
    var body: some View {
        Form {
            Section {
                NativeEndpointEditor()
            } header: {
                HStack(spacing: 6) {
                    Text("Saved endpoints")
                    InfoTip(text: ModelSettingsCopy.endpointsTip)
                }
            }
            Section {
                Button("Resume setup guide") { config.beginOnboarding() }
            } header: {
                HStack(spacing: 6) {
                    Text("Setup guide")
                    InfoTip(text: ModelSettingsCopy.setupGuideTip)
                }
            }
            SaveSection()
        }
        .formStyle(.grouped)
    }
}

struct ModelTab: View {
    var body: some View {
        Form {
            Section("Choose a model") {
                NativeModelEditor()
            }
            Section {
                NativeCapabilityEditor()
            } header: {
                HStack(spacing: 6) {
                    Text("Capabilities")
                    InfoTip(text: ModelSettingsCopy.capabilitiesTip)
                }
            }
            Section {
                NativeVisionBridgeEditor()
            } header: {
                HStack(spacing: 6) {
                    Text("Vision bridge")
                    InfoTip(text: ModelSettingsCopy.visionBridgeTip)
                }
            }
            Section {
                NativeAdvancedControlsEditor()
            }
            SaveSection()
        }
        .formStyle(.grouped)
    }
}

struct PersonaTab: View {
    var body: some View {
        Form {
            Section("Preferences") { PreferencesSettingsView() }
            Section("Prompt library") { PromptLibraryView() }
            SaveSection()
        }
        .formStyle(.grouped)
    }
}

struct NativeToolsTab: View {
    var body: some View {
        Form {
            Section("Tools") { NativeToolEditor() }
            SaveSection()
        }
        .formStyle(.grouped)
    }
}

struct NativeEndpointEditor: View {
    @EnvironmentObject var config: ConfigStore
    var addsOnEntry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if config.nativeSettings.profiles.isEmpty {
                Text(ModelSettingsCopy.noEndpoint)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Button("Add endpoint") { config.addNativeProfile() }
            } else {
                HStack(spacing: 10) {
                    Picker("Endpoint", selection: Binding(
                        get: { config.nativeSettings.activeProfileID ?? "" },
                        set: { config.selectProfile($0) })) {
                        ForEach(config.nativeSettings.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    Button("Add") { config.addNativeProfile() }
                }
                LabeledContent("Saved name") {
                    TextField("", text: config.activeProfileBinding(\.name),
                              prompt: Text(verbatim: ModelSettingsCopy.namePlaceholder))
                        .labelsHidden().accessibilityLabel("Saved name").textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                }
                LabeledContent("Base URL") {
                    TextField("", text: config.activeProfileBinding(\.baseURL),
                              prompt: Text(verbatim: ModelSettingsCopy.baseURLPlaceholder))
                        .labelsHidden().accessibilityLabel("Base URL").textFieldStyle(.roundedBorder).autocorrectionDisabled().frame(maxWidth: 360)
                }
                LabeledContent("API key") {
                    SecureField("", text: config.apiKeyBinding(),
                                prompt: Text(verbatim: ModelSettingsCopy.optionalPlaceholder))
                        .labelsHidden().accessibilityLabel("API key").textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                }
                if let error = config.credentialError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                }
                if let override = config.envOverride("model_base") {
                    Text("\(override) currently overrides this saved endpoint URL.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            if addsOnEntry { config.addNativeProfileOnEntry() }
        }
    }
}

struct NativeModelEditor: View {
    @EnvironmentObject var config: ConfigStore
    @State private var discovery: ModelDiscoveryState = .idle

    private var profile: NativeEndpointProfile? { config.activeNativeProfile }
    private var models: [String] {
        switch discovery {
        case .models(let values): return values
        default: return profile?.discoveredModels ?? []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let profile {
                Text("Endpoint: \(profile.name)")
                    .font(.system(size: 12, weight: .medium))
                Button(discovery == .loading ? ModelSettingsCopy.looking : "Refresh model list") { discover() }
                    .disabled(discovery == .loading)
                    .help(discovery == .idle && !models.isEmpty ? ModelSettingsCopy.savedListHelp : "")
                discoveryMessage
                if !profile.selectedModel.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Selected model").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        Text(config.nativeResolved?.model ?? profile.selectedModel).font(.system(.body, design: .monospaced))
                        Text(config.envOverride("model").map { "\($0) selects the active model. Change that environment value to use the saved choice." }
                            ?? profile.selectionBasis?.explanation
                            ?? "Choose a model below.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        if !profile.discoveredModels.isEmpty,
                           !profile.discoveredModels.contains(profile.selectedModel) {
                            Text("This saved selection was not in the latest model list. It stays selected until you choose another model.")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if models.isEmpty {
                    Text("No cached models. Refresh to ask this endpoint for its model list.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(models, id: \.self) { model in
                            Button { config.selectNativeModel(model) } label: {
                                HStack {
                                    Image(systemName: profile.selectedModel == model ? "checkmark.circle.fill" : "circle")
                                    Text(model).font(.system(.body, design: .monospaced))
                                    Spacer()
                                }
                                .contentShape(Rectangle()).padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            if model != models.last { Divider() }
                        }
                    }
                }
            } else {
                Text(ModelSettingsCopy.endpointFirst)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder private var discoveryMessage: some View {
        if let text = ModelSettingsCopy.discoveryMessage(discovery) {
            switch discovery {
            case .idle:
                EmptyView()
            case .loading:
                HStack { ProgressView().controlSize(.small); Text(verbatim: text) }
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            case .models:
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.green)
            case .empty:
                Label(text, systemImage: "tray")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            case .noUsableModels:
                Label(text, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            case .authenticationFailed:
                Label(text, systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 12)).foregroundStyle(.red)
            case .networkFailed:
                Label(text, systemImage: "network.slash")
                    .font(.system(size: 12)).foregroundStyle(.red)
            case .malformed:
                Label(text, systemImage: "doc.badge.ellipsis")
                    .font(.system(size: 12)).foregroundStyle(.red)
            case .failed:
                Label(text, systemImage: "xmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.red)
            }
        }
    }

    private func discover() {
        guard profile != nil else { return }
        discovery = .loading
        Task {
            do {
                let active = config.nativeDiscoveryConfiguration
                let values = try await ConnectionTest.models(base: active.baseURL, apiKey: active.apiKey)
                config.cacheDiscoveredModels(values)
                discovery = values.isEmpty ? .empty : .models(values)
                try? config.save()
            } catch {
                discovery = ModelDiscoveryState.classify(error)
            }
        }
    }
}

struct NativeCapabilityEditor: View {
    @EnvironmentObject var config: ConfigStore

    private var model: String {
        config.nativeResolved?.model
            ?? config.activeNativeProfile?.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
    private var resolution: ModelCapabilityCatalog.Resolution {
        config.nativeSettings.resolveCapabilities(model: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isEmpty {
                Text(ModelSettingsCopy.chooseModel)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            } else {
                if resolution.source == .override {
                    Button("Use defaults") { config.clearCapabilityOverride(model: model) }
                }
                Toggle("Accepts image input", isOn: capabilityBinding(\.acceptsImages))
                if resolution.profile.acceptsImages {
                    Stepper(
                        "Images per request: \(resolution.profile.maxImagesPerRequest)",
                        value: Binding(
                            get: { resolution.profile.maxImagesPerRequest },
                            set: { value in
                                config.updateCapability(model: model) { $0.maxImagesPerRequest = value }
                            }),
                        in: 1...16)
                }
                Toggle(ModelSettingsCopy.usesTools, isOn: capabilityBinding(\.supportsTools))
                Toggle("Supports streaming replies", isOn: capabilityBinding(\.supportsStreaming))
                Toggle("Supports reasoning controls", isOn: capabilityBinding(\.supportsReasoning))
            }
        }
    }

    private func capabilityBinding(_ keyPath: WritableKeyPath<ModelCapabilityProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { resolution.profile[keyPath: keyPath] },
            set: { value in
                config.updateCapability(model: model) { profile in
                    profile[keyPath: keyPath] = value
                    if keyPath == \.acceptsImages, value, profile.maxImagesPerRequest < 1 {
                        profile.maxImagesPerRequest = ModelCapabilityProfile.vision.maxImagesPerRequest
                    }
                }
            })
    }
}

struct NativeVisionBridgeEditor: View {
    @EnvironmentObject var config: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Base URL") {
                TextField("", text: config.visionBridgeBinding(\.baseURL),
                          prompt: Text(verbatim: ModelSettingsCopy.visionBaseURLPlaceholder))
                    .labelsHidden().accessibilityLabel("Base URL").textFieldStyle(.roundedBorder).autocorrectionDisabled().frame(maxWidth: 360)
            }
            LabeledContent("Model") {
                TextField("", text: config.visionBridgeBinding(\.model),
                          prompt: Text(verbatim: ModelSettingsCopy.visionModelPlaceholder))
                    .labelsHidden().accessibilityLabel("Model").textFieldStyle(.roundedBorder).autocorrectionDisabled().frame(maxWidth: 360)
            }
            LabeledContent("API key") {
                SecureField("", text: $config.visionBridgeAPIKey,
                            prompt: Text(verbatim: ModelSettingsCopy.optionalPlaceholder))
                    .labelsHidden().accessibilityLabel("API key").textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            }
            if let error = config.credentialError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
            }
            if config.nativeSettings.visionBridge.isConfigured {
                Label("The bridge is configured. Unsupported attachments are described here, with disclosure on every bridged turn.",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.green)
            }
        }
    }
}

enum ModelSettingsCopy {
    static let endpointsTip = "API keys are kept in your Mac keychain. The address is the one your model server gives for its OpenAI-compatible API, usually ending in /v1."
    static let capabilitiesTip = "These describe what the chosen model can do. Tandem doesn't check them for you."
    static let visionBridgeTip = "If the chosen model can't read images, Tandem can send them to a second model that can and pass its description along. Without one, Tandem asks before sending a message without its attachment."
    static let setupGuideTip = "You can run the guide again at any time. Your saved endpoints, prompt, tools and chat history stay in place."
    static let setupNote = "API keys are saved in your Mac keychain. Use the OpenAI-compatible API root ending in /v1."
    static let namePlaceholder = "Home model server"
    static let baseURLPlaceholder = "https://model-host.example/v1"
    static let visionBaseURLPlaceholder = "https://vision-host.example/v1"
    static let visionModelPlaceholder = "Model name"
    static let optionalPlaceholder = "Optional"
    static let savedWithoutModel = "Saved. Add a model server and choose a model to start chatting."
    static let savedListHelp = "This is the list from the last time it loaded."
    static let loading = "Loading models…"
    static let noEndpoint = "Add a model server to begin."
    static let endpointFirst = "Add a model server first."
    static let chooseModel = "Choose a model to see what it can do."
    static let looking = "Looking for models…"
    static let usesTools = "Can use tools"
    static let empty = "The endpoint returned an empty model list. Check the server, then retry."
    static let noUsableModels = "The server listed models, but none of them can be used."
    static let authenticationFailed = "Authentication failed. Check the API key, save it, then retry."
    static let networkFailed = "Tandem could not reach the endpoint. Check its URL and network connection, then retry."
    static let malformed = "The endpoint returned a model response Tandem could not read."

    static var fixedStrings: [String] {
        [endpointsTip, capabilitiesTip, visionBridgeTip, setupGuideTip, setupNote, namePlaceholder, baseURLPlaceholder, visionBaseURLPlaceholder,
         visionModelPlaceholder, optionalPlaceholder, savedWithoutModel, savedListHelp, loading, noEndpoint, endpointFirst,
         chooseModel, looking, usesTools, empty, noUsableModels,
         authenticationFailed, networkFailed, malformed]
    }

    static func loaded(_ count: Int) -> String {
        "Loaded \(count) model\(count == 1 ? "" : "s")"
    }

    static func discoveryMessage(_ state: ModelDiscoveryState) -> String? {
        switch state {
        case .idle: return nil
        case .loading: return loading
        case .models(let values): return loaded(values.count)
        case .empty: return empty
        case .noUsableModels: return noUsableModels
        case .authenticationFailed: return authenticationFailed
        case .networkFailed: return networkFailed
        case .malformed: return malformed
        case .failed(let message): return message
        }
    }
}

enum SettingsToolsCopy {
    static let empty = "No tools are available."
    static let services = "Connected services are managed under Integrations."
    static let openIntegrations = "Open Integrations"
    static let openSearch = "Open Search"
    static let openImage = "Open Image"

    static var fixedStrings: [String] {
        [empty, services, openIntegrations, openSearch, openImage]
    }

    static let fieldTypes = "string, boolean, integer or number"

    static func failureLine(_ failure: NativeToolDeclarationFailure) -> String {
        failureLine(file: failure.file, problem: failure.problem)
    }

    static func failureLine(file: String, problem: NativeToolDeclarationProblem) -> String {
        "\((file as NSString).lastPathComponent) wasn't loaded. " + fix(problem)
    }

    static func fix(_ problem: NativeToolDeclarationProblem) -> String {
        switch problem {
        case .unreadable: return "Tandem couldn't open it. Check that the file can be read, then save it again."
        case .notJSON: return "Tandem couldn't read what's in it. Check its brackets, commas and quotes, then save."
        case .missing(let key): return "It needs a \"\(key)\". Add one and save."
        case .badName: return "Its \"name\" must start with a letter and use only letters, digits and underscores. Rename it and save."
        case .badParameters: return "Its \"parameters\" must say \"type\": \"object\" and list its fields under \"properties\". Fix it and save."
        case .badField(let field): return "The field \"\(field)\" needs a \"type\" of \(fieldTypes). Fix it and save."
        case .unsupportedType(let field, let type): return "The field \"\(field)\" is \"\(type)\", which Tandem can't check. Use \(fieldTypes), then save."
        case .unsupportedKeyword(let keyword): return "It uses \"\(keyword)\", which Tandem can't check. Remove it and save."
        case .badValue(let field, let keyword): return "The \"\(keyword)\" on the field \"\(field)\" isn't a value Tandem can use. Fix it and save."
        case .badRequired: return "Its \"required\" must list only fields that are under \"properties\". Fix it and save."
        case .badEndpoint: return "Its \"endpoint\" must be an http or https address, or a path on your Tandem server. Fix it and save."
        case .badMethod: return "Its \"method\" must be \"GET\" or \"POST\". Fix it and save."
        case .badConfirmation: return "Its \"confirmation\" must be \"none\" or \"required\". Fix it and save."
        case .badTimeout: return "Its \"timeout_s\" must be a number from 1 to 300. Fix it and save."
        case .badEnabled: return "Its \"enabled\" must be true or false. Fix it and save."
        case .badJSONFields: return "Its \"json_fields\" must map each text field to its own request field, and only works with \"POST\". Fix it and save."
        case .badSendsTo: return "Its \"sends_to\" must list text fields once each, and only works with \"POST\". Fix it and save."
        case .badVerbs: return "Its \"verbs\" must list one to eight different lowercase words, and only a tool that changes something can have them. Fix it and save."
        case .duplicateName(let name): return "Another file already uses the name \"\(name)\". Rename one of them and save."
        case .reservedName(let name): return "The name \"\(name)\" belongs to a tool built into Tandem. Rename it and save."
        case .other: return "Check the file and save it again."
        }
    }

    static func tab(for toolID: String) -> SettingsTab? {
        switch toolID {
        case NativeWebTools.searchToolID: return .search
        case NativeImageTools.toolID: return .image
        default: return nil
        }
    }

    static func buttonTitle(for toolID: String) -> String? {
        switch tab(for: toolID) {
        case .search: return openSearch
        case .image: return openImage
        default: return nil
        }
    }

    static func listed(
        declarations: [NativeToolDeclaration], serverConnected: Bool,
        imageConfigured: Bool, searchConfigured: Bool
    ) -> [NativeChatToolDescriptor] {
        let hidden = Set(declarations.filter { $0.needsAPIBase && !serverConnected }.map(\.id))
        return NativeChatToolCatalog.tools(
            veraAPIConfigured: serverConnected, imageConfigured: imageConfigured,
            searchConfigured: searchConfigured, declarations: declarations)
            .filter { !hidden.contains($0.id) }
    }
}

struct NativeToolEditor: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore

    private var catalog: [NativeChatToolDescriptor] {
        SettingsToolsCopy.listed(
            declarations: config.capabilityTools.declarations,
            serverConnected: config.veraAPIBase != nil,
            imageConfigured: config.imageBase != nil,
            searchConfigured: config.searchBase != nil)
    }
    private var failures: [NativeToolDeclarationFailure] { config.capabilityTools.failures }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if catalog.isEmpty {
                Label(SettingsToolsCopy.empty, systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 12, weight: .medium))
            }
            ForEach(catalog) { tool in
                if tool.available {
                    Toggle(isOn: Binding(
                        get: { config.nativeSettings.enabledToolIDs.contains(tool.id) },
                        set: { config.setNativeTool(tool.id, enabled: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                            if !tool.summary.isEmpty {
                                Text(tool.summary).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    if config.nativeSettings.enabledToolIDs.contains(tool.id), let access = store.toolAccess(tool.id) {
                        NativeToolAccessRow(access: access)
                    }
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                            Text(tool.setup).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if let tab = SettingsToolsCopy.tab(for: tool.id), let title = SettingsToolsCopy.buttonTitle(for: tool.id) {
                            Button(title) { store.settingsTab = tab }
                        }
                    }
                }
            }
            ForEach(failures) { failure in
                Text(SettingsToolsCopy.failureLine(failure))
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                Text(SettingsToolsCopy.services)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Button(SettingsToolsCopy.openIntegrations) {
                    store.section = .integrations
                    NSApp.keyWindow?.performClose(nil)
                }
            }
        }
    }
}

struct MemoryEndpointEditor: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        HStack(spacing: 6) {
            TextField("Base URL", text: config.memoryEndpointBinding(\.baseURL), prompt: Text("http://my-memory-host:11434/v1"))
                .autocorrectionDisabled()
            if let env = config.memoryEndpointEnvironmentOverride {
                InfoTip(text: "Set by \(env) in the environment. The environment value wins; change it there.")
            } else {
                InfoTip(text: "The OpenAI-compatible endpoint that serves your embeddings, extraction and rerank models. Switching chat profiles never changes it.")
            }
        }
        SecureField("API key", text: $config.memoryEndpointAPIKey, prompt: Text("Optional"))
        if let credentialError = config.credentialError {
            Text(credentialError).font(.system(size: 11)).foregroundStyle(.orange)
        }
        HStack(spacing: 10) {
            Button("Test memory endpoint") { test() }.disabled(testing)
            if testing { ProgressView().controlSize(.small) }
            if let testResult {
                Text(testResult).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        Text(statusLine)
            .font(.system(size: 11))
            .foregroundStyle(statusColor)
            .accessibilityLabel("Memory endpoint status: \(statusLine)")
        if let progress = store.memoryIndexingProgress {
            HStack(spacing: 8) {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear).frame(width: 160)
                Text(progress.label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
        Color.clear.frame(height: 0).task { await store.probeMemoryEndpoint() }
    }

    private var statusLine: String {
        if !config.nativeSettings.memoryEndpoint.isConfigured && config.memoryEndpointEnvironmentOverride == nil {
            return NativeMemoryEndpointStatus.notConfigured.label
        }
        return store.memoryEndpointStatus.label
    }

    private var statusColor: Color {
        switch store.memoryEndpointStatus {
        case .unreachable: .orange
        case .connected: .green
        default: Theme.textSecondary
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            config.loadMemoryCredentialIfNeeded(retry: true)
            guard let resolved = config.memoryEndpointResolved else {
                testResult = "Enter an HTTP or HTTPS memory endpoint ending in /v1."
                return
            }
            do {
                let models = try await ConnectionTest.models(base: resolved.baseURL.absoluteString, apiKey: resolved.apiKey ?? "")
                config.cacheMemoryModels(models)
                try config.save()
                store.updateNativeMemory(settings: config.nativeSettings.memory, service: config.nativeMemoryService)
                _ = await store.probeMemoryEndpoint()
                testResult = models.isEmpty ? "Reachable, but it lists no models." : "Found \(models.count) model\(models.count == 1 ? "" : "s")."
            } catch {
                testResult = error.localizedDescription
                _ = await store.probeMemoryEndpoint()
            }
        }
    }
}

struct NativeMemorySettingsTab: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @State private var saved = false

    private func live<Value>(_ keyPath: WritableKeyPath<NativeMemorySettings, Value>) -> Binding<Value> {
        let binding = config.liveMemoryBinding(keyPath, store: store)
        return Binding(get: { binding.wrappedValue }, set: { value in
            saved = false
            binding.wrappedValue = value
        })
    }

    var body: some View {
        Form {
            Section("Local memory") {
                if let notice = store.memorySettingsNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Toggle("Use approved memory in native chat", isOn: live(\.enabled))
                Text("Approved memory is stored only on this Mac. Tandem only recalls approved items, and every model-suggested change waits for your review.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Toggle("Search past chats", isOn: live(\.searchPastChats))
                Text("When enabled, Tandem may use completed local chats to suggest memory changes. Chats are not copied into memory.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Toggle("Generate proposals from completed chats", isOn: live(\.generateFromChats))
                Text("Suggestions appear in the Memory review queue. They never become approved memory on their own.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Picker("Sensitive information", selection: live(\.sensitiveHandling)) {
                    ForEach(NativeMemorySensitiveHandling.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                ForEach(NativeMemorySensitiveHandling.allCases, id: \.self) { option in
                    Text("\(option.title): \(option.caption)")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            Section("Memory endpoint") {
                MemoryEndpointEditor()
            }
            Section("Memory models") {
                Text("Generating proposals and embeddings sends the current turn and your existing memories to the memory endpoint above, never to the chat endpoint.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                DiscoveredModelPicker(title: "Embeddings model",
                                      models: config.nativeSettings.memoryEndpoint.discoveredModels,
                                      selection: config.memoryStringBinding(\.embeddingsModel))
                Text("Leave embeddings unset to search approved memory locally. An embeddings model on the memory endpoint enables semantic recall. Model-suggested changes still require an extraction model and your review.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                if let status = store.memoryVectorStatus {
                    Label(status.label, systemImage: status.complete ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                DiscoveredModelPicker(title: "Extraction model",
                                      models: config.nativeSettings.memoryEndpoint.discoveredModels,
                                      selection: config.memoryStringBinding(\.extractionModel))
                Text("The extraction model only creates reviewable proposals from bounded completed turns and natural-language requests in Memory.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                DiscoveredModelPicker(title: "Rerank model",
                                      models: config.nativeSettings.memoryEndpoint.discoveredModels,
                                      selection: config.memoryEndpointBinding(\.rerankModel))
                Text("Optional. A reranker on the memory endpoint can reorder recalled memory. Leave it unset to skip rerank calls.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Section("Recall scope") {
                Picker("Memory bank", selection: config.memoryStringBinding(\.bankScope)) {
                    Text("All banks").tag("all")
                    Text("Personal").tag("personal")
                    Text("Work").tag("work")
                    Text("Family").tag("family")
                    Text("Projects").tag("projects")
                }
                Text("Tandem gathers up to \(NativeMemoryRetrievalLimits.lexicalCandidates) matches by words and \(NativeMemoryRetrievalLimits.semanticCandidates) by meaning, merges them, reranks the top \(NativeMemoryRetrievalLimits.rerankCount) when a rerank model is set, and keeps at most \(NativeMemoryRetrievalLimits.itemLimit) items within about \(NativeMemoryRetrievalLimits.tokenBudget) tokens. Expired, suppressed, deleted, pending, and unrelated items are excluded.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Section {
                HStack {
                    Text(saved ? "Saved" : (store.memoryIndexingProgress?.label ?? store.memoryServiceState.label))
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Save memory settings") {
                        do {
                            try config.save()
                            store.updateNativeMemory(
                                settings: config.nativeSettings.memory,
                                service: config.nativeMemoryService)
                            store.memorySettingsNotice = nil
                            saved = true
                        } catch {
                            saved = false
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ImageTab: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @State private var status: String?

    var body: some View {
        Form {
            Section("Image generation") {
                ConfigField(label: "ComfyUI URL", key: NativeImageTools.configKey, placeholder: "http://my-comfyui-host:8188",
                            tip: "The ComfyUI server that renders images. Leave it empty to turn image generation off.")
                InlineTest(title: "Test ComfyUI") {
                    try await ConnectionTest.http(base: config[NativeImageTools.configKey], path: "system_stats", label: "ComfyUI")
                }
                Text("Images render with the Qwen Image 2.1 graph that ships with the app. The server needs that model's diffusion, text encoder and VAE files installed.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Section {
                HStack(spacing: 10) {
                    if let status {
                        Text(status).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Save") { save() }.keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        let configured = NativeImageTools.base(from: config[NativeImageTools.configKey]) != nil
        if configured, !config.nativeSettings.enabledToolIDs.contains(NativeImageTools.toolID) {
            config.setNativeTool(NativeImageTools.toolID, enabled: true)
        }
        do { try config.save() } catch {
            status = "Save failed: \(error.localizedDescription)"
            return
        }
        store.updateNativeToolConsent(config.nativeSettings.enabledToolIDs)
        status = configured ? "Saved. Ask for an image in any chat." : "Saved. Image generation is off."
    }
}

struct SearchTab: View {
    static let savedOn = "Saved. Ask to search the web or start research in any chat."
    static let pagesNote = "Searches run from this Mac against your own search server. Research also reads the pages it finds."

    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @State private var status: String?

    init(status: String? = nil) {
        _status = State(initialValue: status)
    }

    var body: some View {
        Form {
            Section("Web search") {
                ConfigField(label: "SearXNG URL", key: NativeWebSearch.configKey, placeholder: "http://my-search-host:8088",
                            tip: "The SearXNG instance that answers web searches. Leave it empty to turn web search and research off.")
                InlineTest(title: "Test search") {
                    try await ConnectionTest.search(base: config[NativeWebSearch.configKey])
                }
                Text(Self.pagesNote)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Section {
                HStack(spacing: 10) {
                    if let status {
                        Text(status).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Save") { save() }.keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        let configured = NativeWebSearch.base(from: config[NativeWebSearch.configKey]) != nil
        if configured {
            for id in [NativeWebTools.searchToolID, NativeWebTools.fetchToolID, NativeWebTools.researchToolID]
                where !config.nativeSettings.enabledToolIDs.contains(id) {
                config.setNativeTool(id, enabled: true)
            }
        }
        do { try config.save() } catch {
            status = "Save failed: \(error.localizedDescription)"
            return
        }
        store.updateNativeToolConsent(config.nativeSettings.enabledToolIDs)
        status = configured ? Self.savedOn : "Saved. Web search is off."
    }
}

struct ServicesTab: View {
    var body: some View {
        Form {
            EngineSection()
            SaveSection()
        }
        .formStyle(.grouped)
    }
}

private struct EngineSection: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var engine: EngineManager

    private var mode: EngineMode {
        if let m = EngineMode(rawValue: config["engine_mode"]) { return m }
        return config["vera_api_base"].isEmpty ? .off : .remote
    }

    private var modeBinding: Binding<EngineMode> {
        Binding(get: { mode }, set: { new in
            Task {
                await engine.apply(mode: new)
                config["engine_mode"] = engine.currentMode.rawValue
            }
        })
    }

    var body: some View {
        Section("Engine") {
            Picker("Runs", selection: modeBinding) {
                Text("Remote URL").tag(EngineMode.remote)
                Text("On this Mac").tag(EngineMode.local)
                Text("Off").tag(EngineMode.off)
            }
            .pickerStyle(.segmented)

            switch mode {
            case .remote: remoteBody
            case .local: localBody
            case .off: offBody
            }
            if mode != .local, let message = phaseMessage {
                HStack {
                    if engine.busy { ProgressView().controlSize(.small) }
                    Text(message).font(.system(size: 12)).foregroundStyle(phaseColor)
                }
            }
        }
    }

    private var remoteBody: some View {
        Group {
            ConfigField(label: "Base URL", key: "vera_api_base", placeholder: "http://my-api-host:8089")
            InlineTest(title: "Test vera-api") {
                try await ConnectionTest.http(base: config["vera_api_base"],
                                              path: "health/services", label: "vera-api")
            }
        }
    }

    private var offBody: some View {
        Text("vera-api is turned off. Pulse, veins, and the ambient features stay in their unconfigured state.")
            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder private var localBody: some View {
        LabeledContent("Version", value: engine.installedVersion ?? "Not installed")
        LabeledContent("Status", value: statusText)
        LabeledContent("Data", value: engine.dataPathDisplay)
        HStack(spacing: 6) {
            TextField("Port", text: config.binding("engine_port"), prompt: Text("8089"))
                .autocorrectionDisabled().frame(width: 120)
            InfoTip(text: "The loopback port the engine binds. Change it only if 8089 is taken.")
            Spacer(minLength: 0)
        }
        HStack(spacing: 10) {
            if engine.running {
                Button("Stop") { Task { await engine.stopEngine() } }.disabled(engine.busy)
            } else {
                Button(engine.busy ? "Starting…" : "Start") { Task { await engine.startEngine() } }
                    .disabled(engine.busy)
            }
            if engine.busy { ProgressView().controlSize(.small) }
            if let msg = phaseMessage {
                Text(msg).font(.system(size: 12)).foregroundStyle(phaseColor)
            }
            Spacer(minLength: 0)
        }
        if let detail = engine.runDetail {
            Label(detail, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
        Text("Log: \(engine.logPathDisplay)")
            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        HStack(spacing: 10) {
            Text("Effective base").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Text("http://127.0.0.1:\(engine.port)")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        MaintenanceControls()
    }

    private var statusText: String {
        engine.running ? "Running" : "Stopped"
    }

    private var phaseMessage: String? {
        switch engine.phase {
        case .idle, .healthy: return nil
        case .resolving: return "Finding the release…"
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying checksum…"
        case .unpacking: return "Installing…"
        case .launching: return "Starting the engine…"
        case .failed(let m): return m
        }
    }

    private var phaseColor: Color {
        if case .failed = engine.phase { return .red }
        return Theme.textSecondary
    }
}

private struct MaintenanceControls: View {
    @EnvironmentObject var engine: EngineManager
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Button("Remove engine files") { engine.removeEngineFiles() }.disabled(engine.busy)
            Button("Delete data", role: .destructive) { confirmDelete = true }
            Spacer(minLength: 0)
        }
        .confirmationDialog("Delete the engine's data directory?", isPresented: $confirmDelete) {
            Button("Delete data", role: .destructive) { engine.deleteData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(engine.dataPathDisplay) (Pulse history, memory, veins). This cannot be undone.")
        }
    }
}

struct IdentityTab: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @State private var changingAppearance = false
    @EnvironmentObject var companion: CompanionCoordinator
    var body: some View {
        Form {
            Section("Identity") {
                ConfigField(label: "Assistant's name", key: "assistant_name", placeholder: "Name",
                            tip: "How your assistant is named in chat and in work it does on its own. Tandem is the app; this is the assistant.")
                ConfigField(label: "Your name", key: "owner_name", placeholder: "how your assistant greets you",
                            tip: "Drives the greeting and the sidebar chip. Leave empty for a nameless greeting.")
            }
            Section("Companion") {
                HStack(spacing: 14) {
                    CompanionAvatar(size: 36)
                    Text("\(config.companionAppearance.shape.displayName) in \(config.companionAppearance.color.displayName)")
                    Spacer()
                    Button("Change appearance") { changingAppearance = true }
                }
            }
            Section("Appearance") {
                Picker("Appearance", selection: config.binding("appearance")) {
                    Text("System").tag("")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("Menu bar") {
                Toggle("Keep running in the menu bar", isOn: Binding(
                    get: { store.keepsRunningInMenuBar },
                    set: { value in
                        config.setMenuBarKeepRunning(value)
                        store.menuBarPreference = value
                        try? config.save()
                    }))
                .help("Closing the window leaves Tandem in the menu bar so scheduled work keeps running. It turns on by itself once you create a schedule.")
            }
            Section("Quick ask") {
                LabeledContent("Shortcut") {
                    HStack(spacing: 10) {
                        CompanionShortcutRecorder()
                        Button("Reset to default") { apply(nil) }
                            .disabled(config.companionShortcut == .default)
                    }
                }
                if let problem = config.companionShortcutProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            SaveSection()
        }
        .formStyle(.grouped)
        .sheet(isPresented: $changingAppearance) {
            CompanionAppearancePicker(config: config, store: ConfigCompanionAppearanceStore(config: config), chat: store)
        }
    }

    private func apply(_ shortcut: CompanionShortcut?) {
        companion.apply(shortcut)
    }
}

struct CompanionShortcutRecorder: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var companion: CompanionCoordinator
    @State private var recording = false
    @State private var rejected = false
    @State private var monitor: Any?
    @State private var resignObserver: NSObjectProtocol?
    @State private var host = RecorderWindowBox()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(action: toggle) {
                Text(recording ? "Press a shortcut" : config.companionShortcut.symbols)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(recording ? Theme.accent : Theme.textPrimary)
                    .frame(minWidth: 96)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().strokeBorder(recording ? Theme.accent : Theme.hairline, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Press it from any app to open a small message box over the companion thread. Escape hides it.")
            .accessibilityLabel("Quick ask shortcut")
            .accessibilityValue(recording ? "Press a shortcut" : config.companionShortcut.displayName)
            .accessibilityHint("Click, then press the keys you want.")
            if recording && rejected {
                Text("Use at least one of Control, Option or Command with a key.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
        .background(WorkflowCanvasWindowReader { [host] window in host.window = window })
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        stop()
        guard let window = host.window ?? NSApp.keyWindow else { return }
        host.window = window
        recording = true
        rejected = false
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { stop() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window else { return event }
            if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty {
                stop()
                return nil
            }
            guard let shortcut = CompanionShortcut(event: event) else {
                rejected = true
                return nil
            }
            companion.apply(shortcut)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        recording = false
        rejected = false
    }
}

@MainActor
private final class RecorderWindowBox {
    weak var window: NSWindow?
}

struct AboutTab: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var updates: UpdateChecker
    @State private var serverVersion: String?
    @State private var showingGallery = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LiveTandemLogo(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tandem").font(.system(size: 17, weight: .semibold))
                        Text("Version \(AppVersion.current)")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Button("Logo motion gallery") { showingGallery = true }
                }
                .padding(.vertical, 4)
            }
            Section("Versions") {
                LabeledContent("App", value: AppVersion.current)
                LabeledContent("vera-api", value: serverVersion ?? "N/A")
                if let server = serverVersion,
                   Semver.minor(server) != Semver.minor(AppVersion.current) {
                    Label("App and server minor versions differ. Update the older side when convenient.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            Section("Updates") {
                if AppVersion.isSelfBuilt {
                    Text("Built from source. Update with git pull.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    HStack(spacing: 10) {
                        Button(updates.checking ? "Checking…" : "Check for Updates") {
                            Task { await updates.check(manual: true) }
                        }
                        .disabled(updates.checking)
                        if let release = updates.available {
                            Button("Install \(release.tag_name)") { Task { await updates.install() } }
                                .disabled(updates.installing)
                        }
                        if let result = updates.lastResult {
                            Text(result).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Section("Project") {
                Button("github.com/\(UpdateChecker.repo)") {
                    openExternal("https://github.com/\(UpdateChecker.repo)")
                }
                .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .task { await loadServerVersion() }
        .sheet(isPresented: $showingGallery) {
            VStack(spacing: 0) {
                TandemMotionGalleryView()
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showingGallery = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(width: 760, height: 620)
        }
    }

    private func loadServerVersion() async {
        let base = config["vera_api_base"].trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, let url = URL(string: "\(base)/version") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            serverVersion = obj["version"] as? String
        }
    }
}

// MARK: - Building blocks

/// One editable config.json field. Env-overridden keys stay editable (edits land in the
/// file as usual) but an InfoTip explains that the environment value wins at resolution.
private struct ConfigField: View {
    @EnvironmentObject var config: ConfigStore
    let label: String
    let key: String
    var secure = false
    var placeholder = ""
    var tip = ""

    var body: some View {
        HStack(spacing: 6) {
            if secure {
                SecureField(label, text: config.binding(key), prompt: Text(placeholder))
            } else {
                TextField(label, text: config.binding(key), prompt: Text(placeholder))
                    .autocorrectionDisabled()
            }
            if let env = config.envOverride(key) {
                InfoTip(text: "Set by \(env) in the environment. The environment value wins; change it there.")
            } else if !tip.isEmpty {
                InfoTip(text: tip)
            }
        }
    }
}

/// A test button with its result inline (never a silent pass/fail).
private struct InlineTest: View {
    let title: String
    let run: () async throws -> String
    private enum Phase: Equatable { case idle, running, ok(String), fail(String) }
    @State private var phase: Phase = .idle

    var body: some View {
        HStack(spacing: 10) {
            Button(title) {
                phase = .running
                Task {
                    do { phase = .ok(try await run()) }
                    catch { phase = .fail(error.localizedDescription) }
                }
            }
            .disabled(phase == .running)
            switch phase {
            case .idle: EmptyView()
            case .running: ProgressView().controlSize(.small)
            case .ok(let m):
                Label(m, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.green)
            case .fail(let m):
                Label(m, systemImage: "xmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct SaveSection: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @State private var status: String?

    var body: some View {
        Section {
            HStack(spacing: 10) {
                if let status {
                    Text(status).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Save") { save() }.keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private func save() {
        do { try config.save() } catch {
            status = "Save failed: \(error.localizedDescription)"
            return
        }
        guard let resolved = config.nativeResolved else {
            store.reloadCapabilityTools(config.capabilityTools.declarations)
            status = ModelSettingsCopy.savedWithoutModel
            return
        }
        store.adoptNative(
            resolved,
            systemPrompt: config.nativeSettings.systemPrompt,
            activePersonaID: config.nativeSettings.activePersonaID,
            ownerName: config.ownerName,
            companion: CompanionSubject(config.suppliedAssistantName),
            enabledToolIDs: config.nativeSettings.enabledToolIDs,
            capabilityOverrides: config.nativeSettings.capabilityOverrides,
            visionBridge: config.visionBridgeResolved,
            memorySettings: config.nativeSettings.memory,
            memoryService: config.nativeMemoryService,
            rules: config.nativeSettings.rules,
            capabilityDeclarations: config.capabilityTools.declarations)
        status = "Saved"
    }
}

struct NativeToolAccessRow: View {
    let access: NativeToolAccess
    @State private var refresh = 0

    var body: some View {
        let state = access.state()
        Group {
            if let status = access.status(state) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    Text(status.line).font(.system(size: 12))
                    Spacer()
                    Button(status.action) {
                        if state == .notAsked {
                            Task {
                                _ = await access.request()
                                refresh += 1
                            }
                        } else if let pane = access.settingsPane {
                            NSWorkspace.shared.open(pane)
                        }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .id(refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }
}
