import Foundation
import VeraAssistantUI

@MainActor
final class NativePiCandidate {
    let root: PiExperimentRoot
    let config: ConfigStore
    let credentials: PiCandidateCredentials
    let provider: PiCandidateProviderFixture
    let accounting: PiSharedAccounting
    let owner: NativePiAppOwner
    let workspace: AssistantWorkspace
    let admission: NativeInferenceAdmission
    private init(root: PiExperimentRoot, config: ConfigStore, credentials: PiCandidateCredentials,
                 provider: PiCandidateProviderFixture, accounting: PiSharedAccounting,
                 owner: NativePiAppOwner, workspace: AssistantWorkspace, admission: NativeInferenceAdmission) {
        self.root = root; self.config = config; self.credentials = credentials; self.provider = provider
        self.accounting = accounting; self.owner = owner; self.workspace = workspace; self.admission = admission
    }
    static func create(_ arguments: [String], onOwner: @MainActor (NativePiAppOwner) -> Void = { _ in }, httpTransport: @escaping @Sendable (URLRequest) async throws -> (Data, Int) = PiOwnedHTTP.send) async throws -> NativePiCandidate {
        let arguments = try NativePiRuntimePaths.expanded(arguments)
        try piCheck(arguments.count == 10)
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            try piCheck(options[arguments[index]] == nil)
            options[arguments[index]] = arguments[index + 1]
        }
        try piCheck(Set(options.keys) == ["--root", "--repo", "--python", "--node", "--port"])
        umask(0o077)
        let root = try PiExperimentRoot(URL(fileURLWithPath: options["--root"]!))
        let profileFile = root.url.appendingPathComponent("profile.json")
        let raw: [String: Any]
        if FileManager.default.fileExists(atPath: profileFile.path) {
            let fd = open(profileFile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            try piCheck(fd >= 0, .storage)
            var info = stat()
            let valid = fstat(fd, &info) == 0 && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o077 == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_size <= 65536
            defer { close(fd) }
            try piCheck(valid, .storage)
            var bytes = [UInt8](repeating: 0, count: 65537)
            let count = read(fd, &bytes, bytes.count)
            try piCheck(count >= 0 && count <= 65536, .storage)
            guard let decoded = try JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any] else { throw PiBrokerError.storage }
            raw = decoded
        } else {
            var settings = NativeChatSettings.fresh
            let id = UUID().uuidString.lowercased()
            settings.profiles = [NativeEndpointProfile(id: id, name: "Test profile", baseURL: "https://openrouter.ai/api/v1", discoveredModels: [], selectedModel: "qwen/qwen3.8-flash", selectionBasis: .user, lastDiscoveryAt: nil)]
            settings.activeProfileID = id
            raw = settings.merging(into: ["pi_profile_revisions": [id: UUID().uuidString.lowercased()]])
            try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]).write(to: profileFile, options: .atomic)
        }
        guard let profileID = NativeChatSettings.load(from: raw).activeProfileID else { throw PiBrokerError.invalid }
        let credentials = PiCandidateCredentials(profile: profileID)
        let config = ConfigStore(credentialStore: credentials, readConfiguration: { raw }, writeConfiguration: { value in
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: profileFile, options: .atomic)
        })
        let binding = try config.piSelectedProfileBinding()
        let accounting = try PiSharedAccounting(root: root.url.appendingPathComponent("accounting"), baselineNanos: 0)
        let provider = PiCandidateProviderFixture()
        let admission = PiAdmissionFixtureProtocol.admission()
        let executor = try config.piSelectedProfileOperation(binding: binding, admission: admission, accounting: accounting) { outgoing, request in
            try await provider.send(outgoing, request: request)
        }
        var runtimeArguments = arguments
        if let index = runtimeArguments.firstIndex(of: "--root") { runtimeArguments[index + 1] = root.url.appendingPathComponent("model").path }
        let owner = try NativePiAppOwner(arguments: runtimeArguments, executor: executor, ownerBinding: binding.digest, httpTransport: httpTransport)
        onOwner(owner)
        do {
            let ready = try await owner.start()
            try Task.checkCancellation()
            guard case .number(let port) = ready.pi("port"), let identity = ready.pi("profile").piString else { throw PiBrokerError.invalid }
            let workspace = try AssistantWorkspace(dataRoot: root.url.appendingPathComponent("ui"), endpoint: URL(string: "http://127.0.0.1:\(Int(port))")!, workspaceRoot: root.url.appendingPathComponent("model/runtime/workspaces"), runtimeIdentity: piHash(Data((root.url.path + ":" + identity).utf8))) { request in
                try await owner.http(request)
            }
            try await owner.bindAssistant(workspace.assistantID)
            return NativePiCandidate(root: root, config: config, credentials: credentials, provider: provider, accounting: accounting, owner: owner, workspace: workspace, admission: admission)
        } catch {
            await owner.stop()
            admission.session.invalidateAndCancel()
            throw error
        }
    }
    static func verifyNoCredentialFiles(_ root: URL) throws {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                try piCheck(try Data(contentsOf: file).range(of: Data(PiCandidateCredentials.key.utf8)) == nil, .storage)
            }
        }
    }
    func stop() async { await owner.stop(); admission.session.invalidateAndCancel() }
    static func main(_ arguments: [String], contract: Bool, recovery: Bool = false) async {
        do {
            let candidate = try await create(arguments)
            if recovery {
                do {
                    let report = try await candidate.workspace.verifyRecovery(requireFreshReply: false)
                    let calls = await candidate.provider.calls()
                    try piCheck(calls == 0)
                    await candidate.stop()
                    FileHandle.standardOutput.write(report + Data([10]))
                } catch { await candidate.stop(); throw error }
            } else if contract {
                do {
                    let workflow = try PiValue.piRead(await candidate.workspace.verifyWorkflow())
                    await candidate.stop()
                    let rows = try await candidate.accounting.snapshot()
                    let admission = PiAdmissionFixtureProtocol.state.evidence()
                    try piCheck(admission.pi("active") == .number(0))
                    try piCheck(admission.pi("priorities").piArray?.contains(.string("foreground")) == true && admission.pi("priorities").piArray?.contains(.string("background")) == true)
                    try piCheck(candidate.credentials.reads == 2)
                    try verifyNoCredentialFiles(candidate.root.url)
                    let report: PiValue = .object(["transport": .string("app-owned-mock"), "workflow": workflow, "admission": admission, "accounting": rows, "provider_fixture_calls": .number(Double(await candidate.provider.calls())), "credential_reads": .number(Double(candidate.credentials.reads)), "real_keychain_reads": .number(0), "real_provider_calls": .number(0), "installed_changes": .number(0)])
                    FileHandle.standardOutput.write(try report.piData() + Data([10]))
                } catch { await candidate.stop(); throw error }
            } else {
                throw PiBrokerError.invalid
            }
        } catch {
            FileHandle.standardError.write(Data("The isolated Vera candidate could not complete. Its saved work was preserved.\n".utf8))
            exit(1)
        }
    }
}
