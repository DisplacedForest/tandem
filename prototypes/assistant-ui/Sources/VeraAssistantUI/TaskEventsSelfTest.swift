import Foundation

private actor TaskEventsFixture {
    let http = ContractFixture()
    private var streams: [AsyncThrowingStream<AssistantTaskEvent, Error>.Continuation] = []
    private var held: CheckedContinuation<Void, Never>?
    private var holdNext = false
    private var resetNext = false
    private var readsFail = false
    private var foreignTask = false
    var cursors: [Int64] = []
    var transcriptReads = 0
    var requestedConversations: [String] = []
    var writes = 0
    var terminations = 0
    var waiting = false

    func bind(_ assistant: UUID, _ conversation: UUID) async { await http.bind(assistant, conversation) }
    func taskID() -> String { http.taskID }
    func setState(_ value: String) async { await http.pollingTaskState(value) }
    func setText(_ value: String) async {
        let id = http.taskID
        await http.pollingTranscript([Message(id: "handoff", role: "assistant", text: value, taskIDs: [id])])
    }
    func holdTranscript() { holdNext = true; waiting = false }
    func release() { held?.resume(); held = nil; waiting = false }
    func failReads(_ value: Bool) { readsFail = value }
    func includeForeignTask() { foreignTask = true }
    func resetOnReconnect() { resetNext = true; streams.last?.finish(throwing: PrototypeError.unavailable) }
    func disconnect() { streams.last?.finish(throwing: PrototypeError.unavailable) }
    func emit(_ id: Int64, taskID: String? = nil, stream: Int? = nil) async {
        let task = taskID ?? http.taskID
        let event = AssistantTaskEvent(id: id, taskID: task)
        guard !streams.isEmpty else { return }
        streams[stream ?? streams.count - 1].yield(event)
    }
    func burst(_ range: ClosedRange<Int64>) async {
        let task = http.taskID
        for id in range { streams.last?.yield(AssistantTaskEvent(id: id, taskID: task)) }
    }
    func events(_ cursor: Int64) throws -> AsyncThrowingStream<AssistantTaskEvent, Error> {
        cursors.append(cursor)
        if resetNext { resetNext = false; throw AssistantTaskEventError.cursorReset }
        let pair = AsyncThrowingStream<AssistantTaskEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.terminated() } }
        streams.append(pair.continuation)
        return pair.stream
    }
    private func terminated() { terminations += 1 }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.httpMethod == "POST" { writes += 1 }
        if readsFail { throw PrototypeError.unavailable }
        var result = try await http.send(request)
        if request.url?.path == "/tasks", foreignTask {
            var object = try JSONSerialization.jsonObject(with: result.0) as! [String: Any]
            var tasks = object["tasks"] as! [[String: Any]]
            var other = tasks[0]
            other["id"] = UUID().uuidString.lowercased()
            var payload = other["payload"] as! [String: Any]
            payload["assistant_id"] = UUID().uuidString.lowercased()
            other["payload"] = payload
            tasks.append(other)
            object["tasks"] = tasks
            result.0 = try JSONSerialization.data(withJSONObject: object)
        }
        if request.url?.path == "/assistant/messages", request.httpMethod != "POST" {
            transcriptReads += 1
            requestedConversations.append(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)
            if holdNext {
                holdNext = false
                waiting = true
                await withCheckedContinuation { held = $0 }
            }
        }
        return result
    }
}

@MainActor
enum TaskEventsSelfTest {
    static func wait(_ name: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PrototypeSelfTest.Failure(name: name)
    }

    static func run(root: URL) async throws {
        let endpoint = URL(string: "http://127.0.0.1:49152")!
        let fixture = TaskEventsFixture()
        let state = root.appendingPathComponent("state")
        let workspace = try AssistantWorkspace(dataRoot: state, endpoint: endpoint, workspaceRoot: root,
            runtimeIdentity: "event-test", events: { try await fixture.events($0) }) { try await fixture.send($0) }
        let session = workspace.session
        try milestones()
        await fixture.bind(workspace.assistantID, session.id)
        await fixture.setText("Handoff")
        session.startEventTracking()
        try await wait("Tracking starts from legacy zero") { await fixture.cursors == [0] }
        let id = await fixture.taskID()
        try PrototypeSelfTest.require(session.messages.first?.taskIDs == [id]
            && session.tasks.first?.originatingMessageID != nil, "Handoff associations survive the facade")
        let idleReads = await fixture.transcriptReads
        await session.poll()
        try PrototypeSelfTest.require(await fixture.transcriptReads == idleReads, "Healthy event tracking suppresses timer polling")
        await fixture.burst(1...100)
        try await wait("Burst reconciles through high-water event") { session.savedEventCursor == 100 }
        try PrototypeSelfTest.require(await fixture.transcriptReads <= idleReads + 2, "Event bursts coalesce bounded snapshot work")
        try PrototypeSelfTest.require(session.tasks.first?.state == "needs_decision", "Events never imply approval or completion")
        let dedupReads = await fixture.transcriptReads
        await fixture.emit(100)
        await fixture.emit(3)
        try await Task.sleep(for: .milliseconds(100))
        try PrototypeSelfTest.require(await fixture.transcriptReads == dedupReads, "Duplicate and older events do not refetch")

        await fixture.setState("running")
        await fixture.setText("Worker continues")
        workspace.store.newChat()
        await fixture.includeForeignTask()
        await fixture.emit(101, taskID: UUID().uuidString)
        try await wait("Event refresh remains active off assistant destination") { session.savedEventCursor == 101 }
        try PrototypeSelfTest.require(session.messages.first?.text == "Worker continues"
            && session.tasks.first?.state == "running" && session.tasks.count == 2,
            "Snapshots, not events, determine scoped task and transcript content")
        try PrototypeSelfTest.require(await fixture.requestedConversations.allSatisfy { UUID(uuidString: $0) == session.id },
            "Event reconciliation only fetches the bound assistant transcript")
        session.select()
        let failedConnections = await fixture.cursors.count
        await fixture.failReads(true)
        await fixture.emit(102)
        try await wait("Snapshot failure surfaces without cursor advancement") { session.error != nil }
        try PrototypeSelfTest.require(session.savedEventCursor == 101, "Failed authoritative fetch cannot acknowledge an event")
        await fixture.failReads(false)
        await session.poll()
        try PrototypeSelfTest.require(session.connected, "Poll fallback remains usable after stream reconciliation failure")
        try await wait("Snapshot failure reconnects from committed cursor") { await fixture.cursors.count > failedConnections }
        await fixture.emit(102)
        try await wait("Failed snapshot event replays") { session.savedEventCursor == 102 }
        await fixture.disconnect()
        try await wait("Disconnect resumes from committed cursor") { await fixture.cursors.last == 102 }
        await fixture.resetOnReconnect()
        try await wait("Ahead-of-store cursor resets after full reconciliation") {
            let cursor = await fixture.cursors.last
            return session.savedEventCursor == 0 && cursor == 0
        }
        await fixture.emit(5)
        try await wait("Events advance after reset") { session.savedEventCursor == 5 }

        let stateURL = state.appendingPathComponent("assistant-ui.json")
        let hardLink = root.appendingPathComponent("held-state.json")
        try FileManager.default.linkItem(at: stateURL, to: hardLink)
        await fixture.emit(6)
        try await wait("Persistence failure reaches safe unavailable state") { session.error != nil }
        try PrototypeSelfTest.require(session.savedEventCursor == 5, "Failed cursor persistence cannot acknowledge an event")
        try FileManager.default.removeItem(at: hardLink)
        try await wait("Failed batch reconnects without advancing") { (await fixture.cursors.filter { $0 == 5 }.count) > 0 && session.error == nil }
        await fixture.emit(6)
        try await wait("Failed event remains replayable") { session.savedEventCursor == 6 }

        await fixture.holdTranscript()
        await fixture.setText("Stale callback")
        await fixture.emit(7)
        try await wait("Snapshot callback held before stop") { await fixture.waiting }
        let stoppedAt = ContinuousClock.now
        await session.stopEventTracking()
        try PrototypeSelfTest.require(stoppedAt.duration(to: .now) < .seconds(1), "Tracking shutdown is bounded")
        let previousConnections = await fixture.cursors.count
        await fixture.setText("New generation reply")
        session.startEventTracking()
        try await wait("New generation reconciles while old HTTP callback remains held") { await fixture.cursors.count > previousConnections }
        try PrototypeSelfTest.require(session.messages.first?.text == "New generation reply", "Old refresh lock cannot block new generation")
        await fixture.release()
        await fixture.emit(8, stream: 0)
        try await Task.sleep(for: .milliseconds(100))
        try PrototypeSelfTest.require(session.savedEventCursor == 6 && session.messages.first?.text == "New generation reply",
            "Old generation snapshots and events cannot publish after stop")
        await session.stopEventTracking()
        let disk = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
        try PrototypeSelfTest.require(disk.taskEventCursor == 6 && disk.runtimeIdentity == "event-test", "Cursor persists with stable runtime identity")

        let restoredFixture = TaskEventsFixture()
        let restored = try AssistantWorkspace(dataRoot: state, endpoint: URL(string: "http://127.0.0.1:49153")!,
            workspaceRoot: root, runtimeIdentity: "event-test", events: { try await restoredFixture.events($0) }) { try await restoredFixture.send($0) }
        await restoredFixture.bind(restored.assistantID, restored.session.id)
        await restoredFixture.setText("Restored authoritative reply")
        restored.startEventTracking()
        try await wait("Restart resumes committed cursor after authoritative refresh") { await restoredFixture.cursors == [6] }
        try PrototypeSelfTest.require(restored.session.id == session.id && restored.session.messages.first?.text == "Restored authoritative reply",
            "Restart uses authoritative transcript with stable identity and changed loopback port")
        await restored.stopEventTracking()
        let originalWrites = await fixture.writes
        let restoredWrites = await restoredFixture.writes
        try PrototypeSelfTest.require(originalWrites == 0 && restoredWrites == 0, "Tracking never sends messages or decisions")
        do {
            _ = try AssistantWorkspace(dataRoot: state, endpoint: endpoint, workspaceRoot: root,
                runtimeIdentity: "different-runtime") { try await fixture.send($0) }
            throw PrototypeSelfTest.Failure(name: "Different runtime adopted event cursor")
        } catch PrototypeError.configuration { }
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
        legacy.removeValue(forKey: "taskEventCursor")
        try JSONSerialization.data(withJSONObject: legacy).write(to: stateURL, options: .atomic)
        let reopened = try AssistantWorkspace(dataRoot: state, endpoint: endpoint, workspaceRoot: root,
            runtimeIdentity: "event-test") { try await fixture.send($0) }
        try PrototypeSelfTest.require(reopened.session.savedEventCursor == 0, "Legacy state without cursor decodes as zero")
        print("PASS: task event coalescing, snapshot authority, scope, cursor replay/reset, persistence failure, stale callback fencing and bounded shutdown")
    }

    static func milestones() throws {
        var object: [String: Any] = ["id": UUID().uuidString, "worker_type": "pi_worker", "payload": [:],
            "state": "running", "cancel_requested": false, "updated_at": 0]
        func snapshot() throws -> TaskSnapshot {
            try JSONDecoder().decode(TaskSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
        try PrototypeSelfTest.require(try snapshot().milestone.isEmpty, "Missing checkpoint cannot invent running detail")
        object["checkpoint"] = ["approved": true, "internal_phase": "not user copy"]
        try PrototypeSelfTest.require(try snapshot().milestone == "Working in the task workspace.", "Approved running checkpoint permits grounded milestone")
        object["cancel_requested"] = true
        try PrototypeSelfTest.require(try snapshot().milestone.isEmpty, "Cancel request suppresses active work milestone")
        object["state"] = "needs_decision"
        object["decision"] = ["id": UUID().uuidString, "prompt": "Review saved edits before continuing?"]
        object["result"] = ["summary": "Prior summary"]
        try PrototypeSelfTest.require(try snapshot().milestone == "Review saved edits before continuing?", "Current decision takes precedence over old summary")
        object["state"] = "completed"
        try PrototypeSelfTest.require(try snapshot().milestone == "Prior summary", "Completion uses server result summary")
    }
}
