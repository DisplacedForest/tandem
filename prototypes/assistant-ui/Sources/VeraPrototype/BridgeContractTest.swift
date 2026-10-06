import Foundation

@MainActor
enum BridgeContractTest {
    static func run(configuration: PrototypeConfiguration) async throws {
        let store = try PrototypeStore(configuration: configuration)
        await store.refresh()
        try PrototypeSelfTest.require(store.capabilities?.transport == "mock" && store.canSend, "Contract test requires an explicit mock bridge")
        store.setDraft("/task Verify addition in the isolated example")
        await store.send()
        try PrototypeSelfTest.require(store.pending == nil && store.messages.count == 2, "Bridge accepted assistant message")
        let first = try await awaitTask(store, state: "needs_decision")
        store.setDraft("What are you working on?")
        await store.send()
        try PrototypeSelfTest.require(store.messages.count >= 4 && store.pending == nil, "Foreground remains responsive with a waiting task")
        await store.reply(first, approved: true)
        let completed = try await awaitTask(store, state: "completed")
        try PrototypeSelfTest.require(completed.id == first.id, "Stable task identity through completion")
        guard let output = completed.result?.artifacts?.first else { throw PrototypeError.invalidResponse }
        try PrototypeSelfTest.require(output.resolved(in: configuration.workspaceRoot) != nil, "Real task artifact resolves within configured workspace")
        store.setDraft("/task Check a second isolated example")
        await store.send()
        let second = try await awaitTask(store, state: "needs_decision")
        try PrototypeSelfTest.require(second.id != first.id, "Second task identity")
        await store.stop(second)
        await store.refresh()
        try PrototypeSelfTest.require(store.visibleTasks.first(where: { $0.id == second.id })?.state == "canceled", "Task-specific Stop reaches bridge")
        try PrototypeSelfTest.require(store.visibleTasks.first(where: { $0.id == first.id })?.state == "completed", "Stop leaves completed task unchanged")
        store.newChat()
        let focusedID = store.conversation.id
        await store.refresh()
        try PrototypeSelfTest.require(store.visibleTasks.isEmpty, "Focused conversation scope")
        store.setDraft("/task A focused question only")
        await store.send()
        await store.refresh()
        try PrototypeSelfTest.require(store.pending == nil && store.visibleTasks.isEmpty, "Focused mode cannot hand off a worker")
        let reopened = try PrototypeStore(configuration: configuration)
        await reopened.refresh()
        try PrototypeSelfTest.require(reopened.saved.assistantID == store.saved.assistantID && reopened.messages.count >= 4, "Real bridge transcript reopens")
        reopened.destination = .conversation(focusedID)
        await reopened.refresh()
        try PrototypeSelfTest.require(reopened.messages.count == 2, "Focused transcript reopens separately")
        print("PASS: actual mock bridge HTTP, assistant and focused messages, task approval, completed output file, task-specific Stop, persisted identity and transcript")
    }

    static func recover(configuration: PrototypeConfiguration) async throws {
        let store = try PrototypeStore(configuration: configuration)
        guard store.saved.pending.count == 1, let original = store.pending, original.mode == "assistant" else {
            throw PrototypeSelfTest.Failure(name: "Recovery requires one pending assistant message")
        }
        await store.refresh()
        try PrototypeSelfTest.require(store.capabilities?.transport == "mock" && store.connectionError == nil,
                                      "Recovery requires the isolated mock bridge")
        let originalTaskIDs = Set(store.visibleTasks.map(\.id))
        await store.retry()
        try PrototypeSelfTest.require(store.pending?.messageID == original.messageID && !store.canSend
                                      && store.conversationError == PrototypeError.replyUnconfirmed.localizedDescription,
                                      "Interrupted turn returns 409 and retains original request")
        try PrototypeSelfTest.require(!store.canAbandonReply, "Recovery needs explicit inspection")
        await store.reviewUnconfirmedReply()
        try PrototypeSelfTest.require(store.canAbandonReply, "Fresh transcript and task inspection enables recovery")
        store.abandonUnconfirmedReply()
        try PrototypeSelfTest.require(store.pending == nil && store.canSend
                                      && store.saved.abandonedReplies?.last?.messageID == original.messageID,
                                      "Explicit abandonment preserves original identity and unlocks composer")
        await store.refresh()
        try PrototypeSelfTest.require(Set(store.visibleTasks.map(\.id)) == originalTaskIDs,
                                      "Abandonment preserves original tasks without new delegation")
        let reopened = try PrototypeStore(configuration: configuration)
        await reopened.refresh()
        try PrototypeSelfTest.require(reopened.pending == nil && reopened.saved.abandonedReplies?.last?.messageID == original.messageID,
                                      "Abandoned identity persists across restart")
        reopened.setDraft("What is the current prototype status?")
        await reopened.send()
        await reopened.refresh()
        try PrototypeSelfTest.require(reopened.pending == nil && reopened.canSend && reopened.conversationError == nil,
                                      "Explicit fresh message succeeds after interruption")
        try PrototypeSelfTest.require(Set(reopened.visibleTasks.map(\.id)) == originalTaskIDs,
                                      "Fresh status message does not duplicate interrupted tasks")
        print("PASS: interrupted real bridge 409, explicit inspection and abandonment, archived identity, original tasks retained, explicit fresh message")
    }

    private static func awaitTask(_ store: PrototypeStore, state: String) async throws -> TaskSnapshot {
        for _ in 0..<80 {
            await store.refresh()
            if let task = store.visibleTasks.first(where: { $0.state == state }) { return task }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PrototypeSelfTest.Failure(name: "Bridge task did not reach " + state)
    }
}
