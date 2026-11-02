import Foundation

extension SelfTest {
    @MainActor
    static func runConversationStatus() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let (store, pending) = try NativeTurnCurrencyFixture.pendingTurn(repository)
        defer { store.conversationTurnLoop?.cancel() }
        try require(store.conversationStatusLine == "Ready", "An idle conversation reads as ready")

        let activity = NativeToolActivity(id: "status-confirm", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName,
                                          title: "Run a command", round: 1, request: "{\"command\":\"make check\"}", result: nil,
                                          state: .pending, confirmationRequired: true)
        store.turnConfirmations[pending.assistantMessageID] = NativeToolConfirmationRequest(activity: activity)
        try require(store.conversationStatusLine == "Waiting for your approval", "A pending confirmation asks for approval")
        store.turnConfirmations[pending.assistantMessageID] = nil

        let claimed = try repository.claimTurn(pending.id, attempt: UUID())!
        if let index = store.conversationTurns.firstIndex(where: { $0.id == claimed.id }) { store.conversationTurns[index] = claimed }
        store.turnExecutions[claimed.id] = NativeTurnExecution(claimed)
        try require(store.conversationStatusLine == "Working on your answer", "A running answer without a status reads as working")

        store.setTurnStatus("Searching knowledge…", turn: claimed)
        try require(store.conversationStatusLine == "Searching knowledge…", "A running answer shows its live status")

        store.turnExecutions = [:]
        store.turnStatuses = [:]
        print("CONVERSATION STATUS OK")
    }
}
