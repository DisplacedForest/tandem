import Foundation

private final class NativeMCPAuthFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    func count() -> Int { lock.withLock { value } }
}

private actor NativeMCPAuthConnection: NativeMCPConnection {
    private let page: NativeMCPPage
    private var calls = 0
    private var connecting = false
    private var waiting = false
    private var holdDiscovery = false
    private var holdCall = false
    private var ignoreCancellation = false
    init() {
        page = NativeMCPPage(tools: [NativeMCPDiscoveredTool(name: "read", description: "Read a synthetic value", inputSchema: .object(["type": .string("object"), "additionalProperties": .bool(false)]))], nextCursor: nil)
    }
    func connect() async throws {}
    func listTools(cursor: String?) async throws -> NativeMCPPage {
        connecting = true
        defer { connecting = false }
        if holdDiscovery { try await Task.sleep(for: .seconds(10)) }
        return page
    }
    func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue {
        calls += 1; waiting = true
        defer { waiting = false }
        if holdCall {
            do { try await Task.sleep(for: .seconds(10)) }
            catch { if !ignoreCancellation { throw error } }
        }
        return .object(["reading": .number(7)])
    }
    func disconnect() async {}
    func configure(discovery: Bool = false, call: Bool = false, ignoreCancellation: Bool = false) {
        holdDiscovery = discovery; holdCall = call; self.ignoreCancellation = ignoreCancellation
    }
    func isWaiting(discovery: Bool) -> Bool { discovery ? connecting : waiting }
    func count() -> Int { calls }
}

@MainActor
enum NativeMCPAuthorityAuthSelftest {
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NativeToolError.failed(message) }
    }
    private static func reject(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw NativeToolError.failed("An unauthorized MCP operation succeeded")
    }
    private static func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NativeToolError.failed("An MCP authorization fixture did not reach its expected state")
    }
    private static func lease(_ server: NativeMCPServerConfiguration, duration: TimeInterval = 30) throws -> NativeMCPAuthorization {
        try NativeMCPAuthorization(serverID: server.id, endpoint: server.endpoint, token: "temporary-fixture-value", expiresAt: Date().addingTimeInterval(duration), allowLoopbackFixture: server.allowsLoopbackFixture)
    }
    private static func scope(_ role: String = "foreground", mode: String = "assistant") throws -> PiModelScope {
        try PiModelScope(.object(["subject": .string(UUID().uuidString.lowercased()), "assistant": .string(UUID().uuidString.lowercased()), "conversation": .string(UUID().uuidString.lowercased()), "role": .string(role), "mode": .string(mode)]), profile: "fixture")
    }

    @MainActor static func run() async throws {
        let server = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Authorization fixture", endpoint: URL(string: "https://fixture.invalid/mcp")!, readTools: ["read"], scopes: ["focused", "assistant", "worker"], timeout: 2, authentication: .bearer)
        let row: [String: Any] = ["id": server.id, "name": server.name, "url": server.endpoint.absoluteString, "read_tools": ["read"]]
        let anonymous = NativeMCPServerConfiguration.load(["native_mcp_servers": [row]])
        try check(anonymous.1 == nil && anonymous.0.first?.authentication == NativeMCPServerConfiguration.Authentication.none, "Existing anonymous configuration changed")
        var configured = row; configured["authentication"] = "bearer"
        let parsed = NativeMCPServerConfiguration.load(["native_mcp_servers": [configured]])
        try check(parsed.1 == nil && parsed.0.first?.authentication == .bearer, "Bearer configuration could not be read")
        for invalid: Any in ["oauth", "", NSNull(), 1, true] {
            var invalidRow = row; invalidRow["authentication"] = invalid
            let result = NativeMCPServerConfiguration.load(["native_mcp_servers": [invalidRow]])
            try check(result.0.isEmpty && result.1 != nil, "Invalid authentication configuration was accepted")
        }
        for key in ["token", "api_key", "authorization", "allowLoopbackFixture"] {
            var invalidRow = configured; invalidRow[key] = "synthetic"
            let result = NativeMCPServerConfiguration.load(["native_mcp_servers": [invalidRow]])
            try check(result.0.isEmpty && result.1 != nil, "Persistent credential configuration was accepted")
        }
        var insecure = configured; insecure["url"] = "http://127.0.0.1:49152/mcp"
        try check(NativeMCPServerConfiguration.load(["native_mcp_servers": [insecure]]).1 != nil, "Production configuration enabled insecure bearer transport")
        let name = server.toolID("read")
        let counter = NativeMCPAuthFactoryCounter()
        let fixture = NativeMCPAuthConnection()
        let manager = NativeMCPManager(servers: [server], enabled: [name], authenticatedFactory: { config, authorization in
            counter.increment()
            guard authorization?.isValid(serverID: config.id, endpoint: config.endpoint) == true else { throw NativeMCPTransportError.authenticationRequired }
            return fixture
        })
        let authority = manager.authority
        await manager.connect(server.id)
        try check(counter.count() == 0 && !manager.servers[0].connected, "Missing token reached the connection factory")
        for token in ["", "bad token", "invalid\nheader"] {
            await manager.connect(server.id, token: token)
            try check(counter.count() == 0, "Invalid token reached the connection factory")
        }
        let otherServer = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Other", endpoint: server.endpoint, readTools: ["read"], authentication: .bearer)
        try await authority.connect(server.id, authorization: lease(otherServer))
        let otherEndpoint = try NativeMCPServerConfiguration(id: server.id, name: server.name, endpoint: URL(string: "https://other.invalid/mcp")!, readTools: ["read"], authentication: .bearer)
        try await authority.connect(server.id, authorization: lease(otherEndpoint))
        let revoked = try lease(server); revoked.revoke()
        await authority.connect(server.id, authorization: revoked)
        try check(counter.count() == 0, "Wrong or revoked authorization reached the connection factory")
        let first = try lease(server)
        await authority.connect(server.id, authorization: first)
        manager.refresh()
        await authority.connect(server.id, authorization: first)
        try check(first.isValid(serverID: server.id, endpoint: server.endpoint), "Repeated Connect revoked the active lease")
        try check(manager.servers[0].connected && counter.count() == 1, "Authorized connection failed")
        let definition = try requireDefinition(authority)
        let assistant = try scope(), worker = try scope("worker"), focused = try scope(mode: "focused")
        let originalRevision = try await authority.revision(scope: assistant)
        for scope in [assistant, worker, focused] {
            try check(try await authority.catalog(scope: scope) == [definition.schema], "Authorized scopes use different catalogs")
            _ = try await authority.call(scope: scope, id: UUID().uuidString, name: name, arguments: .object([:]))
        }
        manager.setEnabled([])
        try check(authority.definitions(scope: "focused").isEmpty, "A token bypassed disabled tool permission")
        manager.setEnabled([name])
        try check(!definition.isAvailable(), "Permission off and on restored a stale authorized definition")
        let beforeRevoke = await fixture.count()
        let current = try requireDefinition(authority)
        await fixture.configure(call: true, ignoreCancellation: true)
        let held = Task { try await authority.call(scope: worker, id: UUID().uuidString, name: name, arguments: .object([:])) }
        try await wait { await fixture.isWaiting(discovery: false) }
        first.revoke()
        try check(!current.isAvailable() && authority.definitions(scope: "focused").isEmpty, "Revocation left a catalog callable before actor cleanup")
        try check(authority.access.catalogRevision(scope: "assistant") != originalRevision, "Revocation preserved a runtime revision")
        try await reject { _ = try await current.execute([:]) }
        try await reject { _ = try await held.value }
        try check(await fixture.count() == beforeRevoke + 1, "Revocation replayed a dispatched operation")
        try await wait { !authority.access.snapshot()[0].connected }
        await fixture.configure()
        let replacement = try lease(server)
        await authority.connect(server.id, authorization: replacement)
        try check(replacement.isValid(serverID: server.id, endpoint: server.endpoint), "Replacement authorization was invalidated")
        first.revoke()
        try await Task.sleep(for: .milliseconds(20))
        try check(!current.isAvailable() && authority.definitions(scope: "focused").count == 1, "An old callback restored or revoked a replacement catalog")
        let callsBeforeStale = await fixture.count()
        try await reject { _ = try await authority.call(scope: assistant, id: UUID().uuidString, name: name, arguments: .object([:]), expectedRevision: originalRevision) }
        try check(await fixture.count() == callsBeforeStale, "A stale runtime catalog reached a replacement connection")
        await manager.disconnect(server.id)
        try check(!replacement.isValid(serverID: server.id, endpoint: server.endpoint), "Disconnect retained bearer authorization")
        let expiryStart = ContinuousClock.now
        let shortLease = try lease(server, duration: 0.15)
        await authority.connect(server.id, authorization: shortLease)
        let expiring = try requireDefinition(authority)
        await fixture.configure(call: true)
        let expiringCall = Task { try await authority.call(scope: assistant, id: UUID().uuidString, name: name, arguments: .object([:])) }
        try await wait { await fixture.isWaiting(discovery: false) }
        try await reject { _ = try await expiringCall.value }
        try check(expiryStart.duration(to: .now) < .seconds(1), "Expiry waited for the tool deadline")
        try check(!expiring.isAvailable() && authority.definitions(scope: "focused").isEmpty, "Expired authorization remained available")
        try await wait { !authority.access.snapshot()[0].connected }
        await fixture.configure(discovery: true)
        let discoveringLease = try lease(server)
        let connecting = Task { await authority.connect(server.id, authorization: discoveringLease) }
        try await wait { await fixture.isWaiting(discovery: true) }
        discoveringLease.revoke()
        await connecting.value
        try check(authority.definitions(scope: "focused").isEmpty && !authority.access.snapshot()[0].connected, "Revoked discovery published tools")
        await fixture.configure()
        await manager.connect(server.id, token: "temporary-ui-fixture-value")
        try check(manager.servers[0].connected, "The temporary token entry path failed")
        await manager.disconnect(server.id)
        let restarted = NativeMCPManager(servers: [server], enabled: [name], authenticatedFactory: { _, _ in counter.increment(); return fixture })
        let beforeRestart = counter.count()
        await restarted.connect(server.id)
        try check(counter.count() == beforeRestart && restarted.authority.definitions(scope: "focused").isEmpty, "Restart retained or refreshed bearer authorization")
        let focusedOnly = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Focused only", endpoint: server.endpoint, readTools: ["read"], scopes: ["focused"], authentication: .bearer)
        let focusedManager = NativeMCPManager(servers: [focusedOnly], enabled: [focusedOnly.toolID("read")], authenticatedFactory: { _, _ in fixture })
        await focusedManager.connect(focusedOnly.id, token: "temporary-fixture-value")
        try check(focusedManager.authority.definitions(scope: "focused").count == 1 && focusedManager.authority.definitions(scope: "assistant").isEmpty && focusedManager.authority.definitions(scope: "worker").isEmpty, "Authorization expanded server scope")
        await focusedManager.disconnect(focusedOnly.id)
        let unapproved = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Restricted", endpoint: server.endpoint, readTools: ["other_read"], scopes: ["focused"], authentication: .bearer)
        let restricted = NativeMCPManager(servers: [unapproved], enabled: [unapproved.toolID("read")], authenticatedFactory: { _, _ in fixture })
        await restricted.connect(unapproved.id, token: "temporary-fixture-value")
        try check(restricted.authority.definitions(scope: "focused").isEmpty && restricted.authority.definitions(scope: "worker").isEmpty, "Authentication expanded approved tools or scopes")
        await restricted.disconnect(unapproved.id)
        let loopback = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Explicit loopback fixture", endpoint: URL(string: "http://127.0.0.1:49152/mcp")!, readTools: ["read"], authentication: .bearer, allowLoopbackFixture: true)
        let loopbackManager = NativeMCPManager(servers: [loopback], authenticatedFactory: { config, authorization in
            guard authorization?.isValid(serverID: config.id, endpoint: config.endpoint) == true else { throw NativeMCPTransportError.authenticationRequired }
            return fixture
        })
        await loopbackManager.connect(loopback.id, token: "temporary-fixture-value")
        try check(loopbackManager.servers[0].connected, "Explicit loopback fixture token path failed")
        await loopbackManager.disconnect(loopback.id)
        print("NATIVE MCP AUTHORIZATION AUTHORITY SELFTEST OK")
    }

    private static func requireDefinition(_ authority: NativeMCPAuthority) throws -> NativeToolDefinition {
        guard let value = authority.definitions(scope: "focused").first else { throw NativeToolError.failed("The authorized fixture did not advertise its approved read") }
        return value
    }
}
