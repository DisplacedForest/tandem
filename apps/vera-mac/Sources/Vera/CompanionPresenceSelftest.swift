import Foundation

@MainActor
extension SelfTest {
    static func runCompanionPresence() async throws {
        let require = NativeTaskFixture.require
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil)
        let thread = Conversation(id: "presence-companion", title: "Companion", messages: [], updatedAt: Date(),
                                  originType: ChatStore.veraThreadOriginType, originID: ChatStore.veraThreadOriginID)
        store.conversations = [thread]
        store.ensureVeraThread()
        store.selectedID = "ordinary"
        func state(_ active: Bool = true) -> CompanionState {
            CompanionStateMapper.state(CompanionPresence.snapshot(store: store, appActive: active))
        }
        let running = try OngoingWorkFixture.reference(conversationID: thread.id, title: "Read the report", state: "running")
        let decision = try OngoingWorkFixture.reference(conversationID: thread.id, title: "Review the report",
                                                       state: "needs_decision", decision: OngoingWorkFixture.decision)
        let foreign = try OngoingWorkFixture.reference(conversationID: "ordinary", title: "Other work", state: "running")
        func background() -> CompanionBackgroundWork { store.companionBackgroundWork }
        let words = CompanionCurrentWork.words
        try require(words("research", "gather", "new Indy restaurants") == "Finding new Indy restaurants"
                    && words("research", nil, "new Indy restaurants") == "Researching new Indy restaurants"
                    && words("research", "synthesize", "Quiet reading spaces") == "Writing up Quiet reading spaces"
                    && words("document", nil, "Workshop plan") == "Writing Workshop plan"
                    && words("companion", nil, "Sort the seed folders") == "Working on Sort the seed folders"
                    && words("research", nil, "  ") == "Researching", "The line says what is happening in a few words")
        try require(CompanionCurrentWork.kind(workerType: "research", phase: "gather") == .researching
                    && CompanionCurrentWork.kind(workerType: "research", phase: "synthesize") == .writing
                    && CompanionCurrentWork.kind(workerType: "document", phase: nil) == .writing
                    && CompanionCurrentWork.kind(workerType: "companion", phase: nil) == .changing, "Each kind of work has its own look")
        store.nativeTaskReferences = [foreign, running]
        try require(!store.companionWantsAttention, "The badge stays quiet while work runs and nothing waits for an answer")
        store.nativeTaskReferences = [decision]
        try require(store.companionWantsAttention, "The badge changes when the companion needs an answer")
        store.nativeTaskReferences = []
        try require(!store.companionWantsAttention, "The badge goes quiet again once nothing is waiting")
        let defaults = AppLocations.scratchPreferences()
        store.companionDefaults = defaults
        store.conversations[0].messages = [Message(role: .assistant, text: "The seedlings are in.")]
        store.setCompanionSeenReplyForTesting("")
        try require(store.companionUnreadCount == 1 && store.companionBackgroundWork.needsAnswer == 0 && !store.companionAwaitingApproval
                    && store.companionWantsAttention, "The badge changes for an unread reply on its own")
        store.markCompanionSeen()
        try require(store.companionUnreadCount == 0 && !store.companionWantsAttention, "The badge goes quiet once the reply is seen")
        store.conversations[0].messages = []
        let asking = Message(role: .user, text: "Run the check")
        let turn = NativeConversationTurn(id: UUID(), conversationID: thread.id, userMessageID: asking.id, assistantMessageID: UUID(),
            mode: .chat, profile: "", enabledToolIDs: [], persona: "Persona", userScope: "", instructions: "", grounding: [],
            memorySettings: store.nativeMemorySettings, createdAt: Date(), history: [NativeTurnHistoryMessage(asking)])
        let activity = NativeToolActivity(id: "presence-confirm", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName,
                                          title: "Run a command", round: 1, request: "{\"command\":\"make check\"}", result: nil,
                                          state: .pending, confirmationRequired: true)
        store.conversationTurns = [turn]
        store.turnConfirmations[turn.assistantMessageID] = NativeToolConfirmationRequest(activity: activity)
        try require(store.companionUnreadCount == 0 && store.companionBackgroundWork.needsAnswer == 0 && store.companionWantsAttention,
                    "The badge changes for a waiting approval on its own")
        store.turnConfirmations[turn.assistantMessageID] = nil
        store.conversationTurns = []
        try require(!store.companionWantsAttention, "The badge goes quiet once the approval is answered")
        store.generating = true
        store.nativeTaskReferences = [foreign]
        try require(state() == .ready && background().isEmpty && background().current == nil,
                    "Work from an ordinary conversation does not animate the companion or show a line")
        store.nativeTaskReferences.append(running)
        try require(state().working && state(false).working, "Running work shows the companion working, also after navigation or app deactivation")
        try require(background().current?.words.hasSuffix("Read the report") == true, "The line names the work that is running")
        let document = try OngoingWorkFixture.reference(conversationID: thread.id, title: "Workshop plan", workerType: "document", state: "running")
        store.nativeTaskReferences = [document]
        try require(state() == .writing && background().current?.words == "Writing Workshop plan", "Writing has its own look and words")
        let general = try OngoingWorkFixture.reference(conversationID: thread.id, title: "Sort the seed folders", workerType: "companion", state: "running")
        store.nativeTaskReferences = [general]
        try require(state() == .changing, "Other work has its own look")
        store.nativeTaskReferences = [foreign, document, general, running]
        try require(background().current?.line.hasSuffix("Read the report and 2 more") == true && state().working,
                    "Several pieces of work show the newest and count the rest on one line")
        store.nativeTaskReferences = [foreign, document, general]
        try require(background().current?.line == "Working on Sort the seed folders and 1 more" && state() == .changing,
                    "When the newest finishes the line and the figure move to the next newest")
        store.nativeTaskReferences = [foreign, document]
        try require(background().current?.line == "Writing Workshop plan" && state() == .writing, "One piece of work is named with no count")
        let asked = Date().addingTimeInterval(-600)
        store.conversations[0].messages = [
            Message(id: document.origin.userMessageID, role: .user, text: "Write the plan", createdAt: asked.addingTimeInterval(120)),
            Message(id: general.origin.userMessageID, role: .user, text: "Sort the folders", createdAt: asked),
            Message(id: running.origin.userMessageID, role: .user, text: "Read the report", createdAt: asked.addingTimeInterval(60)),
        ]
        store.nativeTaskReferences = [document, general, running]
        try require(background().current?.line == "Writing Workshop plan and 2 more" && state() == .writing,
                    "The newest is the one asked for last, whatever order the work is stored in")
        store.schedules = CompanionOverviewFixture.schedules()
        store.scheduleRuns = ["overview-morning": [NativeScheduleRun(id: "later", scheduleID: "overview-morning", scheduledFor: asked,
                                                                     startedAt: asked.addingTimeInterval(300), outcome: .running)]]
        try require(background().current?.words.hasPrefix("Working on") == true && background().current?.more == 3 && state() == .changing,
                    "A scheduled run that started after the other work is the newest")
        store.scheduleRuns["overview-morning"]![0].startedAt = asked.addingTimeInterval(-300)
        try require(background().current?.line == "Writing Workshop plan and 3 more",
                    "A scheduled run that started before the other work is counted, not named")
        store.scheduleRuns = [:]
        store.schedules = []
        store.conversations[0].messages = []
        store.nativeTaskReferences = [foreign, running]
        store.selectedID = thread.id
        try require(state() == .thinking, "A reply being written shows thinking while work runs")
        store.generating = false
        try require(state().working, "The end of the reply returns to working while work still runs")
        store.selectedID = "ordinary"
        store.generating = true
        store.nativeTaskReferences.append(decision)
        try require(state() == .needsYou, "A question takes precedence over running work")
        try require(background().current != nil, "The line stays while other work still runs")
        try require(store.companionBackgroundWaiting == .task(decision), "The question is findable")
        store.dotProfile.state = .paused
        try require(state() == .needsYou, "Pause cannot conceal an existing question")
        store.nativeTaskReferences = [running]
        try require(state().working, "Pause cannot claim running work has stopped")
        for status in ["queued", "blocked", "completed", "failed", "canceled"] {
            store.nativeTaskReferences = [try OngoingWorkFixture.reference(conversationID: thread.id, title: "Settled work", state: status)]
            try require(state() == .resting && background().current == nil, "Settled \(status) work shows no line and no working figure")
        }
        store.dotProfile.state = .active
        try require(state() == .ready && state(false) == .resting, "Settled work returns to idle or inactive rest")
        store.schedules = CompanionOverviewFixture.schedules()
        store.scheduleRuns = ["overview-other": [NativeScheduleRun(id: "foreign", scheduleID: "overview-other", scheduledFor: Date(), outcome: .running)]]
        try require(state() == .ready && background().current == nil, "An ordinary schedule does not animate the companion")
        store.scheduleRuns["overview-morning"] = [NativeScheduleRun(id: "owned", scheduleID: "overview-morning", scheduledFor: Date(), outcome: .running)]
        try require(state().working && background().current?.words.hasPrefix("Working on") == true, "A running companion schedule shows working and a line")
        store.scheduleRuns["overview-morning"]![0].outcome = .waiting
        try require(state() == .needsYou && background().current == nil, "A companion schedule waiting for an answer shows the question state")
        store.scheduleRuns["overview-morning"]![0].outcome = .completed
        try require(state() == .ready && background().current == nil, "A completed schedule clears the working figure and the line")
        var completed = running
        let previous = running.snapshot!
        completed.snapshot = NativeTaskSnapshot(id: previous.id, workerType: previous.workerType, payload: previous.payload,
                                               state: .canceled, checkpoint: previous.checkpoint, result: nil, decision: nil,
                                               cancelRequested: true, generation: previous.generation, updatedAt: previous.updatedAt + 1)
        store.nativeTaskReferences = [completed]
        store.scheduleRuns["overview-morning"] = [NativeScheduleRun(id: "linked", scheduleID: "overview-morning", scheduledFor: Date(), outcome: .running, taskReferenceID: completed.id.uuidString)]
        try require(state() == .ready && background().current == nil, "A linked terminal task wins over a stale running schedule mirror")
        store.scheduleRuns = [:]
        let unrelatedVoice = CompanionPresence.snapshot(store: store, voiceCapturing: true, voicePlaying: true,
                                                       voiceConversationID: "ordinary")
        try require(CompanionStateMapper.state(unrelatedVoice) == .ready, "Ordinary voice cannot animate the companion")
        let listening = CompanionPresence.snapshot(store: store, voiceCapturing: true, voiceConversationID: thread.id)
        let speaking = CompanionPresence.snapshot(store: store, voicePlaying: true, voiceConversationID: thread.id)
        try require(CompanionStateMapper.state(listening) == .listening && CompanionStateMapper.state(speaking) == .speaking,
                    "Companion voice keeps its actual ownership after navigating to an ordinary chat")
        let presence = CompanionPresence(store: store)
        presence.start()
        defer { presence.stop() }
        store.generating = false
        store.nativeTaskReferences = [running]
        for _ in 0..<100 where !presence.state.working { try await Task.sleep(for: .milliseconds(5)) }
        try require(presence.state.working, "Work starting updates the visible figure")
        store.nativeTaskReferences = [completed]
        for _ in 0..<100 where presence.state.working { try await Task.sleep(for: .milliseconds(5)) }
        try require(!presence.state.working, "Work finishing clears the working figure without navigation")
        store.dotProfile.state = .paused
        for _ in 0..<100 where presence.state != .resting { try await Task.sleep(for: .milliseconds(5)) }
        try require(presence.state == .resting, "Profile publisher applies paused idle state")
        print("  companion presence OK (working by kind, the line, questions, schedule mirrors, pause, publisher updates)")
    }
}
