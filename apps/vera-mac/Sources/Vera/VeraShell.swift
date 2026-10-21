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
        .frame(height: SidebarMetrics.rowHeight)
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
    @Binding var collapsed: Bool
    @Binding var search: String
    @ObservedObject var workflowEditor: WorkflowEditorStore
    let onSelect: (AppSection) -> Void
    @ObservedObject private var pins = SidebarPins.shared
    @State private var showingMore = false
    static let expandedWidth: CGFloat = 256
    static let collapsedWidth: CGFloat = 84
    static let topInset: CGFloat = 40

    private var paletteOpen: Bool { store.section == .agentic && store.agenticFlowID != nil }
    private var wide: Bool { !collapsed || paletteOpen }

    var body: some View {
        Group {
            if paletteOpen {
                WorkflowPalette(store: workflowEditor, searchText: $search) { store.agenticFlowID = nil }
                    .padding(.top, Self.topInset)
            } else {
                column
            }
        }
        .frame(width: wide ? Self.expandedWidth : Self.collapsedWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .animation(.easeInOut(duration: 0.22), value: wide)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if wide {
                UpdateBanner()
            } else {
                CompactUpdateBadge { withAnimation(.easeInOut(duration: 0.18)) { collapsed = false } }
            }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: SidebarMetrics.spacing) {
            Button { withAnimation(.easeInOut(duration: 0.22)) { collapsed.toggle() } } label: {
                Image(systemName: "sidebar.left").font(.system(size: SidebarMetrics.iconSize, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: SidebarMetrics.rowHeight, height: SidebarMetrics.rowHeight)
            }
            .buttonStyle(SidebarRowStyle())
            .help(collapsed ? "Expand sidebar" : "Collapse sidebar")
            .accessibilityLabel(collapsed ? "Expand sidebar" : "Collapse sidebar")
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .trailing)
            .padding(.top, Self.topInset)
            .padding(.bottom, 6)

            actionRow(icon: "square.and.pencil", title: "New chat") { store.newConversation() }
            if collapsed {
                actionRow(icon: "magnifyingglass", title: "Search chats") {
                    withAnimation(.easeInOut(duration: 0.22)) { collapsed = false }
                }
            } else {
                searchField.padding(.vertical, 2)
            }
            navRow(.vera)
            divider
            ForEach(pins.pinned) { destinationRow($0) }
            moreRow

            if collapsed {
                Spacer(minLength: 0)
            } else {
                Group {
                    divider
                    history
                }
                .transition(.opacity)
            }

            SettingsLink {
                SidebarRowLabel(icon: Image(systemName: "gearshape"), title: "Settings", collapsed: collapsed)
            }
            .buttonStyle(SidebarRowStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
            .padding(.bottom, 10)
        }
        .padding(.horizontal, SidebarMetrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 6).padding(.horizontal, SidebarMetrics.inset)
    }

    private var moreRow: some View {
        Button { showingMore.toggle() } label: {
            SidebarRowLabel(icon: Image(systemName: "ellipsis"), title: "More", collapsed: collapsed)
        }
        .buttonStyle(SidebarRowStyle(selected: showingMore))
        .help("More")
        .accessibilityLabel("More sections")
        .popover(isPresented: $showingMore, arrowEdge: .trailing) {
            SidebarMoreMenu(pins: pins,
                            isSelected: { $0.isSelected(section: store.section, pane: store.agenticPane) },
                            go: { destination in showingMore = false; go(destination) })
        }
    }

    private func destinationRow(_ destination: SidebarDestination) -> some View {
        let selected = destination.isSelected(section: store.section, pane: store.agenticPane)
        return Button { go(destination) } label: {
            SidebarRowLabel(icon: Image(systemName: destination.icon), title: destination.title, selected: selected, collapsed: collapsed)
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .help(destination.title)
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func go(_ destination: SidebarDestination) {
        switch destination {
        case .workflows: openAgentic(.canvas)
        case .activity: openAgentic(.activity)
        case .projects: onSelect(.projects)
        case .artifacts: onSelect(.artifacts)
        case .scheduled: onSelect(.scheduled)
        case .integrations: onSelect(.integrations)
        case .pulse: onSelect(.pulse)
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
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            TextField("Search chats", text: $search).textFieldStyle(.plain).font(.system(size: SidebarMetrics.labelSize))
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel("Clear search")
            }
        }
        .modifier(SidebarFieldChrome())
        .padding(.bottom, 2)
    }

    private var history: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SidebarMetrics.spacing) {
                ForEach(store.sidebarGroups(search: search)) { group in
                    SidebarSectionHeader(title: group.title)
                    ForEach(group.convos) { convo in
                        let selected = store.section == .chat && store.selectedID == convo.id
                        Button { store.select(convo.id) } label: {
                            SidebarRow(convo: convo,
                                       onPin: { store.togglePin(convo.id) },
                                       onRename: { store.renameConversation(convo.id, title: $0) },
                                       onMemoryExclusion: { store.toggleMemoryExclusion(convo.id) },
                                       onDelete: { store.deleteConversation(convo.id) })
                        }
                        .buttonStyle(SidebarRowStyle(selected: selected))
                        .accessibilityLabel(convo.title)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func navRow(_ section: AppSection) -> some View {
        let selected = store.section == section
        return Button { onSelect(section) } label: {
            if section == .vera {
                SidebarRowLabel(icon: VeraMark(size: 18), title: store.assistantName, selected: selected, collapsed: collapsed, tintsIcon: false)
            } else {
                SidebarRowLabel(icon: Image(systemName: section.icon), title: section.title, selected: selected, collapsed: collapsed)
            }
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SidebarRowLabel(icon: Image(systemName: icon), title: title, collapsed: collapsed)
        }
        .buttonStyle(SidebarRowStyle())
        .help(title)
        .accessibilityLabel(title)
    }
}

struct SidebarMoreMenu: View {
    @ObservedObject var pins: SidebarPins
    let isSelected: (SidebarDestination) -> Bool
    let go: (SidebarDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarMetrics.spacing) {
            ForEach(SidebarDestination.allCases) { destination in
                SidebarMoreRow(destination: destination,
                               selected: isSelected(destination),
                               pinned: pins.isPinned(destination),
                               go: { go(destination) },
                               togglePin: { pins.toggle(destination) })
            }
        }
        .padding(6)
        .frame(width: 232)
    }
}

private struct SidebarMoreRow: View {
    let destination: SidebarDestination
    let selected: Bool
    let pinned: Bool
    let go: () -> Void
    let togglePin: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: go) {
            SidebarRowLabel(icon: Image(systemName: destination.icon), title: destination.title, selected: selected)
                .padding(.trailing, SidebarMetrics.rowHeight - SidebarMetrics.inset)
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .overlay(alignment: .trailing) {
            Button(action: togglePin) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(pinned ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: SidebarMetrics.rowHeight, height: SidebarMetrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(pinned || hovering ? 1 : 0)
            .help(pinned ? "Unpin from sidebar" : "Pin to sidebar")
            .accessibilityLabel(pinned ? "Unpin \(destination.title)" : "Pin \(destination.title)")
        }
        .onHover { hovering = $0 }
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
