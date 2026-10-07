import Foundation

@MainActor
enum BridgeContractTest {
    static func run(configuration: PrototypeConfiguration) async throws {
        let store = try PrototypeStore(configuration: configuration)
        _ = try await workflow(store: store)
        print("PASS: actual mock bridge HTTP, assistant and focused messages, task approval, completed output file, task-specific Stop, persisted identity and transcript")
    }

    static func workflow(store: PrototypeStore, requireActiveWorker: Bool = false) async throws -> Data {
        await store.refresh()
        try PrototypeSelfTest.require(store.capabilities?.transport == "mock" && store.canSend, "Contract test requires an explicit mock bridge")
        try PrototypeSelfTest.require(store.saved.conversations.isEmpty && store.messages.isEmpty && store.visibleTasks.isEmpty,
                                      "Workflow requires a fresh assistant workspace")
        store.setDraft("/task Verify addition in the isolated example")
        await store.send()
        try PrototypeSelfTest.require(store.pending == nil && store.messages.count == 2, "Bridge accepted assistant message")
        let first = try await awaitTask(store, state: "needs_decision")
        await store.reply(first, approved: true)
        try PrototypeSelfTest.require(store.taskErrors[first.id] == nil, "Approval accepted")
        if requireActiveWorker {
            _ = try await awaitTask(store, state: "running")
        }
        store.setDraft("What are you working on?")
        await store.send()
        try PrototypeSelfTest.require(store.messages.count >= 4 && store.pending == nil, "Foreground remains responsive with an active task")
        if requireActiveWorker {
            await store.refresh()
            try PrototypeSelfTest.require(store.connectionError == nil && store.visibleTasks.contains { $0.id == first.id && $0.state == "running" },
                                          "Foreground reply completes while the worker remains running")
        }
        let completed = try await awaitTask(store, state: "completed")
        try PrototypeSelfTest.require(completed.id == first.id, "Stable task identity through completion")
        guard let output = completed.result?.artifacts?.first,
              let outputURL = output.resolved(in: store.configuration.workspaceRoot) else { throw PrototypeError.artifact }
        await store.refresh()
        await store.refresh()
        try PrototypeSelfTest.require(store.messages.filter { $0.id == "task:" + first.id }.count == 1,
                                      "Completed task result delivered once")
        store.newChat()
        let focusedID = store.conversation.id
        await store.refresh()
        try PrototypeSelfTest.require(store.visibleTasks.isEmpty, "Focused conversation scope")
        store.setDraft("/task A focused question only")
        await store.send()
        await store.refresh()
        try PrototypeSelfTest.require(store.pending == nil && store.visibleTasks.isEmpty, "Focused mode cannot hand off a worker")
        let reopened = try PrototypeStore(configuration: store.configuration, client: store.client)
        await reopened.refresh()
        try PrototypeSelfTest.require(reopened.saved.assistantID == store.saved.assistantID && reopened.messages.count >= 4, "Real bridge transcript reopens")
        try PrototypeSelfTest.require(reopened.messages.filter { $0.id == "task:" + first.id }.count == 1, "Reopen preserves single result delivery")
        reopened.destination = .conversation(focusedID)
        await reopened.refresh()
        try PrototypeSelfTest.require(reopened.messages.count == 2, "Focused transcript reopens separately")
        store.destination = .assistant
        await store.refresh()
        store.setDraft("/task Check a second isolated example")
        await store.send()
        let second = try await awaitTask(store, state: "needs_decision")
        try PrototypeSelfTest.require(second.id != first.id, "Second task identity")
        await store.stop(second)
        await store.refresh()
        try PrototypeSelfTest.require(store.visibleTasks.first(where: { $0.id == second.id })?.state == "canceled", "Task-specific Stop reaches bridge")
        try PrototypeSelfTest.require(store.visibleTasks.first(where: { $0.id == first.id })?.state == "completed", "Stop leaves completed task unchanged")
        return try JSONSerialization.data(withJSONObject: [
            "assistant_id": store.saved.assistantID.uuidString.lowercased(),
            "conversation_id": store.saved.assistant.id.uuidString.lowercased(),
            "completed_task_id": first.id, "stopped_task_id": second.id,
            "focused_conversation_id": focusedID.uuidString.lowercased(),
            "artifact_path": outputURL.path, "result_deliveries": 1,
            "foreground_reply": true, "foreground_while_worker_active": requireActiveWorker, "focused_no_delegation": true, "reopened": true
        ], options: [.sortedKeys])
    }

    static func recover(configuration: PrototypeConfiguration) async throws {
        let store = try PrototypeStore(configuration: configuration)
        _ = try await recovery(store: store)
        print("PASS: interrupted real bridge 409, explicit inspection and abandonment, archived identity, original tasks retained, explicit fresh message")
    }

    static func recovery(store: PrototypeStore, requireFreshReply: Bool = true) async throws -> Data {
        guard store.saved.pending.count == 1, let original = store.pending, original.mode == "assistant" else {
            throw PrototypeSelfTest.Failure(name: "Recovery requires one pending assistant message")
        }
        await store.refresh()
        try PrototypeSelfTest.require(store.capabilities?.transport == "mock" && store.connectionError == nil,
                                      "Recovery requires the isolated mock bridge")
        let originalTaskIDs = Set(store.visibleTasks.map(\.id))
        try PrototypeSelfTest.require(!originalTaskIDs.isEmpty, "Recovery retains accepted work")
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
        try PrototypeSelfTest.require(store.connectionError == nil && Set(store.visibleTasks.map(\.id)) == originalTaskIDs,
                                      "Abandonment preserves original tasks without new delegation")
        let reopened = try PrototypeStore(configuration: store.configuration, client: store.client)
        await reopened.refresh()
        try PrototypeSelfTest.require(reopened.connectionError == nil && reopened.saved.assistantID == store.saved.assistantID
                                      && reopened.saved.assistant.id == store.saved.assistant.id && reopened.pending == nil && reopened.saved.abandonedReplies?.last?.messageID == original.messageID,
                                      "Abandoned identity persists across restart")
        try PrototypeSelfTest.require(Set(reopened.visibleTasks.map(\.id)) == originalTaskIDs,
                                      "Reopen preserves original task identities")
        if !requireFreshReply {
            return try JSONSerialization.data(withJSONObject: [
                "assistant_id": reopened.saved.assistantID.uuidString.lowercased(),
                "conversation_id": reopened.saved.assistant.id.uuidString.lowercased(),
                "archived_message_id": original.messageID.uuidString.lowercased(),
                "original_task_ids": originalTaskIDs.sorted(), "tasks_unchanged": true,
                "archived_on_reopen": true, "fresh_reply": false, "fresh_send_attempted": false
            ], options: [.sortedKeys])
        }
        let previousMessageIDs = Set(reopened.messages.map(\.id))
        reopened.setDraft("What is the current prototype status?")
        await reopened.send()
        await reopened.refresh()
        try PrototypeSelfTest.require(reopened.pending == nil && reopened.canSend && reopened.conversationError == nil,
                                      "Explicit fresh message succeeds after interruption")
        try PrototypeSelfTest.require(Set(reopened.visibleTasks.map(\.id)) == originalTaskIDs,
                                      "Fresh status message does not duplicate interrupted tasks")
        let freshMessages = reopened.messages.filter { $0.role == "user" && !previousMessageIDs.contains($0.id) }
        try PrototypeSelfTest.require(freshMessages.count == 1 && UUID(uuidString: freshMessages[0].id) != original.messageID,
                                      "Recovery sends exactly one new message identity")
        return try JSONSerialization.data(withJSONObject: [
            "assistant_id": reopened.saved.assistantID.uuidString.lowercased(),
            "conversation_id": reopened.saved.assistant.id.uuidString.lowercased(),
            "archived_message_id": original.messageID.uuidString.lowercased(),
            "fresh_message_id": freshMessages[0].id,
            "original_task_ids": originalTaskIDs.sorted(), "tasks_unchanged": true,
            "archived_on_reopen": true, "fresh_reply": true, "fresh_send_attempted": true
        ], options: [.sortedKeys])
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
