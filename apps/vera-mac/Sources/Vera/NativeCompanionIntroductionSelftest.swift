import Foundation
import GRDB

final class NativeCompanionIntroductionTransport: NativeChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[NativeChatMessage]] = []
    private var capturedTools: [[NativeToolSchema]] = []
    var advertisedTools: [[NativeToolSchema]] { lock.withLock { capturedTools } }
    var histories: [[NativeChatMessage]] { lock.withLock { captured } }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        lock.withLock { captured.append(messages); capturedTools.append(tools) }
        let current = messages.last(where: { $0.role == "user" })?.content ?? ""
        var call: NativeChatToolCall?
        var content = "What would you like to call me?"
        if messages.last?.role == "tool" {
            content = "What may I do without asking?"
        } else if tools.contains(where: { $0.name == NativeCompanionProfileTools.name }) {
            let arguments: String?
            switch current {
            case "Call yourself Moss": arguments = "{\"action\":\"name\",\"value\":\"Moss\"}"
            case "Watch the greenhouse": arguments = "{\"action\":\"goal\",\"value\":\"Watch the greenhouse\"}"
            case "Hand commands to me": arguments = "{\"action\":\"rule\",\"category\":\"commands\",\"value\":\"hand_off\"}"
            case "Ask before commands": arguments = "{\"action\":\"rule\",\"category\":\"commands\",\"value\":\"ask\"}"
            case "Run commands without asking": arguments = "{\"action\":\"rule\",\"category\":\"commands\",\"value\":\"act\"}"
            case "Remember I prefer brief replies": arguments = "{\"action\":\"note\",\"value\":\"Brief replies\"}"
            case "Connect Apple Reminders": arguments = "{\"action\":\"connect\",\"value\":\"Apple Reminders\"}"
            case "Disconnect Apple Reminders": arguments = "{\"action\":\"disconnect\",\"value\":\"Apple Reminders\"}"
            case "Setup is done": arguments = "{\"action\":\"finish_setup\",\"value\":\"\"}"
            default: arguments = nil; content = "I changed nothing."
            }
            if let arguments { call = NativeChatToolCall(id: UUID().uuidString, name: NativeCompanionProfileTools.name, arguments: arguments) }
        }
        let result = NativeChatStreamSnapshot(content: call == nil ? content : "", toolCalls: call.map { [$0] } ?? [], finishReason: call == nil ? "stop" : "tool_calls")
        return AsyncThrowingStream { continuation in continuation.yield(result); continuation.finish() }
    }
}

@MainActor
extension SelfTest {
    static func runCompanionIntroduction() async throws {
        let require = NativeTaskFixture.require
        for category in ["payments", "credential_entry", "permanent_deletion", "sensitive"] {
            var refused = false
            do { _ = try NativeCompanionProfileTools.change(["action": .string("rule"), "value": .string("hand_off"), "category": .string(category)]) } catch { refused = true }
            try require(refused, "A profile rule change never names a floor class: \(category)")
        }
        let risky = try NativeCompanionProfileTools.change(["action": .string("rule"), "value": .string("ask"), "category": .string("risky_commands")])
        try require(risky.category == "risky_commands" && risky.value == "ask", "A profile rule change accepts risky commands")
        var retiredRefused = false
        do { _ = try NativeCompanionProfileTools.change(["action": .string("rule"), "value": .string("act_if_preapproved"), "category": .string("commands")]) } catch { retiredRefused = true }
        try require(retiredRefused, "A profile rule change refuses the retired go ahead choice")
        let installed = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil, nativeAssistantName: "Installed")
        CompanionNameShot.apply(to: installed, environment: [:])
        try require(installed.companionName == CompanionNameShot.sampleName, "A shot never shows the installed companion name: it uses the sample name by default")
        CompanionNameShot.apply(to: installed, environment: [CompanionNameShot.variable: "none"])
        try require(installed.companionName == nil, "A shot can render an unnamed companion")
        CompanionNameShot.apply(to: installed, environment: [CompanionNameShot.variable: "Wren"])
        try require(installed.companionName == "Wren", "A shot can render a chosen sample name")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("companion-opening-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let repository = try LocalChatRepository(url: url)
        let transport = NativeCompanionIntroductionTransport()
        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
                              nativeEnabledToolIDs: ["apple-reminders"], artifactPersistenceEnabled: false)
        var persistedName = ""
        store.companionNameWriter = { persistedName = $0 }
        let askSuite = "tandem-companion-name-ask-\(UUID().uuidString)"
        guard let askDefaults = UserDefaults(suiteName: askSuite) else { throw NativeTaskFixture.Failure.assertion("Scratch defaults open") }
        defer { askDefaults.removePersistentDomain(forName: askSuite) }
        store.companionDefaults = askDefaults
        store.asksForCompanionName = true
        try require(CompanionNameAsk.atLaunch(name: nil, settingUp: false, dismissed: false) && !CompanionNameAsk.atLaunch(name: nil, settingUp: true, dismissed: false)
                        && !CompanionNameAsk.atLaunch(name: nil, settingUp: false, dismissed: true) && !CompanionNameAsk.atLaunch(name: "Ada", settingUp: false, dismissed: false)
                        && !CompanionNameAsk.atLaunch(name: "  ", settingUp: false, dismissed: true),
                    "An unnamed install is asked at launch once, not during setup, not after dismissing and not when named")
        await store.connect()
        store.askForCompanionNameAtLaunch(settingUp: false)
        try require(store.companionNameAsk == .launch, "An unnamed install is asked for a name at launch")
        store.finishCompanionNameAsk(named: false)
        store.askForCompanionNameAtLaunch(settingUp: false)
        try require(store.companionNameAsk == nil && store.companionNamePromptDismissed, "Not now is remembered and the launch question is not repeated")
        askDefaults.removeObject(forKey: CompanionNameAsk.dismissedKey)
        store.openVeraThread()
        guard let id = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("Companion exists") }
        try require(store.companionNameAsk == .firstOpen && (try repository.messages(conversationID: id)).isEmpty && transport.histories.isEmpty,
                    "Opening an unnamed companion asks for a name before anything is sent to the model")
        store.prepareCompanionThread()
        try require(store.companionNameAsk == .firstOpen && (try repository.messages(conversationID: id)).isEmpty && transport.histories.isEmpty,
                    "The main conversation view refreshing does not send the opening while the name question is up")
        store.finishCompanionNameAsk(named: false)
        try require(store.companionNameAsk == nil && store.companionName == nil, "Not now continues unnamed")
        let declined = try repository.conversationTurns().first { $0.companionEvent?.isOpening == true }?.companionEvent
        try require(declined?.kind == .introduction && declined?.observation == NativeCompanionEvent.nameDeclined
                        && declined?.instruction.contains("do not ask for one") == true && declined?.instruction.contains("would like to call you") == false,
                    "After Not now the opening tells the model not to ask for a name again")
        func settled() -> Bool { store.selected?.messages.last?.state == .complete && !store.conversationTurns.contains { $0.conversationID == id && ($0.state == .pending || $0.state == .running) } }
        try await NativeSessionFixture.eventually("Opening completes", settled)
        guard let openingTurn = store.conversationTurns.first(where: { $0.conversationID == id }) else { throw NativeTaskFixture.Failure.assertion("The opening turn exists") }
        let followUp = store.companionProfileInstruction(for: openingTurn)
        try require(followUp.contains("do not ask for a name") && !followUp.contains("one question at a time: name,"),
                    "After Not now, later setup turns are also told not to ask for a name")
        try require(store.selected?.messages.count == 1 && store.selected?.messages.first?.role == .assistant, "Opening contains only a real assistant response")
        try require(transport.histories.first?.contains(where: { $0.role == "user" }) == false, "Opening sends no fabricated user message")
        for _ in 0..<3 { store.prepareCompanionOpening() }
        try require(try repository.messages(conversationID: id).count == 1, "Opening is admitted once")
        let reopening = try LocalChatRepository(url: url)
        try require(try reopening.conversationTurns().filter { $0.companionEvent?.isOpening == true }.count == 1, "Opening identity survives restart")
        let userLinks = try await reopening.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM native_conversation_turns WHERE companion_event IS NOT NULL AND user_message_id IS NOT NULL") ?? -1 }
        try require(userLinks == 0, "Assistant origin has no user foreign key")
        func send(_ text: String) async throws {
            try require(store.sendText(text, conversationID: id), "Accept companion answer")
            try await NativeSessionFixture.eventually("Companion answer completes", settled)
        }
        try await send("Call yourself Moss")
        try require(persistedName == "Moss" && store.companionName == "Moss", "Name saved through current tool call")
        let profileBeforeRetired = store.dotProfile
        try await send("Watch the greenhouse")
        try require(store.dotProfile == profileBeforeRetired, "A retired profile action changes nothing")
        try await send("Hand commands to me")
        try require(store.ruleResolver(for: id, requestText: "").choice(for: .commands) == .handOff && store.turnConfirmations.isEmpty, "Tightening applies without widening card")
        try require(store.sendText("Ask before commands", conversationID: id), "Accept widening request")
        try await NativeSessionFixture.eventually("Exact widening asks first") { !store.turnConfirmations.isEmpty }
        guard let (reply, request) = store.turnConfirmations.first else { throw NativeTaskFixture.Failure.assertion("Confirmation exists") }
        try require(NativeCompanionProfileTools.prompt(request)?.contains("ask first") == true, "Card names the exact proposed change")
        store.resolveTurnConfirmation(reply, approved: false, requestID: request.id)
        try await NativeSessionFixture.eventually("Decline completes", settled)
        try require(store.ruleResolver(for: id, requestText: "").choice(for: .commands) == .handOff, "Decline preserves rule")
        try require(store.sendText("Ask before commands", conversationID: id), "Accept stale widening request")
        try await NativeSessionFixture.eventually("Stale widening asks first") { !store.turnConfirmations.isEmpty }
        store.saveDotProfile { $0.connectedToolIDs = [] }
        if let (reply, request) = store.turnConfirmations.first { store.resolveTurnConfirmation(reply, approved: true, requestID: request.id) }
        try await NativeSessionFixture.eventually("Stale approval settles", settled)
        try require(store.ruleResolver(for: id, requestText: "").choice(for: .commands) == .handOff,
                    "Approval cannot apply after the profile changes")
        store.saveDotProfile { $0.connectedToolIDs = nil }
        try require(store.sendText("Ask before commands", conversationID: id), "Accept second widening request")
        try await NativeSessionFixture.eventually("Widening still asks first") { !store.turnConfirmations.isEmpty }
        guard let (approvedReply, approvedRequest) = store.turnConfirmations.first else { throw NativeTaskFixture.Failure.assertion("Second confirmation exists") }
        store.resolveTurnConfirmation(approvedReply, approved: true, requestID: approvedRequest.id)
        try await NativeSessionFixture.eventually("Approval completes", settled)
        try require(store.ruleResolver(for: id, requestText: "").choice(for: .commands) == .ask, "Approval relaxes only companion restriction")
        try require(store.sendText("Run commands without asking", conversationID: id), "Accept over-ceiling request")
        try await NativeSessionFixture.eventually("Over-ceiling request settles", settled)
        try require(store.ruleResolver(for: id, requestText: "").choice(for: .commands) == .ask, "Approval cannot cross global ceiling")
        let profileBeforeProse = store.dotProfile
        try await send("Just describe a profile change")
        try require(store.dotProfile == profileBeforeProse, "Model prose does not mutate profile")
        try await send("Remember I prefer brief replies")
        try require(try repository.pendingProposals().isEmpty, "Memory off never creates preference records")
        var memorySettings = store.nativeMemorySettings
        memorySettings.enabled = true
        store.updateNativeMemory(settings: memorySettings, service: nil)
        let approvedBefore = try repository.approvedMemories()
        try await send("Remember I prefer brief replies")
        try require(try repository.pendingProposals().contains { $0.summary == "Brief replies" && $0.status == .pending },
                    "Memory-enabled preference becomes a pending suggestion")
        try require(try repository.approvedMemories() == approvedBefore, "Preference suggestion cannot change approved memory")
        memorySettings.enabled = false
        store.updateNativeMemory(settings: memorySettings, service: nil)
        try await send("Disconnect Apple Reminders")
        try require(!store.dotSelectedServices(store.dotServiceOptions()).contains("apple-reminders"), "Disconnect removes companion service scope")
        try require(store.sendText("Connect Apple Reminders", conversationID: id), "Accept service proposal")
        try await NativeSessionFixture.eventually("Service asks first") { !store.turnConfirmations.isEmpty }
        if let (reply, request) = store.turnConfirmations.first {
            try require(NativeCompanionProfileTools.prompt(request) == "Allow this companion to use Apple Reminders?", "Service card names exact service")
            store.resolveTurnConfirmation(reply, approved: false, requestID: request.id)
        }
        try await NativeSessionFixture.eventually("Service decline settles", settled)
        try require(!store.dotSelectedServices(store.dotServiceOptions()).contains("apple-reminders"), "Declined service stays disconnected")
        try require(store.sendText("Connect Apple Reminders", conversationID: id), "Accept service approval")
        try await NativeSessionFixture.eventually("Service approval asks") { !store.turnConfirmations.isEmpty }
        if let (reply, request) = store.turnConfirmations.first { store.resolveTurnConfirmation(reply, approved: true, requestID: request.id) }
        try await NativeSessionFixture.eventually("Service approval settles", settled)
        try require(store.dotSelectedServices(store.dotServiceOptions()).contains("apple-reminders"), "Approved service joins companion scope")
        try await send("Setup is done")
        try require(store.dotProfile.setupCompleted, "Setup can finish through the tool")
        store.prepareCompanionRefinement()
        try require(!store.conversationTurns.contains { $0.companionEvent?.kind == .refinement }, "Nothing to follow up on admits no refinement")
        let finished = try OngoingWorkFixture.reference(conversationID: id, title: "Greenhouse note", workerType: "document", state: "completed",
                                                        result: OngoingWorkFixture.documentResult("Greenhouse note"),
                                                        updatedAt: Date().timeIntervalSince1970)
        store.nativeTaskReferences.append(finished)
        store.draft = "A new request"
        store.prepareCompanionRefinement()
        try require(!store.conversationTurns.contains { $0.companionEvent?.kind == .refinement }, "Refinement does not interrupt a draft")
        store.draft = ""
        store.prepareCompanionRefinement()
        try await NativeSessionFixture.eventually("Finished work refinement completes", settled)
        try require(store.conversationTurns.filter { $0.companionEvent?.kind == .refinement }.count == 1, "Finished work admits one refinement")
        try require(store.conversationTurns.first { $0.companionEvent?.kind == .refinement }?.companionEvent?.key == "work:" + finished.id.uuidString,
                    "The refinement follows the finished work")
        store.prepareCompanionRefinement()
        try require(store.conversationTurns.filter { $0.companionEvent?.kind == .refinement }.count == 1, "Refinement is rate limited")
        store.prepareCompanionRefinement(now: Date().addingTimeInterval(ChatStore.companionRefinementInterval + 10))
        try require(store.conversationTurns.filter { $0.companionEvent?.kind == .refinement }.count == 1, "An unanswered refinement is not repeated after the interval")
        store.resetDot()
        try require(store.veraThreadID != id, "Reset creates a new persistent conversation")
        try await NativeSessionFixture.eventually("Reset introduces again") { store.selected?.messages.first?.state == .complete }
        try require(store.selected?.messages.count == 1 && store.selected?.messages.first?.role == .assistant, "Reset intro has no fake user")
        try require(store.conversationTurns.first(where: { $0.conversationID == store.veraThreadID })?.companionEvent?.kind == .introduction,
                    "Reset introduces again despite the saved name")
        let ordinaryTransport = NativeCompanionIntroductionTransport()
        let ordinary = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: ordinaryTransport,
                                 repository: try LocalChatRepository(inMemory: true), artifactPersistenceEnabled: false)
        await ordinary.connect()
        ordinary.newConversation()
        try require(ordinary.sendText("Watch the greenhouse"), "Ordinary chat accepts message")
        try await NativeSessionFixture.eventually("Ordinary chat completes") { ordinary.selected?.messages.last?.state == .complete }
        try require(ordinaryTransport.advertisedTools.allSatisfy { !$0.contains { $0.name == NativeCompanionProfileTools.name } },
                    "Ordinary chat never advertises companion profile tools")
        let pendingURL = directory.appendingPathComponent("pending.sqlite")
        let pendingRepository = try LocalChatRepository(url: pendingURL)
        let pending = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
                                repository: pendingRepository, artifactPersistenceEnabled: false)
        await pending.connect()
        pending.suspendsTurnScheduling = true
        pending.adoptAssistantName("Moss")
        pending.openVeraThread()
        pending.resetDot()
        let openingID = pending.selected?.messages.first?.id
        try require(openingID != nil, "Opening is durable before model dispatch")
        let restartedTransport = NativeCompanionIntroductionTransport()
        let restarted = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: restartedTransport,
                                  repository: try LocalChatRepository(url: pendingURL), nativeAssistantName: "Moss", artifactPersistenceEnabled: false)
        await restarted.connect()
        restarted.openVeraThread()
        try await NativeSessionFixture.eventually("Pending opening resumes after restart") { restarted.selected?.messages.first?.state == .complete }
        try require(restarted.selected?.messages.count == 1 && restarted.selected?.messages.first?.id == openingID,
                    "Restart uses the same opening message exactly once")
        try require(restarted.conversationTurns.first(where: { $0.conversationID == restarted.veraThreadID })?.companionEvent?.kind == .introduction,
                    "Reset before dispatch survives restart with the saved name")
        let failedTransport = NativeScriptedFailureTransport(failures: [NativeChatClient.ClientError.http(400, "The request could not complete.")])
        let failed = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: failedTransport,
                               repository: try LocalChatRepository(inMemory: true), artifactPersistenceEnabled: false)
        await failed.connect()
        failed.openVeraThread()
        try await NativeSessionFixture.eventually("Opening failure remains visible") { failed.selected?.messages.first?.state == .interrupted }
        let failedOpeningID = failed.selected?.messages.first?.id
        failed.retryLastTurn()
        try await NativeSessionFixture.eventually("Opening retry completes") { failed.selected?.messages.first?.state == .complete }
        try require(failed.selected?.messages.count == 1 && failed.selected?.messages.first?.id == failedOpeningID,
                    "Retry preserves the assistant-only opening identity")
        try require(failed.conversationTurns.filter { $0.companionEvent?.isOpening == true }.count == 1,
                    "Retry keeps the same durable origin")
        let renamed = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
                                repository: try LocalChatRepository(inMemory: true), nativeAssistantName: "Moss", artifactPersistenceEnabled: false)
        await renamed.connect()
        renamed.openVeraThread()
        try await NativeSessionFixture.eventually("Name-only existing profile opens") { renamed.selected?.messages.first?.state == .complete }
        try require(renamed.conversationTurns.first(where: { $0.companionEvent != nil })?.companionEvent?.kind == .welcome,
                    "A saved name alone does not restart onboarding")
        let configuredRepository = try LocalChatRepository(inMemory: true)
        let configured = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
                                   repository: configuredRepository, artifactPersistenceEnabled: false)
        await configured.connect()
        configured.saveDotProfile { $0.setupCompleted = true; $0.connectedToolIDs = ["apple-reminders"] }
        configured.openVeraThread()
        try await NativeSessionFixture.eventually("Saved empty profile opens") { configured.selected?.messages.first?.state == .complete }
        try require(configured.conversationTurns.first(where: { $0.companionEvent != nil })?.companionEvent?.kind == .welcome,
                    "Existing empty profile opens without re-onboarding")
        try require(configured.dotProfile.setupCompleted && configured.dotProfile.connectedToolIDs == ["apple-reminders"], "Opening preserves saved profile")

    }
}
