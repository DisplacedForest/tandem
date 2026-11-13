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

    struct IconGeometry: Equatable {
        let bytes: Int
        let hash: UInt64
        var side = 24
    }

    static let iconGeometry: [InterfaceIcon: IconGeometry] = [
        .search: IconGeometry(bytes: 500, hash: 11666982603186441170),
        .add: IconGeometry(bytes: 265, hash: 13205456113675037522),
        .sidebar: IconGeometry(bytes: 1366, hash: 10167534887057486873),
        .sidebarShown: IconGeometry(bytes: 2225, hash: 14390550895553307252),
        .more: IconGeometry(bytes: 100, hash: 9401086856371832709),
        .home: IconGeometry(bytes: 1398, hash: 1669975422232020603),
        .chat: IconGeometry(bytes: 719, hash: 4727889612936719036),
        .settings: IconGeometry(bytes: 1271, hash: 14184745131888506841),
        .projects: IconGeometry(bytes: 697, hash: 4946116776941346420, side: 20),
        .projectOpen: IconGeometry(bytes: 2405, hash: 16637674623537552920),
        .library: IconGeometry(bytes: 1280, hash: 6289694957238832706),
        .scheduled: IconGeometry(bytes: 453, hash: 17768382527750560289),
        .plugins: IconGeometry(bytes: 1437, hash: 8724439596248102886),
        .pulse: IconGeometry(bytes: 2415, hash: 18024484980784978891),
        .workflows: IconGeometry(bytes: 1556, hash: 8722813287961875453),
        .activity: IconGeometry(bytes: 456, hash: 15428600264880338152),
        .memory: IconGeometry(bytes: 1166, hash: 8953277172807369300),
        .companion: IconGeometry(bytes: 574, hash: 13623657184867545989),
        .attention: IconGeometry(bytes: 651, hash: 10506749735272278851),
        .update: IconGeometry(bytes: 592, hash: 12592026924203043116),
        .clear: IconGeometry(bytes: 263, hash: 5878221935624466636),
        .pin: IconGeometry(bytes: 1107, hash: 17874464801791710818),
        .close: IconGeometry(bytes: 196, hash: 8390395120732435969),
        .info: IconGeometry(bytes: 533, hash: 7047778675819240951),
        .warning: IconGeometry(bytes: 1021, hash: 6844464036137675511),
        .connect: IconGeometry(bytes: 449, hash: 905839141765071649),
        .attach: IconGeometry(bytes: 444, hash: 14785805475343738788),
        .folder: IconGeometry(bytes: 2454, hash: 10116636564115222591),
        .research: IconGeometry(bytes: 1670, hash: 10270706448582035180),
        .document: IconGeometry(bytes: 2657, hash: 1140187331660743019),
        .image: IconGeometry(bytes: 1233, hash: 15084281777000784573),
        .reminders: IconGeometry(bytes: 2536, hash: 15234358487964984702),
        .rules: IconGeometry(bytes: 810, hash: 4931027334619142328),
        .tool: IconGeometry(bytes: 438, hash: 17366720933809361075),
        .voice: IconGeometry(bytes: 519, hash: 13330080550912626834),
        .dictate: IconGeometry(bytes: 850, hash: 11489530479510735273),
        .dictating: IconGeometry(bytes: 874, hash: 14410899516536224187),
        .send: IconGeometry(bytes: 129, hash: 11744404674765987333),
        .stop: IconGeometry(bytes: 119, hash: 12254759145195972880),
        .done: IconGeometry(bytes: 586, hash: 5194145164676587557),
        .stopped: IconGeometry(bytes: 180, hash: 12453720026567839284),
        .paused: IconGeometry(bytes: 259, hash: 10722450644395476547),
        .question: IconGeometry(bytes: 869, hash: 5192175480380517568),
        .failed: IconGeometry(bytes: 499, hash: 7718356855032257294),
        .needsYou: IconGeometry(bytes: 514, hash: 5578166281573923529),
        .declined: IconGeometry(bytes: 146, hash: 14236215097802300827),
        .refused: IconGeometry(bytes: 300, hash: 14939144681513251688),
        .timedOut: IconGeometry(bytes: 1134, hash: 12966522723310919404),
        .terminal: IconGeometry(bytes: 2266, hash: 14743431999374310603),
        .edit: IconGeometry(bytes: 706, hash: 3004767787539017732),
        .fileAdded: IconGeometry(bytes: 1044, hash: 3221957271757878965),
        .moved: IconGeometry(bytes: 419, hash: 14713047368757306162),
        .folderAdded: IconGeometry(bytes: 2520, hash: 16392791367150624517, side: 18),
        .trash: IconGeometry(bytes: 936, hash: 9336008833375516873),
        .link: IconGeometry(bytes: 1159, hash: 15524316508204179840),
        .copy: IconGeometry(bytes: 3221, hash: 146665332394702837),
        .reply: IconGeometry(bytes: 921, hash: 14158836824330727499),
        .selectText: IconGeometry(bytes: 1525, hash: 9022037510570118882),
        .addReaction: IconGeometry(bytes: 1328, hash: 11034650447187561382),
        .good: IconGeometry(bytes: 2455, hash: 12031135414672809284),
        .goodChosen: IconGeometry(bytes: 464, hash: 6455414001273910115),
        .bad: IconGeometry(bytes: 2429, hash: 5454773189447699107),
        .badChosen: IconGeometry(bytes: 559, hash: 5260672730238567873),
        .expand: IconGeometry(bytes: 121, hash: 1897763155044169926),
        .collapse: IconGeometry(bytes: 115, hash: 7228592855516792996),
        .next: IconGeometry(bytes: 120, hash: 12069323854929476458),
        .back: IconGeometry(bytes: 120, hash: 6253633672018244088),
        .choose: IconGeometry(bytes: 628, hash: 2182408223912166480),
        .latest: IconGeometry(bytes: 131, hash: 3304619820672566877),
        .bridged: IconGeometry(bytes: 1069, hash: 9936219808698129602),
        .withheld: IconGeometry(bytes: 1603, hash: 3848292242780143714),
        .checkboxOn: IconGeometry(bytes: 1325, hash: 15286044549133111796),
        .checkboxOff: IconGeometry(bytes: 1825, hash: 5472626730620543207),
        .radioOn: IconGeometry(bytes: 226, hash: 17340246410702786588),
        .radioOff: IconGeometry(bytes: 224, hash: 10803538240702399099),
    ]

    static let candidateGeometry: [InterfaceIconCandidate: IconGeometry] = [
        .connectStatus: IconGeometry(bytes: 1370, hash: 16386569431639055677),
        .researchTelescope: IconGeometry(bytes: 769, hash: 4537033671586817260),
        .remindersList: IconGeometry(bytes: 914, hash: 13406093435795975882),
        .rulesShield: IconGeometry(bytes: 343, hash: 6387568544129092439),
        .declinedHand: IconGeometry(bytes: 1183, hash: 5359133356539751217),
        .refusedShield: IconGeometry(bytes: 958, hash: 3097556506170922716),
        .timedOutStopwatch: IconGeometry(bytes: 776, hash: 6580490067836235028),
        .fileAddedBlank: IconGeometry(bytes: 2496, hash: 869476924721325526),
        .movedForward: IconGeometry(bytes: 326, hash: 14719823673505904522),
        .replyLeft: IconGeometry(bytes: 429, hash: 5208448157472655625),
    ]

    private static func checkIconFile(_ name: String, url: URL?, image: NSImage?, geometry: IconGeometry?) throws {
        let require = NativeTaskFixture.require
        guard let url, let svg = try? String(contentsOf: url, encoding: .utf8) else {
            throw SelfTestFailure("The \(name) icon file is missing from the app resources")
        }
        guard let geometry else { throw SelfTestFailure("The \(name) icon has no pinned geometry") }
        try require(svg.contains("viewBox=\"0 0 \(geometry.side) \(geometry.side)\"") && iconGeometry(svg).bytes == geometry.bytes
                    && iconGeometry(svg).hash == geometry.hash, "The \(name) icon keeps its source geometry")
        guard let image else { throw SelfTestFailure("The \(name) icon does not load as an image") }
        try require(image.isTemplate, "The \(name) icon takes the text color")
        try require(iconDraws(image), "The \(name) icon draws visible marks")
    }

    static func iconGeometry(_ svg: String) -> IconGeometry {
        var paths: [String] = []
        var rest = svg[...]
        while let start = rest.range(of: " d=\"") {
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { break }
            paths.append(String(after[..<end]))
            rest = after[after.index(after: end)...]
        }
        let bytes = Array(paths.joined(separator: "\n").utf8)
        var hash: UInt64 = 14695981039346656037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return IconGeometry(bytes: bytes.count, hash: hash)
    }

    static func runConversationTopBar() throws {
        let require = NativeTaskFixture.require

        let resources = InterfaceIcon.allCases.map(\.resource) + InterfaceIconCandidate.allCases.map(\.resource)
        try require(Set(resources).count == resources.count, "Each icon meaning has its own file")
        for candidate in InterfaceIconCandidate.allCases {
            try checkIconFile(candidate.rawValue, url: candidate.url, image: candidate.image, geometry: candidateGeometry[candidate])
            try require(candidate.resource.hasPrefix(candidate.role.resource + "-"), "The \(candidate.rawValue) icon sits beside the one it could replace")
        }
        for icon in InterfaceIcon.allCases {
            try checkIconFile(icon.rawValue, url: icon.url, image: icon.image, geometry: iconGeometry[icon])
            let menu = InterfaceIconCache.shared.menuImage(icon.resource)
            try require(icon.menuImage != nil && menu?.isTemplate == true
                        && menu?.size == NSSize(width: InterfaceIconSize.menu, height: InterfaceIconSize.menu)
                        && menu.map(iconDraws) == true, "The \(icon.rawValue) icon has a menu image")
        }
        try require(Set(SidebarDestination.primary + SidebarDestination.secondary) == Set(SidebarDestination.allCases),
                    "Every destination shows in the rail or its menu")
        for destination in SidebarDestination.allCases {
            try require(destination.glyph.image != nil, "The \(destination.title) destination draws its icon")
        }
        for section in AppSection.allCases {
            try require(section.glyph.image != nil, "The \(section.title) section draws its icon")
        }
        try require(SidebarDestination.integrations.glyph == .plugins && AppSection.integrations.glyph == .plugins,
                    "Plugins shows the plugins icon")
        try require(SidebarDestination.chats.glyph == .home && SidebarDestination.library.glyph == AppSection.artifacts.glyph
                    && SidebarDestination.workflows.glyph == AppSection.agentic.glyph, "The rail and the screens agree on icons")
        try require(SidebarRow.optionsLabel("Compost ratios") == "Options for Compost ratios", "A chat row's options button is named for its chat")
        try require(MessageMenuAction.copy.icon == .copy && MessageMenuAction.reply.icon == MessageReplyCopy.icon,
                    "Copy and reply show their own icons in the message menu and the reply bar")
        try require(MessageReplyCopy.cancelIcon == .close, "Cancelling a reply shows the close icon")
        try require(ComposerControlGlyph(kind: .send(active: true, generating: false)).icon == .send
                    && ComposerControlGlyph(kind: .stop(enabled: true)).icon == .stop
                    && ComposerControlGlyph(kind: .dictate(active: true)).icon == .dictating
                    && ComposerControlGlyph(kind: .dictate(active: false)).icon == .dictate
                    && ComposerControlGlyph(kind: .plus).icon == .add, "The composer buttons show send, stop, dictation and add")
        let failedRun = NativeCommandRun(id: "icons", command: "make check", directory: "", outcome: .ran, reason: .userApproved,
                                         exitCode: 2, stdout: "", durationMilliseconds: 1)
        try require(NativeCommandRunCard(run: failedRun).icon == .warning, "A command that failed shows the warning icon")
        try require(NativeTaskCardPresentation.Status.completed.icon == .done && TranscriptMarker.preferenceSaved.icon == .done
                    && NativeTaskCardPresentation.Status.failed.icon == .failed
                    && NativeTaskCardPresentation.Status.working.icon(document: true) == .edit
                    && NativeTaskCardPresentation.Status.working.icon(document: false) == .research, "Work status icons follow their meaning")
        try require(ComposerMentionCatalog.filesItem.icon == .attach && ComposerMentionCatalog.folderItem.icon == .folder,
                    "Adding files and working in a folder keep their own icons")
        try require(VeraAskCard.optionIcon(on: true, multiSelect: true) == .checkboxOn && VeraAskCard.optionIcon(on: false, multiSelect: false) == .radioOff,
                    "Question options show a box for several answers and a circle for one")
        try require(MessageReaction.addIcon == .addReaction, "Adding a reaction shows its own icon")
        try require(VeraResources.url("interface-icons-NOTICE", ext: "txt") != nil, "The icon notice ships inside the app")

        for section in AppSection.allCases {
            let shows = ConversationTopBarModel.showsRailToggle(section: section)
            try require(shows == !(section == .chat || section == .vera),
                        "Only one sidebar control shows for \(section.rawValue)")
        }
        try require(ConversationTopBarModel.sidebarTitle(collapsed: false) == "Hide sidebar"
                    && ConversationTopBarModel.sidebarTitle(collapsed: true) == "Show sidebar", "The sidebar button says what it will do")
        try require(ConversationTopBarModel.sidebarIcon(collapsed: false) == .sidebarShown
                    && ConversationTopBarModel.sidebarIcon(collapsed: true) == .sidebar
                    && InterfaceIcon.sidebar.resource != InterfaceIcon.sidebarShown.resource,
                    "The sidebar button is filled while the sidebar shows and outlined while it is hidden")

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
        try require(Set(filed.map(\.id)).count == filed.count, "Every chat menu item has its own identity")

        let twins = [ConversationTopBarShot.project("garden-a", "Garden"), ConversationTopBarShot.project("garden-b", "Garden")]
        let twinMove = ConversationTopBarModel.chatMenu(ConversationTopBarShot.titledChat(), projects: twins, companionThread: false)
            .first { $0.title == "Move to project" }?.children ?? []
        try require(twinMove.count == 2 && Set(twinMove.map(\.id)).count == 2,
                    "Two projects with the same name stay separate entries in Move to project")
        try require(twinMove.map(\.action) == [.moveToProject("garden-a"), .moveToProject("garden-b")],
                    "Each same-named project entry moves the chat to its own project")

        let first = ConversationTopBarShot.titledChat()
        var second = Conversation(id: "top-bar-second-chat", title: "Weekend errands",
                                  messages: [Message(role: .user, text: "What do I need this weekend?")], updatedAt: Date(), isPersisted: true)
        second.titleSource = .generated
        let list = [first, second]
        var selection: Conversation? = first
        let captured = ConversationTopBarTarget(selection)
        selection = second
        try require(captured?.resolve(in: list)?.id == first.id && selection?.id == second.id,
                    "Rename and instructions act on the chat that opened them after the selection moves")
        try require(captured?.resolve(in: [second]) == nil, "A captured chat that was deleted resolves to nothing")
        try require(ConversationTopBarTarget(nil) == nil, "No chat, nothing to act on")
        let live = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil)
        live.conversations = [first, second]
        live.selectedID = first.id
        guard let opened = ConversationTopBarTarget(live.selected) else { throw SelfTestFailure("The selected chat can be captured") }
        live.selectedID = second.id
        opened.rename(to: "Raised bed plan", in: live)
        try require(live.conversations.first { $0.id == first.id }?.title == "Raised bed plan"
                    && live.conversations.first { $0.id == second.id }?.title == second.title && live.selected?.id == second.id,
                    "Rename confirmed after the selection moved renames the chat it was opened on and leaves the selected one alone")
        guard let subject = opened.instructionsSubject(in: live) else { throw SelfTestFailure("The captured chat still resolves") }
        live.setConversationInstructions(subject.id, "Keep it short.")
        try require(subject.id == first.id && live.conversations.first { $0.id == first.id }?.instructions == "Keep it short."
                    && live.conversations.first { $0.id == second.id }?.instructions == nil,
                    "Instructions saved after the selection moved go to the chat they were opened on")

        try require(ConversationTopBarModel.chatTitle(ConversationTopBarShot.titledChat(), companionThread: false) == ConversationTopBarShot.chatTitle,
                    "A titled chat shows its title")
        try require(ConversationTopBarModel.chatTitle(nil, companionThread: false) == nil, "No chat, no title")
        try require(ConversationTopBarModel.chatTitle(Conversation(id: "fresh", title: "New chat", messages: [], updatedAt: Date()),
                                                      companionThread: false) == nil, "A chat that has not started has no title yet")
        try require(ConversationTopBarModel.chatTitle(Conversation(id: "saved-empty", title: "New chat", messages: [], updatedAt: Date(),
                                                                   isPersisted: true), companionThread: false) == nil,
                    "A saved chat with no messages and the default title has no title pill")
        var renamedEmpty = Conversation(id: "renamed-empty", title: "Seed list", messages: [], updatedAt: Date(), isPersisted: true)
        renamedEmpty.titleSource = .user
        try require(ConversationTopBarModel.chatTitle(renamedEmpty, companionThread: false) == "Seed list",
                    "A chat the person named shows its title before its history loads")
        try require(ConversationTopBarModel.chatTitle(ConversationTopBarShot.titledChat(), companionThread: true) == nil,
                    "The companion's conversation shows the companion pill instead")

        let every = ConversationTopBarShot.cards().flatMap(\.items).flatMap { [$0] + $0.children }.map(\.title)
            + [ConversationTopBarModel.moreTitle]
        try require(!every.contains { $0.localizedCaseInsensitiveContains("vera") || $0.contains("\u{2014}") },
                    "Menu wording stays plain")
        print("  conversation top bar OK (\(InterfaceIcon.allCases.count) icons, \(InterfaceIconCandidate.allCases.count) alternates, menus, one sidebar control)")
    }
}

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
