import Foundation

typealias NativeTaskGenerationToolCall = NativeChatToolCall
typealias NativeTaskGenerationTool = NativeToolSchema

extension NativeToolSchema: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, description, parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try container.decode(String.self, forKey: .name),
                  description: try container.decode(String.self, forKey: .description),
                  parameters: try container.decode(NativeTaskPlainJSON.self, forKey: .parameters).value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(NativeTaskPlainJSON(value: parameters), forKey: .parameters)
    }
}

struct NativeTaskPlainJSON: Codable, Sendable {
    let value: NativeJSONValue

    init(value: NativeJSONValue) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = .null }
        else if let flag = try? container.decode(Bool.self) { value = .bool(flag) }
        else if let number = try? container.decode(Double.self) { value = .number(number) }
        else if let text = try? container.decode(String.self) { value = .string(text) }
        else if let items = try? container.decode([NativeTaskPlainJSON].self) { value = .array(items.map(\.value)) }
        else { value = .object(try container.decode([String: NativeTaskPlainJSON].self).mapValues(\.value)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .number(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .array(let items): try container.encode(items.map(NativeTaskPlainJSON.init(value:)))
        case .object(let fields): try container.encode(fields.mapValues(NativeTaskPlainJSON.init(value:)))
        }
    }
}

struct NativeTaskGenerationMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
    let toolCalls: [NativeTaskGenerationToolCall]?
    let toolCallID: String?

    init(role: String, content: String, toolCalls: [NativeTaskGenerationToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    private enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        toolCalls = try container.decodeIfPresent([NativeTaskGenerationToolCall].self, forKey: .toolCalls)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }

    var wireObject: [String: Any] {
        var object: [String: Any] = ["role": role, "content": content]
        if let toolCalls {
            object["tool_calls"] = toolCalls.map { ["id": $0.id, "name": $0.name, "arguments": $0.arguments] }
        }
        if let toolCallID { object["tool_call_id"] = toolCallID }
        return object
    }
}

struct NativeTaskGenerationBudget: Equatable, Sendable {
    let maximumOrdinal: Int
    let maximumMessages: Int?
    let maximumBytes: Int
    let allowsTools: Bool

    static let standard = NativeTaskGenerationBudget(maximumOrdinal: 3, maximumMessages: 8, maximumBytes: 65536, allowsTools: false)

    static var dot: NativeTaskGenerationBudget {
        let budget = NativeCompanionWorkerBudget.standard
        return NativeTaskGenerationBudget(maximumOrdinal: 3, maximumMessages: nil,
                                          maximumBytes: budget.transcriptBytes, allowsTools: true)
    }

    static func forWorker(_ workerType: String) -> NativeTaskGenerationBudget {
        workerType == "companion" ? dot : standard
    }
}

struct NativeTaskGenerationCompletion: Codable, Equatable, Sendable {
    let content: String
    let toolCalls: [NativeTaskGenerationToolCall]
    let finishReason: String

    private enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
        case finishReason = "finish_reason"
    }

    static func text(_ content: String) -> NativeTaskGenerationCompletion {
        NativeTaskGenerationCompletion(content: content, toolCalls: [], finishReason: "stop")
    }

    func validated(for job: NativeTaskGenerationJob) throws -> NativeTaskGenerationCompletion {
        guard job.tools != nil else {
            guard toolCalls.isEmpty else { throw NativeTaskGenerationFailure(code: "provider_response") }
            return self
        }
        let ids = toolCalls.map(\.id)
        guard ["stop", "tool_calls"].contains(finishReason), (finishReason == "tool_calls") != toolCalls.isEmpty,
              toolCalls.count <= 64, Set(ids).count == ids.count,
              toolCalls.allSatisfy({ NativeTaskGenerationJob.validCall($0) }),
              !toolCalls.isEmpty || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.utf8.count <= 262144 else {
            throw NativeTaskGenerationFailure(code: "provider_response")
        }
        return self
    }

    func stored(for job: NativeTaskGenerationJob) throws -> String {
        guard job.tools != nil else { return content }
        return String(decoding: try nativeTaskEncoded(self), as: UTF8.self)
    }

    static func restored(_ text: String, job: NativeTaskGenerationJob) throws -> NativeTaskGenerationCompletion {
        guard job.tools != nil else { return .text(text) }
        return try JSONDecoder().decode(Self.self, from: Data(text.utf8)).validated(for: job)
    }
}

struct NativeTaskGenerationJob: Codable, Equatable, Sendable {
    let id: String
    let taskID: String
    let bindingID: String
    let enrollmentDigest: String
    let admissionBase: URL
    let phase: String
    let attempt: String
    let messages: [NativeTaskGenerationMessage]
    let messagesDigest: String
    let deadlineSeconds: Double
    let generation: Int
    let tools: [NativeTaskGenerationTool]?
    let toolChoice: String?

    init(id: String, taskID: String, bindingID: String, enrollmentDigest: String, admissionBase: URL, phase: String,
         attempt: String, messages: [NativeTaskGenerationMessage], messagesDigest: String, deadlineSeconds: Double,
         generation: Int, tools: [NativeTaskGenerationTool]? = nil, toolChoice: String? = nil) {
        self.id = id
        self.taskID = taskID
        self.bindingID = bindingID
        self.enrollmentDigest = enrollmentDigest
        self.admissionBase = admissionBase
        self.phase = phase
        self.attempt = attempt
        self.messages = messages
        self.messagesDigest = messagesDigest
        self.deadlineSeconds = deadlineSeconds
        self.generation = generation
        self.tools = tools
        self.toolChoice = toolChoice
    }

    func withDeadline(_ seconds: Double) -> NativeTaskGenerationJob {
        NativeTaskGenerationJob(id: id, taskID: taskID, bindingID: bindingID,
            enrollmentDigest: enrollmentDigest, admissionBase: admissionBase, phase: phase,
            attempt: attempt, messages: messages, messagesDigest: messagesDigest,
            deadlineSeconds: seconds, generation: generation, tools: tools, toolChoice: toolChoice)
    }

    func reducingDeadline(by seconds: Double) throws -> NativeTaskGenerationJob {
        guard deadlineSeconds > seconds else { throw NativeTaskGenerationFailure(code: "request_timeout") }
        return withDeadline(deadlineSeconds - seconds)
    }

    var key: String { "\(taskID):\(phase):\(attempt)" }

    private enum CodingKeys: String, CodingKey {
        case id, phase, attempt, messages, generation, tools
        case taskID = "task_id"
        case bindingID = "binding_id"
        case enrollmentDigest = "enrollment_digest"
        case admissionBase = "admission_base"
        case messagesDigest = "messages_digest"
        case deadlineSeconds = "deadline_seconds"
        case toolChoice = "tool_choice"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(String.self, forKey: .id),
                      taskID: container.decode(String.self, forKey: .taskID),
                      bindingID: container.decode(String.self, forKey: .bindingID),
                      enrollmentDigest: container.decode(String.self, forKey: .enrollmentDigest),
                      admissionBase: container.decode(URL.self, forKey: .admissionBase),
                      phase: container.decode(String.self, forKey: .phase),
                      attempt: container.decode(String.self, forKey: .attempt),
                      messages: container.decode([NativeTaskGenerationMessage].self, forKey: .messages),
                      messagesDigest: container.decode(String.self, forKey: .messagesDigest),
                      deadlineSeconds: container.decode(Double.self, forKey: .deadlineSeconds),
                      generation: container.decode(Int.self, forKey: .generation),
                      tools: container.decodeIfPresent([NativeTaskGenerationTool].self, forKey: .tools),
                      toolChoice: container.decodeIfPresent(String.self, forKey: .toolChoice))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(bindingID, forKey: .bindingID)
        try container.encode(enrollmentDigest, forKey: .enrollmentDigest)
        try container.encode(admissionBase, forKey: .admissionBase)
        try container.encode(phase, forKey: .phase)
        try container.encode(attempt, forKey: .attempt)
        try container.encode(messages, forKey: .messages)
        try container.encode(messagesDigest, forKey: .messagesDigest)
        try container.encode(deadlineSeconds, forKey: .deadlineSeconds)
        try container.encode(generation, forKey: .generation)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
    }

    static func decode(_ data: Data) throws -> NativeTaskGenerationJob {
        try NativeTaskJSON.validate(data)
        let expected: Set<String> = ["id", "task_id", "binding_id", "enrollment_digest", "admission_base",
            "phase", "attempt", "messages", "messages_digest", "deadline_seconds", "generation"]
        let messageKeys: Set<String> = ["role", "content", "tool_calls", "tool_call_id"]
        guard data.count <= 1048576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).subtracting(["tools", "tool_choice"]) == expected,
              let messages = object["messages"] as? [[String: Any]],
              messages.allSatisfy({ message in
                  let keys = Set(message.keys)
                  guard keys.isSuperset(of: ["role", "content"]), keys.isSubset(of: messageKeys) else { return false }
                  guard let calls = message["tool_calls"] else { return true }
                  return (calls as? [[String: Any]])?.allSatisfy({ Set($0.keys) == ["id", "name", "arguments"] }) == true
              }),
              object["tools"].map({ ($0 as? [[String: Any]])?.allSatisfy({ Set($0.keys) == ["name", "description", "parameters"] }) == true }) ?? true else {
            throw NativeTaskHTTPError.invalidResponse
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    static func validPhase(_ phase: String) -> Bool {
        let parts = phase.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = parts.first.map(String.init), NativeTaskTransportTiming.Phase(rawValue: name) != nil else { return false }
        if parts.count == 1 { return ["plan", "synthesize", "outline"].contains(name) }
        let index = parts[1]
        let digits = name == "work" ? 1...9 : 1...2
        guard digits.contains(index.count), index.allSatisfy(\.isNumber), let number = Int(index) else { return false }
        switch name {
        case "draft", "revise": return number < NativeDocumentWorker.maximumSections
        case "work": return true
        default: return false
        }
    }

    static func validCall(_ call: NativeTaskGenerationToolCall) -> Bool {
        (1...128).contains(call.id.utf8.count) && (1...128).contains(call.name.utf8.count)
            && call.arguments.utf8.count <= 16384
    }

    static func validShape(_ messages: [NativeTaskGenerationMessage], tools: [NativeTaskGenerationTool]?,
                           toolChoice: String?, budget: NativeTaskGenerationBudget) -> Bool {
        guard messages.count >= 1, budget.maximumMessages.map({ messages.count <= $0 }) ?? true else { return false }
        guard budget.allowsTools else {
            return tools == nil && toolChoice == nil && messages.allSatisfy({
                ["system", "user", "assistant"].contains($0.role) && $0.toolCalls == nil && $0.toolCallID == nil
            })
        }
        if let tools {
            let names = tools.map(\.name)
            guard !tools.isEmpty, tools.count <= 64, Set(names).count == names.count,
                  tools.allSatisfy({ (1...64).contains($0.name.utf8.count) && $0.description.utf8.count <= 4096
                      && $0.name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" } })
            else { return false }
        }
        guard toolChoice == nil || (["auto", "none"].contains(toolChoice ?? "") && tools != nil) else { return false }
        var issued: Set<String> = []
        for message in messages {
            switch message.role {
            case "system", "user":
                guard message.toolCalls == nil, message.toolCallID == nil else { return false }
            case "assistant":
                guard message.toolCallID == nil else { return false }
                if let calls = message.toolCalls {
                    let ids = calls.map(\.id)
                    guard !calls.isEmpty, calls.count <= 64, calls.allSatisfy(validCall),
                          Set(ids).count == ids.count, issued.isDisjoint(with: ids) else { return false }
                    issued.formUnion(ids)
                }
            case "tool":
                guard message.toolCalls == nil, let id = message.toolCallID, issued.contains(id) else { return false }
            default:
                return false
            }
        }
        return true
    }

    static func wireBytes(_ messages: [NativeTaskGenerationMessage], tools: [NativeTaskGenerationTool]?) throws -> Int {
        let base = try JSONSerialization.data(withJSONObject: messages.map(\.wireObject)).count
        guard let tools else { return base }
        return base + (try nativeTaskEncoded(tools)).count
    }

    func validate(reference: NativeTaskReference, enforceInputLimit: Bool = true) throws {
        let workerType = reference.createRequest.workerType
        let budget = NativeTaskGenerationBudget.forWorker(workerType)
        guard let profile = reference.profile, let binding = reference.createRequest.payload.nativeBinding,
              reference.remoteTaskID == taskID, reference.deliveryState == .accepted,
              !reference.cancelRequested, reference.snapshot?.state.isTerminal != true,
              bindingID == binding.id, enrollmentDigest == binding.enrollmentDigest,
              admissionBase == binding.admissionBase, admissionBase == profile.provider.base,
              Self.validPhase(phase), budget.allowsTools || !phase.hasPrefix("work"),
              (1...80).contains(attempt.utf8.count),
              attempt.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 }),
              UUID(uuidString: id) != nil, generation > 0,
              deadlineSeconds.isFinite, deadlineSeconds > 0, deadlineSeconds <= 180,
              Self.validShape(messages, tools: tools, toolChoice: toolChoice, budget: budget),
              Self.digest(messages, tools: tools, toolChoice: toolChoice) == messagesDigest else { throw NativeTaskHTTPError.invalidResponse }
        let limit = budget.allowsTools ? budget.maximumBytes : profile.limits.maximumInputBytes
        if enforceInputLimit, try Self.wireBytes(messages, tools: tools) > limit {
            throw NativeTaskGenerationFailure(code: "input_limit")
        }
    }

    static func digest(_ messages: [NativeTaskGenerationMessage], tools: [NativeTaskGenerationTool]? = nil,
                       toolChoice: String? = nil) -> String {
        var bytes = Data()
        func append(_ text: String) {
            let encoded = Data(text.utf8)
            bytes.append(Data("\(encoded.count):".utf8))
            bytes.append(encoded)
        }
        for message in messages {
            append(message.role)
            append(message.content)
            if let calls = message.toolCalls {
                append("\u{0}tool_calls")
                append(String(calls.count))
                for call in calls {
                    append(call.id)
                    append(call.name)
                    append(call.arguments)
                }
            }
            if let toolCallID = message.toolCallID {
                append("\u{0}tool_call_id")
                append(toolCallID)
            }
        }
        if let tools {
            append("\u{0}tools")
            append(String(tools.count))
            for tool in tools {
                append(tool.name)
                append(tool.description)
                append(String(decoding: (try? tool.parameters.piData()) ?? Data(), as: UTF8.self))
            }
        }
        if let toolChoice {
            append("\u{0}tool_choice")
            append(toolChoice)
        }
        return nativeTaskDigest(bytes)
    }
}

enum NativeTaskGenerationReservation: Equatable, Sendable {
    case execute
    case pending
    case completed(String)
    case unavailable(String)
}

protocol NativeTaskGenerationRepository: NativeTaskRepository {
    func reserveTaskGeneration(referenceID: UUID, job: NativeTaskGenerationJob) throws -> NativeTaskGenerationReservation
    func finishTaskGeneration(referenceID: UUID, job: NativeTaskGenerationJob,
                              response: String?, failure: String?) throws
}

struct NativeTaskGenerationResponse: Codable, Sendable {
    let jobID: String
    let bindingID: String
    let generation: Int
    let messagesDigest: String
    let response: String?
    let failure: String?
    let toolCalls: [NativeTaskGenerationToolCall]?

    init(jobID: String, bindingID: String, generation: Int, messagesDigest: String, response: String?,
         failure: String?, toolCalls: [NativeTaskGenerationToolCall]? = nil) {
        self.jobID = jobID
        self.bindingID = bindingID
        self.generation = generation
        self.messagesDigest = messagesDigest
        self.response = response
        self.failure = failure
        self.toolCalls = toolCalls
    }

    private enum CodingKeys: String, CodingKey {
        case generation, response, failure
        case jobID = "job_id"
        case bindingID = "binding_id"
        case messagesDigest = "messages_digest"
        case toolCalls = "tool_calls"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(jobID: container.decode(String.self, forKey: .jobID),
                      bindingID: container.decode(String.self, forKey: .bindingID),
                      generation: container.decode(Int.self, forKey: .generation),
                      messagesDigest: container.decode(String.self, forKey: .messagesDigest),
                      response: container.decodeIfPresent(String.self, forKey: .response),
                      failure: container.decodeIfPresent(String.self, forKey: .failure),
                      toolCalls: container.decodeIfPresent([NativeTaskGenerationToolCall].self, forKey: .toolCalls))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jobID, forKey: .jobID)
        try container.encode(bindingID, forKey: .bindingID)
        try container.encode(generation, forKey: .generation)
        try container.encode(messagesDigest, forKey: .messagesDigest)
        try container.encodeIfPresent(response, forKey: .response)
        try container.encodeIfPresent(failure, forKey: .failure)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
    }
}
