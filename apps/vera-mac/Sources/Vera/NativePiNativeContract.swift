import Foundation
import VeraAssistantUI

@MainActor
enum NativePiNativeContract {
    static func task(_ session: AssistantSession, state: String) async throws -> AssistantSessionTask {
        for _ in 0..<100 {
            await session.refresh()
            if let task = session.tasks.first(where: { $0.state == state }) { return task }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PiBrokerError.unavailable
    }
    static func run(_ arguments: [String], recovery: Bool = false, reopen: Bool = false) async {
        var current: NativePiPresentation?
        var stage = "startup"
        do {
            let candidate = try await NativePiCandidate.create(arguments)
            let presentation = NativePiPresentation(factory: {
                NativePiConnection(workspace: candidate.workspace, stop: { await candidate.stop() })
            })
            current = presentation
            try piCheck(presentation.session == nil && !presentation.canSend)
            await presentation.connect()
            guard let session = presentation.session else { throw PiBrokerError.unavailable }
            if reopen {
                let report: [String: Any] = ["conversation_id": session.id.uuidString.lowercased(),
                    "projected_ids": presentation.conversation!.messages.map { $0.id.uuidString },
                    "archived_message_ids": session.archivedReplyIDs.map { $0.uuidString.lowercased() },
                    "task_ids": session.tasks.map(\.id).sorted(), "pending": session.pendingID != nil, "draft": session.draft]
                await presentation.stop()
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]))
                return
            }
            if recovery {
                var report = try await recover(presentation)
                report["assistant_id"] = candidate.workspace.assistantID.uuidString.lowercased()
                await presentation.stop()
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]))
                return
            }
            let repository = try LocalChatRepository(inMemory: true)
            let classic = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository,
                attachmentStore: NativeAttachmentStore(directory: candidate.root.url.appendingPathComponent("attachments")),
                artifactPersistenceEnabled: false)
            classic.newConversation()
            classic.draft = "Keep this focused draft"
            let conversations = classic.conversations
            let route = NativeComposerRoute(store: classic, assistant: presentation)
            try piCheck(!route.allowsAttachments && !route.addFiles([candidate.root.url.appendingPathComponent("not-an-image")])
                && classic.attachmentError == nil)
            let id = session.id
            try piCheck(session.connectionLabel == "Test runtime" && session.messages.isEmpty)
            presentation.isSelected = true
            route.draft = "/task Verify addition in the isolated example"
            route.send()
            for _ in 0..<100 {
                if session.messages.count == 2 && session.pendingID == nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            stage = "approval wait"
            let first = try await task(session, state: "needs_decision")
            guard let decision = first.decisionID else { throw PiBrokerError.invalid }
            await session.reply(taskID: first.id, decisionID: UUID().uuidString, approved: true)
            try piCheck(session.tasks.first?.state == "needs_decision")
            stage = "approved work"
            await session.reply(taskID: first.id, decisionID: decision, approved: true)
            _ = try await task(session, state: "running")
            stage = "foreground reply"
            route.draft = "What are you working on?"
            await session.send()
            await session.refresh()
            try piCheck(session.pendingID == nil && session.messages.count >= 4
                && session.tasks.contains { $0.id == first.id && $0.state == "running" })
            presentation.isSelected = false
            try piCheck(presentation.connection != nil && classic.conversations == conversations && classic.draft == "Keep this focused draft")
            stage = "completion"
            let finished = try await task(session, state: "completed")
            try piCheck(finished.id == first.id)
            guard let output = session.output(taskID: first.id, index: 0) else { throw PiBrokerError.invalid }
            await session.refresh()
            stage = "stable projection"
            let projected = presentation.conversation!.messages
            await session.refresh()
            await session.refresh()
            try piCheck(presentation.conversation!.messages == projected)
            let resultID = NativePiPresentation.messageID(conversation: id, source: "task:" + first.id)
            try piCheck(projected.filter { $0.id == resultID }.count == 1)
            stage = "second task"
            presentation.draft = "/task Check another isolated example"
            await session.send()
            let second = try await task(session, state: "needs_decision")
            try piCheck(second.id != first.id)
            stage = "task cancellation"
            await session.stop(taskID: second.id)
            await session.refresh()
            try piCheck(session.tasks.contains { $0.id == second.id && $0.state == "canceled" })
            try piCheck(classic.conversations == conversations && classic.draft == "Keep this focused draft")
            stage = "final projection"
            let finalIDs = presentation.conversation!.messages.map(\.id)
            await presentation.stop()
            try piCheck(presentation.connection == nil && !presentation.canSend)
            try NativePiCandidate.verifyNoCredentialFiles(candidate.root.url)
            let report: [String: Any] = ["transport": "app-owned-mock", "native_components": true,
                "assistant_id": candidate.workspace.assistantID.uuidString.lowercased(), "conversation_id": id.uuidString.lowercased(),
                "completed_task_id": first.id, "stopped_task_id": second.id, "artifact_path": output.path,
                "foreground_while_worker_active": true, "result_deliveries": 1, "projected_ids": finalIDs.map { $0.uuidString },
                "classic_store_unchanged": true, "real_provider_calls": 0, "real_keychain_reads": 0, "visible_launch": false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]))
        } catch {
            if let current { await current.stop() }
            FileHandle.standardError.write(Data("Native assistant contract failed during \(stage): \(type(of: error))\n".utf8))
            exit(1)
        }
    }
    static func recover(_ presentation: NativePiPresentation) async throws -> [String: Any] {
        guard let session = presentation.session, let pending = session.pendingID else { throw PiBrokerError.invalid }
        let tasks = session.tasks.map(\.id).sorted()
        try piCheck(!tasks.isEmpty)
        await session.retry(messageID: pending)
        try piCheck(session.pendingID == pending && !session.canSend)
        await session.review(messageID: pending)
        try piCheck(session.canContinue)
        presentation.draft = "Preserve edited recovery draft"
        session.continueWithoutReply(messageID: UUID())
        try piCheck(session.pendingID == pending)
        session.continueWithoutReply(messageID: pending)
        await session.refresh()
        try piCheck(session.pendingID == nil && session.tasks.map(\.id).sorted() == tasks
            && presentation.draft == "Preserve edited recovery draft")
        let report: [String: Any] = ["archived_message_id": pending.uuidString.lowercased(), "original_task_ids": tasks,
            "tasks_unchanged": true, "fresh_send_attempted": false, "edited_draft_preserved": true, "visible_launch": false]
        return report
    }
}
