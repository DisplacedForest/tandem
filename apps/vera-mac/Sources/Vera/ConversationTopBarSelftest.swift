import AppKit
import Foundation

@MainActor
enum ConversationTopBarShot {
    static let titledViews: Set<String> = ["chat", "chat-collapsed"]
    static let chatTitle = "Planning the spring garden beds"

    static func project(_ id: String, _ name: String) -> ProjectRecord {
        ProjectRecord(id: id, name: name, instructions: "", grants: [], files: [], createdAt: Date(), updatedAt: Date())
    }

    static func titledChat(projectID: String? = nil, pinned: Bool = false, memoryExcluded: Bool = false) -> Conversation {
        var conversation = Conversation(id: "top-bar-titled-chat", title: chatTitle,
                                        messages: [Message(role: .user, text: "Help me plan the spring garden beds.")],
                                        updatedAt: Date(), isPersisted: true)
        conversation.projectID = projectID
        conversation.pinned = pinned
        conversation.memoryExcluded = memoryExcluded
        return conversation
    }

    static func seedTitledChat(_ store: ChatStore) {
        let conversation = titledChat()
        store.conversations.removeAll { $0.id == conversation.id }
        store.conversations.insert(conversation, at: 0)
        store.selectedID = conversation.id
    }

    static func cards() -> [TopBarMenuProposal.Card] {
        let projects = [project("garden", "Garden"), project("house", "House")]
        return [
            TopBarMenuProposal.Card(title: "Ada's conversation",
                                    items: ConversationTopBarModel.companionMenu(name: "Ada", profileOpen: false, paused: false)),
            TopBarMenuProposal.Card(title: "Profile open, paused",
                                    items: ConversationTopBarModel.companionMenu(name: "Ada", profileOpen: true, paused: true)),
            TopBarMenuProposal.Card(title: "A chat in a project",
                                    items: ConversationTopBarModel.chatMenu(titledChat(projectID: "garden"), projects: projects,
                                                                            companionThread: false)),
        ]
    }
}

@MainActor
extension SelfTest {
    private static func iconDraws(_ image: NSImage) -> Bool {
        let side = 32
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<side {
            for y in 0..<side where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 }
        }
        return inked > 20 && inked < side * side - 20
    }

    static func runConversationTopBar() throws {
        let require = NativeTaskFixture.require

        try require(Set(InterfaceIcon.allCases.map(\.resource)).count == InterfaceIcon.allCases.count, "Each icon meaning has its own file")
        for icon in InterfaceIcon.allCases {
            guard let url = icon.url, let svg = try? String(contentsOf: url, encoding: .utf8) else {
                throw SelfTestFailure("The \(icon.rawValue) icon file is missing from the app resources")
            }
            try require(svg.contains("viewBox=\"0 0 24 24\"") && svg.contains(" d=\"M"), "The \(icon.rawValue) icon keeps its source geometry")
            guard let image = icon.image else { throw SelfTestFailure("The \(icon.rawValue) icon does not load as an image") }
            try require(image.isTemplate, "The \(icon.rawValue) icon takes the text color")
            try require(iconDraws(image), "The \(icon.rawValue) icon draws visible marks")
        }
        try require(VeraResources.url("interface-icons-NOTICE", ext: "txt") != nil, "The icon notice ships inside the app")

        for section in AppSection.allCases {
            let shows = ConversationTopBarModel.showsRailToggle(section: section)
            try require(shows == !(section == .chat || section == .vera),
                        "Only one sidebar control shows for \(section.rawValue)")
        }
        try require(ConversationTopBarModel.sidebarTitle(collapsed: false) == "Hide sidebar"
                    && ConversationTopBarModel.sidebarTitle(collapsed: true) == "Show sidebar", "The sidebar button says what it will do")

        let named = CompanionSubject("Ada").inline
        let unnamed = CompanionSubject(nil).inline
        try require(ConversationTopBarModel.pillTitle(name: named, profileOpen: false) == "Open Ada's profile"
                    && ConversationTopBarModel.pillTitle(name: named, profileOpen: true) == "Close Ada's profile", "The pill names the companion")
        try require(ConversationTopBarModel.pillTitle(name: unnamed, profileOpen: false) == "Open your companion's profile"
                    && ConversationTopBarModel.pillTitle(name: unnamed, profileOpen: true) == "Close your companion's profile",
                    "The unnamed pill reads as your companion")

        func titles(_ items: [ConversationTopBarMenuItem]) -> [String] { items.map(\.title) }
        try require(titles(ConversationTopBarModel.companionMenu(name: named, profileOpen: false, paused: false))
                    == ["Open Ada's profile", "Pause", "Companion settings"], "The companion menu, profile closed")
        try require(titles(ConversationTopBarModel.companionMenu(name: named, profileOpen: true, paused: true))
                    == ["Close Ada's profile", "Resume", "Companion settings"], "The companion menu, profile open and paused")
        try require(titles(ConversationTopBarModel.companionMenu(name: unnamed, profileOpen: false, paused: true))
                    == ["Open your companion's profile", "Resume", "Companion settings"], "The unnamed companion menu")
        let actions = ConversationTopBarModel.companionMenu(name: unnamed, profileOpen: true, paused: false).map(\.action)
        try require(actions == [.toggleProfile, .pause, .companionSettings], "The companion menu acts on the profile, pause and settings")

        let projects = [ConversationTopBarShot.project("garden", "Garden"), ConversationTopBarShot.project("house", "House")]
        try require(ConversationTopBarModel.chatMenu(nil, projects: projects, companionThread: false).isEmpty, "No chat, no menu")
        try require(ConversationTopBarModel.chatMenu(ConversationTopBarShot.titledChat(), projects: [], companionThread: true).isEmpty,
                    "The companion's conversation never gets the chat menu")
        let plain = ConversationTopBarModel.chatMenu(ConversationTopBarShot.titledChat(), projects: [], companionThread: false)
        try require(titles(plain) == ["Rename", "Pin", "Instructions\u{2026}", "Exclude from memory suggestions", "Delete"],
                    "A chat outside any project offers the row's actions")
        try require(plain.last?.destructive == true && plain.last?.action == .delete, "Delete is marked destructive")
        let filed = ConversationTopBarModel.chatMenu(ConversationTopBarShot.titledChat(projectID: "garden", pinned: true, memoryExcluded: true),
                                                     projects: projects, companionThread: false)
        try require(titles(filed) == ["Rename", "Unpin", "Instructions\u{2026}", "Move to project", "Remove from project",
                                      "Allow memory suggestions", "Delete"], "A pinned chat in a project offers the row's actions")
        let move = filed.first { $0.title == "Move to project" }
        try require(move?.children.map(\.title) == ["Garden", "House"] && move?.children.map(\.checked) == [true, false]
                    && move?.children.first?.action == .moveToProject("garden"), "Move to project lists every project and marks the current one")

        try require(ConversationTopBarModel.chatTitle(ConversationTopBarShot.titledChat(), companionThread: false) == ConversationTopBarShot.chatTitle,
                    "A titled chat shows its title")
        try require(ConversationTopBarModel.chatTitle(nil, companionThread: false) == nil, "No chat, no title")
        try require(ConversationTopBarModel.chatTitle(Conversation(id: "fresh", title: "New chat", messages: [], updatedAt: Date()),
                                                      companionThread: false) == nil, "A chat that has not started has no title yet")
        try require(ConversationTopBarModel.chatTitle(ConversationTopBarShot.titledChat(), companionThread: true) == nil,
                    "The companion's conversation shows the companion pill instead")

        let every = ConversationTopBarShot.cards().flatMap(\.items).flatMap { [$0] + $0.children }.map(\.title)
            + [ConversationTopBarModel.moreTitle]
        try require(!every.contains { $0.localizedCaseInsensitiveContains("vera") || $0.contains("\u{2014}") },
                    "Menu wording stays plain")
        print("  conversation top bar OK (\(InterfaceIcon.allCases.count) icons, menus, one sidebar control)")
    }
}

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
