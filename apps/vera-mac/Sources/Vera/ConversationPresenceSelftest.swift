import Foundation

@MainActor
extension SelfTest {
    static func runConversationPresence() throws {
        let require = NativeTaskFixture.require
        try require(ConversationPresence.headerKind(companionThread: false) == .conversation, "A standard chat has the conversation header")
        try require(ConversationPresence.headerKind(companionThread: true) == .none, "The companion thread has no header strip")
        try require(ConversationPresence.headerFigure(companionThread: false) == .none && !ConversationPresence.headerShowsStatus(companionThread: false),
                    "A standard chat header carries no figure and no state line")
        try require(ConversationPresence.greetingFigure(companionThread: false) == .mark, "A standard chat greeting shows the Tandem mark")
        try require(ConversationPresence.replyFigure(companionThread: false) == .none, "A standard chat reply shows no figure")
        try require(ConversationPresence.headerFigure(companionThread: true) == .companion
                    && ConversationPresence.greetingFigure(companionThread: true) == .companion
                    && ConversationPresence.replyFigure(companionThread: true) == .companion,
                    "Only the companion thread shows the companion figure")

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
        try require(ConversationPresence.replyFigure(companionThread: store.isVeraThread(store.selectedID)) == .none
                    && ConversationPresence.headerFigure(companionThread: store.isVeraThread(store.selectedID)) == .none,
                    "The default treatment for a conversation is the standard one")
        store.ensureVeraThread()
        store.openVeraThread()
        try require(store.isVeraThread(store.selectedID), "Opening the companion thread selects it")
        try require(ConversationPresence.replyFigure(companionThread: store.isVeraThread(store.selectedID)) == .companion,
                    "The companion thread is the one place the companion figure appears")
    }
}
