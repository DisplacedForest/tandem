import SwiftUI

struct DotSettingsView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var goal = ""
    @State private var selected: Set<String> = []
    @State private var rules: [NativeActionClass: NativeRuleChoice] = [:]
    @State private var revokedPrefixes: Set<String> = []
    @State private var options: [NativeDotServiceOption] = []
    @State private var problem: String?
    @State private var confirmingReset = false
    @State private var removal = NativeDotRemovalSummary()

    private var displayName: String? {
        CompanionSentence.savedName(name) ?? store.companionDisplayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompanionNamedText(template: CompanionSentence.placeholder).font(.system(size: 17, weight: .semibold))
                .environment(\.companionName, displayName).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DotProfileForm(name: $name, goal: $goal, selected: $selected, rules: $rules, revokedPrefixes: $revokedPrefixes, options: options)
                    stateSection
                    startOverSection
                }
                .padding(.trailing, 6)
            }
            .frame(minHeight: 300, maxHeight: 520)
            if let failed = store.companionConfigurationError, failed.lead == CompanionErrorCopy.resetLead {
                Label { CompanionLineText(line: failed.line) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.top, 10)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.top, 10)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 520)
        .onAppear(perform: load)
        .confirmationDialog("Start over with \(store.companion.inline)?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                if store.resetDot() { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removal.sentence)
        }
    }

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scheduled work")
                Spacer()
                Text(store.isDotPaused ? "Paused" : "Runs on schedule").foregroundStyle(Theme.textSecondary)
                Button(store.isDotPaused ? "Resume" : "Pause") {
                    store.setDotState(store.isDotPaused ? .active : .paused)
                }
            }
            Text(DotProfileCopy.pausedNote).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
    }

    private var startOverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.bottom, 6)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start over")
                    CompanionNamedText(template: DotProfileCopy.startOver)
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Reset", role: .destructive) {
                    removal = store.dotRemovalSummary()
                    confirmingReset = true
                }
                .help("Clear the conversation, its memories, its schedules and the goal")
            }
        }
    }

    private func load() {
        name = config["assistant_name"]
        goal = store.dotProfile.goal
        options = store.dotServiceOptions()
        selected = store.dotSelectedServices(options)
        rules = DotProfileCopy.draftRules(store)
        revokedPrefixes = []
    }

    private func save() {
        if let failure = DotProfileCopy.saveName(name, config: config, store: store) {
            problem = failure
            return
        }
        let connected = store.dotConnectedToolIDs(selected: selected, options: options)
        let cleanGoal = goal
        store.saveDotProfile {
            $0.goal = cleanGoal
            $0.connectedToolIDs = connected
            $0.setupCompleted = true
        }
        DotProfileCopy.commitRules(rules, revokedPrefixes: revokedPrefixes, store: store)
        dismiss()
    }
}
