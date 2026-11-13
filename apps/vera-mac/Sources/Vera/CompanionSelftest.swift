import Foundation

extension SelfTest {
    @MainActor
    static func runCompanion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandem-companion-selftest-\(UUID().uuidString.lowercased())", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = AppLocations.scratchPreferences()
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: artifacts)
        let config = NativeChatConfig(
            baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
            model: "local-model", chatTemplateKwargs: nil)
        let store = ChatStore(
            nativeConfig: config, nativeTransport: SelfTestNativeTransport(), repository: repository,
            attachmentStore: NativeAttachmentStore(directory: artifacts))
        store.companionDefaults = defaults
        await store.connect()

        try NativeTaskFixture.require(store.companionUnreadCount == 0 && store.companionSeenReplyID == nil,
                                      "unread is zero before the panel has ever been seen")

        store.newConversation()
        let otherID = store.selectedID
        let sectionBefore = store.section
        try NativeTaskFixture.require(otherID != nil, "a main conversation is selected")
        store.prepareCompanionThread()
        try NativeTaskFixture.require(store.veraThreadID != nil, "prepare creates the assistant thread")
        try NativeTaskFixture.require(store.selectedID == otherID && store.section == sectionBefore,
                                      "prepare leaves the main selection and section alone")

        store.draft = "main draft"
        store.companionDraft = "hello"
        store.prepareCompanionThread()
        store.markCompanionSeen()
        store.prepareCompanionThread()
        store.markCompanionSeen()
        try NativeTaskFixture.require(store.companionDraft == "hello", "the panel draft survives hide and show")
        try NativeTaskFixture.require(store.draft == "main draft", "hide and show leave the main draft alone")

        store.companionDraft = "from the panel"
        try NativeTaskFixture.require(store.sendCompanion(), "sending from the panel succeeds")
        guard let threadID = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("thread id after send") }
        func thread() -> Conversation? { store.conversations.first { $0.id == threadID } }
        try NativeTaskFixture.require(
            thread()?.messages.last(where: { $0.role == .user })?.text == "from the panel",
            "the panel message lands in the assistant thread")
        try NativeTaskFixture.require(store.selectedID == otherID, "sending keeps the main selection")
        try NativeTaskFixture.require(store.draft == "main draft", "sending keeps the main draft")
        try NativeTaskFixture.require(store.companionDraft.isEmpty && store.companionAttachments.isEmpty
                                      && store.companionError == nil, "sending clears the panel composer")
        let other = store.conversations.first { $0.id == otherID }
        try NativeTaskFixture.require(other?.messages.isEmpty == true, "the main conversation gets no message")

        let streamingReplies = thread()?.messages.filter { $0.role == .assistant && $0.state == .complete }.count ?? 0
        store.markCompanionSeen()
        try NativeTaskFixture.require(streamingReplies == 0 && store.companionSeenReplyID == "",
                                      "showing the panel mid-reply acknowledges only what had finished")

        func completed() -> [Message] {
            thread()?.messages.filter { $0.role == .assistant && $0.state == .complete && !$0.text.isEmpty } ?? []
        }
        func settle() async throws {
            for _ in 0..<500 {
                if thread()?.messages.contains(where: { $0.role == .assistant && $0.state == .streaming }) == false { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NativeTaskFixture.Failure.assertion("the assistant reply settles")
        }
        try await settle()
        guard let reply = thread()?.messages.last(where: { $0.role == .assistant }) else {
            throw NativeTaskFixture.Failure.assertion("an assistant reply exists")
        }
        try NativeTaskFixture.require(reply.state == .complete && !reply.text.isEmpty, "the reply completes with text")
        try NativeTaskFixture.require(store.companionUnreadCount == 2,
                                      "the opening and reply that finish after the panel was shown count as new")
        store.markCompanionSeen()
        try NativeTaskFixture.require(store.companionUnreadCount == 0 && store.companionSeenReplyID == reply.id.uuidString,
                                      "looking again acknowledges the finished reply")

        store.setCompanionSeenReplyForTesting(nil)
        try NativeTaskFixture.require(store.companionUnreadCount == 0 && store.companionSeenReplyID == nil,
                                      "a panel never seen shows nothing new even with a finished reply")

        store.setCompanionSeenReplyForTesting("")
        try NativeTaskFixture.require(store.companionUnreadCount == completed().count && completed().count == 2,
                                      "seen with no replies yet counts every finished reply")
        try NativeTaskFixture.require(defaults.string(forKey: ChatStore.companionSeenKey) == "",
                                      "the empty marker is saved")

        let rebuilt = ChatStore(
            nativeConfig: config, nativeTransport: SelfTestNativeTransport(), repository: repository,
            attachmentStore: NativeAttachmentStore(directory: artifacts))
        rebuilt.companionDefaults = defaults
        await rebuilt.connect()
        rebuilt.prepareCompanionThread()
        try NativeTaskFixture.require(rebuilt.veraThreadID == threadID, "a rebuilt store finds the same assistant thread")
        try NativeTaskFixture.require(rebuilt.companionSeenReplyID == "" && rebuilt.companionUnreadCount == 2,
                                      "a rebuilt store reads the saved marker and the same new count")

        store.markCompanionSeen()
        try NativeTaskFixture.require(store.companionUnreadCount == 0 && store.companionSeenReplyID == reply.id.uuidString,
                                      "acknowledging marks the last finished reply")
        try NativeTaskFixture.require(defaults.string(forKey: ChatStore.companionSeenKey) == reply.id.uuidString,
                                      "the acknowledged reply is saved")
        let reread = ChatStore(
            nativeConfig: config, nativeTransport: SelfTestNativeTransport(), repository: repository,
            attachmentStore: NativeAttachmentStore(directory: artifacts))
        reread.companionDefaults = defaults
        await reread.connect()
        reread.prepareCompanionThread()
        try NativeTaskFixture.require(reread.companionSeenReplyID == reply.id.uuidString && reread.companionUnreadCount == 0,
                                      "a rebuilt store keeps the acknowledged reply")

        guard let otherID else { throw NativeTaskFixture.Failure.assertion("main conversation id") }
        store.setCompanionSeenReplyForTesting("")
        store.select(threadID)
        try NativeTaskFixture.require(store.companionSeenReplyID == reply.id.uuidString,
                                      "opening the thread in the main window acknowledges it")
        try NativeTaskFixture.require(store.sendText("while open", conversationID: threadID), "a reply arrives while the thread is open")
        try await settle()
        store.select(otherID)
        try NativeTaskFixture.require(store.companionSeenReplyID == completed().last?.id.uuidString,
                                      "leaving the thread acknowledges the reply that arrived while it was open")
        try NativeTaskFixture.require(store.sendText("after leaving", conversationID: threadID), "a reply arrives after leaving")
        try await settle()
        try NativeTaskFixture.require(completed().count == 4 && store.companionUnreadCount == 1,
                                      "only the reply after leaving the thread counts as new")
        try NativeTaskFixture.require(store.selectedID == otherID, "replies in the thread keep the main selection")

        store.select(threadID)
        store.section = .memory
        let acknowledgedOnLeave = store.companionSeenReplyID
        try NativeTaskFixture.require(acknowledgedOnLeave == completed().last?.id.uuidString, "leaving the companion section acknowledges what was shown")
        try NativeTaskFixture.require(store.sendText("while on another section", conversationID: threadID), "a reply arrives while another section shows")
        try await settle()
        try NativeTaskFixture.require(store.companionUnreadCount == 1, "a reply that arrives while another section shows counts as new")
        store.select(otherID)
        try NativeTaskFixture.require(store.companionUnreadCount == 1 && store.companionSeenReplyID == acknowledgedOnLeave,
                                      "selecting another chat afterwards does not acknowledge the unseen reply")

        try NativeTaskFixture.require(!store.companionAwaitingApproval, "nothing awaits approval without a pending tool turn")

        print("  companion: PASS (thread prep, draft isolation, panel send, acknowledgement, rebuild, main window, section navigation, approval)")
    }
}
