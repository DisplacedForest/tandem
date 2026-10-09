import Foundation

@MainActor
enum NativeMCPOAuthUISelftest {
    private static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw NativeToolError.failed(message) }
    }
    private static func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NativeToolError.failed("The OAuth UI fixture did not reach the expected state.")
    }
    private static func rejected(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw NativeToolError.failed("A stale OAuth operation succeeded.")
    }
    private static func server() throws -> NativeMCPServerConfiguration {
        let resource = URL(string: "https://resource-fixture.invalid/mcp")!
        return try NativeMCPServerConfiguration(id: UUID().uuidString, name: "OAuth UI fixture", endpoint: resource, readTools: ["fixture_read"], scopes: ["focused", "assistant", "worker"], authentication: .oauth, oauth: NativeMCPOAuthUIFixtureTransport.configuration(resource: resource))
    }
    private static func connection() -> NativeMCPFixtureConnection {
        NativeMCPFixtureConnection(pages: [NativeMCPPage(tools: [NativeMCPDiscoveredTool(name: "fixture_read", description: "Synthetic read", inputSchema: .object(["type": .string("object"), "additionalProperties": .bool(false)]))], nextCursor: nil)])
    }
    private static func manager(_ server: NativeMCPServerConfiguration, browser: NativeMCPOAuthFixtureBrowser, transport: NativeMCPOAuthUIFixtureTransport, connection: NativeMCPFixtureConnection, lifetime: TimeInterval? = nil) -> NativeMCPManager {
        NativeMCPManager(servers: [server], authenticatedFactory: { config, lease in
            guard lease?.isValid(serverID: config.id, endpoint: config.endpoint) == true else { throw NativeMCPTransportError.authenticationRequired }
            return connection
        }, oauthTransport: transport, oauthBrowserFactory: { browser }, oauthLifetimeForFixture: lifetime)
    }
    private static func signIn(_ manager: NativeMCPManager, _ server: NativeMCPServerConfiguration, browser: NativeMCPOAuthFixtureBrowser) async throws {
        guard let review = manager.beginOAuthReview(server.id) else { throw NativeToolError.failed("The fixture review was unavailable.") }
        let task = Task { await manager.signIn(server.id, reviewID: review.id) }
        try await wait { browser.waiting }
        browser.complete()
        await task.value
        try check(manager.servers[0].connected, "OAuth sign-in did not discover tools.")
    }

    static func run() async throws {
        try configuration()
        try await connectedFlow()
        try await cancellation()
        try await staleCleanup()
        try await lateNetworkResults()
        try await configAndExpiry()
        try await discoveryAndAuthFailure()
        print("NATIVE MCP OAUTH UI SELFTEST OK")
    }

    private static func configuration() throws {
        let server = try server(), oauth = server.oauth!
        let object: [String: Any] = ["resource": oauth.resource.absoluteString, "issuer": oauth.issuer.absoluteString, "protected_resource_metadata_url": oauth.protectedResourceMetadataURL.absoluteString, "authorization_server_metadata_url": oauth.authorizationServerMetadataURL.absoluteString, "authorization_endpoint": oauth.authorizationEndpoint.absoluteString, "token_endpoint": oauth.tokenEndpoint.absoluteString, "client_id": oauth.clientID, "redirect_uri": oauth.redirectURI.absoluteString, "scopes": oauth.scopes.sorted()]
        var row: [String: Any] = ["id": server.id, "name": server.name, "url": server.endpoint.absoluteString, "read_tools": ["fixture_read"], "authentication": "oauth", "oauth": object]
        try check(NativeMCPServerConfiguration.load(["native_mcp_servers": [row]]).0.first?.oauth == oauth, "OAuth configuration did not preserve its approved binding.")
        let wrongConsent = try oauth.consent(serverID: UUID().uuidString.lowercased())
        do {
            _ = try NativeMCPOAuthConnectionLifetime(configuration: server, consent: wrongConsent)
            throw NativeToolError.failed("A mismatched consent created OAuth ownership.")
        } catch NativeMCPOAuthError.invalidConsent {}

        for key in ["token", "access_token", "refresh_token", "client_secret", "allowLoopbackFixture"] {
            var changed = object; changed[key] = "synthetic-secret"
            row["oauth"] = changed
            try check(NativeMCPServerConfiguration.load(["native_mcp_servers": [row]]).1 != nil, "OAuth configuration accepted persistent credential data.")
        }
        row["oauth"] = object
        row["url"] = "https://different-fixture.invalid/mcp"
        try check(NativeMCPServerConfiguration.load(["native_mcp_servers": [row]]).1 != nil, "OAuth configuration changed its resource.")
        row["url"] = server.endpoint.absoluteString
        row["authentication"] = "none"
        try check(NativeMCPServerConfiguration.load(["native_mcp_servers": [row]]).1 != nil, "Anonymous configuration accepted OAuth authority.")
        row["authentication"] = "oauth"
        row.removeValue(forKey: "oauth")
        try check(NativeMCPServerConfiguration.load(["native_mcp_servers": [row]]).1 != nil, "OAuth configuration did not require a reviewed registration.")
    }

    private static func connectedFlow() async throws {
        let server = try server(), browser = NativeMCPOAuthFixtureBrowser(), transport = NativeMCPOAuthUIFixtureTransport(resource: server.endpoint), connection = connection()
        let manager = manager(server, browser: browser, transport: transport, connection: connection)
        try check(await transport.requests == 0 && browser.starts == 0, "OAuth ran without an explicit sign-in action.")
        guard let review = manager.beginOAuthReview(server.id) else { throw NativeToolError.unavailable }
        try check(review.consent.resource == server.endpoint && review.consent.scopes == ["docs.read"], "The review did not expose the approved access.")
        try check(await transport.requests == 0 && browser.starts == 0, "Opening review started OAuth.")
        await manager.signIn(server.id, reviewID: UUID())
        try check(await transport.requests == 0, "An unreviewed sign-in was accepted.")
        manager.cancelOAuthReview(server.id, reviewID: review.id)
        try await signIn(manager, server, browser: browser)
        try check(manager.authority.definitions(scope: "focused").isEmpty, "Sign-in granted tool permission.")
        manager.setEnabled([server.toolID("fixture_read")])
        manager.refresh()
        try check(manager.servers[0].connected && browser.starts == 1, "Enabling a discovered tool forced another sign-in.")
        manager.cancelPendingOAuth()
        guard let old = manager.authority.definitions(scope: "focused").first else { throw NativeToolError.unavailable }
        _ = try await old.execute([:])
        try check(manager.servers[0].connected, "Closing Settings ended an established connection.")
        let scope = try NativeMCPAuthoritySelftest.scope()
        let revision = try await manager.authority.revision(scope: scope)
        await manager.refreshOAuth(server.id)
        try check(manager.servers[0].connected && browser.starts == 1, "Refresh opened a new browser grant.")
        try check(await transport.refreshes == 1 && !old.isAvailable(), "Refresh revived a stale tool definition.")
        try await rejected { _ = try await manager.authority.call(scope: scope, id: UUID().uuidString, name: server.toolID("fixture_read"), arguments: .object([:]), expectedRevision: revision) }
        try check(manager.authority.definitions(scope: "focused").count == 1, "Rejecting a stale catalog disconnected the current one.")
        manager.cancelOAuthLocally(server.id)
        try check(manager.authority.definitions(scope: "focused").isEmpty, "Disconnect left OAuth tools callable before cleanup.")
        await manager.disconnect(server.id)
        try check(manager.oauthFlows.isEmpty && !manager.servers[0].connected, "Disconnect kept refresh authority.")
        let restarted = self.manager(server, browser: NativeMCPOAuthFixtureBrowser(), transport: transport, connection: connection)
        await restarted.connect(server.id)
        try check(restarted.authority.definitions(scope: "focused").isEmpty && !restarted.servers[0].connected, "Restart retained an OAuth grant.")
    }

    private static func cancellation() async throws {
        let server = try server(), browser = NativeMCPOAuthFixtureBrowser(), transport = NativeMCPOAuthUIFixtureTransport(resource: server.endpoint)
        browser.ignoreCancellation = true
        let manager = manager(server, browser: browser, transport: transport, connection: connection())
        guard let review = manager.beginOAuthReview(server.id) else { throw NativeToolError.unavailable }
        let task = Task { await manager.signIn(server.id, reviewID: review.id) }
        try await wait { browser.waiting }
        manager.cancelPendingOAuth()
        try check(manager.authority.definitions(scope: "focused").isEmpty, "Closing an unfinished flow left authority.")
        browser.complete()
        await task.value
        try check(await transport.exchanges == 0 && !manager.servers[0].connected, "A late callback exchanged a canceled code.")
        try check(manager.oauthFlows.isEmpty, "Canceled sign-in kept its owning session.")
    }

    private static func staleCleanup() async throws {
        let server = try server(), browser = NativeMCPOAuthFixtureBrowser(), transport = NativeMCPOAuthUIFixtureTransport(resource: server.endpoint)
        let manager = manager(server, browser: browser, transport: transport, connection: connection())
        let originalGeneration = manager.authority.access.snapshot()[0].generation
        guard let abandoned = manager.beginOAuthReview(server.id) else { throw NativeToolError.unavailable }
        manager.cancelOAuthReview(server.id, reviewID: abandoned.id)
        guard let fresh = manager.beginOAuthReview(server.id) else { throw NativeToolError.unavailable }
        let first = Task { await manager.signIn(server.id, reviewID: fresh.id) }
        try await wait { browser.waiting }
        guard let firstOwner = manager.authority.access.oauthOwner(server.id) else { throw NativeToolError.unavailable }
        await manager.authority.disconnect(server.id, expectedGeneration: originalGeneration)
        manager.cancelOAuthReview(server.id, reviewID: abandoned.id)
        try check(firstOwner.isActive && browser.waiting, "Stale review cleanup canceled a replacement sign-in.")
        browser.complete()
        await first.value
        try check(manager.servers[0].connected, "Stale cleanup blocked the new catalog.")
        await manager.disconnect(server.id)
        guard let next = manager.beginOAuthReview(server.id) else { throw NativeToolError.unavailable }
        let second = Task { await manager.signIn(server.id, reviewID: next.id) }
        try await wait { browser.waiting }
        await manager.authority.disconnect(server.id, oauth: firstOwner)
        try check(manager.authority.access.oauthOwner(server.id)?.isActive == true && browser.waiting, "An old owner canceled a newer connection.")
        browser.complete()
        await second.value
        try check(manager.servers[0].connected, "A stale owner restored old connection state.")
        await manager.disconnect(server.id)
    }

    private static func lateNetworkResults() async throws {
        for step in ["metadata", "exchange", "refresh"] {
            let server = try server(), browser = NativeMCPOAuthFixtureBrowser(), transport = NativeMCPOAuthUIFixtureTransport(resource: server.endpoint)
            let manager = manager(server, browser: browser, transport: transport, connection: connection())
            if step == "refresh" { try await signIn(manager, server, browser: browser) }
            await transport.configure(hold: step)
            let task: Task<Void, Never>
            if step == "refresh" { task = Task { await manager.refreshOAuth(server.id) } }
            else {
                browser.automatic = true
                guard let review = manager.beginOAuthReview(server.id) else { throw NativeToolError.unavailable }
                task = Task { await manager.signIn(server.id, reviewID: review.id) }
            }
            try await wait { await transport.waiting }
            manager.cancelOAuth(server.id)
            await transport.release()
            await task.value
            try check(manager.authority.definitions(scope: "focused").isEmpty && !manager.servers[0].connected && manager.oauthFlows.isEmpty, "A late OAuth response restored a canceled catalog.")
        }
    }

    private static func discoveryAndAuthFailure() async throws {
        let server = try server(), browser = NativeMCPOAuthFixtureBrowser(), transport = NativeMCPOAuthUIFixtureTransport(resource: server.endpoint)
        browser.automatic = true
        let connection = HeldConnection()
        let manager = NativeMCPManager(servers: [server], authenticatedFactory: { config, lease in
            guard lease?.isValid(serverID: config.id, endpoint: config.endpoint) == true else { throw NativeMCPTransportError.authenticationRequired }
            return connection
        }, oauthTransport: transport, oauthBrowserFactory: { browser })
        guard let review = manager.beginOAuthReview(server.id) else { throw NativeToolError.unavailable }
        let task = Task { await manager.signIn(server.id, reviewID: review.id) }
        try await wait { await connection.waiting }
        manager.cancelOAuth(server.id)
        await connection.release()
        await task.value
        try await wait { !manager.authority.access.snapshot()[0].connecting }
        manager.refresh()
        try check(!manager.servers[0].connected && manager.servers[0].tools.isEmpty, "Late MCP discovery restored canceled OAuth tools.")
        guard let second = manager.beginOAuthReview(server.id) else { throw NativeToolError.unavailable }
        await manager.signIn(server.id, reviewID: second.id)
        manager.setEnabled([server.toolID("fixture_read")])
        guard let owner = manager.authority.access.oauthOwner(server.id), let session = owner.session,
              let definition = manager.authority.definitions(scope: "focused").first else { throw NativeToolError.unavailable }
        await connection.fail()
        try await rejected { _ = try await definition.execute([:]) }
        try check(!owner.isActive && !definition.isAvailable(), "A service authentication failure retained OAuth authority.")
        try await rejected { _ = try await session.refresh(generation: owner.consent.generation) }
        try check(await transport.refreshes == 0, "Authentication failure automatically refreshed or retained a grant.")
        await manager.disconnect(server.id)
    }

    private actor HeldConnection: NativeMCPConnection {
        private(set) var waiting = false
        private var held = true
        private var fails = false
        private var pending: CheckedContinuation<Void, Never>?
        func connect() async throws {}
        func listTools(cursor: String?) async throws -> NativeMCPPage {
            if held {
                waiting = true
                await withCheckedContinuation { pending = $0 }
                waiting = false
            }
            return NativeMCPPage(tools: [NativeMCPDiscoveredTool(name: "fixture_read", description: "Synthetic read", inputSchema: .object(["type": .string("object")]))], nextCursor: nil)
        }
        func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue {
            if fails { throw NativeMCPTransportError.authenticationRequired }
            return .object(["reading": .number(7)])
        }
        func disconnect() async {}
        func release() { held = false; pending?.resume(); pending = nil }
        func fail() { fails = true }
    }

    private static func configAndExpiry() async throws {
        let server = try server(), browser = NativeMCPOAuthFixtureBrowser(), transport = NativeMCPOAuthUIFixtureTransport(resource: server.endpoint)
        browser.ignoreCancellation = true
        let manager = manager(server, browser: browser, transport: transport, connection: connection())
        guard let review = manager.beginOAuthReview(server.id) else { throw NativeToolError.unavailable }
        let task = Task { await manager.signIn(server.id, reviewID: review.id) }
        try await wait { browser.waiting }
        await manager.replaceConfiguration([server])
        browser.complete()
        await task.value
        try check(await transport.exchanges == 0 && !manager.servers[0].connected, "Replacing configuration reused an old consent generation.")
        await manager.signIn(server.id, reviewID: review.id)
        try check(await transport.exchanges == 0, "A prior review authorized the replacement configuration.")
        let expiringBrowser = NativeMCPOAuthFixtureBrowser()
        let expiring = self.manager(server, browser: expiringBrowser, transport: transport, connection: connection(), lifetime: 2.5)
        guard let shortReview = expiring.beginOAuthReview(server.id) else { throw NativeToolError.unavailable }
        let pending = Task { await expiring.signIn(server.id, reviewID: shortReview.id) }
        try await wait { expiringBrowser.waiting }
        await pending.value
        try check(!expiringBrowser.waiting && expiring.oauthFlows.isEmpty, "Expiry did not cancel the pending browser.")
    }
}
