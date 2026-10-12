import Foundation

final class NativeSessionReadFailureRepository: ChatRepository, NativeConversationTurnRepository, @unchecked Sendable {
    let base: LocalChatRepository
    let lock = NSLock()
    var failReads = false
    var failReadsAfterAcceptance = true
    var failTurnWrites = false
    var historyReads = 0
    var transcriptReads = 0
    var polledRecords = 0
    init(_ base: LocalChatRepository) { self.base = base }
    func listConversations() throws -> [Conversation] { try base.listConversations() }
    func messages(conversationID: String) throws -> [Message] {
        lock.withLock { transcriptReads += 1 }
        if lock.withLock({ failReads }) { throw NativeToolError.failed("synthetic refresh failure") }
        return try base.messages(conversationID: conversationID)
    }
    func recentMessages(conversationID: String, limit: Int) throws -> [Message] { try base.recentMessages(conversationID: conversationID, limit: limit) }
    func saveConversation(_ conversation: Conversation) throws { try base.saveConversation(conversation) }
    func saveMessage(_ message: Message, conversationID: String, ordinal: Int) throws { try base.saveMessage(message, conversationID: conversationID, ordinal: ordinal) }
    func deleteConversation(_ id: String) throws { try base.deleteConversation(id) }
    func conversation(originType: String, originID: String) throws -> Conversation? { try base.conversation(originType: originType, originID: originID) }
    func createOriginConversation(_ conversation: Conversation, seed: Message) throws { try base.createOriginConversation(conversation, seed: seed) }
    func referencedAttachmentFileNames() throws -> Set<String> { try base.referencedAttachmentFileNames() }
    func conversationTurns() throws -> [NativeConversationTurn] {
        lock.withLock { historyReads += 1 }
        return try base.conversationTurns()
    }
    func conversationTurnChangeToken() throws -> [Int64] { try base.conversationTurnChangeToken() }
    func conversationTurnHeaders() throws -> [NativeConversationTurnHeader] { try base.conversationTurnHeaders() }
    func pollConversationTurns(watching: Set<UUID>) throws -> [NativeConversationTurn] {
        let records = try base.pollConversationTurns(watching: watching)
        lock.withLock { polledRecords += records.count }
        return records
    }
    func acceptTurn(_ turn: NativeConversationTurn, conversation: Conversation, user: Message, reply: Message) throws {
        try base.acceptTurn(turn, conversation: conversation, user: user, reply: reply)
        lock.withLock { failReads = failReadsAfterAcceptance }
    }
    func enrollLegacyTurn(_ turn: NativeConversationTurn) throws { try base.enrollLegacyTurn(turn) }
    func claimTurn(_ id: UUID, attempt: UUID) throws -> NativeConversationTurn? { try base.claimTurn(id, attempt: attempt) }
    func turnIsCurrent(_ id: UUID, attempt: UUID) throws -> Bool { try base.turnIsCurrent(id, attempt: attempt) }
    func markTurnDispatch(_ id: UUID, attempt: UUID, activity: NativeToolActivity) throws { try base.markTurnDispatch(id, attempt: attempt, activity: activity) }
    func checkpointTurn(_ turn: NativeConversationTurn, message: Message, ordinal: Int) throws {
        if lock.withLock({ failTurnWrites }) { throw NativeToolError.failed("synthetic checkpoint failure") }
        try base.checkpointTurn(turn, message: message, ordinal: ordinal)
    }
    func finishTurn(_ id: UUID, attempt: UUID?, state: NativeConversationTurn.State, message: Message, ordinal: Int) throws {
        if lock.withLock({ failTurnWrites }) { throw NativeToolError.failed("synthetic final state failure") }
        try base.finishTurn(id, attempt: attempt, state: state, message: message, ordinal: ordinal)
    }
    func retryTurn(_ id: UUID, profile: String) throws { try base.retryTurn(id, profile: profile) }
}

@MainActor
enum NativeSessionSafetyFixture {
    static func run() async throws {
        let require = NativeTaskFixture.require
        let base = try LocalChatRepository(inMemory: true)
        let wrapper = NativeSessionReadFailureRepository(base)
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(),
            repository: wrapper, artifactPersistenceEnabled: false)
        store.newConversation()
        store.suspendsTurnScheduling = true
        store.draft = "saved before refresh failed"
        store.send()
        try require(store.draft.isEmpty && store.selected?.messages.count == 2,
                    "A postcommit reload failure must not reject or duplicate an accepted message")
        try require(try base.conversationTurns().count == 1 && base.messages(conversationID: store.selectedID!).count == 2,
                    "Acceptance remains exactly one durable pair despite refresh failure")
        let pending = try base.conversationTurns()[0]
        let claimed = try base.claimTurn(pending.id, attempt: UUID())!
        try require(try base.claimTurn(pending.id, attempt: UUID()) == nil, "Only one process may claim a pending turn")
        do {
            try base.finishTurn(pending.id, attempt: nil, state: .interrupted, message: store.selected!.messages[1], ordinal: 1)
            throw NativeTaskFixture.Failure.assertion("A stale pending rejection must not interrupt another instance's claim")
        } catch is CancellationError {}
        let mutation = NativeToolActivity(id: "unconfirmed-action", toolID: "reminders", name: "apple_reminders_create",
            title: "Create reminder", round: 1, request: "{}", result: nil, state: .pending, confirmationRequired: false)
        try base.markTurnDispatch(claimed.id, attempt: claimed.attempt!, activity: mutation)
        var interrupted = store.selected!.messages[1]
        interrupted.state = .interrupted
        try base.finishTurn(claimed.id, attempt: claimed.attempt, state: .interrupted, message: interrupted, ordinal: 1)
        do {
            try base.retryTurn(claimed.id, profile: claimed.profile)
            throw NativeTaskFixture.Failure.assertion("Unconfirmed mutation dispatch must prevent unsafe replay")
        } catch is NativeToolError {}
        try require(try base.conversationTurns()[0].mayHaveEffect,
                    "Dispatch marker survives a later stale message checkpoint that lacks tool activity")
        var options = NativeChatRequestOptions.none
        options.topLevel = [.init(key: "temperature", value: .number(0.2), source: .override)]
        func config(_ options: NativeChatRequestOptions) -> NativeChatConfig {
            .init(baseURL: NativeSessionFixture.config.baseURL, apiKey: nil, model: "local-model", chatTemplateKwargs: nil, options: options)
        }
        let firstFingerprint = NativeConversationTurn.fingerprint(config(options))
        options.topLevel[0] = .init(key: "temperature", value: .number(0.7), source: .override)
        try require(firstFingerprint != NativeConversationTurn.fingerprint(config(options)),
                    "Scalar model option values must change the configuration fingerprint")
        let topLevelFingerprint = NativeConversationTurn.fingerprint(config(options))
        options.kwargs = options.topLevel
        options.topLevel = []
        try require(topLevelFingerprint != NativeConversationTurn.fingerprint(config(options)),
                    "Top-level and template option scopes must not collide")
        try await legacyRetry()
        try await changedProfile()
        try await revokedConfirmation()
        try await separateResearchStop()
        try await finalizationRecovery()
        try await finalizationReplaced()
        try await idleHistory()
        try terminalRefreshRetry()
        try fastExternalCompletion()
        print("NATIVE SESSION SAFETY FIXTURE OK")
    }

    static func finalizationRecovery() async throws {
        let base = try LocalChatRepository(inMemory: true)
        let repository = NativeSessionReadFailureRepository(base)
        repository.lock.withLock { repository.failReadsAfterAcceptance = false; repository.failTurnWrites = true }
        let transport = NativeSessionFixtureTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
            repository: repository, artifactPersistenceEnabled: false)
        store.newConversation()
        store.sendText("first saved answer")
        store.sendText("queued follow-up")
        try await NativeSessionFixture.eventually("Failed final state must retain local ownership") {
            store.turnExecutions.values.contains { $0.finalization != nil }
        }
        let records = try base.conversationTurns()
        try NativeTaskFixture.require(records.filter { $0.state == .running }.count == 1
            && records.filter { $0.state == .pending }.count == 1 && store.turnExecutions.count == 1,
            "A temporary write failure must not strand a running record without local finalization ownership")
        try NativeTaskFixture.require(transport.histories.count == 1, "State-save recovery must not replay provider work")
        repository.lock.withLock { repository.failTurnWrites = false }
        store.scheduleConversationTurns()
        try await NativeSessionFixture.eventually("Queue must resume once storage recovers") {
            store.selected?.messages.last?.state == .complete && store.turnExecutions.isEmpty
        }
        let recovered = try base.conversationTurns()
        try NativeTaskFixture.require(recovered[0].state == .interrupted && recovered[1].state == .complete
            && transport.histories.count == 2, "Only the queued answer may start after finalization recovers")
    }

    static func finalizationReplaced() async throws {
        for deleted in [false, true] {
            let base = try LocalChatRepository(inMemory: true)
            let repository = NativeSessionReadFailureRepository(base)
            repository.lock.withLock { repository.failReadsAfterAcceptance = false; repository.failTurnWrites = true }
            let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(),
                repository: repository, artifactPersistenceEnabled: false)
            store.newConversation()
            store.sendText("answer with a delayed state save")
            try await NativeSessionFixture.eventually("Finalization should wait for storage") {
                store.turnExecutions.values.contains { $0.finalization != nil }
            }
            let turn = try base.conversationTurns()[0]
            if deleted {
                try base.deleteConversation(turn.conversationID)
            } else {
                var reply = try base.messages(conversationID: turn.conversationID)[1]
                reply.state = .interrupted
                try base.finishTurn(turn.id, attempt: turn.attempt, state: .stopped, message: reply, ordinal: 1)
                try base.retryTurn(turn.id, profile: turn.profile)
                _ = try base.claimTurn(turn.id, attempt: UUID())
            }
            repository.lock.withLock { repository.failTurnWrites = false }
            store.scheduleConversationTurns()
            try NativeTaskFixture.require(store.turnExecutions.isEmpty,
                "Deleted or superseded attempts must release stale local finalization ownership")
            let records = try base.conversationTurns()
            try NativeTaskFixture.require(deleted ? records.isEmpty : records[0].state == .running && records[0].attempt != turn.attempt,
                "Late state saves must not recreate deleted records or overwrite a newer attempt")
        }
    }

    static func idleHistory() async throws {
        let base = try LocalChatRepository(inMemory: true)
        let writer = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(),
            repository: base, artifactPersistenceEnabled: false)
        writer.newConversation()
        for index in 0..<40 {
            writer.sendText("Completed history \(index)")
            try await NativeSessionFixture.eventually("Fixture history must complete") { writer.turnExecutions.isEmpty }
        }
        let repository = NativeSessionReadFailureRepository(base)
        repository.lock.withLock { repository.failReadsAfterAcceptance = false }
        let reader = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(),
            repository: repository, artifactPersistenceEnabled: false)
        reader.reloadConversationTurns()
        reader.scheduleConversationTurns()
        let before = repository.lock.withLock { (repository.historyReads, repository.transcriptReads, repository.polledRecords) }
        for _ in 0..<8 { reader.scheduleConversationTurns() }
        try base.saveConversation(writer.selected!)
        reader.scheduleConversationTurns()
        let after = repository.lock.withLock { (repository.historyReads, repository.transcriptReads, repository.polledRecords) }
        try NativeTaskFixture.require(before == after,
            "Idle and unrelated-write ticks must not decode completed turn histories or reload old transcripts")
    }

    static func terminalRefreshRetry() throws {
        let base = try LocalChatRepository(inMemory: true)
        let writer = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(),
            repository: base, artifactPersistenceEnabled: false)
        writer.newConversation()
        writer.suspendsTurnScheduling = true
        writer.sendText("Remote process answer")
        let pending = try base.conversationTurns()[0]
        let running = try base.claimTurn(pending.id, attempt: UUID())!
        let repository = NativeSessionReadFailureRepository(base)
        let reader = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(),
            repository: repository, artifactPersistenceEnabled: false)
        reader.scheduleConversationTurns()
        var reply = try base.messages(conversationID: running.conversationID)[1]
        reply.text = "The remote answer completed."
        reply.state = .complete
        try base.finishTurn(running.id, attempt: running.attempt, state: .complete, message: reply, ordinal: 1)
        repository.lock.withLock { repository.failReads = true }
        reader.scheduleConversationTurns()
        try NativeTaskFixture.require(reader.dirtyTurnConversations.contains(running.conversationID),
            "A failed terminal transcript refresh must remain dirty after its turn becomes inactive")
        repository.lock.withLock { repository.failReads = false }
        reader.scheduleConversationTurns()
        let restored = reader.conversations.first { $0.id == running.conversationID }?.messages.last
        try NativeTaskFixture.require(reader.dirtyTurnConversations.isEmpty && restored?.state == .complete
            && restored?.text == reply.text, "An unchanged idle tick must retry the failed visible terminal refresh")
        let reads = repository.lock.withLock { repository.transcriptReads }
        reader.scheduleConversationTurns()
        try NativeTaskFixture.require(reads == repository.lock.withLock { repository.transcriptReads },
            "Successful terminal refresh must restore the zero-reload idle path")
    }

    static func fastExternalCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fast-completion.sqlite")
        let original = try LocalChatRepository(url: url)
        let other = try LocalChatRepository(url: url)
        let reader = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(),
            repository: original, artifactPersistenceEnabled: false)
        reader.scheduleConversationTurns()
        let writer = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(),
            repository: other, artifactPersistenceEnabled: false)
        writer.newConversation()
        writer.suspendsTurnScheduling = true
        writer.sendText("Accepted and completed between polls")
        let pending = try other.conversationTurns()[0]
        let running = try other.claimTurn(pending.id, attempt: UUID())!
        var reply = try other.messages(conversationID: running.conversationID)[1]
        reply.text = "A fast answer from the other instance."
        reply.state = .complete
        try other.finishTurn(running.id, attempt: running.attempt, state: .complete, message: reply, ordinal: 1)
        reader.scheduleConversationTurns()
        let visible = reader.conversations.first { $0.id == running.conversationID }?.messages
        try NativeTaskFixture.require(visible?.count == 2 && visible?.last?.state == .complete && visible?.last?.text == reply.text,
            "A task completed entirely between another instance's polls must still restore its messages and new conversation")
    }

    static func legacyRetry() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let user = Message(role: .user, text: "What happened in the match?")
        let reply = Message(role: .assistant, text: "", state: .interrupted, failure: "Old tool budget reached")
        let conversation = Conversation(id: UUID().uuidString, title: "Earlier chat", messages: [user, reply], updatedAt: Date(), isPersisted: true)
        try repository.saveConversation(conversation)
        try repository.saveMessage(user, conversationID: conversation.id, ordinal: 0)
        try repository.saveMessage(reply, conversationID: conversation.id, ordinal: 1)
        let store = NativeSessionFixture.store(repository, transport: NativeSessionFixtureTransport(), gate: NativeSessionGate())
        store.conversations = [conversation]
        store.selectedID = conversation.id
        store.retryLastTurn()
        try await NativeSessionFixture.eventually("Explicit legacy retry should finish") { store.selected?.messages.last?.state == .complete }
        try NativeTaskFixture.require(try repository.messages(conversationID: conversation.id).map(\.id) == [user.id, reply.id],
                                      "Legacy retry must retain the original user/reply IDs without duplicate messages")
        try NativeTaskFixture.require(try repository.conversationTurns().count == 1,
                                      "Legacy retry is enrolled only after the explicit user action")
    }

    static func changedProfile() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let transport = NativeSessionFixtureTransport()
        let store = NativeSessionFixture.store(repository, transport: transport, gate: NativeSessionGate())
        store.suspendsTurnScheduling = true
        store.sendText("saved with original model")
        store.applyNativeOptions(.init(baseURL: NativeSessionFixture.config.baseURL, apiKey: nil,
            model: "changed-model", chatTemplateKwargs: nil))
        store.suspendsTurnScheduling = false
        store.scheduleConversationTurns()
        try NativeTaskFixture.require(transport.histories.isEmpty && store.conversationTurns.first?.state == .interrupted,
                                      "Pending messages must not silently use a changed model")
    }
    static func revokedConfirmation() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let gate = NativeSessionGate()
        await gate.release()
        let store = NativeSessionFixture.store(repository, transport: NativeSessionFixtureTransport(), gate: gate, confirmation: true)
        store.sendText("slow action")
        let id = store.selected!.messages.last!.id
        try await NativeSessionFixture.eventually("Confirmation must be visible before revocation") { store.turnConfirmations[id] != nil }
        let request = store.turnConfirmations[id]!
        let token = store.turnConfirmationTokens[id]!
        store.updateNativeToolConsent([])
        store.resolveTurnConfirmation(id, approved: true, requestID: request.id, token: token)
        try await NativeSessionFixture.eventually("Revoked action must stop without execution") { store.selected?.messages.last?.state == .interrupted }
        let executions = await gate.waiting
        try NativeTaskFixture.require(executions == 0, "Disabling a tool while approval is pending must prevent its effect")
    }

    static func separateResearchStop() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let remote = UUID().uuidString
        let request = try NativeResearchTaskRequest(objective: "Compare two fictional materials", deliverables: ["Cited report"])
        let payloadData = try nativeTaskEncoded(NativeResearchTaskPayload(request: request))
        let taskClient = NativeTaskClient { _, url, body, _ in
            let input = try body.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
            let canceled = url.lastPathComponent == "cancel"
            let response = try NativeTaskClient.canonical(["id": remote, "worker_type": "research",
                "payload": input?["payload"] ?? JSONSerialization.jsonObject(with: payloadData), "state": canceled ? "canceled" : "queued",
                "checkpoint": [:], "cancel_requested": canceled, "generation": 1, "updated_at": 1.0])
            return (response, 200)
        }
        let gate = NativeSessionGate()
        let hold = NativeToolDefinition(id: "hold", name: "hold", title: "Check reference", description: "Read a fixture",
            parameters: .object(["type": .string("object")]), confirmation: .none, isAvailable: { true },
            execute: { _ in await gate.wait(); return .object(["ready": .bool(true)]) })
        let store = ChatStore(veraAPI: VeraAPIClient(base: URL(string: "http://127.0.0.1:1")!),
            nativeConfig: NativeSessionFixture.config, nativeTransport: NativeSessionFixtureTransport(), repository: repository,
            nativeEnabledToolIDs: ["hold", NativeWebTools.researchToolID],
            nativeToolRegistry: NativeToolRegistry(definitions: [hold]), nativeTaskClient: taskClient,
            artifactPersistenceEnabled: false)
        store.newConversation()
        store.sendText("slow research acknowledgment")
        let messages = store.selected!.messages
        try await NativeSessionFixture.eventually("Foreground tool should wait during research handoff") {
            store.selected?.messages.last?.toolActivities.isEmpty == false
        }
        let origin = NativeTaskOrigin(conversationID: store.selectedID!, userMessageID: messages[0].id,
                                      assistantMessageID: messages[1].id)
        let reference = try await store.nativeTaskService!.submit(origin: origin,
            request: request)
        if let update = try repository.projectTask(id: reference.id, snapshot: reference.snapshot) { store.applyNativeTaskUpdates([update]) }
        store.stopAnswer(messages[1].id)
        let saved = try repository.taskReference(id: reference.id)!
        let transcript = try repository.messages(conversationID: origin.conversationID)
        try NativeTaskFixture.require(!saved.cancelRequested && transcript[1].displayBlocks.contains {
            if case .taskCard(let card) = $0 { return card.canCancel }; return false
        }, "Stop answer must retain the independent research card and its Stop research action")
        let canceled = try await store.nativeTaskService!.requestCancellation(reference.id)
        try NativeTaskFixture.require(canceled.cancelRequested && canceled.cancelDelivered,
                                      "The retained research task must remain independently cancellable: \(canceled.cancelRequested), \(canceled.cancelDelivered), \(canceled.lastDeliveryError ?? "none")")
        await gate.release()
    }

}
