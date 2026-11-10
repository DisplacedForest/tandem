import SwiftUI

enum SidebarMetrics {
    static let rowHeight: CGFloat = 28
    static let iconSize: CGFloat = 15
    static let iconSlot: CGFloat = 18
    static let inset: CGFloat = 8
    static let labelSize: CGFloat = 13
    static let radius: CGFloat = 6
    static let spacing: CGFloat = 1
}

struct SidebarRowStyle: ButtonStyle {
    var selected = false

    static func fill(selected: Bool, hovering: Bool, pressed: Bool) -> Color {
        if pressed || selected { return Theme.surfaceSelected }
        if hovering { return Theme.surfaceHover }
        return .clear
    }

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous)
                    .fill(Self.fill(selected: selected, hovering: hovering, pressed: configuration.isPressed)))
                .contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous))
                .onHover { hovering = $0 }
                .onChange(of: selected) { _, _ in hovering = false }
        }

        private static func fill(selected: Bool, hovering: Bool, pressed: Bool) -> Color {
            SidebarRowStyle.fill(selected: selected, hovering: hovering, pressed: pressed)
        }
    }
}

struct SidebarRowLabel<Icon: View>: View {
    let icon: Icon
    let title: String
    var selected = false
    var collapsed = false
    var tintsIcon = true
    var rowHeight: CGFloat = SidebarMetrics.rowHeight

    var body: some View {
        HStack(spacing: SidebarMetrics.inset) {
            icon
                .font(.system(size: SidebarMetrics.iconSize, weight: .medium))
                .foregroundStyle(tintsIcon && selected ? Theme.accent : Theme.textSecondary)
                .frame(width: SidebarMetrics.iconSlot, height: SidebarMetrics.iconSlot)
            if !collapsed {
                Text(title).font(.system(size: SidebarMetrics.labelSize, weight: selected ? .medium : .regular))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    .transition(.opacity)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, collapsed ? 0 : SidebarMetrics.inset)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
    }
}

struct SidebarSectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SidebarMetrics.inset).padding(.top, 14).padding(.bottom, 4)
    }
}

struct SidebarChatRowLabel<Trailing: View>: View {
    let title: String
    var selected = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: SidebarMetrics.inset) {
            Text(title).font(.system(size: SidebarMetrics.labelSize)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, SidebarMetrics.inset)
        .frame(height: SidebarMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SidebarFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, SidebarMetrics.inset)
            .frame(height: SidebarMetrics.rowHeight)
            .background(RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct VeraSidebar: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore
    @Environment(\.renderSafe) private var renderSafe
    @State private var showingCompanionSettings = false
    @State private var expandedProjects: Set<String> = []
    @State private var projectName = ""
    @State private var creatingProject = false
    @Binding var collapsed: Bool
    @Binding var search: String
    @ObservedObject var workflowEditor: WorkflowEditorStore
    let onSelect: (AppSection) -> Void
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    static let railWidth: CGFloat = 56
    static let contextWidth: CGFloat = 244
    static let expandedWidth = railWidth + contextWidth
    static let collapsedWidth = railWidth
    static let topInset: CGFloat = 40

    private var paletteOpen: Bool { store.section == .agentic && store.agenticFlowID != nil }
    private var wide: Bool { !collapsed || paletteOpen }
    private var showsSearch: Bool { searching || !search.isEmpty }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 0) {
            globalRail
            if wide {
                Rectangle().fill(Theme.hairline).frame(width: 1)
                VStack(spacing: 0) {
                    if paletteOpen {
                        WorkflowPalette(store: workflowEditor, searchText: $search) { store.agenticFlowID = nil }
                            .padding(.top, Self.topInset)
                    } else {
                        contextColumn
                    }
                    if !renderSafe { UpdateBanner() }
                }
                .frame(width: Self.contextWidth - 1)
                .background(Theme.sidebar)
            }
        }
        .frame(width: wide ? Self.expandedWidth : Self.collapsedWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .animation(.easeInOut(duration: 0.18), value: wide)
        .onAppear { revealSelectedProject() }
        .onChange(of: store.selectedID) { _, _ in revealSelectedProject() }
        .alert("New project", isPresented: $creatingProject) {
            TextField("Project name", text: $projectName)
            Button("Create") {
                store.clearProjectError()
                if let project = store.createProject(name: projectName) { expandedProjects.insert(project.id) }
                else if store.projectError == nil { store.projectError = "The project couldn't be created. Try again." }
            }.disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var globalRail: some View {
        VStack(spacing: 10) {
            ForEach(SidebarDestination.primary) { destination in
                railButton(destination.title, icon: destination.icon,
                           selected: destination.isRailSelected(section: store.section, pane: store.agenticPane)) { go(destination) }
            }
            if renderSafe { railGlyph("ellipsis", selected: moreSelected) }
            else { moreMenu }
            Spacer(minLength: 12)
            if collapsed {
                railButton("New chat", icon: "square.and.pencil") { store.newConversation() }
                railButton("Search chats", icon: "magnifyingglass") { collapsed = false; openSearch() }
                railButton(store.companion.leading, icon: "bubble.left") { onSelect(.vera) }
                if !renderSafe { CompactUpdateBadge { collapsed = false } }
            }
            collapseToggle
            if renderSafe { railGlyph("gearshape", selected: false) }
            else {
                SettingsLink { railGlyph("gearshape", selected: false) }
                    .buttonStyle(SidebarRowStyle())
                    .help("Settings").accessibilityLabel("Settings")
            }
        }
        .padding(.top, Self.topInset + 8).padding(.bottom, 12)
        .frame(width: Self.railWidth)
        .background(Theme.bg)
    }

    private func railGlyph(_ icon: String, selected: Bool) -> some View {
        Image(systemName: icon).font(.system(size: 19, weight: .regular))
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .frame(width: 38, height: 38)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func railButton(_ title: String, icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        if renderSafe {
            railGlyph(icon, selected: selected)
                .background(RoundedRectangle(cornerRadius: SidebarMetrics.radius).fill(selected ? Theme.surfaceSelected : .clear))
        } else {
            Button(action: action) { railGlyph(icon, selected: selected) }
                .buttonStyle(SidebarRowStyle(selected: selected))
                .help(title).accessibilityLabel(title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
    }

    private var contextColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Tandem").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Button { toggleSearch() } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary).frame(width: 28, height: 28)
                }
                .buttonStyle(SidebarRowStyle(selected: showsSearch))
                .help("Search chats").accessibilityLabel("Search chats")
            }
            .padding(.horizontal, 8).padding(.bottom, 10)
            actionRow(icon: "square.and.pencil", title: "New chat") { store.newConversation() }
            companionRow
            if showsSearch { searchField.padding(.top, 6) }
            if renderSafe {
                navigationContents
                Spacer(minLength: 0)
            } else {
                ScrollView { navigationContents }
            }
        }
        .padding(.horizontal, 8).padding(.top, Self.topInset + 8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var navigationContents: some View {
        VStack(alignment: .leading, spacing: SidebarMetrics.spacing) {
            HStack(spacing: 4) {
                SidebarSectionHeader(title: "Projects")
                Button { projectName = ""; creatingProject = true } label: {
                    Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(SidebarRowStyle()).help("New project").accessibilityLabel("New project")
                .padding(.top, 10)
            }
            ForEach(store.projects.filter { project in
                query.isEmpty || project.name.localizedCaseInsensitiveContains(query)
                    || store.projectConversations(project.id).contains { $0.title.localizedCaseInsensitiveContains(query) }
            }) { project in
                projectRow(project)
                if expandedProjects.contains(project.id) || !query.isEmpty || renderSafe {
                    ForEach(store.projectConversations(project.id).filter {
                        query.isEmpty || project.name.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)
                    }) { conversation in
                        chatRow(conversation).padding(.leading, 22)
                    }
                }
            }
            if let error = store.projectError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(8)
            }
            ForEach(recentGroups) { group in
                SidebarSectionHeader(title: group.title == "Today" ? "Recents" : group.title)
                ForEach(group.convos) { chatRow($0) }
            }
        }
        .padding(.bottom, 12)
    }

    private var recentGroups: [ChatStore.SidebarGroup] {
        let projects = Set(store.projects.map(\.id))
        return store.sidebarGroups(search: search).compactMap { group in
            let conversations = group.convos.filter { $0.projectID.map { !projects.contains($0) } ?? true }
            return conversations.isEmpty ? nil : ChatStore.SidebarGroup(title: group.title, convos: conversations)
        }
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        SidebarProjectRow(project: project, expanded: expandedProjects.contains(project.id) || renderSafe,
                          selected: store.selected?.projectID == project.id && store.section == .chat,
                          onExpand: {
                              if expandedProjects.contains(project.id) { expandedProjects.remove(project.id) }
                              else { expandedProjects.insert(project.id) }
                          }, onNewChat: {
                              expandedProjects.insert(project.id)
                              store.newConversation(inProject: project.id)
                          })
    }

    private func revealSelectedProject() {
        if let id = store.selected?.projectID { expandedProjects.insert(id) }
    }

    private var collapseToggle: some View {
        railButton(collapsed ? "Expand sidebar" : "Collapse sidebar", icon: "sidebar.left") { collapsed.toggle() }
    }

    private var moreSelected: Bool {
        SidebarDestination.secondary.filter { $0 != .projects }.contains { $0.isSelected(section: store.section, pane: store.agenticPane) }
    }

    private var moreMenu: some View {
        Menu {
            ForEach(SidebarDestination.secondary) { destination in
                Button { go(destination) } label: { Label(destination.title, systemImage: destination.icon) }
            }
        } label: {
            railGlyph("ellipsis", selected: moreSelected)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More").accessibilityLabel("More destinations")
    }

    private var companionRow: some View {
        let selected = store.section == .vera
        return Button { onSelect(.vera) } label: {
            SidebarRowLabel(icon: CompanionAvatar(size: 20), title: store.companion.leading, selected: selected,
                            tintsIcon: false, rowHeight: 34)
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .help(store.companion.leading).accessibilityLabel(store.companion.leading)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button(store.isDotPaused ? "Resume" : "Pause") { store.setDotState(store.isDotPaused ? .active : .paused) }
            Button("Companion settings") { showingCompanionSettings = true }
        }
        .sheet(isPresented: $showingCompanionSettings) {
            DotSettingsView().environmentObject(store).environmentObject(config)
        }
    }

    private func toggleSearch() {
        if showsSearch { search = ""; searching = false; searchFocused = false }
        else { openSearch() }
    }

    private func openSearch() {
        searching = true
        DispatchQueue.main.async { searchFocused = true }
    }

    private func go(_ destination: SidebarDestination) {
        switch destination {
        case .chats: onSelect(.chat)
        case .projects: onSelect(.projects)
        case .library: onSelect(.artifacts)
        case .scheduled: onSelect(.scheduled)
        case .integrations: onSelect(.integrations)
        case .pulse: onSelect(.pulse)
        case .workflows: openAgentic(.canvas)
        case .activity: openAgentic(.activity)
        case .memory: onSelect(.memory)
        }
    }

    private func openAgentic(_ pane: AgenticPane) {
        store.section = .agentic
        store.agenticPane = pane
        store.agenticFlowID = nil
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextField("Search chats", text: $search).textFieldStyle(.plain).font(.system(size: SidebarMetrics.labelSize))
                .focused($searchFocused)
                .onExitCommand { search = ""; searching = false; searchFocused = false }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel("Clear search")
            }
        }
        .modifier(SidebarFieldChrome()).padding(.bottom, 2)
    }

    private func chatRow(_ conversation: Conversation) -> some View {
        let selected = store.section == .chat && store.selectedID == conversation.id
        return Button { store.select(conversation.id) } label: {
            SidebarRow(convo: conversation, onPin: { store.togglePin(conversation.id) },
                       onRename: { store.renameConversation(conversation.id, title: $0) },
                       onMemoryExclusion: { store.toggleMemoryExclusion(conversation.id) },
                       onDelete: { store.deleteConversation(conversation.id) })
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .accessibilityLabel(conversation.title).accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { SidebarRowLabel(icon: Image(systemName: icon), title: title, rowHeight: 34) }
            .buttonStyle(SidebarRowStyle()).help(title).accessibilityLabel(title)
    }
}

struct SidebarProjectRow: View {
    let project: ProjectRecord
    let expanded: Bool
    let selected: Bool
    let onExpand: () -> Void
    let onNewChat: () -> Void
    @EnvironmentObject var store: ChatStore
    @State private var hovering = false
    @State private var previewing = false
    @State private var previewPinned = false
    @State private var insidePreview = false
    @State private var editing = false
    @State private var dismissal: Task<Void, Never>?
    private enum Focus: Hashable { case row, options, newChat }
    @FocusState private var focused: Focus?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onExpand) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .font(.system(size: 15)).foregroundStyle(Theme.textSecondary).frame(width: 18)
                    Text(project.name).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8).frame(height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focused($focused, equals: .row)
            .accessibilityLabel(project.name)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide project chats")
            Menu {
                Button("New chat", action: createChat)
                Button(expanded ? "Collapse" : "Expand", action: onExpand)
                Button("Project details", action: showPreview)
                Button("Edit project") { editing = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 22, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(hovering || focused != nil ? 1 : 0)
            .focused($focused, equals: .options)
            .help("Project options").accessibilityLabel("Options for \(project.name)")
            Button(action: createChat) {
                Image(systemName: "square.and.pencil").font(.system(size: 13)).frame(width: 24, height: 28)
            }
            .buttonStyle(.plain).opacity(hovering || focused != nil ? 1 : 0)
            .focused($focused, equals: .newChat)
            .help("New chat in \(project.name)").accessibilityLabel("New chat in \(project.name)")
        }
        .foregroundStyle(Theme.textSecondary)
        .background(RoundedRectangle(cornerRadius: SidebarMetrics.radius).fill(selected ? Theme.surfaceSelected : hovering ? Theme.surfaceHover : .clear))
        .onHover { entered in
            hovering = entered
            if entered {
                dismissal?.cancel()
                if !editing { previewing = true }
            } else { scheduleDismissal() }
        }
        .popover(isPresented: $previewing, arrowEdge: .trailing) {
            ProjectPreview(project: store.project(project.id) ?? project) {
                previewing = false
                editing = true
            }
            .onHover { entered in
                insidePreview = entered
                if entered { dismissal?.cancel() } else { scheduleDismissal() }
            }
        }
        .sheet(isPresented: $editing) { ProjectEditor(project: store.project(project.id) ?? project) }
        .onChange(of: previewing) { _, visible in
            if !visible { insidePreview = false; previewPinned = false; dismissal?.cancel() }
        }
        .onChange(of: editing) { _, visible in
            if visible { previewing = false }
        }
        .onDisappear { dismissal?.cancel() }
        .accessibilityAction(named: "Project details", showPreview)
        .contextMenu {
            Button("New chat", action: createChat)
            Button("Project details", action: showPreview)
            Button("Edit project") { editing = true }
        }
    }

    private func createChat() {
        dismissal?.cancel()
        previewing = false
        onNewChat()
    }

    private func showPreview() {
        dismissal?.cancel()
        previewPinned = true
        previewing = true
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissal = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, !hovering, !insidePreview, !previewPinned else { return }
            previewing = false
        }
    }
}

struct CompactUpdateBadge: View {
    @EnvironmentObject var updates: UpdateChecker
    let onOpen: () -> Void

    var body: some View {
        if let release = updates.available {
            Button(action: onOpen) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15)).foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Update available (\(release.tag_name))")
            .accessibilityLabel("Update available, expand the sidebar to install")
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
        }
    }
}

struct DestinationPlaceholder: View {
    let section: AppSection

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: section.icon).font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text(section.placeholder?.title ?? section.title).font(.system(size: 20, weight: .semibold))
            Text(section.placeholder?.note ?? "")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text("Nothing here yet.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .accessibilityElement(children: .combine)
    }
}
