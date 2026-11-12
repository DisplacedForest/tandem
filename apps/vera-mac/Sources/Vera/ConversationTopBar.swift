import SwiftUI

@MainActor
enum ConversationTopBarMetrics {
    static let fade: CGFloat = 84
    static let top: CGFloat = CompanionProfileMetrics.top
    static let edge: CGFloat = CompanionProfileMetrics.edge
    static let height: CGFloat = SidebarRoundButtonStyle.size
    static let iconSize: CGFloat = 18
    static let gap: CGFloat = 8
    static let transcriptTop: CGFloat = CompanionProfileMetrics.transcriptTop
    static let clearance: CGFloat = top + height + 10
}

enum ConversationTopBarAction: Hashable, Sendable {
    case toggleProfile
    case pause
    case resume
    case companionSettings
    case rename
    case pin
    case unpin
    case instructions
    case moveToProject(String)
    case removeFromProject
    case excludeFromMemory
    case allowMemory
    case delete
}

struct ConversationTopBarMenuItem: Hashable, Identifiable, Sendable {
    let title: String
    var action: ConversationTopBarAction? = nil
    var destructive = false
    var checked = false
    var children: [ConversationTopBarMenuItem] = []

    var id: String { title }
}

struct ConversationSidebarControl {
    let collapsed: Bool
    let toggle: @MainActor () -> Void
}

private struct ConversationSidebarControlKey: EnvironmentKey {
    static let defaultValue: ConversationSidebarControl? = nil
}

extension EnvironmentValues {
    var conversationSidebar: ConversationSidebarControl? {
        get { self[ConversationSidebarControlKey.self] }
        set { self[ConversationSidebarControlKey.self] = newValue }
    }
}

enum ConversationTopBarModel {
    static func showsRailToggle(section: AppSection) -> Bool { section != .chat && section != .vera }

    static func sidebarTitle(collapsed: Bool) -> String { collapsed ? "Show sidebar" : "Hide sidebar" }

    static let moreTitle = "More options"

    static func pillTitle(name: String, profileOpen: Bool) -> String {
        CompanionProfileCopy.toggleTitle(name: name, open: profileOpen)
    }

    static func companionMenu(name: String, profileOpen: Bool, paused: Bool) -> [ConversationTopBarMenuItem] {
        [
            ConversationTopBarMenuItem(title: CompanionProfileCopy.toggleTitle(name: name, open: profileOpen), action: .toggleProfile),
            ConversationTopBarMenuItem(title: paused ? "Resume" : "Pause", action: paused ? .resume : .pause),
            ConversationTopBarMenuItem(title: "Companion settings", action: .companionSettings),
        ]
    }

    static func chatMenu(_ conversation: Conversation?, projects: [ProjectRecord], companionThread: Bool) -> [ConversationTopBarMenuItem] {
        guard let conversation, !companionThread else { return [] }
        var items = [
            ConversationTopBarMenuItem(title: "Rename", action: .rename),
            ConversationTopBarMenuItem(title: conversation.pinned ? "Unpin" : "Pin", action: conversation.pinned ? .unpin : .pin),
            ConversationTopBarMenuItem(title: "Instructions\u{2026}", action: .instructions),
        ]
        if !projects.isEmpty {
            items.append(ConversationTopBarMenuItem(title: "Move to project", children: projects.map {
                ConversationTopBarMenuItem(title: $0.name, action: .moveToProject($0.id), checked: conversation.projectID == $0.id)
            }))
        }
        if conversation.projectID != nil {
            items.append(ConversationTopBarMenuItem(title: "Remove from project", action: .removeFromProject))
        }
        items.append(conversation.memoryExcluded
            ? ConversationTopBarMenuItem(title: "Allow memory suggestions", action: .allowMemory)
            : ConversationTopBarMenuItem(title: "Exclude from memory suggestions", action: .excludeFromMemory))
        items.append(ConversationTopBarMenuItem(title: "Delete", action: .delete, destructive: true))
        return items
    }

    static func chatTitle(_ conversation: Conversation?, companionThread: Bool) -> String? {
        guard let conversation, !companionThread else { return nil }
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !conversation.messages.isEmpty || conversation.isPersisted else { return nil }
        return title
    }
}

struct TopBarPillStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, selected: selected)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Capsule().fill(CompanionTileStyle.fill(selected: selected, hovering: hovering, pressed: configuration.isPressed)))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

struct ConversationTopBar: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore
    @Environment(\.renderSafe) private var renderSafe
    @Environment(\.conversationSidebar) private var sidebar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var profile: Binding<CompanionProfileState>? = nil
    var fixed: CompanionOverviewModel? = nil
    var conversation: Conversation? = nil
    @State private var renaming = false
    @State private var renameText = ""
    @State private var editingInstructions = false
    @State private var showingCompanionSettings = false
    @State private var moreHovering = false

    private var companion: Bool { profile != nil }
    private var mention: String { fixed?.mention ?? store.companion.inline }
    private var profileOpen: Bool { profile?.wrappedValue.isOpen ?? false }
    private var paused: Bool { fixed?.paused ?? store.isDotPaused }
    private var chatTitle: String? {
        ConversationTopBarModel.chatTitle(conversation, companionThread: store.isVeraThread(conversation?.id))
    }

    private var items: [ConversationTopBarMenuItem] {
        if companion { return ConversationTopBarModel.companionMenu(name: mention, profileOpen: profileOpen, paused: paused) }
        return ConversationTopBarModel.chatMenu(conversation, projects: store.projects,
                                                companionThread: store.isVeraThread(conversation?.id))
    }

    var body: some View {
        HStack(spacing: ConversationTopBarMetrics.gap) {
            slot { sidebarButton }
            Spacer(minLength: 0)
            pill
            Spacer(minLength: 0)
            slot { moreButton }
        }
        .padding(.horizontal, ConversationTopBarMetrics.edge)
        .padding(.top, ConversationTopBarMetrics.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(alignment: .top) {
            LinearGradient(stops: [.init(color: Theme.conversationBackground, location: 0),
                                   .init(color: Theme.conversationBackground.opacity(0.85), location: 0.55),
                                   .init(color: Theme.conversationBackground.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: ConversationTopBarMetrics.fade)
                .allowsHitTesting(false)
        }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Rename") { if let id = conversation?.id { store.renameConversation(id, title: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $editingInstructions) {
            if let conversation { ConversationInstructionsEditor(conversation: conversation) }
        }
        .sheet(isPresented: $showingCompanionSettings) {
            DotSettingsView().environmentObject(store).environmentObject(config)
        }
    }

    private func slot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(width: ConversationTopBarMetrics.height, height: ConversationTopBarMetrics.height)
    }

    private func roundIcon(_ icon: InterfaceIcon) -> some View {
        InterfaceIconView(icon: icon, size: ConversationTopBarMetrics.iconSize)
    }

    private func staticRound(_ icon: InterfaceIcon) -> some View {
        roundIcon(icon)
            .foregroundStyle(Theme.textPrimary)
            .frame(width: SidebarRoundButtonStyle.size, height: SidebarRoundButtonStyle.size)
            .background(Circle().fill(CompanionTileStyle.fill(selected: false, hovering: false, pressed: false)))
    }

    @ViewBuilder private var sidebarButton: some View {
        if let sidebar {
            let title = ConversationTopBarModel.sidebarTitle(collapsed: sidebar.collapsed)
            if renderSafe {
                staticRound(.sidebar).accessibilityLabel(title)
            } else {
                Button { sidebar.toggle() } label: { roundIcon(.sidebar) }
                    .buttonStyle(SidebarRoundButtonStyle())
                    .help(title).accessibilityLabel(title)
            }
        }
    }

    @ViewBuilder private var pill: some View {
        if companion {
            let title = ConversationTopBarModel.pillTitle(name: mention, profileOpen: profileOpen)
            if renderSafe {
                companionPillLabel.background(Capsule().fill(CompanionTileStyle.fill(selected: profileOpen, hovering: false, pressed: false)))
                    .accessibilityLabel(title)
            } else {
                Button(action: toggleProfile) { companionPillLabel }
                    .buttonStyle(TopBarPillStyle(selected: profileOpen))
                    .help(title).accessibilityLabel(title)
            }
        } else if let chatTitle {
            Text(chatTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.warmTextPrimary)
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 14)
                .frame(height: ConversationTopBarMetrics.height)
                .background(Capsule().fill(CompanionTileStyle.fill(selected: false, hovering: false, pressed: false)))
                .help(chatTitle)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var companionPillLabel: some View {
        HStack(spacing: 8) {
            CompanionAvatar(size: 22)
            CompanionNamedText(template: CompanionSentence.placeholder)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.warmTextPrimary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.leading, 6).padding(.trailing, 14)
        .frame(height: ConversationTopBarMetrics.height)
        .contentShape(Capsule())
    }

    @ViewBuilder private var moreButton: some View {
        let items = items
        if !items.isEmpty {
            if renderSafe {
                staticRound(.more).accessibilityLabel(ConversationTopBarModel.moreTitle)
            } else {
                Menu { menuContents(items) } label: { moreLabel }
                    .menuStyle(.button).buttonStyle(.plain)
                    .menuIndicator(.hidden).fixedSize()
                    .onHover { moreHovering = $0 }
                    .help(ConversationTopBarModel.moreTitle).accessibilityLabel(ConversationTopBarModel.moreTitle)
            }
        }
    }

    private var moreLabel: some View {
        roundIcon(.more)
            .foregroundStyle(Theme.textPrimary)
            .frame(width: SidebarRoundButtonStyle.size, height: SidebarRoundButtonStyle.size)
            .background(Circle().fill(CompanionTileStyle.fill(selected: false, hovering: moreHovering, pressed: false)))
            .contentShape(Circle())
    }

    private func menuContents(_ items: [ConversationTopBarMenuItem]) -> some View {
        ForEach(items) { item in
            if !item.children.isEmpty {
                Menu(item.title) {
                    ForEach(item.children) { child in
                        Toggle(child.title, isOn: Binding(get: { child.checked }, set: { _ in perform(child.action) }))
                    }
                }
            } else {
                Button(item.title, role: item.destructive ? .destructive : nil) { perform(item.action) }
            }
        }
    }

    private func toggleProfile() {
        guard let profile else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { profile.wrappedValue.toggle(now: Date()) }
    }

    private func perform(_ action: ConversationTopBarAction?) {
        guard let action else { return }
        let id = conversation?.id
        switch action {
        case .toggleProfile: toggleProfile()
        case .pause: store.setDotState(.paused)
        case .resume: store.setDotState(.active)
        case .companionSettings: showingCompanionSettings = true
        case .rename:
            renameText = conversation?.title ?? ""
            renaming = true
        case .pin, .unpin: if let id { store.togglePin(id) }
        case .instructions: editingInstructions = true
        case .moveToProject(let project): if let id { store.moveConversation(id, toProject: project) }
        case .removeFromProject: if let id { store.moveConversation(id, toProject: nil) }
        case .excludeFromMemory, .allowMemory: if let id { store.toggleMemoryExclusion(id) }
        case .delete: if let id { store.deleteConversation(id) }
        }
    }
}

struct TopBarMenuProposal: View {
    struct Card: Identifiable {
        let title: String
        let items: [ConversationTopBarMenuItem]
        var id: String { title }
    }

    let cards: [Card]

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(cards) { card($0.title, $0.items) }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.conversationBackground)
    }

    private func card(_ title: String, _ items: [ConversationTopBarMenuItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                InterfaceIconView(icon: .more, size: ConversationTopBarMetrics.iconSize)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: SidebarRoundButtonStyle.size, height: SidebarRoundButtonStyle.size)
                    .background(Circle().fill(Theme.cardFill))
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warmTextSecondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    row(item, indent: 0)
                    ForEach(item.children) { row($0, indent: 1) }
                }
            }
            .padding(.vertical, 6)
            .frame(width: 300, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
        }
    }

    private func row(_ item: ConversationTopBarMenuItem, indent: Int) -> some View {
        HStack(spacing: 6) {
            Text(item.checked ? "\u{2713}" : "").frame(width: 12)
            Text(item.title)
            Spacer(minLength: 0)
            if !item.children.isEmpty { Text("\u{203A}").foregroundStyle(Theme.warmTextSecondary) }
        }
        .font(.system(size: 13))
        .foregroundStyle(item.destructive ? Color.red : Theme.warmTextPrimary)
        .padding(.leading, 10 + CGFloat(indent) * 16).padding(.trailing, 12)
        .frame(height: 26)
    }
}
