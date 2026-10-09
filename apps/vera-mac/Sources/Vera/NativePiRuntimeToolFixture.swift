import Foundation
import GRDB

actor PiToolFixtureService: NativeRuntimeToolServing {
    static let name = "mcp_" + String(repeating: "a", count: 40)
    static let schema = NativeToolSchema(name: name, description: "Read a fixture value", parameters: .object(["type": .string("object"), "properties": .object(["query": .object(["type": .string("string")])]), "required": .array([.string("query")]), "additionalProperties": .bool(false)]))
    var enabled = true
    var deny = false
    var wait = false
    var oversized = false
    var calls = 0
    var cancellations = 0
    func configure(enabled: Bool = true, deny: Bool = false, wait: Bool = false, oversized: Bool = false) {
        self.enabled = enabled; self.deny = deny; self.wait = wait; self.oversized = oversized
    }
    func catalog(scope: PiModelScope) async throws -> [NativeToolSchema] { enabled ? [Self.schema] : [] }
    func call(scope: PiModelScope, id: String, name: String, arguments: NativeJSONValue) async throws -> NativeJSONValue {
        try piCheck(enabled && !deny, .unauthorized)
        calls += 1
        if wait { try await Task.sleep(for: .milliseconds(150)) }
        return .object(["answer": .string(oversized ? String(repeating: "x", count: 8192) : "fixture value")])
    }
    func cancel(scope: PiModelScope) async { cancellations += 1 }
}

enum NativePiRuntimeToolFixture {
    static func operation(_ scope: PiModelScope, callID: String = "sdk-call", id: String = UUID().uuidString.lowercased()) -> PiValue {
        var wire = scope.wire.piObject!
        wire.merge(["op": .string("tool_call"), "id": .string(id), "channel": .string("tools-channel"), "call_id": .string(callID), "name": .string(PiToolFixtureService.name), "arguments": .object(["query": .string("fixture")])]) { _, value in value }
        return .object(wire)
    }
    static func refuses(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw PiBrokerError.invalid
    }
    static func restart(_ root: URL) async throws {
        let binding = NativePiModelBrokerFixture.binding()
        do {
            let ledger = try PiModelLedger(root: root, manifest: "tools-restart")
            let broker = NativePiModelBroker(ledger: ledger, channel: "tools-channel", tools: PiToolFixtureService())
            let scope = try await broker.authorize(binding)
            _ = try await broker.toolOperation(operation(scope, callID: "completed"))
            _ = try await broker.toolOperation(operation(scope, callID: "uncertain"))
            try await ledger.database.write { db in
                try db.execute(sql: "UPDATE runtime_tools SET state='reserved',result=NULL WHERE id='uncertain'")
            }
            await broker.close()
        }
        let ledger = try PiModelLedger(root: root, manifest: "tools-restart")
        let service = PiToolFixtureService()
        let broker = NativePiModelBroker(ledger: ledger, channel: "tools-channel", tools: service)
        let scope = try await broker.authorize(binding)
        _ = try await broker.toolOperation(operation(scope, callID: "completed"))
        try await refuses { _ = try await broker.toolOperation(operation(scope, callID: "uncertain")) }
        try piCheck(await service.calls == 0)
        await broker.close()
    }
    static func exercise(_ root: URL) async throws {
        let service = PiToolFixtureService()
        let ledger = try PiModelLedger(root: root, manifest: "tools-fixture")
        let broker = NativePiModelBroker(ledger: ledger, channel: "tools-channel", tools: service)
        for (role, mode) in [("foreground", "assistant"), ("foreground", "focused"), ("worker", "assistant")] {
            let scope = try await broker.authorize(NativePiModelBrokerFixture.binding(role: role, mode: mode))
            let request = operation(scope)
            let first = try await broker.toolOperation(request)
            try piCheck(first.pi("value").pi("answer") == .string("fixture value"))
            let replay = try await broker.toolOperation(request)
            try piCheck(first == replay)
            for field in ["scope", "channel", "profile", "subject", "role", "mode", "assistant", "conversation"] {
                try await refuses { _ = try await broker.toolOperation(NativePiModelBrokerFixture.changed(request, field, .string("wrong"))) }
            }
            try await refuses { _ = try await broker.toolOperation(NativePiModelBrokerFixture.changed(request, "arguments", .object(["query": .number(1)]))) }
            let schemas = try await broker.toolCatalog(scope)
            let model = try PiModelRequest(NativePiModelBrokerFixture.request(scope, channel: "tools-channel"), scope: scope, channel: "tools-channel", hostTools: schemas)
            let body = try PiProviderCodec.body(model, model: "fixture")
            try piCheck(body.pi("tools").piArray?.contains(where: { $0.pi("function").pi("name") == .string(PiToolFixtureService.name) }) == true)
            let block: PiValue = .object(["type": .string("toolCall"), "id": .string("history-call"), "name": .string(PiToolFixtureService.name), "arguments": .object(["query": .string("fixture")])])
            let reply: PiValue = .object(["content": .array([block]), "usage": .object(["input": .number(20), "output": .number(4), "cost_usd": .number(0)])])
            try PiModelReply.validate(reply, request: model)
            let history: PiValue = .array([.object(["role": .string("user"), "content": .string("fixture")]), .object(["role": .string("assistant"), "content": .array([block])]), .object(["role": .string("toolResult"), "toolCallId": .string("history-call"), "toolName": .string(PiToolFixtureService.name), "content": .array([.object(["type": .string("text"), "text": .string("fixture value")])])])])
            _ = try PiModelRequest(NativePiModelBrokerFixture.changed(NativePiModelBrokerFixture.request(scope, channel: "tools-channel"), "messages", history), scope: scope, channel: "tools-channel", hostTools: schemas)
            await service.configure(enabled: false)
            try await refuses { _ = try await broker.toolOperation(request) }
            try await refuses { try PiModelReply.validate(reply, request: PiModelRequest(NativePiModelBrokerFixture.request(scope, channel: "tools-channel"), scope: scope, channel: "tools-channel")) }
            await service.configure()
        }
        try piCheck(await service.calls == 3)
        let stopped = try await broker.authorize(NativePiModelBrokerFixture.binding(role: "worker"))
        await broker.revoke(subject: stopped.subject)
        try await refuses { _ = try await broker.toolOperation(operation(stopped)) }
        let scope = try await broker.authorize(NativePiModelBrokerFixture.binding())
        await service.configure(deny: true)
        try await refuses { _ = try await broker.toolOperation(operation(scope, callID: "denied")) }
        await service.configure()
        try await refuses { _ = try await broker.toolOperation(operation(scope, callID: "denied")) }
        await service.configure(wait: true)
        let cancelRequest = operation(scope, callID: "cancel")
        let running = Task { try await broker.toolOperation(cancelRequest) }
        while await service.calls < 4 { try await Task.sleep(for: .milliseconds(5)) }
        await broker.cancel(cancelRequest.pi("id").piString!)
        try await refuses { _ = try await running.value }
        await service.configure()
        try await refuses { _ = try await broker.toolOperation(operation(scope, callID: "cancel")) }
        await service.configure(wait: true)
        let revocation = Task { try await broker.toolOperation(operation(scope, callID: "revoke")) }
        while await service.calls < 5 { try await Task.sleep(for: .milliseconds(5)) }
        await service.configure(enabled: false)
        try await refuses { _ = try await revocation.value }
        await service.configure(oversized: true)
        try await refuses { _ = try await broker.toolOperation(operation(scope, callID: "oversized")) }
        await service.configure(wait: true)
        let disconnected = Task { try await broker.toolOperation(operation(scope, callID: "disconnect")) }
        while await service.calls < 7 { try await Task.sleep(for: .milliseconds(5)) }
        await broker.close()
        try await refuses { _ = try await disconnected.value }
        try piCheck(await service.cancellations > 0)
        try await refuses { _ = try await broker.toolOperation(operation(scope, callID: "closed")) }
    }
}

struct PiToolModelFixture: PiMockModelExecutor {
    func complete(_ request: PiModelRequest) async throws -> PiValue {
        var blocks: [PiValue] = [.object(["type": .string("text"), "text": .string("Host tools completed")])]
        if request.toolCount == 0 {
            func call(_ name: String, _ arguments: PiValue) -> PiValue {
                .object(["type": .string("toolCall"), "id": .string(UUID().uuidString.lowercased()), "name": .string(name), "arguments": arguments])
            }
            if request.scope.role == "foreground", request.messages.last?.pi("content").piString?.hasPrefix("/task ") == true {
                blocks = [call("delegate", .object(["objective": .string("Read host fixture and correct sum.py")]))]
            } else {
                blocks = [call(PiToolFixtureService.name, .object(["query": .string("fixture")]))]
                if request.scope.role == "worker" {
                    blocks += [call("read_file", .object(["path": .string("sum.py")])),
                        call("write_file", .object(["path": .string("sum.py"), "content": .string("def add(a, b):\n    return a + b\n")])),
                        call("check_python", .object(["path": .string("sum.py")]))]
                }
            }
        }
        return .object(["content": .array(blocks), "usage": .object(["input": .number(20), "output": .number(4), "cost_usd": .number(0)])])
    }
}

extension NativePiRuntimeToolFixture {
    static func contract(_ arguments: [String]) async throws {
        var arguments = try NativePiRuntimePaths.expanded(arguments)
        guard let index = arguments.firstIndex(of: "--root") else { throw PiBrokerError.invalid }
        arguments[index + 1] = URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("host-tools-contract").path
        let service = PiToolFixtureService()
        let owner = try NativePiAppOwner(arguments: arguments, executor: PiToolModelFixture(), ownerBinding: "tool-fixture", tools: service)
        do {
            _ = try await owner.start()
            let assistant = UUID()
            try await owner.bindAssistant(assistant)
            let endpoint = try await owner.endpoint()
            func send(_ path: String, _ body: PiValue? = nil) async throws -> PiValue {
                var request = URLRequest(url: endpoint.appendingPathComponent(path))
                if let body { request.httpMethod = "POST"; request.httpBody = try body.piData() }
                let (data, status) = try await owner.http(request)
                try piCheck(status == 200)
                return try PiValue.piRead(data)
            }
            func message(_ text: String, mode: String) async throws -> PiValue {
                try await send("assistant/messages", .object(["assistant_id": .string(assistant.uuidString.lowercased()), "conversation_id": .string(UUID().uuidString.lowercased()), "message_id": .string(UUID().uuidString.lowercased()), "mode": .string(mode), "text": .string(text)]))
            }
            for mode in ["assistant", "focused"] {
                let result = try await message("Read host fixture", mode: mode)
                try piCheck(result.pi("text") == .string("Host tools completed"))
            }
            let delegated = try await message("/task read fixture", mode: "assistant")
            guard let taskID = delegated.pi("task_ids").piArray?.first?.piString else { throw PiBrokerError.invalid }
            func snapshot() async throws -> PiValue {
                let list = try await send("tasks")
                guard let task = list.pi("tasks").piArray?.first(where: { $0.pi("id").piString == taskID }) else { throw PiBrokerError.invalid }
                return task
            }
            var task = try await snapshot()
            for _ in 0..<100 {
                if task.pi("state") == .string("needs_decision") { break }
                try await Task.sleep(for: .milliseconds(20))
                task = try await snapshot()
            }
            let beforeApproval = await service.calls
            try piCheck(task.pi("state") == .string("needs_decision") && beforeApproval == 2)
            _ = try await send("tasks/" + taskID + "/decision", .object(["decision_id": task.pi("decision").pi("id"), "idempotency_key": .string(UUID().uuidString.lowercased()), "reply": .object(["approved": .bool(true)])]))
            for _ in 0..<150 {
                task = try await snapshot()
                if task.pi("state") == .string("completed") { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let afterApproval = await service.calls
            try piCheck(task.pi("state") == .string("completed") && afterApproval == 3)
            await owner.stop()
        } catch { await owner.stop(); throw error }
    }
}
