import Foundation

struct Reply: Sendable {
    let content: [J]
    let input: Int
    let output: Int
    let cost: Int64
    let toolCount: Int
    init(_ data: Data, request: Completion) throws {
        let value = try J.parse(data)
        try require(value["model"].string == modelID, .providerResponse)
        guard let choices = value["choices"].array, choices.count == 1,
              choices[0]["finish_reason"].string.map({ ["stop", "tool_calls"].contains($0) }) == true else { throw Failure.providerResponse }
        let message = choices[0]["message"]
        try require(message["role"].string == "assistant", .providerResponse)
        var content: [J] = []
        if let text = message["content"].string {
            try require(text.utf8.count <= 16000, .providerResponse)
            if !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])) }
        } else { try require(message["content"] == .null, .providerResponse) }
        var ids = Set<String>()
        if message["tool_calls"] != .null {
            guard let calls = message["tool_calls"].array, calls.count <= 8 else { throw Failure.providerResponse }
            for call in calls {
                try call.keys(["id", "type", "function"], required: ["id", "type", "function"])
                guard let id = call["id"].string, !id.isEmpty, id.utf8.count <= 128,
                      call["type"].string == "function", let name = call["function"]["name"].string,
                      let argumentText = call["function"]["arguments"].string else { throw Failure.providerResponse }
                try call["function"].keys(["name", "arguments"], required: ["name", "arguments"])
                try require(!request.priorToolIDs.contains(id) && ids.insert(id).inserted, .providerResponse)
                let args = try J.parse(Data(argumentText.utf8), limit: 8192)
                try ToolSchema.validate(name, args: args, role: request.toolRole)
                content.append(.object(["type": .string("toolCall"), "id": .string(id), "name": .string(name), "arguments": args]))
            }
        }
        try require(!content.isEmpty, .providerResponse)
        try require((choices[0]["finish_reason"].string == "tool_calls") == !ids.isEmpty, .providerResponse)
        self.content = content
        toolCount = ids.count
        func count(_ name: String, cap: Int) throws -> Int {
            guard let n = value["usage"][name].decimal, n >= 0, n <= Decimal(cap), n == Decimal(NSDecimalNumber(decimal: n).intValue) else { throw Failure.providerResponse }
            return NSDecimalNumber(decimal: n).intValue
        }
        input = try count("prompt_tokens", cap: 16384)
        output = try count("completion_tokens", cap: 256)
        guard let amount = value["usage"]["cost"].decimal else { throw Failure.providerResponse }
        cost = try nanos(amount)
    }
    func envelope(_ id: String) -> J {
        .object(["request_id": .string(id), "ok": .bool(true), "content": .array(content), "usage": .object(["input": .number(Decimal(input)), "output": .number(Decimal(output)), "cost_usd": money(cost)])])
    }
}

actor Broker {
    let permit: Permit
    let ledger: Ledger
    let credentials: any CredentialSource
    let http: any HTTPTransport
    let timeout: Duration
    private var key: String?
    private var credentialAttempted = false
    private var activeRoles = Set<String>()
    init(permit: Permit, ledger: Ledger, credentials: any CredentialSource, http: any HTTPTransport, timeout: Duration = .seconds(30)) throws {
        self.timeout = timeout
        self.permit = permit; self.ledger = ledger; self.credentials = credentials; self.http = http
        try ledger.bind(permit)
    }
    func complete(_ value: J, requestPermit: J) async throws -> J {
        try await withThrowingTaskGroup(of: J.self) { group in
            group.addTask { try await self.perform(value, requestPermit: requestPermit) }
            group.addTask { try await Task.sleep(for: self.timeout); throw Failure.deadline }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw Failure.unavailable }
            return result
        }
    }
    private func perform(_ value: J, requestPermit: J) async throws -> J {
        let request = try Completion(value, permit: permit, requestPermit: requestPermit)
        try ledger.check(request)
        try require(activeRoles.insert(request.session.role).inserted, .unavailable)
        defer { activeRoles.remove(request.session.role) }
        try Task.checkCancellation()
        if key == nil {
            try require(!credentialAttempted, .credentialUnavailable)
            credentialAttempted = true
            try ledger.claimCredential(permit)
            key = try credentials.read(profile: permit.profileID)
        }
        guard let key, !key.isEmpty, key.utf8.count <= 4096, !key.contains("\n"), !key.contains("\r") else { throw Failure.credentialUnavailable }
        try require(!String(decoding: try value.data(), as: UTF8.self).contains(key), .redacted)
        let catalog = try await http.send(path: "models", body: nil, credential: key, limit: 8_000_000)
        let pricing = try Pricing(catalog: J.parse(catalog, limit: 8_000_000))
        let usage = try await http.send(path: "key", body: nil, credential: key, limit: 65536)
        guard let amount = try J.parse(usage)["data"]["usage"].decimal else { throw Failure.providerResponse }
        let keyUsage = try nanos(amount)
        let body = try request.body(pricing).data()
        try require(!String(decoding: body, as: UTF8.self).contains(key), .redacted)
        try Task.checkCancellation()
        try require(Date() < permit.expires, .unauthorized)
        try ledger.reserve(request, permit: permit, amount: pricing.reservation, keyUsage: keyUsage)
        do {
            let result = try await http.send(path: "chat/completions", body: body, credential: key, limit: 65536)
            try Task.checkCancellation()
            try require(!String(decoding: result, as: UTF8.self).contains(key), .redacted)
            let reply = try Reply(result, request: request)
            let envelope = reply.envelope(request.id)
            try require(!String(decoding: try envelope.data(), as: UTF8.self).contains(key), .redacted)
            try ledger.settle(request, charged: reply.cost, input: reply.input, output: reply.output, tools: reply.toolCount)
            return envelope
        } catch {
            ledger.uncertain(request.id)
            if error is CancellationError { throw Failure.canceled }
            throw (error as? Failure) ?? Failure.unavailable
        }
    }
}
