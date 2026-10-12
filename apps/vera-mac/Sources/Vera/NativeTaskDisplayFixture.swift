import Foundation

@MainActor
enum NativeTaskDisplayFixture {
    static func snapshot(_ reference: NativeTaskReference, id: String, state: String,
                         decision: [String: Any]? = nil, result: [String: Any]? = nil,
                         canceled: Bool = false, checkpoint: [String: Any]? = nil) throws -> NativeTaskSnapshot {
        var object = try JSONSerialization.jsonObject(with: NativeTaskFixture.snapshot(
            reference, id: id, state: state, canceled: canceled)) as! [String: Any]
        object["decision"] = decision
        object["result"] = result
        if let checkpoint { object["checkpoint"] = checkpoint }
        return try JSONDecoder().decode(NativeTaskSnapshot.self, from: NativeTaskClient.canonical(object))
    }

    static func run() async throws {
        try NativeTaskDisplaySelfTest.run()
        try NativeTaskEventsSelfTest.run()
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chat.sqlite")
        let repository = try LocalChatRepository(url: url)
        let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!)
        let origin = try NativeTaskFixture.origin(repository)
        let request = try NativeResearchTaskRequest(objective: "Compare workshop insulation", deliverables: ["Cited comparison"])
        let reference = try repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: nil)
        let remote = UUID().uuidString
        let queued = try snapshot(reference, id: remote, state: "queued")
        _ = try repository.acknowledgeTaskReference(id: reference.id, snapshot: queued)
        let bound = try repository.taskReference(id: reference.id)!
        for (reason, phrase) in [("request_limit", "model request limit"), ("input_limit", "smaller research request"),
                                 ("request_conflict", "could not be resumed safely")] {
            let failed = try snapshot(reference, id: remote, state: "failed", checkpoint: ["failure_reason": reason])
            let restored = try JSONDecoder().decode(NativeTaskSnapshot.self, from: nativeTaskEncoded(failed))
            let display = try NativeTaskProjection.display(reference: bound, snapshot: restored)
            try require(display.card.milestone.contains(phrase) && !display.card.milestone.contains(reason),
                        "Persisted failure categories must become actionable plain language")
        }
        let unavailable = try snapshot(reference, id: remote, state: "blocked", checkpoint: ["native_unavailable": "hidden-binding"])
        let blocked = try NativeTaskProjection.display(reference: bound, snapshot: unavailable)
        try require(blocked.card.milestone.contains("original model profile") && !blocked.card.milestone.contains("hidden-binding"),
                    "Unavailable native models must explain the required profile without exposing binding identifiers")
        let firstInstance = UUID()
        let first = try repository.claimTaskStream(engine: engine, instanceID: firstInstance)
        let second = try repository.claimTaskStream(engine: engine, instanceID: UUID())
        _ = try repository.projectTask(id: reference.id, snapshot: queued, lease: first)
        let old = try repository.beginTaskRefresh(id: reference.id, lease: first)
        let newer = try repository.beginTaskRefresh(id: reference.id, lease: second)
        let completed = try snapshot(reference, id: remote, state: "completed", result: [
            "kind": "research_report", "query": request.objective, "report": "A useful comparison. [1]",
            "sources": [["n": 1, "title": "Saved reference", "url": "local"]],
        ])
        _ = try repository.projectTask(id: reference.id, snapshot: completed, cursor: 8, lease: second, generation: newer)
        do {
            _ = try repository.projectTask(id: reference.id, snapshot: queued, cursor: 3, lease: first, generation: old)
            throw NativeTaskFixture.Failure.assertion("Superseded snapshot must not commit")
        } catch is CancellationError {}
        try repository.saveTaskCursor(8, lease: second)
        try repository.saveTaskCursor(4, lease: first)
        let resumed = try repository.claimTaskStream(engine: engine, instanceID: firstInstance)
        try require(resumed.cursor == 8, "Shared cursor advances only after durable projection and cannot regress")
        do {
            try repository.saveTaskCursor(9, lease: first)
            throw NativeTaskFixture.Failure.assertion("Replaced session must be fenced")
        } catch is CancellationError {}
        try repository.saveTaskCursor(8, lease: second)
        _ = try repository.acknowledgeTaskReference(id: reference.id, snapshot: queued)
        _ = try repository.acknowledgeTaskCancellation(id: reference.id,
            snapshot: snapshot(reference, id: remote, state: "running", canceled: true))
        let terminal = try repository.taskReference(id: reference.id)
        try require(terminal?.snapshot?.state == .completed && terminal?.cancelDelivered == true,
                    "Late outbox receipts must preserve completion and stop cancellation polling")
        var ordinary = try repository.messages(conversationID: origin.conversationID).last!
        ordinary.text = "The request is saved."
        ordinary.spokenText = nil
        ordinary.displayBlocks = []
        try repository.saveMessage(ordinary, conversationID: origin.conversationID, ordinal: 1)
        _ = try repository.projectTask(id: reference.id, snapshot: completed, cursor: 8, lease: resumed)
        let reopened = try LocalChatRepository(url: url)
        let stored = try reopened.messages(conversationID: origin.conversationID).last!
        try require(stored.displayBlocks.count == 2, "Streaming saves and replay must preserve exactly one card and report")
        try require(stored.spokenText == ordinary.text, "Background report must not overwrite spoken text")
        try require(stored.nativeEnvelope.speechInput == ordinary.text, "The restored speech envelope excludes report content")
        var regenerated = stored
        regenerated.text = "The regenerated foreground reply."
        try reopened.saveMessage(regenerated, conversationID: origin.conversationID, ordinal: 1)
        let regeneratedStored = try reopened.messages(conversationID: origin.conversationID).last!
        try require(regeneratedStored.nativeEnvelope.speechInput == regenerated.text,
                    "Regenerating a reopened reply must replace its prior spoken text")
        try require(regeneratedStored.displayBlocks == stored.displayBlocks,
                    "Regenerating foreground text must preserve background display blocks")
        try require(try reopened.taskProjection(id: reference.id)?.snapshot?.state == .completed,
                    "Canonical projection must survive reopening the original conversation")
        try repository.saveTaskCursor(0, lease: resumed, reset: true)
        do {
            try repository.saveTaskCursor(10, lease: second)
            throw NativeTaskFixture.Failure.assertion("An old session must not advance a reset engine cursor")
        } catch is CancellationError {}
        var reset = try repository.claimTaskStream(engine: engine, instanceID: UUID())
        try require(reset.cursor == 0, "Changed engine database restarts replay")
        try require(try repository.messages(conversationID: origin.conversationID).last?.displayBlocks == stored.displayBlocks,
                    "Cursor reset retains the completed report")
        let nextOrigin = try NativeTaskFixture.origin(repository)
        let next = try repository.prepareTaskReference(origin: nextOrigin, engine: engine, request: request, profile: nil)
        let nextRemote = UUID().uuidString
        let decisionID = UUID().uuidString
        let paused = try snapshot(next, id: nextRemote, state: "needs_decision",
            decision: ["id": decisionID, "prompt": "The report needs a retry.", "choices": ["retry"]])
        _ = try repository.acknowledgeTaskReference(id: next.id, snapshot: paused)
        _ = try repository.projectTask(id: next.id, snapshot: paused, lease: reset)
        let eventClient = NativeTaskClient { _, url, _, _ in
            (try nativeTaskEncoded(url.lastPathComponent == nextRemote ? paused : completed), 200)
        }
        let eventTransport = NativeTaskEventTransport { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(NativeTaskEvent(id: 10, taskID: remote))
                continuation.yield(NativeTaskEvent(id: 11, taskID: nextRemote))
                continuation.finish()
            }
        }
        let eventService = NativeTaskHandoffService(repository: repository, client: eventClient, configuredBase: { engine.base })
        let eventTracker = NativeTaskTracker(repository: repository, client: eventClient, service: eventService,
            transport: eventTransport, configuredBase: { engine.base })
        for _ in 0..<4 {
            await eventTracker.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        let observedCursor = try repository.claimTaskStream(engine: engine, instanceID: UUID())
        try require(observedCursor.cursor == 11,
                    "Terminal snapshot at cursor zero must not block later events for another active task")
        try require(try repository.taskProjection(id: reference.id)?.cursor == 10,
                    "Terminal event watermark must be durable before global cursor advancement")
        try repository.saveTaskCursor(0, lease: observedCursor, reset: true)
        for _ in 0..<4 {
            await eventTracker.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        reset = try repository.claimTaskStream(engine: engine, instanceID: UUID())
        try require(reset.cursor == 11,
                    "A second-instance reset must reclaim the tracker session even without a pending event batch")
        await eventTracker.stop()
        try repository.releaseTaskStream(observedCursor)
        let deletedOrigin = try NativeTaskFixture.origin(repository)
        let deleted = try repository.prepareTaskReference(origin: deletedOrigin, engine: engine, request: request, profile: nil)
        let deletedRemote = UUID().uuidString
        let deletedSnapshot = try snapshot(deleted, id: deletedRemote, state: "queued")
        _ = try repository.acknowledgeTaskReference(id: deleted.id, snapshot: deletedSnapshot)
        let deletionClient = NativeTaskClient { _, url, _, _ in
            (try nativeTaskEncoded(url.lastPathComponent == deletedRemote ? deletedSnapshot : paused), 200)
        }
        let deletionTransport = NativeTaskEventTransport { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(NativeTaskEvent(id: 12, taskID: deletedRemote))
                continuation.yield(NativeTaskEvent(id: 13, taskID: nextRemote))
                continuation.finish()
            }
        }
        let deletionTracker = NativeTaskTracker(repository: repository, client: deletionClient, service: eventService,
            transport: deletionTransport, configuredBase: { engine.base })
        await deletionTracker.tick()
        try await Task.sleep(for: .milliseconds(10))
        try repository.deleteConversation(deletedOrigin.conversationID)
        for _ in 0..<3 {
            await deletionTracker.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        let afterDeletion = try repository.claimTaskStream(engine: engine, instanceID: UUID())
        try require(afterDeletion.cursor == 13,
                    "Deleting a conversation with pending events must not stall another active task's cursor")
        try require(try repository.taskProjection(id: deleted.id) == nil,
                    "Replayed events must not recreate a deleted transcript")
        await deletionTracker.stop()
        try repository.releaseTaskStream(afterDeletion)
        let beforeRetry = try repository.beginTaskRefresh(id: next.id, lease: reset)
        let retry = try repository.prepareTaskRetry(id: next.id, decisionID: decisionID)
        do {
            _ = try reopened.projectTask(id: next.id,
                snapshot: snapshot(next, id: nextRemote, state: "queued"), lease: reset, generation: beforeRetry)
            throw NativeTaskFixture.Failure.assertion("Retry click must fence an already-running GET from another instance")
        } catch is CancellationError {}
        try require(try repository.pendingTaskRetries() == [retry], "Stale GET must not discard the persisted retry")
        let duplicate = try reopened.prepareTaskRetry(id: next.id, decisionID: decisionID)
        try require(retry == duplicate, "Two instances must reuse one persisted decision reply key")
        _ = try repository.requestTaskCancellation(id: next.id)
        do {
            _ = try repository.prepareTaskRetry(id: next.id, decisionID: decisionID)
            throw NativeTaskFixture.Failure.assertion("Cancellation must prevent a new retry intent")
        } catch is NativeTaskError {}
        let calls = NativeTaskDisplayFixtureCalls()
        let noNetwork = NativeTaskClient { _, _, _, _ in
            await calls.record()
            throw NativeTaskFixture.Failure.assertion("Unconfigured task history must not contact an engine")
        }
        let service = NativeTaskHandoffService(repository: repository, client: noNetwork, configuredBase: { nil })
        let tracker = NativeTaskTracker(repository: repository, client: noNetwork, service: service, configuredBase: { nil })
        await tracker.tick()
        await tracker.stop()
        try require(await calls.count == 0, "Disconnected history must make zero network requests")
        try require(try repository.messages(conversationID: origin.conversationID).last?.displayBlocks == stored.displayBlocks,
                    "Disconnected history remains readable without network")
        try repository.deleteConversation(nextOrigin.conversationID)
        try require(try repository.pendingTaskRetries().isEmpty, "Deleting the original conversation removes retry UI content")
        try await restoredControls()
    }

    static func restoredControls() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!)
        let selection = NativeTaskEngineSelection(engine.base)
        let request = try NativeResearchTaskRequest(objective: "Restored research", deliverables: ["Cited report"])
        let stopping = try repository.prepareTaskReference(origin: NativeTaskFixture.origin(repository), engine: engine,
            request: request, profile: nil)
        let stoppingRemote = UUID().uuidString
        let queued = try snapshot(stopping, id: stoppingRemote, state: "queued")
        _ = try repository.acknowledgeTaskReference(id: stopping.id, snapshot: queued)
        _ = try repository.projectTask(id: stopping.id, snapshot: queued)
        let retrying = try repository.prepareTaskReference(origin: NativeTaskFixture.origin(repository), engine: engine,
            request: request, profile: nil)
        let retryRemote = UUID().uuidString
        let decision = UUID().uuidString
        let paused = try snapshot(retrying, id: retryRemote, state: "needs_decision",
            decision: ["id": decision, "prompt": "Retry the saved research?", "choices": ["retry"]])
        _ = try repository.acknowledgeTaskReference(id: retrying.id, snapshot: paused)
        _ = try repository.projectTask(id: retrying.id, snapshot: paused)
        let stopped = try snapshot(stopping, id: stoppingRemote, state: "canceled", canceled: true)
        let continued = try snapshot(retrying, id: retryRemote, state: "queued")
        let calls = NativeTaskDisplayFixtureCalls()
        let client = NativeTaskClient { method, url, body, _ in
            await calls.record()
            try NativeTaskFixture.require(method == "POST", "First-click controls must send only their selected action")
            if url.lastPathComponent == "cancel" { return (try nativeTaskEncoded(stopped), 200) }
            let value = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
            try NativeTaskFixture.require(value?["decision_id"] as? String == decision,
                                          "Restored Retry must retain the current decision identity")
            return (try nativeTaskEncoded(continued), 200)
        }
        let service = NativeTaskHandoffService(repository: repository, client: client, configuredBase: { selection.base })
        let stopTracker = NativeTaskTracker(repository: repository, client: client, service: service,
            configuredBase: { selection.base })
        await stopTracker.cancel(stopping.id)
        let savedStop = try repository.taskReference(id: stopping.id)
        try NativeTaskFixture.require(savedStop?.cancelRequested == true && savedStop?.cancelDelivered == true,
                                      "Restored Stop must persist and deliver before the first tracker tick")
        await stopTracker.stop()
        let retryTracker = NativeTaskTracker(repository: repository, client: client, service: service,
            configuredBase: { selection.base })
        selection.set(nil)
        await retryTracker.retry(retrying.id)
        await retryTracker.cancel(retrying.id)
        selection.set(URL(string: "https://other-engine.test/api")!)
        await retryTracker.retry(retrying.id)
        await retryTracker.cancel(retrying.id)
        try NativeTaskFixture.require(await calls.count == 1,
                                      "Disconnected and changed-engine controls must make no network requests")
        try NativeTaskFixture.require(try repository.pendingTaskRetries().isEmpty
            && repository.taskReference(id: retrying.id)?.cancelRequested == false,
            "Unavailable controls must not authorize a later action")
        selection.set(engine.base)
        await retryTracker.retry(retrying.id)
        await retryTracker.retry(retrying.id)
        try NativeTaskFixture.require(await calls.count == 2,
                                      "Restored Retry must deliver exactly once before the first tracker tick")
        try NativeTaskFixture.require(try repository.taskProjection(id: retrying.id)?.snapshot?.state == .queued,
                                      "Restored Retry must update the original card without waiting for tracking")
        await retryTracker.stop()
    }
}

actor NativeTaskDisplayFixtureCalls {
    private(set) var count = 0
    func record() { count += 1 }
}
