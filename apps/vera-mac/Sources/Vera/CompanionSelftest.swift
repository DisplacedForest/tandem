import Foundation

extension SelfTest {
    @MainActor
    static func runCompanion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandem-companion-selftest-\(UUID().uuidString.lowercased())", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "tandem-companion-selftest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NativeTaskFixture.Failure.assertion("companion defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: artifacts)
        let config = NativeChatConfig(
            baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
            model: "local-model", chatTemplateKwargs: nil)
        let store = ChatStore(
            nativeConfig: config, nativeTransport: SelfTestNativeTransport(), repository: repository,
            attachmentStore: NativeAttachmentStore(directory: artifacts))
        store.companionDefaults = defaults
        await store.connect()

        try NativeTaskFixture.require(store.companionUnreadCount == 0 && store.companionLastSeen == nil,
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

        for _ in 0..<500 {
            if let reply = thread()?.messages.last(where: { $0.role == .assistant }), reply.state != .streaming { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let reply = thread()?.messages.last(where: { $0.role == .assistant }) else {
            throw NativeTaskFixture.Failure.assertion("an assistant reply exists")
        }
        try NativeTaskFixture.require(reply.state == .complete && !reply.text.isEmpty, "the reply completes with text")

        store.setCompanionLastSeenForTesting(reply.createdAt.addingTimeInterval(-1))
        try NativeTaskFixture.require(store.companionUnreadCount == 1, "a reply after the last look counts as new")
        store.markCompanionSeen()
        try NativeTaskFixture.require(store.companionUnreadCount == 0, "looking again clears the new count")
        try NativeTaskFixture.require(defaults.object(forKey: ChatStore.companionLastSeenKey) is Date,
                                      "the last look is saved")

        store.setCompanionLastSeenForTesting(nil)
        try NativeTaskFixture.require(store.companionUnreadCount == 0, "no last look means nothing is new")

        print("  companion: PASS (thread prep, draft isolation, panel send, unread count)")
    }
}
