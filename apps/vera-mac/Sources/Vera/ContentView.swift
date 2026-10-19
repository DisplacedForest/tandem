import SwiftUI

enum SidebarItem: Hashable {
    case convo(String)
    case feed, workflows, activity
}

struct ContentView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var voice: VoiceSession
    @EnvironmentObject var config: ConfigStore
    @State private var search = ""
    @StateObject private var workflowEditor = WorkflowEditorStore()

    private func selectRail(_ item: AppSection) {
        switch item {
        case .vera: store.openVeraThread()
        case .chat:
            if let id = store.selectedID, !store.isVeraThread(id) { store.select(id) } else { store.newConversation() }
        case .pulse: store.goToPulse()
        case .memory: store.section = .memory
        case .projects, .artifacts, .scheduled, .integrations, .agentic: store.section = item
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                IconRail(selection: store.section, onSelect: selectRail)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                NavigationSplitView {
                    Sidebar(search: $search, workflowEditor: workflowEditor)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } detail: {
                    HStack(spacing: 0) {
                        Group {
                            switch store.section {
                            case .vera, .chat: ChatPane()
                            case .pulse: PulseView()
                            case .memory: MemoryView()
                            case .agentic: AgenticView(workflowEditor: workflowEditor)
                            case .projects, .artifacts, .scheduled, .integrations:
                                DestinationPlaceholder(section: store.section)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if store.showCanvas, store.section == .chat || store.section == .vera {
                            Divider()
                            CanvasPanel().frame(width: 480)
                        }
                    }
                    .background(Theme.ink)
                }
            }
            .task { await store.connect() }

            if voice.isActive {
                VoiceView().transition(.opacity).zIndex(1)
            }
        }
        .environment(\.inspectMemorySource, { store.inspectMemoryCitation($0) })
        .sheet(item: $store.inspectedMemory) { MemoryDetailView(memory: $0, citedRevision: store.inspectedMemoryRevision) }
        .animation(.easeInOut(duration: 0.2), value: voice.isActive)
        .sheet(isPresented: $config.showOnboarding) { OnboardingSheet() }
    }
}

struct Placeholder: View {
    let title: String
    let note: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hammer.fill").font(.system(size: 28)).foregroundStyle(Theme.textSecondary)
            Text(title).font(.system(size: 18, weight: .semibold))
            Text("coming in \(note)").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

private struct Sidebar: View {
    @EnvironmentObject var store: ChatStore
    @Binding var search: String
    @ObservedObject var workflowEditor: WorkflowEditorStore

    private var pulseSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                switch store.section {
                case .agentic: return store.agenticPane == .canvas ? .workflows : .activity
                default: return .feed
                }
            },
            set: { item in
                switch item {
                case .feed: store.goToPulse()
                case .workflows: store.section = .agentic; store.agenticPane = .canvas; store.agenticFlowID = nil
                case .activity: store.section = .agentic; store.agenticPane = .activity; store.agenticFlowID = nil
                default: break
                }
            })
    }

    private var chatSelection: Binding<SidebarItem?> {
        Binding(
            get: { store.section == .chat ? store.selectedID.map(SidebarItem.convo) : nil },
            set: { if case .convo(let id)? = $0 { store.select(id) } })
    }

    var body: some View {
        Group {
            switch store.section.rail {
            case .vera: veraPanel
            case .chat: chatList
            case .pulse:
                if store.section == .agentic, store.agenticFlowID != nil {
                    WorkflowPalette(store: workflowEditor, searchText: $search) { store.agenticFlowID = nil }
                } else {
                    pulseList
                }
            case .memory:
                SidebarHeading(title: "Memory", note: "What Vera remembers about you, with its sources.")
                Spacer()
            default:
                SidebarHeading(title: store.section.placeholder?.title ?? store.section.title)
                Spacer()
            }
        }
        .background(Theme.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { UpdateBanner() }
        .toolbar {
            if store.section.rail == .chat {
                ToolbarItem {
                    Button { store.newConversation() } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    .help("New chat")
                }
            }
        }
    }

    private var veraPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VeraMark(size: 24)
                Text("Vera").font(.system(size: 15, weight: .semibold))
            }
            Text("Your ongoing thread. It keeps its history, drafts and background work between visits.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pulseList: some View {
        List(selection: pulseSelection) {
            Section {
                Label("Feed", systemImage: "newspaper").tag(SidebarItem.feed)
                Label("Workflows", systemImage: "point.3.connected.trianglepath.dotted").tag(SidebarItem.workflows)
                Label("Activity", systemImage: "bolt").tag(SidebarItem.activity)
            }
        }
        .listStyle(.sidebar)
        .labelStyle(NativeSidebarLabelStyle())
        .tint(Theme.accent)
    }

    private var chatList: some View {
        List(selection: chatSelection) {
            Section {
                Button { store.newConversation() } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(.plain)
            }
            ForEach(store.sidebarGroups(search: search)) { group in
                Section(group.title) {
                    ForEach(group.convos) { convo in
                        SidebarRow(convo: convo,
                                   onPin: { store.togglePin(convo.id) },
                                   onMemoryExclusion: { store.toggleMemoryExclusion(convo.id) },
                                   onDelete: { store.deleteConversation(convo.id) })
                            .tag(SidebarItem.convo(convo.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .labelStyle(NativeSidebarLabelStyle())
        .tint(Theme.accent)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
    }
}

private struct NativeSidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)
            configuration.title
        }
    }
}

struct SidebarRow: View {
    let convo: Conversation
    var onPin: () -> Void = {}
    var onMemoryExclusion: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            Text(convo.title).lineLimit(1)
            Spacer(minLength: 0)
            // Hover only reveals the ⋯ menu — no hover background, since macOS drops
            // onHover-exit events and would leave rows stuck looking selected.
            if hovering {
                Menu {
                    Button(convo.pinned ? "Unpin" : "Pin", action: onPin)
                    Button(
                        convo.memoryExcluded ? "Allow memory suggestions" : "Exclude from memory suggestions",
                        action: onMemoryExclusion)
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 18).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            } else if convo.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9))
                    .foregroundStyle(Theme.textSecondary).rotationEffect(.degrees(45))
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(convo.pinned ? "Unpin" : "Pin", action: onPin)
            Button(
                convo.memoryExcluded ? "Allow memory suggestions" : "Exclude from memory suggestions",
                action: onMemoryExclusion)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Chat pane

private struct ChatPane: View {
    @EnvironmentObject var store: ChatStore
    private var conversation: Conversation? { store.selected }
    private var generating: Bool { store.generating }
    @State private var highlightedMessageID: UUID?
    @State private var highlightVisible = false

    private func revealPendingSource(_ proxy: ScrollViewProxy) {
        guard let id = store.pendingHighlightMessageID,
              conversation?.messages.contains(where: { $0.id == id }) == true else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard store.pendingHighlightMessageID == id else { return }
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            store.clearPendingHighlight(id)
            highlightedMessageID = id
            highlightVisible = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.easeOut(duration: 1.8)) { highlightVisible = false }
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            if highlightedMessageID == id { highlightedMessageID = nil }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = store.pendingSourceNotice, notice.conversationID == conversation?.id {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.textSecondary)
                    Text(notice.message).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { store.dismissSourceNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .frame(maxWidth: 760)
                .padding(.horizontal, 28).padding(.top, 10)
                .accessibilityElement(children: .contain)
            }
            if let convo = conversation, !convo.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(convo.messages) { msg in
                                let confirmation = store.turnConfirmations[msg.id]
                                let confirmationToken = store.turnConfirmationTokens[msg.id]
                                MessageRow(message: msg, nativeActions: true,
                                           onAnswer: { id, sel, other in store.submitAsk(messageID: id, selections: sel, other: other) },
                                           onOpenArtifact: { store.openArtifact($0) },
                                           attachmentStore: store.attachmentStore,
                                           pendingConfirmation: confirmation,
                                           onToolDecision: { approved in
                                               store.resolveTurnConfirmation(msg.id, approved: approved,
                                                   requestID: confirmation?.id, token: confirmationToken)
                                           })
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Theme.accent.opacity(highlightedMessageID == msg.id && highlightVisible ? 0.14 : 0))
                                            .padding(-8))
                                    .id(msg.id)
                            }
                            VeraMark(size: 27, animated: generating)
                                .frame(width: 27, height: 27)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 2)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 26)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    // Follow the text as it streams in, and on new turns / chat switches.
                    .onChange(of: convo.messages.last?.text ?? "") { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: convo.messages.count) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: store.selectedID) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                        revealPendingSource(proxy)
                    }
                    .onChange(of: store.pendingHighlightMessageID) { revealPendingSource(proxy) }
                    .onAppear {
                        proxy.scrollTo("bottom", anchor: .bottom)
                        revealPendingSource(proxy)
                    }
                }
                if let status = store.streamStatus {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 28).padding(.bottom, 2)
                }
                if convo.isPersisted {
                    HStack(spacing: 12) {
                        ConversationInstructionsChip(conversation: convo)
                        if store.isPulseConfigured {
                            KnowledgeGroundingChip(conversation: convo)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 28).padding(.top, 4)
                }
                ComposerField().padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
                    .frame(maxWidth: 760)
            } else if let convo = conversation, convo.isPersisted, !store.isVeraThread(convo.id) {
                ChatLoadingSkeleton()
                ComposerField().padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
                    .frame(maxWidth: 760)
            } else {
                EmptyChatView()
            }
        }
    }
}

/// Shimmering placeholder shown while a real chat's history loads (no welcome-screen flash).
private struct ChatLoadingSkeleton: View {
    @State private var on = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) { bar(140); bar(nil); bar(360) }
            }
            Spacer()
        }
        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 26)
        .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        .opacity(on ? 0.45 : 0.9)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true } }
    }
    private func bar(_ w: CGFloat?) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)).frame(height: 12)
            .frame(maxWidth: w ?? .infinity, alignment: .leading)
    }
}

/// Centered welcome shown for an empty chat — greeting, centered composer, and starter prompts.
/// When the app isn't connected, offers the setup sheet instead of pretending to work.
private struct EmptyChatView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore

    private var greeting: String {
        if store.isVeraThread(store.selectedID) { return "What are we working on?" }
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "morning" : (h < 18 ? "afternoon" : "evening")
        guard let name = config.ownerName else { return "Good \(part)" }
        return "Good \(part), \(name)"
    }

    private let starters = [
        "What's on today?", "Check the kitchen", "What's the weather?", "Research a topic for me",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                HStack(spacing: 12) {
                    VeraMark(size: 30)
                    Text(greeting).font(.system(size: 28, weight: .semibold))
                }
                ComposerField()
                if let error = store.chatConfigurationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else if store.isLive {
                    FlowChips(items: starters) { s in store.draft = s; store.focusTick &+= 1 }
                } else {
                    Button { config.showOnboarding = true } label: {
                        Label("Vera isn't connected. Set up the connection", systemImage: "bolt.horizontal")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.surface).clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 28)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

/// Wrapping row of tappable starter-prompt chips.
private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void
    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { s in
                Button { onTap(s) } label: {
                    Text(s).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.surface).clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct MessageRow: View {
    @EnvironmentObject private var store: ChatStore
    let message: Message
    var nativeActions = true
    var onAnswer: ((UUID, [String], String) -> Void)? = nil
    var onOpenArtifact: ((Artifact) -> Void)? = nil
    var attachmentStore: NativeAttachmentStore? = nil
    var pendingConfirmation: NativeToolConfirmationRequest? = nil
    var onToolDecision: ((Bool) -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if message.role == .assistant {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(NativeTaskTranscript.visibleActivities(in: message)) { activity in
                        NativeToolActivityChip(activity: activity)
                        if let pendingConfirmation, pendingConfirmation.id == activity.id {
                            NativeToolConfirmationBar(
                                request: pendingConfirmation,
                                onDecision: { onToolDecision?($0) })
                        }
                    }
                    AssistantBody(message: message, nativeActions: nativeActions, onAnswer: onAnswer, onOpenArtifact: onOpenArtifact)
                    if nativeActions && !message.displayBlocks.isEmpty {
                        NativeDisplayBlocksView(blocks: message.displayBlocks,
                            connectedTaskIDs: store.connectedNativeTaskIDs,
                            onCancel: store.cancelNativeTask, onRetry: store.retryNativeTask)
                    }
                    if nativeActions, let status = store.answerStatus(message.id) {
                        NativeAnswerControls(status: status, canStop: store.canStopAnswer(message.id),
                                             onStop: { store.stopAnswer(message.id) })
                    }
                    if nativeActions && message.state == .interrupted {
                        Label(message.failure ?? "The response was interrupted", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        Button("Retry answer") { store.retryAnswer(message.id) }
                            .buttonStyle(.borderless).font(.system(size: 11))
                    }
                }
            } else {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.attachments.isEmpty {
                        SentAttachmentsBar(attachments: message.attachments, store: attachmentStore)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 14)).textSelection(.enabled)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.userBubble)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if let note = message.routeNote {
                        AttachmentRouteBadge(
                            note: note,
                            missingImages: attachmentStore?.missingImageNames(
                                in: message.attachments) ?? [])
                    }
                }
            }
        }
    }
}

struct AttachmentRouteBadge: View {
    let note: MessageRouteNote
    var missingImages: [String] = []
    @State private var showDisclosure = false

    private var icon: String {
        switch note.route {
        case .direct: return missingImages.isEmpty ? "photo" : "exclamationmark.triangle"
        case .bridged: return "arrow.triangle.branch"
        case .withheld: return "eye.slash"
        }
    }

    private var label: String {
        switch note.route {
        case .direct where !missingImages.isEmpty:
            return "\(missingImages.joined(separator: ", ")) could not be loaded and was not included in the model request"
        case .direct:
            return "Image included in the model request"
        case .bridged where note.disclosure == nil:
            return "Routing through the vision bridge\(note.bridgeModel.map { " (\($0))" } ?? "")"
        case .bridged:
            return "Described by the vision bridge\(note.bridgeModel.map { " (\($0))" } ?? ""). The model did not receive the image."
        case .withheld:
            return "Sent without the attachment"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label).font(.system(size: 11))
            if note.route == .bridged, note.disclosure != nil {
                Button(showDisclosure ? "Hide description" : "Show description") {
                    showDisclosure.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
            }
        }
        .foregroundStyle(Theme.textSecondary)
        if showDisclosure, let disclosure = note.disclosure {
            Text(disclosure)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(Theme.textSecondary)
                .padding(10).frame(maxWidth: 480, alignment: .leading)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1))
        }
    }
}

struct NativeToolActivityChip: View {
    let activity: NativeToolActivity
    @State private var expanded = false

    private var icon: String {
        switch activity.state {
        case .pending: return "clock"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var status: String {
        switch activity.state {
        case .pending: return "Working"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                inspected("Request", activity.request)
                if let result = activity.result { inspected("Result", result) }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                if activity.state == .pending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon)
                        .foregroundStyle(activity.state == .failed ? Color.orange : Theme.accent)
                }
                Text(activity.title).font(.system(size: 12, weight: .medium))
                Text(status).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                if activity.confirmationRequired {
                    Text("Confirmation required")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
            }
            .foregroundStyle(Theme.textPrimary)
        }
        .disclosureGroupStyle(.automatic)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: 480, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }

    private func inspected(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

struct NativeToolConfirmationBar: View {
    let request: NativeToolConfirmationRequest
    var prompt: String? = nil
    var defaultApproval = true
    var allowApprove = true
    var allowDecline = true
    var onDecision: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 13)).foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt ?? "Run \(request.title)?")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text("Vera waits for your decision before this tool runs.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("Decline") { onDecision(false) }.disabled(!allowDecline)
            if defaultApproval {
                Button("Approve") { onDecision(true) }.keyboardShortcut(.defaultAction).disabled(!allowApprove)
            } else {
                Button("Approve") { onDecision(true) }.disabled(!allowApprove)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: 480, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.orange.opacity(0.5), lineWidth: 1))
    }
}

/// A tappable reference to an artifact, shown inline under Vera's message.
struct ArtifactChip: View {
    let artifact: Artifact
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 13)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(detail ?? "\(artifact.type.rawValue) · open in Canvas").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right.square").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(10).frame(maxWidth: 360, alignment: .leading)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Composer

/// The rounded chat input box (text field + send), reused by the bottom bar and the empty state.
/// Moves the cursor into the field whenever `store.focusTick` changes (new chat, starter tap).
struct ComposerField: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var voice: VoiceSession
    @EnvironmentObject var config: ConfigStore
    @FocusState private var focused: Bool
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?

    private var route: NativeComposerRoute { NativeComposerRoute(store: store, assistant: nil) }
    private var draft: Binding<String> {
        Binding(get: { route.draft }, set: { route.draft = $0 })
    }
    private func submit() { route.send() }
    private var canSend: Bool { route.canSend }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.attachmentError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text(error).font(.system(size: 11))
                    Button {
                        store.attachmentError = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Theme.textSecondary)
            }
            if !store.attachments.isEmpty {
                AttachmentsBar(attachments: store.attachments, onRemove: { store.removeAttachment($0) })
            }
            TextField("Message Vera…", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    // Shift+Return inserts a line break; plain Return sends.
                    // We must insert the newline ourselves and return .handled —
                    // the field editor maps any Return to submit, so .ignored sends.
                    if press.modifiers.contains(.shift) {
                        draft.wrappedValue += "\n"
                        return .handled
                    }
                    submit()
                    return .handled
                }
            HStack(spacing: 10) {
                Menu {
                    Button("Add files or photos") { pickFiles() }
                    if let prompts = try? store.promptLibrary?.reusablePrompts(), !prompts.isEmpty {
                        Divider()
                        ForEach(prompts) { prompt in
                            Button("Insert: \(prompt.name)") {
                                store.draft = store.draft.isEmpty
                                    ? prompt.content : store.draft + "\n" + prompt.content
                                store.focusTick &+= 1
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: Circle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Add images or insert a saved prompt")
                Spacer()
                Button(action: {}) {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(true)
                .help("Voice is not available in native chat yet")
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(store.generating ? Theme.accentGlow
                                         : (canSend ? Theme.accent : Theme.textSecondary))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            Button("", action: pickFiles).keyboardShortcut("u", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(dropTargeted ? Theme.accent : .clear, lineWidth: 2))
        .onAppear {
            focused = true
            installPasteMonitor()
        }
        .onDisappear { removePasteMonitor() }
        .onChange(of: store.focusTick) { _, _ in focused = true }
        .confirmationDialog(
            store.pendingSendDecision?.imageLimit == nil
                ? "This model can't take images" : "Too many images for this model",
            isPresented: Binding(
                get: { store.pendingSendDecision != nil },
                set: { if !$0 { route.cancelPendingSend() } }),
            titleVisibility: .visible
        ) {
            Button("Send without the attachments") { route.confirmWithoutAttachments() }
            Button("Cancel", role: .cancel) { route.cancelPendingSend() }
        } message: {
            if let decision = store.pendingSendDecision {
                if let limit = decision.imageLimit {
                    Text("\(decision.modelID) accepts at most \(limit) image\(limit == 1 ? "" : "s") per request and no vision bridge is configured. Send the message without its \(decision.imageCount) images, or cancel and remove some. You can raise the limit or set up a bridge in Settings.")
                } else {
                    Text("\(decision.modelID) does not accept image input and no vision bridge is configured. Send the message without \(decision.imageCount == 1 ? "its image" : "its \(decision.imageCount) images"), or cancel and keep editing. You can set up a bridge or adjust this model's capabilities in Settings.")
                }
            }
        }
        .confirmationDialog(
            "The endpoint rejected a parameter",
            isPresented: Binding(
                get: { store.parameterRejection != nil },
                set: { if !$0 { route.clearParameterRejection() } }),
            titleVisibility: .visible
        ) {
            Button("Reset \(store.parameterRejection?.rejection.displayName ?? "the parameter") and try again") {
                resetRejectedParameter()
            }
            Button("Keep the value", role: .cancel) { route.clearParameterRejection() }
        } message: {
            if let prompt = store.parameterRejection {
                Text("\(prompt.model) rejected \(prompt.rejection.displayName): \(prompt.detail) Your message is saved in the conversation. Resetting sends the same message again without this setting.")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            route.addFiles(urls)
        } isTargeted: { dropTargeted = $0 }
    }

    private func resetRejectedParameter() {
        guard let prompt = store.parameterRejection else { return }
        store.parameterRejection = nil
        config.clearRejectedParameter(model: prompt.model, rejection: prompt.rejection)
        try? config.save()
        if let resolved = config.nativeResolved { store.applyNativeOptions(resolved) }
        store.retryLastTurn(conversationID: prompt.conversationID)
    }

    private func pickFiles() {
        FilePicker.pick { urls in route.addFiles(urls) }
    }

    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused,
                  let window = event.window, window == NSApp.keyWindow,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let pasteboard = NSPasteboard.general
            if pasteboard.string(forType: .string) != nil { return event }
            let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?
                .filter(\.isFileURL) ?? []
            if !fileURLs.isEmpty {
                store.addFiles(fileURLs)
                return nil
            }
            if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
               !images.isEmpty {
                let datas = images.compactMap(\.pngData)
                if !datas.isEmpty {
                    store.addPastedImages(datas)
                    return nil
                }
            }
            return event
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }
}
