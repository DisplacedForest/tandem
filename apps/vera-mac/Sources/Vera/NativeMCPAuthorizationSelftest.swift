import Foundation
import Synchronization

enum NativeMCPAuthorizationSelftest {
    enum Failure: Error { case assertion(String) }
    private static let token = "vera-synthetic-bearer-proof-7GkN4"
    private static let replacement = "vera-synthetic-bearer-replacement-3FhP8"

    static func run(port: String, counterFile: URL) async throws {
        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }
        func lease(_ path: String = "bearer", seconds: TimeInterval = 60, value: String = token) throws -> NativeMCPAuthorization {
            try NativeMCPAuthorization(serverID: "fixture", endpoint: url(path), token: value, expiresAt: Date().addingTimeInterval(seconds), allowLoopbackFixture: true)
        }
        func connection(_ path: String, _ authorization: NativeMCPAuthorization) throws -> NativeMCPSDKConnection {
            try NativeMCPSDKConnection(endpoint: url(path), timeout: 2, maximumResponseBytes: 8192, authorization: authorization, serverID: "fixture")
        }
        func count(_ path: String, _ method: String) throws -> Int {
            let values = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: counterFile))
            return values["/\(path)|\(method)", default: 0]
        }
        let authorization = try lease()
        try require(!String(describing: authorization).contains(token) && !String(reflecting: authorization).contains(token), "Credential description leaked")
        try require(!authorization.isValid(serverID: "other", endpoint: url("bearer")), "Cross-server lease accepted")
        try require(!authorization.isValid(serverID: "fixture", endpoint: url("ok")), "Cross-endpoint lease accepted")
        for (endpoint, serverID) in [(url("ok"), "fixture"), (url("bearer"), "other")] {
            do {
                _ = try NativeMCPSDKConnection(endpoint: endpoint, authorization: authorization, serverID: serverID)
                throw Failure.assertion("Invalid lease binding accepted")
            } catch NativeMCPTransportError.authenticationRequired {}
        }
        for value in ["", "bad token", "bad\nvalue", "token\r\nInjected:value"] {
            do { _ = try lease(value: value); throw Failure.assertion("Invalid Bearer value accepted") }
            catch NativeMCPAuthorizationError.invalidCredential {}
        }
        do {
            _ = try NativeMCPAuthorization(serverID: "fixture", endpoint: url("bearer"), token: token, expiresAt: Date().addingTimeInterval(60))
            throw Failure.assertion("Production HTTP credential accepted")
        } catch NativeMCPAuthorizationError.invalidBinding {}
        do { _ = try lease(seconds: 3601); throw Failure.assertion("Long lease accepted") }
        catch NativeMCPAuthorizationError.expired {}
        let held = try lease()
        let prepared = held.makeAuthorizer().authorizationHeader(for: url("bearer")) != nil
        try require(prepared, "SDK authorizer did not prepare fixture header")
        held.revoke()
        let sends = Mutex(0)
        do {
            try held.performAuthorizedRequest(URLRequest(url: url("bearer"))) { _ in sends.withLock { $0 += 1 } }
            throw Failure.assertion("Revocation between SDK authorization and send accepted")
        } catch NativeMCPTransportError.authenticationRequired {}
        try require(sends.withLock { $0 } == 0, "Revoked send callback executed")
        let client = try connection("bearer", authorization)
        try await client.connect()
        _ = try await client.listTools(cursor: nil)
        _ = try await client.call(name: "fixture_read", arguments: ["rows": .array([])])
        await client.disconnect()
        try require(authorization.isValid(serverID: "fixture", endpoint: url("bearer")), "Disconnect extended or revoked lease")
        try await client.connect()
        await client.disconnect()
        for path in ["bearer-denied", "bearer-scope"] {
            let denied = try lease(path)
            let client = try connection(path, denied)
            do { try await client.connect(); throw Failure.assertion("Challenge accepted") }
            catch NativeMCPTransportError.authenticationRequired {}
            try require(!denied.isValid(serverID: "fixture", endpoint: url(path)), "Challenge did not revoke lease")
            try require(try count(path, "initialize") == 1, "Authentication replayed request")
            await client.disconnect()
        }
        let anonymous = try NativeMCPSDKConnection(endpoint: url("bearer"), timeout: 2)
        do { try await anonymous.connect(); throw Failure.assertion("Anonymous protected connect accepted") }
        catch NativeMCPTransportError.authenticationRequired {}
        await anonymous.disconnect()
        let redirected = try lease("bearer-redirect")
        let redirectClient = try connection("bearer-redirect", redirected)
        do { try await redirectClient.connect(); throw Failure.assertion("Bearer redirect followed") }
        catch NativeMCPTransportError.redirectDenied {}
        await redirectClient.disconnect()
        for path in ["bearer-echo", "bearer-echo-escaped", "bearer-echo-sse", "bearer-echo-schema", "bearer-echo-header"] {
            let protected = try lease(path)
            let client = try connection(path, protected)
            do {
                try await client.connect()
                if path == "bearer-echo-schema" { _ = try await client.listTools(cursor: nil) }
                else { _ = try await client.call(name: "fixture_read", arguments: [:]) }
                throw Failure.assertion("Credential echo reached client")
            } catch NativeMCPTransportError.malformedResponse {}
            await client.disconnect()
        }
        let revoked = try lease()
        let listenerCalls = Mutex(0)
        let removed = revoked.onInvalidation { listenerCalls.withLock { $0 += 100 } }
        revoked.removeInvalidationObserver(removed)
        revoked.onInvalidation { listenerCalls.withLock { $0 += 1 } }
        let revocable = try connection("bearer", revoked)
        try await revocable.connect()
        let started = ContinuousClock.now
        let pending = Task { try await revocable.call(name: "slow", arguments: [:]) }
        try await Task.sleep(for: .milliseconds(50))
        revoked.revoke()
        do { _ = try await pending.value; throw Failure.assertion("Revoked operation returned") }
        catch NativeMCPTransportError.authenticationRequired {}
        try require(started.duration(to: .now) < .seconds(1), "Revocation did not cancel promptly")
        revoked.revoke()
        try require(listenerCalls.withLock { $0 } == 1, "Observer did not fire exactly once")
        revoked.onInvalidation { listenerCalls.withLock { $0 += 1 } }
        try require(listenerCalls.withLock { $0 } == 2, "Late observer not notified")
        let before = try count("bearer", "initialize")
        do { try await revocable.connect(); throw Failure.assertion("Revoked reconnect accepted") }
        catch NativeMCPTransportError.authenticationRequired {}
        try require(try count("bearer", "initialize") == before, "Revoked reconnect sent traffic")
        await revocable.disconnect()
        let fresh = try lease(value: replacement)
        let replacementClient = try connection("bearer", fresh)
        try await replacementClient.connect()
        _ = try await replacementClient.call(name: "fixture_read", arguments: [:])
        await replacementClient.disconnect()
        let expiring = try lease(seconds: 0.25)
        let expiredCalls = Mutex(0)
        expiring.onInvalidation { expiredCalls.withLock { $0 += 1 } }
        let expirable = try connection("bearer", expiring)
        try await expirable.connect()
        let expiringCall = Task { try await expirable.call(name: "slow", arguments: [:]) }
        do { _ = try await expiringCall.value; throw Failure.assertion("Expired result accepted") }
        catch NativeMCPTransportError.authenticationRequired {}
        try require(expiredCalls.withLock { $0 } == 1, "Expiry did not notify")
        await expirable.disconnect()
        authorization.revoke()
        fresh.revoke()
        print("MCP AUTHORIZATION SELFTEST OK")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }
}
