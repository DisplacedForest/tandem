import SwiftUI

enum CompanionThreadPanelMetrics {
    static let width = OngoingWorkMetrics.panelWidth
    static let minimumWindowWidth = OngoingWorkMetrics.minimumWindowWidth
}

enum CompanionPanelPlacement: Equatable, Sendable {
    case beside, header, none

    static func decide(isCompanionThread: Bool, windowWidth: CGFloat, canvasShowing: Bool) -> CompanionPanelPlacement {
        guard isCompanionThread else { return .none }
        if canvasShowing || windowWidth < CompanionThreadPanelMetrics.minimumWindowWidth { return .header }
        return .beside
    }
}

struct CompanionThreadPanel: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore
    @Environment(\.renderSafe) private var renderSafe
    @Environment(\.companionLiveState) private var liveState
    var fixed: CompanionOverviewModel? = nil
    var onClose: (() -> Void)? = nil
    @State private var model: CompanionOverviewModel
    @State private var selectedID: String?
    @State private var showingAllActivity = false
    @State private var editingProfile = false
    @State private var editingAppearance = false

    init(fixed: CompanionOverviewModel? = nil, selectedID: String? = nil, onClose: (() -> Void)? = nil) {
        self.fixed = fixed
        self.onClose = onClose
        _selectedID = State(initialValue: selectedID)
        _model = State(initialValue: fixed ?? CompanionOverviewModel(name: "", goal: "", services: "", rules: "", paused: false, activity: [], outputs: []))
    }

    private var current: CompanionOverviewModel { fixed ?? model }

    private var stateLine: String {
        if current.paused { return "Paused" }
        return liveState.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onClose {
                HStack {
                    Spacer()
                    Button("Done", action: onClose).keyboardShortcut(.cancelAction).accessibilityLabel("Close \(current.name)'s panel")
                }
                .padding(.horizontal, 20).padding(.top, 16)
            }
            if renderSafe {
                content.padding(20)
                Spacer(minLength: 0)
            } else {
                ScrollView { content.padding(20) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(Theme.conversationBackground)
        .onAppear { refresh() }
        .onReceive(store.objectWillChange.debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)) { _ in refresh() }
        .sheet(isPresented: $editingProfile) {
            DotSettingsView().environmentObject(store).environmentObject(config)
        }
        .sheet(isPresented: $editingAppearance) {
            CompanionAppearancePicker(config: config, store: ConfigCompanionAppearanceStore(config: config), chat: store)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(current.name)'s panel")
    }

    private func refresh() {
        guard fixed == nil else { return }
        let next = store.companionOverviewModel()
        if next != model { model = next }
        if let id = selectedID, next.selected(id) == nil { selectedID = nil }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            identity
            thisMac
            activity
            rules
            outputs
        }
    }

    private var identity: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    CompanionAvatar(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(current.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.warmTextPrimary)
                        HStack(spacing: 6) {
                            Circle().fill(current.paused ? Theme.warmTextSecondary : Theme.statusGreen).frame(width: 7, height: 7)
                            Text(stateLine).font(.system(size: 13)).foregroundStyle(Theme.warmTextSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(current.name), \(stateLine)")
                Text(current.goal.isEmpty ? CompanionOverviewModel.noGoal : current.goal)
                    .font(.system(size: 13)).foregroundStyle(current.goal.isEmpty ? Theme.warmTextSecondary : Theme.warmTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        store.setDotState(current.paused ? .active : .paused)
                    } label: {
                        Label(current.paused ? "Resume" : "Pause", systemImage: current.paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(DotProfileCopy.pausedNote)
                    .accessibilityLabel(CompanionOverviewModel.pauseTitle(name: current.name, paused: current.paused))
                    Button("Appearance") { editingAppearance = true }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.sage)
                        .help("Change \(current.name)'s name, shape and color")
                    Spacer(minLength: 0)
                    Button { editingProfile = true } label: {
                        Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.warmTextSecondary)
                            .frame(width: 26, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(current.name)'s goal, services, rules and start over")
                    .accessibilityLabel("Settings for \(current.name)")
                }
                if current.paused {
                    Text(DotProfileCopy.pausedNote).font(.system(size: 12)).foregroundStyle(Theme.warmTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var thisMac: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label(CompanionOverviewModel.thisMac, systemImage: "desktopcomputer")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warmTextPrimary)
                Text(current.services).font(.system(size: 13)).foregroundStyle(Theme.warmTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !current.rules.isEmpty {
                    Text(current.rules).font(.system(size: 12)).foregroundStyle(Theme.warmTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var visibleActivity: [CompanionActivityItem] {
        showingAllActivity ? current.activity : Array(current.activity.prefix(CompanionOverviewModel.activityPreview))
    }

    private var activity: some View {
        section("Recent activity") {
            if current.activity.isEmpty {
                empty(CompanionOverviewModel.noActivity)
            }
            ForEach(visibleActivity) { item in
                activityRow(item)
            }
            if current.activity.count > CompanionOverviewModel.activityPreview {
                OngoingWorkFooter(title: showingAllActivity ? "Show less" : "Show more") { showingAllActivity.toggle() }
            }
        }
    }

    private func activityRow(_ item: CompanionActivityItem) -> some View {
        let selected = selectedID == item.id
        let shown = OngoingWork.presentation(status: item.status, document: item.isDocument, hasArtifact: item.hasArtifact)
        let row = OngoingWorkItem(id: item.id, conversationID: store.veraThreadID ?? "", title: item.title, state: item.state,
                                  glyph: shown.glyph, artifact: nil, reference: nil)
        return VStack(alignment: .leading, spacing: 8) {
            OngoingWorkCard(item: row) { selectedID = selected ? nil : item.id }
                .overlay(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous)
                    .stroke(selected ? Theme.sage : Color.clear, lineWidth: 1.5))
                .accessibilityAddTraits(selected ? .isSelected : [])
            if selected, item.canOpen || item.canRetry || item.canStop {
                HStack(spacing: 8) {
                    if item.canOpen { Button("Open") { store.openCompanionActivity(item) } }
                    if item.canRetry { Button("Retry") { store.retryCompanionWork(item) } }
                    if item.canStop { Button(CompanionOverviewModel.stopTitle) { store.stopCompanionWork(item) } }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .padding(.leading, 4)
            }
        }
    }

    private var rules: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Rules for this task").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warmTextPrimary)
                if let title = current.rulesTitle(selected: selectedID) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.warmTextPrimary)
                    Text(CompanionOverviewModel.noTaskRules).font(.system(size: 12)).foregroundStyle(Theme.warmTextSecondary)
                } else {
                    Text(CompanionOverviewModel.selectWorkHint).font(.system(size: 12)).foregroundStyle(Theme.warmTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var outputs: some View {
        section("Outputs") {
            if current.outputs.isEmpty {
                empty(CompanionOverviewModel.noOutputs)
            }
            ForEach(current.outputs.prefix(CompanionOverviewModel.outputPreview)) { result in
                Button { store.openCompanionResult(result.id) } label: {
                    ConversationResultRow(title: result.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(result.title)")
            }
            if current.outputs.count > CompanionOverviewModel.outputPreview {
                OngoingWorkFooter(title: "Show more") { store.openCompanionOutputs() }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warmTextPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.warmTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
