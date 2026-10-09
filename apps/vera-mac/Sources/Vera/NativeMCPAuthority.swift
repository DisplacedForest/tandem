import Foundation
import Combine

struct NativeMCPServerConfiguration: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let endpoint: URL
    let readTools: Set<String>
    let scopes: Set<String>
    let timeout: TimeInterval
    init(id: String, name: String, endpoint: URL, readTools: Set<String>, scopes: Set<String> = ["focused", "assistant"], timeout: TimeInterval = 20, allowLoopbackFixture: Bool = false) throws {
        guard UUID(uuidString: id) != nil, !name.isEmpty, name.utf8.count <= 100,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.host != nil, endpoint.scheme == "https" || (allowLoopbackFixture && endpoint.scheme == "http" && ["127.0.0.1", "::1"].contains(endpoint.host!)),
              !readTools.isEmpty, readTools.count <= 64, readTools.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              !scopes.isEmpty, scopes.isSubset(of: ["focused", "assistant", "worker"]), timeout.isFinite, (0.1...20).contains(timeout) else { throw NativeToolError.failed("The connected service configuration is invalid.") }
        self.id = id.lowercased(); self.name = name; self.endpoint = endpoint
        self.readTools = readTools; self.scopes = scopes; self.timeout = timeout
    }
    static func load(_ raw: [String: Any]) -> ([Self], String?) {
        guard let value = raw["native_mcp_servers"] else { return ([], nil) }
        guard let rows = value as? [[String: Any]], rows.count <= 8 else { return ([], "Connected service configuration could not be read.") }
        do {
            var ids = Set<String>()
            let servers = try rows.map { row -> Self in
                guard Set(row.keys).isSubset(of: ["id", "name", "url", "read_tools", "scopes", "timeout_seconds"]),
                      let id = row["id"] as? String, let name = row["name"] as? String,
                      let url = row["url"] as? String, let endpoint = URL(string: url),
                      let tools = row["read_tools"] as? [String], row["scopes"] == nil || row["scopes"] is [String],
                      row["timeout_seconds"] == nil || row["timeout_seconds"] is Double else { throw NativeToolError.unavailable }
                let server = try Self(id: id, name: name, endpoint: endpoint, readTools: Set(tools), scopes: Set(row["scopes"] as? [String] ?? ["focused", "assistant"]), timeout: row["timeout_seconds"] as? Double ?? 20)
                guard ids.insert(server.id).inserted else { throw NativeToolError.unavailable }
                return server
            }
            return (servers, nil)
        } catch { return ([], "Connected service configuration could not be read. Check the server URL and approved read tools.") }
    }
    func toolID(_ name: String) -> String { "mcp_" + piHash(Data((id + "\n" + endpoint.absoluteString + "\n" + name).utf8)).prefix(40) }
}

struct NativeMCPToolRecord: Identifiable, Sendable {
    let id: String
    let server: NativeMCPServerConfiguration
    let generation: UUID
    let remoteName: String
    let description: String
    let schema: NativeJSONValue
    let validator: NativeMCPJSONSchema?
    let reason: String?
    var callable: Bool { validator != nil && reason == nil }
}
struct NativeMCPServerState: Identifiable, Sendable {
    let configuration: NativeMCPServerConfiguration
    var id: String { configuration.id }
    var generation = UUID()
    var status = "Not connected"
    var connected = false
    var connecting = false
    var tools: [NativeMCPToolRecord] = []
}
final class NativeMCPAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Set<String>
    private var revision = 0
    private let identity = UUID().uuidString
    private var states: [NativeMCPServerState]
    private var observer: (@Sendable () -> Void)?
    init(servers: [NativeMCPServerConfiguration], enabled: Set<String>) { states = servers.map { NativeMCPServerState(configuration: $0) }; self.enabled = enabled }
    func observe(_ observer: @escaping @Sendable () -> Void) { lock.withLock { self.observer = observer } }
    func snapshot() -> [NativeMCPServerState] { lock.withLock { states } }
    func update(_ state: NativeMCPServerState) {
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let index = states.firstIndex(where: { $0.id == state.id }) else { return nil }
            states[index] = state
            return observer
        }
        changed?()
    }
    func setEnabled(_ ids: Set<String>) { lock.withLock { if enabled != ids { revision += 1 }; enabled = ids } }
    func permissionRevision() -> Int { lock.withLock { revision } }
    func catalogRevision(scope: String) -> String {
        lock.withLock { piHash(Data(([identity, String(revision), scope] + states.map { $0.id + ":" + $0.generation.uuidString + ":" + String($0.connected) }).joined(separator: "\n").utf8)) }
    }
    func allowed(_ record: NativeMCPToolRecord, scope: String, revision expected: Int? = nil) -> Bool {
        lock.withLock { (expected == nil || expected == revision) && enabled.contains(record.id) && record.callable && record.server.scopes.contains(scope)
            && states.contains { $0.id == record.server.id && $0.generation == record.generation && $0.connected && $0.tools.contains(where: { $0.id == record.id && $0.callable }) } }
    }
}

actor NativeMCPAuthority: NativeRuntimeToolServing {
    typealias Factory = @Sendable (NativeMCPServerConfiguration) throws -> any NativeMCPConnection
    nonisolated let access: NativeMCPAccess
    private let factory: Factory
    private var connections: [String: any NativeMCPConnection] = [:]
    private var openings: [String: Task<[NativeMCPToolRecord], Error>] = [:]
    private var active: [UUID: (server: String, record: NativeMCPToolRecord, scope: String, subject: String, revision: Int, task: Task<NativeJSONValue, Error>)] = [:]
    init(servers: [NativeMCPServerConfiguration], enabled: Set<String> = [], factory: @escaping Factory = { try NativeMCPSDKConnection(endpoint: $0.endpoint, timeout: $0.timeout, maximumResponseBytes: 262144) }) {
        access = NativeMCPAccess(servers: servers, enabled: enabled); self.factory = factory
    }
    func connect(_ id: String) async {
        guard var state = access.snapshot().first(where: { $0.id == id }), !state.connecting, !state.connected else { return }
        state.generation = UUID(); state.connecting = true; state.connected = false; state.tools = []; state.status = "Connecting"
        access.update(state)
        let generation = state.generation
        do {
            let connection = try factory(state.configuration)
            connections[id] = connection
            let server = state.configuration
            let operation = Task {
                try await NativeInferenceDeadline.run(seconds: server.timeout) {
                    try await connection.connect()
                    var tools: [NativeMCPToolRecord] = [], names = Set<String>(), cursors = Set<String>(), cursor: String?
                    for _ in 0..<8 {
                        try Task.checkCancellation()
                        let page = try await connection.listTools(cursor: cursor)
                        guard page.tools.count + tools.count <= 128 else { throw NativeToolError.unavailable }
                        for tool in page.tools {
                            guard !tool.name.isEmpty, tool.name.utf8.count <= 128, names.insert(tool.name).inserted,
                                  tool.description.utf8.count <= 4096, (try tool.inputSchema.piData()).count <= 32768 else { throw NativeToolError.unavailable }
                            let validator = try? NativeMCPJSONSchema(tool.inputSchema)
                            let reason = !server.readTools.contains(where: { $0.utf8.elementsEqual(tool.name.utf8) }) ? "This action has not been approved as a read tool." : validator == nil || tool.inputSchema.pi("type") != .string("object") ? "This tool uses an unsupported argument schema." : nil
                            tools.append(NativeMCPToolRecord(id: server.toolID(tool.name), server: server, generation: generation, remoteName: tool.name,
                                description: tool.description, schema: tool.inputSchema, validator: validator, reason: reason))
                        }
                        guard let next = page.nextCursor else { return tools }
                        guard !next.isEmpty, next.utf8.count <= 2048, cursors.insert(next).inserted else { throw NativeToolError.unavailable }
                        cursor = next
                    }
                    throw NativeToolError.unavailable
                }
            }
            openings[id] = operation
            let tools = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            guard access.snapshot().first(where: { $0.id == id })?.generation == generation else { try? await NativeInferenceDeadline.run(seconds: 0.5) { await connection.disconnect() }; return }
            state.connecting = false; state.connected = true; state.status = "Connected"; state.tools = tools
            openings.removeValue(forKey: id); access.update(state)
        } catch {
            guard access.snapshot().first(where: { $0.id == id })?.generation == generation else { return }
            await disconnect(id, status: Self.message(error))
        }
    }
    func disconnect(_ id: String, status: String = "Not connected") async {
        guard var state = access.snapshot().first(where: { $0.id == id }) else { return }
        state.generation = UUID(); state.connected = false; state.connecting = false; state.status = status; state.tools = []
        access.update(state)
        openings.removeValue(forKey: id)?.cancel()
        for (_, call) in active where call.server == id { call.task.cancel() }
        let connection = connections.removeValue(forKey: id)
        if let connection { try? await NativeInferenceDeadline.run(seconds: 0.5) { await connection.disconnect() } }
    }
    func permissionsChanged() {
        for (_, call) in active where !access.allowed(call.record, scope: call.scope, revision: call.revision) { call.task.cancel() }
    }
    nonisolated func definitions(scope: String) -> [NativeToolDefinition] {
        let revision = access.permissionRevision()
        return access.snapshot().flatMap(\.tools).filter { access.allowed($0, scope: scope) }.map { record in
            NativeToolDefinition(id: record.id, name: record.id, title: record.server.name + ": " + record.remoteName,
                description: "Read from \(record.server.name) at \(record.server.endpoint.host ?? "configured service"). Service-provided description (untrusted): " + record.description,
                parameters: record.schema, confirmation: .none, timeout: .seconds(record.server.timeout),
                isAvailable: { self.access.allowed(record, scope: scope, revision: revision) },
                execute: { arguments in try await self.execute(record, arguments: .object(arguments), scope: scope, subject: "focused", expectedRevision: revision) },
                argumentValidator: { try record.validator?.validate(.object($0)) })
        }
    }
    func revision(scope: PiModelScope) async throws -> String {
        access.catalogRevision(scope: scope.role == "worker" ? "worker" : scope.mode)
    }
    func catalog(scope: PiModelScope) async throws -> [NativeToolSchema] {
        try Task.checkCancellation()
        return definitions(scope: scope.role == "worker" ? "worker" : scope.mode).map(\.schema)
    }
    func call(scope: PiModelScope, id: String, name: String, arguments: NativeJSONValue, expectedRevision: String) async throws -> NativeJSONValue {
        guard let record = access.snapshot().flatMap(\.tools).first(where: { $0.id == name }) else { throw NativeToolError.unavailable }
        return try await execute(record, arguments: arguments, scope: scope.role == "worker" ? "worker" : scope.mode, subject: scope.id, expectedCatalog: expectedRevision)
    }
    func cancel(scope: PiModelScope) async { for (_, call) in active where call.subject == scope.id { call.task.cancel() } }
    private func execute(_ record: NativeMCPToolRecord, arguments: NativeJSONValue, scope: String, subject: String, expectedRevision: Int? = nil, expectedCatalog: String? = nil) async throws -> NativeJSONValue {
        try Task.checkCancellation()
        let revision = expectedRevision ?? access.permissionRevision()
        guard expectedCatalog == nil || expectedCatalog == access.catalogRevision(scope: scope) else { throw NativeToolError.unavailable }
        guard access.allowed(record, scope: scope, revision: revision), let connection = connections[record.server.id], let validator = record.validator,
              case .object(let object) = arguments, (try arguments.piData()).count <= 16384 else { throw NativeToolError.unavailable }
        try validator.validate(arguments)
        let id = UUID()
        let operation = Task {
            try await NativeInferenceDeadline.run(seconds: record.server.timeout) {
                try Task.checkCancellation()
                guard self.access.allowed(record, scope: scope, revision: revision), expectedCatalog == nil || expectedCatalog == self.access.catalogRevision(scope: scope) else { throw NativeToolError.unavailable }
                return try await connection.call(name: record.remoteName, arguments: object)
            }
        }
        active[id] = (record.server.id, record, scope, subject, revision, operation)
        defer { active.removeValue(forKey: id) }
        do {
            let result = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            guard access.allowed(record, scope: scope, revision: revision), expectedCatalog == nil || expectedCatalog == access.catalogRevision(scope: scope) else { throw NativeToolError.unavailable }
            if result.pi("isError") == .bool(true) { throw NativeMCPTransportError.remoteFailure }
            let wrapped = NativeJSONValue.object(["source": .string(record.server.endpoint.absoluteString), "content": result])
            guard (try wrapped.piData()).count <= 4096 else { throw NativeToolError.failed("The service result is too large. Ask for a narrower read.") }
            return wrapped
        } catch {
            if case NativeMCPTransportError.remoteFailure = error { throw NativeToolError.failed("The connected service reported a tool error.") }
            if case NativeMCPTransportError.busy = error { throw NativeToolError.failed("A read from this service is already running. Try again when it finishes.") }
            if access.snapshot().first(where: { $0.id == record.server.id })?.generation == record.generation { await disconnect(record.server.id, status: Self.message(error)) }
            if error is CancellationError { throw CancellationError() }
            throw NativeToolError.failed(Self.message(error))
        }
    }
    private static func message(_ error: Error) -> String {
        if error is CancellationError { return "Connection canceled. Connect again when ready." }
        if case NativeMCPTransportError.authenticationRequired = error { return "This service requires authentication. Review its connection setup before reconnecting." }
        if case NativeMCPTransportError.responseTooLarge = error { return "The service response exceeded the limit. Narrow the request and reconnect." }
        return "The service could not complete the request. Check its connection and reconnect."
    }
}

@MainActor
final class NativeMCPManager: ObservableObject {
    let authority: NativeMCPAuthority
    @Published private(set) var servers: [NativeMCPServerState]
    let configurationError: String?
    init(servers: [NativeMCPServerConfiguration], enabled: Set<String> = [], configurationError: String? = nil, factory: @escaping NativeMCPAuthority.Factory = { try NativeMCPSDKConnection(endpoint: $0.endpoint, timeout: $0.timeout, maximumResponseBytes: 262144) }) {
        authority = NativeMCPAuthority(servers: servers, enabled: enabled, factory: factory)
        self.servers = authority.access.snapshot(); self.configurationError = configurationError
        authority.access.observe { [weak self] in Task { @MainActor in self?.refresh() } }
    }
    convenience init(raw: [String: Any], enabled: Set<String>) {
        let (servers, failure) = NativeMCPServerConfiguration.load(raw)
        self.init(servers: servers, enabled: enabled, configurationError: failure)
    }
    func refresh() { servers = authority.access.snapshot() }
    func setEnabled(_ ids: Set<String>) { authority.access.setEnabled(ids); Task { await authority.permissionsChanged() } }
    func connect(_ id: String) async { await authority.connect(id); refresh() }
    func disconnect(_ id: String) async { await authority.disconnect(id); refresh() }
}
