import Foundation

actor WorkspaceFixture {
    struct Work {
        let id: String
        let request: MessageRequest
        var state: String
    }
    var messages: [UUID: [Message]] = [:]
    var tasks: [Work] = []
    var paths: [String] = []
    var foregroundDuringWork = false
    var completionPolls: Int?
    let decisionID = UUID().uuidString.lowercased()
    let artifact: URL

    init(artifact: URL) { self.artifact = artifact }

    func task(_ value: Work) -> [String: Any] {
        ["id": value.id, "worker_type": "pi_worker", "state": value.state, "cancel_requested": false,
         "updated_at": Date().timeIntervalSince1970,
         "payload": ["assistant_id": value.request.assistantID.uuidString, "conversation_id": value.request.conversationID.uuidString,
                     "originating_message_id": value.request.messageID.uuidString, "objective": value.request.text],
         "decision": ["id": decisionID, "prompt": "Approve fixture work?"],
         "result": value.state == "completed" ? ["summary": "Fixture complete", "artifacts": [["kind": "file", "path": artifact.path, "title": "sum.py"]]] : NSNull()]
    }

    func send(_ request: URLRequest) throws -> (Data, Int) {
        guard request.value(forHTTPHeaderField: "Authorization") == nil else { throw PrototypeError.invalidResponse }
        let path = request.url!.path
        paths.append(path)
        var value: [String: Any]
        if path == "/assistant/capabilities" {
            value = ["protocol_version": 1, "foreground": true, "worker": true, "computers": false, "transport": "mock"]
        } else if path == "/assistant/messages", request.httpMethod == "POST" {
            let body = try JSONDecoder().decode(MessageRequest.self, from: request.httpBody!)
            var taskIDs: [String] = []
            if body.mode == "assistant", body.text.hasPrefix("/task ") {
                let id = UUID().uuidString.lowercased()
                tasks.append(Work(id: id, request: body, state: "needs_decision"))
                taskIDs = [id]
            } else if let index = tasks.firstIndex(where: { $0.state == "running" }) {
                foregroundDuringWork = true
                completionPolls = 1
                try PrototypeSelfTest.require(tasks[index].state == "running", "Fixture worker running")
            }
            let reply = UUID().uuidString.lowercased()
            messages[body.conversationID, default: []].append(Message(id: body.messageID.uuidString, role: "user", text: body.text, taskIDs: []))
            messages[body.conversationID, default: []].append(Message(id: reply, role: "assistant", text: "Fixture reply", taskIDs: taskIDs))
            value = ["message_id": body.messageID.uuidString, "reply_id": reply, "text": "Fixture reply", "task_ids": taskIDs]
        } else if path == "/assistant/messages" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let id = UUID(uuidString: query.first(where: { $0.name == "conversation_id" })!.value!)!
            return (try JSONEncoder().encode(["messages": messages[id] ?? []]), 200)
        } else if path == "/tasks" {
            if let polls = completionPolls {
                if polls > 0 { completionPolls = polls - 1 }
                else if let index = tasks.firstIndex(where: { $0.state == "running" }) {
                    tasks[index].state = "completed"
                    let work = tasks[index]
                    messages[work.request.conversationID, default: []].append(Message(id: "task:" + work.id, role: "assistant", text: "Fixture complete", taskIDs: [work.id]))
                    completionPolls = nil
                }
            }
            value = ["tasks": tasks.map(task)]
        } else if let index = tasks.firstIndex(where: { path == "/tasks/" + $0.id + "/decision" }) {
            let reply = try JSONDecoder().decode(DecisionRequest.self, from: request.httpBody!)
            guard reply.decisionID == decisionID, reply.reply.approved else { throw PrototypeError.invalidResponse }
            tasks[index].state = "running"
            value = task(tasks[index])
        } else if let index = tasks.firstIndex(where: { path == "/tasks/" + $0.id + "/cancel" }) {
            tasks[index].state = "canceled"
            value = task(tasks[index])
        } else { throw PrototypeError.invalidResponse }
        return (try JSONSerialization.data(withJSONObject: value), 200)
    }
}

@MainActor
enum FacadeSelfTest {
    static func run(root: URL) async throws {
        let fm = FileManager.default
        let outputRoot = root.appendingPathComponent("outputs")
        try fm.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let output = outputRoot.appendingPathComponent("sum.py")
        try Data("def add(a, b):\n    return a + b\n".utf8).write(to: output)
        let fixture = WorkspaceFixture(artifact: output)
        let dataRoot = root.appendingPathComponent("state")
        let firstEndpoint = URL(string: "http://127.0.0.1:49152")!
        let secondEndpoint = URL(string: "http://127.0.0.1:49153")!
        let send: @Sendable (URLRequest) async throws -> (Data, Int) = { try await fixture.send($0) }
        let workspace = try AssistantWorkspace(dataRoot: dataRoot, endpoint: firstEndpoint, workspaceRoot: outputRoot,
                                               runtimeIdentity: "disposable-runtime", send: send)
        let evidence = try await workspace.verifyWorkflow()
        let decoded = try JSONSerialization.jsonObject(with: evidence) as! [String: Any]
        try PrototypeSelfTest.require(decoded["result_deliveries"] as? Int == 1 && decoded["artifact_path"] as? String == output.path,
                                      "Facade workflow returns checked output evidence")
        let responsive = await fixture.foregroundDuringWork
        try PrototypeSelfTest.require(responsive, "Facade uses supplied transport for foreground during worker")
        workspace.store.setDraft("Preserve this draft")
        let pending = MessageRequest(assistantID: workspace.store.saved.assistantID, conversationID: workspace.store.saved.assistant.id,
                                     messageID: UUID(), text: "Unconfirmed", mode: "assistant")
        let stateURL = dataRoot.appendingPathComponent("assistant-ui.json")
        var state = workspace.store.saved
        state.pending.append(pending)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        let reopened = try AssistantWorkspace(dataRoot: dataRoot, endpoint: secondEndpoint, workspaceRoot: outputRoot,
                                              runtimeIdentity: "disposable-runtime", send: send)
        try PrototypeSelfTest.require(reopened.store.saved.assistantID == state.assistantID && reopened.store.pending?.messageID == pending.messageID
                                      && reopened.store.conversation.draft == "Preserve this draft" && reopened.store.saved.endpoint == secondEndpoint,
                                      "Stable runtime permits ephemeral port change without losing identity or pending reply")
        let bytes = try Data(contentsOf: stateURL)
        do {
            _ = try AssistantWorkspace(dataRoot: dataRoot, endpoint: secondEndpoint, workspaceRoot: outputRoot,
                                       runtimeIdentity: "another-runtime", send: send)
            throw PrototypeSelfTest.Failure(name: "Changed runtime identity accepted")
        } catch is PrototypeError { }
        do {
            _ = try PrototypeStore(configuration: PrototypeConfiguration(dataRoot: dataRoot, endpoint: secondEndpoint, workspaceRoot: outputRoot))
            throw PrototypeSelfTest.Failure(name: "Bound state opened by standalone transport")
        } catch is PrototypeError { }
        try PrototypeSelfTest.require(try Data(contentsOf: stateURL) == bytes, "Rejected runtime cannot mutate saved state")
        let legacyRoot = root.appendingPathComponent("legacy")
        _ = try PrototypeStore(configuration: PrototypeConfiguration(dataRoot: legacyRoot, endpoint: firstEndpoint, workspaceRoot: outputRoot))
        do {
            _ = try AssistantWorkspace(dataRoot: legacyRoot, endpoint: firstEndpoint, workspaceRoot: outputRoot,
                                       runtimeIdentity: "disposable-runtime", send: send)
            throw PrototypeSelfTest.Failure(name: "Legacy state adopted by new runtime")
        } catch is PrototypeError { }
        do {
            _ = try AssistantWorkspace(dataRoot: root.appendingPathComponent("invalid"), endpoint: firstEndpoint, workspaceRoot: outputRoot,
                                       runtimeIdentity: "", send: send)
            throw PrototypeSelfTest.Failure(name: "Empty runtime identity accepted")
        } catch is PrototypeError { }
        let json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        try PrototypeSelfTest.require(Set(json.keys).isSubset(of: ["assistantID", "assistant", "conversations", "pending", "abandonedReplies", "decisions", "endpoint", "runtimeIdentity"]),
                                      "Workspace persists only conversation state and runtime binding")
        for requireFreshReply in [true, false] {
            let recoveryFixture = ContractFixture()
            let recovery = try AssistantWorkspace(dataRoot: root.appendingPathComponent(requireFreshReply ? "recovery" : "quarantined-recovery"), endpoint: firstEndpoint,
                                                 workspaceRoot: outputRoot, runtimeIdentity: "recovery-runtime") { try await recoveryFixture.send($0) }
            await recoveryFixture.bind(recovery.assistantID, recovery.store.saved.assistant.id)
            await recovery.store.refresh()
            recovery.store.setDraft("Continue accepted work")
            await recoveryFixture.interruptNextMessage()
            await recovery.store.send()
            guard let originalID = recovery.store.pending?.messageID else { throw PrototypeError.invalidResponse }
            let recoveryEvidence = try await recovery.verifyRecovery(requireFreshReply: requireFreshReply)
            let recovered = try JSONSerialization.jsonObject(with: recoveryEvidence) as! [String: Any]
            try PrototypeSelfTest.require(recovered["archived_message_id"] as? String == originalID.uuidString.lowercased()
                                          && recovered["tasks_unchanged"] as? Bool == true, "Facade recovery retains original identity and tasks")
            let recoveryRequests = await recoveryFixture.requests
            try PrototypeSelfTest.require(recoveryRequests.count == (requireFreshReply ? 3 : 2)
                                          && recoveryRequests[0].messageID == recoveryRequests[1].messageID,
                                          "Facade recovery retries only the original identity before optional fresh Send")
            try PrototypeSelfTest.require(recovered["fresh_reply"] as? Bool == requireFreshReply
                                          && recovered["fresh_send_attempted"] as? Bool == requireFreshReply,
                                          "Quarantined recovery makes no fresh Send and reports the boundary")
            if requireFreshReply {
                try PrototypeSelfTest.require(recoveryRequests[2].messageID != originalID, "Explicit fresh Send uses a new identity")
            }
        }
        print("PASS: reusable UI workflow, injected transport, active-worker reply, single output, Stop, focused mode, stable runtime restart and legacy rejection")
    }
}
