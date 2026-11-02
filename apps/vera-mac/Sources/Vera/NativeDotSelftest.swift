import Foundation

@MainActor
extension SelfTest {
    static func runNativeDot() async throws {
        let require = NativeTaskFixture.require
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vera-dot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("vera.sqlite")
        let repository = try LocalChatRepository(url: url)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository,
                              nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
        await store.connect()

        try require(store.dotProfileLoaded && !store.dotProfile.setupCompleted && store.dotProfile.goal.isEmpty
                    && store.dotProfile.state == .active && store.dotProfile.connectedToolIDs == nil, "A fresh install starts with an empty profile that still needs setup")
        try require(try NativeDotProfileStore(database: repository.database).load() == nil, "Nothing is stored until setup is answered")
        store.skipDotSetup()
        try require(store.dotProfile.setupCompleted, "Skipping setup marks it answered")
        let goal = "Keep the greenhouse on track: watering, vent checks and a weekly note."
        store.saveDotProfile { $0.goal = "  \(goal)\n" }
        try require(store.dotProfile.goal == goal, "The goal is trimmed when saved")
        store.saveDotProfile { $0.goal = String(repeating: "g", count: 2500) }
        try require(store.dotProfile.goal.count == NativeDotProfile.goalLimit, "The goal is clamped to its limit")
        store.saveDotProfile { $0.goal = goal }
        store.setDotState(.paused)
        let reopened = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: try LocalChatRepository(url: url),
                                 nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
        await reopened.connect()
        try require(reopened.dotProfile.goal == goal && reopened.dotProfile.state == .paused && reopened.dotProfile.setupCompleted,
                    "A second store over the same database loads the same goal and state")
        let partial = try JSONDecoder().decode(NativeDotProfile.self, from: Data("{\"goal\":\"Plan the garden\"}".utf8))
        try require(partial.goal == "Plan the garden" && partial.state == .active && !partial.setupCompleted && partial.connectedToolIDs == nil,
                    "Older or partial profile JSON still loads with defaults")
        store.setDotState(.active)

        guard let veraID = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The Vera thread exists") }
        let focused = Conversation(id: UUID().uuidString, title: "Seed catalog", messages: [], updatedAt: Date())
        try repository.saveConversation(focused)
        try repository.saveMessage(Message(role: .user, text: "Which seeds came in?"), conversationID: focused.id, ordinal: 0)
        try repository.saveMessage(Message(role: .assistant, text: "Tomatoes and basil."), conversationID: focused.id, ordinal: 1)

        store.tightenConversationRule(.act, for: .commands, conversationID: veraID)
        try require(store.conversationRules(for: veraID).choices[.commands] == nil
                    && store.ruleResolver(for: veraID, requestText: "").choice(for: .commands) == .ask, "The Vera thread cannot loosen past the global ask")
        store.tightenConversationRule(.handOff, for: .commands, conversationID: veraID)
        store.tightenConversationRule(.act, for: .sensitive, conversationID: veraID)
        let resolver = store.ruleResolver(for: veraID, requestText: "")
        try require(resolver.choice(for: .commands) == .handOff && resolver.choice(for: .sensitive) == .handOff, "Tightening holds and sensitive stays handed off")
        try require(store.ruleResolver(for: focused.id, requestText: "").choice(for: .commands) == .ask, "Tightening the Vera thread leaves other chats alone")

        guard let dotContext = store.dotContext(for: veraID, requestText: "what's next?") else {
            throw NativeTaskFixture.Failure.assertion("The Vera thread gets the standing context")
        }
        try require(dotContext.contains(goal) && dotContext.contains("You are Ada") && dotContext.contains("Run commands in granted folders: hand off to the user.")
                    && dotContext.contains("always handed to the user") && dotContext.contains(NativeDotContext.coordinatorNote)
                    && dotContext.count <= NativeDotContext.limit, "The standing context carries the name, goal, coordinator role and the rules in effect")
        try require(store.dotContext(for: focused.id, requestText: "hi") == nil, "Focused chats never receive the standing context")
        let veraPrompt = NativeContextAssembler.assemble(NativeContextInput(persona: "Persona", timestamp: Date(), timeZone: .current,
                                                                            assistantProfile: dotContext)).prompt
        let focusedPrompt = NativeContextAssembler.assemble(NativeContextInput(persona: "Persona", timestamp: Date(), timeZone: .current,
                                                                               assistantProfile: store.dotContext(for: focused.id, requestText: "hi"))).prompt
        try require(veraPrompt.contains("STANDING ASSISTANT") && veraPrompt.contains(goal) && !focusedPrompt.contains("STANDING ASSISTANT"),
                    "Only the Vera thread's prompt has the standing assistant section")
        let long = NativeDotContext.render(name: "Ada", goal: String(repeating: "word ", count: 600), resolver: resolver)
        try require(long.count <= NativeDotContext.limit && long.contains("...") && long.contains(NativeDotContext.coordinatorNote), "A long goal is shortened to keep the block small")
        let goalless = NativeDotContext.render(name: "Ada", goal: "", resolver: resolver)
        try require(goalless.contains("No standing goal has been set yet.") && goalless.contains(NativeDotContext.coordinatorNote), "A missing goal is said plainly and the coordinator role stays")

        store.saveDotProfile { $0.connectedToolIDs = ["a"] }
        try require(store.dotToolIDs(base: ["a", "b"]) == ["a"], "Connected services narrow the tools")
        store.saveDotProfile { $0.connectedToolIDs = nil }
        try require(store.dotToolIDs(base: ["a", "b"]) == ["a", "b"], "No selection passes every enabled tool")
        let options = [NativeDotServiceOption(id: "a", name: "A", detail: "", toolIDs: ["a"]),
                       NativeDotServiceOption(id: "service:s", name: "S", detail: "", toolIDs: ["s1", "s2"])]
        try require(store.dotConnectedToolIDs(selected: ["a", "service:s"], options: options) == nil
                    && store.dotConnectedToolIDs(selected: ["service:s"], options: options) == ["s1", "s2"], "Service choices map to tool sets")

        try await checkTurnTools(store, veraID: veraID, focusedID: focused.id, goal: goal)
        try checkRuleDrafts(store, veraID: veraID)

        var paused = NativeDotProfile(state: .paused)
        try require(!paused.allowsScheduledRun(owner: .dot) && paused.allowsScheduledRun(owner: .conversation), "Pause holds only the dot's schedules")
        paused.state = .active
        try require(paused.allowsScheduledRun(owner: .dot), "Resuming lets dot schedules run")
        let scheduleStore = NativeScheduleStore(database: try LocalChatRepository(inMemory: true).database)
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let due = try NativeSchedule(owner: .dot, workerType: "research", title: "Weekly note", instruction: "Write the greenhouse note",
                                     cadence: .daily(minuteOfDay: 9 * 60), timeZone: .current, nextRunAt: moment.addingTimeInterval(-10))
        try scheduleStore.save(due)
        let scheduler = NativeScheduler(store: scheduleStore, now: { moment }, lookup: { _ in nil },
                                        fire: { _, _, _ in .skipped("Ada is paused.") })
        _ = await scheduler.tick()
        let skippedRuns = try scheduleStore.runs(scheduleID: due.id)
        let advanced = try scheduleStore.get(due.id)
        try require(skippedRuns.count == 1, "A paused schedule records exactly one run: \(skippedRuns)")
        try require(skippedRuns[0].outcome == .skipped && skippedRuns[0].detail == "Ada is paused.", "A paused run is recorded as skipped with a plain reason: \(skippedRuns[0])")
        try require(skippedRuns[0].finishedAt == moment, "A skipped run finishes at the tick: \(String(describing: skippedRuns[0].finishedAt)) vs \(moment)")
        try require((advanced?.nextRunAt ?? .distantPast) > moment, "The schedule moves on, so resuming never catches up")
        try scheduleStore.delete(due.id)
        guard let liveStore = store.nativeScheduleStore else { throw NativeTaskFixture.Failure.assertion("The store has a schedule store") }
        try liveStore.save(due)
        store.setDotState(.paused)
        let probe = NativeScheduleRun(scheduleID: due.id, scheduledFor: moment, outcome: .running)
        let pausedFire = await store.fireSchedule(due, run: probe, bind: { _, _ in })
        try require(pausedFire == .skipped("Ada is paused."), "The store skips a dot schedule while paused: \(pausedFire)")
        var conversationOwned = due
        conversationOwned.owner = .conversation
        try liveStore.save(conversationOwned)
        if case .skipped = await store.fireSchedule(conversationOwned, run: probe, bind: { _, _ in }) {
            throw NativeTaskFixture.Failure.assertion("Conversation schedules ignore the pause")
        }
        try liveStore.delete(due.id)
        let removedFire = await store.fireSchedule(conversationOwned, run: probe, bind: { _, _ in })
        try require(removedFire == .skipped(ChatStore.removedScheduleReason), "A removed schedule never runs: \(removedFire)")
        store.setDotState(.active)

        var missedDraft = NativeScheduleDraft()
        missedDraft.title = "Morning vent check"
        missedDraft.instruction = "Check the vents"
        missedDraft.owner = .dot
        guard var missed = store.createSchedule(missedDraft) else { throw NativeTaskFixture.Failure.assertion("The missed-run fixture saves") }
        store.setDotState(.paused)
        missed.nextRunAt = Date().addingTimeInterval(-3600)
        try liveStore.save(missed)
        store.setDotState(.active)
        let resumedAt = Date()
        let afterResume = try liveStore.get(missed.id)
        try require((afterResume?.nextRunAt ?? .distantPast) > resumedAt && afterResume?.enabled == true,
                    "Resuming moves a past-due dot schedule to its next time instead of running it: \(String(describing: afterResume?.nextRunAt))")
        try require(try liveStore.runs(scheduleID: missed.id).isEmpty, "Resuming records no catch-up run")
        try require(store.schedules.first(where: { $0.id == missed.id })?.nextRunAt == afterResume?.nextRunAt, "The schedule list shows the moved time")
        store.deleteSchedule(missed.id)

        let first = Message(role: .user, text: "Note that the vents stick in the morning.")
        let second = Message(role: .assistant, text: "Noted.")
        let third = Message(role: .user, text: "And the hose leaks.")
        for (index, message) in [first, second, third].enumerated() {
            try repository.saveMessage(message, conversationID: veraID, ordinal: index)
        }
        let now = Date()
        let dotMemory = NativeMemoryRecord(id: "dot-memory", title: "Sticky vents", summary: "Greenhouse vents stick in the morning",
                                           details: ["The greenhouse vents stick in the morning"], group: .areas, category: .goal, bank: "home",
                                           durability: .durable, expiry: nil, status: .approved, embedding: nil, sourceConversationID: veraID,
                                           sourceMessageID: first.id.uuidString, createdAt: now, updatedAt: now)
        let otherMemory = NativeMemoryRecord(id: "other-memory", title: "Seed order", summary: "Orders seeds in February",
                                             details: ["Orders seeds in February"], group: .areas, category: .goal, bank: "home",
                                             durability: .durable, expiry: nil, status: .approved, embedding: nil, sourceConversationID: focused.id,
                                             sourceMessageID: nil, createdAt: now, updatedAt: now)
        try repository.saveMemory(dotMemory, decision: .accepted, note: "Fixture")
        try repository.saveMemory(otherMemory, decision: .accepted, note: "Fixture")
        let proposal = NativeMemoryProposal(id: "dot-proposal", kind: .create, title: "Leaky hose", summary: "The hose leaks",
                                            details: ["The garden hose leaks"], group: .areas, category: .goal, bank: "home",
                                            durability: .durable, expiry: nil, targetIDs: [], sourceConversationID: veraID,
                                            sourceMessageID: third.id.uuidString, createdAt: now, status: .pending)
        try repository.saveProposal(proposal)
        var dotDraft = NativeScheduleDraft()
        dotDraft.title = "Weekly greenhouse note"
        dotDraft.instruction = "Write the weekly greenhouse note"
        dotDraft.owner = .dot
        var chatDraft = NativeScheduleDraft()
        chatDraft.title = "Seed sale watch"
        chatDraft.instruction = "Look for seed sales"
        chatDraft.owner = .conversation
        guard store.createSchedule(dotDraft) != nil, let kept = store.createSchedule(chatDraft) else {
            throw NativeTaskFixture.Failure.assertion("Fixture schedules save")
        }
        store.artifactLibrary = [Artifact.mock()]
        let artifactsBefore = store.artifactLibrary
        let threadArtifact = try repository.recordArtifact(ArtifactDraft(
            kind: .document, title: "Greenhouse note", conversationID: veraID, originTitle: "Ada", messageID: nil,
            sourceKey: "dot:note", data: Data("# Note".utf8), mime: "text/markdown", fileExtension: "md"), revising: nil)
        store.saveDotProfile { $0.goal = goal }

        let summary = store.dotRemovalSummary()
        try require(summary.messages == 3 && summary.memories == 1 && summary.proposals == 1 && summary.schedules == 1
                    && summary.artifacts == 1 && summary.hasGoal && !summary.services, "The removal summary counts what start over removes: \(summary)")
        try require(summary.sentence == "This removes 3 messages, 1 memory, 1 suggested memory, 1 schedule and the goal. Your 1 artifact stays in Artifacts.",
                    "The removal summary reads plainly: \(summary.sentence)")
        store.saveDotProfile { $0.connectedToolIDs = ["a"] }
        let withServices = store.dotRemovalSummary()
        try require(withServices.services && withServices.sentence
                    == "This removes 3 messages, 1 memory, 1 suggested memory, 1 schedule, the goal and the service choices. Your 1 artifact stays in Artifacts.",
                    "The removal summary lists the service choices when some were made: \(withServices.sentence)")
        let servicesOnly = NativeDotRemovalSummary(services: true)
        try require(servicesOnly.sentence == "This removes the service choices.", "Service choices alone read plainly: \(servicesOnly.sentence)")

        store.openVeraThread()
        store.resetDot()
        guard let freshID = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("A fresh Vera thread exists after reset") }
        try require(freshID != veraID && (try repository.messages(conversationID: freshID)).isEmpty
                    && (try repository.messages(conversationID: veraID)).isEmpty, "Reset replaces the thread with an empty one")
        try require(store.selectedID == freshID && store.section == .vera, "The fresh thread is selected when the old one was showing")
        try require(store.conversations.filter { $0.originType == ChatStore.veraThreadOriginType && $0.originID == ChatStore.veraThreadOriginID }.count == 1,
                    "Exactly one Vera thread remains")
        let memories = try repository.allMemories()
        try require(memories.first(where: { $0.id == "dot-memory" })?.status == .deleted
                    && memories.first(where: { $0.id == "dot-memory" })?.summary.isEmpty == true, "Dot-sourced memory is tombstoned")
        try require(memories.first(where: { $0.id == "other-memory" })?.status == .approved, "Memory from other chats stays")
        try require(try repository.pendingProposals().allSatisfy { $0.id != "dot-proposal" }, "Pending dot proposals are dismissed")
        try require(store.schedules.map(\.id) == [kept.id], "Only the conversation schedule remains")
        try require((try repository.messages(conversationID: focused.id)).count == 2, "Focused chats survive reset")
        try require(store.artifactLibrary == artifactsBefore, "Artifacts stay")
        let keptArtifact = try repository.artifact(threadArtifact.artifactID)
        try require(keptArtifact != nil && keptArtifact?.conversationID == nil, "An artifact made in the Vera thread stays in Artifacts, detached from the removed thread")
        try require(store.dotProfile == NativeDotProfile(updatedAt: store.dotProfile.updatedAt) && !store.dotProfile.setupCompleted
                    && (try NativeDotProfileStore(database: repository.database).load()) == nil, "The profile returns to defaults and setup shows again")
        try require(store.conversationRules(for: freshID).isEmpty, "The fresh thread starts with the global rules")
        try checkHeaderSummary()
        try await checkCorruptProfile(folder: folder)
        try await checkFireLiveness(folder: folder)
        try await checkExtractionAfterReset()
        print("  dot OK (profile, context, tightening, services, pause, resume, liveness, extraction, header, reset)")
    }

    private static func turn(_ store: ChatStore, conversationID: String, text: String) -> NativeConversationTurn {
        let user = Message(role: .user, text: text)
        return NativeConversationTurn(id: UUID(), conversationID: conversationID, userMessageID: user.id, assistantMessageID: UUID(),
            mode: .chat, profile: "", enabledToolIDs: [], persona: "Persona", userScope: "", instructions: "", grounding: [],
            memorySettings: store.nativeMemorySettings, createdAt: Date(), history: [NativeTurnHistoryMessage(user)])
    }

    private static func checkTurnTools(_ store: ChatStore, veraID: String, focusedID: String, goal: String) async throws {
        let require = NativeTaskFixture.require
        let search = NativeWebTools.searchToolID
        let mention = "@Search the web for greenhouse vents"
        store.updateNativeToolConsent(["a"])
        store.saveDotProfile { $0.connectedToolIDs = nil }
        let veraTools = store.turnToolAuthority(for: turn(store, conversationID: veraID, text: mention)).1
        let focusedTools = store.turnToolAuthority(for: turn(store, conversationID: focusedID, text: mention)).1
        try require(!veraTools.contains(search) && veraTools.contains("a"), "A mention cannot restore a tool that is off in Settings in the Vera thread: \(veraTools)")
        try require(focusedTools.contains(search), "Focused chats keep mention consent: \(focusedTools)")
        store.updateNativeToolConsent(["a", search])
        store.saveDotProfile { $0.connectedToolIDs = ["a"] }
        let notConnected = store.turnToolAuthority(for: turn(store, conversationID: veraID, text: mention)).1
        try require(notConnected == ["a"], "A mention cannot restore a service the Vera thread turned off: \(notConnected)")
        store.saveDotProfile { $0.connectedToolIDs = nil }
        let both = store.turnToolAuthority(for: turn(store, conversationID: veraID, text: mention)).1
        try require(both.contains(search), "A mention of a tool that is on and connected still counts: \(both)")
        store.updateNativeToolConsent([])

        let legacy = turn(store, conversationID: veraID, text: "What's next for the greenhouse?")
        try require(legacy.dotContext == nil, "The fixture turn predates the standing context")
        let replayed = store.turnDotContext(legacy)
        let prompt = NativeContextAssembler.assemble(NativeContextInput(persona: "Persona", timestamp: Date(), timeZone: .current,
                                                                        assistantProfile: replayed)).prompt
        try require(prompt.contains("STANDING ASSISTANT") && prompt.contains(goal), "An older Vera turn without a stored block still assembles with it")
        try require(store.turnDotContext(turn(store, conversationID: focusedID, text: "hi")) == nil, "An older focused turn stays without the block")
        var stored = legacy
        stored.dotContext = "Stored block"
        try require(store.turnDotContext(stored) == "Stored block", "A turn's stored block wins over a live one")
    }

    private static func checkRuleDrafts(_ store: ChatStore, veraID: String) throws {
        let require = NativeTaskFixture.require
        let before = store.conversationRules(for: veraID)
        var draft = DotProfileCopy.draftRules(store)
        try require(draft == before.choices, "The draft starts from the thread's current rules")
        draft[.commands] = .ask
        draft[.trash] = .handOff
        try require(store.conversationRules(for: veraID) == before, "Editing the draft leaves the thread's rules alone until saved")
        DotProfileCopy.commitRules(draft, store: store)
        let resolver = store.ruleResolver(for: veraID, requestText: "")
        try require(store.conversationRules(for: veraID).choices[.commands] == nil && resolver.choice(for: .commands) == .ask,
                    "Saving a draft back at the default clears the tightening")
        try require(resolver.choice(for: .trash) == .handOff, "Saving a stricter draft tightens the thread")
        DotProfileCopy.commitRules(before.choices, store: store)
        try require(store.conversationRules(for: veraID).choices == before.choices, "Committing the original draft restores the rules")
    }

    private static func checkHeaderSummary() throws {
        let require = NativeTaskFixture.require
        let tightened = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(choices: [.commands: .handOff]), requestText: "")
        let summary = NativeDotContext.headerSummary(resolver: tightened)
        try require(summary == "Asks first for Trash. Hands off commands and sending.", "The header summary reads plainly: \(summary)")
        let relaxed = NativeRules(choices: [.fileEdits: .act, .commands: .act, .trash: .act, .networkSends: .act])
        let quiet = NativeDotContext.headerSummary(resolver: NativeRuleResolver(global: relaxed, conversation: NativeConversationRules(), requestText: ""))
        try require(quiet == "Acts without asking", "Nothing asking reads plainly: \(quiet)")
        let mixed = NativeRules(choices: [.fileEdits: .actIfPreapproved, .commands: .ask, .trash: .ask, .networkSends: .act])
        let mixedSummary = NativeDotContext.headerSummary(resolver: NativeRuleResolver(global: mixed, conversation: NativeConversationRules(), requestText: ""))
        try require(mixedSummary == "Asks first for commands and Trash. Needs your go-ahead in the request for file edits.", "Mixed rules read plainly: \(mixedSummary)")
        let raw = NativeActionClass.allCases.map(\.rawValue) + NativeRuleChoice.allCases.map(\.rawValue)
        for text in [summary, quiet, mixedSummary] {
            try require(!raw.contains { $0.contains("_") && text.contains($0) } && !text.contains("_"), "The header summary carries no internal names: \(text)")
        }
    }

    private static func checkCorruptProfile(folder: URL) async throws {
        let require = NativeTaskFixture.require
        let odd = try JSONDecoder().decode(NativeDotProfile.self, from: Data("{\"goal\":\"Plan\",\"state\":\"sleeping\",\"connected_tool_ids\":\"oops\"}".utf8))
        try require(odd.state == .paused && odd.connectedToolIDs == [], "An unknown state pauses and malformed services connect nothing")
        let cleared = try JSONDecoder().decode(NativeDotProfile.self, from: Data("{\"connected_tool_ids\":null,\"state\":\"active\"}".utf8))
        try require(cleared.connectedToolIDs == nil && cleared.state == .active, "A null service list still means every enabled tool")
        let url = folder.appendingPathComponent("corrupt.sqlite")
        let repository = try LocalChatRepository(url: url)
        try await repository.database.write { db in
            try db.execute(sql: "INSERT INTO native_dot_profile(id, profile_json, updated_at) VALUES('dot', 'not json', 0)")
        }
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository,
                              nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
        await store.connect()
        try require(store.dotProfile.state == .paused && store.dotProfile.connectedToolIDs == [] && store.dotProfile.setupCompleted,
                    "A profile that can't be read fails closed: \(store.dotProfile)")
        try require(store.chatConfigurationError?.contains("Scheduled work is paused and no services are connected until the settings are saved again.") == true,
                    "The failure says what is held and how to fix it: \(store.chatConfigurationError ?? "")")
        try require(store.dotToolIDs(base: ["a", "b"]).isEmpty && !store.dotProfile.allowsScheduledRun(owner: .dot), "Nothing runs or connects while the profile is unreadable")
        store.saveDotProfile { $0.goal = "Plan the garden" }
        try require(try NativeDotProfileStore(database: repository.database).load()?.goal == "Plan the garden", "Saving the settings repairs the stored profile")
    }

    private static func checkFireLiveness(folder: URL) async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(url: folder.appendingPathComponent("fire.sqlite"))
        let config = NativeChatConfig(baseURL: URL(string: "https://fixture.invalid/v1")!, apiKey: nil, model: "fixture", chatTemplateKwargs: nil)
        let store = ChatStore(nativeConfig: config, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                              nativeSearchAvailable: { false }, artifactPersistenceEnabled: false)
        await store.connect()
        var draft = NativeScheduleDraft()
        draft.title = "Weekly note"
        draft.instruction = "Write the weekly greenhouse note"
        draft.workerType = "document"
        draft.owner = .dot
        guard let schedule = store.createSchedule(draft) else { throw NativeTaskFixture.Failure.assertion("The liveness fixture schedule saves") }
        store.ensureVeraThread()
        guard let threadID = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The liveness fixture has a Vera thread") }
        let probe = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), outcome: .running)
        let messagesBefore = try repository.messages(conversationID: threadID).count
        let pausedMidway = await store.fireSchedule(schedule, run: probe, bind: { _, _ in
            await MainActor.run { store.setDotState(.paused) }
        })
        try require(pausedMidway == .skipped("Ada is paused."), "Pausing while a run starts skips it: \(pausedMidway)")
        try require(try repository.messages(conversationID: threadID).count == messagesBefore
                    && (try repository.taskReferences(conversationID: threadID)).isEmpty, "A run skipped mid-start saves nothing and submits nothing")
        store.setDotState(.active)
        let removedMidway = await store.fireSchedule(schedule, run: probe, bind: { _, _ in
            await MainActor.run { store.deleteSchedule(schedule.id) }
        })
        try require(removedMidway == .skipped(ChatStore.removedScheduleReason), "Removing a schedule while it starts skips it: \(removedMidway)")
        try require(try repository.messages(conversationID: threadID).count == messagesBefore
                    && (try repository.taskReferences(conversationID: threadID)).isEmpty, "A removed run saves nothing and submits nothing")
    }

    private static func checkExtractionAfterReset() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        var settings = NativeMemorySettings.fresh
        settings.enabled = true
        settings.embeddingsModel = "embed-model"
        settings.extractionModel = "extract-model"
        settings.bankScope = "personal"
        settings.generateFromChats = true
        let service = DotMemoryService()
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                              nativeMemorySettings: settings, nativeMemoryService: service, artifactPersistenceEnabled: false)
        await store.connect()
        store.ensureVeraThread()
        guard let veraID = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The extraction fixture has a Vera thread") }
        let focused = Conversation(id: UUID().uuidString, title: "Seeds", messages: [], updatedAt: Date())
        try repository.saveConversation(focused)
        let reply = Message(role: .assistant, text: "Noted.")
        func learn(_ conversationID: String) async {
            await store.learnFromCompletedTurn(
                user: "I prefer watering the greenhouse in the morning.", assistant: reply,
                source: NativeMemoryTurnSource(conversationID: conversationID, messageID: UUID().uuidString, date: Date()),
                turnKey: conversationID + "|" + UUID().uuidString, conversationExcluded: false)
        }
        await learn(focused.id)
        try require(try repository.pendingProposals().contains { $0.sourceConversationID == focused.id }, "A live chat's extraction is saved")
        service.onExtract = { store.resetDot() }
        await learn(veraID)
        try require(service.calls == 2 && store.veraThreadID != veraID, "The reset happened while extraction was in flight")
        try require(try repository.pendingProposals().allSatisfy { $0.sourceConversationID != veraID },
                    "An extraction started before start over is dropped")
        let gone = Conversation(id: UUID().uuidString, title: "Gone", messages: [], updatedAt: Date())
        try repository.saveConversation(gone)
        service.onExtract = { try? repository.deleteConversation(gone.id) }
        await learn(gone.id)
        try require(try repository.pendingProposals().allSatisfy { $0.sourceConversationID != gone.id },
                    "An extraction for a deleted chat is dropped")
        service.onExtract = nil
    }
}

final class DotMemoryService: NativeMemoryServing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var hook: (@MainActor @Sendable () -> Void)?

    var calls: Int { lock.withLock { count } }
    var onExtract: (@MainActor @Sendable () -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    func embed(_ text: String) async throws -> [Double] { [1, 0] }

    func proposals(
        user: String, assistant: String, sourceConversationID: String?, sourceMessageID: String?,
        existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] {
        let pending = lock.withLock { count += 1; return self.hook }
        if let pending { await pending() }
        return [NativeMemoryProposal(
            id: UUID().uuidString, kind: .create, title: "Morning watering",
            summary: "Waters the greenhouse in the morning", details: ["The user waters the greenhouse in the morning"],
            group: .profile, category: .preference, bank: "personal", durability: .durable,
            expiry: nil, targetIDs: [], sourceConversationID: sourceConversationID,
            sourceMessageID: sourceMessageID, createdAt: now, status: .pending)]
    }

    func proposal(
        request: String, existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] { [] }
}
