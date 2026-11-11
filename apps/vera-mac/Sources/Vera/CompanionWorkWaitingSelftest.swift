import Foundation

extension SelfTest {
    @MainActor
    static func runCompanionWorkWaiting() throws {
        let require = NativeTaskFixture.require
        let saved = CompanionSavedTextFixture.self
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil)
        let thread = Conversation(id: "waiting-companion", title: "Companion", messages: [
            Message(role: .user, text: "Sort the seed folders."),
            Message(role: .assistant, text: "I'll sort them in the background."),
        ], updatedAt: Date(), originType: ChatStore.veraThreadOriginType, originID: ChatStore.veraThreadOriginID)
        let ordinary = Conversation(id: "waiting-ordinary", title: "Other", messages: [], updatedAt: Date())
        store.conversations = [thread, ordinary]
        store.ensureVeraThread()
        store.selectedID = ordinary.id
        try require(store.veraThreadID == thread.id, "The companion conversation exists")
        let threadID = thread.id
        func messageCount() -> Int { store.conversations.first { $0.id == threadID }?.messages.count ?? -1 }
        let messages = messageCount()

        let waiting = try saved.reference(state: "needs_decision", conversationID: threadID, decision: saved.approvalDecision())
        let notWaiting: [(NativeTaskReference, String)] = [
            (try OngoingWorkFixture.reference(conversationID: threadID, title: "Compare seed vendors", state: "needs_decision",
                                              decision: OngoingWorkFixture.decision), "Research waiting on a retry is not an approval"),
            (try saved.reference(state: "needs_decision", conversationID: threadID, decision: OngoingWorkFixture.decision),
             "Companion work waiting on a retry is not an approval"),
            (try saved.reference(state: "needs_decision", conversationID: ordinary.id, decision: saved.approvalDecision()),
             "Companion work started in another conversation is not waiting here"),
            (try saved.reference(state: "running", conversationID: threadID), "Running companion work is not waiting"),
            (try saved.reference(state: "completed", conversationID: threadID, result: saved.result("Done.", shape: nil)),
             "Answered companion work is not waiting"),
        ]
        for (reference, message) in notWaiting {
            store.nativeTaskReferences = [reference]
            try require(store.companionWorkAwaitingApproval == nil && !store.companionApprovalWaiting, message)
        }
        store.nativeTaskReferences = notWaiting.map(\.0)
        try require(!store.companionApprovalWaiting, "None of the other tasks makes the panel ask for approval")

        store.nativeTaskReferences.append(waiting)
        try require(store.companionWorkAwaitingApproval?.id == waiting.id, "Companion work asking for approval is found")
        try require(store.companionApprovalWaiting, "The panel shows the approval banner for waiting companion work")
        try require(messageCount() == messages, "Work moving into waiting posts no message")

        store.revealCompanionWorkApproval()
        try require(store.selectedID == threadID, "The approval opens the companion conversation")
        try require(store.pendingTaskReveal == waiting.id.uuidString, "The approval scrolls to the waiting task")
        let owner = Message(id: waiting.origin.assistantMessageID, role: .assistant, text: "I'll sort them in the background.")
        try require(OngoingWork.owningMessageID(taskID: waiting.id.uuidString, fallback: waiting.origin.assistantMessageID,
                                                in: [owner]) == waiting.origin.assistantMessageID,
                    "The scroll lands on the message that started the task")
        store.pendingTaskReveal = nil
        store.revealCompanionWorkApproval()
        try require(store.pendingTaskReveal == waiting.id.uuidString, "Pressing the banner button always scrolls to the task")

        store.pendingTaskReveal = nil
        store.revealedCompanionWorkDecisionID = nil
        store.select(ordinary.id)
        store.openVeraThread()
        try require(store.pendingTaskReveal == waiting.id.uuidString, "Opening the companion conversation scrolls to the waiting task")
        store.pendingTaskReveal = nil
        store.openVeraThread()
        try require(store.pendingTaskReveal == nil, "Opening the conversation again does not scroll again")
        store.select(threadID)
        try require(store.pendingTaskReveal == nil, "Selecting the conversation again does not scroll again")
        store.select(ordinary.id)
        store.select(threadID)
        try require(store.pendingTaskReveal == nil, "Coming back to the conversation does not scroll again")

        let next = try saved.reference(state: "needs_decision", conversationID: threadID,
                                       decision: ["id": "next-approval", "prompt": saved.approvalQuestion, "choices": ["decline", "approve"]])
        store.nativeTaskReferences = [next]
        store.openVeraThread()
        try require(store.pendingTaskReveal == next.id.uuidString, "A new approval scrolls to its task once")
        store.pendingTaskReveal = nil
        try require(messageCount() == messages, "The scroll calls post no message")

        let user = Message(role: .user, text: "Run make check")
        let turn = NativeConversationTurn(id: UUID(), conversationID: threadID, userMessageID: user.id, assistantMessageID: UUID(),
            mode: .chat, profile: "", enabledToolIDs: [], persona: "Persona", userScope: "", instructions: "", grounding: [],
            memorySettings: store.nativeMemorySettings, createdAt: Date(), history: [NativeTurnHistoryMessage(user)])
        let activity = NativeToolActivity(id: "waiting-confirm", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName,
                                          title: "Run a command", round: 1, request: "{\"command\":\"make check\"}", result: nil,
                                          state: .pending, confirmationRequired: true)
        store.conversationTurns = [turn]
        store.turnConfirmations[turn.assistantMessageID] = NativeToolConfirmationRequest(activity: activity)
        store.nativeTaskReferences = [waiting]
        store.revealedCompanionWorkDecisionID = nil
        try require(store.companionAwaitingApproval && store.companionApprovalWaiting, "A waiting chat answer shows the banner")
        store.revealCompanionWorkApproval()
        try require(store.pendingTaskReveal == nil, "A waiting chat answer goes first, the task is not scrolled to")
        store.select(ordinary.id)
        store.openVeraThread()
        try require(store.pendingTaskReveal == nil, "Opening the conversation leaves the chat answer's card in view")
        try require(messageCount() == messages, "Waiting work never adds a message")
        print("  companion work waiting OK (approval only, companion conversation only, scrolls once, chat answer first)")
    }
}
