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
        store.generating = true
        store.nativeTaskReferences = [foreign]
        try require(state() == .ready && background().isEmpty, "Work from an ordinary conversation is not the companion's background work")
        store.nativeTaskReferences.append(running)
        try require(state() == .ready && state(false) == .resting, "Running background work does not show the companion as thinking")
        try require(background() == CompanionBackgroundWork(running: 1, needsAnswer: 0), "Running background work is counted on its own")
        try require(background().runningLine == "1 thing running in the background" && background().answerLine == nil,
                    "One running piece of work has its own line")
        store.selectedID = thread.id
        try require(state() == .thinking, "A reply being written shows thinking while background work runs")
        store.generating = false
        try require(state() == .ready, "The end of the reply returns to idle while background work still runs")
        store.selectedID = "ordinary"
        store.generating = true
        store.nativeTaskReferences.append(decision)
        try require(state() == .ready, "A background question does not change the conversation's state")
        try require(background() == CompanionBackgroundWork(running: 1, needsAnswer: 1), "A background question is counted on its own")
        try require(background().answerLine == "1 thing in the background needs your answer", "A background question has its own line")
        try require(store.companionBackgroundWaiting == .task(decision), "The background question is findable")
        store.revealCompanionBackgroundWaiting()
        try require(store.selectedID == thread.id && store.pendingTaskReveal == decision.id.uuidString,
                    "The background line opens the card with the question")
        store.pendingTaskReveal = nil
        store.selectedID = "ordinary"
        store.nativeTaskReferences.append(try OngoingWorkFixture.reference(conversationID: thread.id, title: "Read the appendix", state: "running"))
        store.nativeTaskReferences.append(try OngoingWorkFixture.reference(conversationID: thread.id, title: "Review the appendix",
                                                                         state: "needs_decision", decision: OngoingWorkFixture.decision))
        try require(background().runningLine == "2 things running in the background"
                    && background().answerLine == "2 things in the background need your answer", "Several pieces of work are counted")
        store.nativeTaskReferences = [foreign, running, decision]
        store.dotProfile.state = .paused
        try require(state() == .resting && background() == CompanionBackgroundWork(running: 1, needsAnswer: 1),
                    "Pause rests the companion and leaves the background lines truthful")
        for status in ["queued", "blocked", "completed", "failed", "canceled"] {
            store.nativeTaskReferences = [try OngoingWorkFixture.reference(conversationID: thread.id, title: "Settled work", state: status)]
            try require(state() == .resting && background().isEmpty, "Settled \(status) work has no background line")
        }
        store.dotProfile.state = .active
        try require(state() == .ready && state(false) == .resting, "Settled companion work returns to idle or inactive rest")
        store.schedules = CompanionOverviewFixture.schedules()
        store.scheduleRuns = ["overview-other": [NativeScheduleRun(id: "foreign", scheduleID: "overview-other", scheduledFor: Date(), outcome: .running)]]
        try require(state() == .ready && background().isEmpty, "An ordinary schedule is not the companion's background work")
        store.scheduleRuns["overview-morning"] = [NativeScheduleRun(id: "owned", scheduleID: "overview-morning", scheduledFor: Date(), outcome: .running)]
        try require(state() == .ready && background() == CompanionBackgroundWork(running: 1, needsAnswer: 0),
                    "A running companion schedule is background work, not thinking")
        store.scheduleRuns["overview-morning"]![0].outcome = .waiting
        try require(state() == .ready && background() == CompanionBackgroundWork(running: 0, needsAnswer: 1),
                    "A companion schedule with a question is on the background line, not the conversation's state")
        store.scheduleRuns["overview-morning"]![0].outcome = .completed
        try require(state() == .ready && background().isEmpty, "A completed schedule clears the background line")
        var completed = running
        let previous = running.snapshot!
        completed.snapshot = NativeTaskSnapshot(id: previous.id, workerType: previous.workerType, payload: previous.payload,
                                               state: .canceled, checkpoint: previous.checkpoint, result: nil, decision: nil,
                                               cancelRequested: true, generation: previous.generation, updatedAt: previous.updatedAt + 1)
        store.nativeTaskReferences = [completed]
        store.scheduleRuns["overview-morning"] = [NativeScheduleRun(id: "linked", scheduleID: "overview-morning", scheduledFor: Date(), outcome: .running, taskReferenceID: completed.id.uuidString)]
        try require(state() == .ready && background().isEmpty, "A linked terminal task wins over a stale running schedule mirror")
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
        try await Task.sleep(for: .milliseconds(60))
        try require(presence.state != .thinking && presence.state != .needsYou, "Background work arriving leaves the visible presence idle")
        store.selectedID = thread.id
        store.generating = true
        for _ in 0..<100 where presence.state != .thinking { try await Task.sleep(for: .milliseconds(5)) }
        try require(presence.state == .thinking, "A reply in the companion conversation updates the visible presence")
        store.generating = false
        for _ in 0..<100 where presence.state == .thinking { try await Task.sleep(for: .milliseconds(5)) }
        try require(presence.state != .thinking, "The end of the reply clears visible thinking while background work runs")
        store.dotProfile.state = .paused
        for _ in 0..<100 where presence.state != .resting { try await Task.sleep(for: .milliseconds(5)) }
        try require(presence.state == .resting, "Profile publisher applies paused idle state")
        print("  companion presence OK (replies only, background lines, schedule mirrors, pause, publisher updates)")
    }
}
