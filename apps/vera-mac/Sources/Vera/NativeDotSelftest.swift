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
        store.setDotState(.paused)
        let probe = NativeScheduleRun(scheduleID: due.id, scheduledFor: moment, outcome: .running)
        let pausedFire = await store.fireSchedule(due, run: probe, bind: { _, _ in })
        try require(pausedFire == .skipped("Ada is paused."), "The store skips a dot schedule while paused")
        var conversationOwned = due
        conversationOwned.owner = .conversation
        if case .skipped = await store.fireSchedule(conversationOwned, run: probe, bind: { _, _ in }) {
            throw NativeTaskFixture.Failure.assertion("Conversation schedules ignore the pause")
        }
        store.setDotState(.active)

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
        store.saveDotProfile { $0.goal = goal }

        let summary = store.dotRemovalSummary()
        try require(summary.messages == 3 && summary.memories == 1 && summary.proposals == 1 && summary.schedules == 1
                    && summary.artifacts == 1 && summary.hasGoal, "The removal summary counts what start over removes: \(summary)")
        try require(summary.sentence == "This removes 3 messages, 1 memory, 1 suggested memory, 1 schedule and the goal. Your 1 artifact stays in Artifacts.",
                    "The removal summary reads plainly: \(summary.sentence)")

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
        try require(store.dotProfile == NativeDotProfile(updatedAt: store.dotProfile.updatedAt) && !store.dotProfile.setupCompleted
                    && (try NativeDotProfileStore(database: repository.database).load()) == nil, "The profile returns to defaults and setup shows again")
        try require(store.conversationRules(for: freshID).isEmpty, "The fresh thread starts with the global rules")
        print("  dot OK (profile, context, tightening, services, pause, reset)")
    }
}
