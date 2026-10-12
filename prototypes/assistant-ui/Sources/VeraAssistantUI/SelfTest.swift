import Foundation

actor ContractFixture {
    var requests: [MessageRequest] = []
    var decisions: [DecisionRequest] = []
    var cancellations: [String] = []
    var replies: [UUID: [Message]] = [:]
    var boundAssistant: UUID?
    var boundConversation: UUID?
    var failAfterAccept = false
    var failDecisionAfterAccept = false
    var messageDelay = false
    var rejectMessage = false
    var interruptMessage = false
    var interruptedIDs = Set<UUID>()
    var offline = false
    var capabilityResponse: Data?
    var originatingMessageID = UUID()
    let unrelatedOriginID = UUID()
    var taskStates: [String: String] = [:]
    let taskID = UUID().uuidString.lowercased()
    let secondTaskID = UUID().uuidString.lowercased()
    let decisionID = UUID().uuidString.lowercased()

    func bind(_ assistant: UUID, _ conversation: UUID) { boundAssistant = assistant; boundConversation = conversation }
    func interruptNextMessage() { interruptMessage = true }
    func advertise(_ data: Data) { capabilityResponse = data }
    func setOffline(_ value: Bool) { offline = value }
    func loseMessageReply() { failAfterAccept = true }
    func rejectNextMessage() { rejectMessage = true }
    func delayMessages() { messageDelay = true }
    func loseDecisionReply() { failDecisionAfterAccept = true }

    func response(_ object: Any, status: Int = 200) throws -> (Data, Int) {
        (try JSONSerialization.data(withJSONObject: object), status)
    }

    func task(_ id: String, state: String? = nil) -> [String: Any] {
        ["id": id, "worker_type": "pi_worker", "payload": ["assistant_id": boundAssistant!.uuidString.lowercased(),
            "conversation_id": boundConversation!.uuidString.lowercased(), "originating_message_id": (id == taskID ? originatingMessageID : unrelatedOriginID).uuidString.lowercased(), "objective": id == taskID ? "Compare workshop insulation" : "Measure wall area"],
         "state": state ?? taskStates[id] ?? "needs_decision", "cancel_requested": false, "updated_at": 123.0,
         "decision": ["id": decisionID, "prompt": "Read the project files?", "choices": ["approve", "decline"]],
         "result": NSNull()]
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if offline { throw PrototypeError.unavailable }
        let path = request.url!.path
        switch path {
        case "/assistant/capabilities":
            if let capabilityResponse { return (capabilityResponse, 200) }
            return try response(["protocol_version": 1, "foreground": true, "worker": true, "computers": false, "transport": "mock"])
        case "/assistant/messages" where request.httpMethod == "POST":
            let body = try JSONDecoder().decode(MessageRequest.self, from: request.httpBody!)
            if rejectMessage { rejectMessage = false; return try response(["detail": "Rejected"], status: 422) }
            requests.append(body)
            if interruptedIDs.contains(body.messageID) { return try response(["detail": "Interrupted"], status: 409) }
            if interruptMessage {
                interruptMessage = false
                interruptedIDs.insert(body.messageID)
                originatingMessageID = body.messageID
                replies[body.conversationID, default: []].append(Message(id: body.messageID.uuidString.lowercased(), role: "user", text: body.text, taskIDs: [taskID]))
                throw PrototypeError.unavailable
            }
            if messageDelay { try await Task.sleep(for: .milliseconds(60)) }
            let replyID = "reply-" + body.messageID.uuidString.lowercased()
            if !(replies[body.conversationID] ?? []).contains(where: { $0.id == replyID }) {
                replies[body.conversationID, default: []].append(Message(id: body.messageID.uuidString.lowercased(), role: "user", text: body.text, taskIDs: []))
                replies[body.conversationID, default: []].append(Message(id: replyID, role: "assistant", text: "Recorded: " + body.text, taskIDs: []))
            }
            if failAfterAccept { failAfterAccept = false; throw PrototypeError.unavailable }
            return try response(["message_id": body.messageID.uuidString.lowercased(), "reply_id": replyID, "text": "Recorded: " + body.text, "task_ids": []])
        case "/assistant/messages":
            let raw = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            return (try JSONEncoder().encode(["messages": replies[UUID(uuidString: raw)!] ?? []]), 200)
        case "/tasks": return try response(["tasks": [task(taskID), task(secondTaskID)]])
        case "/tasks/\(taskID)/cancel", "/tasks/\(secondTaskID)/cancel":
            let id = request.url!.deletingLastPathComponent().lastPathComponent
            cancellations.append(id)
            taskStates[id] = "canceled"
            return try response(task(id))
        case "/tasks/\(taskID)/decision":
            let body = try JSONDecoder().decode(DecisionRequest.self, from: request.httpBody!)
            decisions.append(body)
            if failDecisionAfterAccept { failDecisionAfterAccept = false; throw PrototypeError.unavailable }
            taskStates[taskID] = "queued"
            return try response(task(taskID))
        default: throw PrototypeError.invalidResponse
        }
    }
}

enum PrototypeSelfTest {
    static func require(_ value: Bool, _ name: String) throws {
        if !value { throw Failure(name: name) }
    }
    struct Failure: Error, LocalizedError {
        let name: String
        var errorDescription: String? { name }
    }

    @MainActor static func run() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vera-ui-selftest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let endpoint = URL(string: "http://127.0.0.1:49152")!
            let configuration = try PrototypeConfiguration(dataRoot: root.appendingPathComponent("state"), endpoint: endpoint, workspaceRoot: root.appendingPathComponent("outputs"))
            let fixture = ContractFixture()
            let client = PrototypeClient(base: endpoint) { try await fixture.send($0) }
            let store = try PrototypeStore(configuration: configuration, client: client)
            await fixture.bind(store.saved.assistantID, store.saved.assistant.id)
            store.setDraft("Compare workshop insulation")
            store.newChat()
            let focusedID = store.conversation.id
            try require(focusedID != store.saved.assistant.id, "Focused chat uses a separate identity")
            store.setDraft("One quick question")
            store.destination = .assistant
            try require(store.conversation.draft == "Compare workshop insulation", "Vera draft survives navigation")
            let reopened = try PrototypeStore(configuration: configuration, client: client)
            try require(reopened.saved.assistantID == store.saved.assistantID && reopened.saved.assistant.id == store.saved.assistant.id, "Assistant identity survives restart")
            try require(reopened.saved.conversations.first?.draft == "One quick question", "Focused draft survives restart")
            await store.refresh()
            try require(store.connectionLabel == "Test runtime" && store.visibleTasks.count == 2, "Mock runtime and task scope")
            store.setDraft(String(repeating: "e\u{301}", count: 4001))
            await store.send()
            let oversizedRequests = await fixture.requests
            try require(store.pending == nil && oversizedRequests.isEmpty, "Unicode scalar limit rejects oversize text before sending")
            store.setDraft("Editable rejected message")
            await fixture.rejectNextMessage()
            await store.send()
            try require(store.pending == nil && store.conversation.draft == "Editable rejected message", "Definitive rejection preserves editable draft without retry lock")
            store.setDraft("Compare workshop insulation")
            await fixture.loseMessageReply()
            await store.send()
            try require(store.pending != nil, "Ambiguous response retains idempotent request")
            await store.refresh()
            try require(store.messages.count == 2, "Accepted message restored from runtime")
            let retryStore = try PrototypeStore(configuration: configuration, client: client)
            await retryStore.refresh()
            await retryStore.retry()
            try require(retryStore.messages.count == 2 && retryStore.pending == nil, "Retry deduplicates lowercase server UUID")
            let sent = await fixture.requests
            try require(sent.count == 2 && sent[0].messageID == sent[1].messageID && sent[0].mode == "assistant", "Retry preserves request identity and mode")
            retryStore.destination = .conversation(focusedID)
            await retryStore.refresh()
            try require(retryStore.visibleTasks.isEmpty, "Focused chat hides other conversation tasks")
            await fixture.delayMessages()
            let send = Task { await retryStore.send() }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
            retryStore.destination = .assistant
            retryStore.setDraft("Unrelated draft")
            await send.value
            try require(retryStore.conversation.draft == "Unrelated draft", "Background reply preserves current destination draft")
            let focusedRequest = await fixture.requests.last
            try require(focusedRequest?.mode == "focused" && focusedRequest?.conversationID == focusedID, "Focused request contract")
            await retryStore.refresh()
            let decisionTask = retryStore.visibleTasks[0]
            await fixture.loseDecisionReply()
            await retryStore.reply(decisionTask, approved: true)
            let decisionRestart = try PrototypeStore(configuration: configuration, client: client)
            await decisionRestart.refresh()
            await decisionRestart.reply(decisionRestart.visibleTasks[0], approved: true)
            let decisions = await fixture.decisions
            try require(decisions.count == 2 && decisions[0].idempotencyKey == decisions[1].idempotencyKey, "Decision retry survives restart with same key")
            let second = decisionRestart.visibleTasks[1]
            await decisionRestart.stop(second)
            let cancels = await fixture.cancellations
            try require(cancels == [second.id], "Stop targets only selected task")
            try require(decisionRestart.visibleTasks[1].status == "Stopped" && decisionRestart.visibleTasks[0].state == "queued", "Stop preserves other task")
            let outputs = root.appendingPathComponent("outputs")
            try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
            try Data("result".utf8).write(to: outputs.appendingPathComponent("report.txt"))
            let good = TaskArtifact(kind: "file", path: "report.txt", title: "Report")
            try require(good.resolved(in: outputs) != nil, "Existing task output resolves")
            try require(TaskArtifact(kind: "file", path: "../state/assistant-ui.json", title: "Escape").resolved(in: outputs) == nil, "Traversal rejected")
            try FileManager.default.createSymbolicLink(at: outputs.appendingPathComponent("escape"), withDestinationURL: root.appendingPathComponent("state/assistant-ui.json"))
            try require(TaskArtifact(kind: "file", path: "escape", title: "Escape").resolved(in: outputs) == nil, "Symlink escape rejected")
            try require(TaskArtifact(kind: "file", path: "missing", title: "Missing").resolved(in: outputs) == nil, "Missing output stays unavailable")
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outside.appendingPathComponent("report.txt"))
            let swapped = root.appendingPathComponent("swapped")
            try FileManager.default.createDirectory(at: swapped, withIntermediateDirectories: true)
            let pinned = swapped.resolvingSymlinksInPath()
            try FileManager.default.moveItem(at: swapped, to: root.appendingPathComponent("original-output"))
            try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: outside)
            try require(good.resolved(in: pinned) == nil, "Replaced workspace root cannot expand output authority")
            do {
                _ = try PrototypeConfiguration(dataRoot: root.appendingPathComponent("bad"), endpoint: URL(string: "https://example.com"), workspaceRoot: nil)
                throw Failure(name: "Remote runtime accepted")
            } catch is PrototypeError { }
            do {
                _ = try PrototypeStore(configuration: PrototypeConfiguration(dataRoot: configuration.dataRoot, endpoint: URL(string: "http://127.0.0.1:49153"), workspaceRoot: nil))
                throw Failure(name: "State reused for another runtime")
            } catch is PrototypeError { }
            let linked = root.appendingPathComponent("linked")
            try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("assistant-ui.json"), withDestinationURL: configuration.dataRoot.appendingPathComponent("assistant-ui.json"))
            do {
                _ = try PrototypeStore(configuration: PrototypeConfiguration(dataRoot: linked, endpoint: endpoint, workspaceRoot: nil))
                throw Failure(name: "State symlink accepted")
            } catch is PrototypeError { }
            let offline = try PrototypeStore(configuration: PrototypeConfiguration(dataRoot: root.appendingPathComponent("offline"), endpoint: nil, workspaceRoot: nil))
            try require(!offline.canSend && offline.capabilities == nil && offline.visibleTasks.isEmpty, "Offline has no invented capabilities or tasks")
            if let index = CommandLine.arguments.firstIndex(of: "--render-dir"), index + 1 < CommandLine.arguments.count {
                try RenderTest.render(decisionRestart, directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            }
            try await CapabilitySelfTest.run(root: root.appendingPathComponent("capabilities"))
            try await FacadeSelfTest.run(root: root.appendingPathComponent("facade"))
            try await AssistantSessionSelfTest.run(root: root.appendingPathComponent("native-session"))
            try await PollingSelfTest.run(root: root.appendingPathComponent("polling"))
            try await TaskEventsSelfTest.run(root: root.appendingPathComponent("task-events"))
            try await RecoverySelfTest.run(root: root.appendingPathComponent("recovery"))
            print("PASS: identity, navigation, drafts, scoped messages/tasks, lost-response restart retry, decision retry, Stop isolation, output paths, unavailable state")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
