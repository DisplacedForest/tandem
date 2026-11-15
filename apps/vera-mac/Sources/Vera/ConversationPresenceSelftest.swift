import Foundation

@MainActor
extension SelfTest {
    static func runConversationPresence() throws {
        let require = NativeTaskFixture.require
        try require(ConversationPresence.greetingFigure(companionThread: false) == .mark, "A standard chat greeting shows the Tandem mark")
        try require(ConversationPresence.replyFigure(companionThread: false) == .none, "A standard chat reply shows no figure")
        try require(ConversationPresence.greetingFigure(companionThread: true) == .companion
                    && ConversationPresence.replyFigure(companionThread: true) == .companion,
                    "Only the companion thread shows the companion figure")

        try require(ConversationPresence.assistantName(companionThread: false, savedName: "Vera") == "Tandem",
                    "An ordinary composer uses the product name even with an old companion name")
        try require(ConversationPresence.assistantName(companionThread: false, savedName: "Cedar") == "Tandem",
                    "A custom companion name never replaces ordinary chat identity")
        try require(ConversationPresence.assistantName(companionThread: true, savedName: "Cedar") == "Cedar"
                    && ConversationPresence.assistantName(companionThread: true, savedName: "Vera") == "Vera",
                    "Companion identity preserves the saved name without renaming user data")

        let owned = "chat-with-work"
        let references = [try OngoingWorkFixture.reference(conversationID: owned, title: "Compare insulation options", state: "running")]
        let other = "no-work-" + UUID().uuidString
        try require(!ConversationPresence.showsWorkPanel(references: references, conversationID: other, wide: true, canvasOpen: false),
                    "A chat without work never shows the work panel, even on a wide window")
        try require(ConversationPresence.showsWorkPanel(references: references, conversationID: owned, wide: true, canvasOpen: false),
                    "A chat with work shows the panel on a wide window")
        try require(!ConversationPresence.showsWorkPanel(references: references, conversationID: owned, wide: true, canvasOpen: true)
                    && !ConversationPresence.showsWorkPanel(references: references, conversationID: owned, wide: false, canvasOpen: false),
                    "The canvas and a narrow window both hide the panel")
        try require(!ConversationPresence.showsWorkPanel(references: [], conversationID: other, wide: true, canvasOpen: false),
                    "A chat without work has no work panel")

        let repository = try LocalChatRepository(inMemory: true)
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(),
            repository: repository, artifactPersistenceEnabled: false)
        store.newConversation()
        try require(!store.isVeraThread(store.selectedID), "A new chat is a standard chat by default")
        try require(ConversationPresence.replyFigure(companionThread: store.isVeraThread(store.selectedID)) == .none,
                    "The default treatment for a conversation is the standard one")
        store.ensureVeraThread()
        store.openVeraThread()
        try require(store.isVeraThread(store.selectedID), "Opening the companion thread selects it")
        try require(ConversationPresence.replyFigure(companionThread: store.isVeraThread(store.selectedID)) == .companion,
                    "The companion thread is the one place the companion figure appears")
        try conversationRows()
    }

    static func conversationRows() throws {
        let require = NativeTaskFixture.require
        let asking = NativeToolActivity(id: "ask", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName, title: "Run a command", round: 1,
                                        request: "{\"command\":\"make pdf\"}", result: nil, state: .pending, confirmationRequired: true)
        try require(NativeToolActivityChip.icon(for: asking, awaitingDecision: true) == .needsYou
                    && !NativeToolActivityChip.showsSpinner(asking, awaitingDecision: true),
                    "A row waiting on the person's decision shows the hand, not a spinner")
        try require(NativeToolActivityChip.showsSpinner(asking, awaitingDecision: false), "A row that is running keeps its spinner")

        let ran = NativeToolActivity(id: "ran", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName, title: "Run a command", round: 1,
                                     request: "{\"command\":\"make check\"}", result: "{\"exit_code\":0}", state: .succeeded, confirmationRequired: true)
        let card = NativeDisplayBlock.commandRun(NativeCommandRun(id: "turn:ran", command: "make check", directory: "/tmp", outcome: .ran))
        let shown = Message(role: .assistant, text: "Done.", toolActivities: [ran, asking], displayBlocks: [card])
        try require(NativeTaskTranscript.visibleActivities(in: shown).map(\.id) == ["ask"],
                    "A command shown as a card is not also listed as a row, and one still waiting stays")
        let bare = Message(role: .assistant, text: "Done.", toolActivities: [ran])
        try require(NativeTaskTranscript.visibleActivities(in: bare).map(\.id) == ["ran"], "A command with no card keeps its row")

        let label = AttachmentRouteBadge.label
        try require(label(MessageRouteNote(route: .direct), ["photo.png"]) == "photo.png couldn't be loaded, so it wasn't sent",
                    "One missing image is named in the note")
        try require(label(MessageRouteNote(route: .direct), ["a.png", "b.png"]) == "a.png, b.png couldn't be loaded, so they weren't sent",
                    "Several missing images are named together")
        try require(label(MessageRouteNote(route: .direct), []) == "Image sent with your message", "A sent image says so plainly")
        try require(label(MessageRouteNote(route: .bridged, bridgeModel: "vl-model"), []) == "Having the image described first",
                    "An image being described says so without naming the second model")
        try require(label(MessageRouteNote(route: .bridged, bridgeModel: "vl-model", disclosure: "An orange square."), [])
                    == "Described by a second model first. The one answering didn't see the image itself.",
                    "A described image explains what the answer saw")
        try require(label(MessageRouteNote(route: .withheld), []) == "Sent without the attachment", "A withheld attachment is unchanged")
        let notes = [label(MessageRouteNote(route: .direct), ["photo.png"]), label(MessageRouteNote(route: .direct), []),
                     label(MessageRouteNote(route: .bridged, bridgeModel: "vl-model"), []),
                     label(MessageRouteNote(route: .bridged, bridgeModel: "vl-model", disclosure: "x"), []),
                     label(MessageRouteNote(route: .withheld), [])]
        let banned = ["model request", "bridge", "vl-model", "\u{2014}", "Tandem"]
        try require(notes.allSatisfy { note in !banned.contains { note.contains($0) } },
                    "Attachment notes never use internal words or a long dash: \(notes)")
    }
}
