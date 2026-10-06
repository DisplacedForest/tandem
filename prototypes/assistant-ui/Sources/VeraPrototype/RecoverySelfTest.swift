import Foundation

@MainActor
enum RecoverySelfTest {
    static func run(root: URL) async throws {
        let endpoint = URL(string: "http://127.0.0.1:49154")!
        let configuration = try PrototypeConfiguration(dataRoot: root, endpoint: endpoint, workspaceRoot: nil)
        let fixture = ContractFixture()
        let client = PrototypeClient(base: endpoint) { try await fixture.send($0) }
        let store = try PrototypeStore(configuration: configuration, client: client)
        await fixture.bind(store.saved.assistantID, store.saved.assistant.id)
        await store.refresh()
        store.setDraft("Continue the existing task")
        await fixture.interruptNextMessage()
        await store.send()
        guard let original = store.pending else { throw PrototypeSelfTest.Failure(name: "Interrupted request missing") }
        let reopened = try PrototypeStore(configuration: configuration, client: client)
        await reopened.refresh()
        await reopened.retry()
        try PrototypeSelfTest.require(reopened.conversationError == PrototypeError.status(409).localizedDescription
                                      && reopened.pending?.messageID == original.messageID && !reopened.canSend,
                                      "Interrupted 409 remains identifiable after restart")
        let originalTasks = Set(reopened.visibleTasks.map(\.id))
        reopened.abandonUnconfirmedReply()
        try PrototypeSelfTest.require(reopened.pending != nil, "Cannot abandon before explicit inspection")
        await fixture.setOffline(true)
        await reopened.reviewUnconfirmedReply()
        reopened.abandonUnconfirmedReply()
        try PrototypeSelfTest.require(reopened.pending != nil && !reopened.canAbandonReply, "Failed refresh cannot authorize recovery")
        await fixture.setOffline(false)
        await reopened.reviewUnconfirmedReply()
        try PrototypeSelfTest.require(reopened.canAbandonReply && reopened.pendingTasks.count == 1,
                                      "Explicit inspection shows only associated task")
        let requestsBefore = await fixture.requests.count
        reopened.abandonUnconfirmedReply()
        let requestsAfter = await fixture.requests.count
        try PrototypeSelfTest.require(requestsBefore == requestsAfter && reopened.canSend && reopened.pending == nil,
                                      "Abandon sends nothing and unlocks composer")
        try PrototypeSelfTest.require(reopened.saved.abandonedReplies?.last?.messageID == original.messageID
                                      && reopened.conversation.draft.isEmpty && Set(reopened.visibleTasks.map(\.id)) == originalTasks,
                                      "Original identity and tasks remain; unchanged draft cannot invite accidental replay")
        try PrototypeSelfTest.require(reopened.messages.contains { UUID(uuidString: $0.id) == original.messageID },
                                      "Accepted original user message remains in transcript")
        let again = try PrototypeStore(configuration: configuration, client: client)
        await again.refresh()
        try PrototypeSelfTest.require(again.canSend && again.saved.abandonedReplies?.last?.messageID == original.messageID,
                                      "Recovery persists across restart")
        again.setDraft("A fresh question")
        await again.send()
        let fresh = await fixture.requests.last
        try PrototypeSelfTest.require(again.pending == nil && fresh?.messageID != original.messageID && fresh?.text == "A fresh question",
                                      "Only explicit fresh Send creates a new request")
        await fixture.interruptNextMessage()
        again.setDraft("Another interrupted turn")
        await again.send()
        again.setDraft("Keep this revised draft")
        await again.reviewUnconfirmedReply()
        again.abandonUnconfirmedReply()
        try PrototypeSelfTest.require(again.conversation.draft == "Keep this revised draft" && again.canSend,
                                      "Recovery preserves a revised draft")
        print("PASS: interrupted 409 recovery, inspection gate, no automatic resend, archived identity, preserved tasks and drafts")
    }
}
