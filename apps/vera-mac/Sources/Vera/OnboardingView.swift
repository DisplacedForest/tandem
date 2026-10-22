import SwiftUI

struct OnboardingSheet: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @State private var step = 0
    @State private var loaded = false
    @State private var error: String?

    private let steps = ["Endpoint", "Model", "Memory", "Pulse"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                VeraMark(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up Tandem").font(.system(size: 20, weight: .semibold))
                    Text("Connect a model. Memory and Pulse are optional and can be set up later in Settings.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 5) {
                        Image(systemName: index < step ? "checkmark.circle.fill" : "\(index + 1).circle.fill")
                        Text(title)
                    }
                    .font(.system(size: 11, weight: index == step ? .semibold : .regular))
                    .foregroundStyle(index <= step ? Theme.accent : Theme.textSecondary)
                    if index < steps.count - 1 { Divider().frame(width: 18, height: 1) }
                }
            }

            ScrollView {
                Group {
                    switch step {
                    case 0:
                        IdentityOnboardingEditor()
                        Divider().padding(.vertical, 6)
                        NativeEndpointEditor()
                    case 1: NativeModelEditor()
                    case 2: NativeMemoryOnboardingEditor()
                    default: PulseOnboardingEditor()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let error {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.red)
            }

            HStack {
                Button("Skip for now") { config.skipOnboarding() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Spacer()
                if step > 0 { Button("Back") { move(to: step - 1) } }
                if step >= 2, step < steps.count - 1 {
                    Button("Skip this step") { move(to: step + 1) }
                }
                Button(step == steps.count - 1 ? "Finish" : "Continue") { advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 620)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            step = min(max(config.nativeSettings.onboardingStep, 0), steps.count - 1)
            if config.nativeSettings.onboardingState != .inProgress {
                config.updateOnboarding(step: step)
            }
        }
    }

    private func advance() {
        error = nil
        switch step {
        case 0:
            guard let profile = config.activeNativeProfile,
                  let url = URL(string: profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme == "http" || url.scheme == "https",
                  url.lastPathComponent == "v1" else {
                error = "Enter an HTTP or HTTPS model endpoint ending in /v1."
                return
            }
        case 1:
            guard config.activeNativeProfile?.selectedModel.isEmpty == false else {
                error = "Choose one of the discovered model identifiers."
                return
            }
        case 2:
            break
        default:
            finish()
            return
        }
        move(to: step + 1)
    }

    private func move(to value: Int) {
        step = value
        config.updateOnboarding(step: value)
    }

    private func finish() {
        do { try config.save() } catch let saveError {
            error = "Tandem could not save these settings: \(saveError.localizedDescription)"
            return
        }
        guard let resolved = config.nativeResolved else {
            error = "Choose a valid endpoint and model before finishing."
            return
        }
        store.adoptNative(
            resolved,
            systemPrompt: config.nativeSettings.systemPrompt,
            activePersonaID: config.nativeSettings.activePersonaID,
            ownerName: config.ownerName,
            assistantName: config.assistantName,
            enabledToolIDs: config.nativeSettings.enabledToolIDs,
            capabilityOverrides: config.nativeSettings.capabilityOverrides,
            visionBridge: config.visionBridgeResolved,
            memorySettings: config.nativeSettings.memory,
            memoryService: config.nativeMemoryService,
            rules: config.nativeSettings.rules,
            capabilityDeclarations: config.capabilityTools.declarations)
        config.completeOnboarding()
    }
}

struct NativeMemoryOnboardingEditor: View {
    @EnvironmentObject var config: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Turn on local memory", isOn: config.memoryBoolBinding(\.enabled))
            Text("Memory is optional and starts off after upgrade. Approved facts stay on this Mac. Suggestions, corrections, merges, and deletion all require your review.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if config.nativeSettings.memory.enabled {
                Text("Memory has its own endpoint so switching chat models never moves it. Leave it empty to search approved memory locally.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                MemoryEndpointEditor()
                DiscoveredModelPicker(title: "Embeddings model",
                                      models: config.nativeSettings.memoryEndpoint.discoveredModels,
                                      selection: config.memoryStringBinding(\.embeddingsModel))
                DiscoveredModelPicker(title: "Extraction model",
                                      models: config.nativeSettings.memoryEndpoint.discoveredModels,
                                      selection: config.memoryStringBinding(\.extractionModel))
                Toggle("Generate reviewable suggestions from completed chats", isOn: config.memoryBoolBinding(\.generateFromChats))
                Text("Episodic facts need an absolute expiry date and stop being recalled when they expire. A daily groom removes them after that date passes, with every removal recorded in the audit trail.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct PulseOnboardingEditor: View {
    @EnvironmentObject var config: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pulse is Vera's daily briefing and ambient watches. It runs on a separate vera-api service; leave this empty if you don't run one.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            LabeledContent("Service URL") {
                TextField("http://vera-host.example:8089", text: config.binding("vera_api_base"))
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled().frame(maxWidth: 360)
            }
            Text("You can add or change this later in Settings, Services.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
    }
}

struct IdentityOnboardingEditor: View {
    @EnvironmentObject var config: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tandem is the app. The assistant inside it is yours to name.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            LabeledContent("Assistant's name") {
                TextField(ConfigStore.defaultAssistantName, text: config.binding("assistant_name"))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            LabeledContent("Your name") {
                TextField("Optional", text: config.binding("owner_name"))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
        }
    }
}
