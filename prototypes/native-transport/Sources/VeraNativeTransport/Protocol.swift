import Foundation

let modelID = "qwen/qwen3.8-flash"
let origin = "https://openrouter.ai/api/v1/"

struct SessionPermit: Sendable {
    let id: String
    let taskID: String
    let role: String
}
struct Permit: Sendable {
    let experiment: String
    let profileID: String
    let expires: Date
    let baseline: Int64
    let budget: Int64
    let maxRequests: Int
    let sessions: [String: SessionPermit]
    let digest: String
    init(_ value: J, now: Date = Date()) throws {
        try value.keys(["experiment_id", "profile_id", "issued_at", "expires_at", "reconciliation_id", "prior_test_spend_usd", "exclusive_test_owner", "budget_scope", "budget_usd", "max_requests", "sessions", "credential_access"], required: ["experiment_id", "profile_id", "issued_at", "expires_at", "reconciliation_id", "prior_test_spend_usd", "exclusive_test_owner", "budget_scope", "budget_usd", "max_requests", "sessions", "credential_access"])
        experiment = try identifier(value["experiment_id"])
        _ = try identifier(value["reconciliation_id"])
        guard let profile = value["profile_id"].string, UUID(uuidString: profile) != nil,
              let issued = value["issued_at"].decimal, let expiration = value["expires_at"].decimal,
              let count = value["max_requests"].decimal else { throw Failure.unauthorized }
        let nowValue = Decimal(now.timeIntervalSince1970)
        try require(issued <= nowValue && issued >= nowValue - 300 && expiration > nowValue && expiration <= issued + 3600, .unauthorized)
        try require(value["exclusive_test_owner"].boolean == true && value["budget_scope"].string == "vera-tests" && value["credential_access"].string == "noninteractive-once", .unauthorized)
        try require(count >= 1 && count <= 12 && count == Decimal(NSDecimalNumber(decimal: count).intValue), .unauthorized)
        maxRequests = NSDecimalNumber(decimal: count).intValue
        profileID = profile
        expires = Date(timeIntervalSince1970: NSDecimalNumber(decimal: expiration).doubleValue)
        baseline = try nanos(price(value["prior_test_spend_usd"]))
        budget = try nanos(price(value["budget_usd"]))
        try require(baseline <= 200_000_000_000 && budget > 0 && budget <= 1_000_000_000, .budget)
        guard let entries = value["sessions"].array, !entries.isEmpty, entries.count <= 3 else { throw Failure.unauthorized }
        var parsed: [String: SessionPermit] = [:]
        for entry in entries {
            try entry.keys(["id", "task_id", "role"], required: ["id", "task_id", "role"])
            let id = try identifier(entry["id"]), task = try identifier(entry["task_id"])
            guard let role = entry["role"].string, ["foreground", "worker"].contains(role), parsed[id] == nil else { throw Failure.unauthorized }
            parsed[id] = SessionPermit(id: id, taskID: task, role: role)
        }
        try require(parsed.values.filter { $0.role == "foreground" }.count <= 2 && parsed.values.filter { $0.role == "worker" }.count <= 1, .unauthorized)
        sessions = parsed
        digest = try value.digest()
    }
}

struct Completion: Sendable {
    let id: String
    let session: SessionPermit
    let digest: String
    let messages: [J]
    let tools: [J]
    let priorToolIDs: Set<String>
    let toolsUsed: Int
    init(_ value: J, permit: Permit, requestPermit: J, now: Date = Date()) throws {
        try require(now < permit.expires, .unauthorized)
        try value.keys(["op", "request_id", "session_id", "task_id", "role", "messages"], required: ["op", "request_id", "session_id", "task_id", "role", "messages"])
        try require(value["op"].string == "complete")
        id = try identifier(value["request_id"])
        let sessionID = try identifier(value["session_id"])
        guard let bound = permit.sessions[sessionID], bound.taskID == value["task_id"].string, bound.role == value["role"].string else { throw Failure.unauthorized }
        session = bound
        digest = try value.digest()
        try requestPermit.keys(["request_id", "input_sha256", "experiment_id"], required: ["request_id", "input_sha256", "experiment_id"])
        try require(requestPermit["request_id"].string == id && requestPermit["input_sha256"].string == digest && requestPermit["experiment_id"].string == permit.experiment, .unauthorized)
        let parsed = try Transcript.convert(value["messages"], role: bound.role)
        messages = parsed.0
        priorToolIDs = Set(parsed.0.flatMap { $0["tool_calls"].array ?? [] }.compactMap { $0["id"].string })
        toolsUsed = parsed.1
        tools = ToolSchema.tools(bound.role)
        let size = try J.object(["messages": .array(messages), "tools": .array(tools)]).data().count
        try require(size <= 8192)
    }
    func body(_ pricing: Pricing) -> J {
        .object(["model": .string(modelID), "messages": .array(messages), "tools": .array(tools), "stream": .bool(false), "max_tokens": .number(256), "reasoning": .object(["enabled": .bool(false)]), "provider": .object(["allow_fallbacks": .bool(false), "require_parameters": .bool(true), "max_price": .object(["prompt": .number(pricing.input * 1_000_000), "completion": .number(pricing.output * 1_000_000)])])])
    }
}

enum ToolSchema {
    static func names(_ role: String) -> Set<String> { role == "worker" ? ["read_file", "write_file", "check_python"] : ["delegate"] }
    static func validate(_ name: String, args: J, role: String) throws {
        try require(names(role).contains(name))
        if name == "delegate" {
            try args.keys(["objective"], required: ["objective"])
            try require(args["objective"].string.map { !$0.isEmpty && $0.utf8.count <= 4000 } == true)
        } else {
            let keys: Set<String> = name == "write_file" ? ["path", "content"] : ["path"]
            try args.keys(keys, required: keys)
            try require(args["path"].string == "sum.py")
            if name == "write_file" { try require(args["content"].string.map { $0.utf8.count <= 4000 } == true) }
        }
    }
    static func tools(_ role: String) -> [J] {
        names(role).sorted().map { name in
            var properties: [String: J] = [:]
            if name == "delegate" { properties["objective"] = .object(["type": .string("string"), "maxLength": .number(4000)]) }
            else { properties["path"] = .object(["type": .string("string"), "enum": .array([.string("sum.py")])]) }
            if name == "write_file" { properties["content"] = .object(["type": .string("string"), "maxLength": .number(4000)]) }
            return .object(["type": .string("function"), "function": .object(["name": .string(name), "description": .string(name == "delegate" ? "Accept explicitly requested background work. The host persists it and requires approval before execution." : "Operate only on the approved disposable sum.py fixture."), "parameters": .object(["type": .string("object"), "properties": .object(properties), "required": .array(properties.keys.sorted().map(J.string)), "additionalProperties": .bool(false)])])])
        }
    }
}

enum Transcript {
    static func text(_ content: J) throws -> String {
        if let value = content.string { try require(value.utf8.count <= 8192); return value }
        guard let parts = content.array, parts.count <= 4 else { throw Failure.invalidRequest }
        return try parts.map { item in
            try item.keys(["type", "text"], required: ["type", "text"])
            try require(item["type"].string == "text")
            guard let value = item["text"].string, value.utf8.count <= 8192 else { throw Failure.invalidRequest }
            return value
        }.joined()
    }
    static func convert(_ value: J, role: String) throws -> ([J], Int) {
        guard let entries = value.array, !entries.isEmpty, entries.count <= 32 else { throw Failure.invalidRequest }
        var output: [J] = [], pending: [String: String] = [:], seen = Set<String>(), tools = 0
        for (index, entry) in entries.enumerated() {
            try entry.keys(["role", "content", "toolCallId", "toolName", "isError"], required: ["role", "content"])
            guard let kind = entry["role"].string else { throw Failure.invalidRequest }
            switch kind {
            case "system", "user":
                try entry.keys(["role", "content"], required: ["role", "content"])
                try require(pending.isEmpty && (kind != "system" || index == 0))
                output.append(.object(["role": .string(kind), "content": .string(try text(entry["content"]))]))
            case "assistant":
                try entry.keys(["role", "content"], required: ["role", "content"])
                try require(pending.isEmpty)
                guard let content = entry["content"].array, content.count <= 8 else { throw Failure.invalidRequest }
                var textParts: [String] = [], calls: [J] = []
                for item in content {
                    if item["type"].string == "text" { textParts.append(try text(.array([item]))); continue }
                    try item.keys(["type", "id", "name", "arguments"], required: ["type", "id", "name", "arguments"])
                    guard item["type"].string == "toolCall", let id = item["id"].string, !id.isEmpty, id.utf8.count <= 128, let name = item["name"].string else { throw Failure.invalidRequest }
                    try require(seen.insert(id).inserted)
                    try ToolSchema.validate(name, args: item["arguments"], role: role)
                    pending[id] = name; tools += 1
                    calls.append(.object(["id": .string(id), "type": .string("function"), "function": .object(["name": .string(name), "arguments": .string(String(decoding: try item["arguments"].data(), as: UTF8.self))])]))
                }
                var converted: [String: J] = ["role": .string("assistant"), "content": .string(textParts.joined())]
                if !calls.isEmpty { converted["tool_calls"] = .array(calls) }
                output.append(.object(converted))
            case "toolResult":
                try entry.keys(["role", "content", "toolCallId", "toolName", "isError"], required: ["role", "content", "toolCallId"])
                guard let id = entry["toolCallId"].string, let name = pending.removeValue(forKey: id) else { throw Failure.invalidRequest }
                if entry.object?["toolName"] != nil { try require(entry["toolName"].string == name) }
                if entry.object?["isError"] != nil { try require(entry["isError"].boolean != nil) }
                output.append(.object(["role": .string("tool"), "tool_call_id": .string(id), "content": .string((entry["isError"].boolean == true ? "Tool failed: " : "") + (try text(entry["content"])))]))
            default: throw Failure.invalidRequest
            }
        }
        try require(pending.isEmpty && tools <= 8 && ["user", "toolResult"].contains(entries.last?["role"].string ?? ""))
        return (output, tools)
    }
}

struct Pricing: Sendable {
    let input: Decimal
    let output: Decimal
    init(catalog: J) throws {
        guard let entries = catalog["data"].array else { throw Failure.providerResponse }
        let models = entries.filter { $0["id"].string == modelID }
        try require(models.count == 1, .providerResponse)
        let selected = models[0]
        try require(selected["reasoning"]["mandatory"].boolean == false, .providerResponse)
        try require(selected["alias_target"] == .null && selected["pricing"]["overrides"] == .null, .providerResponse)
        let supported = Set(selected["supported_parameters"].array?.compactMap(\.string) ?? [])
        try require(Set(["tools", "max_tokens", "reasoning"]).isSubset(of: supported), .providerResponse)
        guard let fields = selected["pricing"].object else { throw Failure.providerResponse }
        input = try price(fields["prompt"] ?? .null); output = try price(fields["completion"] ?? .null)
        for (key, value) in fields where !["prompt", "completion", "input_cache_read", "input_cache_write"].contains(key) {
            try require(try price(value) == 0, .providerResponse)
        }
        for key in ["input_cache_read", "input_cache_write"] where fields[key] != nil {
            try require(try price(fields[key]!) <= input, .providerResponse)
        }
    }
    var reservation: Int64 { get throws { try nanos(input * 16384 + output * 256) } }
}
