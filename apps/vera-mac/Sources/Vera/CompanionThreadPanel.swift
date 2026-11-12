import SwiftUI
import MarkdownUI

extension CompanionProfileState {
    static func available(section: AppSection, companionThread: Bool) -> Bool { section == .vera && companionThread }
}

enum CompanionProfileMetrics {
    static let width: CGFloat = 340
    static let minimumWidth: CGFloat = 280
    static let minimumConversation: CGFloat = 360
    static let divider: CGFloat = 1
    static let edge: CGFloat = 16
    static let top: CGFloat = 14
    static let toggleSize: CGFloat = 32
    static let transcriptTop: CGFloat = 66

    static func panelWidth(available: CGFloat) -> CGFloat {
        min(width, max(minimumWidth, available - minimumConversation - divider))
    }
}

struct CompanionProfileLayout<Conversation: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var state: CompanionProfileState
    var shown: Bool
    var fixed: CompanionOverviewModel?
    var selectedID: String?
    let conversation: Conversation

    init(state: Binding<CompanionProfileState>, shown: Bool = true, fixed: CompanionOverviewModel? = nil,
         selectedID: String? = nil, @ViewBuilder conversation: () -> Conversation) {
        _state = state
        self.shown = shown
        self.fixed = fixed
        self.selectedID = selectedID
        self.conversation = conversation()
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { state.close(now: Date()) }
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                conversation
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if shown { CompanionProfileControls(state: $state, fixed: fixed) }
                    }
                if shown, state.isOpen {
                    HStack(spacing: 0) {
                        Rectangle().fill(Theme.hairline).frame(width: CompanionProfileMetrics.divider)
                        CompanionThreadPanel(fixed: fixed, selectedID: selectedID, newSince: state.lastClosed,
                                             width: CompanionProfileMetrics.panelWidth(available: proxy.size.width),
                                             onClose: close)
                    }
                    .frame(maxHeight: .infinity)
                    .transition(reduceMotion ? .identity : .move(edge: .trailing))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}

struct CompanionProfileControls: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var state: CompanionProfileState
    var fixed: CompanionOverviewModel? = nil

    private var mention: String { fixed?.mention ?? store.companion.inline }
    private var toggleTitle: String { CompanionProfileCopy.toggleTitle(name: mention, open: state.isOpen) }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { state.toggle(now: Date()) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    CompanionAvatar(size: 22)
                    CompanionNamedText(template: CompanionSentence.placeholder)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.warmTextPrimary)
                        .lineLimit(1)
                }
                .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 5)
                .background(Capsule().fill(Theme.cardFill).shadow(color: .black.opacity(0.08), radius: 6, y: 2))
                .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(toggleTitle)
            .accessibilityLabel(toggleTitle)
            .padding(.top, CompanionProfileMetrics.top)
            .padding(.horizontal, CompanionProfileMetrics.toggleSize + CompanionProfileMetrics.edge * 2)

            Button(action: toggle) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(state.isOpen ? Theme.warmTextPrimary : Theme.warmTextSecondary)
                    .frame(width: CompanionProfileMetrics.toggleSize, height: CompanionProfileMetrics.toggleSize)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(state.isOpen ? Theme.cardFill : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(toggleTitle)
            .accessibilityLabel(toggleTitle)
            .padding(.top, CompanionProfileMetrics.top)
            .padding(.trailing, CompanionProfileMetrics.edge)
            .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct CompanionThreadPanel: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore
    @Environment(\.renderSafe) private var renderSafe
    var fixed: CompanionOverviewModel? = nil
    var newSince: Date
    var width: CGFloat
    var onClose: (() -> Void)? = nil
    @State private var model: CompanionOverviewModel
    @State private var selectedID: String?
    @State private var showingAllActivity = false
    @State private var editingProfile = false
    @State private var editingAppearance = false
    @State private var navigationError: String?
    @State private var scheduleProblem: (id: String, text: String)?

    init(fixed: CompanionOverviewModel? = nil, selectedID: String? = nil, newSince: Date = .distantFuture,
         width: CGFloat = CompanionProfileMetrics.width, onClose: (() -> Void)? = nil) {
        self.fixed = fixed
        self.newSince = newSince
        self.width = width
        self.onClose = onClose
        _selectedID = State(initialValue: selectedID)
        _model = State(initialValue: fixed ?? CompanionOverviewModel(name: "", services: "", rules: "", paused: false, activity: [], outputs: []))
    }

    private var current: CompanionOverviewModel { fixed ?? model }

    var body: some View {
        Group {
            if renderSafe {
                content
            } else {
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView { content }
                }
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.cardFill)
        .background {
            if let onClose {
                Button("", action: onClose).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
        }
        .onAppear { refresh() }
        .onReceive(store.objectWillChange.debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)) { _ in refresh() }
        .sheet(isPresented: $editingProfile) {
            DotSettingsView().environmentObject(store).environmentObject(config)
        }
        .sheet(isPresented: $editingAppearance) {
            CompanionAppearancePicker(config: config, store: ConfigCompanionAppearanceStore(config: config), chat: store)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CompanionProfileCopy.panelLabel(name: CompanionSubject(current.name).leading))
    }

    private func refresh() {
        guard fixed == nil else { return }
        let next = store.companionOverviewModel()
        if next != model { model = next }
        if let id = selectedID, next.selected(id) == nil { selectedID = nil }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let item = current.selected(selectedID) {
                activityDetail(item)
            } else {
                identity
                if !current.activity.isEmpty { activity }
                if !current.outputs.isEmpty { outputs }
                if !current.upcoming.isEmpty { upcoming }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                CompanionAvatar(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    CompanionNamedText(template: CompanionSentence.placeholder)
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.warmTextPrimary)
                        .lineLimit(1)
                    if let line = CompanionProfileCopy.activeLine(since: current.lastActive, now: Date()) {
                        Text(line).font(.system(size: 12)).foregroundStyle(Theme.warmTextSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                moreMenu
            }
            if current.paused {
                Text(DotProfileCopy.pausedNote).font(.system(size: 12)).foregroundStyle(Theme.warmTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if current.isEmpty {
                Text(CompanionProfileCopy.empty).font(.system(size: 13)).foregroundStyle(Theme.warmTextSecondary)
            }
        }
    }

    private var moreIcon: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warmTextSecondary)
            .frame(width: 28, height: 24).contentShape(Rectangle())
    }

    @ViewBuilder private var moreMenu: some View {
        if renderSafe {
            moreIcon
        } else {
            Menu {
                Button(CompanionOverviewModel.pauseTitle(name: current.mention, paused: current.paused)) {
                    store.setDotState(current.paused ? .active : .paused)
                }
                Button("Appearance") { editingAppearance = true }
                Button("Settings") { editingProfile = true }
            } label: { moreIcon }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(CompanionProfileCopy.moreOptions)
            .accessibilityLabel(CompanionProfileCopy.moreOptions)
        }
    }

    private var activity: some View {
        section("Recent activity") {
            ForEach(CompanionOverviewModel.preview(current.activity, limit: CompanionOverviewModel.activityPreview,
                                                   expanded: showingAllActivity)) { item in
                activityRow(item)
            }
            if CompanionOverviewModel.hasMore(current.activity.count, limit: CompanionOverviewModel.activityPreview) {
                moreRow(showingAllActivity ? CompanionProfileCopy.showLess : CompanionProfileCopy.showMore,
                        systemImage: showingAllActivity ? "chevron.up" : "chevron.down") { showingAllActivity.toggle() }
            }
        }
    }

    private func activityRow(_ item: CompanionActivityItem) -> some View {
        let glyph = OngoingWork.presentation(status: item.status, document: item.isDocument, hasArtifact: item.hasArtifact).glyph
        let new = CompanionOverviewModel.isNew(item, since: newSince)
        let line = item.line
        return Button { navigationError = nil; selectedID = item.id } label: {
            HStack(spacing: 10) {
                OngoingWorkGlyph(glyph: glyph)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.warmTextPrimary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if !line.isEmpty {
                        Text(line).font(.system(size: 12)).foregroundStyle(Theme.warmTextSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if new {
                    Circle().fill(Theme.statusGreen).frame(width: 8, height: 8).accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([item.title, line, new ? "New" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func moreRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.sage)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    .background(Theme.conversationBackground, in: RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius))
            }
            Text(item.state).font(.system(size: 13)).foregroundStyle(Theme.warmTextSecondary)
            if let outcome = detail.outcome {
                Markdown(outcome)
                    .markdownTextStyle { ForegroundColor(Theme.warmTextPrimary); FontSize(13) }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .safeReportContent()
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
                    HStack(spacing: 10) {
                        Image(systemName: result.kind == .image ? "photo" : "doc.text")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.warmTextSecondary)
                            .frame(width: OngoingWorkMetrics.glyphSize)
                        Text(result.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.warmTextPrimary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(result.title)")
            }
            if CompanionOverviewModel.hasMore(current.outputs.count, limit: CompanionOverviewModel.outputPreview) {
                moreRow(CompanionProfileCopy.showMore, systemImage: "chevron.right") { store.openCompanionOutputs() }
            }
        }
    }

    private var upcoming: some View {
        section("Upcoming") {
            ForEach(current.upcoming) { schedule in
                HStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.warmTextSecondary)
                        .frame(width: OngoingWorkMetrics.glyphSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(schedule.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.warmTextPrimary)
                            .lineLimit(2)
                        Text(schedule.when).font(.system(size: 12)).foregroundStyle(Theme.warmTextSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    scheduleSwitch(schedule)
                }
                .padding(.vertical, 4)
                if let problem = scheduleProblem, problem.id == schedule.id {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(problem.text).font(.system(size: 12)).foregroundStyle(Theme.warmTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(CompanionProfileCopy.openScheduled) { store.openCompanionSchedules() }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.sage)
                    }
                    .padding(.leading, OngoingWorkMetrics.glyphSize + 10).padding(.bottom, 4)
                }
            }
        }
    }

    @ViewBuilder private func scheduleSwitch(_ schedule: CompanionUpcoming) -> some View {
        if renderSafe {
            Capsule().fill(schedule.enabled ? Theme.sage : Theme.cardStroke)
                .frame(width: 26, height: 15)
                .overlay(alignment: schedule.enabled ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 13, height: 13).padding(1)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                }
                .accessibilityLabel(CompanionProfileCopy.runLabel(schedule.title))
        } else {
            Toggle(CompanionProfileCopy.runLabel(schedule.title), isOn: Binding(
                get: { schedule.enabled },
                set: { on in
                    let problem = store.switchCompanionSchedule(schedule.id, on: on)
                    scheduleProblem = problem.map { (schedule.id, $0) }
                }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel(CompanionProfileCopy.runLabel(schedule.title))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warmTextSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 2)
            content()
        }
    }
}
