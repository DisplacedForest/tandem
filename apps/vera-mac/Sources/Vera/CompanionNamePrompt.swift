import SwiftUI

enum CompanionNameAsk: String, Identifiable {
    case launch
    case firstOpen

    var id: String { rawValue }

    static let dismissedKey = "companion_name_prompt_dismissed"
    static let asksExistingInstalls = true

    static func atLaunch(name: String?, settingUp: Bool, dismissed: Bool) -> Bool {
        asksExistingInstalls && CompanionSubject(name).name == nil && !settingUp && !dismissed
    }

    static func onFirstOpen(name: String?, dismissed: Bool) -> Bool {
        CompanionSubject(name).name == nil && !dismissed
    }
}

@MainActor
extension ChatStore {
    var companionNamePromptDismissed: Bool {
        companionDefaults.bool(forKey: CompanionNameAsk.dismissedKey)
    }

    func askForCompanionNameAtLaunch(settingUp: Bool) {
        guard asksForCompanionName, companionNameAsk == nil,
              CompanionNameAsk.atLaunch(name: companionName, settingUp: settingUp, dismissed: companionNamePromptDismissed) else { return }
        companionNameAsk = .launch
    }

    func finishCompanionNameAsk(named: Bool) {
        let reason = companionNameAsk
        companionNameAsk = nil
        if !named { companionDefaults.set(true, forKey: CompanionNameAsk.dismissedKey) }
        if reason == .firstOpen { prepareCompanionOpening() }
    }
}

struct CompanionNamePrompt: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var config: ConfigStore
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name your companion").font(.system(size: 17, weight: .semibold))
            Text("Pick any name. You can change it later in Settings.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .accessibilityLabel("Companion name")
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Not now") { store.finishCompanionNameAsk(named: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        if let failure = DotProfileCopy.saveName(trimmed, config: config, store: store) {
            error = failure
            return
        }
        store.finishCompanionNameAsk(named: true)
    }
}

struct CompanionEnvironment: ViewModifier {
    @ObservedObject var store: ChatStore
    @ObservedObject var config: ConfigStore
    @ObservedObject var presence: CompanionPresence

    func body(content: Content) -> some View {
        content
            .environment(\.companionName, store.companionDisplayName)
            .environment(\.companionAppearance, config.companionAppearance)
            .environment(\.companionLiveState, presence.state)
    }
}
