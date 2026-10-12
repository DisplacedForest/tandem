import Foundation
import Security

actor RejectingCredentialHTTP: HTTPTransport {
    private var calls = 0
    func send(path: String, body: Data?, credential: String, limit: Int) async throws -> Data {
        calls += 1
        throw Failure.invalidRequest
    }
    var count: Int { calls }
}

enum CredentialDiagnosticSelftest {
    static func run() async throws {
        let mappings: [(OSStatus, String)] = [
            (errSecSuccess, "invalid_data"), (errSecItemNotFound, "item_missing"),
            (errSecInteractionNotAllowed, "interaction_disallowed"), (errSecInteractionRequired, "interaction_required"),
            (errSecMissingEntitlement, "missing_entitlement"), (errSecAuthFailed, "auth_failed"),
            (OSStatus(CSSMERR_CSP_OPERATION_AUTH_DENIED), "authorization_denied"), (OSStatus(CSSMERR_DL_OPERATION_AUTH_DENIED), "authorization_denied"),
            (errSecUserCanceled, "canceled"), (errSecNotAvailable, "unavailable"), (errSecDecode, "decode_failed"),
            (Int32.min, "os_error"), (Int32.max, "os_error")
        ]
        for (status, category) in mappings {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let access = FixtureKeychainAccess(.accepted, status: status, data: nil)
            let credentials = NativeCredential(access: access, context: { FixtureAuthenticationContext() })
            let http = RejectingCredentialHTTP()
            let broker = try Broker(permit: fixture.permit, ledger: fixture.ledger, credentials: credentials, http: http)
            let request = fixture.request(), authorization = try fixture.authorization(request)
            try await Selftest.expectAsync(.credentialUnavailable) { _ = try await broker.complete(request, requestPermit: authorization) }
            let expected = [["os_status": String(status), "category": category]]
            try ensure(try fixture.ledger.credentialFailure(request["request_id"].string!) == expected)
            try ensure(try fixture.ledger.credentialFailure(UUID().uuidString.lowercased()).isEmpty)
            try ensure(try fixture.ledger.snapshot().isEmpty)
            try ensure(await http.count == 0)
            let stages = try fixture.ledger.phaseSnapshot().compactMap { $0["stage"] }
            try ensure(stages == ["accepted", "keychainBegin", "keychainReturned"])
            try await Selftest.expectAsync(.credentialUnavailable) { _ = try await broker.complete(request, requestPermit: authorization) }
            try ensure(access.recorded == ["disable", "verify", "read"])
            try ensure(try fixture.ledger.credentialFailure(request["request_id"].string!) == expected)
        }
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("credential-diagnostic-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString.lowercased()
        do {
            let ledger = try Ledger(root: directory)
            try ledger.traceCredentialFailure(id, CredentialReadFailure(status: errSecItemNotFound))
            try Selftest.expect(.storage) { try ledger.traceCredentialFailure(id, CredentialReadFailure(status: errSecAuthFailed)) }
        }
        do {
            let reopened = try Ledger(root: directory)
            try ensure(try reopened.credentialFailure(id) == [["os_status": String(errSecItemNotFound), "category": "item_missing"]])
            try Selftest.corrupt(directory, "UPDATE credential_failures SET category='synthetic-untrusted-value'")
            try Selftest.expect(.storage) { _ = try reopened.credentialFailure(id) }
        }
        for data in [Data(), Data([255]), Data("synthetic-private-line\n".utf8), Data(repeating: 65, count: 4097)] {
            let access = FixtureKeychainAccess(.accepted, data: data)
            let credentials = NativeCredential(access: access, context: { FixtureAuthenticationContext() })
            do {
                _ = try credentials.read(profile: UUID().uuidString, progress: { _ in })
                throw Failure.invalidRequest
            } catch let failure as CredentialReadFailure {
                try ensure(failure.status == errSecSuccess && failure.category == "invalid_data")
            }
        }
    }
}
