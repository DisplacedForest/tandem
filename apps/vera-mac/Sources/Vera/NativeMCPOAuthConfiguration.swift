import Foundation
import Synchronization

struct NativeMCPOAuthConfiguration: Equatable, Sendable {
    let resource: URL
    let issuer: URL
    let protectedResourceMetadataURL: URL
    let authorizationServerMetadataURL: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let clientID: String
    let redirectURI: URL
    let scopes: Set<String>
    private let allowLoopbackFixture: Bool

    init(resource: URL, issuer: URL, protectedResourceMetadataURL: URL, authorizationServerMetadataURL: URL, authorizationEndpoint: URL, tokenEndpoint: URL, clientID: String, redirectURI: URL, scopes: Set<String>, allowLoopbackFixture: Bool = false) throws {
        guard redirectURI.scheme == "vera-oauth" else { throw NativeMCPOAuthError.invalidConsent }
        _ = try NativeMCPOAuthConsent(serverID: "validation", resource: resource, issuer: issuer, protectedResourceMetadataURL: protectedResourceMetadataURL, authorizationServerMetadataURL: authorizationServerMetadataURL, authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint, clientID: clientID, redirectURI: redirectURI, scopes: scopes, generation: UUID(), expiresAt: Date().addingTimeInterval(60), allowLoopbackFixture: allowLoopbackFixture)
        self.resource = resource
        self.issuer = issuer
        self.protectedResourceMetadataURL = protectedResourceMetadataURL
        self.authorizationServerMetadataURL = authorizationServerMetadataURL
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.allowLoopbackFixture = allowLoopbackFixture
    }

    static func load(_ value: Any?) throws -> Self {
        guard let object = value as? [String: Any], Set(object.keys) == ["resource", "issuer", "protected_resource_metadata_url", "authorization_server_metadata_url", "authorization_endpoint", "token_endpoint", "client_id", "redirect_uri", "scopes"],
              let clientID = object["client_id"] as? String, let scopes = object["scopes"] as? [String], scopes.count == Set(scopes).count else { throw NativeMCPOAuthError.invalidConsent }
        func url(_ key: String) throws -> URL {
            guard let text = object[key] as? String, let result = URL(string: text), result.absoluteString == text else { throw NativeMCPOAuthError.invalidConsent }
            return result
        }
        return try Self(resource: url("resource"), issuer: url("issuer"), protectedResourceMetadataURL: url("protected_resource_metadata_url"), authorizationServerMetadataURL: url("authorization_server_metadata_url"), authorizationEndpoint: url("authorization_endpoint"), tokenEndpoint: url("token_endpoint"), clientID: clientID, redirectURI: url("redirect_uri"), scopes: Set(scopes))
    }

    func consent(serverID: String, generation: UUID = UUID(), expiresAt: Date = Date().addingTimeInterval(3600)) throws -> NativeMCPOAuthConsent {
        try NativeMCPOAuthConsent(serverID: serverID, resource: resource, issuer: issuer, protectedResourceMetadataURL: protectedResourceMetadataURL, authorizationServerMetadataURL: authorizationServerMetadataURL, authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint, clientID: clientID, redirectURI: redirectURI, scopes: scopes, generation: generation, expiresAt: expiresAt, allowLoopbackFixture: allowLoopbackFixture)
    }
}

final class NativeMCPOAuthConnectionLifetime: Sendable {
    let configuration: NativeMCPServerConfiguration
    let consent: NativeMCPOAuthConsent
    private let deadline: ContinuousClock.Instant
    private struct State {
        var active = true
        var session: NativeMCPOAuthSession?
        var expiry: Task<Void, Never>?
        var onCancel: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())

    init(configuration: NativeMCPServerConfiguration, consent: NativeMCPOAuthConsent) throws {
        guard configuration.authentication == .oauth, let oauth = configuration.oauth,
              consent.serverID == configuration.id, consent.resource == configuration.endpoint,
              consent.issuer == oauth.issuer, consent.protectedResourceMetadataURL == oauth.protectedResourceMetadataURL,
              consent.authorizationServerMetadataURL == oauth.authorizationServerMetadataURL,
              consent.authorizationEndpoint == oauth.authorizationEndpoint, consent.tokenEndpoint == oauth.tokenEndpoint,
              consent.clientID == oauth.clientID, consent.redirectURI == oauth.redirectURI, consent.scopes == oauth.scopes else { throw NativeMCPOAuthError.invalidConsent }
        self.configuration = configuration
        self.consent = consent
        deadline = ContinuousClock.now.advanced(by: .seconds(max(0, consent.expiresAt.timeIntervalSinceNow)))
        let deadline = deadline
        let expiry = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            self?.cancel()
        }
        state.withLock { $0.expiry = expiry }
    }

    deinit { cancel() }
    var isActive: Bool { state.withLock { $0.active && Date() < consent.expiresAt && ContinuousClock.now < deadline } }
    var session: NativeMCPOAuthSession? { state.withLock { $0.session } }

    func install(_ session: NativeMCPOAuthSession) throws {
        let installed = state.withLock { value in
            guard value.active, Date() < consent.expiresAt, ContinuousClock.now < deadline, value.session == nil,
                  session.consent.generation == consent.generation, session.consent.serverID == configuration.id,
                  session.consent.resource == configuration.endpoint,
                  session.consent.issuer == consent.issuer, session.consent.protectedResourceMetadataURL == consent.protectedResourceMetadataURL,
                  session.consent.authorizationServerMetadataURL == consent.authorizationServerMetadataURL,
                  session.consent.authorizationEndpoint == consent.authorizationEndpoint, session.consent.tokenEndpoint == consent.tokenEndpoint,
                  session.consent.clientID == consent.clientID, session.consent.redirectURI == consent.redirectURI,
                  session.consent.scopes == consent.scopes, session.consent.expiresAt == consent.expiresAt else { return false }
            value.session = session
            return true
        }
        guard installed else { session.cancel(); throw NativeMCPOAuthError.cancelled }
    }

    func onCancel(_ callback: @escaping @Sendable () -> Void) {
        let call = state.withLock { value in
            guard value.active else { return true }
            value.onCancel = callback
            return false
        }
        if call { callback() }
    }

    func cancel() {
        let captured = state.withLock { value in
            let captured = (value.session, value.expiry, value.onCancel)
            value.active = false
            value.session = nil
            value.expiry = nil
            value.onCancel = nil
            return captured
        }
        captured.0?.cancel()
        captured.1?.cancel()
        captured.2?()
    }
}
