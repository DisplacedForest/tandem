import Foundation
import MCP
import Logging
import Synchronization

protocol NativeMCPConnection: Sendable {
    func connect() async throws
    func listTools(cursor: String?) async throws -> NativeMCPPage
    func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue
    func disconnect() async
}

struct NativeMCPDiscoveredTool: Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: NativeJSONValue
}

struct NativeMCPPage: Sendable, Equatable {
    let tools: [NativeMCPDiscoveredTool]
    let nextCursor: String?
}

enum NativeMCPTransportError: Error, Sendable, Equatable {
    case invalidEndpoint, authenticationRequired, unsupportedProtocol, malformedResponse
    case responseTooLarge, timeout, disconnected, busy, network, redirectDenied, remoteFailure
}

actor NativeMCPSDKConnection: NativeMCPConnection {
    private let endpoint: URL
    private let timeout: TimeInterval
    private let maximumResponseBytes: Int
    private var client: Client?
    private var boundary: NativeMCPNetworkBoundary?
    private var boundaryID: String?
    private var busy = false
    private var generation = 0

    init(endpoint: URL, timeout: TimeInterval = 20, maximumResponseBytes: Int = 1_048_576) throws {
        guard let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.query == nil,
              endpoint.scheme == "https" || (endpoint.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              timeout.isFinite, timeout > 0, timeout <= 300,
              maximumResponseBytes > 0, maximumResponseBytes <= 8_000_000 else {
            throw NativeMCPTransportError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    func connect() async throws {
        guard !busy else { throw NativeMCPTransportError.busy }
        busy = true
        let expectedGeneration = generation + 1
        await disconnect()
        busy = false
        try Task.checkCancellation()
        guard generation == expectedGeneration else { throw NativeMCPTransportError.disconnected }
        let guardrail = NativeMCPNetworkBoundary(endpoint: endpoint, maximumBytes: maximumResponseBytes, timeout: timeout)
        let identifier = UUID().uuidString
        NativeMCPBoundedURLProtocol.boundaries.withLock { $0[identifier] = guardrail }
        boundaryID = identifier
        boundary = guardrail
        let configuration = NativeMCPNetworkBoundary.configuration(timeout: timeout)
        configuration.protocolClasses = [NativeMCPBoundedURLProtocol.self]
        let transport = HTTPClientTransport(endpoint: endpoint, configuration: configuration, streaming: false, requestModifier: { request in
            var request = request
            request.setValue(identifier, forHTTPHeaderField: NativeMCPBoundedURLProtocol.marker)
            return request
        })
        let candidate = Client(name: "Vera", version: "1", configuration: .strict)
        client = candidate
        let validated = NativeMCPValidatingTransport(underlying: transport, boundary: guardrail) { await candidate.disconnect() }
        try await perform {
            let result = try await candidate.connect(transport: validated)
            guard Version.supported.contains(result.protocolVersion), result.capabilities.tools != nil else {
                throw NativeMCPTransportError.unsupportedProtocol
            }
            await transport.setProtocolVersion(result.protocolVersion)
        }
    }

    func listTools(cursor: String? = nil) async throws -> NativeMCPPage {
        guard let client else { throw NativeMCPTransportError.disconnected }
        return try await perform {
            let page = try await client.listTools(cursor: cursor)
            return NativeMCPPage(tools: try page.tools.map {
                NativeMCPDiscoveredTool(name: $0.name, description: $0.description ?? "", inputSchema: try Self.native($0.inputSchema))
            }, nextCursor: page.nextCursor)
        }
    }

    func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue {
        guard let client else { throw NativeMCPTransportError.disconnected }
        return try await perform {
            let context: RequestContext<CallTool.Result> = try await client.callTool(name: name, arguments: arguments.mapValues(Self.sdk))
            let result = try await context.value
            return try Self.native(Value(result))
        }
    }

    func disconnect() async {
        generation += 1
        let previous = client
        client = nil
        boundary?.cancel()
        boundary = nil
        if let boundaryID {
            NativeMCPBoundedURLProtocol.boundaries.withLock { _ = $0.removeValue(forKey: boundaryID) }
        }
        boundaryID = nil
        await previous?.disconnect()
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !busy else { throw NativeMCPTransportError.busy }
        try Task.checkCancellation()
        busy = true
        defer { busy = false }
        let timeout = timeout
        let current = client
        let guardrail = boundary
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: T.self) { group in
                    group.addTask { try await operation() }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeout))
                        guardrail?.fail(.timeout)
                        guardrail?.cancel()
                        await current?.disconnect()
                        throw NativeMCPTransportError.timeout
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } onCancel: {
                guardrail?.cancel()
                Task { await current?.disconnect() }
            }
        } catch {
            let failure = guardrail?.failure
            await disconnect()
            if Task.isCancelled { throw CancellationError() }
            if let failure { throw failure }
            if let error = error as? NativeMCPTransportError { throw error }
            if let error = error as? URLError {
                throw error.code == .timedOut ? NativeMCPTransportError.timeout : NativeMCPTransportError.network
            }
            if let error = error as? MCPError {
                switch error {
                case .connectionClosed, .transportError: throw NativeMCPTransportError.network
                default: throw NativeMCPTransportError.remoteFailure
                }
            }
            throw NativeMCPTransportError.malformedResponse
        }
    }

    private static func sdk(_ value: NativeJSONValue) -> Value {
        switch value {
        case .object(let value): return .object(value.mapValues(sdk))
        case .array(let value): return .array(value.map(sdk))
        case .string(let value): return .string(value)
        case .number(let value): return .double(value)
        case .bool(let value): return .bool(value)
        case .null: return .null
        }
    }

    private static func native(_ value: Value) throws -> NativeJSONValue {
        switch value {
        case .object(let value): return .object(try value.mapValues(native))
        case .array(let value): return .array(try value.map(native))
        case .string(let value): return .string(value)
        case .int(let value):
            guard let exact = Double(exactly: value) else { throw NativeMCPTransportError.malformedResponse }
            return .number(exact)
        case .double(let value): return .number(value)
        case .bool(let value): return .bool(value)
        case .null: return .null
        case .data: return .string(try JSONDecoder().decode(String.self, from: JSONEncoder().encode(value)))
        }
    }
}

private final class NativeMCPNetworkBoundary: Sendable {
    let endpoint: URL
    let maximumBytes: Int
    let timeout: TimeInterval
    private struct State {
        var failure: NativeMCPTransportError?
        var sessions: [URLSession] = []
        var cancelled = false
    }
    private let state = Mutex(State())

    init(endpoint: URL, maximumBytes: Int, timeout: TimeInterval) {
        self.endpoint = endpoint
        self.maximumBytes = maximumBytes
        self.timeout = timeout
    }

    var failure: NativeMCPTransportError? { state.withLock { $0.failure } }
    func fail(_ error: NativeMCPTransportError) { state.withLock { if $0.failure == nil { $0.failure = error } } }
    func add(_ session: URLSession) -> Bool {
        state.withLock {
            guard !$0.cancelled else { return false }
            $0.sessions.append(session)
            return true
        }
    }
    func remove(_ session: URLSession) { state.withLock { $0.sessions.removeAll { $0 === session } } }
    func cancel() {
        let sessions = state.withLock { state in
            state.cancelled = true
            let result = state.sessions
            state.sessions = []
            return result
        }
        sessions.forEach { $0.invalidateAndCancel() }
    }
    static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = [:]
        return configuration
    }
}

private final class NativeMCPBoundedURLProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    static let marker = "X-Vera-MCP-Boundary"
    static let boundaries = Mutex<[String: NativeMCPNetworkBoundary]>([:])
    private var guardrail: NativeMCPNetworkBoundary?
    private var session: URLSession?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var terminal = false
    private let lock = NSRecursiveLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        lock.lock()
        defer { lock.unlock() }
        guard let identifier = request.value(forHTTPHeaderField: Self.marker),
              let guardrail = Self.boundaries.withLock({ $0[identifier] }), request.url == guardrail.endpoint else {
            finish(NativeMCPTransportError.invalidEndpoint)
            return
        }
        self.guardrail = guardrail
        var outgoing = request
        outgoing.setValue(nil, forHTTPHeaderField: Self.marker)
        outgoing.setValue(nil, forHTTPHeaderField: "Authorization")
        outgoing.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        outgoing.setValue(nil, forHTTPHeaderField: "Cookie")
        let session = URLSession(configuration: NativeMCPNetworkBoundary.configuration(timeout: guardrail.timeout), delegate: self, delegateQueue: nil)
        self.session = session
        guard guardrail.add(session) else { finish(CancellationError()); return }
        session.dataTask(with: outgoing).resume()
    }

    override func stopLoading() {
        lock.lock()
        defer { lock.unlock() }
        terminal = true
        if let session { guardrail?.remove(session); session.invalidateAndCancel() }
        session = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        lock.lock()
        defer { lock.unlock() }
        guardrail?.fail(.redirectDenied)
        finish(NativeMCPTransportError.redirectDenied)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            guardrail?.fail(.authenticationRequired)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, let http = response as? HTTPURLResponse, let guardrail else { completionHandler(.cancel); return }
        if [401, 403].contains(http.statusCode) {
            guardrail.fail(.authenticationRequired)
            completionHandler(.cancel)
            finish(NativeMCPTransportError.authenticationRequired)
            return
        }
        if http.expectedContentLength > guardrail.maximumBytes {
            guardrail.fail(.responseTooLarge)
            completionHandler(.cancel)
            finish(NativeMCPTransportError.responseTooLarge)
            return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, let guardrail else { return }
        guard data.count <= guardrail.maximumBytes - body.count else {
            guardrail.fail(.responseTooLarge)
            finish(NativeMCPTransportError.responseTooLarge)
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return }
        if let error { finish(error); return }
        guard let response else { finish(NativeMCPTransportError.malformedResponse); return }
        if response.mimeType == "application/json", !body.isEmpty,
           (try? JSONSerialization.jsonObject(with: body)) == nil {
            guardrail?.fail(.malformedResponse)
            finish(NativeMCPTransportError.malformedResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        terminal = true
        client?.urlProtocolDidFinishLoading(self)
        guardrail?.remove(session)
        session.finishTasksAndInvalidate()
        self.session = nil
    }

    private func finish(_ error: Error) {
        guard !terminal else { return }
        terminal = true
        client?.urlProtocol(self, didFailWithError: error)
        if let session { guardrail?.remove(session); session.invalidateAndCancel() }
        session = nil
    }
}


private extension HTTPClientTransport {
    func setProtocolVersion(_ version: String) { protocolVersion = version }
}

private actor NativeMCPValidatingTransport: Transport {
    nonisolated let logger: Logger
    private let underlying: HTTPClientTransport
    private let boundary: NativeMCPNetworkBoundary
    private let onFailure: @Sendable () async -> Void
    private var forwarding: Task<Void, Never>?

    init(underlying: HTTPClientTransport, boundary: NativeMCPNetworkBoundary, onFailure: @escaping @Sendable () async -> Void) {
        self.underlying = underlying
        self.boundary = boundary
        self.onFailure = onFailure
        logger = underlying.logger
    }

    func connect() async throws { try await underlying.connect() }
    func send(_ data: Data) async throws { try await underlying.send(data) }
    func disconnect() async {
        forwarding?.cancel()
        forwarding = nil
        await underlying.disconnect()
    }
    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [underlying, boundary, onFailure] in
                do {
                    for try await data in await underlying.receive() {
                        try Task.checkCancellation()
                        do {
                            try NativeTaskJSON.validate(data, maximumBytes: boundary.maximumBytes)
                            _ = try JSONSerialization.jsonObject(with: data)
                        } catch {
                            boundary.fail(.malformedResponse)
                            continuation.finish(throwing: NativeMCPTransportError.malformedResponse)
                            boundary.cancel()
                            await onFailure()
                            return
                        }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            forwarding = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
