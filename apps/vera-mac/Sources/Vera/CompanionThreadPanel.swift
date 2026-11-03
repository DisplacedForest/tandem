import SwiftUI
import MarkdownUI

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
    @State private var navigationError: String?

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
            if let item = current.selected(selectedID) {
                activityDetail(item)
            } else {
                identity
                if !current.activity.isEmpty { activity }
                if !current.outputs.isEmpty { outputs }
            }
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
                if !current.goal.isEmpty {
                    Text(current.goal).font(.system(size: 13)).foregroundStyle(Theme.warmTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    private var visibleActivity: [CompanionActivityItem] {
        showingAllActivity ? current.activity : Array(current.activity.prefix(CompanionOverviewModel.activityPreview))
    }

    private var activity: some View {
        section("Recent activity") {
            ForEach(visibleActivity) { item in
                activityRow(item)
            }
            if current.activity.count > CompanionOverviewModel.activityPreview {
                OngoingWorkFooter(title: showingAllActivity ? "Show less" : "Show more") { showingAllActivity.toggle() }
            }
        }
    }

    private func activityRow(_ item: CompanionActivityItem) -> some View {
        let shown = OngoingWork.presentation(status: item.status, document: item.isDocument, hasArtifact: item.hasArtifact)
        let row = OngoingWorkItem(id: item.id, conversationID: store.veraThreadID ?? "", title: item.title, state: item.state,
                                  glyph: shown.glyph, artifact: nil, reference: nil)
        return OngoingWorkCard(item: row) { navigationError = nil; selectedID = item.id }
            .accessibilityLabel("Details for \(item.title)")
    }

    private func activityDetail(_ item: CompanionActivityItem) -> some View {
        let detail = store.companionActivityDetail(item)
        return VStack(alignment: .leading, spacing: 20) {
            Button { navigationError = nil; selectedID = nil } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.plain).accessibilityLabel("Back to overview")
            Text(item.title).font(.system(size: 18, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let request = detail.request {
                Text(request).font(.system(size: 13)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius))
            }
            Text(item.state).font(.system(size: 13)).foregroundStyle(Theme.warmTextSecondary)
            if let outcome = detail.outcome {
                Markdown(outcome)
                    .markdownTextStyle { ForegroundColor(Theme.warmTextPrimary); FontSize(13) }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.canRetry || item.canStop {
                HStack {
                    if item.canRetry { Button("Retry") { store.retryCompanionWork(item) } }
                    if item.canStop { Button(CompanionOverviewModel.stopTitle) { store.stopCompanionWork(item) } }
                }.controlSize(.small)
            }
            if let navigationError {
                Text(navigationError).font(.system(size: 13)).foregroundStyle(Theme.warmTextSecondary)
            }
            if detail.canOpen {
                Button {
                    if store.openCompanionActivity(item) { onClose?() }
                    else { navigationError = "This chat is no longer available." }
                } label: {
                    Label("Go to chat", systemImage: "bubble.left")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large)
            }
        }.foregroundStyle(Theme.warmTextPrimary)
    }

    private var outputs: some View {
        section("Outputs") {
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

}
