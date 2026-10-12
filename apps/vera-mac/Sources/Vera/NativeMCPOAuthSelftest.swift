import Foundation
import MCP
import Synchronization

nonisolated enum NativeMCPOAuthSelftest {
    private struct Failure: Error {}
    static let resource = URL(string: "https://resource.example.test/mcp")!
    static let issuer = URL(string: "https://issuer.example.test")!
    static let authorizationEndpoint = URL(string: "https://issuer.example.test/authorize")!
    static let tokenEndpoint = URL(string: "https://issuer.example.test/token")!
    static let resourceMetadata = URL(string: "https://resource.example.test/.well-known/oauth-protected-resource/mcp")!
    static let issuerMetadata = URL(string: "https://issuer.example.test/.well-known/oauth-authorization-server")!
    static let callback = URL(string: "vera-oauth://oauth/callback")!

    static func require(_ value: Bool) throws { if !value { throw Failure() } }

    static func rejected(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch is Failure { throw Failure() } catch { return }
        throw Failure()
    }

    static func consent(lifetime: TimeInterval = 120, generation: UUID = UUID(), redirect: URL = callback, target: URL = resource) throws -> NativeMCPOAuthConsent {
        try NativeMCPOAuthConsent(serverID: "fixture", resource: target, issuer: issuer, protectedResourceMetadataURL: resourceMetadata, authorizationServerMetadataURL: issuerMetadata, authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint, clientID: "fixture-public-client", redirectURI: redirect, scopes: ["docs.read", "profile.read"], generation: generation, expiresAt: Date().addingTimeInterval(lifetime))
    }

    static func resourceObject() -> [String: Any] {
        ["resource": resource.absoluteString, "authorization_servers": [issuer.absoluteString], "scopes_supported": ["docs.read", "profile.read"]]
    }

    static func issuerObject() -> [String: Any] {
        ["issuer": issuer.absoluteString, "authorization_endpoint": authorizationEndpoint.absoluteString, "token_endpoint": tokenEndpoint.absoluteString, "code_challenge_methods_supported": ["S256"], "response_types_supported": ["code"], "token_endpoint_auth_methods_supported": ["none"], "authorization_response_iss_parameter_supported": true, "grant_types_supported": ["authorization_code", "refresh_token"], "scopes_supported": ["docs.read", "profile.read"], "registration_endpoint": "https://never-request.example.test/register"]
    }

    static func tokenObject(_ index: Int = 1) -> [String: Any] {
        ["access_token": "synthetic-access-\(index)", "token_type": "Bearer", "expires_in": 3600, "refresh_token": "synthetic-refresh-\(index)", "scope": "docs.read"]
    }

    static func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    static func reply(_ url: URL) throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let state = items.first { $0.name == "state" }!.value!
        var callback = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        callback.queryItems = [URLQueryItem(name: "code", value: "synthetic-code"), URLQueryItem(name: "state", value: state), URLQueryItem(name: "iss", value: issuer.absoluteString)]
        return callback.url!
    }

    static func run() async throws {
        try await consentRejections()
        try await success()
        try await metadataRejections()
        try await callbackRejections()
        try await tokenRejections()
        try await refreshRejections()
        try await cancellation()
        try await networkBoundary()
        print("Native OAuth lifecycle selftest PASS")
    }

    private static func consentRejections() async throws {
        let redirects = ["HTTP://callback.example.test/path", "FILE://callback.example.test/path", "DATA://callback.example.test/path", "ftp://callback.example.test/path", "ws://callback.example.test/path", "vera-oauth:///path", "vera-oauth://callback.example.test/path?unexpected=1", "vera-oauth://callback.example.test/path#fragment", "vera-oauth://user@callback.example.test/path"]
        for address in redirects {
            try await rejected { _ = try consent(redirect: URL(string: address)!) }
        }
        let relative = URL(string: "path", relativeTo: URL(string: "https://callback.example.test/")!)!
        try await rejected { _ = try consent(redirect: relative) }
        for address in ["http://resource.example.test/mcp", "HTTPS://resource.example.test/mcp", "https://user@resource.example.test/mcp", "https://resource.example.test/mcp?unexpected=1", "https://resource.example.test/mcp#fragment"] {
            try await rejected { _ = try consent(target: URL(string: address)!) }
        }
        _ = try consent(redirect: URL(string: "https://callback.example.test/path")!)
    }

    private static func success() async throws {
        let consent = try consent()
        let fixture = try Fixture()
        let session = try await NativeMCPOAuthSession.discover(consent: consent, transport: fixture)
        try require(session.metadataDigest.count == 64)
        let authorization = try await session.authorizationURL(generation: consent.generation)
        let items = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!
        try require(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        try require(items.first { $0.name == "resource" }?.value == resource.absoluteString)
        let lease = try await session.complete(callback: reply(authorization), generation: consent.generation)
        try require(lease.isValid(serverID: "fixture", endpoint: resource))
        let exchange = await fixture.lastForm
        try require(exchange["grant_type"] == "authorization_code" && exchange["code"] == "synthetic-code" && exchange["resource"] == resource.absoluteString)
        try require(try PKCE.makeChallenge(from: exchange["code_verifier"]!) == items.first { $0.name == "code_challenge" }?.value)
        try await rejected { _ = try await session.complete(callback: reply(authorization), generation: consent.generation) }
        let next = try await session.refresh(generation: consent.generation)
        try require(!lease.isValid(serverID: "fixture", endpoint: resource) && next.isValid(serverID: "fixture", endpoint: resource))
        let firstRefresh = await fixture.lastForm
        try require(firstRefresh["refresh_token"] == "synthetic-refresh-1" && firstRefresh["scope"] == "docs.read")
        let third = try await session.refresh(generation: consent.generation)
        let secondRefresh = await fixture.lastForm
        try require(secondRefresh["refresh_token"] == "synthetic-refresh-2")
        try require(!next.isValid(serverID: "fixture", endpoint: resource) && third.isValid(serverID: "fixture", endpoint: resource))
        try require(!String(reflecting: session).contains("synthetic"))
        session.revoke()
        try require(!third.isValid(serverID: "fixture", endpoint: resource))
        try await rejected { _ = try await session.refresh(generation: consent.generation) }
        let counts = await fixture.counts
        try require(counts == [resourceMetadata.absoluteString: 1, issuerMetadata.absoluteString: 1, tokenEndpoint.absoluteString: 3])
        try await rejected { _ = try self.consent(lifetime: 3601) }
        try await rejected { _ = try self.consent(lifetime: -1) }
    }

    private static func metadataRejections() async throws {
        for key in ["resource", "authorization_servers", "scopes_supported"] {
            var object = resourceObject()
            object[key] = key == "resource" ? "https://wrong.example.test/mcp" : ["wrong"]
            let fixture = try Fixture(resource: data(object))
            try await rejected { _ = try await NativeMCPOAuthSession.discover(consent: consent(), transport: fixture) }
            let count = await fixture.counts.values.reduce(0, +)
            try require(count == 1)
        }
        for key in ["issuer", "authorization_endpoint", "token_endpoint", "code_challenge_methods_supported", "response_types_supported", "token_endpoint_auth_methods_supported", "authorization_response_iss_parameter_supported", "grant_types_supported", "scopes_supported"] {
            var object = issuerObject()
            object.removeValue(forKey: key)
            let fixture = try Fixture(issuer: data(object))
            try await rejected { _ = try await NativeMCPOAuthSession.discover(consent: consent(), transport: fixture) }
            let count = await fixture.counts.values.reduce(0, +)
            try require(count == 2)
        }
        let duplicate = Data("{\"resource\":\"a\",\"resource\":\"b\"}".utf8)
        for malformed in [duplicate, Data(repeating: 32, count: 32769), Data((String(repeating: "[", count: 25) + String(repeating: "]", count: 25)).utf8)] {
            let fixture = try Fixture(resource: malformed)
            try await rejected { _ = try await NativeMCPOAuthSession.discover(consent: consent(), transport: fixture) }
        }
    }

    private static func callbackRejections() async throws {
        for mutation in 0..<10 {
            let consent = try consent()
            let fixture = try Fixture()
            let session = try await NativeMCPOAuthSession.discover(consent: consent, transport: fixture)
            let url = try await session.authorizationURL(generation: consent.generation)
            var callback = URLComponents(url: try reply(url), resolvingAgainstBaseURL: false)!
            switch mutation {
            case 0: callback.queryItems!.append(URLQueryItem(name: "state", value: "duplicate"))
            case 1: callback.queryItems!.append(URLQueryItem(name: "code", value: "duplicate"))
            case 2: callback.fragment = "hidden"
            case 3: callback.user = "injected"
            case 4: callback.queryItems!.append(URLQueryItem(name: "error", value: "access_denied"))
            case 5: callback.queryItems!.removeAll { $0.name == "iss" }
            case 6: callback.queryItems = callback.queryItems!.map { $0.name == "iss" ? URLQueryItem(name: "iss", value: "https://other.example.test") : $0 }
            case 7: callback.queryItems = callback.queryItems!.map { $0.name == "state" ? URLQueryItem(name: "state", value: "wrong") : $0 }
            case 8: callback.path = "/wrong"
            default: callback.queryItems!.removeAll { $0.name == "code" }
            }
            let badURL = callback.url!
            try await rejected { _ = try await session.complete(callback: badURL, generation: consent.generation) }
            try await rejected { _ = try await session.complete(callback: reply(url), generation: consent.generation) }
            let count = await fixture.counts[tokenEndpoint.absoluteString, default: 0]
            try require(count == 0)
        }
    }

    private static func tokenRejections() async throws {
        var mutations: [Data] = []
        for key in ["access_token", "token_type", "expires_in"] {
            var object = tokenObject()
            object.removeValue(forKey: key)
            mutations.append(try data(object))
        }
        let values: [(String, Any)] = [("token_type", "MAC"), ("access_token", "bad token"), ("expires_in", true), ("expires_in", 0), ("expires_in", 1.5), ("scope", "admin"), ("scope", "docs.read docs.read"), ("resource", "https://wrong.example.test"), ("refresh_token", "bad token"), ("id_token", "synthetic-secret")]
        for (key, value) in values {
            var object = tokenObject()
            object[key] = value
            mutations.append(try data(object))
        }
        mutations.append(Data("{\"access_token\":\"a\",\"access_token\":\"b\"}".utf8))
        for token in mutations {
            let consent = try consent()
            let fixture = try Fixture(token: token)
            let session = try await NativeMCPOAuthSession.discover(consent: consent, transport: fixture)
            let url = try await session.authorizationURL(generation: consent.generation)
            try await rejected { _ = try await session.complete(callback: reply(url), generation: consent.generation) }
            try await rejected { _ = try await session.complete(callback: reply(url), generation: consent.generation) }
            let count = await fixture.counts[tokenEndpoint.absoluteString, default: 0]
            try require(count == 1)
        }
    }

    private static func refreshRejections() async throws {
        let consent = try consent()
        let fixture = try Fixture()
        let session = try await NativeMCPOAuthSession.discover(consent: consent, transport: fixture)
        let url = try await session.authorizationURL(generation: consent.generation)
        let lease = try await session.complete(callback: reply(url), generation: consent.generation)
        var expanded = tokenObject(2)
        expanded["scope"] = "docs.read profile.read"
        await fixture.replaceToken(try data(expanded))
        try await rejected { _ = try await session.refresh(generation: consent.generation) }
        try require(!lease.isValid(serverID: "fixture", endpoint: resource))
        try await rejected { _ = try await session.refresh(generation: consent.generation) }
        let form = await fixture.lastForm
        try require(form["scope"] == "docs.read")
        let counts = await fixture.counts
        try require(counts[tokenEndpoint.absoluteString] == 2 && counts[authorizationEndpoint.absoluteString] == nil)
        let nextFixture = try Fixture()
        let next = try await NativeMCPOAuthSession.discover(consent: self.consent(), transport: nextFixture)
        try await rejected { _ = try await next.authorizationURL(generation: consent.generation) }
        next.cancel()
    }

    private static func cancellation() async throws {
        let consent = try consent()
        let fixture = try Fixture(holdToken: true)
        let session = try await NativeMCPOAuthSession.discover(consent: consent, transport: fixture)
        try await rejected { _ = try await session.authorizationURL(generation: UUID()) }
        let url = try await session.authorizationURL(generation: consent.generation)
        let operation = Task { try await session.complete(callback: reply(url), generation: consent.generation) }
        await fixture.waitForToken()
        try await rejected { _ = try await session.complete(callback: reply(url), generation: consent.generation) }
        session.cancel()
        await fixture.release()
        try await rejected { _ = try await operation.value }
        try await rejected { _ = try await session.complete(callback: reply(url), generation: consent.generation) }
        let short = try self.consent(lifetime: 1.5)
        let shortFixture = try Fixture()
        let expiring = try await NativeMCPOAuthSession.discover(consent: short, transport: shortFixture)
        let authorization = try await expiring.authorizationURL(generation: short.generation)
        let lease = try await expiring.complete(callback: reply(authorization), generation: short.generation)
        let rotated = try await expiring.refresh(generation: short.generation)
        try require(!lease.isValid(serverID: "fixture", endpoint: resource) && rotated.isValid(serverID: "fixture", endpoint: resource))
        try await Task.sleep(for: .milliseconds(1600))
        try require(!lease.isValid(serverID: "fixture", endpoint: resource) && !rotated.isValid(serverID: "fixture", endpoint: resource))
        try await rejected { _ = try await expiring.refresh(generation: short.generation) }
    }

    private static func networkBoundary() async throws {
        let transport = NativeMCPOAuthHTTPTransport(fixtureProtocol: Wire.self)
        for mode in [Wire.Mode.success, .length, .chunks, .redirect, .wrongURL, .unauthorized, .cookie] {
            Wire.fixture.withLock { $0 = Wire.State(mode: mode) }
            let gate = NativeMCPOAuthGate(consent: try consent())
            let request = NativeMCPOAuthRequest(url: tokenEndpoint, body: Data("grant_type=fixture&synthetic=secret".utf8))
            if mode == .success || mode == .cookie {
                let result = try await transport.send(request, gate: gate)
                try require(result.body == Data("{}".utf8))
                if mode == .cookie { _ = try await transport.send(request, gate: gate) }
            } else {
                try await rejected { _ = try await transport.send(request, gate: gate) }
            }
            let state = Wire.fixture.withLock { $0 }
            try require(!state.unsafeHeader && state.requests <= 2)
            if mode == .redirect { try require(state.requests == 1) }
            gate.cancel()
        }
        Wire.fixture.withLock { $0 = Wire.State(mode: .held) }
        let gate = NativeMCPOAuthGate(consent: try consent())
        let operation = Task { try await transport.send(NativeMCPOAuthRequest(url: tokenEndpoint, body: nil), gate: gate) }
        for _ in 0..<100 {
            if Wire.fixture.withLock({ $0.requests > 0 }) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        gate.cancel()
        try await rejected { _ = try await operation.value }
        try require(Wire.fixture.withLock { $0.requests } == 1)
        Wire.fixture.withLock { $0 = Wire.State(mode: .held) }
        let expires = try consent(lifetime: 1.0)
        let started = ContinuousClock.now
        try await rejected { _ = try await NativeMCPOAuthSession.discover(consent: expires, transport: transport) }
        try require(started.duration(to: .now) < .seconds(5))
        for _ in 0..<100 {
            if Wire.fixture.withLock({ $0.stops > 0 }) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try require(Wire.fixture.withLock { $0.requests == 1 && $0.stops > 0 })
        Wire.fixture.withLock { $0 = Wire.State(mode: .held) }
        let discovering = Task { try await NativeMCPOAuthSession.discover(consent: consent(), transport: transport) }
        for _ in 0..<100 {
            if Wire.fixture.withLock({ $0.requests > 0 }) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        discovering.cancel()
        try await rejected { _ = try await discovering.value }
    }

    private actor Fixture: NativeMCPOAuthTransport {
        let resourceBody: Data
        let issuerBody: Data
        var tokenBody: Data?
        let holdToken: Bool
        var counts: [String: Int] = [:]
        var lastForm: [String: String] = [:]
        var pending: CheckedContinuation<Void, Never>?
        var observers: [CheckedContinuation<Void, Never>] = []

        init(resource: Data? = nil, issuer: Data? = nil, token: Data? = nil, holdToken: Bool = false) throws {
            resourceBody = try resource ?? data(resourceObject())
            issuerBody = try issuer ?? data(issuerObject())
            tokenBody = token
            self.holdToken = holdToken
        }

        func send(_ request: NativeMCPOAuthRequest, gate: NativeMCPOAuthGate) async throws -> NativeMCPOAuthResponse {
            try gate.check()
            counts[request.url.absoluteString, default: 0] += 1
            let body: Data
            if request.url == resourceMetadata { body = resourceBody }
            else if request.url == issuerMetadata { body = issuerBody }
            else if request.url == tokenEndpoint {
                lastForm = Dictionary(uniqueKeysWithValues: String(decoding: request.body!, as: UTF8.self).split(separator: "&").map { part in
                    let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    return (String(pair[0]), String(pair[1]).removingPercentEncoding!)
                })
                if holdToken {
                    await withCheckedContinuation { continuation in
                        pending = continuation
                        observers.forEach { $0.resume() }
                        observers.removeAll()
                    }
                }
                body = try tokenBody ?? data(tokenObject(counts[request.url.absoluteString]!))
            } else { throw Failure() }
            return NativeMCPOAuthResponse(url: request.url, status: 200, contentType: "application/json", body: body)
        }

        func replaceToken(_ data: Data) { tokenBody = data }

        func waitForToken() async {
            if pending != nil { return }
            await withCheckedContinuation { observers.append($0) }
        }
        func release() { pending?.resume(); pending = nil }
    }

    private final class Wire: URLProtocol, @unchecked Sendable {
        enum Mode: Sendable { case success, length, chunks, redirect, wrongURL, unauthorized, cookie, held }
        struct State: Sendable {
            let mode: Mode
            var requests = 0
            var unsafeHeader = false
            var stops = 0
        }
        static let fixture = Mutex(State(mode: .success))
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let mode = Self.fixture.withLock { value in
                value.requests += 1
                value.unsafeHeader = value.unsafeHeader || request.value(forHTTPHeaderField: "Authorization") != nil || request.value(forHTTPHeaderField: "Cookie") != nil
                return value.mode
            }
            if mode == .held { return }
            var headers = ["Content-Type": "application/json"]
            if mode == .length { headers["Content-Length"] = "32769" }
            if mode == .cookie { headers["Set-Cookie"] = "fixture=synthetic; Secure; Path=/" }
            let url = mode == .wrongURL ? URL(string: "https://unapproved.example.test")! : request.url!
            if mode == .redirect {
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://unapproved.example.test"])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://unapproved.example.test")!), redirectResponse: response)
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: mode == .unauthorized ? 401 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if mode == .chunks {
                client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 20000))
                client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 20000))
            } else { client?.urlProtocol(self, didLoad: Data("{}".utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { Self.fixture.withLock { $0.stops += 1 } }
    }
}
