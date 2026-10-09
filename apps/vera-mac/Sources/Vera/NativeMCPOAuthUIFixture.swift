import Foundation
import Combine

@MainActor
final class NativeMCPOAuthFixtureBrowser: NativeMCPOAuthBrowser, ObservableObject {
    @Published private(set) var waiting = false
    private var continuation: CheckedContinuation<URL, any Error>?
    private var callback: URL?
    private(set) var starts = 0
    private(set) var cancels = 0
    var ignoreCancellation = false
    var automatic = false

    func authenticate(url: URL, callback: URL) async throws -> URL {
        guard continuation == nil,
              let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value else { throw NativeMCPOAuthError.invalidState }
        starts += 1
        var result = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        result.queryItems = [URLQueryItem(name: "code", value: "synthetic-code"), URLQueryItem(name: "state", value: state), URLQueryItem(name: "iss", value: NativeMCPOAuthUIFixtureTransport.issuer.absoluteString)]
        self.callback = result.url
        if automatic { return result.url! }
        waiting = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete() {
        guard let callback else { return }
        let continuation = continuation
        self.continuation = nil
        self.callback = nil
        waiting = false
        continuation?.resume(returning: callback)
    }

    func cancel() {
        cancels += 1
        if ignoreCancellation { return }
        let continuation = continuation
        self.continuation = nil
        callback = nil
        waiting = false
        continuation?.resume(throwing: NativeMCPOAuthError.cancelled)
    }
}

actor NativeMCPOAuthUIFixtureTransport: NativeMCPOAuthTransport {
    static let issuer = URL(string: "https://oauth-fixture.invalid")!
    static let authorizationEndpoint = URL(string: "https://oauth-fixture.invalid/authorize")!
    static let tokenEndpoint = URL(string: "https://oauth-fixture.invalid/token")!
    static let resourceMetadata = URL(string: "https://oauth-fixture.invalid/resource-metadata")!
    static let issuerMetadata = URL(string: "https://oauth-fixture.invalid/issuer-metadata")!
    let resource: URL
    private(set) var requests = 0
    private(set) var exchanges = 0
    private(set) var refreshes = 0
    var held: String?
    var reject = false
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var waiting = false

    init(resource: URL) { self.resource = resource }

    static func configuration(resource: URL, allowLoopbackFixture: Bool = false) throws -> NativeMCPOAuthConfiguration {
        try NativeMCPOAuthConfiguration(resource: resource, issuer: issuer, protectedResourceMetadataURL: resourceMetadata, authorizationServerMetadataURL: issuerMetadata, authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint, clientID: "synthetic-public-client", redirectURI: URL(string: "vera-oauth://fixture/callback")!, scopes: ["docs.read"], allowLoopbackFixture: allowLoopbackFixture)
    }

    func send(_ request: NativeMCPOAuthRequest, gate: NativeMCPOAuthGate) async throws -> NativeMCPOAuthResponse {
        try gate.check()
        requests += 1
        let object: [String: Any]
        let step: String
        if request.url == Self.resourceMetadata {
            step = "metadata"
            object = ["resource": resource.absoluteString, "authorization_servers": [Self.issuer.absoluteString], "scopes_supported": ["docs.read"]]
        } else if request.url == Self.issuerMetadata {
            step = "issuer"
            object = ["issuer": Self.issuer.absoluteString, "authorization_endpoint": Self.authorizationEndpoint.absoluteString, "token_endpoint": Self.tokenEndpoint.absoluteString, "scopes_supported": ["docs.read"], "code_challenge_methods_supported": ["S256"], "response_types_supported": ["code"], "token_endpoint_auth_methods_supported": ["none"], "authorization_response_iss_parameter_supported": true, "grant_types_supported": ["authorization_code", "refresh_token"]]
        } else if request.url == Self.tokenEndpoint {
            let text = String(decoding: request.body ?? Data(), as: UTF8.self)
            if text.contains("grant_type=refresh_token") { refreshes += 1; step = "refresh" }
            else { exchanges += 1; step = "exchange" }
            object = ["access_token": "vera-synthetic-bearer-proof-7GkN4", "token_type": "Bearer", "expires_in": 3600, "scope": "docs.read", "refresh_token": "synthetic-refresh-\(refreshes)"]
        } else { throw NativeMCPOAuthError.invalidConsent }
        if held == step {
            waiting = true
            await withCheckedContinuation { pending = $0 }
            waiting = false
        }
        if reject { throw NativeMCPOAuthError.network }
        return NativeMCPOAuthResponse(url: request.url, status: 200, contentType: "application/json", body: try JSONSerialization.data(withJSONObject: object))
    }

    func configure(hold: String? = nil, reject: Bool = false) { held = hold; self.reject = reject }
    func release() { pending?.resume(); pending = nil }
}
