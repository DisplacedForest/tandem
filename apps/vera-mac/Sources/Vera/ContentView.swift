import SwiftUI

/// The sidebar's selectable destinations — nav surfaces, one conversation, or an Agentic pane.
enum SidebarItem: Hashable {
    case pulse, memory, knowledge, assistant
    case convo(String)
    case canvas, activity
}

struct ContentView: View {
    @ObservedObject var assistant = NativePiNativeContext.presentation
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var voice: VoiceSession
    @EnvironmentObject var config: ConfigStore
    @State private var search = ""
    @StateObject private var workflowEditor = WorkflowEditorStore()

    /// The toolbar modality picker's view of `store.section`: any non-agentic surface reads
    /// as Chat; picking a mode routes to that mode's home surface.
    private var mode: Binding<AppSection> {
        Binding(get: { store.section == .agentic ? .agentic : .chat },
                set: { assistant.isSelected = false; store.section = $0 == .agentic ? .agentic : .chat })
    }

    var body: some View {
        ZStack {
            NavigationSplitView {
                Sidebar(search: $search, workflowEditor: workflowEditor, assistant: assistant)
                    .navigationSplitViewColumnWidth(min: 210, ideal: 248, max: 320)
            } detail: {
                HStack(spacing: 0) {
                    Group {
                        switch store.section {
                        case .chat: ChatPane(assistant: assistant.isSelected ? assistant : nil)
                                .id(assistant.isSelected ? "assistant" : "classic")
                        case .pulse: PulseView()
                        case .memory: MemoryView()
                        case .knowledge: KnowledgeView()
                        case .agentic: AgenticView(workflowEditor: workflowEditor)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.showCanvas && !assistant.isSelected {
                        Divider()
                        CanvasPanel().frame(width: 480)
                    }
                }
                .background(Theme.ink)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Picker("Mode", selection: mode) {
                            Text("Chat").tag(AppSection.chat)
                            Text("Agentic").tag(AppSection.agentic)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .task { await store.connect() }
            .onChange(of: store.section) { if store.section != .chat { assistant.isSelected = false } }
            .onChange(of: store.selectedID) { assistant.isSelected = false }

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

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject var store: ChatStore
    @Binding var search: String
    @ObservedObject var workflowEditor: WorkflowEditorStore
    @ObservedObject var assistant: NativePiPresentation

    private var agenticTab: Bool { store.section == .agentic }

    /// Bridges native list selection to the store's section / conversation / pane state.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                switch store.section {
                case .pulse: return .pulse
                case .memory: return .memory
                case .knowledge: return .knowledge
                case .agentic: return store.agenticPane == .canvas ? .canvas : .activity
                case .chat: return assistant.isSelected ? .assistant : store.selectedID.map(SidebarItem.convo)
                }
            },
            set: { item in
                assistant.isSelected = item == .assistant
                switch item {
                case .assistant: store.section = .chat
                case .pulse: store.goToPulse()
                case .memory: store.section = .memory
                case .knowledge: store.section = .knowledge
                case .canvas: store.section = .agentic; store.agenticPane = .canvas; store.agenticFlowID = nil
                case .activity: store.section = .agentic; store.agenticPane = .activity; store.agenticFlowID = nil
                case .convo(let id): store.select(id)
                case nil: break
                }
            })
    }

    var body: some View {
        Group {
            if agenticTab, store.agenticFlowID != nil {
                WorkflowPalette(store: workflowEditor, searchText: $search) {
                    store.agenticFlowID = nil
                }
            } else {
                navigationList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                VeraMark(size: 18)
                Text("Vera").font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { UpdateBanner() }
        .toolbar {
            ToolbarItem {
                Button {
                    assistant.isSelected = false
                    store.newConversation()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .help("New chat")
            }
        }
    }

    private var navigationList: some View {
        List(selection: selection) {
            if agenticTab {
                Section {
                    Label("Canvas", systemImage: "point.3.connected.trianglepath.dotted")
                        .tag(SidebarItem.canvas)
                    Label("Activity", systemImage: "bolt").tag(SidebarItem.activity)
                }
            } else {
                Section {
                    Label("Vera", systemImage: "sparkle").tag(SidebarItem.assistant)
                    Label("Pulse", systemImage: "newspaper").tag(SidebarItem.pulse)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { store.goToPulse() })
                    Label("Memory", systemImage: "tray.full").tag(SidebarItem.memory)
                    Label("Knowledge", systemImage: "books.vertical").tag(SidebarItem.knowledge)
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
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
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
    @ObservedObject private var presentation: NativePiPresentation
    private let usesAssistant: Bool
    private var assistant: NativePiPresentation? { usesAssistant ? presentation : nil }
    init(assistant: NativePiPresentation? = nil) {
        _presentation = ObservedObject(wrappedValue: assistant ?? NativePiNativeContext.presentation)
        usesAssistant = assistant != nil
    }
    private var conversation: Conversation? { assistant == nil ? store.selected : assistant?.conversation }
    private var generating: Bool { assistant?.session?.busy ?? (assistant == nil && store.generating) }

    var body: some View {
        VStack(spacing: 0) {
            if let convo = conversation, !convo.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(convo.messages) { msg in
                                let confirmation = assistant == nil ? store.turnConfirmations[msg.id] : nil
                                let confirmationToken = assistant == nil ? store.turnConfirmationTokens[msg.id] : nil
                                MessageRow(message: msg, nativeActions: assistant == nil,
                                           onAnswer: { id, sel, other in store.submitAsk(messageID: id, selections: sel, other: other) },
                                           onOpenArtifact: { store.openArtifact($0) },
                                           attachmentStore: store.attachmentStore,
                                           pendingConfirmation: confirmation,
                                           onToolDecision: { approved in
                                               store.resolveTurnConfirmation(msg.id, approved: approved,
                                                   requestID: confirmation?.id, token: confirmationToken)
                                           })
                            }
                            // One mark per chat at the leading edge — below the last response; animates
                            // while Vera works, sits still when idle. (Like Claude's single mark.)
                            if let assistant { NativePiTaskSection(assistant: assistant) }
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
                    .onChange(of: store.selectedID) { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                if assistant == nil, let status = store.streamStatus {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 28).padding(.bottom, 2)
                }
                if let assistant { NativePiSessionStatus(assistant: assistant).frame(maxWidth: 760).padding(.horizontal, 28) }
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
                ComposerField(assistant: assistant).padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
                    .frame(maxWidth: 760)
            } else if let convo = conversation, convo.isPersisted {
                // A real chat whose history is still loading — skeleton, not the welcome flash.
                ChatLoadingSkeleton()
                ComposerField(assistant: assistant).padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
                    .frame(maxWidth: 760)
            } else {
                EmptyChatView(assistant: assistant)
            }
        }
        .task(id: assistant?.session?.id) {
            guard let session = assistant?.session else { return }
            while !Task.isCancelled {
                await session.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
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
    var assistant: NativePiPresentation? = nil
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore

    private var greeting: String {
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
                ComposerField(assistant: assistant)
                if let assistant {
                    NativePiSessionStatus(assistant: assistant)
                } else if let error = store.chatConfigurationError {
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
    @ObservedObject private var presentation: NativePiPresentation
    private let usesAssistant: Bool
    private var assistant: NativePiPresentation? { usesAssistant ? presentation : nil }
    init(assistant: NativePiPresentation? = nil) {
        _presentation = ObservedObject(wrappedValue: assistant ?? NativePiNativeContext.presentation)
        usesAssistant = assistant != nil
    }
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var voice: VoiceSession
    @EnvironmentObject var config: ConfigStore
    @FocusState private var focused: Bool
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?

    private var route: NativeComposerRoute { NativeComposerRoute(store: store, assistant: assistant) }
    private var draft: Binding<String> {
        Binding(get: { route.draft }, set: { route.draft = $0 })
    }
    private func submit() { route.send() }
    private var canSend: Bool { route.canSend }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if assistant == nil {
                NativeSessionModeControl(mode: store.selectedSessionMode, onSelect: store.setSessionMode)
            }
            if assistant == nil, let error = store.attachmentError {
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
            if assistant == nil && !store.attachments.isEmpty {
                AttachmentsBar(attachments: store.attachments, onRemove: { store.removeAttachment($0) })
            }
            TextField("Message Vera…", text: draft, axis: .vertical)
                .disabled(usesAssistant && assistant?.session == nil)
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
                if assistant == nil {
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
                }
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
                        .foregroundStyle((assistant?.session?.busy ?? (assistant == nil && store.generating)) ? Theme.accentGlow
                                         : (canSend ? Theme.accent : Theme.textSecondary))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            // Hidden ⌘U shortcut for the file picker.
            if assistant == nil {
                Button("", action: pickFiles).keyboardShortcut("u", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(dropTargeted ? Theme.accent : .clear, lineWidth: 2))
        .onAppear {
            focused = true
            if assistant == nil { installPasteMonitor() }
        }
        .onDisappear { removePasteMonitor() }
        .onChange(of: store.focusTick) { _, _ in focused = true }
        .confirmationDialog(
            store.pendingSendDecision?.imageLimit == nil
                ? "This model can't take images" : "Too many images for this model",
            isPresented: Binding(
                get: { assistant == nil && store.pendingSendDecision != nil },
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
                get: { assistant == nil && store.parameterRejection != nil },
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
        guard assistant == nil else { return }
        guard let prompt = store.parameterRejection else { return }
        store.parameterRejection = nil
        config.clearRejectedParameter(model: prompt.model, rejection: prompt.rejection)
        try? config.save()
        if let resolved = config.nativeResolved { store.applyNativeOptions(resolved) }
        store.retryLastTurn(conversationID: prompt.conversationID)
    }

    private func pickFiles() {
        guard assistant == nil else { return }
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
