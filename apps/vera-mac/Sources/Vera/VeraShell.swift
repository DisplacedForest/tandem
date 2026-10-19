import SwiftUI

struct VeraSidebar: View {
    @EnvironmentObject var store: ChatStore
    @Binding var collapsed: Bool
    @Binding var search: String
    @ObservedObject var workflowEditor: WorkflowEditorStore
    let onSelect: (AppSection) -> Void
    static let expandedWidth: CGFloat = 256
    static let collapsedWidth: CGFloat = 64
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if wide {
                UpdateBanner()
            } else {
                CompactUpdateBadge { withAnimation(.easeInOut(duration: 0.18)) { collapsed = false } }
            }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if !collapsed { Spacer(minLength: 0) }
                Button { withAnimation(.easeInOut(duration: 0.18)) { collapsed.toggle() } } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand sidebar" : "Collapse sidebar")
                .accessibilityLabel(collapsed ? "Expand sidebar" : "Collapse sidebar")
                if collapsed { Spacer(minLength: 0) }
            }
            .padding(.top, Self.topInset)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            navRow(.vera)
            actionRow(icon: "square.and.pencil", title: "New chat") { store.newConversation() }
            navRow(.projects)
            navRow(.artifacts)
            navRow(.scheduled)
            navRow(.integrations)
            divider
            navRow(.pulse)
            agenticRow(icon: "point.3.connected.trianglepath.dotted", title: "Workflows", pane: .canvas)
            agenticRow(icon: "bolt", title: "Activity", pane: .activity)
            navRow(.memory)

            if collapsed {
                Spacer(minLength: 0)
            } else {
                divider
                searchField
                history
            }

            SettingsLink {
                rowLabel(icon: Image(systemName: "gearshape"), title: "Settings", selected: false)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 6)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextField("Search chats", text: $search).textFieldStyle(.plain).font(.system(size: 13))
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        .padding(.bottom, 4)
    }

    private var history: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(store.sidebarGroups(search: search)) { group in
                    Text(group.title.uppercased())
                        .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3)
                    ForEach(group.convos) { convo in
                        Button { store.select(convo.id) } label: {
                            SidebarRow(convo: convo,
                                       onPin: { store.togglePin(convo.id) },
                                       onMemoryExclusion: { store.toggleMemoryExclusion(convo.id) },
                                       onDelete: { store.deleteConversation(convo.id) })
                                .font(.system(size: 13))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(store.section == .chat && store.selectedID == convo.id ? Theme.surfaceHover : Color.clear))
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(convo.title)
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
                rowLabel(icon: VeraMark(size: 20), title: section.title, selected: selected)
            } else {
                rowLabel(icon: Image(systemName: section.icon), title: section.title, selected: selected)
            }
        }
        .buttonStyle(.plain)
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func agenticRow(icon: String, title: String, pane: AgenticPane) -> some View {
        let selected = store.section == .agentic && store.agenticPane == pane
        return Button {
            store.section = .agentic
            store.agenticPane = pane
            store.agenticFlowID = nil
        } label: {
            rowLabel(icon: Image(systemName: icon), title: title, selected: selected)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowLabel(icon: Image(systemName: icon), title: title, selected: false)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func rowLabel<Icon: View>(icon: Icon, title: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            icon
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22, height: 22)
            if !collapsed {
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
        .padding(.horizontal, collapsed ? 0 : 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Theme.surfaceHover : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
