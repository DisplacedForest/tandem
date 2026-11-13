import Combine
import Foundation

@MainActor
extension SelfTest {
    static func runScheduleWithoutKinds() async throws {
        let require = NativeTaskFixture.require
        try await scheduleWithoutKindsStore(require)
        try scheduleWithoutKindsTool(require)
        try await scheduleWithoutKindsAdvertised(require)
        try await scheduleWithoutKindsLoop(require)
        try await scheduleWithoutKindsQuestion(require)
        try scheduleWithoutKindsCheckInPlace(require)
        try await scheduleWithoutKindsSearchNote(require)
        try scheduleWithoutKindsCard(require)
        try await scheduleWithoutKindsWords(require)
        try scheduleWithoutKindsPanels(require)
        try scheduleWithoutKindsRunWords(require)
        try await scheduleWithoutKindsProfileAside(require)
        try scheduleWithoutKindsLibrary(require)
        try scheduleWithoutKindsDelivered(require)
        try scheduleWithoutKindsCurrentLine(require)
        try await scheduleWithoutKindsDeletedChat(require)
        print("  schedule without kinds OK (new schedules are the companion's with either destination, reload, edit keeps kind, old research and document load, fire and edit as before, own chat and companion runs start in the chosen chat without search, pause skips and notes both, profile and companion lists, start over counts and removes both and keeps the chat, tool has no kind field, results default per conversation, real loop allow decline and unreadable in both conversations, own chat question posts and is answered in the companion's conversation and the result lands in its own chat, old research question stays in its chat, no search line and reasons, the loaded question card updates where it was answered, card lines, words, profile and work panels, runs of older schedules read as plain work while chat work reads as before, old saved cards decode, own chat run in the profile with put aside and pick back up, the companion's documents in the Library and profile and not the next companion's after start over, delivered results open plainly, the current work line, a deleted own chat takes its question card with it)")
    }

    private static func scheduleWithoutKindsStore(_ require: (Bool, String) throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("chat.sqlite"))
        let config = NativeChatConfig(baseURL: URL(string: "https://fixture.invalid/v1")!, apiKey: nil, model: "fixture", chatTemplateKwargs: nil)
        let store = ChatStore(nativeConfig: config, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                              nativeSearchAvailable: { false }, artifactPersistenceEnabled: false)
        await store.connect()
        defer { store.stopNativeTaskRecovery() }
        guard let scheduleStore = store.nativeScheduleStore else { throw NativeTaskFixture.Failure.assertion("The store keeps schedules") }

        func draft(_ title: String, _ owner: NativeScheduleOwner) -> NativeScheduleDraft {
            var draft = NativeScheduleDraft()
            draft.title = title
            draft.instruction = "Check my calendar and the weather."
            draft.owner = owner
            draft.cadence = .weekdays(minuteOfDay: 7 * 60)
            return draft
        }
        try require(NativeScheduleDraft().workerType == NativeSchedule.companionWorkerType, "A new schedule is carried out by the companion")
        guard let own = store.createSchedule(draft("Morning summary", .conversation)),
              let shared = store.createSchedule(draft("Evening summary", .dot)) else {
            throw NativeTaskFixture.Failure.assertion("New schedules save: \(store.scheduleError ?? "")")
        }
        try require(own.isCompanionWork && own.owner == .conversation && own.runsAsCompanion
                    && shared.isCompanionWork && shared.owner == .dot && shared.runsAsCompanion,
                    "A new schedule is the companion's and keeps where its results go")
        let reloaded = try scheduleStore.all()
        try require(reloaded.contains { $0.id == own.id && $0.isCompanionWork && $0.owner == .conversation }
                    && reloaded.contains { $0.id == shared.id && $0.isCompanionWork && $0.owner == .dot }, "Both reload as saved")
        var renamed = draft("Morning summary, short", .conversation)
        renamed.workerType = own.workerType
        store.updateSchedule(own.id, with: renamed)
        let afterEdit = try scheduleStore.get(own.id)
        try require(afterEdit?.title == "Morning summary, short" && afterEdit?.isCompanionWork == true && afterEdit?.owner == .conversation,
                    "Editing keeps it the companion's and its own chat")

        let zone = TimeZone(identifier: "UTC")!
        var research = try NativeSchedule(owner: .conversation, conversationID: "old-research-chat", workerType: "research", title: "Frost check",
                                          instruction: "Check the frost forecast.", cadence: .daily(minuteOfDay: 6 * 60), timeZone: zone)
        research.advance(after: Date(), from: nil)
        var document = try NativeSchedule(owner: .conversation, conversationID: "old-document-chat", workerType: "document", title: "Weekly note",
                                          instruction: "Write the weekly greenhouse note.", cadence: .weekly(weekday: 2, minuteOfDay: 9 * 60), timeZone: zone)
        document.advance(after: Date(), from: nil)
        try scheduleStore.save(research)
        try scheduleStore.save(document)
        store.reloadSchedules()
        guard let oldResearch = store.schedules.first(where: { $0.id == research.id }),
              let oldDocument = store.schedules.first(where: { $0.id == document.id }) else {
            throw NativeTaskFixture.Failure.assertion("Older schedules load")
        }
        try require(oldResearch.workerType == "research" && oldDocument.workerType == "document"
                    && !oldResearch.runsAsCompanion && !oldDocument.runsAsCompanion, "Older schedules keep their stored kind")
        let shapes = [try oldResearch.taskRequest().workerType, try oldDocument.taskRequest().workerType, try own.taskRequest().workerType]
        try require(shapes == ["research", "document", NativeSchedule.companionWorkerType], "Each starts through its own routine")
        var keptDraft = NativeScheduleDraft(oldDocument)
        keptDraft.title = "Weekly note, edited"
        store.updateSchedule(oldDocument.id, with: keptDraft)
        let keptDocument = try scheduleStore.get(oldDocument.id)
        try require(keptDocument?.workerType == "document" && keptDocument?.owner == .conversation && keptDocument?.conversationID == "old-document-chat",
                    "Editing an older schedule keeps its kind and its chat")

        func probe(_ schedule: NativeSchedule) -> NativeScheduleRun {
            NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), outcome: .running)
        }
        let researchFired = await store.fireSchedule(oldResearch, run: probe(oldResearch), bind: { _, _ in })
        try require(researchFired == .failed("Search isn't set up. Add a search URL in Settings."), "Older research still needs search: \(researchFired)")
        guard case .started = await store.fireSchedule(oldDocument, run: probe(oldDocument), bind: { _, _ in }) else {
            throw NativeTaskFixture.Failure.assertion("An older document starts without search")
        }
        guard let ownLive = try scheduleStore.get(own.id) else { throw NativeTaskFixture.Failure.assertion("The schedule exists") }
        guard case .started(let ownText) = await store.fireSchedule(ownLive, run: probe(ownLive), bind: { _, _ in }),
              let ownReference = try repository.taskReference(id: UUID(uuidString: ownText) ?? UUID()) else {
            throw NativeTaskFixture.Failure.assertion("A companion schedule with its own chat starts without search")
        }
        guard case .started(let sharedText) = await store.fireSchedule(shared, run: probe(shared), bind: { _, _ in }),
              let sharedReference = try repository.taskReference(id: UUID(uuidString: sharedText) ?? UUID()) else {
            throw NativeTaskFixture.Failure.assertion("A companion schedule for the companion's conversation starts without search")
        }
        let ownChat = try scheduleStore.get(own.id)?.conversationID
        try require(store.veraThreadID != nil && ownChat != nil && ownReference.origin.conversationID == ownChat
                    && !store.isVeraThread(ownReference.origin.conversationID) && ownReference.request.workerType == NativeSchedule.companionWorkerType,
                    "Its run starts in its own chat, as the companion's work, and the companion's conversation exists")
        try require(store.isVeraThread(sharedReference.origin.conversationID), "A schedule for the companion starts in the companion's conversation")

        let run = NativeScheduleRun(scheduleID: own.id, scheduledFor: Date(), startedAt: Date(), outcome: .running,
                                    conversationID: ownReference.origin.conversationID,
                                    messageID: ownReference.origin.assistantMessageID.uuidString, taskReferenceID: ownReference.id.uuidString)
        try scheduleStore.saveRun(run)
        store.reloadSchedules()
        store.reloadNativeTaskReferences()
        let overview = store.companionOverviewModel()
        try require(overview.activity.contains { $0.source == .task(ownReference.id) } && !overview.activity.contains { $0.id == "run:" + run.id } && overview.upcoming.contains { $0.id == own.id }
                    && overview.upcoming.contains { $0.id == shared.id } && !overview.upcoming.contains { $0.id == oldResearch.id },
                    "The profile lists the own chat schedule's run and both companion schedules, not the older research one")
        try require(store.switchCompanionSchedule(own.id, on: true) == nil, "The profile's switch covers it")

        store.setDotState(.paused)
        for schedule in [ownLive, shared] {
            let paused = await store.fireSchedule(schedule, run: probe(schedule), bind: { _, _ in })
            try require(paused == .skipped(CompanionSavedText.marker + " is paused."), "A paused companion skips \(schedule.title): \(paused)")
            try require(NativeScheduleControls.pausedNote(schedule, assistantPaused: true).map { CompanionSentence.plain($0, name: "Ada") } == "Paused with Ada",
                        "\(schedule.title) says it's paused with the companion")
        }
        try require(NativeScheduleControls.pausedNote(oldResearch, assistantPaused: true) == nil, "An older own chat schedule ignores the pause")
        store.setDotState(.active)

        let summary = store.dotRemovalSummary()
        try require(summary.schedules == 2, "Start over counts both of the companion's schedules: \(summary.schedules)")
        try require(store.resetDot(), "Start over completes")
        let left = try scheduleStore.all().map(\.id)
        try require(!left.contains(own.id) && !left.contains(shared.id) && left.contains(oldResearch.id) && left.contains(oldDocument.id),
                    "Start over removes the companion's schedules and keeps the older ones")
        try require(try repository.listConversations().contains { $0.id == ownChat }, "The schedule's own chat stays")
    }

    private static func scheduleWithoutKindsTool(_ require: (Bool, String) throws -> Void) throws {
        let zone = TimeZone(identifier: "America/Chicago")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let definition = NativeScheduleTools.definition(now: { now }, timeZone: { zone }, save: { _ in throw NativeToolError.unavailable })
        guard case .object(let root) = definition.parameters, case .object(let properties)? = root["properties"],
              case .array(let required)? = root["required"] else {
            throw NativeTaskFixture.Failure.assertion("The tool has parameters")
        }
        try require(properties["worker_type"] == nil && !required.contains(.string("worker_type")) && !NativeScheduleTools.argumentNames.contains("worker_type"),
                    "The tool has no kind field")
        try require(required == [.string("title"), .string("instruction"), .string("repeat")], "Title, instruction and repeat are required")
        try require(definition.description == NativeScheduleTools.description && !definition.description.contains("worker_type"),
                    "The description names no kind")
        let values: [String: NativeJSONValue] = ["title": .string("Morning summary"), "instruction": .string("Check my calendar."),
                                                 "repeat": .string("weekdays"), "time": .string("07:00")]
        var withKind = values
        withKind["worker_type"] = .string("research")
        try require((try? definition.refusesBeforeAsking?(withKind)) == nil, "A call carrying a kind is refused before asking")
        for companionThread in [false, true] {
            let unset = try NativeScheduleTools.draft(from: values, now: now, timeZone: zone, companionThread: companionThread)
            try require(unset.owner == (companionThread ? .dot : .conversation) && unset.workerType == NativeSchedule.companionWorkerType,
                        "Without results_to the companion's conversation goes to the companion and any other chat to its own chat")
            for (wire, owner) in [("assistant", NativeScheduleOwner.dot), ("own_chat", .conversation)] {
                var explicit = values
                explicit["results_to"] = .string(wire)
                try require(try NativeScheduleTools.draft(from: explicit, now: now, timeZone: zone, companionThread: companionThread).owner == owner,
                            "results_to \(wire) is honoured everywhere")
            }
        }
    }

    private static func scheduleWithoutKindsAdvertised(_ require: (Bool, String) throws -> Void) async throws {
        let ask = "Every weekday at 7 research lunar ice news."
        let harness = try CompanionAskedWorkFixture.harness { _, _, _ in CompanionAskedWorkTransport.say("Done.") }
        defer { harness.store.conversationTurnLoop?.cancel() }
        harness.store.nativeScheduleStore = NativeScheduleStore(database: harness.repository.database)
        func offered() -> NativeToolSchema? {
            harness.transport.records.last { $0.user == ask }?.tools.first { $0.name == NativeScheduleTools.toolName }
        }
        func properties(_ schema: NativeToolSchema?) -> [String: NativeJSONValue] {
            guard case .object(let root)? = schema?.parameters, case .object(let properties)? = root["properties"] else { return [:] }
            return properties
        }
        _ = try await CompanionAskedWorkFixture.send(harness, ask)
        let inThread = offered()
        harness.store.newConversation()
        guard let focused = harness.store.selectedID, focused != harness.threadID else { throw NativeTaskFixture.Failure.assertion("A focused chat opens") }
        _ = try await CompanionAskedWorkFixture.send(harness, ask, conversationID: focused)
        let inChat = offered()
        try require(inThread != nil && inChat != nil && properties(inThread)["worker_type"] == nil && properties(inChat)["worker_type"] == nil
                    && inThread?.description == NativeScheduleTools.description && inChat?.description == NativeScheduleTools.description,
                    "Both conversations are offered the same tool with no kind field")
    }

    private static func scheduleWithoutKindsLoop(_ require: (Bool, String) throws -> Void) async throws {
        let ask = "Every weekday at 7 research lunar ice news."
        let calls = ScheduleWithoutKindsCalls()
        let harness = try CompanionAskedWorkFixture.harness { _, messages, _ in
            if CompanionAskedWorkTransport.answered(messages) { return CompanionAskedWorkTransport.say("Done.") }
            return CompanionAskedWorkTransport.hand([CompanionAskedWorkTransport.call(NativeScheduleTools.toolName, calls.next())])
        }
        defer { harness.store.conversationTurnLoop?.cancel() }
        let scheduleStore = NativeScheduleStore(database: harness.repository.database)
        harness.store.nativeScheduleStore = scheduleStore
        let raised = ScheduleWithoutKindsCards()
        let watch = harness.store.$pendingToolConfirmation.sink { if $0 != nil { raised.add() } }
        defer { watch.cancel() }
        harness.store.newConversation()
        guard let focused = harness.store.selectedID, focused != harness.threadID else { throw NativeTaskFixture.Failure.assertion("A focused chat opens") }

        func arguments(repeatKind: String = "weekdays", kind: String? = nil) -> [String: NativeJSONValue] {
            var values: [String: NativeJSONValue] = ["title": .string("Morning summary"), "instruction": .string("Check my calendar and the weather."),
                                                     "repeat": .string(repeatKind), "time": .string("07:00")]
            if let kind { values["worker_type"] = .string(kind) }
            return values
        }
        func toolReply(_ text: String) -> String {
            harness.transport.records.filter { $0.user == text }.last?.messages.last { $0.role == "tool" }?.content ?? ""
        }
        func turn(_ label: String, in conversationID: String, _ values: [String: NativeJSONValue], decide: Bool?) async throws {
            calls.set(values)
            let text = ask + " " + label
            let before = raised.count
            try require(harness.store.sendText(text, conversationID: conversationID, fromComposer: true), "The message is accepted: \(label)")
            if let decide {
                try await NativeSessionFixture.eventually("A card is raised: \(label)") { harness.store.pendingToolConfirmation != nil }
                try require(harness.store.pendingToolConfirmation?.toolID == NativeScheduleTools.toolID, "The card is for the schedule: \(label)")
                harness.store.resolveToolConfirmation(decide)
            }
            try await NativeSessionFixture.eventually("The reply completes: \(label)") {
                let saved = (try? harness.repository.messages(conversationID: conversationID)) ?? []
                guard let index = saved.lastIndex(where: { $0.role == .user && $0.text == text }), saved.indices.contains(index + 1),
                      saved[index + 1].state == .complete,
                      !harness.store.conversationTurns.contains(where: { $0.conversationID == conversationID && ($0.state == .pending || $0.state == .running) })
                else { return false }
                return true
            }
            try require(raised.count == before + (decide == nil ? 0 : 1), "\(decide == nil ? "No card" : "One card") is raised: \(label)")
        }

        for (place, conversationID, owner) in [("ordinary", focused, NativeScheduleOwner.conversation), ("companion", harness.threadID, .dot)] {
            let before = try scheduleStore.all().count
            try await turn(place + " decline", in: conversationID, arguments(), decide: false)
            try require(try scheduleStore.all().count == before, "Declining in the \(place) conversation saves nothing")
            try await turn(place + " allow", in: conversationID, arguments(), decide: true)
            let saved = try scheduleStore.all()
            try require(saved.count == before + 1 && saved.last?.isCompanionWork == true && saved.last?.owner == owner,
                        "Allow in the \(place) conversation saves the companion's schedule with results to \(owner)")
            try await turn(place + " weekly", in: conversationID, arguments(repeatKind: "weekly"), decide: nil)
            try require(toolReply(ask + " " + place + " weekly").contains("A weekly schedule needs a weekday.") && (try scheduleStore.all()).count == before + 1,
                        "An unreadable request in the \(place) conversation is refused before asking with its reason")
            try await turn(place + " kind", in: conversationID, arguments(kind: "research"), decide: nil)
            try require((try scheduleStore.all()).count == before + 1, "A call carrying a kind in the \(place) conversation is refused before asking")
        }
    }

    private static func scheduleWithoutKindsQuestion(_ require: (Bool, String) throws -> Void) async throws {
        let harness = try await CompanionTalkControlFixture.harness { _, _, _ in CompanionAskedWorkTransport.say("Fine.") }
        defer { Task { await CompanionTalkControlFixture.finish(harness) } }
        let store = harness.store
        let scheduleStore = NativeScheduleStore(database: harness.repository.database)
        store.nativeScheduleStore = scheduleStore
        var draft = NativeScheduleDraft()
        draft.title = "Vent check"
        draft.instruction = CompanionTalkControlFixture.askRetry
        draft.owner = .conversation
        guard let schedule = store.createSchedule(draft) else { throw NativeTaskFixture.Failure.assertion("The schedule saves") }
        guard case .started(let text) = await store.fireSchedule(schedule, run: NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), outcome: .running),
                                                                 bind: { _, _ in }),
              let referenceID = UUID(uuidString: text), let reference = try harness.repository.taskReference(id: referenceID),
              let ownChat = try scheduleStore.get(schedule.id)?.conversationID else {
            throw NativeTaskFixture.Failure.assertion("The schedule's run starts")
        }
        try require(reference.origin.conversationID == ownChat && ownChat != harness.threadID, "The run starts in the schedule's own chat")
        var run = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), startedAt: Date(), outcome: .running, conversationID: ownChat,
                                    messageID: reference.origin.assistantMessageID.uuidString, taskReferenceID: reference.id.uuidString)
        try scheduleStore.saveRun(run)
        store.reloadSchedules()
        store.reloadNativeTaskReferences()
        try await CompanionTalkControlFixture.settle(harness, reference, .waiting)
        try require(store.companionTalkEntries(now: Date()).contains { $0.referenceID == reference.id },
                    "The companion's conversation lists the run as its work, so it can be stopped or put aside by asking")
        run.outcome = .waiting
        try scheduleStore.saveRun(run)
        store.reloadSchedules()
        let ownBefore = try harness.repository.messages(conversationID: ownChat).count
        store.select(harness.threadID)
        store.postScheduleCheckIns()
        let posted = try harness.repository.messages(conversationID: harness.threadID).last
        func loadedCard() -> NativeTaskCardPresentation? {
            store.conversations.first { $0.id == harness.threadID }?.messages.first { $0.id == posted?.id }?.displayBlocks.compactMap { block in
                if case .taskCard(let card) = block, card.id == reference.id.uuidString { return card }
                return nil
            }.first
        }
        try require(loadedCard()?.status == .needsInput, "The loaded companion conversation shows the question")
        try require(posted?.text.hasPrefix("The scheduled \"Vent check\" stopped to ask: ") == true
                    && posted?.displayBlocks.contains { if case .taskCard(let card) = $0 { card.id == reference.id.uuidString } else { false } } == true,
                    "The question is posted with its card in the companion's conversation: \(posted?.text ?? "")")
        try require(try harness.repository.messages(conversationID: ownChat).count == ownBefore, "Nothing is posted in its own chat")
        store.answerNativeTask(reference.id.uuidString, choice: "retry")
        try await CompanionTalkControlFixture.eventually("The answer reaches the run and it finishes") {
            (try? CompanionTalkControlFixture.engineRecord(harness, reference))??.state == .completed
        }
        try await CompanionTalkControlFixture.eventually("The loaded card in the companion's conversation stops asking without a reload") {
            let saved = ((try? harness.repository.messages(conversationID: harness.threadID)) ?? []).first { $0.id == posted?.id }?.displayBlocks
            let loaded = store.conversations.first { $0.id == harness.threadID }?.messages.first { $0.id == posted?.id }?.displayBlocks
            return loaded != nil && loaded == saved && loadedCard()?.status != .needsInput
        }
        try await CompanionTalkControlFixture.eventually("The result lands in the schedule's own chat") {
            ((try? harness.repository.messages(conversationID: ownChat)) ?? []).contains { $0.delivery?.referenceID == reference.id.uuidString }
        }
        try require(!(try harness.repository.messages(conversationID: harness.threadID)).contains { $0.delivery?.referenceID == reference.id.uuidString },
                    "Nothing from the result lands in the companion's conversation")
    }

    private static func scheduleWithoutKindsCheckInPlace(_ require: (Bool, String) throws -> Void) throws {
        func checkIn(workerType: String) throws -> (thread: String?, origin: String, threadText: String?, originText: String?) {
            let repository = try LocalChatRepository(inMemory: true)
            let engine = try NativeTaskEngineIdentity(CardShot.engineURL)
            let origin = try NativeTaskFixture.origin(repository)
            let request = try NativeResearchTaskRequest(objective: "Bed check", deliverables: workerType == "companion" ? [] : ["A short summary"],
                                                        workerType: workerType)
            let reference = try repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: nil)
            var object = (try JSONSerialization.jsonObject(with: NativeTaskFixture.snapshot(reference, id: UUID().uuidString, state: "needs_decision"))) as? [String: Any] ?? [:]
            object["worker_type"] = workerType
            object["decision"] = ["id": "bed-question", "prompt": "Which bed?", "choices": ["retry"]]
            let waiting = try JSONDecoder().decode(NativeTaskSnapshot.self, from: NativeTaskClient.canonical(object))
            _ = try repository.acknowledgeTaskReference(id: reference.id, snapshot: waiting)
            _ = try repository.projectTask(id: reference.id, snapshot: waiting)
            let scheduleStore = NativeScheduleStore(database: repository.database)
            var schedule = try NativeSchedule(owner: .conversation, conversationID: origin.conversationID, workerType: workerType, title: "Bed check",
                                              instruction: "Check the beds.", cadence: .everyHours(6), timeZone: TimeZone(identifier: "UTC")!)
            schedule.advance(after: Date(), from: nil)
            try scheduleStore.save(schedule)
            try scheduleStore.saveRun(NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), startedAt: Date(), outcome: .waiting,
                                                        detail: "Which bed?", conversationID: origin.conversationID,
                                                        messageID: origin.assistantMessageID.uuidString, taskReferenceID: reference.id.uuidString))
            let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
            store.loadDotProfile()
            store.skipDotSetup()
            store.ensureVeraThread()
            store.nativeScheduleStore = scheduleStore
            store.reloadSchedules()
            let threadBefore = try store.veraThreadID.map { try repository.messages(conversationID: $0).count } ?? 0
            let originBefore = try repository.messages(conversationID: origin.conversationID).count
            store.postScheduleCheckIns()
            let threadMessages = try store.veraThreadID.map { try repository.messages(conversationID: $0) } ?? []
            let originMessages = try repository.messages(conversationID: origin.conversationID)
            return (threadMessages.count > threadBefore ? threadMessages.last?.text : nil, origin.conversationID,
                    threadMessages.count > threadBefore ? threadMessages.last?.text : nil,
                    originMessages.count > originBefore ? originMessages.last?.text : nil)
        }
        let research = try checkIn(workerType: "research")
        try require(research.threadText == nil && research.originText == "The scheduled \"Bed check\" stopped to ask: Which bed?",
                    "An older research schedule's question still posts in its own chat: \(research)")
        let companion = try checkIn(workerType: NativeSchedule.companionWorkerType)
        try require(companion.originText == nil && companion.threadText?.hasPrefix("The scheduled \"Bed check\" stopped to ask: ") == true,
                    "A companion run's question from its own chat posts in the companion's conversation: \(companion)")
    }

    private static func scheduleWithoutKindsSearchNote(_ require: (Bool, String) throws -> Void) async throws {
        func context(base: URL?, enabled: Set<String>) throws -> NativeCompanionWorkerContext? {
            let repository = try LocalChatRepository(inMemory: true)
            let registry = NativeToolRegistry(definitions: NativeWebTools.definitions(searchBase: { base }))
            let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                                  nativeEnabledToolIDs: enabled, nativeToolRegistry: registry, nativeSearchAvailable: { base != nil },
                                  artifactPersistenceEnabled: false)
            store.loadDotProfile()
            store.skipDotSetup()
            store.ensureVeraThread()
            return store.companionWorkerContext(connectedToolIDs: nil)
        }
        let base = URL(string: "https://search.test")!
        let noURL = try context(base: nil, enabled: [NativeWebTools.searchToolID])
        let notOn = try context(base: base, enabled: [])
        let offered = try context(base: base, enabled: [NativeWebTools.searchToolID])
        try require(noURL?.searchNote == NativeCompanionWorkerContext.noSearchURL, "Without a search URL the companion is told that reason")
        try require(notOn?.searchNote == NativeCompanionWorkerContext.searchNotOn, "With search turned off the companion is told that reason")
        try require(offered != nil && offered?.searchNote == nil && offered?.tools.contains { $0.id == NativeWebTools.searchToolID } == true,
                    "With search offered there is no note")

        func systemPrompt(_ note: String?) async throws -> String {
            var harness = try NativeCompanionHarness(rules: [:]) { _ in NativeCompanionScriptedModel.text("The beds look fine.") }
            let thread = harness.thread
            let tools = NativeCompanionHarness.tools(harness.service, reconcile: false)
            harness.environment.context = { _, _ in
                var context = NativeCompanionWorkerContext(assistantName: "Ada", threadID: thread.current, tools: tools)
                context.searchNote = note
                return context
            }
            _ = try harness.create("Check the beds", mode: "scheduled")
            _ = try await harness.runUntilSettled()
            return harness.model.allRequests.compactMap { $0.first }.first { $0.role == "system" && $0.content.hasPrefix("You are Ada") }?.content ?? ""
        }
        let plain = try await systemPrompt(nil)
        let noted = try await systemPrompt(NativeCompanionWorkerContext.noSearchURL)
        try require(!plain.isEmpty && !plain.contains("search the web in this run") && noted.contains(NativeCompanionWorkerContext.noSearchURL)
                    && noted.replacingOccurrences(of: "\n\n" + NativeCompanionWorkerContext.noSearchURL, with: "") == plain,
                    "The prompt gains exactly the one line when search isn't offered and is otherwise unchanged")
        let banned = Set(CompanionTalkControlFixture.banned + CompanionTalkControlFixture.pronouns)
        for line in [NativeCompanionWorkerContext.noSearchURL, NativeCompanionWorkerContext.searchNotOn] {
            let words = line.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            try require(!words.contains { banned.contains($0) }, "The search line stays plain: \(line)")
        }
    }

    private static func scheduleWithoutKindsCard(_ require: (Bool, String) throws -> Void) throws {
        func card(_ resultsTo: String?) -> NativeToolConfirmationRequest {
            let tail = resultsTo.map { ",\"results_to\":\"\($0)\"" } ?? ""
            let request = "{\"title\":\"Morning summary\",\"instruction\":\"Check my calendar and the weather.\"\(tail),\"repeat\":\"weekdays\",\"time\":\"07:00\"}"
            return NativeToolConfirmationRequest(activity: NativeToolActivity(id: "summary", toolID: NativeScheduleTools.toolID, name: NativeScheduleTools.toolName,
                title: "Schedule work", round: 1, request: request, result: nil, state: .pending, confirmationRequired: true))
        }
        let placeholder = CompanionSentence.placeholder
        let block = NativeToolConfirmationBar.literal(for: card(nil), companionThread: true) ?? ""
        try require(block.hasPrefix("Morning summary, weekdays at") && block.hasSuffix("Check my calendar and the weather."),
                    "The card shows the name, cadence and what it will do: \(block)")
        try require(NativeToolConfirmationBar.closingLine(for: card(nil), actor: placeholder, companionThread: true)?.plain(name: "Ada") == "Results go to Ada."
                    && NativeToolConfirmationBar.closingLine(for: card("own_chat"), actor: placeholder, companionThread: true)?.plain(name: "Ada")
                        == "Results go to its own chat."
                    && NativeToolConfirmationBar.closingLine(for: card(nil), actor: "Tandem")?.plain(name: "Ada") == "Results go to its own chat.",
                    "The card says where results go, with the conversation's default when unset")
        let kinded = NativeToolConfirmationRequest(activity: NativeToolActivity(id: "kinded", toolID: NativeScheduleTools.toolID, name: NativeScheduleTools.toolName,
            title: "Schedule work", round: 1, request: "{\"title\":\"x\",\"worker_type\":\"research\",\"instruction\":\"y\",\"repeat\":\"daily\",\"time\":\"07:00\"}",
            result: nil, state: .pending, confirmationRequired: true))
        try require(NativeToolConfirmationBar.literal(for: kinded, companionThread: true) == nil, "A request the app can't read shows no raw fields")
        try require(CompanionLine.named(ScheduledView.emptyMessage).plain(name: nil)
                        == "Set up something for your companion to do every day, on weekdays, weekly, every few hours, or once."
                    && CompanionLine.named(ScheduledView.emptyMessage).plain(name: "Ada")
                        == "Set up something for Ada to do every day, on weekdays, weekly, every few hours, or once.",
                    "The empty state names the companion")
        try require(ScheduleEditor.instructionLabel == "What to do", "The editor asks what to do")
    }

    private static func scheduleWithoutKindsWords(_ require: (Bool, String) throws -> Void) async throws {
        let zone = TimeZone(identifier: "UTC")!
        let schedules = [
            try NativeSchedule(owner: .conversation, workerType: "research", title: "Frost check", instruction: "Check the frost.",
                               cadence: .daily(minuteOfDay: 420), timeZone: zone),
            try NativeSchedule(owner: .dot, workerType: "document", title: "Weekly note", instruction: "Note the week.",
                               cadence: .weekly(weekday: 2, minuteOfDay: 540), timeZone: zone),
            try NativeSchedule(owner: .conversation, workerType: NativeSchedule.companionWorkerType, title: "Morning summary",
                               instruction: "Check my calendar.", cadence: .weekdays(minuteOfDay: 420), timeZone: zone),
        ]
        var shown = [CompanionLine.named(ScheduledView.emptyMessage).plain(name: nil), ScheduleEditor.instructionLabel]
        for schedule in schedules {
            shown.append(NativeScheduleControls.resultsLine("\(schedule.cadenceSummary). ", toCompanion: schedule.owner == .dot).plain(name: nil))
            shown.append(NativeScheduleControls.resultsLine(schedule.detailLead, toCompanion: schedule.owner == .dot, end: ".").plain(name: nil))
            shown.append(schedule.checkInSentence("Which one?"))
        }
        var draft = NativeScheduleDraft()
        for owner in [NativeScheduleOwner.dot, .conversation] {
            draft.owner = owner
            shown.append(CompanionSentence.plain(NativeScheduleTools.destination(for: draft), name: nil))
            let save: @Sendable (NativeScheduleDraft) async throws -> NativeSchedule = { saved in
                try NativeSchedule(owner: saved.owner, workerType: saved.workerType, title: saved.title, instruction: saved.instruction,
                                   cadence: saved.cadence, timeZone: zone)
            }
            let result = try await NativeScheduleTools.definition(timeZone: { zone }, save: save).execute([
                "title": .string("Morning summary"), "instruction": .string("Check my calendar."), "repeat": .string("daily"), "time": .string("07:00"),
                "results_to": .string(owner == .dot ? "assistant" : "own_chat")])
            if case .object(let fields) = result, case .string(let message)? = fields["message"] { shown.append(message) }
        }
        try require(shown.count == 2 + 9 + 4, "Every line was gathered")
        let banned = Set(CompanionTalkControlFixture.banned + CompanionTalkControlFixture.pronouns + ["research", "document", "writing"])
        for text in shown {
            let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            try require(!words.contains { banned.contains($0) } && !text.contains("\u{2014}"), "Schedule wording names no kind: \(text)")
        }
    }

    private static func scheduleWithoutKindsPanels(_ require: (Bool, String) throws -> Void) throws {
        let reference = OngoingWorkFixture.store().nativeTaskReferences.last!
        let statuses: [NativeTaskCardPresentation.Status] = [.preparing, .queued, .working, .stopping, .stopped, .completed, .needsInput,
                                                             .failed, .setAside, .newer]
        for status in statuses {
            let card = NativeTaskCardPresentation(id: reference.id.uuidString, title: "Morning summary", status: status, milestone: "",
                                                  workerType: NativeSchedule.companionWorkerType)
            let profile = CompanionOverviewModel.taskItem(card: card, reference: reference, decision: nil, hasArtifact: false, date: Date()).state
            let panel = OngoingWork.presentation(status: status, document: false, hasArtifact: false, title: card.statusTitle).state
            for shown in [profile, panel] {
                try require(shown == card.statusTitle && !shown.lowercased().contains("research") && !shown.lowercased().contains("writing"),
                            "The companion's work never reads as research while \(status.rawValue): \(shown)")
            }
            var research = card
            research.workerType = "research"
            var document = card
            document.workerType = "document"
            try require(CompanionOverviewModel.taskItem(card: research, reference: reference, decision: nil, hasArtifact: false, date: Date()).state
                            == status.title(document: false)
                        && CompanionOverviewModel.taskItem(card: document, reference: reference, decision: nil, hasArtifact: false, date: Date()).state
                            == status.title(document: true)
                        && OngoingWork.presentation(status: status, document: false, hasArtifact: false, title: research.statusTitle).state
                            == OngoingWork.presentation(status: status, document: false, hasArtifact: false).state
                        && OngoingWork.presentation(status: status, document: true, hasArtifact: false, title: document.statusTitle).state
                            == OngoingWork.presentation(status: status, document: true, hasArtifact: false).state,
                        "Research and documents read as before while \(status.rawValue)")
        }
        let ready = NativeTaskCardPresentation(id: reference.id.uuidString, title: "Morning summary", status: .completed, milestone: "",
                                               workerType: NativeSchedule.companionWorkerType)
        try require(CompanionOverviewModel.taskItem(card: ready, reference: reference, decision: nil, hasArtifact: true, date: Date()).state == "Ready to open",
                    "Finished work with a document still reads as ready to open")
    }

    private static func scheduleWithoutKindsSnapshot(_ reference: NativeTaskReference, remote: String, workerType: String, state: String,
                                                     canceled: Bool = false, checkpoint: [String: Any]? = nil,
                                                     result: [String: Any]? = nil) throws -> NativeTaskSnapshot {
        var object = (try JSONSerialization.jsonObject(with: NativeTaskFixture.snapshot(reference, id: remote, state: state, canceled: canceled))) as? [String: Any] ?? [:]
        object["worker_type"] = workerType
        if let checkpoint { object["checkpoint"] = checkpoint }
        if let result { object["result"] = result }
        return try JSONDecoder().decode(NativeTaskSnapshot.self, from: NativeTaskClient.canonical(object))
    }

    private static func scheduleWithoutKindsRunWords(_ require: (Bool, String) throws -> Void) throws {
        let kindWords: Set<String> = ["research", "researching", "document", "documents", "writing", "write", "written"]
        func plain(_ text: String) -> Bool {
            !text.lowercased().components(separatedBy: CharacterSet.letters.inverted).contains { kindWords.contains($0) }
        }
        for workerType in ["research", "document"] {
            for scheduled in [true, false] {
                let repository = try LocalChatRepository(inMemory: true)
                let engine = try NativeTaskEngineIdentity(CardShot.engineURL)
                let origin = try NativeTaskFixture.origin(repository)
                let request = try NativeResearchTaskRequest(objective: "Check the frost forecast", deliverables: ["A short summary"], workerType: workerType,
                                                            scheduleID: scheduled ? UUID().uuidString.lowercased() : nil)
                let prepared = try repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: nil)
                let remote = UUID().uuidString
                _ = try repository.acknowledgeTaskReference(id: prepared.id, snapshot: try scheduleWithoutKindsSnapshot(prepared, remote: remote, workerType: workerType, state: "queued"))
                guard let reference = try repository.taskReference(id: prepared.id) else { throw NativeTaskFixture.Failure.assertion("The reference binds") }
                let result: [String: Any] = workerType == "document"
                    ? ["kind": "document_report", "query": request.objective, "report": "# Frost\n\nNo frost tonight.", "sources": []]
                    : ["kind": "research_report", "query": request.objective, "report": "No frost tonight. [1]",
                       "sources": [["n": 1, "title": "Saved forecast", "url": "local"]]]
                let states: [(String, NativeTaskSnapshot, NativeScheduleOutcome)] = [
                    ("running", try scheduleWithoutKindsSnapshot(reference, remote: remote, workerType: workerType, state: "running"), .running),
                    ("stopping", try scheduleWithoutKindsSnapshot(reference, remote: remote, workerType: workerType, state: "running", canceled: true), .running),
                    ("stopped", try scheduleWithoutKindsSnapshot(reference, remote: remote, workerType: workerType, state: "canceled"), .stopped),
                    ("finished", try scheduleWithoutKindsSnapshot(reference, remote: remote, workerType: workerType, state: "completed", result: result), .completed),
                    ("blocked", try scheduleWithoutKindsSnapshot(reference, remote: remote, workerType: workerType, state: "blocked",
                                                                 checkpoint: ["native_unavailable": "hidden"]), .blocked),
                    ("failed", try scheduleWithoutKindsSnapshot(reference, remote: remote, workerType: workerType, state: "failed"), .failed),
                ]
                for (label, snapshot, outcome) in states {
                    let display = try NativeTaskProjection.display(reference: reference, snapshot: snapshot)
                    let card = display.card
                    let hasArtifact = display.artifact != nil
                    let profile = CompanionOverviewModel.taskItem(card: card, reference: reference, decision: nil, hasArtifact: hasArtifact, date: Date()).state
                    let panel = OngoingWork.presentation(status: card.status, document: card.isDocument, hasArtifact: hasArtifact, title: card.statusTitle).state
                    let runTitle = ChatStore.scheduleRunTitle(NativeScheduleRun(scheduleID: "s", scheduledFor: Date(), outcome: outcome), card: card)
                    let shown = [card.statusTitle, card.stopTitle, card.milestone, profile, panel, runTitle] + (display.artifact.map { [$0.openTitle] } ?? [])
                    if scheduled {
                        try require(card.scheduled == true && shown.allSatisfy(plain),
                                    "A \(label) run of a schedule saved as \(workerType) names no kind of work: \(shown)")
                        if label == "finished" && workerType == "document" {
                            try require(profile == "Ready to open", "A finished scheduled document still reads ready to open: \(profile)")
                        }
                    } else {
                        let stop = workerType == "document" ? "Stop writing" : "Stop research"
                        try require(card.scheduled == nil && card.statusTitle == card.status.title(document: workerType == "document") && card.stopTitle == stop,
                                    "A \(label) \(workerType) started from a chat reads as before: \(card.statusTitle)")
                        if label == "finished" {
                            try require(card.milestone == (workerType == "document" ? "The document is ready." : "The report is ready.")
                                        && display.artifact?.openTitle == (workerType == "document" ? "Open document" : "Open report"),
                                        "Finished \(workerType) from a chat reads as before: \(card.milestone)")
                        }
                    }
                }
            }
        }
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NativeTaskCardPresentation(id: "old", title: "Old", status: .working, milestone: "",
                                                                                                         workerType: "research"))) as? [String: Any] ?? [:]
        saved["scheduled"] = nil
        let decoded = try JSONDecoder().decode(NativeTaskCardPresentation.self, from: JSONSerialization.data(withJSONObject: saved))
        try require(decoded.scheduled == nil && decoded.statusTitle == "Researching", "A card saved before this still decodes and reads as it did")
    }

    private static func scheduleWithoutKindsProfileAside(_ require: (Bool, String) throws -> Void) async throws {
        let harness = try await CompanionTalkControlFixture.harness { _, _, _ in CompanionAskedWorkTransport.say("Fine.") }
        defer { Task { await CompanionTalkControlFixture.finish(harness) } }
        let store = harness.store
        let scheduleStore = NativeScheduleStore(database: harness.repository.database)
        store.nativeScheduleStore = scheduleStore
        var draft = NativeScheduleDraft()
        draft.title = "Seed count"
        draft.instruction = "Count the seed packets."
        draft.owner = .conversation
        guard let schedule = store.createSchedule(draft) else { throw NativeTaskFixture.Failure.assertion("The schedule saves") }
        guard case .started(let text) = await store.fireSchedule(schedule, run: NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), outcome: .running),
                                                                 bind: { _, _ in }),
              let referenceID = UUID(uuidString: text), let reference = try harness.repository.taskReference(id: referenceID),
              let ownChat = try scheduleStore.get(schedule.id)?.conversationID else {
            throw NativeTaskFixture.Failure.assertion("The schedule's run starts")
        }
        let run = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), startedAt: Date(), outcome: .running, conversationID: ownChat,
                                    messageID: reference.origin.assistantMessageID.uuidString, taskReferenceID: reference.id.uuidString)
        try scheduleStore.saveRun(run)
        store.reloadSchedules()
        store.reloadNativeTaskReferences()
        func item() -> CompanionActivityItem? {
            store.reloadNativeTaskReferences()
            return store.companionOverviewModel().activity.first { $0.source == .task(reference.id) }
        }
        try await CompanionTalkControlFixture.eventually("The own chat run shows in the profile while it's going") {
            item()?.status == .working && item()?.canSetAside == true
        }
        try require(!store.companionOverviewModel().activity.contains { $0.id == "run:" + run.id }, "The run isn't listed twice")
        _ = await store.companionTalkHold(reference.id, resume: false)
        try await CompanionTalkControlFixture.eventually("The profile shows it put aside with pick back up") {
            item()?.status == .setAside && item()?.state == NativeTaskCardPresentation.setAsideTitle && item()?.canPickUp == true
        }
        guard let shown = item() else { throw NativeTaskFixture.Failure.assertion("The item exists") }
        try require(store.companionActivityDetail(shown).canOpen && store.openCompanionActivity(shown) && store.selectedID == ownChat,
                    "Go to chat opens its own chat")
    }

    private static func scheduleWithoutKindsLibrary(_ require: (Bool, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: directory)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                              attachmentStore: NativeAttachmentStore(directory: directory), artifactPersistenceEnabled: false)
        store.loadDotProfile()
        store.skipDotSetup()
        store.ensureVeraThread()
        guard let thread = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion's conversation exists") }
        let engine = try NativeTaskEngineIdentity(CardShot.engineURL)
        func made(_ request: NativeResearchTaskRequest, workerType: String) throws -> (chat: String, remote: String) {
            let origin = try NativeTaskFixture.origin(repository)
            let prepared = try repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: nil)
            let remote = UUID().uuidString
            _ = try repository.acknowledgeTaskReference(id: prepared.id, snapshot: try scheduleWithoutKindsSnapshot(prepared, remote: remote, workerType: workerType, state: "queued"))
            store.conversations = try repository.listConversations()
            return (origin.conversationID, remote)
        }
        let companion = try made(try NativeResearchTaskRequest(dot: NativeCompanionTaskPayload(assignment: "Write the bed note", mode: "scheduled",
                                                                                              scheduleID: UUID().uuidString.lowercased()), title: "Bed note"),
                                 workerType: NativeSchedule.companionWorkerType)
        let other = try made(try NativeResearchTaskRequest(objective: "Compare heaters", deliverables: ["A short summary"], workerType: "document"),
                             workerType: "document")
        store.reloadNativeTaskReferences()
        store.recordTaskArtifacts([.artifact(NativeResearchArtifact(id: companion.remote, title: "Bed note", report: "# Beds", sources: [], kind: "document"))],
                                  conversationID: companion.chat, messageID: UUID().uuidString)
        store.recordTaskArtifacts([.artifact(NativeResearchArtifact(id: other.remote, title: "Heater comparison", report: "# Heat", sources: [], kind: "document"))],
                                  conversationID: other.chat, messageID: UUID().uuidString)
        store.reloadArtifacts()
        guard let bed = store.artifactRecords.first(where: { $0.title == "Bed note" }),
              let heat = store.artifactRecords.first(where: { $0.title == "Heater comparison" }) else {
            throw NativeTaskFixture.Failure.assertion("Both documents are saved")
        }
        try require(bed.originTitle == CompanionSavedText.marker && bed.conversationID == companion.chat,
                    "The companion's document is credited to the companion and still opens in its own chat")
        try require(heat.originTitle != CompanionSavedText.marker && heat.conversationID == other.chat, "Other work keeps its chat's credit")
        var library = ArtifactLibrarySelection()
        library.conversationFilter = thread
        let shown = library.visible(store.artifactRecords, companionThreadID: thread).map(\.title)
        try require(shown.contains("Bed note") && !shown.contains("Heater comparison"), "The Library's companion filter includes it: \(shown)")
        let outputs = store.companionOverviewModel().outputs.map(\.title)
        try require(outputs.contains("Bed note") && !outputs.contains("Heater comparison"), "The profile's outputs include it: \(outputs)")
        try require(store.resetDot(), "Start over completes")
        guard let fresh = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("A fresh companion conversation opens") }
        let saved = try repository.listArtifacts()
        let kept = saved.first { $0.title == "Bed note" }
        try require(kept != nil && kept?.conversationID == companion.chat && kept?.originTitle != CompanionSavedText.marker
                    && (try repository.listConversations()).contains { $0.id == companion.chat },
                    "After start over the document and its chat stay, credited to its chat: \(kept?.originTitle ?? "nil")")
        let reopened = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                                 attachmentStore: NativeAttachmentStore(directory: directory), artifactPersistenceEnabled: false)
        reopened.loadDotProfile()
        reopened.conversations = try repository.listConversations()
        reopened.ensureVeraThread()
        reopened.reloadArtifacts()
        var after = ArtifactLibrarySelection()
        after.conversationFilter = reopened.veraThreadID ?? fresh
        let afterShown = after.visible(reopened.artifactRecords, companionThreadID: reopened.veraThreadID ?? fresh).map(\.title)
        let afterOutputs = reopened.companionOverviewModel().outputs.map(\.title)
        try require(!afterShown.contains("Bed note") && !afterOutputs.contains("Bed note"),
                    "The new companion's Library filter and outputs don't list it, after reopening from the database: \(afterShown) \(afterOutputs)")
    }


    private static func scheduleWithoutKindsDelivered(_ require: (Bool, String) throws -> Void) throws {
        func delivered(_ request: NativeResearchTaskRequest, workerType: String, result: [String: Any]) throws -> Message? {
            let repository = try LocalChatRepository(inMemory: true)
            let origin = try NativeTaskFixture.origin(repository)
            let prepared = try repository.prepareTaskReference(origin: origin, engine: try NativeTaskEngineIdentity(CardShot.engineURL), request: request, profile: nil)
            let remote = UUID().uuidString
            _ = try repository.acknowledgeTaskReference(id: prepared.id, snapshot: try scheduleWithoutKindsSnapshot(prepared, remote: remote, workerType: workerType, state: "queued"))
            guard let reference = try repository.taskReference(id: prepared.id) else { return nil }
            var finished = result
            finished["query"] = reference.request.objective
            _ = try repository.projectTask(id: reference.id, snapshot: try scheduleWithoutKindsSnapshot(reference, remote: remote, workerType: workerType,
                                                                                                        state: "completed", result: finished))
            return try repository.deliverTaskMessages(id: reference.id).first?.message
        }
        func openTitle(_ message: Message?) -> String? {
            message?.displayBlocks.compactMap { if case .artifact(let artifact) = $0 { artifact.openTitle } else { nil } }.first
        }
        let schedule = UUID().uuidString.lowercased()
        let documentResult: [String: Any] = ["kind": "document_report", "report": "# Frost\n\nNo frost tonight.", "sources": []]
        let keptResult: [String: Any] = ["kind": "companion_report", "report": "# Beds\n\nAll watered.", "summary": "All watered.",
                                         "title": "Bed note", "sources": [], "keep": true]
        let older = try delivered(try NativeResearchTaskRequest(objective: "Frost check", deliverables: ["A short note"], workerType: "document", scheduleID: schedule),
                                  workerType: "document", result: documentResult)
        let companion = try delivered(try NativeResearchTaskRequest(dot: NativeCompanionTaskPayload(assignment: "Write the bed note", mode: "scheduled",
                                                                                                  scheduleID: schedule), title: "Bed note"),
                                      workerType: NativeSchedule.companionWorkerType, result: keptResult)
        let chat = try delivered(try NativeResearchTaskRequest(objective: "Frost check", deliverables: ["A short note"], workerType: "document"),
                                 workerType: "document", result: documentResult)
        try require(openTitle(older) == "Open" && openTitle(companion) == "Open",
                    "A scheduled run's delivered result opens with a plain button: \(openTitle(older) ?? "nil") \(openTitle(companion) ?? "nil")")
        try require(openTitle(chat) == "Open document", "A document asked for in a chat keeps its button: \(openTitle(chat) ?? "nil")")
        if var older {
            older.displayBlocks = try JSONDecoder().decode([NativeDisplayBlock].self, from: JSONEncoder().encode(older.displayBlocks))
            try require(openTitle(older) == "Open", "The flag survives being saved and read back")
        }
    }

    private static func scheduleWithoutKindsCurrentLine(_ require: (Bool, String) throws -> Void) throws {
        func line(workerType: String, phase: String?, scheduled: Bool) throws -> String? {
            let repository = try LocalChatRepository(inMemory: true)
            let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
            store.loadDotProfile()
            store.skipDotSetup()
            store.ensureVeraThread()
            guard let thread = store.veraThreadID else { return nil }
            let user = Message(role: .user, text: "Check the frost")
            let reply = Message(role: .assistant, text: "", state: .streaming)
            try repository.saveMessage(user, conversationID: thread, ordinal: 0)
            try repository.saveMessage(reply, conversationID: thread, ordinal: 1)
            let origin = NativeTaskOrigin(conversationID: thread, userMessageID: user.id, assistantMessageID: reply.id)
            let request = try NativeResearchTaskRequest(objective: "Frost check", deliverables: ["A short note"], workerType: workerType,
                                                        title: "Frost check", scheduleID: scheduled ? UUID().uuidString.lowercased() : nil)
            let prepared = try repository.prepareTaskReference(origin: origin, engine: try NativeTaskEngineIdentity(CardShot.engineURL), request: request, profile: nil)
            let remote = UUID().uuidString
            _ = try repository.acknowledgeTaskReference(id: prepared.id, snapshot: try scheduleWithoutKindsSnapshot(prepared, remote: remote, workerType: workerType,
                state: "running", checkpoint: phase.map { ["phase": $0] }))
            guard let reference = try repository.taskReference(id: prepared.id) else { return nil }
            store.nativeTaskReferences = [reference]
            return store.companionBackgroundWork.current?.words
        }
        for workerType in ["research", "document"] {
            for phase in [nil, "gather", "synthesize"] as [String?] {
                let scheduled = try line(workerType: workerType, phase: phase, scheduled: true)
                try require(scheduled == "Working on Frost check",
                            "A scheduled \(workerType) run in \(phase ?? "planning") reads as the companion's own work: \(scheduled ?? "nil")")
                let chat = try line(workerType: workerType, phase: phase, scheduled: false)
                try require(chat == CompanionCurrentWork.words(workerType: workerType, phase: phase, title: "Frost check"),
                            "Chat-started \(workerType) in \(phase ?? "planning") reads as before: \(chat ?? "nil")")
            }
        }
        try require(CompanionCurrentWork.words(workerType: "research", phase: "synthesize", title: "Frost check") == "Writing up Frost check"
                    && CompanionCurrentWork.words(workerType: "document", phase: nil, title: "Frost check") == "Writing Frost check",
                    "Chat-started words are today's")
    }

    private static func scheduleWithoutKindsDeletedChat(_ require: (Bool, String) throws -> Void) async throws {
        let harness = try await CompanionTalkControlFixture.harness { _, _, _ in CompanionAskedWorkTransport.say("Fine.") }
        defer { Task { await CompanionTalkControlFixture.finish(harness) } }
        let store = harness.store
        let scheduleStore = NativeScheduleStore(database: harness.repository.database)
        store.nativeScheduleStore = scheduleStore
        var draft = NativeScheduleDraft()
        draft.title = "Vent check"
        draft.instruction = CompanionTalkControlFixture.askRetry
        draft.owner = .conversation
        guard let schedule = store.createSchedule(draft) else { throw NativeTaskFixture.Failure.assertion("The schedule saves") }
        guard case .started(let text) = await store.fireSchedule(schedule, run: NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), outcome: .running),
                                                                 bind: { _, _ in }),
              let referenceID = UUID(uuidString: text), let reference = try harness.repository.taskReference(id: referenceID),
              let ownChat = try scheduleStore.get(schedule.id)?.conversationID else {
            throw NativeTaskFixture.Failure.assertion("The schedule's run starts")
        }
        try scheduleStore.saveRun(NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), startedAt: Date(), outcome: .running, conversationID: ownChat,
                                                    messageID: reference.origin.assistantMessageID.uuidString, taskReferenceID: reference.id.uuidString))
        store.reloadSchedules()
        store.reloadNativeTaskReferences()
        try await CompanionTalkControlFixture.settle(harness, reference, .waiting)
        guard var run = try scheduleStore.runs(scheduleID: schedule.id).first else { throw NativeTaskFixture.Failure.assertion("The run is saved") }
        run.outcome = .waiting
        try scheduleStore.saveRun(run)
        store.reloadSchedules()
        store.select(harness.threadID)
        store.postScheduleCheckIns()
        guard let posted = try harness.repository.messages(conversationID: harness.threadID).last,
              posted.text.hasPrefix("The scheduled \"Vent check\" stopped to ask: ") else {
            throw NativeTaskFixture.Failure.assertion("The question is posted in the companion's conversation")
        }
        func loaded() -> Bool {
            store.conversations.first { $0.id == harness.threadID }?.messages.contains { $0.id == posted.id } ?? false
        }
        func saved() throws -> Bool { try harness.repository.messages(conversationID: harness.threadID).contains { $0.id == posted.id } }
        try require(loaded() && (try saved()), "The question is in the loaded companion conversation and the database")
        store.deleteConversation(ownChat)
        try require(!loaded() && !(try saved()), "Deleting the schedule's own chat takes its question out of the companion's conversation")
        try require(try scheduleStore.get(schedule.id) != nil, "The schedule stays")
        try await CompanionTalkControlFixture.eventually("The run's work stops") {
            let state = (try? CompanionTalkControlFixture.engineRecord(harness, reference))??.state
            return state == .canceled || state == nil
        }
        store.reloadNativeTaskReferences()
        let reopened = try harness.repository.listConversations().first { $0.id == harness.threadID }
        try require(!(try saved()) && !(reopened?.messages.contains { $0.id == posted.id } ?? false)
                    && !(try harness.repository.messages(conversationID: harness.threadID)).contains { message in
                        message.displayBlocks.contains { if case .taskCard(let card) = $0 { card.id == reference.id.uuidString } else { false } } },
                    "Read back from the database, no question or card for that run is left")
    }

}

final class ScheduleWithoutKindsCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: NativeJSONValue] = [:]

    func set(_ next: [String: NativeJSONValue]) { lock.withLock { values = next } }
    func next() -> [String: NativeJSONValue] { lock.withLock { values } }
}

@MainActor
final class ScheduleWithoutKindsCards {
    private(set) var count = 0
    func add() { count += 1 }
}
