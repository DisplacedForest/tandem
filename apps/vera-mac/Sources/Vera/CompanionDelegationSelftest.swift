import Foundation

@MainActor
enum CompanionDelegationSelftest {
    static func run() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let relay = NativeCompanionWorkerRelay()
        let service = NativeCompanionFakeService()
        let gate = NativeSessionGate()
        let entered = CompanionTalkBox(false)
        let model = NativeCompanionScriptedModel { messages in
            if !messages.contains(where: { $0.role == "tool" }) {
                return NativeCompanionScriptedModel.call("garden_status", "{}", id: "read")
            }
            return .text("The garden check is complete. The original setting was 70 percent.")
        }
        let tools = NativeCompanionHarness.tools(service, reconcile: false).filter { $0.name == "garden_status" }
        relay.extraTools = tools
        let environment = relay.environment(database: repository.database)
        let engine = NativeTaskLocalEngine(database: repository.database, pollSeconds: 0.05, workers: { _ in
            ["companion": NativeTaskWorker(timeoutSeconds: 60) { task in
                try await NativeDSHWorker.step(task, environment: environment) { phase, attempt, ordinal, messages, offered, _ in
                    entered.value = true
                    await gate.wait()
                    return try model.complete(phase, attempt + "-\(ordinal)", messages, offered)
                }
            }]
        })
        let transport = CompanionAskedWorkTransport { user, messages, _ in
            if user == "Are you still here?" { return CompanionAskedWorkTransport.say("Yes, I'm here.") }
            if CompanionAskedWorkTransport.answered(messages) { return CompanionAskedWorkTransport.say("I'll check that.") }
            return CompanionAskedWorkTransport.hand([CompanionAskedWorkTransport.general("Check the garden status. The confirmed original setting was 70 percent.")])
        }
        let store = ChatStore(veraAPI: VeraAPIClient(base: NativeTaskLocalEngine.identity.base),
            nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
            nativeAssistantName: "Ada", nativeEnabledToolIDs: Set(tools.map(\.id)), nativeToolRegistry: NativeToolRegistry(definitions: tools),
            nativeTaskClient: engine.client, nativeSearchAvailable: { false }, artifactPersistenceEnabled: false)
        store.loadDotProfile()
        store.skipDotSetup()
        store.ensureVeraThread()
        relay.attach(store)
        store.stopNativeTaskRecovery()
        guard let thread = store.veraThreadID, let projection = store.repository as? any NativeTaskProjectionRepository,
              let handoff = store.nativeTaskService else { throw NativeTaskFixture.Failure.assertion("The companion is ready") }
        store.nativeTaskTracker = NativeTaskTracker(repository: projection, client: engine.client, service: handoff, transport: engine.transport,
            configuredBase: { NativeTaskLocalEngine.identity.base }, onUpdate: { [weak store] updates in store?.applyNativeTaskUpdates(updates) })
        store.startNativeTaskRecovery()
        try await engine.start()
        do {
            let harness = CompanionAskedWorkFixture.Harness(store: store, repository: repository, transport: transport, threadID: thread, posts: NativeChatRulesCounter())
            let acknowledgment = try await CompanionAskedWorkFixture.send(harness, "Check the garden. Its original setting was 70 percent.")
            try NativeTaskFixture.require(acknowledgment.text == "I'll check that.", "The companion acknowledges the saved handoff")
            try await CompanionTalkControlFixture.eventually("DSH receives the delegated request") { entered.value }
            try NativeTaskFixture.require(service.count("garden_status") == 0, "The foreground never runs the service lookup")
            let available = try await CompanionAskedWorkFixture.send(harness, "Are you still here?")
            try NativeTaskFixture.require(available.text == "Yes, I'm here.", "The companion stays responsive while DSH is running")
            try NativeTaskFixture.require(transport.records.allSatisfy { !$0.tools.contains(where: { $0.name == "garden_status" }) }, "Service tools are absent from the companion's foreground schemas")
            await gate.release()
            try await CompanionTalkControlFixture.eventually("The delegated result is delivered") {
                ((try? repository.messages(conversationID: thread)) ?? []).contains { $0.text.contains("The garden check is complete.") }
            }
            let saved = try repository.messages(conversationID: thread)
            try NativeTaskFixture.require(service.count("garden_status") == 1, "DSH executes the lookup once")
            try NativeTaskFixture.require(saved.filter { $0.text.contains("The garden check is complete.") }.count == 1, "The result reaches the originating conversation exactly once")
            try NativeTaskFixture.require(model.allRequests.contains { $0.contains { $0.content.contains("confirmed original setting was 70 percent") } }, "Confirmed conversational context reaches delegated work")
            try NativeTaskFixture.require(model.allOffered.contains { $0.contains("garden_status") }, "Delegated work retains the service tools hidden from the companion")
            store.conversationTurnLoop?.cancel()
            store.stopNativeTaskRecovery()
            await engine.stop()
        } catch {
            await gate.release()
            store.conversationTurnLoop?.cancel()
            store.stopNativeTaskRecovery()
            await engine.stop()
            throw error
        }
    }
}
