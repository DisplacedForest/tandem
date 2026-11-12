import Foundation

@MainActor
extension SelfTest {
    private static let retiredText = "  Grow tomatoes on the balcony.\n"
    private static let retiredWord = "goal"

    private static func retiredFree(_ text: String) -> Bool {
        !text.lowercased().contains(retiredWord) && !text.contains("Grow tomatoes on the balcony")
    }

    private static func requireRetiredFree(_ texts: [String], _ label: String) throws {
        for text in texts {
            try NativeTaskFixture.require(retiredFree(text), "\(label) never mentions the retired setting: \(text)")
        }
    }

    private static func savedValue(_ data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?[retiredWord] as? String
    }

    private static func injected(_ json: String) throws -> String {
        let escaped = String(decoding: try JSONEncoder().encode(retiredText), as: UTF8.self)
        let marker = "\"mode\":\"manual\""
        guard json.components(separatedBy: marker).count == 2 else { throw NativeTaskFixture.Failure.assertion("The saved request has one mode") }
        return json.replacingOccurrences(of: marker, with: "\"\(retiredWord)\":\(escaped)," + marker)
    }

    private static func retiredTurn(_ store: ChatStore, conversationID: String, event: NativeCompanionEvent? = nil) -> NativeConversationTurn {
        let user = Message(role: .user, text: "What can you reach?")
        var turn = NativeConversationTurn(id: UUID(), conversationID: conversationID, userMessageID: user.id, assistantMessageID: UUID(),
            mode: .chat, profile: "", enabledToolIDs: [], persona: "Persona", userScope: "", instructions: "", grounding: [],
            memorySettings: store.nativeMemorySettings, createdAt: Date(), history: [NativeTurnHistoryMessage(user)])
        turn.companionEvent = event
        return turn
    }

    static func runCompanionRetiredSetting() async throws {
        let require = NativeTaskFixture.require
        let oldJSON = try JSONSerialization.data(withJSONObject: [retiredWord: retiredText, "state": "active", "setup_completed": true,
                                                                  "updated_at": 1_800_000_000.0], options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(NativeDotProfile.self, from: oldJSON)
        try require(decoded.setupCompleted && decoded.state == .active, "A profile saved with the retired setting still decodes")
        try require(try savedValue(JSONEncoder().encode(decoded)) == retiredText, "Encoding carries the saved value byte for byte")
        try require(try savedValue(JSONEncoder().encode(NativeDotProfile())) == nil, "A new profile never writes the retired key")
        var renamedCopy = decoded
        renamedCopy.setupCompleted = false
        try require(renamedCopy != decoded, "Profiles still compare by their settings")

        let repository = try LocalChatRepository(inMemory: true)
        try NativeDotProfileStore(database: repository.database).save(decoded)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository,
                              nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
        await store.connect()
        store.nativeSchedulerLoop?.cancel()
        await store.nativeSchedulerLoop?.value
        store.nativeSchedulerLoop = nil
        defer { store.stopNativeTaskRecovery() }
        try require(store.dotProfile == decoded, "The store loads the old profile as saved")
        store.ensureVeraThread()
        guard let threadID = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion thread exists") }

        let resolver = store.ruleResolver(for: threadID, requestText: "")
        let overview = CompanionOverviewModel.build(name: "Ada", profile: store.dotProfile, services: "Can reach every service that is turned on.",
                                                    rules: NativeDotContext.headerSummary(resolver: resolver), activity: [], results: [])
        try requireRetiredFree([String(describing: overview), String(describing: store.companionOverviewModel())], "The panel")
        let context = store.dotContext(for: threadID, requestText: "") ?? ""
        let assembled = NativeContextAssembler.assemble(NativeContextInput(persona: "Persona", timestamp: Date(), timeZone: .current,
                                                                           assistantProfile: context)).prompt
            .components(separatedBy: "\n\n").filter { $0.hasPrefix("Your standing role") }.joined()
        try require(context.contains("You are Ada") && assembled.contains(context), "The companion still gets its standing context")
        try requireRetiredFree([context, assembled, NativeDotContext.render(name: "Ada", resolver: resolver),
                                NativeDotContext.render(name: "", resolver: resolver),
                                store.turnDotContext(retiredTurn(store, conversationID: threadID)) ?? ""], "The companion instructions")

        var setup = store.dotProfile
        setup.setupCompleted = false
        store.dotProfile = setup
        let named = retiredTurn(store, conversationID: threadID, event: NativeCompanionEvent(kind: .introduction, key: "opening"))
        store.conversationTurns.append(named)
        let namedInstruction = store.companionProfileInstruction(for: retiredTurn(store, conversationID: threadID))
        try require(namedInstruction.contains("name, then what may run without asking"), "Setup asks for the name, then the permissions: \(namedInstruction)")
        store.conversationTurns.removeAll { $0.id == named.id }
        var declinedEvent = NativeCompanionEvent(kind: .introduction, key: "opening")
        declinedEvent.observation = NativeCompanionEvent.nameDeclined
        let declined = retiredTurn(store, conversationID: threadID, event: declinedEvent)
        let previousName = store.companionName
        store.adoptAssistantName(nil)
        store.conversationTurns.append(declined)
        let declinedInstruction = store.companionProfileInstruction(for: retiredTurn(store, conversationID: threadID))
        try require(declinedInstruction.contains("ask one question at a time: what may run without asking. The user chose not to name you yet"),
                    "Without a name, setup asks only about permissions: \(declinedInstruction)")
        store.conversationTurns.removeAll { $0.id == declined.id }
        store.adoptAssistantName(previousName)
        store.dotProfile = decoded
        var instructions = [namedInstruction, declinedInstruction, store.companionProfileInstruction(for: retiredTurn(store, conversationID: threadID))]
        for event in [NativeCompanionEvent(kind: .introduction, key: "a"), declinedEvent, NativeCompanionEvent(kind: .welcome, key: "b"),
                      NativeCompanionEvent(kind: .refinement, key: "c"), NativeCompanionEvent(kind: .refinement, key: "d", observation: "The note is ready.")] {
            instructions.append(event.instruction)
        }
        try requireRetiredFree(instructions, "The setup and check-in instructions")

        guard let tool = store.companionProfileTool(for: retiredTurn(store, conversationID: threadID)) else {
            throw NativeTaskFixture.Failure.assertion("The companion thread offers the profile tool")
        }
        try requireRetiredFree([tool.name, tool.title, tool.description, String(describing: tool.parameters)], "The profile tool")
        var refused = false
        do { _ = try NativeCompanionProfileTools.change(["action": .string(retiredWord), "value": .string("Grow tomatoes")]) } catch { refused = true }
        try require(refused, "The profile tool refuses the retired action like an unknown one")
        var validatorRefused = false
        do { try tool.argumentValidator?(["action": .string(retiredWord), "value": .string("Grow tomatoes")]) } catch { validatorRefused = true }
        try require(validatorRefused, "The tool's argument check refuses the retired action")

        store.adoptAssistantName("Wren")
        store.saveDotProfile { $0.connectedToolIDs = [] }
        guard let raw = try await repository.database.read({ db in
            try String.fetchOne(db, sql: "SELECT profile_json FROM native_dot_profile WHERE id = ?", arguments: [NativeDotProfileStore.rowID])
        }) else { throw NativeTaskFixture.Failure.assertion("The profile is stored") }
        try require(try savedValue(Data(raw.utf8)) == retiredText, "Saving again after a rename keeps the saved value exactly")
        store.adoptAssistantName(previousName)

        let fresh = try NativeCompanionTaskPayload(assignment: "Check the seed tray", mode: "manual")
        let freshRequest = try NativeResearchTaskRequest(dot: fresh)
        let freshCreate = NativeTaskCreateRequest(request: freshRequest, idempotencyKey: UUID())
        let freshBody = try freshCreate.encoded()
        let freshPayload = (try JSONSerialization.jsonObject(with: freshBody) as? [String: Any])?["payload"] as? [String: Any] ?? [:]
        try require(freshPayload[retiredWord] == nil && !freshPayload.isEmpty, "A new request never writes the retired key")
        try require(try savedValue(JSONEncoder().encode(fresh)) == nil, "A new payload never writes the retired key")

        let oldBody = Data(try injected(String(decoding: freshBody, as: UTF8.self)).utf8)
        let oldCreate = try JSONDecoder().decode(NativeTaskCreateRequest.self, from: oldBody)
        try require(try oldCreate.encoded() == oldBody, "An old saved request still matches its original body")
        let oldPayloadObject = (try JSONSerialization.jsonObject(with: oldBody) as? [String: Any])?["payload"] as? [String: Any] ?? [:]
        try require(oldPayloadObject[retiredWord] as? String == retiredText && Set(oldPayloadObject.keys).isSubset(of: NativeCompanionTaskPayload.payloadKeys),
                    "An old saved request keeps its value and passes the key check")
        let oldPayload = try JSONDecoder().decode(NativeCompanionTaskPayload.self, from: NativeTaskStore.canonical(oldPayloadObject))
        try require(oldPayload.assignment == "Check the seed tray" && oldPayload != fresh, "An old payload decodes and validates")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let oldRequestJSON = try injected(String(decoding: try encoder.encode(freshRequest), as: UTF8.self))
        let oldRequest = try JSONDecoder().decode(NativeResearchTaskRequest.self, from: Data(oldRequestJSON.utf8))
        try require(String(decoding: try encoder.encode(oldRequest), as: UTF8.self) == oldRequestJSON, "An old saved request round trips unchanged")
        var reference = NativeTaskReference(
            id: UUID(), origin: NativeTaskOrigin(conversationID: threadID, userMessageID: UUID(), assistantMessageID: UUID()),
            engine: try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!), request: oldRequest, createRequest: oldCreate,
            body: oldBody, profile: nil, remoteTaskID: UUID().uuidString, deliveryState: .accepted, cancelRequested: false,
            cancelDelivered: false, lastDeliveryError: nil, snapshot: nil)
        var cardTexts: [String] = []
        for state in ["queued", "running", "blocked", "needs_decision", "failed", "canceled", "completed"] {
            var object: [String: Any] = ["id": reference.remoteTaskID ?? "", "worker_type": "companion", "payload": oldPayloadObject,
                                         "state": state, "checkpoint": [:], "cancel_requested": false, "generation": 1, "updated_at": 1.0]
            if state == "needs_decision" { object["decision"] = ["id": "retry", "prompt": "The step didn't finish. Retry this step?", "choices": ["retry"]] }
            if state == "completed" {
                var result = CompanionSavedTextFixture.result("The tray is watered.", shape: NativeCompanionShape.answer)
                result["query"] = "Check the seed tray"
                object["result"] = result
            }
            reference.snapshot = try JSONDecoder().decode(NativeTaskSnapshot.self, from: NativeTaskClient.canonical(object))
            try require(reference.snapshot?.payload == oldCreate.payload, "The saved request matches its snapshot in state \(state)")
            let card = try NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot).card
            try require(card.canRetry == (state == "needs_decision"), "An old request in state \(state) offers retry only when asked")
            cardTexts += [String(describing: card), card.milestone, card.statusTitle]
            var stopping = reference
            stopping.cancelRequested = true
            if !(reference.snapshot?.state.isTerminal ?? true) {
                cardTexts.append(try NativeTaskProjection.display(reference: stopping, snapshot: stopping.snapshot).card.milestone)
            }
        }
        cardTexts.append(try NativeTaskProjection.display(reference: { var bare = reference; bare.snapshot = nil; return bare }(), snapshot: nil).card.milestone)
        try requireRetiredFree(cardTexts, "Companion work cards")

        var prompts: [String] = []
        for old in [true, false] {
            let harness = try NativeCompanionHarness(rules: [:]) { _ in .text("The tray is watered.") }
            if old {
                _ = try harness.store.create(workerType: "companion", payload: try NativeTaskStore.canonical(oldPayloadObject),
                                             idempotencyKey: UUID().uuidString)
            } else {
                _ = try harness.create("Check the seed tray")
            }
            _ = try await harness.step()
            guard let system = harness.model.allRequests.first?.first(where: { $0.role == "system" })?.content else {
                throw NativeTaskFixture.Failure.assertion("The worker sends a system prompt")
            }
            try require(system.contains("working on one assignment"), "The worker prompt is the companion's own")
            prompts.append(system)
        }
        try requireRetiredFree(prompts, "The worker prompt for old and new requests")

        var summaries: [String] = []
        for messages in [0, 1, 3] {
            for schedules in [0, 1] {
                for services in [false, true] {
                    for artifacts in [0, 2] {
                        var summary = NativeDotRemovalSummary(services: services)
                        summary.messages = messages
                        summary.memories = messages
                        summary.proposals = messages
                        summary.schedules = schedules
                        summary.artifacts = artifacts
                        summaries.append(summary.sentence)
                    }
                }
            }
        }
        summaries.append(store.dotRemovalSummary().sentence)
        try requireRetiredFree(summaries, "Start over")

        var copy = [DotProfileCopy.subtitle, DotProfileCopy.startOver, DotProfileCopy.pausedNote, DotProfileCopy.servicesNote,
                    DotProfileCopy.noServices, DotProfileCopy.rulesNote,
                    CompanionErrorCopy.loadLead, CompanionErrorCopy.loadTail, CompanionErrorCopy.saveLead, CompanionErrorCopy.clearLead,
                    CompanionErrorCopy.threadLead, CompanionErrorCopy.resetLead, CompanionErrorCopy.resetTail,
                    CompanionWorkCopy.describe, CompanionWorkCopy.paused, CompanionWorkCopy.conversation, CompanionWorkCopy.couldNotStart,
                    CompanionOverviewModel.noTaskRules, CompanionOverviewModel.selectWorkHint, CompanionOverviewModel.noActivity,
                    CompanionOverviewModel.noOutputs, CompanionOverviewModel.thisMac, CompanionOverviewModel.stopTitle,
                    CompanionOverviewModel.pauseTitle(name: "Ada", paused: true), CompanionOverviewModel.pauseTitle(name: "Ada", paused: false),
                    NativeDotContext.coordinatorNote, NativeDotContext.clickLine, NativeDotContext.headerSummary(resolver: resolver)]
        copy += copy.map { CompanionSentence.plain($0, name: nil) }
        for invalid in [{ try NativeCompanionTaskPayload(assignment: "Check", mode: "later") },
                        { try NativeCompanionTaskPayload(assignment: " ", mode: "manual") }] as [() throws -> NativeCompanionTaskPayload] {
            do { _ = try invalid() } catch { copy.append(error.localizedDescription) }
        }
        try requireRetiredFree(copy, "Companion copy")
        try await checkRetiredStoredContext()
        try checkCarriedValues()
        print("  companion retired setting OK (old profile and requests load, nothing shows or tells the model about it)")
    }
    private static func oldStoredContext(_ sentence: String) -> String {
        let resolver = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(choices: [.commands: .handOff]), requestText: "")
        let current = NativeDotContext.render(name: "Ada", resolver: resolver).components(separatedBy: "\n")
        let oldCoordinator = current[1].replacingOccurrences(of: "longer work is handed to", with: "work on the " + retiredWord + " is handed to")
        return ([current[0], sentence, oldCoordinator] + current.dropFirst(2)).joined(separator: "\n")
    }

    private static var oldContexts: [String] {
        [oldStoredContext("Your standing " + retiredWord + ": Grow tomatoes on the balcony. Keep this " + retiredWord + " in mind when it is relevant; do not force it into unrelated conversations."),
         oldStoredContext("No standing " + retiredWord + " has been set yet.")]
    }

    private static func checkRetiredStoredContext() async throws {
        let require = NativeTaskFixture.require
        let resolver = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(choices: [.commands: .handOff]), requestText: "")
        let current = NativeDotContext.render(name: "Ada", resolver: resolver)
        for old in oldContexts {
            let cleaned = NativeDotContext.retired(old)
            try requireRetiredFree([cleaned], "A stored context from before")
            try require(cleaned == current, "Only the retired lines change and every rule line stays byte for byte: \(cleaned)")
            let kept = old.components(separatedBy: "\n").filter { !$0.lowercased().contains(retiredWord) }
            try require(kept.allSatisfy { cleaned.components(separatedBy: "\n").contains($0) }, "Every other stored line survives unchanged")
        }
        try require(NativeDotContext.retired("Stored block\nRun commands in shared folders: hand off to the user.")
                    == "Stored block\nRun commands in shared folders: hand off to the user.", "A current stored block is returned unchanged")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("companion-retired-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let first = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: NativeCompanionIntroductionTransport(),
                              repository: try LocalChatRepository(url: url), nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
        await first.connect()
        first.suspendsTurnScheduling = true
        first.openVeraThread()
        guard let threadID = first.veraThreadID, let pending = first.conversationTurns.first(where: { $0.conversationID == threadID }),
              pending.dotContext != nil else { throw NativeTaskFixture.Failure.assertion("A pending companion turn stores its context") }
        first.stopNativeTaskRecovery()
        let repository = try LocalChatRepository(url: url)
        let oldContext = oldContexts[0]
        try await repository.database.write { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT record_json FROM native_conversation_turns WHERE id = ?", arguments: [pending.id.uuidString]),
                  var object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                throw NativeTaskFixture.Failure.assertion("The pending turn is stored")
            }
            object["dotContext"] = oldContext
            let rewritten = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            try db.execute(sql: "UPDATE native_conversation_turns SET record_json = ? WHERE id = ?", arguments: [rewritten, pending.id.uuidString])
        }
        try require(try repository.conversationTurns().first { $0.id == pending.id }?.dotContext == oldContexts[0], "The turn now carries a context from before")
        let transport = NativeCompanionIntroductionTransport()
        let resumed = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport, repository: repository,
                                nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
        await resumed.connect()
        defer { resumed.stopNativeTaskRecovery() }
        resumed.openVeraThread()
        try await NativeSessionFixture.eventually("The saved turn is sent") { !transport.histories.isEmpty }
        guard let system = transport.histories.first?.first(where: { $0.role == "system" })?.content else {
            throw NativeTaskFixture.Failure.assertion("The saved turn sends a system prompt")
        }
        let standing = system.components(separatedBy: "\n\n").filter { $0.hasPrefix("Your standing role") }.joined()
        try require(standing.contains("Run commands in shared folders: hand off to the user.") && standing.contains("You are Ada"),
                    "The saved turn keeps its own rules")
        try requireRetiredFree([standing], "The saved turn's standing context")
        try require(!system.contains("Grow tomatoes on the balcony"), "The saved text never reaches the model")
    }

    private static func checkCarriedValues() throws {
        let require = NativeTaskFixture.require
        func parsed(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
        let values: [Any] = [NSNull(), "", " padded ", 123, 1.5, ["plan": ["beds": 3], "done": false]]
        for value in values {
            let object: [String: Any] = [retiredWord: value, "state": "active", "updated_at": 1_800_000_000.0]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            var profile = try JSONDecoder().decode(NativeDotProfile.self, from: data)
            profile.setupCompleted = true
            let again = try parsed(JSONEncoder().encode(profile))
            try require(again.keys.contains(retiredWord), "The carried key survives a save: \(value)")
            try require(NSDictionary(dictionary: [retiredWord: again[retiredWord] ?? "missing"]).isEqual(to: [retiredWord: value]),
                        "The carried value survives a save exactly: \(value) became \(String(describing: again[retiredWord]))")
            if let text = value as? String { try require(again[retiredWord] as? String == text, "Saved text keeps its exact spacing") }
        }
        let absent = try JSONDecoder().decode(NativeDotProfile.self, from: Data(#"{"state":"active"}"#.utf8))
        try require(try parsed(JSONEncoder().encode(absent))[retiredWord] == nil, "An absent value stays absent")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for carried in [nil, "\"\"", "\"Grow tomatoes on the balcony.\"", "null"] as [String?] {
            let body = "{" + (carried.map { "\"\(retiredWord)\":\($0)," } ?? "") + #""assignment":"Check the seed tray","mode":"manual"}"#
            let sorted = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: Data(body.utf8)), options: [.sortedKeys])
            let payload = try JSONDecoder().decode(NativeCompanionTaskPayload.self, from: sorted)
            let wire = try encoder.encode(NativeResearchTaskPayload(request: try NativeResearchTaskRequest(dot: payload)))
            let expected = #"{"assignment":"Check the seed tray","# + (carried.map { "\"\(retiredWord)\":\($0)," } ?? "") + #""mode":"manual"}"#
            try require(String(decoding: wire, as: UTF8.self) == expected, "A saved request round trips byte for byte: \(String(decoding: wire, as: UTF8.self))")
        }
    }
}
