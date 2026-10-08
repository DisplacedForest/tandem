import Foundation

typealias PiProviderSend = @Sendable (URLRequest, PiModelRequest) async throws -> (Data, Int)

struct PiSelectedProfileBinding: Equatable, Sendable {
    let profileID: String
    let revision: String
    let endpoint: URL
    let model: String
    init(profileID: String, revision: String, endpoint: String, model: String) throws {
        try piCheck(!profileID.isEmpty && profileID.utf8.count <= 128, .unauthorized)
        _ = try piUUID(.string(revision))
        guard let url = URL(string: endpoint), url.absoluteString == "https://openrouter.ai/api/v1", model == "qwen/qwen3.8-flash" else { throw PiBrokerError.unauthorized }
        self.profileID = profileID; self.revision = revision; self.endpoint = url; self.model = model
    }
    var digest: String { piHash(Data([profileID, revision, endpoint.absoluteString, model].joined(separator: "\n").utf8)) }
}

actor PiSharedAccounting {
    let ledger: PiModelLedger
    private var blocked = false
    init(root: URL, baselineNanos: Int64, budgetNanos: Int64 = 200_000_000_000, ownerBinding: String = "fixture", transport: PiTransportKind = .mock) throws {
        ledger = try PiModelLedger(root: root, manifest: "app-shared-accounting-v1", budget: budgetNanos, baseline: baselineNanos, ownerBinding: ownerBinding, transport: transport)
    }
    func reserve(_ request: PiModelRequest) throws -> PiValue? {
        try piCheck(!blocked, .uncertain)
        try ledger.bind(request.scope)
        return try ledger.reserve(request)
    }
    func settle(_ request: PiModelRequest, reply: PiValue) throws { try ledger.settle(request.id, reply: reply) }
    func uncertain(_ request: PiModelRequest) { blocked = true; ledger.uncertain(request.id) }
    func snapshot() throws -> PiValue { try ledger.snapshot() }
}

struct PiSelectedProfileOperation: PiMockModelExecutor {
    let binding: PiSelectedProfileBinding
    let admission: NativeInferenceAdmission
    let accounting: PiSharedAccounting
    let validate: @Sendable () async throws -> Void
    let send: @Sendable (PiModelRequest, Data) async throws -> (Data, Int)
    var checkpointPricing: PiCheckpointPricing? = nil
    var memoryBridge: NativeRuntimeMemoryBridge? = nil
    func prepareRequest(_ request: PiModelRequest) async throws -> PiModelRequest {
        if let memoryBridge { return try await memoryBridge.prepare(request) }
        return request
    }
    func validateRequest(_ request: PiModelRequest) async throws {
        try Task.checkCancellation()
        if let memoryBridge { try await memoryBridge.validate(request) }
    }
    func validateOwner() async throws { try await validate() }
    func complete(_ request: PiModelRequest) async throws -> PiValue {
        try await validate()
        let request = try await prepareRequest(request)
        let body = try checkpointPricing?.body(request) ?? PiProviderCodec.body(request, model: binding.model).piData()
        try piCheck(body.count <= 16384)
        return try await admission.perform(endpoint: binding.endpoint, priority: request.scope.role == "foreground" ? .foreground : .background, requestedSeconds: 30) { budget in
            try budget.check()
            try await validate()
            try await validateRequest(request)
            if let saved = try await accounting.reserve(request) {
                try await validate()
                try await validateRequest(request)
                try PiModelReply.validate(saved, request: request)
                return saved
            }
            do {
                try await validateRequest(request)
                let (data, status) = try await send(request, body)
                try budget.check()
                try piCheck(status == 200 && data.count <= 65536, .unavailable)
                let reply = try PiProviderCodec.reply(PiValue.piRead(data), request: request, model: binding.model)
                try await accounting.settle(request, reply: reply)
                try await validateRequest(request)
                return reply
            } catch {
                await accounting.uncertain(request)
                throw PiBrokerError.unavailable
            }
        }
    }
}

enum PiProviderCodec {
    static func tools(_ scope: PiModelScope) -> [PiValue] {
        let names = scope.role == "worker" ? ["read_file", "write_file", "check_python"] : (scope.mode == "assistant" ? ["delegate"] : [])
        return names.map { name in
            var properties: [String: PiValue] = name == "delegate" ? ["objective": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(8000)])] : ["path": .object(["type": .string("string"), "enum": .array([.string("sum.py")])])]
            if name == "write_file" { properties["content"] = .object(["type": .string("string"), "maxLength": .number(8192)]) }
            return .object(["type": .string("function"), "function": .object(["name": .string(name), "description": .string(name == "delegate" ? "Accept explicitly requested background work. Execution waits for the user's decision." : "Operate only on the approved disposable sum.py task fixture."), "parameters": .object(["type": .string("object"), "properties": .object(properties), "required": .array(properties.keys.sorted().map(PiValue.string)), "additionalProperties": .bool(false)])])])
        }
    }
    static func body(_ request: PiModelRequest, model: String) throws -> PiValue {
        let messages: [PiValue] = try request.messages.map { entry in
            let role = entry.pi("role").piString!
            if role == "system" || role == "user" { return entry }
            if role == "toolResult" {
                let text = entry.pi("content").piArray!.map { $0.pi("text").piString! }.joined()
                return .object(["role": .string("tool"), "tool_call_id": entry.pi("toolCallId"), "content": .string((entry.pi("isError") == .bool(true) ? "Tool failed: " : "") + text)])
            }
            let blocks = entry.pi("content").piArray!
            let text = blocks.filter { $0.pi("type").piString == "text" }.map { $0.pi("text").piString! }.joined()
            let calls: [PiValue] = try blocks.filter { $0.pi("type").piString == "toolCall" }.map { block in
                .object(["id": block.pi("id"), "type": .string("function"), "function": .object(["name": block.pi("name"), "arguments": .string(String(decoding: try block.pi("arguments").piData(), as: UTF8.self))])])
            }
            var converted: [String: PiValue] = ["role": .string("assistant"), "content": .string(text)]
            if !calls.isEmpty { converted["tool_calls"] = .array(calls) }
            return .object(converted)
        }
        return .object(["model": .string(model), "messages": .array(messages), "tools": .array(tools(request.scope)), "stream": .bool(false), "max_tokens": .number(256), "reasoning": .object(["enabled": .bool(false)]), "provider": .object(["allow_fallbacks": .bool(false), "require_parameters": .bool(true), "max_price": .object(["prompt": .number(0.05), "completion": .number(0.1)])])])
    }
    static func reply(_ value: PiValue, request: PiModelRequest, model: String) throws -> PiValue {
        try piCheck(value.pi("model").piString == model, .invalid)
        guard let choices = value.pi("choices").piArray, choices.count == 1 else { throw PiBrokerError.invalid }
        let choice = choices[0], message = choice.pi("message")
        try piCheck(message.pi("role").piString == "assistant" && ["stop", "tool_calls"].contains(choice.pi("finish_reason").piString ?? ""))
        try piCheck(message.pi("content") == .null || message.pi("content").piString != nil)
        try piCheck(message.pi("tool_calls") == .null || message.pi("tool_calls").piArray != nil)
        var content: [PiValue] = []
        if let text = message.pi("content").piString, !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])) }
        var returnedCalls = 0
        if let calls = message.pi("tool_calls").piArray {
            returnedCalls = calls.count
            for call in calls {
                try piCheck(call.pi("type").piString == "function")
                guard let raw = call.pi("function").pi("arguments").piString else { throw PiBrokerError.invalid }
                content.append(.object(["type": .string("toolCall"), "id": call.pi("id"), "name": call.pi("function").pi("name"), "arguments": try PiValue.piRead(Data(raw.utf8))]))
            }
        }
        try piCheck((choice.pi("finish_reason").piString == "tool_calls") == (returnedCalls > 0))
        let usage = value.pi("usage")
        let reply: PiValue = .object(["content": .array(content), "usage": .object(["input": usage.pi("prompt_tokens"), "output": usage.pi("completion_tokens"), "cost_usd": usage.pi("cost")])])
        try PiModelReply.validate(reply, request: request)
        return reply
    }
}
