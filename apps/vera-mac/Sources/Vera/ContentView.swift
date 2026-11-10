import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore
    @State private var search = ""
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @StateObject private var workflowEditor = WorkflowEditorStore()
    @State private var windowWidth: CGFloat = 0

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
        HStack(spacing: 0) {
            VeraSidebar(collapsed: $sidebarCollapsed, search: $search, workflowEditor: workflowEditor, onSelect: select)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            HStack(spacing: 0) {
                Group {
                    switch store.section {
                    case .vera: ChatPane(workCollapsed: companionPlacement == .header)
                    case .chat: ChatPane(workCollapsed: false)
                    case .pulse: PulseView()
                    case .memory: MemoryView()
                    case .agentic: AgenticView(workflowEditor: workflowEditor)
                    case .scheduled: ScheduledView()
                    case .artifacts: ArtifactsView()
                    case .projects: ProjectsView()
                    case .integrations: IntegrationsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.showCanvas, chatSection {
                    Divider()
                    CanvasPanel().frame(width: 480)
                } else if companionPlacement == .beside {
                    CompanionThreadPanel()
                        .frame(width: CompanionThreadPanelMetrics.width)
                } else if chatSection, ConversationPresence.showsWorkPanel(
                    references: store.nativeTaskReferences, conversationID: store.selectedID,
                    wide: wideEnoughForWork, canvasOpen: store.showCanvas) {
                    OngoingWorkPanel(conversationID: store.selectedID, onSelect: store.revealOngoingWork)
                        .frame(width: OngoingWorkMetrics.panelWidth)
                }
            }
            .background(Theme.ink)
        }
        .ignoresSafeArea(.container, edges: .top)
        .task { await store.connect() }
        .modifier(CompanionAttentionWindow())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .environment(\.inspectMemorySource, { store.inspectMemoryCitation($0) })
        .sheet(item: $store.inspectedMemory) { MemoryDetailView(memory: $0, citedRevision: store.inspectedMemoryRevision, trace: store.inspectedMemoryTrace) }
        .sheet(isPresented: $config.showOnboarding) { OnboardingSheet() }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { store.pendingConversationDeletion != nil },
                set: { if !$0 { store.cancelDeleteConversation() } }),
            titleVisibility: .visible,
            presenting: store.pendingConversationDeletion
        ) { _ in
            Button("Keep artifacts") { store.confirmDeleteConversation(.keep) }
            Button("Delete artifacts too", role: .destructive) { store.confirmDeleteConversation(.delete) }
            Button("Cancel", role: .cancel) { store.cancelDeleteConversation() }
        } message: { pending in
            Text(Self.deletionMessage(pending.artifactCount))
        }
    }

    private var chatSection: Bool { store.section == .chat || store.section == .vera }
    private var companionPlacement: CompanionPanelPlacement {
        CompanionPanelPlacement.decide(isCompanionThread: store.section == .vera && store.isVeraThread(store.selectedID),
                                       windowWidth: windowWidth, canvasShowing: store.showCanvas)
    }
    private var wideEnoughForWork: Bool { windowWidth >= OngoingWorkMetrics.minimumWindowWidth }

    private var deletionTitle: String {
        "Delete \u{201C}\(store.pendingConversationDeletion?.title ?? "chat")\u{201D}?"
    }

    static func deletionMessage(_ count: Int) -> String {
        let noun = count == 1 ? "an artifact" : "\(count) artifacts"
        let pronoun = count == 1 ? "it" : "them"
        return "This chat produced \(noun). You can keep \(pronoun) in Library or delete \(pronoun) with the chat."
    }
}

struct SidebarRow: View {
    @EnvironmentObject var store: ChatStore
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
        if !store.projects.isEmpty {
            Menu("Move to project") {
                ForEach(store.projects) { project in
                    Button {
                        store.moveConversation(convo.id, toProject: project.id)
                    } label: {
                        if convo.projectID == project.id {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            }
        }
        if convo.projectID != nil {
            Button("Remove from project") { store.moveConversation(convo.id, toProject: nil) }
        }
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
    var workCollapsed = false
    @EnvironmentObject var config: ConfigStore
    private var conversation: Conversation? {
        if store.section == .vera { return store.conversations.first { $0.id == store.veraThreadID } }
        return store.selected
    }
    @State private var highlightedMessageID: UUID?
    @State private var highlightVisible = false
    @State private var showingWork = false
    @State private var openedWorkReport: NativeResearchArtifact?
    @State private var revealTask: Task<Void, Never>?
    @State private var revealConversationID: String?
    @StateObject private var transcriptContinuity = CompanionTranscriptContinuity()

    private func cancelTaskReveal() {
        revealTask?.cancel()
        revealTask = nil
        revealConversationID = nil
        store.highlightedTaskID = nil
    }

    private func revealPendingTask(_ proxy: ScrollViewProxy) {
        guard let taskID = store.pendingTaskReveal, let convo = conversation, !convo.messages.isEmpty,
              let reference = store.nativeTaskReferences.first(where: { $0.id.uuidString == taskID }),
              reference.origin.conversationID == convo.id else { return }
        store.pendingTaskReveal = nil
        guard let owner = OngoingWork.owningMessageID(taskID: taskID, fallback: reference.origin.assistantMessageID,
                                                      in: convo.messages) else { return }
        let artifact = OngoingWork.item(reference).artifact
        let origin = convo.id
        let generation = store.taskRevealGeneration
        cancelTaskReveal()
        revealConversationID = origin
        revealTask = Task { @MainActor in
            @MainActor func applies() -> Bool {
                OngoingWork.revealApplies(origin: origin, selectedConversationID: store.selectedID, generation: generation,
                                          latestGeneration: store.taskRevealGeneration, cancelled: Task.isCancelled)
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard applies() else { return }
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(owner, anchor: .center) }
            store.highlightedTaskID = taskID
            var remaining = Duration.seconds(2)
            if let artifact {
                try? await Task.sleep(for: .milliseconds(350))
                guard applies() else { return }
                remaining -= .milliseconds(350)
                openedWorkReport = artifact
            }
            try? await Task.sleep(for: remaining)
            guard applies() else { return }
            if store.highlightedTaskID == taskID { store.highlightedTaskID = nil }
            revealTask = nil
            revealConversationID = nil
        }
    }

    private func refreshCompanionOpening() {
        if store.section == .vera {
            store.prepareCompanionThread()
            if store.selectedID != store.veraThreadID { store.openVeraThread() }
        } else if store.isVeraThread(conversation?.id) {
            store.prepareCompanionOpening()
        }
    }

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

    private var showsHeader: Bool {
        guard let convo = conversation else { return false }
        return !convo.messages.isEmpty || (convo.isPersisted && !store.isVeraThread(convo.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader, ConversationPresence.headerKind(companionThread: store.isVeraThread(conversation?.id)) == .conversation {
                ConversationHeader(name: ConversationPresence.headerTitle(conversationTitle: conversation?.title), status: store.conversationStatusLine)
            }
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
                .frame(maxWidth: ConversationMetrics.columnWidth)
                .padding(.horizontal, 28).padding(.top, showsHeader ? 10 : 36)
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
                                           onToolDecision: { decision in
                                               store.resolveTurnConfirmation(msg.id, decision: decision,
                                                   requestID: confirmation?.id, token: confirmationToken)
                                           },
                                           companionThread: store.isVeraThread(convo.id))
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Theme.accent.opacity(highlightedMessageID == msg.id && highlightVisible ? 0.14 : 0))
                                            .padding(-8))
                                    .id(msg.id)
                                if msg.role == .user, let marker = store.preferenceMarker(for: msg, in: convo.id) {
                                    TranscriptMarkerRow(marker: marker)
                                        .id("\(msg.id.uuidString)-marker")
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 26)
                        .frame(maxWidth: ConversationMetrics.columnWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onScrollPhaseChange { _, phase in
                        transcriptContinuity.scrollPhaseChanged(phase)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
                    } action: { _, nearBottom in
                        if store.isVeraThread(convo.id) { transcriptContinuity.observe(nearBottom: nearBottom, conversationID: convo.id) }
                    }
                    .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0) { visible in
                        if store.isVeraThread(convo.id) {
                            transcriptContinuity.observe(visible: visible, ordered: convo.messages.map(\.id), conversationID: convo.id)
                        }
                    }
                    .onChange(of: convo.messages.last?.text ?? "") {
                        if !store.isVeraThread(convo.id) || transcriptContinuity.shouldFollowLatest { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: convo.messages.count) {
                        if store.isVeraThread(convo.id) {
                            if transcriptContinuity.shouldFollowLatest { proxy.scrollTo("bottom", anchor: .bottom) }
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
                    .onChange(of: store.pendingHighlightMessageID) { revealPendingSource(proxy) }
                    .onChange(of: store.pendingTaskReveal) { revealPendingTask(proxy) }
                    .task(id: convo.id) {
                        store.refreshPreferenceMarkers(conversationID: convo.id)
                        let companion = store.isVeraThread(convo.id)
                        let anchor = companion ? transcriptContinuity.begin(conversationID: convo.id, messages: convo.messages.map(\.id)) : nil
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                        else { proxy.scrollTo("bottom", anchor: .bottom) }
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        if companion { transcriptContinuity.finishRestoring(conversationID: convo.id) }
                        revealPendingSource(proxy)
                        revealPendingTask(proxy)
                    }
                    .sheet(item: $openedWorkReport) { NativeResearchReportView(artifact: $0) }
                }
                if convo.isPersisted, store.isPulseConfigured {
                    HStack(spacing: 12) {
                        KnowledgeGroundingChip(conversation: convo)
                        Spacer()
                    }
                    .frame(maxWidth: ConversationMetrics.columnWidth)
                    .padding(.horizontal, 28).padding(.top, 4)
                }
                ComposerField().padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
                    .frame(maxWidth: ConversationMetrics.columnWidth)
            } else if store.section == .vera || store.isVeraThread(conversation?.id) {
                CompanionOpeningView(error: store.companionOpeningError,
                                     needsConnection: store.repository != nil && !store.pendingProfileAvailable,
                                     canRetry: store.repository != nil) {
                    store.chatConfigurationError = nil
                    store.prepareCompanionThread()
                    store.openVeraThread()
                }
                ComposerField().padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
                    .frame(maxWidth: ConversationMetrics.columnWidth)
            } else if let convo = conversation, convo.isPersisted, !store.isVeraThread(convo.id) {
                ChatLoadingSkeleton()
                ComposerField().padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
                    .frame(maxWidth: ConversationMetrics.columnWidth)
            } else {
                EmptyChatView()
            }
        }
        .background(Theme.conversationBackground)
        .onChange(of: store.selectedID) {
            if let revealConversationID, revealConversationID != store.selectedID { cancelTaskReveal() }
            refreshCompanionOpening()
        }
        .overlay(alignment: .topTrailing) {
            if workCollapsed, store.isVeraThread(conversation?.id) {
                Button { showingWork = true } label: {
                    HStack(spacing: 8) {
                        CompanionAvatar(size: 18)
                        Text("Details").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.warmTextPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.cardFill))
                    .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(store.assistantName)'s state, activity and results")
                .accessibilityLabel("Details for \(store.assistantName)")
                .padding(.top, 44).padding(.trailing, 20)
            }
        }
        .sheet(isPresented: $showingWork) {
            if store.isVeraThread(conversation?.id) {
                CompanionThreadPanel(onClose: { showingWork = false })
                    .frame(width: 420, height: 640)
                    .environmentObject(store)
                    .environmentObject(config)
            }
        }
        .onAppear(perform: refreshCompanionOpening)
        .onChange(of: store.dotProfile) { refreshCompanionOpening() }
        .onChange(of: workCollapsed) { _, collapsed in
            if !collapsed, store.isVeraThread(conversation?.id) { showingWork = false }
        }
        .onChange(of: store.dotProfileLoaded) { refreshCompanionOpening() }
    }
}

struct ConversationHeader: View {
    let name: String
    let status: String
    var companionThread = false

    var body: some View {
        HStack(spacing: 12) {
            ConversationFigureView(figure: ConversationPresence.headerFigure(companionThread: companionThread),
                                   size: ConversationMetrics.avatarSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: ConversationMetrics.headerNameSize, weight: .semibold))
                    .foregroundStyle(Theme.warmTextPrimary)
                    .lineLimit(1)
                if ConversationPresence.headerShowsStatus(companionThread: companionThread) {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.statusGreen).frame(width: 7, height: 7)
                        Text(status)
                            .font(.system(size: ConversationMetrics.metaSize))
                            .foregroundStyle(Theme.warmTextSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: ConversationMetrics.columnWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.top, 36).padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
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

struct EmptyChatView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore

    private var project: ProjectRecord? { store.selectedID.flatMap(store.projectForConversation) }

    private var greeting: String {
        if project != nil { return "What should we work on?" }
        if store.isVeraThread(store.selectedID) { return "What are we working on?" }
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "morning" : (h < 18 ? "afternoon" : "evening")
        guard let name = config.ownerName else { return "Good \(part)" }
        return "Good \(part), \(name)"
    }

    private let starters = [
        "What's on today?", "What's the weather?", "Research a topic for me",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                HStack(spacing: 14) {
                    if project == nil {
                        ConversationFigureView(figure: ConversationPresence.greetingFigure(companionThread: store.isVeraThread(store.selectedID)), size: 56)
                    }
                    Text(greeting).font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.warmTextPrimary)
                }
                ComposerField()
                if let error = store.chatConfigurationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else if store.isLive && project == nil {
                    FlowChips(items: starters) { s in store.draft = s; store.focusTick &+= 1 }
                } else if !store.isLive {
                    Button { config.showOnboarding = true } label: {
                        Label("\(store.conversationAssistantName) isn't connected. Set up the connection", systemImage: "bolt.horizontal")
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
        .background(Theme.conversationBackground)
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
        Text(title).font(.system(size: 13)).foregroundStyle(Theme.warmTextPrimary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Theme.cardFill))
            .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
    }
}

enum ComposerControlKind {
    case plus, voice, dictate(active: Bool), send(active: Bool, generating: Bool), stop(enabled: Bool)
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
    static let plusSize: CGFloat = 30
    static let sendSize: CGFloat = 32

    private var fill: Color {
        switch kind {
        case .plus: Theme.assistantBubble
        case .voice: Theme.surfaceHover
        case .dictate(let active): active ? Theme.sage : Theme.surfaceHover
        case .send(let active, let generating): generating || active ? Theme.sage : Theme.sage.opacity(0.35)
        case .stop(let enabled): enabled ? Theme.sage : Theme.sage.opacity(0.35)
        }
    }

    private var tint: Color {
        switch kind {
        case .plus: Theme.warmTextSecondary
        case .voice: Theme.textSecondary
        case .dictate(let active): active ? Theme.onSage : Theme.textSecondary
        case .send, .stop: Theme.onSage
        }
    }

    private var diameter: CGFloat {
        switch kind {
        case .plus: Self.plusSize
        case .voice, .dictate: Self.size
        case .send, .stop: Self.sendSize
        }
    }

    private var symbol: String {
        switch kind {
        case .plus: "plus"
        case .voice: "waveform"
        case .dictate(let active): active ? "mic.fill" : "mic"
        case .send: "arrow.up"
        case .stop: "stop.fill"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: { if case .stop = kind { 12 } else { 15 } }(), weight: { if case .send = kind { .semibold } else { .medium } }()))
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill))
            .frame(width: Self.sendSize, height: Self.sendSize)
            .contentShape(Rectangle())
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
    var onToolDecision: ((NativeCardChoiceKind) -> Void)? = nil
    var companionThread = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                if ConversationPresence.replyFigure(companionThread: companionThread) == .companion {
                    CompanionAvatar(size: ConversationMetrics.replyAvatarSize)
                        .padding(.top, 4)
                }
                VStack(alignment: .leading, spacing: 8) {
                    AssistantBody(message: message, section: .bubble, companionThread: companionThread, nativeActions: nativeActions, onAnswer: onAnswer, onOpenArtifact: onOpenArtifact)
                    ForEach(NativeTaskTranscript.visibleActivities(in: message)) { activity in
                        let awaiting = pendingConfirmation?.id == activity.id
                        switch NativeToolActivityPresentation.forActivity(activity) {
                        case .chip:
                            NativeToolActivityChip(activity: activity, awaitingDecision: awaiting,
                                onCancel: nativeActions && activity.isCancelableRun ? { store.cancelToolRun(message.id) } : nil)
                        case .imagePlaceholder:
                            ImageGenerationPlaceholder(activity: activity,
                                onCancel: nativeActions ? { store.cancelToolRun(message.id) } : nil)
                        case .hidden:
                            EmptyView()
                        }
                        if let pendingConfirmation, awaiting {
                            NativeToolConfirmationBar(
                                request: pendingConfirmation,
                                prompt: NativeToolConfirmationBar.prompt(for: pendingConfirmation),
                                detail: NativeToolConfirmationBar.detail(for: pendingConfirmation, assistantName: CompanionSentence.placeholder),
                                actor: companionThread ? CompanionSentence.placeholder : "Tandem",
                                onDecision: { onToolDecision?($0 ? .allowOnce : .decline) },
                                onChoice: { onToolDecision?($0) })
                        }
                    }
                    AssistantBody(message: message, section: .extras, nativeActions: nativeActions, onAnswer: onAnswer, onOpenArtifact: onOpenArtifact)
                    ForEach(message.attachments.filter(\.isImage)) { attachment in
                        GeneratedImageView(attachment: attachment, store: attachmentStore)
                    }
                    if nativeActions && !message.displayBlocks.isEmpty {
                        NativeDisplayBlocksView(blocks: message.displayBlocks,
                            connectedTaskIDs: store.connectedNativeTaskIDs,
                            onCancel: store.cancelNativeTask, onRetry: store.retryNativeTask,
                            onDecide: store.answerNativeTask,
                            onSaveAnswer: store.saveNativeTaskAnswer,
                            highlightedTaskID: store.highlightedTaskID)
                    }
                    if nativeActions && store.isQueuedAnswer(message.id) {
                        NativeAnswerControls(status: "Waiting to answer", canStop: true, stopLabel: "Cancel",
                                             onStop: { store.stopAnswer(message.id, reason: "Canceled.") })
                    } else if nativeActions, let note = store.answerNote(message.id) {
                        Text(note).font(.system(size: ConversationMetrics.metaSize)).foregroundStyle(Theme.warmTextSecondary)
                    } else if nativeActions, let status = store.replyStatus(message.id) {
                        Text(status).font(.system(size: ConversationMetrics.metaSize)).foregroundStyle(Theme.warmTextSecondary)
                    }
                    if nativeActions && message.state == .interrupted {
                        Label(message.failure ?? "The response was interrupted", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Theme.warmTextSecondary)
                        Button("Retry answer") { store.retryAnswer(message.id) }
                            .buttonStyle(.borderless).font(.system(size: 11))
                    }
                    AssistantBody(message: message, section: .actions, nativeActions: nativeActions, onAnswer: onAnswer, onOpenArtifact: onOpenArtifact)
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.attachments.isEmpty {
                        SentAttachmentsBar(attachments: message.attachments, store: attachmentStore)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: ConversationMetrics.bodySize)).textSelection(.enabled)
                            .foregroundStyle(Theme.warmTextPrimary)
                            .padding(.horizontal, ConversationMetrics.bubblePaddingH)
                            .padding(.vertical, ConversationMetrics.bubblePaddingV)
                            .background(Theme.userBubble)
                            .clipShape(RoundedRectangle(cornerRadius: ConversationMetrics.bubbleRadius, style: .continuous))
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
    var awaitingDecision = false
    var onCancel: (() -> Void)? = nil
    @State private var expanded = false

    static let declineMarkers = ["The user did not approve this call", "The user already declined"]

    static func isDeclined(_ activity: NativeToolActivity) -> Bool {
        guard activity.state == .failed, let result = activity.result else { return false }
        return declineMarkers.contains { result.contains($0) }
    }

    private var declined: Bool { Self.isDeclined(activity) }

    private var icon: String {
        if declined { return "hand.raised.slash" }
        switch activity.state {
        case .pending: return "clock"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .canceled: return "slash.circle"
        }
    }

    private var status: String {
        if declined { return "Declined" }
        switch activity.state {
        case .pending: return awaitingDecision ? "Waiting for you" : (activity.progress?.label ?? "Working")
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }

    private var iconColor: Color {
        if declined { return Theme.warmTextSecondary }
        switch activity.state {
        case .failed: return Color.orange
        case .pending: return Theme.sage
        default: return Theme.warmTextSecondary
        }
    }

    private var showsConfirmationTag: Bool {
        activity.confirmationRequired && activity.state == .pending && awaitingDecision
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
                Text(status).font(.system(size: 11)).foregroundStyle(Theme.warmTextSecondary)
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
            .foregroundStyle(Theme.warmTextPrimary)
        }
        .disclosureGroupStyle(.automatic)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: 480, alignment: .leading)
        .background(Theme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
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
    var detail: String? = nil
    var actor = "Tandem"
    var defaultApproval = true
    var allowApprove = true
    var allowDecline = true
    var onDecision: (Bool) -> Void
    var onChoice: ((NativeCardChoiceKind) -> Void)? = nil
    @Environment(\.renderSafe) private var renderSafe

    static func prompt(for request: NativeToolConfirmationRequest) -> String? {
        if let prompt = NativeCompanionProfileTools.prompt(request) { return prompt }
        return nil
    }

    static func detail(for request: NativeToolConfirmationRequest, assistantName: String = "") -> String? {
        nil
    }

    static func sentence(for request: NativeToolConfirmationRequest, actor: String) -> String {
        NativeCardChoices.sentence(actor: actor, subject: request.subject, title: request.title)
    }

    static func literal(for request: NativeToolConfirmationRequest) -> String? {
        if request.toolID == NativeCommandTools.toolID, let command = NativeCommandTools.command(inRequest: request.request) {
            return NativeCommandTools.directory(inRequest: request.request).map { command + "\nin " + $0 } ?? command
        }
        if request.toolID == NativeFolderTools.toolID, let path = NativeFolderTools.pathArgument(inRequest: request.request) { return path }
        if request.toolID == NativeScheduleTools.toolID, let draft = NativeScheduleTools.draft(inRequest: request.request) {
            return NativeScheduleTools.literal(for: draft)
        }
        let lines = NativeCompanionWorker.details(request.title, argumentsJSON: request.request)
        return lines.isEmpty ? nil : lines
    }

    static func closing(for request: NativeToolConfirmationRequest) -> String? {
        guard request.toolID == NativeScheduleTools.toolID, let draft = NativeScheduleTools.draft(inRequest: request.request) else { return nil }
        return NativeScheduleTools.destination(for: draft)
    }

    private var answers: CardAnswers {
        var built = onChoice == nil ? CardAnswers() : CardAnswers.chat(request)
        if request.subject == nil { built.allowTitle = "Approve" }
        return built
    }

    private var block: String? {
        if let prompt {
            let rest = prompt.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            return rest.isEmpty ? nil : rest
        }
        return Self.literal(for: request)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.sage)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.sage.opacity(0.16)))
                VStack(alignment: .leading, spacing: 6) {
                    CompanionNamedText(template: prompt?.components(separatedBy: "\n").first ?? Self.sentence(for: request, actor: actor))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warmTextPrimary)
                    if let block {
                        ShotSafeScroll(renderSafe: renderSafe, axis: .vertical) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(block)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if prompt == nil, let closing = Self.closing(for: request) {
                                    CompanionNamedText(template: closing)
                                }
                            }
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.warmTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: renderSafe ? nil : 180)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.conversationBackground))
                    }
                    if let detail {
                        CompanionNamedText(template: detail)
                            .font(.system(size: ConversationMetrics.metaSize)).foregroundStyle(Theme.warmTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            CardAnswerRow(answers: answers, defaultApproval: defaultApproval, allowApprove: allowApprove, allowDecline: allowDecline,
                          onAllow: { onDecision(true) }, onDecline: { onDecision(false) },
                          onItem: { id in if let kind = NativeCardChoiceKind(rawValue: id) { onChoice?(kind) } })
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous)
            .stroke(Theme.cardStroke, lineWidth: 1))
    }
}

struct ConversationButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        ConversationButtonBody(kind: kind, label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct ConversationButtonBody: View {
    let kind: ConversationButtonStyle.Kind
    let label: ButtonStyleConfiguration.Label
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(kind == .primary ? Theme.onSage : Theme.warmTextPrimary)
            .padding(.horizontal, 14).frame(height: 28)
            .background(Capsule().fill(kind == .primary ? Theme.sage : Color.clear))
            .overlay(Capsule().stroke(kind == .primary ? Color.clear : Theme.cardStroke, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled ? (pressed ? 0.8 : 1) : 0.45)
    }
}

struct SageCapsuleLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.onSage)
            .padding(.horizontal, 14).frame(height: 28)
            .background(Capsule().fill(Theme.sage))
    }
}

struct ArtifactChip: View {
    let artifact: Artifact
    var detail: String? = nil

    static func displayTitle(_ artifact: Artifact) -> String {
        let title = artifact.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        switch artifact.type {
        case .markdown: return "Document"
        case .code: return "Code"
        case .html: return "Web page"
        case .svg: return "Image"
        case .mermaid: return "Diagram"
        case .unknown: return "Result"
        }
    }

    var body: some View {
        ConversationResultRow(title: Self.displayTitle(artifact), action: detail ?? "Open")
    }
}

struct ConversationResultRow: View {
    let title: String
    var action: String = "Open"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.warmTextSecondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.warmTextPrimary)
                .lineLimit(3)
            Spacer(minLength: 12)
            SageCapsuleLabel(title: action)
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 10)
        .frame(maxWidth: 480, alignment: .leading)
        .background(Theme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous)
            .stroke(Theme.cardStroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous))
    }
}

// MARK: - Composer

struct ComposerField: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore
    @FocusState private var focused: Bool
    @State private var editingProject: ProjectRecord?
    @State private var managingProjectFiles: ProjectRecord?
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?
    @State private var mentionSelectionID: String?
    @State private var dismissedDraft: String?
    @State private var showingFolderUnsupported = false

    private var route: NativeComposerRoute { NativeComposerRoute(store: store, assistant: nil) }
    private var draft: Binding<String> {
        Binding(get: { route.draft }, set: { route.draft = $0 })
    }
    private func submit() {
        route.send()
    }
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

    private var project: ProjectRecord? { store.selectedID.flatMap(store.projectForConversation) }

    var body: some View {
        VStack(spacing: 0) {
            composer
            if let project {
                HStack(spacing: 18) {
                    Button { editingProject = project } label: {
                        Label(project.name, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    }.accessibilityLabel("Edit project \(project.name)").help(project.name)
                    Menu {
                        Button("Add files to this chat", action: pickFiles)
                        Button("Work in a folder…", action: pickFolder)
                        Button("Manage project files") { managingProjectFiles = project }
                    } label: {
                        Label("Files", systemImage: "doc.on.doc")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Files for \(project.name)")
                    Button { store.section = .integrations } label: {
                        Label("Plugins", systemImage: "puzzlepiece.extension")
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13)).foregroundStyle(Theme.textPrimary).buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Theme.surface, in: UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
                .padding(.horizontal, 12)
            }
        }
        .sheet(item: $editingProject) { ProjectEditor(project: $0) }
        .sheet(item: $managingProjectFiles) { ProjectFilesEditor(projectID: $0.id) }
    }

    private var composer: some View {
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
            HStack(alignment: .bottom, spacing: 8) {
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
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: ComposerControlGlyph.sendSize, height: ComposerControlGlyph.sendSize)
                .contentShape(Rectangle())
                .help("Add files, grant a folder, or insert a saved prompt")
                .accessibilityLabel("Add attachments")
                TextField("Message \(store.conversationAssistantName)", text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: ConversationMetrics.bodySize))
                    .foregroundStyle(Theme.warmTextPrimary)
                    .lineLimit(project != nil && store.selected?.messages.isEmpty == true ? 3...8 : 1...8)
                    .focused($focused)
                    .padding(.vertical, 6)
                    .frame(minHeight: ComposerControlGlyph.sendSize)
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
        }
        .background {
            Button("", action: pickFiles).keyboardShortcut("u", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: ConversationMetrics.composerRadius, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: ConversationMetrics.composerRadius, style: .continuous)
            .stroke(dropTargeted ? Theme.accent : Theme.cardStroke, lineWidth: dropTargeted ? 2 : 1))
        .onAppear {
            focused = true
            installPasteMonitor()
        }
        .onDisappear {
            removePasteMonitor()
        }
        .modifier(CompanionComposerAttention(focused: focused, draft: store.draft))
        .onChange(of: store.focusTick) { _, _ in focused = true }
        .onChange(of: store.grantConsentTick) { _, _ in
            let missing = [NativeFolderTools.toolID, NativeCommandTools.toolID].filter { !config.nativeSettings.enabledToolIDs.contains($0) }
            guard !missing.isEmpty else { return }
            for id in missing { config.setNativeTool(id, enabled: true) }
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
