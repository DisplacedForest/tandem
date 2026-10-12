import Foundation

final class PiCandidateCredentials: NativeCredentialStore {
    static let key = "in-memory-mock-credential"
    private var values: [String: String]
    var reads = 0
    init(profile: String) { values = [profile: Self.key] }
    func read(for profileID: String) throws -> String? { reads += 1; return values[profileID] }
    func set(_ value: String?, for profileID: String) throws { values[profileID] = value }
    func addIfAbsent(_ value: String, for profileID: String) throws {
        if values[profileID] == nil { values[profileID] = value }
    }
}

actor PiCandidateProviderFixture {
    private var count = 0
    private var activeDocuments = 0
    private var documentCount = 0
    func documentCalls() -> Int { documentCount }
    func documentActive() -> Bool { activeDocuments > 0 }
    func send(_ outgoing: URLRequest, request: PiModelRequest) async throws -> (Data, Int) {
        try piCheck(outgoing.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions" && outgoing.httpMethod == "POST" && outgoing.value(forHTTPHeaderField: "Authorization") == "Bearer " + PiCandidateCredentials.key)
        guard let data = outgoing.httpBody else { throw PiBrokerError.invalid }
        let parsed = try PiValue.piRead(data)
        let expected = try PiProviderCodec.body(request, model: "qwen/qwen3.8-flash")
        try piCheck(parsed == expected)
        count += 1
        if request.scope.role == "document" { activeDocuments += 1; documentCount += 1 }
        defer { if request.scope.role == "document" { activeDocuments -= 1 } }
        if request.scope.role == "foreground", request.toolCount > 0,
           request.messages.contains(where: { $0.pi("role").piString == "user" && ($0.pi("content").piString?.contains("Slow acknowledgment fixture.") ?? false) }) {
            try await Task.sleep(for: .seconds(4))
        }
        let fixture = try await PiFixtureModel().complete(request)
        let block = fixture.pi("content").piArray![0]
        var message: [String: PiValue] = ["role": .string("assistant"), "content": .null]
        var finish = "stop"
        if block.pi("type").piString == "text" { message["content"] = block.pi("text") }
        else {
            finish = "tool_calls"
            message["tool_calls"] = .array([.object(["id": block.pi("id"), "type": .string("function"), "function": .object(["name": block.pi("name"), "arguments": .string(String(decoding: try block.pi("arguments").piData(), as: UTF8.self))])])])
        }
        let value: PiValue = .object(["model": .string("qwen/qwen3.8-flash"), "choices": .array([.object(["finish_reason": .string(finish), "message": .object(message)])]), "usage": .object(["prompt_tokens": .number(20), "completion_tokens": .number(4), "cost": .number(0.000028)])])
        return (try value.piData(), 200)
    }
    func calls() -> Int { count }
}

final class PiAdmissionFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [String: String] = [:]
    private var priorities: [String] = []
    private var released = 0
    private var unavailable = false
    private var generationSeconds = 3.0
    func setGenerationSeconds(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; generationSeconds = seconds }
    func setUnavailable(_ value: Bool) { lock.lock(); defer { lock.unlock() }; unavailable = value }
    func response(_ request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try piCheck(!unavailable, .unavailable)
        let path = request.url?.path ?? ""
        let id: String, state: String
        if path.hasSuffix("/release") {
            id = request.url!.deletingLastPathComponent().lastPathComponent
            if active.removeValue(forKey: id) != nil { released += 1 }
            state = "released"
        } else {
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096), collected = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    try piCheck(count >= 0 && collected.count + count <= 8192)
                    if count == 0 { break }
                    collected.append(contentsOf: bytes.prefix(count))
                }
                data = collected
            }
            guard let data else { throw PiBrokerError.invalid }
            let value = try PiValue.piRead(data)
            try value.piKeys(["request_id", "resource", "priority", "requested_seconds"])
            id = try piUUID(value.pi("request_id"))
            guard let priority = value.pi("priority").piString, ["foreground", "background"].contains(priority) else { throw PiBrokerError.invalid }
            state = active.count < 2 || active[id] != nil ? "admitted" : "pending"
            if state == "admitted", active[id] == nil { active[id] = priority; priorities.append(priority) }
        }
        return try PiValue.object(["request_id": .string(id), "state": .string(state), "generation_seconds_remaining": .number(generationSeconds), "lease_seconds_remaining": .number(generationSeconds + 1), "poll_seconds": .number(0.01), "queue_seconds": .number(3), "queue_wait_seconds": .number(0)]).piData()
    }
    func evidence() -> PiValue {
        lock.lock(); defer { lock.unlock() }
        return .object(["priorities": .array(priorities.map(PiValue.string)), "released": .number(Double(released)), "active": .number(Double(active.count))])
    }
}

final class PiAdmissionFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = PiAdmissionFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            try piCheck(request.url?.host == "admission.invalid")
            let data = try Self.state.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: PiBrokerError.unavailable) }
    }
    override func stopLoading() {}
    static func admission() -> NativeInferenceAdmission {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return NativeInferenceAdmission(baseURL: URL(string: "https://admission.invalid")!, session: URLSession(configuration: configuration))
    }
}
