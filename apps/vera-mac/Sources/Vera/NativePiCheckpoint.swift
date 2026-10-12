import Foundation
import Security
import LocalAuthentication
import Darwin

final class PiCheckpointDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    init(seconds: Double, code: Int32) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { [self] in
            lock.lock(); defer { lock.unlock() }
            if !finished { _exit(code) }
        }
    }
    func finish() { lock.lock(); defer { lock.unlock() }; finished = true }
}

final class PiCheckpointCredentials: NativeCredentialStore {
    let selected: String
    let readSelected: (String) throws -> String?
    private var readOnce = false
    init(selected: String, readSelected: @escaping (String) throws -> String?) { self.selected = selected; self.readSelected = readSelected }
    func read(for profileID: String) throws -> String? {
        guard profileID == selected else { return nil }
        try piCheck(!readOnce, .unauthorized); readOnce = true
        return try readSelected(profileID)
    }
    func set(_ value: String?, for profileID: String) throws { throw PiBrokerError.unauthorized }
    func addIfAbsent(_ value: String, for profileID: String) throws { throw PiBrokerError.unauthorized }
    static func existing(_ profile: String, recordStatus: (Int32) throws -> Void) throws -> String? {
        let deadline = PiCheckpointDeadline(seconds: 5, code: 126)
        defer { deadline.finish() }
        try piCheck(SecKeychainSetUserInteractionAllowed(false) == errSecSuccess, .unauthorized)
        var allowed = DarwinBoolean(true)
        try piCheck(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess && !allowed.boolValue, .unauthorized)
        var operations = NativeKeychainOperations()
        var readStatus: OSStatus?
        operations.read = { dictionary, result in
            var query = dictionary as! [String: Any]
            guard let context = query[kSecUseAuthenticationContext as String] as? LAContext, context.interactionNotAllowed else { readStatus = errSecInteractionNotAllowed; return errSecInteractionNotAllowed }
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            let status = SecItemCopyMatching(query as CFDictionary, result)
            readStatus = status
            return status
        }
        do {
            let result = try KeychainNativeCredentialStore(allowsInteraction: false, operations: operations).read(for: profile)
            if let readStatus { try recordStatus(readStatus) }
            return result
        } catch {
            if let readStatus { try recordStatus(readStatus) }
            throw error
        }
    }
}

@MainActor
enum NativePiCheckpoint {
    static func identity(_ certificate: String) throws {
        try piCheck(certificate.count == 40 && certificate.allSatisfy { "0123456789abcdefABCDEF".contains($0) }, .unauthorized)
        try piCheck(Bundle.main.bundleIdentifier == "app.vera.mac" && Bundle.main.bundleURL.path == "/Applications/Vera.app", .unauthorized)
        var own: SecCode?, requirement: SecRequirement?
        let text = "identifier \"app.vera.mac\" and certificate leaf = H\"\(certificate)\""
        try piCheck(SecCodeCopySelf([], &own) == errSecSuccess && SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, .unauthorized)
        guard let own, let requirement else { throw PiBrokerError.unauthorized }
        try piCheck(SecCodeCheckValidity(own, [], requirement) == errSecSuccess, .unauthorized)
    }
    static func main(_ arguments: [String]) async {
        var journal: PiCheckpointLedger?
        do {
            let arguments = try NativePiRuntimePaths.expanded(arguments)
            try piCheck(arguments.count == 16)
            var options: [String: String] = [:]
            for index in stride(from: 0, to: arguments.count, by: 2) { try piCheck(options[arguments[index]] == nil); options[arguments[index]] = arguments[index + 1] }
            try piCheck(Set(options.keys) == ["--root", "--repo", "--python", "--node", "--port", "--ledger", "--authorization", "--certificate"] && options["--port"] == "0")
            try identity(options["--certificate"]!)
            let root = URL(fileURLWithPath: options["--root"]!)
            try piCheck(!FileManager.default.fileExists(atPath: root.path), .storage)
            let ledger = try PiCheckpointLedger(path: URL(fileURLWithPath: options["--ledger"]!), id: options["--authorization"]!)
            journal = ledger
            try ledger.consume()
            let deadline = PiCheckpointDeadline(seconds: 110, code: 124)
            defer { deadline.finish() }
            let raw = ConfigFile.read()
            let profile = try NativeProviderSmoke.savedProfile(from: raw)
            try piCheck(profile.selectedModel == PiCheckpointPricing.model && (raw["model_api_key"] as? String ?? "").isEmpty, .unauthorized)
            let credentials = PiCheckpointCredentials(selected: profile.id) { profile in
                try PiCheckpointCredentials.existing(profile) { status in try ledger.stage("credential_returned", additions: ["credential_os_status": .number(Double(status))]) }
            }
            let config = ConfigStore(credentialStore: credentials, readConfiguration: { raw }, writeConfiguration: { _ in throw PiBrokerError.unauthorized })
            _ = try config.piSelectedProfileBinding()
            try ledger.stage("credential_returned")
            guard let admission = NativeInferenceAdmission.configured() else { throw PiBrokerError.unavailable }
            var runtime: [String] = []
            for key in ["--root", "--repo", "--python", "--node", "--port"] { runtime += [key, options[key]!] }
            let result = try await run(arguments: runtime, root: root, config: config, ledger: ledger, admission: admission, http: PiProviderHTTP(), transport: .openRouter)
            FileHandle.standardOutput.write(try result.piData() + Data([10]))
        } catch {
            let report: PiValue = .object(["outcome": .string("stopped"), "error": .string((error as? PiBrokerError)?.rawValue ?? "operation_failed"), "checkpoint": journal?.report() ?? .null])
            if let data = try? report.piData() { FileHandle.standardOutput.write(data + Data([10])) }
            exit(1)
        }
    }
    static func run(arguments: [String], root: URL, config: ConfigStore, ledger: PiCheckpointLedger, admission: NativeInferenceAdmission, http: PiProviderHTTP, transport: PiTransportKind) async throws -> PiValue {
        umask(0o077)
        let experiment = try PiExperimentRoot(root)
        let provider = try await PiPreparedProvider.checkpoint(owner: config, admission: admission, journal: ledger, accountingRoot: experiment.url.appendingPathComponent("accounting"), http: http, transport: transport)
        var runtime = arguments
        guard let index = runtime.firstIndex(of: "--root") else { throw PiBrokerError.invalid }
        runtime[index + 1] = experiment.url.appendingPathComponent("model").path
        let session = try await NativePiPreparedSession.create(arguments: runtime, uiRoot: experiment.url.appendingPathComponent("ui"), provider: provider)
        do {
            let endpoint = try await session.owner.endpoint()
            let conversation = UUID().uuidString.lowercased(), message = UUID().uuidString.lowercased()
            var request = URLRequest(url: endpoint.appendingPathComponent("assistant/messages"))
            request.httpMethod = "POST"
            request.httpBody = try PiValue.object(["assistant_id": .string(session.workspace.assistantID.uuidString.lowercased()), "conversation_id": .string(conversation), "message_id": .string(message), "mode": .string("focused"), "text": .string(PiCheckpointPricing.user)]).piData()
            let (data, status) = try await session.owner.http(request)
            try piCheck(status == 200, .unavailable)
            let answer = try PiValue.piRead(data)
            try piCheck(answer.pi("task_ids") == .array([]) && answer.pi("text").piString?.trimmingCharacters(in: .whitespacesAndNewlines) == "OK", .invalid)
            await session.owner.stop()
            return .object(["outcome": .string("completed"), "transport": .string(transport.rawValue), "reply": answer.pi("text"), "checkpoint": ledger.report(), "accounting": try await provider.accounting.snapshot()])
        } catch { await session.owner.stop(); throw error }
    }
}
