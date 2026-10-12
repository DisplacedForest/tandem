import Combine
import CryptoKit
import Foundation
import VeraAssistantUI

@MainActor
final class NativePiConnection {
    let workspace: AssistantWorkspace
    private let stopAction: () async -> Void
    private var stopping: Task<Void, Never>?
    init(workspace: AssistantWorkspace, stop: @escaping () async -> Void) {
        self.workspace = workspace
        stopAction = stop
    }
    func stop() async {
        if let stopping { await stopping.value; return }
        let action = stopAction
        let task = Task { await action() }
        stopping = task
        await task.value
    }
    static func prepared(arguments: [String], uiRoot: URL, provider: PiPreparedProvider) async throws -> NativePiConnection {
        let session = try await NativePiPreparedSession.create(arguments: arguments, uiRoot: uiRoot, provider: provider)
        return NativePiConnection(workspace: session.workspace, stop: { await session.owner.stop() })
    }
}

@MainActor
final class NativePiPresentation: ObservableObject {
    typealias Factory = @MainActor () async throws -> NativePiConnection
    @Published var isSelected = false
    @Published private(set) var connection: NativePiConnection?
    @Published private(set) var starting = false
    @Published private(set) var failure: String?
    private let factory: Factory?
    private var observation: AnyCancellable?
    private var startup: Task<NativePiConnection, Error>?
    private var shutdown: Task<Void, Never>?
    private var revision = 0
    private var stopped = false

    init(factory: Factory? = nil) { self.factory = factory }
    var session: AssistantSession? { connection?.workspace.session }
    var canConnect: Bool { factory != nil && connection == nil && !starting && !stopped }
    var canSend: Bool { session?.canSend == true && !stopped }
    var draft: String {
        get { session?.draft ?? "" }
        set { session?.setDraft(newValue) }
    }
    var conversation: Conversation? {
        guard let session else { return nil }
        return Conversation(id: session.id.uuidString, title: "Vera", messages: session.messages.map {
            Message(id: Self.messageID(conversation: session.id, source: $0.id), role: $0.isUser ? .user : .assistant,
                    text: $0.text, createdAt: Date(timeIntervalSince1970: 0))
        }, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }
    static func messageID(conversation: UUID, source: String) -> UUID {
        let normalized = UUID(uuidString: source)?.uuidString.lowercased() ?? source
        let bytes = Array(SHA256.hash(data: Data(("vera.pi.message:" + conversation.uuidString.lowercased() + ":" + normalized).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    func send() { guard canSend, let session else { return }; Task { await session.send() } }
    func connect() async {
        guard canConnect, let factory else { return }
        starting = true
        failure = nil
        revision += 1
        let generation = revision
        let task = Task { try await factory() }
        startup = task
        do {
            let result = try await task.value
            guard generation == revision else { return }
            if Task.isCancelled {
                await result.stop()
                if generation == revision { starting = false; startup = nil }
                return
            }
            result.workspace.session.select()
            observation = result.workspace.session.objectWillChange.sink { [weak self] in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
            connection = result
            await result.workspace.session.refresh()
        } catch {
            if generation == revision { failure = "Vera couldn't connect. Your saved work is preserved." }
        }
        if generation == revision { starting = false; startup = nil }
    }
    func stop() async {
        if let shutdown { await shutdown.value; return }
        stopped = true
        revision += 1
        let pending = startup
        pending?.cancel()
        let active = connection
        startup = nil
        connection = nil
        observation = nil
        starting = false
        let task = Task {
            if let pending, case .success(let result) = await pending.result { await result.stop() }
            if let active { await active.stop() }
        }
        shutdown = task
        await task.value
    }
}

@MainActor
enum NativePiNativeContext {
    static var candidate: NativePiCandidate?
    static var presentation = NativePiPresentation()
    static func validateIsolation(_ arguments: [String], environment: [String: String], foundationHome: URL, accountHome: URL) throws {
        guard let isolatedHome = environment["CFFIXED_USER_HOME"], isolatedHome.hasPrefix("/"),
              let index = arguments.firstIndex(of: "--root"), index + 1 < arguments.count else { throw PiBrokerError.invalid }
        let home = try piCanonical(URL(fileURLWithPath: isolatedHome))
        let actualHome = try piCanonical(accountHome)
        try piCheck(home.path != actualHome.path && !actualHome.path.hasPrefix(home.path + "/") && home.path != "/"
            && (try piCanonical(foundationHome)).path == home.path)
        for relative in [".vera", "Library/Application Support/Vera", "Library/Keychains"] {
            let protected = try piCanonical(actualHome.appendingPathComponent(relative)).path
            try piCheck(home.path != protected && !home.path.hasPrefix(protected + "/") && !protected.hasPrefix(home.path + "/"))
        }
        try piCheck(try piCanonical(URL(fileURLWithPath: arguments[index + 1])).path.hasPrefix(home.path + "/"))
        if let config = environment["VERA_CONFIG_DIR"] {
            try piCheck(try piCanonical(URL(fileURLWithPath: config)).path.hasPrefix(home.path + "/"))
        }
    }
    static func prepareFixture(_ arguments: [String]) async throws {
        guard let account = getpwuid(getuid()), let directory = account.pointee.pw_dir else { throw PiBrokerError.invalid }
        try validateIsolation(arguments, environment: ProcessInfo.processInfo.environment,
            foundationHome: FileManager.default.homeDirectoryForCurrentUser,
            accountHome: URL(fileURLWithPath: String(cString: directory)))
        let candidate = try await NativePiCandidate.create(arguments)
        self.candidate = candidate
        presentation = NativePiPresentation(factory: {
            NativePiConnection(workspace: candidate.workspace, stop: { await candidate.stop() })
        })
        await presentation.connect()
    }
}
