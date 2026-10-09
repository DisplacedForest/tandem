import Foundation
import CryptoKit
import MCP
import Synchronization

enum NativeMCPOAuthError: Error, Sendable, Equatable {
    case invalidConsent, invalidMetadata, invalidCallback, invalidToken, expired, cancelled, busy, invalidState, network, responseTooLarge, redirectDenied
}

struct NativeMCPOAuthConsent: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let serverID: String
    let resource: URL
    let issuer: URL
    let protectedResourceMetadataURL: URL
    let authorizationServerMetadataURL: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let clientID: String
    let redirectURI: URL
    let scopes: Set<String>
    let generation: UUID
    let expiresAt: Date
    fileprivate let deadline: ContinuousClock.Instant
    fileprivate let allowLoopbackFixture: Bool

    init(serverID: String, resource: URL, issuer: URL, protectedResourceMetadataURL: URL, authorizationServerMetadataURL: URL, authorizationEndpoint: URL, tokenEndpoint: URL, clientID: String, redirectURI: URL, scopes: Set<String>, generation: UUID, expiresAt: Date, allowLoopbackFixture: Bool = false, callbackScheme: String = "vera-oauth") throws {
        let duration = expiresAt.timeIntervalSinceNow
        guard !serverID.isEmpty, serverID.utf8.count <= 256,
              !clientID.isEmpty, clientID.utf8.count <= 1024, clientID.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
              duration.isFinite, duration > 0, duration <= 3600,
              !scopes.isEmpty, scopes.count <= 64, scopes.allSatisfy(Self.validScope) else { throw NativeMCPOAuthError.invalidConsent }
        for url in [resource, issuer, protectedResourceMetadataURL, authorizationServerMetadataURL, authorizationEndpoint, tokenEndpoint] {
            guard Self.validURL(url, allowLoopbackFixture: allowLoopbackFixture) else { throw NativeMCPOAuthError.invalidConsent }
        }
        guard callbackScheme == "vera-oauth" || (allowLoopbackFixture && callbackScheme == "vera-fixture"),
              let scheme = redirectURI.scheme, ["https", callbackScheme].contains(scheme),
              redirectURI.baseURL == nil, let callbackHost = redirectURI.host, !callbackHost.isEmpty, redirectURI.user == nil, redirectURI.password == nil,
              redirectURI.query == nil, redirectURI.fragment == nil, redirectURI.absoluteString.utf8.count <= 2048,
              URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)?.url?.absoluteString == redirectURI.absoluteString else { throw NativeMCPOAuthError.invalidConsent }
        self.serverID = serverID
        self.resource = resource
        self.issuer = issuer
        self.protectedResourceMetadataURL = protectedResourceMetadataURL
        self.authorizationServerMetadataURL = authorizationServerMetadataURL
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.generation = generation
        self.expiresAt = expiresAt
        self.deadline = ContinuousClock.now.advanced(by: .seconds(duration))
        self.allowLoopbackFixture = allowLoopbackFixture
    }

    var description: String { "NativeMCPOAuthConsent(redacted)" }
    var debugDescription: String { description }

    fileprivate static func validURL(_ url: URL, allowLoopbackFixture: Bool) -> Bool {
        guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.absoluteString.utf8.count <= 2048,
              url.baseURL == nil else { return false }
        return url.scheme == "https" || (allowLoopbackFixture && url.scheme == "http" && ["127.0.0.1", "[::1]"].contains(host))
    }

    fileprivate static func validScope(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { $0 == 33 || (35...91).contains($0) || (93...126).contains($0) }
    }
}

final class NativeMCPOAuthGate: Sendable {
    private struct State {
        var cancelled = false
        var lease: NativeMCPAuthorization?
        var handlers: [UUID: @Sendable () -> Void] = [:]
        var expiryTask: Task<Void, Never>?
    }
    private let state = Mutex(State())
    private let expiresAt: Date
    private let deadline: ContinuousClock.Instant

    init(consent: NativeMCPOAuthConsent) {
        expiresAt = consent.expiresAt
        deadline = consent.deadline
        let deadline = consent.deadline
        let task = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            self?.cancel()
        }
        state.withLock { $0.expiryTask = task }
    }

    deinit { state.withLock { $0.expiryTask?.cancel() } }

    func check() throws {
        try state.withLock { value in
            guard !value.cancelled else { throw NativeMCPOAuthError.cancelled }
            guard Date() < expiresAt, ContinuousClock.now < deadline else { throw NativeMCPOAuthError.expired }
        }
        try Task.checkCancellation()
    }

    func perform(_ body: () throws -> Void) throws {
        try state.withLock { value in
            guard !value.cancelled else { throw NativeMCPOAuthError.cancelled }
            guard Date() < expiresAt, ContinuousClock.now < deadline else { throw NativeMCPOAuthError.expired }
            try Task.checkCancellation()
            try body()
        }
    }

    func install(_ lease: NativeMCPAuthorization) throws {
        let previous = try state.withLock { value in
            guard !value.cancelled else { throw NativeMCPOAuthError.cancelled }
            guard Date() < expiresAt, ContinuousClock.now < deadline else { throw NativeMCPOAuthError.expired }
            let previous = value.lease
            value.lease = lease
            return previous
        }
        previous?.revoke()
    }

    func register(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let call = state.withLock { value in
            guard !value.cancelled, Date() < expiresAt, ContinuousClock.now < deadline else { return true }
            value.handlers[id] = handler
            return false
        }
        if call { handler() }
        return id
    }

    func remove(_ id: UUID) { state.withLock { _ = $0.handlers.removeValue(forKey: id) } }

    func cancel() {
        let captured = state.withLock { value in
            value.cancelled = true
            let captured = (value.lease, Array(value.handlers.values), value.expiryTask)
            value.lease = nil
            value.handlers.removeAll()
            value.expiryTask = nil
            return captured
        }
        captured.2?.cancel()
        captured.0?.revoke()
        captured.1.forEach { $0() }
    }
}

struct NativeMCPOAuthRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: URL
    let body: Data?
    let maximumBytes = 32768
    let timeout: TimeInterval = 20
    var description: String { "NativeMCPOAuthRequest(redacted)" }
    var debugDescription: String { description }
}

struct NativeMCPOAuthResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: URL
    let status: Int
    let contentType: String
    let body: Data
    var description: String { "NativeMCPOAuthResponse(redacted)" }
    var debugDescription: String { description }
}

protocol NativeMCPOAuthTransport: Sendable {
    func send(_ request: NativeMCPOAuthRequest, gate: NativeMCPOAuthGate) async throws -> NativeMCPOAuthResponse
}

actor NativeMCPOAuthSession: CustomStringConvertible, CustomDebugStringConvertible {
    nonisolated let consent: NativeMCPOAuthConsent
    nonisolated let metadataDigest: String
    nonisolated private let gate: NativeMCPOAuthGate
    private let transport: any NativeMCPOAuthTransport
    private let supportsRefresh: Bool
    private var verifier: String?
    private var state: String?
    private var started = false
    private var consumed = false
    private var busy = false
    private var refreshToken: String?
    private var grantedScopes: Set<String>
    private var eraseObserver: UUID?

    private init(consent: NativeMCPOAuthConsent, transport: any NativeMCPOAuthTransport, gate: NativeMCPOAuthGate, metadataDigest: String, supportsRefresh: Bool) {
        self.consent = consent
        self.transport = transport
        self.gate = gate
        self.metadataDigest = metadataDigest
        self.supportsRefresh = supportsRefresh
        self.grantedScopes = consent.scopes
    }

    nonisolated var description: String { "NativeMCPOAuthSession(redacted)" }
    nonisolated var debugDescription: String { description }

    deinit { gate.cancel() }

    static func discover(consent: NativeMCPOAuthConsent, transport: any NativeMCPOAuthTransport = NativeMCPOAuthHTTPTransport()) async throws -> NativeMCPOAuthSession {
        let gate = NativeMCPOAuthGate(consent: consent)
        do {
            let resourceData = try await receive(NativeMCPOAuthRequest(url: consent.protectedResourceMetadataURL, body: nil), transport: transport, gate: gate)
            let resource = try object(resourceData, failure: .invalidMetadata)
            guard resource["resource"] as? String == consent.resource.absoluteString,
                  let servers = resource["authorization_servers"] as? [String], servers.count <= 8,
                  servers.contains(consent.issuer.absoluteString) else { throw NativeMCPOAuthError.invalidMetadata }
            if let supported = resource["scopes_supported"] {
                guard let supported = supported as? [String], consent.scopes.isSubset(of: Set(supported)) else { throw NativeMCPOAuthError.invalidMetadata }
            }
            let issuerData = try await receive(NativeMCPOAuthRequest(url: consent.authorizationServerMetadataURL, body: nil), transport: transport, gate: gate)
            let issuer = try object(issuerData, failure: .invalidMetadata)
            guard issuer["issuer"] as? String == consent.issuer.absoluteString,
                  issuer["authorization_endpoint"] as? String == consent.authorizationEndpoint.absoluteString,
                  issuer["token_endpoint"] as? String == consent.tokenEndpoint.absoluteString,
                  (issuer["code_challenge_methods_supported"] as? [String])?.contains("S256") == true,
                  (issuer["response_types_supported"] as? [String])?.contains("code") == true,
                  (issuer["token_endpoint_auth_methods_supported"] as? [String])?.contains("none") == true,
                  (issuer["authorization_response_iss_parameter_supported"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) == true,
                  let grants = issuer["grant_types_supported"] as? [String], grants.contains("authorization_code"),
                  let scopes = issuer["scopes_supported"] as? [String], consent.scopes.isSubset(of: Set(scopes)) else { throw NativeMCPOAuthError.invalidMetadata }
            try gate.check()
            var digestData = Data()
            for data in [resourceData, issuerData] {
                digestData.append(Data(String(data.count).utf8))
                digestData.append(0)
                digestData.append(data)
            }
            let digest = SHA256.hash(data: digestData).map { String(format: "%02x", $0) }.joined()
            let session = NativeMCPOAuthSession(consent: consent, transport: transport, gate: gate, metadataDigest: digest, supportsRefresh: grants.contains("refresh_token"))
            await session.armExpiry()
            return session
        } catch {
            gate.cancel()
            throw safe(error)
        }
    }

    private func armExpiry() {
        eraseObserver = gate.register { [weak self] in Task { await self?.erase() } }
    }

    func authorizationURL(generation: UUID) throws -> URL {
        try validate(generation)
        guard !started, !consumed, !busy else { throw NativeMCPOAuthError.invalidState }
        started = true
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        do {
            let url = try OAuthAuthorizationCodeFlow().buildURL(authorizationEndpoint: consent.authorizationEndpoint, resource: consent.resource, redirectURI: consent.redirectURI, clientID: consent.clientID, codeChallenge: PKCE.makeChallenge(from: verifier), scopes: consent.scopes, state: state, scopeSerializer: DefaultOAuthScopeSelector())
            self.verifier = verifier
            self.state = state
            return url
        } catch { revoke(); throw Self.safe(error) }
    }

    func complete(callback: URL, generation: UUID) async throws -> NativeMCPAuthorization {
        try validate(generation)
        guard !busy else { throw NativeMCPOAuthError.busy }
        guard started, !consumed, let verifier, let state else { throw NativeMCPOAuthError.invalidState }
        consumed = true
        self.verifier = nil
        self.state = nil
        busy = true
        defer { busy = false }
        do {
            let code = try extract(callback, expectedState: state)
            let body = Self.form(["grant_type": "authorization_code", "code": code, "client_id": consent.clientID, "redirect_uri": consent.redirectURI.absoluteString, "code_verifier": verifier, "resource": consent.resource.absoluteString])
            return try await exchange(body: body, generation: generation)
        } catch { revoke(); throw Self.safe(error) }
    }

    func refresh(generation: UUID) async throws -> NativeMCPAuthorization {
        try validate(generation)
        guard !busy else { throw NativeMCPOAuthError.busy }
        guard consumed, supportsRefresh, let token = refreshToken else { throw NativeMCPOAuthError.invalidState }
        refreshToken = nil
        busy = true
        defer { busy = false }
        do {
            let body = Self.form(["grant_type": "refresh_token", "refresh_token": token, "client_id": consent.clientID, "resource": consent.resource.absoluteString, "scope": grantedScopes.sorted().joined(separator: " ")])
            let lease = try await exchange(body: body, generation: generation)
            if refreshToken == nil { refreshToken = token }
            return lease
        } catch { revoke(); throw Self.safe(error) }
    }

    nonisolated func revoke() { gate.cancel() }
    nonisolated func cancel() { gate.cancel() }

    private func erase() {
        verifier = nil
        state = nil
        refreshToken = nil
        if let eraseObserver { gate.remove(eraseObserver) }
        eraseObserver = nil
    }

    private func validate(_ generation: UUID) throws {
        guard generation == consent.generation else { throw NativeMCPOAuthError.invalidState }
        try gate.check()
    }

    private func extract(_ callback: URL, expectedState: String) throws -> String {
        guard callback.absoluteString.utf8.count <= 8192,
              var components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.fragment == nil,
              let items = components.queryItems, items.count <= 4,
              Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["state", "code", "iss"].contains($0.name) && $0.value != nil }),
              items.first(where: { $0.name == "iss" })?.value == consent.issuer.absoluteString,
              items.first(where: { $0.name == "state" })?.value == expectedState,
              let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 4096, code.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { throw NativeMCPOAuthError.invalidCallback }
        components.query = nil
        guard components.url?.absoluteString == consent.redirectURI.absoluteString else { throw NativeMCPOAuthError.invalidCallback }
        do { return try OAuthAuthorizationCodeFlow().extractCode(from: callback, expectedRedirectURI: consent.redirectURI, expectedState: expectedState) }
        catch { throw NativeMCPOAuthError.invalidCallback }
    }

    private func exchange(body: Data, generation: UUID) async throws -> NativeMCPAuthorization {
        try validate(generation)
        let request = NativeMCPOAuthRequest(url: consent.tokenEndpoint, body: body)
        let data = try await Self.receive(request, transport: transport, gate: gate)
        try validate(generation)
        let value = try Self.object(data, failure: .invalidToken)
        guard Set(value.keys).isSubset(of: ["access_token", "token_type", "expires_in", "refresh_token", "scope", "resource"]),
              let token = value["access_token"] as? String,
              (value["token_type"] as? String)?.lowercased() == "bearer",
              let lifetime = value["expires_in"] as? NSNumber, CFGetTypeID(lifetime) != CFBooleanGetTypeID(),
              lifetime.doubleValue.isFinite, lifetime.doubleValue > 0, lifetime.doubleValue <= 31_536_000,
              lifetime.doubleValue.rounded() == lifetime.doubleValue else { throw NativeMCPOAuthError.invalidToken }
        if let resource = value["resource"] { guard resource as? String == consent.resource.absoluteString else { throw NativeMCPOAuthError.invalidToken } }
        var scopes = grantedScopes
        if let scope = value["scope"] {
            guard let text = scope as? String else { throw NativeMCPOAuthError.invalidToken }
            let parts = text.components(separatedBy: " ")
            guard parts.count <= 64, parts.allSatisfy(NativeMCPOAuthConsent.validScope), Set(parts).count == parts.count else { throw NativeMCPOAuthError.invalidToken }
            scopes = Set(parts)
        }
        guard !scopes.isEmpty, scopes.isSubset(of: grantedScopes) else { throw NativeMCPOAuthError.invalidToken }
        var nextRefresh: String?
        if let candidate = value["refresh_token"] {
            guard supportsRefresh, let candidate = candidate as? String, !candidate.isEmpty,
                  candidate.utf8.count <= 8192, candidate.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { throw NativeMCPOAuthError.invalidToken }
            nextRefresh = candidate
        }
        let remaining = min(consent.expiresAt.timeIntervalSinceNow, ContinuousClock.now.duration(to: consent.deadline).seconds)
        guard remaining > 0 else { throw NativeMCPOAuthError.expired }
        let expiry = min(consent.expiresAt, Date().addingTimeInterval(min(lifetime.doubleValue, remaining, 3600)))
        let lease: NativeMCPAuthorization
        do { lease = try NativeMCPAuthorization(serverID: consent.serverID, endpoint: consent.resource, token: token, expiresAt: expiry, allowLoopbackFixture: consent.allowLoopbackFixture) }
        catch { throw NativeMCPOAuthError.invalidToken }
        do {
            try validate(generation)
            try gate.install(lease)
            try validate(generation)
        } catch { lease.revoke(); throw error }
        grantedScopes = scopes
        refreshToken = nextRefresh
        return lease
    }

    private static func receive(_ request: NativeMCPOAuthRequest, transport: any NativeMCPOAuthTransport, gate: NativeMCPOAuthGate) async throws -> Data {
        try gate.check()
        do {
            let response = try await withTaskCancellationHandler {
                try await transport.send(request, gate: gate)
            } onCancel: { gate.cancel() }
            try gate.check()
            guard response.url.absoluteString == request.url.absoluteString, response.status == 200,
                  response.contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw NativeMCPOAuthError.network }
            guard response.body.count <= request.maximumBytes else { throw NativeMCPOAuthError.responseTooLarge }
            return response.body
        } catch { throw safe(error) }
    }

    private static func object(_ data: Data, failure: NativeMCPOAuthError) throws -> [String: Any] {
        do {
            try NativeMCPWireJSON.validate(data, maximumBytes: 32768)
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure }
            return value
        } catch { throw failure }
    }

    private static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.keys.sorted().map { key in key + "=" + fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
    }

    private static func safe(_ error: Error) -> NativeMCPOAuthError {
        if let error = error as? NativeMCPOAuthError { return error }
        if error is CancellationError { return .cancelled }
        return .network
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
