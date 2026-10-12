import Foundation
import MCP
import Synchronization

enum NativeMCPAuthorizationError: Error, Sendable, Equatable {
    case invalidBinding, invalidCredential, expired
}

final class NativeMCPAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let serverID: String
    private let endpoint: URL
    private let expiresAt: Date
    private let monotonicDeadline: ContinuousClock.Instant
    private struct State {
        var token: String?
        var observers: [UUID: @Sendable () -> Void] = [:]
        var expiryTask: Task<Void, Never>?
    }
    private let state: Mutex<State>

    init(serverID: String, endpoint: URL, token: String, expiresAt: Date, allowLoopbackFixture: Bool = false) throws {
        guard !serverID.isEmpty, serverID.utf8.count <= 256,
              let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.scheme == "https" || (allowLoopbackFixture && endpoint.scheme == "http" && ["127.0.0.1", "[::1]"].contains(host)) else {
            throw NativeMCPAuthorizationError.invalidBinding
        }
        let punctuation = Set("-._~+/=".utf8)
        guard !token.isEmpty, token.utf8.count <= 8192, token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || punctuation.contains($0) }) else {
            throw NativeMCPAuthorizationError.invalidCredential
        }
        let duration = expiresAt.timeIntervalSinceNow
        guard duration.isFinite, duration > 0, duration <= 3600 else { throw NativeMCPAuthorizationError.expired }
        self.serverID = serverID
        self.endpoint = endpoint
        self.expiresAt = expiresAt
        monotonicDeadline = ContinuousClock.now.advanced(by: .seconds(duration))
        state = Mutex(State(token: token))
        let task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            self?.revoke()
        }
        state.withLock { $0.expiryTask = task }
    }

    deinit { state.withLock { $0.expiryTask?.cancel() } }

    var description: String { "NativeMCPAuthorization(redacted)" }
    var debugDescription: String { description }

    func isValid(serverID: String, endpoint: URL) -> Bool {
        guard self.serverID == serverID, self.endpoint == endpoint else { return false }
        guard !expired else { revoke(); return false }
        return state.withLock { $0.token != nil }
    }

    func revoke() {
        let captured = state.withLock { state -> (Task<Void, Never>?, [@Sendable () -> Void]) in
            state.token = nil
            let result = (state.expiryTask, Array(state.observers.values))
            state.expiryTask = nil
            state.observers = [:]
            return result
        }
        captured.0?.cancel()
        captured.1.forEach { $0() }
    }

    @discardableResult
    func onInvalidation(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let callNow = state.withLock { state in
            guard state.token != nil, !expired else { return true }
            state.observers[id] = callback
            return false
        }
        if callNow { revoke(); callback() }
        return id
    }

    func removeInvalidationObserver(_ id: UUID) { state.withLock { _ = $0.observers.removeValue(forKey: id) } }

    func makeAuthorizer() -> any HTTPClientAuthorizer { NativeMCPLeaseAuthorizer(authorization: self) }

    func performAuthorizedRequest(_ request: URLRequest, perform: (URLRequest) -> Void) throws {
        guard request.url == endpoint else { throw NativeMCPTransportError.authenticationRequired }
        try state.withLock { state in
            guard !expired, let token = state.token else { throw NativeMCPTransportError.authenticationRequired }
            var result = request
            result.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            perform(result)
        }
    }

    private var expired: Bool { Date() >= expiresAt || ContinuousClock.now >= monotonicDeadline }

    func validateResponse(_ data: Data, endpoint: URL, includingDecodedJSON: Bool = false) throws {
        guard isValid(serverID: serverID, endpoint: endpoint) else { throw NativeMCPTransportError.authenticationRequired }
        let token = state.withLock { $0.token }
        guard let token else { throw NativeMCPTransportError.authenticationRequired }
        if String(data: data, encoding: .utf8)?.contains(token) == true {
            throw NativeMCPTransportError.malformedResponse
        }
        if includingDecodedJSON, let object = try? JSONSerialization.jsonObject(with: data), Self.contains(token, in: object) {
            throw NativeMCPTransportError.malformedResponse
        }
    }

    private static func contains(_ token: String, in value: Any) -> Bool {
        if let value = value as? String { return value.contains(token) }
        if let value = value as? [String: Any] { return value.contains { $0.key.contains(token) || contains(token, in: $0.value) } }
        if let value = value as? [Any] { return value.contains { contains(token, in: $0) } }
        return false
    }

    fileprivate func header(for endpoint: URL) -> String? {
        guard isValid(serverID: serverID, endpoint: endpoint) else { return nil }
        return state.withLock { $0.token.map { "Bearer " + $0 } }
    }
}

private final class NativeMCPLeaseAuthorizer: HTTPClientAuthorizer, Sendable {
    private let authorization: NativeMCPAuthorization
    let maxAuthorizationAttempts = 1

    init(authorization: NativeMCPAuthorization) { self.authorization = authorization }
    func validateEndpointSecurity(for endpoint: URL) throws {
        guard authorization.header(for: endpoint) != nil else { throw NativeMCPTransportError.authenticationRequired }
    }
    func authorizationHeader(for endpoint: URL) -> String? { authorization.header(for: endpoint) }
    func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {}
    func handleChallenge(statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?, session: URLSession) async throws -> Bool {
        _ = DefaultOAuthWWWAuthenticateParser().parseBearer(from: headers)
        authorization.revoke()
        return false
    }
}
