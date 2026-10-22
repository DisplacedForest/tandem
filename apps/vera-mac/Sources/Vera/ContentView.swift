import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var voice: VoiceSession
    @EnvironmentObject var config: ConfigStore
    @State private var search = ""
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @StateObject private var workflowEditor = WorkflowEditorStore()

    private func select(_ item: AppSection) {
        switch item {
        case .vera: store.openVeraThread()
        case .chat: store.openChats()
        case .pulse: store.goToPulse()
        case .memory: store.section = .memory
        case .projects, .artifacts, .scheduled, .integrations, .agentic: store.section = item
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                VeraSidebar(collapsed: $sidebarCollapsed, search: $search, workflowEditor: workflowEditor, onSelect: select)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                HStack(spacing: 0) {
                    Group {
                        switch store.section {
                        case .vera, .chat: ChatPane()
                        case .pulse: PulseView()
                        case .memory: MemoryView()
                        case .agentic: AgenticView(workflowEditor: workflowEditor)
                        case .scheduled: ScheduledView()
                        case .projects, .artifacts, .integrations:
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
            .ignoresSafeArea(.container, edges: .top)
            .task { await store.connect() }

            if voice.isActive {
                VoiceView().transition(.opacity).zIndex(1)
            }
        }
        .environment(\.inspectMemorySource, { store.inspectMemoryCitation($0) })
        .sheet(item: $store.inspectedMemory) { MemoryDetailView(memory: $0, citedRevision: store.inspectedMemoryRevision, trace: store.inspectedMemoryTrace) }
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

struct SidebarRow: View {
    let convo: Conversation
    var onPin: () -> Void = {}
    var onRename: (String) -> Void = { _ in }
    var onMemoryExclusion: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var hovering = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var editingInstructions = false

    private func beginRename() {
        renameText = convo.title
        renaming = true
    }

    @ViewBuilder private var menuItems: some View {
        Button("Rename", action: beginRename)
        Button(convo.pinned ? "Unpin" : "Pin", action: onPin)
        Button("Instructions…") { editingInstructions = true }
        Button(
            convo.memoryExcluded ? "Allow memory suggestions" : "Exclude from memory suggestions",
            action: onMemoryExclusion)
        Button("Delete", role: .destructive, action: onDelete)
    }

    var body: some View {
        SidebarChatRowLabel(title: convo.title) {
            if hovering {
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 18).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            } else if convo.pinned {
                Image(systemName: "pin").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Rename") { onRename(renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $editingInstructions) {
            ConversationInstructionsEditor(conversation: convo)
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
                        .padding(.horizontal, 28).padding(.top, 44).padding(.bottom, 26)
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
                if convo.isPersisted, store.isPulseConfigured {
                    HStack(spacing: 12) {
                        KnowledgeGroundingChip(conversation: convo)
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
        RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceHover).frame(height: 12)
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
                        Label("\(store.assistantName) isn't connected. Set up the connection", systemImage: "bolt.horizontal")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Theme.surface).clipShape(Capsule())
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
                Button { onTap(s) } label: { StarterChipLabel(title: s) }
                    .buttonStyle(.plain)
            }
        }
    }
}

struct StarterChipLabel: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Theme.surface).clipShape(Capsule())
    }
}

enum ComposerControlKind {
    case plus, voice, send(active: Bool, generating: Bool), stop(enabled: Bool)
}

struct ComposerMentionList: View {
    let sections: [(ComposerMentionSection, [ComposerMentionItem])]
    let selection: Int
    let onHover: (Int) -> Void
    let onPick: (ComposerMentionItem) -> Void

    private var rows: [ComposerMentionItem] { sections.flatMap(\.1) }

    var body: some View {
        if rows.count > 8 {
            ScrollViewReader { proxy in
                ScrollView { list }
                    .frame(maxHeight: 300)
                    .onChange(of: selection) { _, index in
                        if let item = rows[safe: index] { proxy.scrollTo(item.id) }
                    }
            }
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(sections.enumerated()), id: \.offset) { sectionIndex, section in
                Text(section.0.rawValue).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, SidebarMetrics.inset).padding(.top, sectionIndex == 0 ? 2 : 10).padding(.bottom, 4)
                ForEach(section.1) { item in
                    let index = rows.firstIndex(of: item) ?? 0
                    Button { onPick(item) } label: {
                        HStack(spacing: SidebarMetrics.inset) {
                            Image(systemName: item.icon).font(.system(size: SidebarMetrics.iconSize, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: SidebarMetrics.iconSlot, height: SidebarMetrics.iconSlot)
                            Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                            if !item.detail.isEmpty {
                                Text(item.detail).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, SidebarMetrics.inset)
                        .frame(height: SidebarMetrics.rowHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous)
                            .fill(index == selection ? Theme.surfaceHover : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .opacity(item.available ? 1 : 0.45)
                    .onHover { if $0 { onHover(index) } }
                    .id(item.id)
                    .accessibilityLabel(item.detail.isEmpty ? item.name : item.name + ", " + item.detail)
                }
            }
        }
        .padding(.bottom, 6)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct ComposerControlGlyph: View {
    let kind: ComposerControlKind
    static let size: CGFloat = 28

    private var fill: Color {
        switch kind {
        case .plus: .clear
        case .voice: Theme.surfaceHover
        case .send(let active, let generating): generating ? Theme.accentGlow : (active ? Theme.accent : Theme.surfaceHover)
        case .stop(let enabled): enabled ? Theme.accent : Theme.surfaceHover
        }
    }

    private var tint: Color {
        switch kind {
        case .plus, .voice: Theme.textSecondary
        case .send(let active, let generating): active || generating ? Theme.onAccent : Theme.textSecondary
        case .stop(let enabled): enabled ? Theme.onAccent : Theme.textSecondary
        }
    }

    private var symbol: String {
        switch kind {
        case .plus: "plus"
        case .voice: "waveform"
        case .send: "arrow.up"
        case .stop: "stop.fill"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: { if case .stop = kind { 12 } else { 15 } }(), weight: .medium))
            .foregroundStyle(tint)
            .frame(width: Self.size, height: Self.size)
            .background(Circle().fill(fill))
            .contentShape(Circle())
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
                        switch NativeToolActivityPresentation.forActivity(activity) {
                        case .chip:
                            NativeToolActivityChip(activity: activity,
                                onCancel: nativeActions && activity.isCancelableRun ? { store.cancelToolRun(message.id) } : nil)
                        case .imagePlaceholder:
                            ImageGenerationPlaceholder(activity: activity,
                                onCancel: nativeActions ? { store.cancelToolRun(message.id) } : nil)
                        case .hidden:
                            EmptyView()
                        }
                        if let pendingConfirmation, pendingConfirmation.id == activity.id {
                            NativeToolConfirmationBar(
                                request: pendingConfirmation,
                                onDecision: { onToolDecision?($0) })
                        }
                    }
                    AssistantBody(message: message, nativeActions: nativeActions, onAnswer: onAnswer, onOpenArtifact: onOpenArtifact)
                    ForEach(message.attachments.filter(\.isImage)) { attachment in
                        GeneratedImageView(attachment: attachment, store: attachmentStore)
                    }
                    if nativeActions && !message.displayBlocks.isEmpty {
                        NativeDisplayBlocksView(blocks: message.displayBlocks,
                            connectedTaskIDs: store.connectedNativeTaskIDs,
                            onCancel: store.cancelNativeTask, onRetry: store.retryNativeTask)
                    }
                    if nativeActions && store.isQueuedAnswer(message.id) {
                        NativeAnswerControls(status: "Waiting to answer", canStop: true, stopLabel: "Cancel",
                                             onStop: { store.stopAnswer(message.id, reason: "Canceled.") })
                    } else if nativeActions, let note = store.answerNote(message.id) {
                        Text(note).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
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
                            .foregroundStyle(Theme.textPrimary)
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
    var onCancel: (() -> Void)? = nil
    @State private var expanded = false

    private var icon: String {
        switch activity.state {
        case .pending: return "clock"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .canceled: return "slash.circle"
        }
    }

    private var status: String {
        switch activity.state {
        case .pending: return activity.progress?.label ?? "Working"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }

    private var iconColor: Color {
        switch activity.state {
        case .failed: return Color.orange
        case .pending: return Theme.accent
        default: return Theme.textSecondary
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
                    Image(systemName: icon).foregroundStyle(iconColor)
                }
                Text(activity.title).font(.system(size: 12, weight: .medium))
                Text(status).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                if activity.confirmationRequired {
                    Text("Confirmation required")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
                if activity.state == .pending, let progress = activity.progress {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                        .accessibilityLabel(progress.label)
                }
                if activity.state == .pending, let onCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .accessibilityLabel("Cancel \(activity.title)")
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
                Text("This tool runs only after your decision.")
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
    @State private var mentionSelectionID: String?
    @State private var dismissedDraft: String?
    @State private var showingFolderUnsupported = false

    private var route: NativeComposerRoute { NativeComposerRoute(store: store, assistant: nil) }
    private var draft: Binding<String> {
        Binding(get: { route.draft }, set: { route.draft = $0 })
    }
    private func submit() { route.send() }
    private var canSend: Bool { route.canSend }
    private var mentionQuery: ComposerMentionQuery? {
        guard route.draft != dismissedDraft else { return nil }
        return ComposerMentions.query(in: route.draft)
    }
    private var mentionSections: [(ComposerMentionSection, [ComposerMentionItem])] {
        mentionQuery.map { store.mentionCatalog.sections($0.text) } ?? []
    }
    private var mentionRows: [ComposerMentionItem] { mentionSections.flatMap(\.1) }
    private var mentionIndex: Int { mentionRows.firstIndex { $0.id == mentionSelectionID } ?? 0 }
    private var pickerVisible: Bool { !mentionRows.isEmpty }

    private func pickMention(_ item: ComposerMentionItem) {
        guard let query = mentionQuery else { return }
        let next = ComposerMentions.insert(item, into: route.draft, replacing: query)
        route.draft = next
        dismissedDraft = next
        mentionSelectionID = nil
        if case .files = item.kind { pickFiles() }
        if case .folder = item.kind { pickFolder() }
        focused = true
    }

    private func moveMentionSelection(_ delta: Int) -> KeyPress.Result {
        let rows = mentionRows
        guard !rows.isEmpty else { return .ignored }
        mentionSelectionID = rows[(mentionIndex + delta + rows.count) % rows.count].id
        return .handled
    }

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
            if let error = store.grantError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    Text(error).font(.system(size: 11))
                    Button { store.grantError = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Theme.textSecondary)
            }
            if !store.selectedGrants.isEmpty {
                FolderGrantChips(grants: store.selectedGrants, unsupported: store.folderToolsUnsupportedReason,
                                 onRemove: { store.revokeGrant($0) })
            }
            if !store.attachments.isEmpty {
                AttachmentsBar(attachments: store.attachments, onRemove: { store.removeAttachment($0) })
            }
            if pickerVisible {
                ComposerMentionList(sections: mentionSections, selection: mentionIndex,
                                    onHover: { mentionSelectionID = mentionRows[safe: $0]?.id }, onPick: pickMention)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            TextField("Message \(store.assistantName)…", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .focused($focused)
                .onChange(of: route.draft) { _, _ in mentionSelectionID = nil }
                .onKeyPress(.upArrow) { moveMentionSelection(-1) }
                .onKeyPress(.downArrow) { moveMentionSelection(1) }
                .onKeyPress(.escape) {
                    guard pickerVisible else { return .ignored }
                    dismissedDraft = route.draft
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        draft.wrappedValue += "\n"
                        return .handled
                    }
                    if pickerVisible {
                        pickMention(mentionRows[mentionIndex])
                        return .handled
                    }
                    submit()
                    return .handled
                }
            HStack(spacing: 8) {
                Menu {
                    Button("Add files or photos") { pickFiles() }
                    Button("Work in a folder…") { pickFolder() }
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
                    ComposerControlGlyph(kind: .plus)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Add files, grant a folder, or insert a saved prompt")
                Spacer()
                Button(action: {}) { ComposerControlGlyph(kind: .voice) }
                    .buttonStyle(.plain)
                    .disabled(true)
                    .help("Voice is not available in native chat yet")
                if let stoppable = store.selected.flatMap({ store.stoppableAnswer(in: $0.id) }) {
                    Button { store.stopAnswer(stoppable) } label: {
                        ComposerControlGlyph(kind: .stop(enabled: true))
                    }
                    .buttonStyle(.plain)
                    .help("Stop answer")
                    .accessibilityLabel("Stop answer")
                } else {
                    Button(action: submit) {
                        ComposerControlGlyph(kind: .send(active: canSend, generating: false))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
            Button("", action: pickFiles).keyboardShortcut("u", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(dropTargeted ? Theme.accent : Theme.hairline, lineWidth: dropTargeted ? 2 : 1))
        .onAppear {
            focused = true
            installPasteMonitor()
        }
        .onDisappear { removePasteMonitor() }
        .onChange(of: store.focusTick) { _, _ in focused = true }
        .onChange(of: store.grantConsentTick) { _, _ in
            guard !config.nativeSettings.enabledToolIDs.contains(NativeFolderTools.toolID) else { return }
            config.setNativeTool(NativeFolderTools.toolID, enabled: true)
            try? config.save()
        }
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
        .alert("This model can't use folders", isPresented: $showingFolderUnsupported) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.folderToolsUnsupportedReason ?? "")
        }
    }

    private func pickFolder() {
        if store.folderToolsUnsupportedReason != nil {
            showingFolderUnsupported = true
            return
        }
        FilePicker.pickFolder { url in
            guard let url else { return }
            store.grantFolder(url)
        }
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
