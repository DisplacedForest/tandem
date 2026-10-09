import Combine
import Foundation

private actor PollingGate {
    var holding = false
    var entered = false
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() { holding = true; entered = false }
    func wait() async {
        calls += 1
        guard holding else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { holding = false; continuation?.resume(); continuation = nil }
}

extension ContractFixture {
    func pollingTaskState(_ value: String) { taskStates[taskID] = value }
    func pollingTranscript(_ messages: [Message]) { replies[boundConversation!] = messages }
}

@MainActor
enum PollingSelfTest {
    static func run(root: URL) async throws {
        let fixture = ContractFixture()
        let gate = PollingGate()
        let endpoint = URL(string: "http://127.0.0.1:49152")!
        let configuration = try PrototypeConfiguration(dataRoot: root, endpoint: endpoint, workspaceRoot: nil)
        let client = PrototypeClient(base: endpoint) { request in
            if request.url?.path == "/assistant/capabilities" { await gate.wait() }
            return try await fixture.send(request)
        }
        let store = try PrototypeStore(configuration: configuration, client: client)
        let session = AssistantSession(store: store)
        await fixture.bind(store.saved.assistantID, session.id)
        await session.poll()
        var changes = 0
        var progress: [Bool] = []
        let observation = session.objectWillChange.sink { MainActor.assumeIsolated { changes += 1 } }
        let busy = store.$refreshing.dropFirst().sink { value in MainActor.assumeIsolated { progress.append(value) } }
        defer { observation.cancel(); busy.cancel() }
        for _ in 0..<3 { await session.poll() }
        try PrototypeSelfTest.require(changes == 0 && progress.isEmpty, "Identical polls do not invalidate rendered state or publish progress")

        await fixture.pollingTaskState("running")
        await session.poll()
        try PrototypeSelfTest.require(changes == 1 && session.tasks.first?.state == "running", "Changed task state propagates")
        changes = 0
        await fixture.pollingTranscript([Message(id: "reply", role: "assistant", text: "First reply", taskIDs: [])])
        await session.poll()
        try PrototypeSelfTest.require(changes == 1 && session.messages.first?.text == "First reply", "New transcript propagates")
        changes = 0
        await fixture.pollingTranscript([Message(id: "reply", role: "assistant", text: "Updated reply", taskIDs: [])])
        await session.poll()
        try PrototypeSelfTest.require(changes == 1 && session.messages.first?.text == "Updated reply", "Changed existing message propagates")
        changes = 0
        await fixture.advertise(try JSONSerialization.data(withJSONObject: ["protocol_version": 1, "foreground": false,
            "worker": true, "computers": false, "transport": "mock"]))
        await session.poll()
        try PrototypeSelfTest.require(changes == 1 && store.capabilities?.foreground == false, "Changed capabilities propagate")
        changes = 0
        await fixture.setOffline(true)
        await session.poll()
        try PrototypeSelfTest.require(changes == 1 && !session.connected && session.error != nil, "New connection error propagates")
        changes = 0
        await session.poll()
        try PrototypeSelfTest.require(changes == 0, "Repeated identical connection error does not invalidate")
        await fixture.setOffline(false)
        await session.poll()
        try PrototypeSelfTest.require(changes == 1 && session.connected && session.error == nil, "Connection recovery propagates")
        changes = 0
        await session.refresh()
        try PrototypeSelfTest.require(changes == 2 && progress == [true, false], "Explicit refresh preserves progress publication")
        changes = 0
        progress = []
        await gate.hold()
        let polling = Task { await session.poll() }
        for _ in 0..<1000 {
            if await gate.entered { break }
            await Task.yield()
        }
        try PrototypeSelfTest.require(await gate.entered, "Polling request reached gate")
        let calls = await gate.calls
        await session.poll()
        try PrototypeSelfTest.require(await gate.calls == calls && !store.refreshing, "Polling serializes automatic refresh without visible progress")
        await gate.release()
        await polling.value
        try PrototypeSelfTest.require(changes == 0 && progress.isEmpty, "Completing an identical held poll stays silent")
        await session.refresh()
        try PrototypeSelfTest.require(progress == [true, false], "Manual progress resumes after polling finishes")
        progress = []
        await gate.hold()
        let beforeManual = Task { await session.poll() }
        for _ in 0..<1000 {
            if await gate.entered { break }
            await Task.yield()
        }
        try PrototypeSelfTest.require(await gate.entered, "Poll before explicit refresh reached gate")
        let manual = Task { await session.refresh() }
        for _ in 0..<1000 where !store.refreshing { await Task.yield() }
        try PrototypeSelfTest.require(store.refreshing && progress == [true], "Explicit refresh shows busy while waiting for polling")
        await gate.release()
        await beforeManual.value
        await manual.value
        try PrototypeSelfTest.require(progress == [true, false] && !store.refreshing, "Queued explicit refresh completes and clears busy")

        await fixture.advertise(try JSONSerialization.data(withJSONObject: ["protocol_version": 1, "foreground": true,
            "worker": true, "computers": false, "transport": "mock"]))
        await session.poll()
        session.setDraft("Unconfirmed work")
        await fixture.interruptNextMessage()
        await session.send()
        guard let pending = session.pendingID else { throw PrototypeError.invalidResponse }
        let requests = await fixture.requests.count
        await gate.hold()
        let beforeReview = Task { await session.poll() }
        for _ in 0..<1000 {
            if await gate.entered { break }
            await Task.yield()
        }
        try PrototypeSelfTest.require(await gate.entered, "Poll before review reached gate")
        let review = Task { await session.review(messageID: pending) }
        for _ in 0..<1000 where !session.reviewing { await Task.yield() }
        try PrototypeSelfTest.require(session.reviewing && !session.canContinue, "Explicit review waits visibly for polling")
        await gate.release()
        await beforeReview.value
        await review.value
        try PrototypeSelfTest.require(session.canContinue && !session.reviewing && session.pendingID == pending,
            "Review queued during polling performs inspection and retains request identity")
        try PrototypeSelfTest.require(await fixture.requests.count == requests, "Queued review never resends a message")
        print("PASS: silent identical polling, changed snapshots and errors, explicit refresh progress and in-flight serialization")
    }
}
