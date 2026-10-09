import Foundation

final class PiProviderFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var behavior = "normal"
    private var stops = 0
    private var memoryChecks: [(Bool, Bool)] = []
    func configure(_ behavior: String) { lock.lock(); defer { lock.unlock() }; self.behavior = behavior; paths = []; stops = 0; memoryChecks = [] }
    func stopped() { lock.lock(); defer { lock.unlock() }; stops += 1 }
    func stopCount() -> Int { lock.lock(); defer { lock.unlock() }; return stops }
    func sharedMemoryEvidence() -> [(Bool, Bool)] { lock.lock(); defer { lock.unlock() }; return memoryChecks }
    func calls() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
    func response(_ request: URLRequest) throws -> (Data, Int, [String: String], Double) {
        lock.lock(); defer { lock.unlock() }
        try piCheck(request.url?.host == "openrouter.ai" && request.value(forHTTPHeaderField: "Authorization") == "Bearer " + PiCandidateCredentials.key)
        let path = request.url!.lastPathComponent
        paths.append(path)
        if behavior == "checkpoint-held" && path == "completions" { _ = PiCheckpointDeadline(seconds: 0.5, code: 124) }
        if behavior == "status" { return (Data(), 503, [:], 0) }
        if behavior == "redirect" { return (Data(), 302, ["Location": "https://forbidden.invalid"], 0) }
        if behavior == "oversize" { return (Data(repeating: 32, count: 65537), 200, [:], 0) }
        if behavior == "declared" { return (Data(), 200, ["Content-Length": "9000000"], 0) }
        if behavior == "echo" { return (Data(PiCandidateCredentials.key.utf8), 200, [:], 0) }
        if behavior == "malformed" { return (Data("{".utf8), 200, [:], 0) }
        if behavior == "timeout" { throw URLError(.timedOut) }
        if path == "models" {
            if behavior == "metadata-echo" {
                var fields = Self.catalog.piObject!
                fields["description"] = .string(PiCandidateCredentials.key)
                let text = String(decoding: try PiValue.object(fields).piData(), as: UTF8.self).replacingOccurrences(of: PiCandidateCredentials.key, with: "\\u0069n-memory-mock-credential")
                return (Data(text.utf8), 200, [:], 0)
            }
            return (try (behavior.hasPrefix("checkpoint") ? Self.checkpointCatalog : Self.catalog).piData(), 200, [:], 0)
        }
        if path == "key" { return (Data("{\"data\":{\"usage\":0.25}}".utf8), 200, [:], 0) }
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                try piCheck(count >= 0 && collected.count + count <= 16384)
                if count == 0 { break }
                collected.append(contentsOf: bytes.prefix(count))
            }
            data = collected
        }
        guard let data else { throw PiBrokerError.invalid }
        let body = try PiValue.piRead(data)
        try piCheck(body.pi("model").piString == "qwen/qwen3.8-flash" && [PiValue.number(256), .number(1024)].contains(body.pi("max_tokens")) && body.pi("reasoning").pi("enabled") == .bool(false))
        try piCheck(body.pi("provider").pi("max_price").pi("prompt") == .number(behavior.hasPrefix("checkpoint") ? 0.17 : 0.05) && body.pi("provider").pi("allow_fallbacks") == .bool(false))
        let names = body.pi("tools").piArray!.compactMap { $0.pi("function").pi("name").piString }
        let messages = body.pi("messages").piArray!, last = body.pi("messages").piArray!.last!
        let worker = names.contains("write_file")
        let prompt = messages.first?.pi("content").piString ?? ""
        memoryChecks.append((worker, prompt.contains("USER-APPROVED MEMORY CONTEXT")))
        try piCheck(!prompt.contains("Other-bank-only evidence"))
        let count = messages.filter { $0.pi("role").piString == "tool" }.count
        var name: String?, args: PiValue = .object([:])
        if worker && count < 3 {
            name = ["read_file", "write_file", "check_python"][count]
            args = .object(name == "write_file" ? ["path": .string("sum.py"), "content": .string("def add(a, b):\n    return a + b\n")] : ["path": .string("sum.py")])
        } else if names.contains("delegate"), last.pi("role").piString == "user", let text = last.pi("content").piString, text.hasPrefix("/task ") {
            name = "delegate"; args = .object(["objective": .string(String(text.dropFirst(6)))])
        }
        var message: [String: PiValue] = ["role": .string("assistant"), "content": .string(behavior.hasPrefix("checkpoint") ? "OK" : "HTTP provider fixture reply.")]
        if let name {
            message["content"] = .null
            message["tool_calls"] = .array([.object(["id": .string(UUID().uuidString.lowercased()), "type": .string("function"), "function": .object(["name": .string(name), "arguments": .string(String(decoding: try args.piData(), as: UTF8.self))])])])
        }
        if behavior == "escaped-echo" { message["content"] = .string(PiCandidateCredentials.key) }
        if behavior == "nested-echo" {
            name = "delegate"
            message["content"] = .null
            message["tool_calls"] = .array([.object(["id": .string(UUID().uuidString.lowercased()), "type": .string("function"), "function": .object(["name": .string("delegate"), "arguments": .string("{\"objective\":\"\\u0069n-memory-mock-credential\"}")])])])
        }
        let reply: PiValue = .object(["model": .string("qwen/qwen3.8-flash"), "choices": .array([.object(["finish_reason": .string(name == nil ? "stop" : "tool_calls"), "message": .object(message)])]), "usage": behavior == "missing-cost" ? .object(["prompt_tokens": .number(20), "completion_tokens": .number(4)]) : .object(["prompt_tokens": .number(20), "completion_tokens": .number(4), "cost": .number(0.000028)])])
        let replyData = try reply.piData()
        let encoded = behavior == "escaped-echo" ? Data(String(decoding: replyData, as: UTF8.self).replacingOccurrences(of: PiCandidateCredentials.key, with: "\\u0069n-memory-mock-credential").utf8) : replyData
        return (encoded, 200, [:], (behavior == "held" || behavior == "checkpoint-held") ? 5 : (worker ? 0.3 : 0.01))
    }
    static var checkpointCatalog: PiValue {
        var entry = catalog.pi("data").piArray![0].piObject!
        entry["pricing"] = .object(["prompt": .string("0.00000015"), "completion": .string("0.00000047"), "request": .string("0")])
        return .object(["data": .array([.object(entry)])])
    }
    static var catalog: PiValue {
        .object(["data": .array([.object(["id": .string("qwen/qwen3.8-flash"), "reasoning": .object(["mandatory": .bool(false)]), "supported_parameters": .array(["tools", "max_tokens", "reasoning"].map(PiValue.string)), "pricing": .object(["prompt": .string("0.00000005"), "completion": .string("0.0000001"), "request": .string("0"), "input_cache_read": .string("0.000000025")])])])])
    }
}

final class PiProviderFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = PiProviderFixtureState()
    private var delivery: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (data, status, headers, delay) = try Self.state.response(request)
            delivery = Task { @Sendable [self] in
                do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation() }
                catch { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
    }
    override func stopLoading() { delivery?.cancel(); Self.state.stopped() }
    static func http() -> PiProviderHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return PiProviderHTTP(configuration: configuration)
    }
}

final class PiProviderDelayedAdmission: URLProtocol, @unchecked Sendable {
    private var delivery: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try PiAdmissionFixtureProtocol.state.response(request)
            let delay: Double = request.url!.path.hasSuffix("/release") ? 0 : 1
            delivery = Task { @Sendable [self] in
                do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation() }
                catch { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    }
    override func stopLoading() { delivery?.cancel() }
}
