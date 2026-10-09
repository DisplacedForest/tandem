import Foundation
import CryptoKit
import CoreFoundation

typealias PiValue = NativeJSONValue

enum PiBrokerError: String, Error { case invalid, unauthorized, unavailable, budget, duplicate, uncertain, storage, canceled }

func piCheck(_ condition: Bool, _ error: PiBrokerError = .invalid) throws {
    guard condition else { throw error }
}

extension NativeJSONValue {
    var piObject: [String: Self]? { if case .object(let value) = self { return value }; return nil }
    var piArray: [Self]? { if case .array(let value) = self { return value }; return nil }
    var piString: String? { if case .string(let value) = self { return value }; return nil }
    func pi(_ key: String) -> Self { piObject?[key] ?? .null }
    func piKeys(_ keys: Set<String>, required: Set<String>? = nil) throws {
        try piCheck(piObject != nil && Set(piObject!.keys).isSubset(of: keys) && (required ?? keys).isSubset(of: Set(piObject!.keys)))
    }
    func piData() throws -> Data {
        try JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
    static func piRead(_ data: Data, maximumBytes: Int = 65536) throws -> Self {
        try piCheck(data.count <= maximumBytes)
        try NativeTaskJSON.validate(data, maximumBytes: maximumBytes)
        return try piDecode(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }
    static func piDecode(_ value: Any) throws -> Self {
        if let object = value as? [String: Any] { return .object(try object.mapValues(piDecode)) }
        if let array = value as? [Any] { return .array(try array.map(piDecode)) }
        if let string = value as? String { return .string(string) }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        }
        if value is NSNull { return .null }
        throw PiBrokerError.invalid
    }
}

func piUUID(_ value: PiValue) throws -> String {
    guard let text = value.piString, UUID(uuidString: text)?.uuidString.lowercased() == text else { throw PiBrokerError.invalid }
    return text
}
func piToolID(_ value: PiValue) throws -> String {
    guard let id = value.piString, !id.isEmpty, id.utf8.count <= 128,
          id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw PiBrokerError.invalid }
    return id
}
func piHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

struct PiModelScope: Sendable {
    let id: String
    let subject: String
    let assistant: String
    let conversation: String
    let role: String
    let mode: String
    let profile: String
    init(_ value: PiValue, profile: String) throws {
        try value.piKeys(["subject", "assistant", "conversation", "role", "mode"])
        subject = try piUUID(value.pi("subject"))
        assistant = try piUUID(value.pi("assistant"))
        conversation = try piUUID(value.pi("conversation"))
        guard let role = value.pi("role").piString, let mode = value.pi("mode").piString else { throw PiBrokerError.invalid }
        try piCheck(["foreground", "worker", "document"].contains(role) && ["assistant", "focused"].contains(mode) && (role == "foreground" || mode == "assistant"))
        self.role = role; self.mode = mode; self.profile = profile
        id = UUID().uuidString.lowercased()
    }
    var binding: String { [subject, assistant, conversation, role, mode, profile].joined(separator: ":") }
    var wire: PiValue { .object(["scope": .string(id), "subject": .string(subject), "role": .string(role), "mode": .string(mode), "profile": .string(profile), "assistant": .string(assistant), "conversation": .string(conversation)]) }
}

struct PiModelRequest: Sendable {
    let id: String
    let scope: PiModelScope
    let digest: String
    let messages: [PiValue]
    let toolCount: Int
    let toolIDs: Set<String>
    let hostTools: [NativeToolSchema]
    let hostToolRevision: String?
    let hostToolAuthority: (any NativeRuntimeToolServing)?
    var memoryContext: NativeRuntimeMemoryContext? = nil
    var memoryAuthority: NativeRuntimeMemoryBridge? = nil
    init(_ value: PiValue, scope: PiModelScope, channel: String, hostTools: [NativeToolSchema] = [], hostToolRevision: String? = nil, hostToolAuthority: (any NativeRuntimeToolServing)? = nil) throws {
        try PiRuntimeTools.validate(hostTools)
        self.hostTools = hostTools
        self.hostToolRevision = hostToolRevision
        self.hostToolAuthority = hostToolAuthority
        try value.piKeys(["op", "id", "channel", "profile", "scope", "subject", "role", "mode", "assistant", "conversation", "messages"])
        id = try piUUID(value.pi("id"))
        try piCheck(value.pi("op").piString == "complete" && value.pi("channel").piString == channel && value.pi("scope").piString == scope.id && value.pi("profile").piString == scope.profile && value.pi("subject").piString == scope.subject && value.pi("role").piString == scope.role && value.pi("mode").piString == scope.mode && value.pi("assistant").piString == scope.assistant && value.pi("conversation").piString == scope.conversation, .unauthorized)
        guard let messages = value.pi("messages").piArray else { throw PiBrokerError.invalid }
        try piCheck(!messages.isEmpty && messages.count <= 32 && (try value.pi("messages").piData()).count <= (scope.role == "document" ? 32768 : 8192))
        self.scope = scope; self.messages = messages
        var pending: [String: String] = [:], seen = Set<String>(), count = 0
        for (index, message) in messages.enumerated() {
            let role = message.pi("role").piString
            if role == "system" || role == "user" {
                try message.piKeys(["role", "content"])
                try piCheck(pending.isEmpty && (role != "system" || index == 0) && message.pi("content").piString != nil)
            } else if role == "assistant" {
                try message.piKeys(["role", "content"])
                try piCheck(pending.isEmpty)
                guard let content = message.pi("content").piArray else { throw PiBrokerError.invalid }
                for block in content {
                    if block.pi("type").piString == "text" { try Self.text(block) }
                    else {
                        try block.piKeys(["type", "id", "name", "arguments"])
                        try piCheck(block.pi("type").piString == "toolCall")
                        let callID = try piToolID(block.pi("id"))
                        guard let name = block.pi("name").piString else { throw PiBrokerError.invalid }
                        try Self.arguments(block.pi("arguments"), name: name, scope: scope, hostTools: hostTools)
                        try piCheck(seen.insert(callID).inserted)
                        pending[callID] = name; count += 1
                    }
                }
            } else if role == "toolResult" {
                try message.piKeys(["role", "content", "toolCallId", "toolName", "isError"], required: ["role", "content", "toolCallId", "toolName"])
                let callID = try piToolID(message.pi("toolCallId"))
                guard let name = message.pi("toolName").piString, let expected = pending.removeValue(forKey: callID) else { throw PiBrokerError.invalid }
                try piCheck(expected == name && seen.contains(callID))
                guard let blocks = message.pi("content").piArray else { throw PiBrokerError.invalid }
                for block in blocks { try Self.text(block) }
                if message.piObject?["isError"] != nil { try piCheck(message.pi("isError") == .bool(true) || message.pi("isError") == .bool(false)) }
            } else { throw PiBrokerError.invalid }
        }
        try piCheck(pending.isEmpty && count <= 8)
        toolCount = count
        toolIDs = seen
        digest = piHash(try PiValue.object(["binding": .string(scope.binding), "messages": .array(messages), "host_tools": PiRuntimeTools.wire(hostTools), "host_tool_revision": hostToolRevision.map(PiValue.string) ?? .null]).piData())
    }
    private init(original: PiModelRequest, context: NativeRuntimeMemoryContext, authority: NativeRuntimeMemoryBridge) throws {
        id = original.id; scope = original.scope; toolCount = original.toolCount; toolIDs = original.toolIDs
        hostTools = original.hostTools
        hostToolRevision = original.hostToolRevision
        hostToolAuthority = original.hostToolAuthority
        memoryContext = context
        memoryAuthority = authority
        var messages = original.messages
        let prior = messages.first?.pi("role").piString == "system" ? messages.removeFirst().pi("content").piString ?? "" : ""
        messages.insert(.object(["role": .string("system"), "content": .string(context.prompt + "\n\n" + prior)]), at: 0)
        try piCheck((try PiValue.array(messages).piData()).count <= 14336)
        self.messages = messages
        digest = piHash(Data((original.digest + ":" + context.digest).utf8))
    }
    func withMemoryContext(_ context: NativeRuntimeMemoryContext, authority: NativeRuntimeMemoryBridge) throws -> PiModelRequest {
        try PiModelRequest(original: self, context: context, authority: authority)
    }
    func validateHostTools() async throws {
        try Task.checkCancellation()
        guard hostToolAuthority != nil || hostToolRevision != nil else { return }
        let current = try await PiRuntimeToolSnapshot.capture(scope: scope, authority: hostToolAuthority)
        try piCheck(current == PiRuntimeToolSnapshot(revision: hostToolRevision, schemas: hostTools), .unauthorized)
    }
    static func text(_ block: PiValue) throws {
        try block.piKeys(["type", "text"])
        try piCheck(block.pi("type").piString == "text" && block.pi("text").piString != nil)
    }
    static func arguments(_ args: PiValue, name: String, scope: PiModelScope, hostTools: [NativeToolSchema] = []) throws {
        try piCheck(scope.role != "document", .unauthorized)
        if let schema = hostTools.first(where: { $0.name == name }) {
            try NativeMCPJSONSchema(schema.parameters).validate(args)
            return
        }
        if scope.role == "foreground" {
            try piCheck(scope.mode == "assistant" && name == "delegate", .unauthorized)
            try args.piKeys(["objective"])
            guard let text = args.pi("objective").piString else { throw PiBrokerError.invalid }
            try piCheck(!text.isEmpty && text.count <= 8000)
        } else {
            try piCheck(["read_file", "write_file", "check_python"].contains(name), .unauthorized)
            try args.piKeys(name == "write_file" ? ["path", "content"] : ["path"])
            try piCheck(args.pi("path").piString == "sum.py", .unauthorized)
            if name == "write_file" { try piCheck(args.pi("content").piString != nil && (args.pi("content").piString?.utf8.count ?? 65537) <= 8192) }
        }
    }
}

protocol PiMockModelExecutor: Sendable {
    func validateOwner() async throws
    func retryDocument(_ subject: String) async throws
    func prepareRequest(_ request: PiModelRequest) async throws -> PiModelRequest
    func validateRequest(_ request: PiModelRequest) async throws
    func complete(_ request: PiModelRequest) async throws -> PiValue
}

extension PiMockModelExecutor {
    func validateOwner() async throws {}
    func retryDocument(_ subject: String) async throws {}
    func prepareRequest(_ request: PiModelRequest) async throws -> PiModelRequest { request }
    func validateRequest(_ request: PiModelRequest) async throws { try await request.validateHostTools() }
}

struct PiFixtureModel: PiMockModelExecutor {
    func complete(_ request: PiModelRequest) async throws -> PiValue {
        try await Task.sleep(for: .milliseconds(request.scope.role == "foreground" ? 30 : 600))
        var content: [PiValue] = [], name: String?, args: PiValue = .object([:])
        if request.scope.role == "document" {
            let prompt = request.messages.first?.pi("content").piString ?? ""
            let text: PiValue = prompt.contains("Plan at most")
                ? .object(["sections": .array(["Purpose", "Preparation", "Discussion", "Next steps"].map {
                    .object(["heading": .string($0), "instructions": .string("Use the supplied notes.")])
                })])
                : .object(["text": .string("Keep literal [1] and [2, 3].\n\n```text\nvalues[1] = retained\n```\n\n## Sources\n\nSupplied workshop notes.\n\n[Unsafe link](file:///private/example) and [safe link](https://reference.example/notes).\n\n![Omitted image](https://image.example/notes.png)")])
            content = [.object(["type": .string("text"), "text": .string(String(decoding: try text.piData(), as: UTF8.self))])]
        } else if request.messages.last?.pi("isError") == .bool(true) {
            content = [.object(["type": .string("text"), "text": .string("App-owned mock stopped after a tool failure.")])]
        } else if request.scope.role == "worker", request.toolCount < 3 {
            name = ["read_file", "write_file", "check_python"][request.toolCount]
            args = .object(name == "write_file" ? ["path": .string("sum.py"), "content": .string("def add(a, b):\n    return a + b\n")] : ["path": .string("sum.py")])
        } else if request.scope.role == "foreground", request.scope.mode == "assistant", request.messages.last?.pi("role").piString == "user", let text = request.messages.last?.pi("content").piString, text.hasPrefix("/task ") {
            name = "delegate"; args = .object(["objective": .string(String(text.dropFirst(6)))])
        }
        if let name { content = [.object(["type": .string("toolCall"), "id": .string(UUID().uuidString.lowercased()), "name": .string(name), "arguments": args])] }
        if content.isEmpty { content = [.object(["type": .string("text"), "text": .string(request.scope.role == "worker" ? "App-owned mock updated sum.py." : "App-owned mock reply.")])] }
        return .object(["content": .array(content), "usage": .object(["input": .number(20), "output": .number(4), "cost_usd": .number(0.000028)])])
    }
}
