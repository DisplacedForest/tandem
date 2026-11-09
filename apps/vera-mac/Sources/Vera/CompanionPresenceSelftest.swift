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
        store.generating = true
        store.nativeTaskReferences = [foreign]
        try require(state() == .ready, "An ordinary foreground or background task cannot animate the companion")
        store.nativeTaskReferences.append(running)
        try require(state() == .thinking && state(false) == .thinking, "Actual companion work remains visible after navigation or app deactivation")
        store.nativeTaskReferences.append(decision)
        try require(state() == .needsYou, "A companion decision takes precedence over other running work")
        store.dotProfile.state = .paused
        try require(state() == .needsYou, "Pause cannot conceal an existing decision")
        store.nativeTaskReferences = [running]
        try require(state() == .thinking, "Pause cannot claim an already running task has stopped")
        for status in ["queued", "blocked", "completed", "failed", "canceled"] {
            store.nativeTaskReferences = [try OngoingWorkFixture.reference(conversationID: thread.id, title: "Settled work", state: status)]
            try require(state() == .resting, "A paused companion is not busy for \(status) work")
        }
        store.dotProfile.state = .active
        try require(state() == .ready && state(false) == .resting, "Settled companion work returns to idle or inactive rest")
        store.schedules = CompanionOverviewFixture.schedules()
        store.scheduleRuns = ["overview-other": [NativeScheduleRun(id: "foreign", scheduleID: "overview-other", scheduledFor: Date(), outcome: .running)]]
        try require(state() == .ready, "An ordinary schedule does not animate the companion")
        store.scheduleRuns["overview-morning"] = [NativeScheduleRun(id: "owned", scheduleID: "overview-morning", scheduledFor: Date(), outcome: .running)]
        try require(state() == .thinking, "An active companion schedule animates its character")
        store.scheduleRuns["overview-morning"]![0].outcome = .waiting
        try require(state() == .needsYou, "A companion schedule waiting for input shows the decision state")
        store.scheduleRuns["overview-morning"]![0].outcome = .completed
        try require(state() == .ready, "A completed schedule clears working presence")
        var completed = running
        let previous = running.snapshot!
        completed.snapshot = NativeTaskSnapshot(id: previous.id, workerType: previous.workerType, payload: previous.payload,
                                               state: .canceled, checkpoint: previous.checkpoint, result: nil, decision: nil,
                                               cancelRequested: true, generation: previous.generation, updatedAt: previous.updatedAt + 1)
        store.nativeTaskReferences = [completed]
        store.scheduleRuns["overview-morning"] = [NativeScheduleRun(id: "linked", scheduleID: "overview-morning", scheduledFor: Date(), outcome: .running, taskReferenceID: completed.id.uuidString)]
        try require(state() == .ready, "A linked terminal task wins over a stale running schedule mirror")
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
        store.nativeTaskReferences = [running]
        for _ in 0..<100 where presence.state != .thinking { try await Task.sleep(for: .milliseconds(5)) }
        try require(presence.state == .thinking, "Task publisher updates the visible presence")
        store.nativeTaskReferences = [completed]
        for _ in 0..<100 where presence.state == .thinking { try await Task.sleep(for: .milliseconds(5)) }
        try require(presence.state != .thinking, "Completion publisher clears visible thinking without navigation")
        store.dotProfile.state = .paused
        for _ in 0..<100 where presence.state != .resting { try await Task.sleep(for: .milliseconds(5)) }
        try require(presence.state == .resting, "Profile publisher applies paused idle state")
        print("  companion presence OK (ownership, decisions, completion, schedule mirrors, pause, publisher updates)")
    }
}
