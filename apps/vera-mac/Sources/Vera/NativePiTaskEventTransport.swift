import Foundation
import VeraAssistantUI

struct PiOwnedTaskEventConnection: Sendable {
    let events: AsyncThrowingStream<AssistantTaskEvent, Error>
    let cancel: @Sendable () -> Void
}

struct PiOwnedTaskEventTransport: Sendable {
    let open: @Sendable (URLRequest) -> PiOwnedTaskEventConnection
    static let maximumBufferedEvents = 256
    static let requestTimeout: TimeInterval = 45
    static let resourceTimeout: TimeInterval = 300
    static let live = PiOwnedTaskEventTransport { open($0) }

    static func request(endpoint: URL, capability: String, after: Int64) throws -> URLRequest {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port,
              (1...65535).contains(port), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              capability.utf8.count == 72, capability.allSatisfy({ "0123456789abcdef-".contains($0) }), after >= 0 else {
            throw PiBrokerError.unauthorized
        }
        var request = URLRequest(url: endpoint.appendingPathComponent("tasks/events"))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + capability, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(String(after), forHTTPHeaderField: "Last-Event-ID")
        return request
    }

    static func validate(_ request: URLRequest) throws {
        guard request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.percentEncodedPath == "/tasks/events", let rawCursor = request.value(forHTTPHeaderField: "Last-Event-ID"),
              let cursor = Int64(rawCursor), String(cursor) == rawCursor,
              let authorization = request.value(forHTTPHeaderField: "Authorization"), authorization.hasPrefix("Bearer "),
              request.value(forHTTPHeaderField: "Accept") == "text/event-stream" else { throw PiBrokerError.unauthorized }
        parts.path = ""
        guard let endpoint = parts.url else { throw PiBrokerError.unauthorized }
        _ = try self.request(endpoint: endpoint, capability: String(authorization.dropFirst(7)), after: cursor)
    }

    static func configuration(protocolClasses: [AnyClass]? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.connectionProxyDictionary = [:]
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.protocolClasses = protocolClasses
        return configuration
    }

    static func open(_ request: URLRequest, protocolClasses: [AnyClass]? = nil) -> PiOwnedTaskEventConnection {
        let session = URLSession(configuration: configuration(protocolClasses: protocolClasses), delegate: PiOwnedEventRedirectGuard(), delegateQueue: nil)
        let (events, continuation) = AsyncThrowingStream<AssistantTaskEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(maximumBufferedEvents))
        let operation = Task {
            defer { session.invalidateAndCancel() }
            do {
                try validate(request)
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, response.url == request.url else { throw PiBrokerError.unavailable }
                if response.statusCode == 409 { throw AssistantTaskEventError.cursorReset }
                guard response.statusCode == 200 else { throw PiBrokerError.unavailable }
                guard response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream" else {
                    throw PiBrokerError.invalid
                }
                var decoder = NativeTaskEventDecoder()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if let event = try decoder.consume(byte: byte) {
                        guard UUID(uuidString: event.taskID) != nil else { throw PiBrokerError.invalid }
                        switch continuation.yield(AssistantTaskEvent(id: event.id, taskID: event.taskID)) {
                        case .enqueued: break
                        case .dropped: throw PiBrokerError.unavailable
                        case .terminated: return
                        @unknown default: throw PiBrokerError.unavailable
                        }
                    }
                }
                continuation.finish()
            } catch is CancellationError { continuation.finish(throwing: CancellationError()) }
            catch AssistantTaskEventError.cursorReset { continuation.finish(throwing: AssistantTaskEventError.cursorReset) }
            catch { continuation.finish(throwing: PiBrokerError.unavailable) }
        }
        let cancel: @Sendable () -> Void = {
            operation.cancel()
            session.invalidateAndCancel()
            continuation.finish(throwing: CancellationError())
        }
        continuation.onTermination = { _ in operation.cancel(); session.invalidateAndCancel() }
        return PiOwnedTaskEventConnection(events: events, cancel: cancel)
    }
}

final class PiOwnedEventRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
