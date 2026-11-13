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
        try await decisionChoices()
        try await savedAnswer()
        try companionSources()
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chat.sqlite")
        let repository = try LocalChatRepository(url: url)
        let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!)
        let origin = try NativeTaskFixture.origin(repository)
        let request = try NativeResearchTaskRequest(objective: "Compare workshop insulation", deliverables: ["Cited comparison"])
        let reference = try repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: nil)
        try repository.recordSettledBeforeDelivery(id: reference.id)
        let remote = UUID().uuidString
        let queued = try snapshot(reference, id: remote, state: "queued")
        _ = try repository.acknowledgeTaskReference(id: reference.id, snapshot: queued)
        let bound = try repository.taskReference(id: reference.id)!
        for (reason, phrase) in [("request_limit", "couldn't finish"), ("input_limit", "smaller research request"),
                                 ("request_conflict", "could not be resumed safely")] {
            let failed = try snapshot(reference, id: remote, state: "failed", checkpoint: ["failure_reason": reason])
            let restored = try JSONDecoder().decode(NativeTaskSnapshot.self, from: nativeTaskEncoded(failed))
            let display = try NativeTaskProjection.display(reference: bound, snapshot: restored)
            try require(display.card.milestone.contains(phrase) && !display.card.milestone.contains(reason)
                        && !display.card.milestone.lowercased().contains("limit"),
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

extension NativeTaskDisplayFixture {
    static func companionSources() throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!)
        let request = try NativeResearchTaskRequest(dot: NativeCompanionTaskPayload(assignment: "How much rain fell?", mode: "manual"))
        let origin = try NativeTaskFixture.origin(repository)
        let prepared = try repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: nil)
        let payload = (try JSONSerialization.jsonObject(with: prepared.body) as! [String: Any])["payload"]!
        let remote = UUID().uuidString
        func finished(_ report: String, sources: [[String: Any]], shape: String) throws -> NativeTaskSnapshot {
            try JSONDecoder().decode(NativeTaskSnapshot.self, from: NativeTaskClient.canonical([
                "id": remote, "worker_type": "companion", "payload": payload, "state": "completed",
                "checkpoint": [:], "cancel_requested": false, "generation": 1, "updated_at": 1.0,
                "result": ["kind": "companion_report", "query": prepared.request.objective, "report": report, "sources": sources,
                           "summary": report, "title": prepared.request.objective, "shape": shape],
            ]))
        }
        let reference = try repository.acknowledgeTaskReference(id: prepared.id, snapshot: try finished("", sources: [], shape: "answer"))
        let listed: [[String: Any]] = [["n": 1, "title": "Rain totals", "url": "https://weather.example/rain"],
                                       ["n": 2, "title": "River levels", "url": "https://gauge.example/levels"]]
        let expected = [PulseSource(n: 1, title: "Rain totals", url: "https://weather.example/rain"),
                        PulseSource(n: 2, title: "River levels", url: "https://gauge.example/levels")]
        let report = "Two inches fell [1]. The river rose [2]."
        let answer = try NativeTaskProjection.display(reference: reference, snapshot: try finished(report, sources: listed, shape: "answer"))
        try require(answer.card.answer == report && answer.card.sources == expected && answer.artifact == nil,
                    "A cited companion answer keeps its sources on the card")
        try require(NativeTaskProjection.answerDocument(answer.card)?.sources == expected, "Saving the answer keeps its sources")
        let document = try NativeTaskProjection.display(reference: reference, snapshot: try finished(report, sources: listed, shape: "document"))
        try require(document.artifact?.sources == expected && document.artifact?.isDocument == true && document.card.sources == expected,
                    "A cited companion document keeps its sources")
        try require(document.card.milestone == "Two inches fell. The river rose.", "The one-line summary on the card drops its bracket numbers")
        let year = try NativeTaskProjection.display(reference: reference, snapshot: try finished("Records began in [2024] and rain fell [1].",
                                                                                                    sources: [listed[0]], shape: "answer"))
        try require(year.card.answer == "Records began in [2024] and rain fell [1]." && year.card.sources == [expected[0]],
                    "A bracketed number that is not a source is accepted and left as written")
        let duplicate = [listed[0], ["n": 1, "title": "Again", "url": "https://again.example/"]]
        let outside: [[String: Any]] = [["n": 15, "title": "Late", "url": "https://late.example/"]]
        let zero: [[String: Any]] = [["n": 0, "title": "Zero", "url": "https://zero.example/"]]
        let many: [[String: Any]] = (1...15).map { ["n": $0, "title": "Source \($0)", "url": "https://many.example/\($0)"] }
        for invalid in [duplicate, outside, zero, many] {
            var rejected = false
            do { _ = try NativeTaskProjection.display(reference: reference, snapshot: try finished(report, sources: invalid, shape: "answer")) }
            catch NativeTaskHTTPError.invalidResponse { rejected = true }
            try require(rejected, "Invalid companion sources are rejected: \(invalid.count)")
        }
    }

    static func savedAnswer() async throws {
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: directory)
        let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!)
        let request = try NativeResearchTaskRequest(dot: NativeCompanionTaskPayload(assignment: "What's the weather in Chicago tomorrow?", mode: "manual"))
        let origin = try NativeTaskFixture.origin(repository)
        let reference = try repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: nil)
        let body = try JSONSerialization.jsonObject(with: reference.body) as! [String: Any]
        let answer = "Sunny and mild, with a high of 61."
        let finished = try JSONDecoder().decode(NativeTaskSnapshot.self, from: NativeTaskClient.canonical([
            "id": UUID().uuidString, "worker_type": "companion", "payload": body["payload"]!, "state": "completed",
            "checkpoint": [:], "cancel_requested": false, "generation": 1, "updated_at": 1.0,
            "result": ["kind": "companion_report", "query": reference.request.objective, "report": answer, "sources": [],
                       "summary": answer, "title": reference.request.objective, "shape": "answer"],
        ]))
        _ = try repository.acknowledgeTaskReference(id: reference.id, snapshot: finished)
        try repository.recordSettledBeforeDelivery(id: reference.id)
        _ = try repository.projectTask(id: reference.id, snapshot: finished)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository,
                              attachmentStore: NativeAttachmentStore(directory: directory), artifactPersistenceEnabled: false)
        await store.connect()
        store.select(origin.conversationID)
        func blocks() throws -> [NativeDisplayBlock] {
            try repository.messages(conversationID: origin.conversationID).first { $0.id == origin.assistantMessageID }?.displayBlocks ?? []
        }
        func card(_ blocks: [NativeDisplayBlock]) -> NativeTaskCardPresentation? {
            blocks.compactMap { block -> NativeTaskCardPresentation? in if case .taskCard(let card) = block { card } else { nil } }.first
        }
        let before = try blocks()
        try require(card(before)?.answer == answer && !before.contains { if case .artifact = $0 { true } else { false } }
                    && !store.artifactRecords.contains { $0.conversationID == origin.conversationID },
                    "An answer starts on the card with nothing in the Library")
        store.saveNativeTaskAnswer(reference.id.uuidString)
        store.saveNativeTaskAnswer(reference.id.uuidString)
        let after = try blocks()
        let documents = after.compactMap { block -> NativeResearchArtifact? in if case .artifact(let value) = block { value } else { nil } }
        try require(documents.count == 1 && documents.first?.isDocument == true && documents.first?.report == answer
                    && documents.first?.title == card(after)?.title && card(after)?.answer == answer,
                    "Saving keeps the answer on the card and adds one document titled like the card")
        let records = store.artifactRecords.filter { $0.conversationID == origin.conversationID }
        try require(records.count == 1 && records.first?.kind == .document && records.first?.title == card(after)?.title,
                    "The saved answer lands in the Library once")
        let memory = store.conversations.first { $0.id == origin.conversationID }?.messages.first { $0.id == origin.assistantMessageID }?.displayBlocks ?? []
        try require(memory.filter { if case .artifact = $0 { true } else { false } }.count == 1, "The open chat shows the document once")
        store.applyNativeTaskUpdates([NativeTaskMessageUpdate(conversationID: origin.conversationID,
                                                              messageID: origin.assistantMessageID, blocks: before)])
        let afterStale = store.conversations.first { $0.id == origin.conversationID }?.messages
            .first { $0.id == origin.assistantMessageID }?.displayBlocks ?? []
        let staleDocuments = afterStale.compactMap { block -> NativeResearchArtifact? in if case .artifact(let value) = block { value } else { nil } }
        let staleCard = card(afterStale)
        try require(staleDocuments.count == 1 && staleDocuments.first?.id == staleCard?.id
                    && afterStale.firstIndex { $0.id == "artifact:" + reference.id.uuidString } == afterStale.firstIndex { $0.id == "task:" + reference.id.uuidString }.map { $0 + 1 }
                    && staleCard.map { NativeDisplayBlocksView.answerSaved($0, in: afterStale) } == true,
                    "A stale update applied after a save keeps the document under its card and the save action hidden")
        _ = try repository.projectTask(id: reference.id, snapshot: finished)
        try require(try blocks().filter { if case .artifact = $0 { true } else { false } }.count == 1,
                    "A later refresh keeps the saved document")
        try require(try repository.saveTaskAnswer(id: UUID()).isEmpty, "Saving an unknown task does nothing")
    }

    static func decisionChoices() async throws {
        let require = NativeTaskFixture.require
        let legacy = try JSONDecoder().decode(NativeTaskDecision.self,
            from: Data(#"{"id":"d1","prompt":"Retry?","choices":["retry"]}"#.utf8))
        try require(legacy.digest == nil && legacy.choices == ["retry"], "A decision without a digest still decodes")
        let legacyEncoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        try require(legacyEncoded?["digest"] == nil, "A decision without a digest encodes without one")
        let approval = NativeTaskDecision(id: "d2", prompt: "Send it?", choices: ["approve", "decline"], digest: "ab12")
        try require(try JSONDecoder().decode(NativeTaskDecision.self, from: JSONEncoder().encode(approval)) == approval,
                    "A decision digest round-trips")
        let oldIntent = try JSONDecoder().decode(NativeTaskDecisionIntent.self, from: Data("""
            {"referenceID":"\(UUID().uuidString)","decisionID":"d1","key":"\(UUID().uuidString)"}
            """.utf8))
        try require(oldIntent.choice == "retry", "An encoded intent without a choice reads as retry")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("chat.sqlite"))
        let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!)
        let request = try NativeResearchTaskRequest(objective: "Book the inspection", deliverables: ["Booking"])
        func paused(_ decision: [String: Any]) throws -> (NativeTaskReference, NativeTaskSnapshot) {
            let reference = try repository.prepareTaskReference(origin: NativeTaskFixture.origin(repository),
                engine: engine, request: request, profile: nil)
            let value = try snapshot(reference, id: UUID().uuidString, state: "needs_decision", decision: decision)
            _ = try repository.acknowledgeTaskReference(id: reference.id, snapshot: value)
            _ = try repository.projectTask(id: reference.id, snapshot: value)
            return (try repository.taskReference(id: reference.id)!, value)
        }
        let digest = String(repeating: "c4", count: 32)
        let (approve, approveSnapshot) = try paused(["id": "approve-1", "prompt": "Send the booking request?",
                                                    "choices": ["approve", "decline"], "digest": digest])
        try require(approveSnapshot.decision?.digest == digest, "A snapshot decision keeps its digest")
        let card = try repository.messages(conversationID: approve.origin.conversationID).last?.displayBlocks
            .compactMap { block -> NativeTaskCardPresentation? in if case .taskCard(let card) = block { card } else { nil } }.first
        try require(NativeTaskCardPresentation.choiceTitle("approve") == "Allow once" && NativeTaskCardPresentation.choiceTitle("allow_here") == "Always allow for this"
                    && NativeTaskCardPresentation.choiceTitle("allow_always") == "Always allow everywhere" && NativeTaskCardPresentation.choiceTitle("never") == "Never allow it for this"
                    && NativeTaskCardPresentation.choiceTitle("never_commands") == "Never run commands for this"
                    && NativeTaskCardPresentation.choiceTitle("allow_schedule") == "Always allow for this schedule" && NativeTaskCardPresentation.choiceTitle("decline") == "Decline"
                    && NativeTaskCardPresentation.choiceTitle("made_up") == nil, "Every card choice has a plain title and unknown ones have none")
        let whole = CardAnswers.task(choices: ["decline", "never", "allow_always", "allow_here", "approve"], covers: "This action every time", neverTitle: "Never allow it for this")
        try require(whole.allowTitle == "Allow" && whole.declineTitle == "Decline"
                    && whole.allowMenu.map(\.id) == ["allow_here", "allow_always"]
                    && whole.allowMenu.map(\.title) == ["Always allow for this", "Always allow everywhere"]
                    && whole.allowMenu.allSatisfy { $0.note == "This action every time" }
                    && whole.declineMenu.map(\.id) == ["never"] && whole.declineMenu[0].title == "Never allow it for this" && whole.declineMenu[0].note == nil,
                    "A task card shows two answers, and each caret holds only the standing choices with what they cover")
        try require(!(whole.allowMenu + whole.declineMenu).contains { $0.id == "approve" || $0.id == "decline" },
                    "The one-time answers are the buttons themselves and never appear in a caret menu")
        let commands = CardAnswers.task(choices: ["decline", "never_commands", "allow_always", "allow_here", "approve"], covers: "Commands that start with make pdf", neverTitle: "ignored")
        try require(commands.declineMenu.map(\.id) == ["never_commands"] && commands.declineMenu[0].title == "Never run commands for this"
                    && commands.declineMenu[0].note == NativeCardChoices.neverHelp
                    && commands.allowMenu[0].spoken == "Always allow for this. Commands that start with make pdf",
                    "A command card's Never names its reach and says allowed commands still run")
        let run = CardAnswers.task(choices: ["decline", "never_commands", "allow_always", "allow_here", "approve"], covers: "Commands that start with make pdf", neverTitle: nil, run: true)
        try require(run.allowMenu.map(\.title) == ["Always allow for this run", "Always allow everywhere"] && run.declineMenu[0].title == "Never run commands for this run",
                    "On the Scheduled screen the standing choices speak of the run")
        let long = String(repeating: "a", count: CardAnswers.displayLimit + 1)
        let hidden = CardAnswers.task(choices: ["decline", "never", "allow_always", "allow_here", "approve"], covers: "Commands that start with " + long, neverTitle: "Never edit in " + long)
        let wholeRun = CardAnswers.task(choices: ["decline", "never", "approve"], covers: nil, neverTitle: "Never allow it for this", run: true)
        try require(wholeRun.declineMenu.map(\.title) == ["Never allow it for this run"], "On a scheduled run a whole-action never says it applies to this run")
        let savedRun = CardAnswers.task(choices: ["decline", "never", "approve"], covers: nil, neverTitle: "Never allow this in this task", run: true)
        try require(savedRun.declineMenu.map(\.title) == ["Never allow it for this run"], "A never title saved with the earlier words still speaks of the run")
        let earlier = ["Never allow this in this task": "Never allow it for this", "Never allow it for this work": "Never allow it for this",
                       "Never send to ada@example.com in this task": "Never send to ada@example.com for this",
                       "Never run commands for this work": "Never run commands for this", "Never allow this in this chat": "Never allow this in this chat"]
        for (saved, shown) in earlier {
            try require(CardAnswers.task(choices: ["decline", "never", "approve"], covers: nil, neverTitle: saved).declineMenu.map(\.title) == [shown],
                        "A never title saved with earlier words reads with the current ones: \(saved)")
        }
        for kept in ["Never edit in Plans for this work", "Never edit in Plans in this task", "Never edit in Plans for this",
                     "Never move things in Notes for this work to the Trash"] {
            for run in [false, true] {
                try require(CardAnswers.task(choices: ["decline", "never", "approve"], covers: nil, neverTitle: kept, run: run).declineMenu.map(\.title) == [kept],
                            "A folder's own name is never reworded: \(kept)")
            }
        }
        try require(CardAnswers.task(choices: ["decline", "never", "approve"], covers: nil, neverTitle: "Never send to Plans for this work for this", run: true)
                        .declineMenu.map(\.title) == ["Never send to Plans for this work for this run"], "A recipient's own name is kept on a scheduled run")
        let listed: Set<String> = ["task", "tasks", "background", "backgrounds", "worker", "workers", "agent", "agents", "engine", "engines"]
        for (old, new) in SavedWording.earlier {
            let words = Set(new.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            try require(words.isDisjoint(with: listed) && SavedWording.current(old) == new,
                        "A message saved with earlier words reads with the current ones: \(old)")
            try require(NativeScheduler.shownNote(old) == new, "A saved run note reads with the current words: \(old)")
            var refused = try OngoingWorkFixture.reference(conversationID: "words-saved", title: "Lumber prices this month", state: nil)
            refused.deliveryState = .rejected
            refused.lastDeliveryError = old
            try require(NativeTaskProjection.display(reference: refused, snapshot: nil).card.milestone == new, "A refused card saved earlier reads with the current words: \(old)")
            var waiting = try OngoingWorkFixture.reference(conversationID: "words-saved", title: "Lumber prices this month", state: nil)
            waiting.lastDeliveryError = old
            try require(waiting.deliveryState != .rejected && !waiting.cancelRequested
                            && NativeTaskProjection.display(reference: waiting, snapshot: nil).card.connectionNote == new,
                        "A card still waiting to connect reads with the current words: \(old)")
            waiting.lastDeliveryError = nil
            try require(NativeTaskProjection.display(reference: waiting, snapshot: nil, connectionNote: old).card.connectionNote == new,
                        "A saved connection note reads with the current words: \(old)")
        }
        let typed = ["Is the task engine down? The task engine couldn't be reached. is all it says", "The task engine couldn't be reached. Again.",
                     " The task engine couldn't be reached.", "the task engine couldn't be reached.", "Tandem wasn't running at the scheduled time.",
                     "{\"error\":\"The task engine couldn't be reached.\"}"]
        for text in typed {
            try require(SavedWording.current(text) == text && NativeScheduler.shownNote(text) == text, "Text that isn't exactly a line the app wrote is left as saved: \(text)")
        }
        try require(SavedWording.current(SavedWording.argumentsLead + "Provide a worker type, an objective and deliverables.") == SavedWording.argumentsLead + NativeTaskTools.missingArguments
                        && SavedWording.current(SavedWording.argumentsLead + "use the task engine") == SavedWording.argumentsLead + "use the task engine",
                    "A saved arguments message is reworded only when the whole detail is the app's own line")
        let unlabelled = CardAnswers.task(choices: ["decline", "never", "allow_always", "allow_here", "approve"], covers: nil, neverTitle: nil, run: true)
        try require(hidden.allowMenu.isEmpty && hidden.declineMenu.isEmpty && unlabelled.allowMenu.isEmpty && unlabelled.declineMenu.isEmpty
                    && CardAnswers.shown("Edits in a\nb") == nil && CardAnswers.shown("Edits in Greenhouse") == "Edits in Greenhouse",
                    "A standing choice is never offered when what it covers can't be shown in full")
        let plain = CardAnswers.task(choices: ["decline", "approve"], covers: nil, neverTitle: nil)
        try require(plain.allowMenu.isEmpty && plain.declineMenu.isEmpty, "A card with nothing to save has no carets")
        try require(NativeScheduleAnswer.route("retry") == .retry && NativeScheduleAnswer.route("stop") == .stop && NativeScheduleAnswer.route("cancel") == .stop
                    && ["approve", "allow_here", "allow_always", "allow_schedule", "never", "never_commands", "decline", "it_happened", "it_did_not"]
                        .allSatisfy { NativeScheduleAnswer.route($0) == .answer },
                    "On the Scheduled screen only Retry retries and only Stop cancels, and every other answer reaches the waiting work")
        try require(card?.offeredChoices == ["approve", "decline"] && card?.canRetry == false,
                    "A paused card offers each known choice in order")
        do {
            _ = try repository.prepareTaskDecision(id: approve.id, decisionID: "approve-1", choice: "retry")
            throw NativeTaskFixture.Failure.assertion("A choice the decision does not offer must be refused")
        } catch is NativeTaskError {}
        let first = try repository.prepareTaskDecision(id: approve.id, decisionID: "approve-1", choice: "approve")
        try require(first.choice == "approve", "The saved intent keeps its choice")
        let again = try repository.prepareTaskDecision(id: approve.id, decisionID: "approve-1", choice: "approve")
        try require(again == first, "Answering with the same choice reuses the saved intent")
        do {
            _ = try repository.prepareTaskDecision(id: approve.id, decisionID: "approve-1", choice: "decline")
            throw NativeTaskFixture.Failure.assertion("A decision must be answered only once")
        } catch is NativeTaskError {}
        try require(try repository.pendingTaskRetries() == [first], "The pending intent returns its stored choice")
        _ = try repository.projectTask(id: approve.id, snapshot: nil)
        let pendingCard = try repository.messages(conversationID: approve.origin.conversationID).last?.displayBlocks
            .compactMap { block -> NativeTaskCardPresentation? in if case .taskCard(let card) = block { card } else { nil } }.first
        try require(pendingCard?.offeredChoices.isEmpty == true && pendingCard?.statusTitle == "Needs your answer",
                    "A saved answer hides the choices")

        let approveBody = try JSONSerialization.jsonObject(with: NativeTaskClient.decisionBody(first, digest: digest)) as? [String: Any]
        let approveReply = approveBody?["reply"] as? [String: Any]
        try require(approveReply?["action"] as? String == "approve" && approveReply?["digest"] as? String == digest
                    && approveReply?.count == 2 && approveBody?["decision_id"] as? String == "approve-1",
                    "An approval reply carries the choice and the saved digest")
        let retryIntent = NativeTaskDecisionIntent(referenceID: approve.id, decisionID: "r1", key: UUID())
        let retryReply = (try JSONSerialization.jsonObject(with: NativeTaskClient.decisionBody(retryIntent, digest: nil))
            as? [String: Any])?["reply"] as? [String: Any]
        try require(retryReply?.count == 1 && retryReply?["action"] as? String == "retry", "A retry reply carries only the action")

        let bodies = NativeTaskDisplayFixtureBodies()
        let (choose, chooseSnapshot) = try paused(["id": "approve-2", "prompt": "Send it?",
                                                   "choices": ["approve", "decline"], "digest": digest])
        let resumed = try snapshot(choose, id: chooseSnapshot.id, state: "queued")
        let client = NativeTaskClient { method, url, body, _ in
            if method == "POST", let body { await bodies.record(body) }
            return (try nativeTaskEncoded(url.lastPathComponent == "decision" ? resumed : chooseSnapshot), 200)
        }
        let service = NativeTaskHandoffService(repository: repository, client: client, configuredBase: { engine.base })
        let tracker = NativeTaskTracker(repository: repository, client: client, service: service, configuredBase: { engine.base })
        await tracker.decide(choose.id, choice: "stop")
        await tracker.decide(choose.id, choice: "decline")
        let sent = await bodies.values
        let sentReply = sent.first.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["reply"] as? [String: Any]
        try require(sent.count == 1 && sentReply?["action"] as? String == "decline" && sentReply?["digest"] as? String == digest,
                    "The tracker delivers only an offered choice with the digest from the saved decision")
        try require(try repository.taskProjection(id: choose.id)?.snapshot?.state == .queued
                    && repository.pendingTaskRetries() == [first],
                    "A delivered answer resolves its intent and updates the card")
        await tracker.stop()

        let (legacyTask, _) = try paused(["id": "legacy-1", "prompt": "Retry?", "choices": ["retry"]])
        try await repository.database.write { db in
            try db.execute(sql: """
                INSERT INTO native_task_retries(reference_id, message_id, decision_id, reply_key) VALUES (?, ?, ?, ?)
                """, arguments: [legacyTask.id.uuidString, legacyTask.origin.assistantMessageID.uuidString,
                                 "legacy-1", UUID().uuidString])
        }
        try require(try repository.pendingTaskRetries().first { $0.referenceID == legacyTask.id }?.choice == "retry",
                    "An intent row saved before choices existed reads back as retry")
    }
}

actor NativeTaskDisplayFixtureBodies {
    private(set) var values: [Data] = []
    func record(_ body: Data) { values.append(body) }
}

actor NativeTaskDisplayFixtureCalls {
    private(set) var count = 0
    func record() { count += 1 }
}
