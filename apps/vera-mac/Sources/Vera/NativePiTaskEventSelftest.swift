import Foundation
import VeraAssistantUI

private final class PiTaskEventWireState: @unchecked Sendable {
    private let lock = NSLock()
    private var response = (200, "text/event-stream", Data(), false)
    private var requests: [URLRequest] = []
    private var stops = 0
    func configure(status: Int = 200, type: String = "text/event-stream", body: Data = Data(), hold: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        response = (status, type, body, hold)
        requests.removeAll(); stops = 0
    }
    func start(_ request: URLRequest) -> (Int, String, Data, Bool) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return response
    }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    func snapshot() -> ([URLRequest], Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, stops)
    }
}

private final class PiTaskEventWire: URLProtocol, @unchecked Sendable {
    static let state = PiTaskEventWireState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, type, body, hold) = Self.state.start(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let size = body.count < 1024 ? 1 : 512
        for start in stride(from: 0, to: body.count, by: size) {
            client?.urlProtocol(self, didLoad: body.subdata(in: start..<min(start + size, body.count)))
        }
        if !hold { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.state.stop() }
}

enum NativePiTaskEventSelftest {
    static let endpoint = URL(string: "http://127.0.0.1:45678")!
    static let capability = String(repeating: "a", count: 72)
    static let taskID = "11111111-1111-4111-8111-111111111111"
    static func check(_ value: Bool, _ message: String) throws {
        guard value else {
            print("FAIL: task event transport fixture: " + message)
            throw PiBrokerError.invalid
        }
    }
    static func frame(_ id: Int64) -> String {
        "id: \(id)\nevent: task\ndata: {\"id\":\(id),\"task_id\":\"\(taskID)\"}\n\n"
    }
    static func request(_ cursor: Int64 = 0) throws -> URLRequest {
        try PiOwnedTaskEventTransport.request(endpoint: endpoint, capability: capability, after: cursor)
    }
    static func connection(_ request: URLRequest) -> PiOwnedTaskEventConnection {
        PiOwnedTaskEventTransport.open(request, protocolClasses: [PiTaskEventWire.self])
    }
    static func collect(_ request: URLRequest) async throws -> [AssistantTaskEvent] {
        let stream = connection(request)
        defer { stream.cancel() }
        var events: [AssistantTaskEvent] = []
        for try await event in stream.events { events.append(event) }
        return events
    }
    static func rejects(_ request: URLRequest) async throws {
        var rejected = false
        do { _ = try await collect(request) } catch { rejected = true }
        try check(rejected, "invalid stream accepted")
    }
    static func run() async throws {
        let policy = PiOwnedTaskEventTransport.configuration()
        try check(policy.connectionProxyDictionary?.isEmpty == true, "system proxies were not explicitly disabled")
        let request = try request(7)
        try check(request.url?.absoluteString == endpoint.absoluteString + "/tasks/events", "endpoint changed")
        try check(request.value(forHTTPHeaderField: "Last-Event-ID") == "7", "cursor missing")
        try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + capability, "capability missing")
        PiTaskEventWire.state.configure(body: Data((": keepalive\r\n\r\n" + frame(8) + frame(9)).utf8))
        let events = try await collect(request)
        try check(events.map(\.id) == [8, 9] && events.allSatisfy { $0.taskID == taskID }, "chunked frame decoding")
        let observed = PiTaskEventWire.state.snapshot().0
        try check(observed.count == 1 && observed[0].value(forHTTPHeaderField: "Last-Event-ID") == "7", "request wire cursor")

        for url in ["https://example.invalid", "http://localhost:45678", "http://127.0.0.1:45678/other", "http://user@127.0.0.1:45678", "http://127.0.0.1:45678?x=1", "http://127.0.0.1:45678#x", "http://127.0.0.1:0"] {
            var rejected = false
            do { _ = try PiOwnedTaskEventTransport.request(endpoint: URL(string: url)!, capability: capability, after: 0) }
            catch { rejected = true }
            try check(rejected, "foreign endpoint accepted")
        }
        for invalidCapability in ["", "Bearer " + capability, capability + "\n"] {
            var rejected = false
            do { _ = try PiOwnedTaskEventTransport.request(endpoint: endpoint, capability: invalidCapability, after: 0) }
            catch { rejected = true }
            try check(rejected, "invalid capability accepted")
        }
        var negative = request
        negative.setValue("-1", forHTTPHeaderField: "Last-Event-ID")
        var wrongPath = request
        wrongPath.url = endpoint.appendingPathComponent("assistant/messages")
        var foreign = request
        foreign.url = URL(string: "https://example.invalid/tasks/events")
        var unauthenticated = request
        unauthenticated.setValue(nil, forHTTPHeaderField: "Authorization")
        var mutation = request
        mutation.httpMethod = "POST"
        for invalid in [negative, wrongPath, foreign, unauthenticated, mutation] {
            PiTaskEventWire.state.configure()
            try await rejects(invalid)
            try check(PiTaskEventWire.state.snapshot().0.isEmpty, "invalid request reached transport")
        }
        PiTaskEventWire.state.configure(status: 409)
        var reset = false
        do { _ = try await collect(request) } catch AssistantTaskEventError.cursorReset { reset = true }
        try check(reset, "cursor reset was not typed")
        let redirectSession = URLSession(configuration: .ephemeral)
        let redirectTask = redirectSession.dataTask(with: request)
        let redirectResponse = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.invalid/tasks/events"])!
        var redirectedRequest = request
        redirectedRequest.url = URL(string: "https://example.invalid/tasks/events")!
        let redirect: URLRequest? = await withCheckedContinuation { continuation in
            PiOwnedEventRedirectGuard().urlSession(redirectSession, task: redirectTask, willPerformHTTPRedirection: redirectResponse,
                newRequest: redirectedRequest, completionHandler: { continuation.resume(returning: $0) })
        }
        redirectTask.cancel()
        redirectSession.invalidateAndCancel()
        try check(redirect == nil, "redirect retained authenticated request")
        for status in [301, 302, 307, 401, 403, 500] {
            PiTaskEventWire.state.configure(status: status)
            try await rejects(request)
            try check(PiTaskEventWire.state.snapshot().0.count == 1, "refused response caused another request")
        }
        for (type, body) in [("application/json", frame(8)), ("text/event-stream", "id: 8\nevent: task\ndata: {\"id\":9,\"task_id\":\"\(taskID)\"}\n\n"), ("text/event-stream", String(repeating: "x", count: NativeTaskEventDecoder.maximumFrameBytes + 1))] {
            PiTaskEventWire.state.configure(type: type, body: Data(body.utf8))
            try await rejects(request)
        }
        PiTaskEventWire.state.configure(body: Data((1...300).map { frame(Int64($0)) }.joined().utf8), hold: true)
        let overflow = connection(request)
        let overflowDeadline = ContinuousClock.now + .seconds(3)
        while PiTaskEventWire.state.snapshot().1 == 0 {
            try check(ContinuousClock.now < overflowDeadline, "overflow did not close transport")
            try await Task.sleep(for: .milliseconds(5))
        }
        var rejectedOverflow = false
        do { for try await _ in overflow.events {} } catch { rejectedOverflow = true }
        overflow.cancel()
        try check(rejectedOverflow, "unconsumed stream buffer was unbounded")

        PiTaskEventWire.state.configure(hold: true)
        let held = connection(request)
        let waiting = Task { for try await _ in held.events {} }
        let deadline = ContinuousClock.now + .seconds(3)
        while PiTaskEventWire.state.snapshot().0.isEmpty {
            try check(ContinuousClock.now < deadline, "held request never started")
            try await Task.sleep(for: .milliseconds(5))
        }
        held.cancel()
        var canceled = false
        do { try await waiting.value } catch { canceled = true }
        while PiTaskEventWire.state.snapshot().1 == 0 {
            try check(ContinuousClock.now < deadline, "socket task was not stopped")
            try await Task.sleep(for: .milliseconds(5))
        }
        try check(canceled, "held consumer did not finish on cancellation")
        print("PASS: owned task event transport, bounded decoding and buffering, cursor reset, endpoint/auth refusal, cancellation")
    }
}
