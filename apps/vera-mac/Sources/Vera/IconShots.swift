import AppKit
import SwiftUI

@MainActor
enum IconShot {
    static let sizes: [CGFloat] = [16, 20, 24]
    static let candidateSizes: [CGFloat] = [20, 24]

    static func render(view: String, to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let size: CGSize
        let content: AnyView
        switch view {
        case "icons-sheet":
            size = CGSize(width: 900, height: 360)
            content = AnyView(sheet())
        case "icons-candidates":
            size = CGSize(width: 560, height: 250)
            content = AnyView(candidates())
        case "icons-sidebar-states":
            size = CGSize(width: 980, height: 760)
            content = AnyView(sidebarStates())
        default:
            FileHandle.standardError.write(Data("Unknown icons view\n".utf8))
            exit(1)
        }
        let hosting = NSHostingView(rootView: content
            .environment(\.renderSafe, true)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Theme.bg)
            .environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("Icons render failed\n".utf8))
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Icons render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Icons image couldn't be saved\n".utf8))
            exit(1)
        }
    }

    private static func sheet() -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(160), spacing: 12), count: 5), alignment: .leading, spacing: 18) {
            ForEach(InterfaceIcon.allCases, id: \.self) { icon in
                VStack(spacing: 6) {
                    HStack(alignment: .center, spacing: 14) {
                        ForEach(sizes, id: \.self) { side in InterfaceIconView(icon: icon, size: side) }
                    }
                    .frame(height: 28)
                    Text(icon.rawValue).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }
                .frame(width: 160)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(24)
    }

    private struct Choice {
        let title: String
        let current: String
        let role: InterfaceIcon
        let alternate: InterfaceIconCandidate
    }

    private static let choices = [
        Choice(title: "Library", current: AppSection.artifacts.icon, role: .library, alternate: .libraryFolders),
        Choice(title: "Memory", current: AppSection.memory.icon, role: .memory, alternate: .memoryArchive),
        Choice(title: "Workflows", current: AppSection.agentic.icon, role: .workflows, alternate: .workflowsBranch),
    ]

    private static func candidates() -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(choices, id: \.title) { choice in
                HStack(alignment: .center, spacing: 28) {
                    Text(choice.title).font(.system(size: 13, weight: .medium)).frame(width: 90, alignment: .leading)
                    column("now") {
                        ForEach(candidateSizes, id: \.self) { side in
                            Image(systemName: choice.current).font(.system(size: side - 3)).frame(width: side, height: side)
                        }
                    }
                    column("A") {
                        ForEach(candidateSizes, id: \.self) { side in InterfaceIconView(icon: choice.role, size: side) }
                    }
                    column("B") {
                        ForEach(candidateSizes, id: \.self) { side in InterfaceIconView(candidate: choice.alternate, size: side) }
                    }
                }
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(28)
    }

    private static func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 12) { content() }.frame(height: 30)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
        .frame(width: 110)
    }

    private static func sidebarStates() -> some View {
        let store = ProjectShotFixture.store(variant: "projects").store
        store.section = .chat
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        let updates = UpdateChecker()
        updates.available = ReleaseInfo(tag_name: "v0.6.0", html_url: "https://example.invalid/releases/latest", body: nil, assets: [])
        var pinned = Conversation(id: "icons-pinned", title: "Seed starting calendar", messages: [], updatedAt: Date())
        pinned.pinned = true
        let open = Conversation(id: "icons-open", title: "Compost ratios", messages: [], updatedAt: Date())
        let project = store.projects.first ?? ConversationTopBarShot.project("icons-project", "Spring garden")
        return HStack(alignment: .top, spacing: 0) {
            VeraSidebar(collapsed: .constant(false), search: .constant("bed"), workflowEditor: WorkflowEditorStore(), onSelect: { _ in })
                .frame(height: 760)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 18) {
                part("Pinned chat") { SidebarRow(convo: pinned) }
                part("Chat options") { SidebarRow(convo: open, revealsOptions: true) }
                part("Project buttons") {
                    SidebarProjectRow(project: project, expanded: false, selected: false, onExpand: {}, onNewChat: {}, revealsControls: true)
                }
                part("Update") {
                    VStack(spacing: 8) {
                        UpdateBanner()
                        CompactUpdateBadge {}.frame(width: VeraSidebar.railWidth)
                    }
                }
                part("Companion badge") {
                    HStack(spacing: 16) {
                        ForEach([true, false], id: \.self) { attention in
                            CompanionAvatar(size: CompanionTileMetrics.figure)
                                .overlay(alignment: .bottomTrailing) {
                                    CompanionTileBadge(attention: attention, ring: Theme.cardFill).offset(x: -4, y: -4)
                                }
                                .padding(CompanionTileMetrics.inset)
                                .background(RoundedRectangle(cornerRadius: CompanionTileMetrics.radius, style: .continuous).fill(Theme.cardFill))
                        }
                    }
                }
                part("Empty destination") {
                    DestinationPlaceholder(section: .integrations).frame(height: 230)
                }
            }
            .frame(width: 420)
            .padding(24)
        }
        .foregroundStyle(Theme.textPrimary)
        .environmentObject(store)
        .environmentObject(config)
        .environmentObject(updates)
    }

    private static func part<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
            content().frame(width: 280, alignment: .leading).background(Theme.sidebar)
        }
    }
}
