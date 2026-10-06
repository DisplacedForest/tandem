import Foundation
import GRDB

enum NativeTaskFixture {
    enum Failure: Error { case assertion(String) }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    static func snapshot(_ reference: NativeTaskReference, id: String,
                         state: String = "queued", canceled: Bool = false) throws -> Data {
        let body = try JSONSerialization.jsonObject(with: reference.body) as! [String: Any]
        return try NativeTaskClient.canonical([
            "id": id, "worker_type": "research", "payload": body["payload"]!,
            "state": state, "checkpoint": [:], "cancel_requested": canceled,
            "generation": 1, "updated_at": 1.0,
        ])
    }

    static func origin(_ repository: LocalChatRepository) throws -> NativeTaskOrigin {
        let conversation = Conversation(id: UUID().uuidString, title: "Research fixture", messages: [], updatedAt: Date())
        let user = Message(role: .user, text: "Research a fictional moon")
        let assistant = Message(role: .assistant, text: "", state: .streaming)
        try repository.saveConversation(conversation)
        try repository.saveMessage(user, conversationID: conversation.id, ordinal: 0)
        try repository.saveMessage(assistant, conversationID: conversation.id, ordinal: 1)
        return NativeTaskOrigin(conversationID: conversation.id, userMessageID: user.id, assistantMessageID: assistant.id)
    }

    static func repository(_ url: URL) throws -> LocalChatRepository {
        let repository = try LocalChatRepository(url: url)
        try repository.database.write { db in
            if try !db.tableExists("native_task_outbox") { try LocalChatRepository.migrateNativeTasks(db) }
        }
        return repository
    }

    static func run() async throws {
        for invalid in ["{\"id\":1,\"id\":2}", "{\"id\":1,\"\\u0069d\":2}"] {
            do {
                try NativeTaskJSON.validate(Data(invalid.utf8))
                throw Failure.assertion("Duplicate structural JSON keys must fail")
            } catch is NativeTaskHTTPError {}
        }
        for finish in [nil, "length", "tool_calls"] as [String?] {
            do {
                _ = try NativeTaskProvider.completedText(NativeChatStreamSnapshot(content: "Partial", toolCalls: [], finishReason: finish))
                throw Failure.assertion("Incomplete provider output must fail")
            } catch is NativeTaskGenerationFailure {}
        }
        try require(NativeTaskTools.enabledIDs([], hasEngine: true, hasRepository: true).isEmpty, "Background tool is opt-in")
        for (engine, storage) in [(false, true), (true, false)] {
            try require(!NativeTaskTools.enabledIDs([NativeWebTools.researchToolID, NativeTaskTools.toolID],
                hasEngine: engine, hasRepository: storage).contains(NativeTaskTools.toolID), "Background tool availability gates")
        }
        try require(NativeTaskTools.enabledIDs([NativeWebTools.researchToolID], hasEngine: true, hasRepository: true)
            .contains(NativeTaskTools.toolID), "Background tool uses existing research toggle")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chat.sqlite")
        let repository = try repository(url)
        let engine = try NativeTaskEngineIdentity(URL(string: "https://ENGINE.test:443/api/")!)
        try require(engine.base.absoluteString == "https://engine.test/api", "Canonical engine")
        let request = try NativeResearchTaskRequest(objective: "Snow \u{2603} / \u{1f600}", deliverables: ["Cited report"])
        let profile = NativeTaskProfileBinding(id: UUID().uuidString, profileID: "fixture-profile",
            provider: try NativeTaskEngineIdentity(URL(string: "https://provider.test/v1")!),
            savedModel: "fixture-model", executionModel: "fixture-model",
            limits: try NativeTaskGenerationLimits(maximumRequests: 2))
        let origin = try origin(repository)
        let reference = try repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: profile)
        let replay = try repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: nil)
        try require(reference == replay && reference.profile == profile, "Replay must preserve captured profile and body")
        let remote = UUID().uuidString
        let receipt = try snapshot(reference, id: remote)
        let client = NativeTaskClient { _, _, body, _ in
            try require(body == reference.body, "Exact wire request replay")
            return (receipt, 201)
        }
        let accepted = try await client.create(reference)
        _ = try repository.acknowledgeTaskReference(id: reference.id, snapshot: accepted)
        let messages = [NativeTaskGenerationMessage(role: "user", content: "Snow \u{2603} / \u{1f600}"),
                        NativeTaskGenerationMessage(role: "assistant", content: "\u{1}")]
        try require(NativeTaskGenerationJob.digest(messages)
            == "b14976f7840083cd7ca915ca02b21f937629b21a6c0a5c5075f5b8c4331b39aa", "Shared UTF-8 digest")
        let binding = reference.createRequest.payload.nativeBinding!
        func job(_ attempt: String, _ content: [NativeTaskGenerationMessage] = messages) -> NativeTaskGenerationJob {
            NativeTaskGenerationJob(id: UUID().uuidString, taskID: remote, bindingID: binding.id,
                enrollmentDigest: binding.enrollmentDigest, admissionBase: binding.admissionBase,
                phase: "plan", attempt: attempt, messages: content,
                messagesDigest: NativeTaskGenerationJob.digest(content), deadlineSeconds: 10, generation: 1)
        }
        do {
            _ = try repository.reserveTaskGeneration(referenceID: reference.id,
                job: job("oversized-0", [NativeTaskGenerationMessage(role: "user", content: String(repeating: "/", count: 40000))]))
            throw Failure.assertion("Serialized input limit must fail before reservation")
        } catch let error as NativeTaskGenerationFailure {
            try require(error.code == "input_limit", "Input limit has a fixed failure category")
        }
        let beforeFirst = try await repository.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_task_generations")
        }
        try require(beforeFirst == 0, "Oversized input cannot consume a request")
        let first = job("initial-0")
        try require(try repository.reserveTaskGeneration(referenceID: reference.id, job: first) == .execute, "First reservation")
        try repository.finishTaskGeneration(referenceID: reference.id, job: first, response: "Complete", failure: nil)
        let reopened = try self.repository(url)
        try require(try reopened.reserveTaskGeneration(referenceID: reference.id, job: job("initial-0"))
            == .completed("Complete"), "Completed cache survives restart")
        try require(try reopened.reserveTaskGeneration(referenceID: reference.id,
            job: job("initial-0", [NativeTaskGenerationMessage(role: "user", content: "Changed")]))
            == .unavailable("request_conflict"), "Changed messages cannot create another paid identity")
        try require(try reopened.reserveTaskGeneration(referenceID: reference.id, job: job("initial-1")) == .execute,
                    "Second reservation")
        let recovered = try self.repository(url)
        try require(try recovered.reserveTaskGeneration(referenceID: reference.id, job: job("initial-1"))
            == .pending, "Another broker cannot replace a live reservation")
        try await recovered.database.write { db in
            try db.execute(sql: "UPDATE native_task_generations SET reserved_until = 0 WHERE state = 'reserved'")
        }
        try require(try recovered.reserveTaskGeneration(referenceID: reference.id, job: job("initial-1"))
            == .unavailable("previous_request_uncertain"), "Uncertain calls remain spent")
        do {
            try recovered.finishTaskGeneration(referenceID: reference.id, job: job("initial-1"), response: "Late", failure: nil)
            throw Failure.assertion("Expired success must be rejected")
        } catch is NativeTaskHTTPError {}
        do {
            try recovered.finishTaskGeneration(referenceID: reference.id,
                job: job("initial-1", [NativeTaskGenerationMessage(role: "user", content: "Changed")]),
                response: nil, failure: "request_timeout")
            throw Failure.assertion("Mismatched failure cannot change a reservation")
        } catch is NativeTaskHTTPError {}
        try recovered.finishTaskGeneration(referenceID: reference.id, job: job("initial-1"), response: nil, failure: "request_timeout")
        let settled = try self.repository(url)
        try require(try settled.reserveTaskGeneration(referenceID: reference.id, job: job("initial-1"))
            == .unavailable("request_timeout"), "Known timeout survives restart without another request")
        do {
            try settled.finishTaskGeneration(referenceID: reference.id, job: job("initial-1"), response: "Late", failure: nil)
            throw Failure.assertion("A terminal failure cannot become a success")
        } catch is NativeTaskHTTPError {}
        try require(try recovered.reserveTaskGeneration(referenceID: reference.id, job: job("retry-0"))
            == .unavailable("request_limit"), "Retry cannot reset pinned budget")
        let completed = try JSONDecoder().decode(NativeTaskSnapshot.self,
            from: snapshot(reference, id: remote, state: "completed"))
        _ = try recovered.acknowledgeTaskReference(id: reference.id, snapshot: completed)
        _ = try recovered.failTaskDelivery(id: reference.id, permanent: false, message: "Temporary failure")
        let lateCancel = try JSONDecoder().decode(NativeTaskSnapshot.self,
            from: snapshot(reference, id: remote, state: "running", canceled: true))
        let preserved = try recovered.acknowledgeTaskCancellation(id: reference.id, snapshot: lateCancel)
        try require(preserved.snapshot?.state == .completed && preserved.cancelDelivered && preserved.lastDeliveryError == nil,
                    "Late cancellation acknowledgment preserves terminal evidence and stops retries")
        let reordered = Data("{\"b\":\"https:\\/\\/example.test\",\"a\":\"\\u2603\"}".utf8)
        let canonical = try NativeTaskClient.canonical(["a": "\u{2603}", "b": "https://example.test"])
        try require(try NativeTaskClient.canonical(JSONSerialization.jsonObject(with: reordered) as! [String: Any])
            == canonical, "Receipt comparison is independent of key order and escaped slashes")
        try await configurationChecks(repository: repository, engine: engine, request: request)
        try await resistantGeneration(repository: repository, engine: engine, request: request, profile: profile)
        try await lostAcknowledgmentDeletion(directory: directory, engine: engine, request: request)
    }

    @MainActor
    static func configurationChecks(repository: LocalChatRepository, engine: NativeTaskEngineIdentity,
                                    request: NativeResearchTaskRequest) async throws {
        let first = NativeEndpointProfile(id: "original-profile", name: "Original", baseURL: "https://original.test/v1",
            discoveredModels: ["original-model"], selectedModel: "original-model", selectionBasis: .user, lastDiscoveryAt: nil)
        let second = NativeEndpointProfile(id: "other-profile", name: "Other", baseURL: "https://other.test/v1",
            discoveredModels: ["other-model"], selectedModel: "other-model", selectionBasis: .user, lastDiscoveryAt: nil)
        var settings = NativeChatSettings.fresh
        settings.profiles = [first, second]
        settings.activeProfileID = first.id
        var unlocked = true
        let adapter = NativeTaskConfiguration(settings: { settings }, credential: { _ in unlocked ? "synthetic-binding-key" : nil })
        let config = NativeChatConfig(baseURL: URL(string: first.baseURL)!, apiKey: "synthetic-binding-key",
            model: first.selectedModel, chatTemplateKwargs: nil)
        let binding = try adapter.enroll(config: config)
        settings.activeProfileID = second.id
        let captured = try adapter.load(binding)
        try require(captured.model == first.selectedModel && captured.baseURL.absoluteString == first.baseURL,
                    "Active profile changes cannot retarget research")
        let reference = try repository.prepareTaskReference(origin: origin(repository), engine: engine, request: request, profile: binding)
        _ = try repository.acknowledgeTaskReference(id: reference.id,
            snapshot: JSONDecoder().decode(NativeTaskSnapshot.self, from: snapshot(reference, id: UUID().uuidString)))
        let calls = NativeTaskFixtureRequests()
        let client = NativeTaskClient { _, _, _, _ in
            await calls.append(Data("ready".utf8))
            throw NativeTaskHTTPError.unavailable
        }
        let broker = NativeTaskGenerationBroker(repository: repository, client: client, configuredBase: { engine.base },
            isProfileAvailable: { await adapter.isAvailable($0) }, generate: { _, _ in
                await calls.append(Data("provider".utf8))
                return "unexpected"
            })
        let before = try await repository.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_task_generations") }
        for failure in ["deleted", "endpoint", "model", "credential"] {
            settings.profiles = [first, second]
            unlocked = failure != "credential"
            if failure == "deleted" { settings.profiles.removeFirst() }
            if failure == "endpoint" { settings.profiles[0].baseURL = second.baseURL }
            if failure == "model" { settings.profiles[0].selectedModel = second.selectedModel }
            try require(!adapter.isAvailable(binding), "Unavailable profile must block readiness")
            await broker.poll()
        }
        let after = try await repository.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_task_generations") }
        let recorded = await calls.bodies
        try require(recorded.isEmpty && before == after, "Invalid profiles cannot contact the engine or reserve a request")
    }

    static func resistantGeneration(repository: LocalChatRepository, engine: NativeTaskEngineIdentity,
                                    request: NativeResearchTaskRequest, profile: NativeTaskProfileBinding) async throws {
        let reference = try repository.prepareTaskReference(origin: origin(repository), engine: engine, request: request, profile: profile)
        let remote = UUID().uuidString
        let accepted = try JSONDecoder().decode(NativeTaskSnapshot.self, from: snapshot(reference, id: remote))
        let saved = try repository.acknowledgeTaskReference(id: reference.id, snapshot: accepted)
        let binding = saved.createRequest.payload.nativeBinding!
        let messages = [NativeTaskGenerationMessage(role: "user", content: "Fictional question")]
        let job = NativeTaskGenerationJob(id: UUID().uuidString, taskID: remote, bindingID: binding.id,
            enrollmentDigest: binding.enrollmentDigest, admissionBase: binding.admissionBase,
            phase: "plan", attempt: "initial-0", messages: messages,
            messagesDigest: NativeTaskGenerationJob.digest(messages), deadlineSeconds: 0.05, generation: 1)
        let wire = try nativeTaskEncoded(job)
        let client = NativeTaskClient { _, _, _, _ in (wire, 200) }
        let broker = NativeTaskGenerationBroker(repository: repository, client: client,
            configuredBase: { engine.base }, isProfileAvailable: { _ in true }, generate: { _, _ in
                await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
                return "Late response"
            })
        let started = ContinuousClock.now
        await broker.poll()
        try require(nativeTaskSeconds(started.duration(to: .now)) < 0.2, "Resistant generation cannot hold the broker")
        try await Task.sleep(for: .milliseconds(300))
        try require(try repository.reserveTaskGeneration(referenceID: saved.id, job: job)
            == .unavailable("request_timeout"), "Known timeout stays spent and late output cannot overwrite it")
    }

    static func lostAcknowledgmentDeletion(directory: URL, engine: NativeTaskEngineIdentity,
                                          request: NativeResearchTaskRequest) async throws {
        let url = directory.appendingPathComponent("lost.sqlite")
        let repository = try repository(url)
        let origin = try origin(repository)
        let capture = NativeTaskFixtureRequests()
        let remote = UUID().uuidString
        let firstClient = NativeTaskClient { _, _, body, _ in
            await capture.append(body!)
            throw NativeTaskHTTPError.unavailable
        }
        let service = NativeTaskHandoffService(repository: repository, client: firstClient, configuredBase: { engine.base })
        let pending = try await service.submit(origin: origin, request: request)
        try require(pending.deliveryState == .pending, "Lost acknowledgment remains pending")
        try await repository.database.write { db in
            try LocalChatRepository.detachTasks(db, conversationID: origin.conversationID)
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [origin.conversationID])
        }
        let reopened = try self.repository(url)
        let createReceipt = try snapshot(pending, id: remote)
        let cancelReceipt = try snapshot(pending, id: remote, state: "canceled", canceled: true)
        let recoveryClient = NativeTaskClient { _, url, body, _ in
            if url.lastPathComponent == "cancel" { return (cancelReceipt, 200) }
            await capture.append(body!)
            return (createReceipt, 201)
        }
        await NativeTaskHandoffService(repository: reopened, client: recoveryClient,
            configuredBase: { engine.base }).recoverPending()
        let bodies = await capture.bodies
        try require(bodies.count == 2 && bodies[0] == bodies[1], "Restart must replay the same creation key and body")
        try require(try reopened.listConversations().isEmpty, "Recovery cannot recreate deleted chat")
        try require(try reopened.taskReference(id: pending.id) == nil, "Canceled orphan content is removed")
        let tombstones = try await reopened.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_task_outbox WHERE reference_json IS NULL")
        }
        try require(tombstones == 1, "Minimal identity tombstone remains")
    }
}

actor NativeTaskFixtureRequests {
    var bodies: [Data] = []
    func append(_ data: Data) { bodies.append(data) }
}
