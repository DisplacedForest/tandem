import Foundation
import Darwin
import Security
import LocalAuthentication
import CSQLite

struct StalledCredential: CredentialSource {
    let stage: Stage
    func read(profile: String, progress: @Sendable (Stage) throws -> Void) throws -> String {
        try progress(stage)
        usleep(60_000_000)
        return "synthetic-stalled-key"
    }
}

struct StalledHTTP: HTTPTransport {
    let pathToBlock: String
    func stall() { usleep(60_000_000) }
    func send(path: String, body: Data?, credential: String, limit: Int) async throws -> Data {
        if path == pathToBlock { stall() }
        if path == "models" { return try FixtureHTTP.catalog.data() }
        if path == "key" { return try J.object(["data": .object(["usage": .number(0)])]).data() }
        return try FixtureHTTP.answer.data()
    }
}

final class RefusingAuthenticationContext: LAContext {
    override var interactionNotAllowed: Bool {
        get { false }
        set {}
    }
}

enum WatchdogSelftest {
    static func policyAndDisarm() async throws {
        let profile = UUID().uuidString
        try Selftest.expect(.credentialUnavailable) { _ = try NativeCredential.query(profile: profile, context: RefusingAuthenticationContext()) }
        do {
            let query = try NativeCredential.query(profile: profile)
            try ensure(query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
            try ensure((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
            try ensure(query[kSecAttrAccount as String] as? String == profile)
        } catch Failure.credentialUnavailable {}
        for _ in 0..<25 {
            let timer = HardDeadline(after: .milliseconds(20))
            timer.finish()
            timer.arm(after: .milliseconds(1), code: 125)
        }
        try await Task.sleep(for: .milliseconds(50))
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let broker = try Broker(permit: fixture.permit, ledger: fixture.ledger, credentials: FixtureCredential(), http: FixtureHTTP(), hardTimeout: .milliseconds(100), credentialTimeout: .milliseconds(50))
        let request = fixture.request()
        _ = try await broker.complete(request, requestPermit: fixture.authorization(request))
        try await Task.sleep(for: .milliseconds(150))
        let phases = try fixture.ledger.phaseSnapshot().compactMap { $0["stage"] }
        try ensure(phases == ["accepted", "keychainBegin", "keychainReturned", "credentialReturned", "modelsBegin", "modelsReturned", "usageBegin", "usageReturned", "inferenceReserved", "inferenceBegin", "inferenceReturned", "settled"])
    }
    static func run(_ mode: String, root: URL) async throws {
        try require(["metadata", "credential", "models", "usage", "inference", "cancel", "concurrent", "sqlite"].contains(mode))
        let fixture = try Fixture(directory: root)
        let credentials: any CredentialSource = ["metadata", "credential", "cancel"].contains(mode) ? StalledCredential(stage: mode == "metadata" ? .metadataBegin : .keychainBegin) : FixtureCredential()
        let path = mode == "models" ? "models" : (mode == "usage" ? "key" : "chat/completions")
        let http: any HTTPTransport = StalledHTTP(pathToBlock: path)
        let slowCancel = ["cancel", "concurrent"].contains(mode)
        let broker = try Broker(permit: fixture.permit, ledger: fixture.ledger, credentials: credentials, http: http, hardTimeout: (slowCancel || ["metadata", "credential"].contains(mode)) ? .seconds(4) : .milliseconds(300), credentialTimeout: slowCancel ? .seconds(4) : .milliseconds(150))
        var locked: OpaquePointer?
        if mode == "sqlite" {
            try ensure(sqlite3_open(root.appendingPathComponent("spend.sqlite").path, &locked) == SQLITE_OK)
            try ensure(sqlite3_exec(locked, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        }
        defer { if let locked { sqlite3_close(locked) } }
        let request = fixture.request()
        let first = Task { try await broker.complete(request, requestPermit: fixture.authorization(request)) }
        if mode == "concurrent" {
            for _ in 0..<200 {
                if try fixture.ledger.snapshot().count == 1 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let worker = fixture.request(role: "worker")
            let second = Task { try await broker.complete(worker, requestPermit: fixture.authorization(worker)) }
            for _ in 0..<200 {
                if try fixture.ledger.snapshot().count == 2 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try ensure(try fixture.ledger.snapshot().count == 2)
            second.cancel()
        } else if mode == "cancel" {
            try await Task.sleep(for: .milliseconds(50))
            first.cancel()
        }
        _ = try await first.value
        throw Failure.invalidRequest
    }
}
