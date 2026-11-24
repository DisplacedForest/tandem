import Foundation
import Combine

struct NativeMCPServerConfiguration: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let endpoint: URL
    let readTools: Set<String>
    let actTools: Set<String>
    private(set) var asksTools: Set<String>
    private(set) var offTools: Set<String>
    private(set) var staysConnected: Bool
    let locked: Bool
    let scopes: Set<String>
    let timeout: TimeInterval
    enum Authentication: String, Sendable { case none, bearer, oauth }
    let authentication: Authentication
    let oauth: NativeMCPOAuthConfiguration?
    let publisher: String?
    let sourceURL: URL?
    init(id: String, name: String, endpoint: URL, readTools: Set<String>, actTools: Set<String> = [], asksTools: Set<String> = [], offTools: Set<String> = [], staysConnected: Bool = false, locked: Bool = false, scopes: Set<String> = ["focused", "assistant"], timeout: TimeInterval = 20, authentication: Authentication = .none, oauth: NativeMCPOAuthConfiguration? = nil, publisher: String? = nil, sourceURL: URL? = nil) throws {
        try NativeMCPAddress.validate(endpoint, personSupplied: true)
        guard UUID(uuidString: id) != nil, !name.isEmpty, name.utf8.count <= 100,
              readTools.union(actTools).allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              offTools.allSatisfy({ !$0.isEmpty }), asksTools.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              !scopes.isEmpty, scopes.isSubset(of: ["focused", "assistant", "worker"]), timeout.isFinite, (0.1...20).contains(timeout) else { throw NativeToolError.failed("The connected service configuration is invalid.") }
        guard (authentication == .oauth) == (oauth != nil), oauth == nil || oauth?.resource == endpoint else { throw NativeToolError.failed("The sign-in configuration is invalid.") }
        guard publisher.map({ !$0.isEmpty && $0.utf8.count <= 100 }) ?? true,
              sourceURL.map({ $0.scheme == "https" && $0.host != nil && $0.user == nil && $0.password == nil }) ?? true else { throw NativeToolError.failed("The connected service configuration is invalid.") }
        self.publisher = publisher; self.sourceURL = sourceURL
        self.oauth = oauth
        self.id = id.lowercased(); self.name = name; self.endpoint = endpoint
        self.readTools = readTools; self.actTools = actTools; self.asksTools = asksTools.intersection(readTools); self.offTools = offTools; self.locked = locked; self.staysConnected = staysConnected && authentication == .none; self.scopes = scopes; self.timeout = timeout; self.authentication = authentication
    }
    static func load(_ raw: [String: Any]) -> ([Self], String?) {
        guard let value = raw["native_mcp_servers"] else { return ([], nil) }
        guard let rows = value as? [[String: Any]] else { return ([], "Connected service configuration could not be read.") }
        do {
            var ids = Set<String>()
            let servers = try rows.map { row -> Self in
                guard Set(row.keys).isSubset(of: ["id", "name", "url", "read_tools", "act_tools", "asks_tools", "off_tools", "stays_connected", "address_saved", "scopes", "timeout_seconds", "authentication", "oauth", "publisher", "source_url"]),
                      let id = row["id"] as? String, let name = row["name"] as? String,
                      let url = row["url"] as? String, let endpoint = URL(string: url),
                      row["read_tools"] == nil || row["read_tools"] is [String], row["act_tools"] == nil || row["act_tools"] is [String],
                      row["asks_tools"] == nil || row["asks_tools"] is [String], row["off_tools"] == nil || row["off_tools"] is [String], row["stays_connected"] == nil || row["stays_connected"] is Bool, row["address_saved"] == nil || row["address_saved"] is Bool,
                      row["read_tools"] == nil && row["act_tools"] == nil || !((row["read_tools"] as? [String] ?? []) + (row["act_tools"] as? [String] ?? [])).isEmpty,
                      row["scopes"] == nil || row["scopes"] is [String],
                      row["timeout_seconds"] == nil || row["timeout_seconds"] is Double,
                      row["authentication"] == nil || row["authentication"] is String,
                      let authentication = Authentication(rawValue: row["authentication"] as? String ?? "none"),
                      row["publisher"] == nil || row["publisher"] is String,
                      row["source_url"] == nil || (row["source_url"] as? String).flatMap(URL.init(string:)) != nil else { throw NativeToolError.unavailable }
                let oauth = row["oauth"] == nil ? nil : try NativeMCPOAuthConfiguration.load(row["oauth"])
                let server = try Self(id: id, name: name, endpoint: endpoint, readTools: Set(row["read_tools"] as? [String] ?? []), actTools: Set(row["act_tools"] as? [String] ?? []), asksTools: Set(row["asks_tools"] as? [String] ?? []), offTools: Set(row["off_tools"] as? [String] ?? []), staysConnected: row["stays_connected"] as? Bool ?? false, locked: row["address_saved"] as? Bool ?? false, scopes: Set(row["scopes"] as? [String] ?? ["focused", "assistant"]), timeout: row["timeout_seconds"] as? Double ?? 20, authentication: authentication, oauth: oauth, publisher: row["publisher"] as? String, sourceURL: (row["source_url"] as? String).flatMap(URL.init(string:)))
                guard ids.insert(server.id).inserted else { throw NativeToolError.unavailable }
                return server
            }
            return (servers, nil)
        } catch NativeToolError.failed(let reason) where NativeMCPAddress.reasons.contains(reason) {
            return ([], reason)
        } catch { return ([], "Connected service configuration could not be read. Check the server URL and approved tools.") }
    }
    var source: String { (endpoint.scheme ?? "https") + "://" + (endpoint.host ?? "") }
    func toolID(_ name: String) -> String { "mcp_" + piHash(Data((id + "\n" + endpoint.absoluteString + "\n" + name).utf8)).prefix(40) }
    var reportsTools: Bool { readTools.isEmpty && actTools.isEmpty }
    func startsOn(_ name: String) -> Bool { reportsTools && !offTools.contains { $0.utf8.elementsEqual(name.utf8) } }
    func state(of name: String, hints: NativeMCPToolHints) -> NativeMCPToolState {
        if reportsTools { return hints.readOnly == true ? .read : .change }
        return NativeMCPToolState.classify(read: readTools.contains { $0.utf8.elementsEqual(name.utf8) }, act: actTools.contains { $0.utf8.elementsEqual(name.utf8) },
                                    remembered: asksTools.contains { $0.utf8.elementsEqual(name.utf8) }, hints: hints)
    }
    func sameService(_ other: Self) -> Bool { asking([]).turningOff([]).staying(false) == other.asking([]).turningOff([]).staying(false) }
    func carried(_ previous: Self) -> Set<String> { previous.id == id && previous.endpoint == endpoint ? previous.asksTools : [] }
    func asking(_ names: Set<String>) -> Self {
        var copy = self
        copy.asksTools = names.intersection(readTools)
        return copy
    }
    func turningOff(_ names: Set<String>) -> Self {
        var copy = self
        copy.offTools = names
        return copy
    }
    func staying(_ value: Bool) -> Self {
        var copy = self
        copy.staysConnected = value
        return copy
    }
    func newlyMarked(_ tools: [NativeMCPToolRecord]) -> Set<String> {
        Set(tools.filter { tool in tool.hints.tightens && readTools.contains { $0.utf8.elementsEqual(tool.remoteName.utf8) } && !asksTools.contains { $0.utf8.elementsEqual(tool.remoteName.utf8) } }.map(\.remoteName))
    }
}

extension NativeMCPToolHints {
    var tightens: Bool { readOnly == false || (readOnly != true && destructive == true) }
}

enum NativeMCPToolState: String, Sendable, Equatable {
    case unapproved, read, change
    static func classify(read: Bool, act: Bool, remembered: Bool, hints: NativeMCPToolHints) -> NativeMCPToolState {
        if act { return .change }
        guard read else { return .unapproved }
        return remembered || hints.tightens ? .change : .read
    }
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
    var hints = NativeMCPToolHints()
    var title: String? = nil
    var outputSchema: NativeJSONValue? = nil
    var outputValidator: NativeMCPJSONSchema? = nil
    var callable: Bool { validator != nil && reason == nil && state != .unapproved }
    var state: NativeMCPToolState { server.state(of: remoteName, hints: hints) }
    var asksBecauseOfService: Bool { state == .change && !server.reportsTools && !server.actTools.contains { $0.utf8.elementsEqual(remoteName.utf8) } }
    func on(_ server: NativeMCPServerConfiguration) -> Self {
        NativeMCPToolRecord(id: id, server: server, generation: generation, remoteName: remoteName, description: description, schema: schema, validator: validator, reason: reason, hints: hints,
                            title: title, outputSchema: outputSchema, outputValidator: outputValidator)
    }
}
struct NativeMCPServerState: Identifiable, Sendable {
    var configuration: NativeMCPServerConfiguration
    var id: String { configuration.id }
    var generation = UUID()
    var status = "Not connected"
    var connected = false
    var connecting = false
    var refused = false
    var notes: [String] = []
    var tools: [NativeMCPToolRecord] = []
}
final class NativeMCPAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Set<String>
    private var revision = 0
    private let identity = UUID().uuidString
    private var states: [NativeMCPServerState]
    private var observer: (@Sendable () -> Void)?
    private var authorizations: [String: NativeMCPAuthorization] = [:]
    private var oauthOwners: [String: NativeMCPOAuthConnectionLifetime] = [:]
    private var keeper: (@Sendable (String, Set<String>) async -> Bool)?
    init(servers: [NativeMCPServerConfiguration], enabled: Set<String>) { states = servers.map { NativeMCPServerState(configuration: $0) }; self.enabled = enabled }
    func observe(_ observer: @escaping @Sendable () -> Void) { lock.withLock { self.observer = observer } }
    func snapshot() -> [NativeMCPServerState] { lock.withLock { states } }
    func keepMarked(_ keeper: @escaping @Sendable (String, Set<String>) async -> Bool) { lock.withLock { self.keeper = keeper } }
    func saveMarked(_ names: Set<String>, serverID: String) async -> Bool {
        guard let keeper = lock.withLock({ keeper }) else { return false }
        return await keeper(serverID, names)
    }
    func remember(_ names: Set<String>, serverID: String, generation: UUID) -> NativeMCPServerConfiguration? {
        lock.withLock {
            guard let index = states.firstIndex(where: { $0.id == serverID }), states[index].generation == generation else { return nil }
            let configuration = states[index].configuration
            let next = configuration.asking(configuration.asksTools.union(names))
            states[index].configuration = next
            states[index].tools = states[index].tools.map { $0.on(next) }
            return next
        }
    }
    @discardableResult
    func update(_ state: NativeMCPServerState, expectedGeneration: UUID? = nil) -> Bool {
        let changed = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
            guard let index = states.firstIndex(where: { $0.id == state.id }), states[index].configuration == state.configuration,
                  expectedGeneration == nil || states[index].generation == expectedGeneration else { return (false, nil) }
            states[index] = state
            return (true, observer)
        }
        changed.1?()
        return changed.0
    }
    func setAuthorization(_ authorization: NativeMCPAuthorization?, serverID: String) {
        lock.withLock { authorizations[serverID] = authorization }
    }
    private func authorized(_ server: NativeMCPServerConfiguration) -> Bool {
        server.authentication == .none || (authorizations[server.id]?.isValid(serverID: server.id, endpoint: server.endpoint) == true && (server.authentication != .oauth || oauthOwners[server.id]?.isActive == true))
    }
    func oauthOwner(_ id: String) -> NativeMCPOAuthConnectionLifetime? { lock.withLock { oauthOwners[id] } }
    func setOAuthOwner(_ owner: NativeMCPOAuthConnectionLifetime) -> Bool {
        lock.withLock {
            guard owner.isActive, oauthOwners[owner.configuration.id] == nil,
                  states.contains(where: { $0.configuration.sameService(owner.configuration) && !$0.connected && !$0.connecting }) else { return false }
            oauthOwners[owner.configuration.id] = owner
            if let index = states.firstIndex(where: { $0.id == owner.configuration.id }) { states[index].generation = UUID() }
            return true
        }
    }
    func disconnectState(_ id: String, status: String, refused: Bool, owner: NativeMCPOAuthConnectionLifetime?, expectedGeneration: UUID?, preservingOAuth: Bool) -> Bool {
        let result = lock.withLock { () -> (NativeMCPOAuthConnectionLifetime?, (@Sendable () -> Void)?)? in
            guard let index = states.firstIndex(where: { $0.id == id }),
                  expectedGeneration == nil || states[index].generation == expectedGeneration,
                  owner == nil || oauthOwners[id] === owner else { return nil }
            let removed = preservingOAuth ? nil : oauthOwners.removeValue(forKey: id)
            authorizations.removeValue(forKey: id)
            states[index].generation = UUID()
            states[index].connected = false
            states[index].connecting = false
            states[index].status = status
            states[index].refused = refused
            states[index].notes = []
            states[index].tools = []
            return (removed, observer)
        }
        guard let result else { return false }
        result.0?.cancel()
        result.1?()
        return true
    }
    func replaceServers(_ servers: [NativeMCPServerConfiguration]) {
        let previous = lock.withLock {
            let previous = (Array(oauthOwners.values), Array(authorizations.values), observer)
            oauthOwners = [:]
            authorizations = [:]
            let remembered = Dictionary(states.map { ($0.id, $0.configuration) }, uniquingKeysWith: { first, _ in first })
            states = servers.map { NativeMCPServerState(configuration: $0.asking($0.asksTools.union(remembered[$0.id].map($0.carried) ?? []))) }
            revision += 1
            return previous
        }
        previous.0.forEach { $0.cancel() }
        previous.1.forEach { $0.revoke() }
        previous.2?()
    }
    func reconcileServers(_ servers: [NativeMCPServerConfiguration]) -> [String: UUID] {
        let result = lock.withLock { () -> ([String: UUID], [NativeMCPOAuthConnectionLifetime], [NativeMCPAuthorization], (@Sendable () -> Void)?) in
            var stale: [String: UUID] = [:]
            var next: [NativeMCPServerState] = []
            let previous = Dictionary(states.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for server in servers {
                guard var state = previous[server.id] else {
                    next.append(NativeMCPServerState(configuration: server))
                    continue
                }
                let server = server.asking(server.asksTools.union(server.carried(state.configuration)))
                if server.offTools != state.configuration.offTools { revision += 1 }
                if state.configuration == server {
                    next.append(state)
                } else if state.configuration.sameService(server) || Self.keepsConnection(state, server) {
                    state.configuration = server
                    state.tools = state.tools.map { $0.on(server) }
                    next.append(state)
                } else {
                    stale[state.id] = state.generation
                    next.append(NativeMCPServerState(configuration: server))
                }
            }
            let kept = Set(servers.map(\.id))
            for state in states where !kept.contains(state.id) { stale[state.id] = state.generation }
            let owners = stale.keys.compactMap { oauthOwners.removeValue(forKey: $0) }
            let leases = stale.keys.compactMap { authorizations.removeValue(forKey: $0) }
            states = next
            return (stale, owners, leases, observer)
        }
        result.1.forEach { $0.cancel() }
        result.2.forEach { $0.revoke() }
        result.3?()
        return result.0
    }
    private static func keepsConnection(_ state: NativeMCPServerState, _ server: NativeMCPServerConfiguration) -> Bool {
        let current = state.configuration
        return !state.connecting && current.authentication != .oauth && server.authentication != .oauth
            && current.id == server.id && current.endpoint == server.endpoint && current.readTools == server.readTools && current.actTools == server.actTools
            && current.timeout == server.timeout && current.authentication == server.authentication
    }
    func setEnabled(_ ids: Set<String>) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            guard enabled != ids else { return nil }
            revision += 1
            enabled = ids
            return observer
        }
        notify?()
    }
    func isOn(_ record: NativeMCPToolRecord) -> Bool {
        lock.withLock {
            guard let configuration = states.first(where: { $0.id == record.server.id })?.configuration else { return false }
            return configuration.reportsTools ? configuration.startsOn(record.remoteName) : enabled.contains(record.id)
        }
    }
    func startedIDs() -> Set<String> {
        lock.withLock {
            Set(states.flatMap { state in state.tools.filter { $0.callable && state.configuration.startsOn($0.remoteName) }.map(\.id) })
        }
    }
    func permissionRevision() -> Int { lock.withLock { revision } }
    func catalogRevision(scope: String) -> String {
        lock.withLock {
            var lines = [identity, String(revision), scope]
            for state in states {
                let parts = [state.id, state.generation.uuidString, String(state.connected), String(authorized(state.configuration)), String(state.configuration.scopes.contains(scope)), state.configuration.name]
                lines.append(parts.joined(separator: ":"))
                lines.append(contentsOf: state.tools.map { $0.id + "=" + $0.state.rawValue })
            }
            return piHash(Data(lines.joined(separator: "\n").utf8))
        }
    }
    func allowed(_ record: NativeMCPToolRecord, scope: String, revision expected: Int? = nil) -> Bool {
        lock.withLock {
            guard expected == nil || expected == revision else { return false }
            guard let configuration = states.first(where: { $0.id == record.server.id })?.configuration,
                  configuration.reportsTools ? configuration.startsOn(record.remoteName) : enabled.contains(record.id),
                  authorized(record.server), record.callable, record.server.scopes.contains(scope) else { return false }
            return states.contains { state in
                state.id == record.server.id && state.generation == record.generation && state.connected
                    && state.configuration.scopes.contains(scope)
                    && state.tools.contains { $0.id == record.id && $0.callable && $0.state == record.state }
            }
        }
    }
}

struct NativeMCPPermissionRevoked: Error {}
struct NativeMCPServiceFailure: Error { let text: String? }
struct NativeMCPMismatchedReply: Error {}
final class NativeMCPDispatchMark: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.withLock { value = true } }
    var sent: Bool { lock.withLock { value } }
}

actor NativeMCPAuthority: NativeRuntimeToolServing {
    typealias Factory = @Sendable (NativeMCPServerConfiguration) throws -> any NativeMCPConnection
    typealias AuthenticatedFactory = @Sendable (NativeMCPServerConfiguration, NativeMCPAuthorization?) throws -> any NativeMCPConnection
    nonisolated let access: NativeMCPAccess
    private let factory: AuthenticatedFactory
    private struct Handle {
        let serverID: String
        var lease: (authorization: NativeMCPAuthorization, observer: UUID)?
        var connection: (any NativeMCPConnection)?
        var opening: Task<(tools: [NativeMCPToolRecord], notes: [String]), Error>?
    }
    private var handles: [UUID: Handle] = [:]
    private var invalidatedCalls: Set<UUID> = []
    private var active: [UUID: (server: String, record: NativeMCPToolRecord, scope: String, subject: String, revision: Int, task: Task<NativeJSONValue, Error>)] = [:]
    init(servers: [NativeMCPServerConfiguration], enabled: Set<String> = [], factory: Factory? = nil, authenticatedFactory: AuthenticatedFactory? = nil) {
        access = NativeMCPAccess(servers: servers, enabled: enabled)
        self.factory = authenticatedFactory ?? { server, authorization in
            if let factory {
                guard authorization == nil else { throw NativeToolError.unavailable }
                return try factory(server)
            }
            return try NativeMCPSDKConnection(endpoint: server.endpoint, timeout: server.timeout, authorization: authorization, serverID: server.id)
        }
    }
    func connect(_ id: String, authorization: NativeMCPAuthorization? = nil, oauth: NativeMCPOAuthConnectionLifetime? = nil) async {
        if let authorization, authorization.revoked { return }
        guard var state = access.snapshot().first(where: { $0.id == id }), !state.configuration.locked else { authorization?.revoke(); return }
        if state.configuration.authentication == .oauth {
            guard let oauth, oauth.isActive, oauth.session != nil, oauth.configuration.sameService(state.configuration), access.oauthOwner(id) === oauth else { authorization?.revoke(); return }
        } else if oauth != nil { authorization?.revoke(); return }
        guard !state.connecting, !state.connected else {
            if !handles.values.contains(where: { $0.serverID == id && $0.lease?.authorization === authorization }) { authorization?.revoke() }
            return
        }
        let previousGeneration = state.generation
        state.generation = UUID(); state.connecting = true; state.connected = false; state.refused = false; state.notes = []; state.tools = []; state.status = "Connecting"
        guard access.update(state, expectedGeneration: previousGeneration) else { authorization?.revoke(); return }
        let generation = state.generation
        handles[generation] = Handle(serverID: id)
        do {
            let server = state.configuration
            if server.authentication != .none {
                guard let authorization, authorization.isValid(serverID: server.id, endpoint: server.endpoint) else {
                    authorization?.revoke()
                    throw NativeMCPTransportError.authenticationRequired
                }
                access.setAuthorization(authorization, serverID: id)
                let observer = authorization.onInvalidation { [weak self] in
                    Task { await self?.authorizationInvalidated(id, generation: generation) }
                }
                handles[generation]?.lease = (authorization, observer)
            } else if authorization != nil {
                authorization?.revoke()
                throw NativeMCPTransportError.authenticationRequired
            }
            guard server.authentication == .none || authorization?.isValid(serverID: server.id, endpoint: server.endpoint) == true else { throw NativeMCPTransportError.authenticationRequired }
            let connection = try factory(server, authorization)
            handles[generation]?.connection = connection
            let operation = Task {
                try await NativeInferenceDeadline.run(seconds: server.timeout) {
                    try Task.checkCancellation()
                    guard server.authentication == .none || authorization?.isValid(serverID: server.id, endpoint: server.endpoint) == true else { throw NativeMCPTransportError.authenticationRequired }
                    try await connection.connect()
                    var offered: [NativeMCPDiscoveredTool] = [], nameless = 0, repeated = 0, names = Set<String>(), cursors = Set<String>(), cursor: String?
                    while true {
                        try Task.checkCancellation()
                        guard server.authentication == .none || authorization?.isValid(serverID: server.id, endpoint: server.endpoint) == true else { throw NativeMCPTransportError.authenticationRequired }
                        let page = try await connection.listTools(cursor: cursor)
                        guard server.authentication == .none || authorization?.isValid(serverID: server.id, endpoint: server.endpoint) == true else { throw NativeMCPTransportError.authenticationRequired }
                        for tool in page.tools {
                            if tool.name.isEmpty { nameless += 1 }
                            else if !names.insert(tool.name).inserted { repeated += 1 }
                            else { offered.append(tool) }
                        }
                        guard let next = page.nextCursor else { return (tools: Self.records(offered, server: server, generation: generation), notes: Self.notes(nameless: nameless, repeated: repeated)) }
                        guard !next.isEmpty, cursors.insert(next).inserted else { throw NativeToolError.unavailable }
                        cursor = next
                    }
                }
            }
            handles[generation]?.opening = operation
            let discovered = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            guard access.snapshot().first(where: { $0.id == id })?.generation == generation else { await teardown(generation); return }
            try Task.checkCancellation()
            var tools = discovered.tools
            let marked = server.newlyMarked(tools)
            let unsaved = marked.union(server.asksTools)
            if !unsaved.isEmpty { _ = await access.saveMarked(unsaved, serverID: id) }
            if !marked.isEmpty {
                guard let kept = access.remember(marked, serverID: id, generation: generation) else { await teardown(generation); return }
                state.configuration = kept
                tools = tools.map { $0.on(kept) }
                try Task.checkCancellation()
            }
            guard server.authentication == .none || authorization?.isValid(serverID: server.id, endpoint: server.endpoint) == true else { throw NativeMCPTransportError.authenticationRequired }
            state.connecting = false; state.connected = true; state.status = server.authentication == .oauth ? "Signed in" : "Connected"; state.tools = tools; state.notes = discovered.notes
            handles[generation]?.opening = nil
            if !access.update(state, expectedGeneration: generation) { await teardown(generation) }
        } catch {
            guard access.snapshot().first(where: { $0.id == id })?.generation == generation else { await teardown(generation); return }
            await disconnect(id, status: Self.message(error), refused: Self.refused(error), expectedGeneration: generation)
        }
    }
    static func notes(nameless: Int, repeated: Int) -> [String] {
        (nameless > 0 ? ["This service listed \(nameless == 1 ? "a tool" : "\(nameless) tools") with no name, which can't be used."] : [])
            + (repeated > 0 ? ["This service listed \(repeated == 1 ? "a tool" : "\(repeated) tools") under a name it had already used. The first one is used."] : [])
    }
    private static func records(_ offered: [NativeMCPDiscoveredTool], server: NativeMCPServerConfiguration, generation: UUID) -> [NativeMCPToolRecord] {
        offered.map { tool in
            let validator = try? NativeMCPJSONSchema(tool.inputSchema)
            let reason = server.state(of: tool.name, hints: tool.hints) == .unapproved ? "This action has not been approved as a read tool." : validator == nil || tool.inputSchema.pi("type") != .string("object") ? "This tool uses an unsupported argument schema." : nil
            let title = tool.title.map { NativeToolRepair.plain(server.redacted($0)) }.flatMap { $0.isEmpty || $0.utf8.count > 256 ? nil : $0 }
            let output = tool.outputSchema
            let outputValidator = output.flatMap { try? NativeMCPJSONSchema($0) }
            let declared = tool.declaresOutput || tool.outputSchema != nil
            let outputReason = declared && outputValidator == nil ? "This tool declares a result shape Tandem can't check." : nil
            let addressReason = server.quotesAddress(tool.inputSchema) ? "This tool's settings include the service's address, so it isn't offered." : nil
            return NativeMCPToolRecord(id: server.toolID(tool.name), server: server, generation: generation, remoteName: tool.name,
                description: server.redacted(tool.description), schema: server.redactedSchema(tool.inputSchema), validator: validator, reason: reason ?? outputReason ?? addressReason, hints: tool.hints,
                title: title, outputSchema: output, outputValidator: outputValidator)
        }
    }
    private func authorizationInvalidated(_ id: String, generation: UUID) async {
        guard access.snapshot().first(where: { $0.id == id })?.generation == generation else { return }
        let oauth = access.snapshot().first(where: { $0.id == id })?.configuration.authentication == .oauth
        await disconnect(id, status: oauth ? "Sign-in ended. Review access and sign in again." : Self.tokenNeeded, refused: true, expectedGeneration: generation)
    }
    func disconnect(_ id: String, status: String = "Not connected", refused: Bool = false, oauth: NativeMCPOAuthConnectionLifetime? = nil, preservingOAuth: Bool = false, expectedGeneration: UUID? = nil) async {
        guard access.disconnectState(id, status: status, refused: refused, owner: oauth, expectedGeneration: expectedGeneration, preservingOAuth: preservingOAuth) else { return }
        let current = access.snapshot().first(where: { $0.id == id })?.generation
        let stale = handles.filter { $0.value.serverID == id && $0.key != current }.map(\.key)
        for generation in stale { await teardown(generation) }
    }
    func retire(_ stale: [String: UUID]) async {
        for generation in stale.values { await teardown(generation) }
        permissionsChanged()
    }
    private func teardown(_ generation: UUID) async {
        guard let handle = handles.removeValue(forKey: generation) else { return }
        if let lease = handle.lease {
            lease.authorization.removeInvalidationObserver(lease.observer)
            lease.authorization.revoke()
        }
        handle.opening?.cancel()
        for (key, call) in active where call.record.generation == generation {
            invalidatedCalls.insert(key)
            call.task.cancel()
        }
        if let connection = handle.connection { try? await NativeInferenceDeadline.run(seconds: 0.5) { await connection.disconnect() } }
    }
    func suspendOAuth(_ id: String, owner: NativeMCPOAuthConnectionLifetime) async -> Bool {
        guard access.oauthOwner(id) === owner, owner.isActive else { return false }
        await disconnect(id, status: "Refreshing sign-in", oauth: owner, preservingOAuth: true)
        return access.oauthOwner(id) === owner && owner.isActive
    }
    func permissionsChanged() {
        for (key, call) in active where !access.allowed(call.record, scope: call.scope, revision: call.revision) {
            invalidatedCalls.insert(key)
            call.task.cancel()
        }
    }
    nonisolated func shown(_ record: NativeMCPToolRecord) -> String {
        let name = NativeToolRepair.plain(record.remoteName)
        guard let title = record.title.map({ NativeToolRepair.plain($0) }), !title.isEmpty else { return name }
        let others = access.snapshot().filter { $0.id == record.server.id }.flatMap(\.tools).filter { $0.id != record.id }
        let taken = others.contains { other in
            [other.remoteName, other.title ?? ""].contains { NativeToolRepair.plain($0).compare(title, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame }
        }
        return taken ? name : title
    }
    nonisolated func definitions(scope: String) -> [NativeToolDefinition] {
        let revision = access.permissionRevision()
        return access.snapshot().flatMap(\.tools).filter { access.allowed($0, scope: scope) }.map { record in
            let change = record.state == .change
            let lead = change ? "Make a change through" : "Read from"
            return NativeToolDefinition(id: record.id, name: record.id, title: record.server.name + ": " + record.remoteName,
                description: "\(lead) \(record.server.name) at \(record.server.endpoint.host ?? "configured service"). Service-provided description (untrusted): " + record.description,
                parameters: record.schema, confirmation: .none, timeout: .seconds(record.server.timeout), effect: change ? .write : .read,
                action: change ? .serviceChanges : nil,
                isAvailable: { self.access.allowed(record, scope: scope, revision: revision) },
                execute: { arguments in try await self.execute(record, arguments: .object(arguments), scope: scope, subject: "focused", expectedRevision: revision) },
                argumentValidator: { try record.validator?.validate(.object($0)) },
                wants: change ? "use \(shown(record)) in \(NativeToolRepair.plain(record.server.name))" : nil,
                outputSchema: record.outputSchema, checksOwnResult: true)
        }
    }
    func revision(scope: PiModelScope) async throws -> String {
        access.catalogRevision(scope: scope.role == "worker" ? "worker" : scope.mode)
    }
    func catalog(scope: PiModelScope) async throws -> [NativeToolSchema] {
        try Task.checkCancellation()
        return definitions(scope: scope.role == "worker" ? "worker" : scope.mode).filter { $0.effect == .read }.map(\.schema)
    }
    func call(scope: PiModelScope, id: String, name: String, arguments: NativeJSONValue, expectedRevision: String) async throws -> NativeJSONValue {
        guard let record = access.snapshot().flatMap(\.tools).first(where: { $0.id == name }), record.state == .read else { throw NativeToolError.unavailable }
        let result = try await execute(record, arguments: arguments, scope: scope.role == "worker" ? "worker" : scope.mode, subject: scope.id, expectedCatalog: expectedRevision)
        guard try result.piData().count > PiRuntimeTools.resultBytes else { return result }
        return try NativeJSONValue.piRead(Data(NativeToolResultBudget.serialized(result, maximumBytes: PiRuntimeTools.resultBytes).utf8))
    }
    func cancel(scope: PiModelScope) async { for (_, call) in active where call.subject == scope.id { call.task.cancel() } }
    private func execute(_ record: NativeMCPToolRecord, arguments: NativeJSONValue, scope: String, subject: String, expectedRevision: Int? = nil, expectedCatalog: String? = nil) async throws -> NativeJSONValue {
        try Task.checkCancellation()
        let revision = expectedRevision ?? access.permissionRevision()
        guard expectedCatalog == nil || expectedCatalog == access.catalogRevision(scope: scope) else { throw NativeToolError.unavailable }
        guard access.allowed(record, scope: scope, revision: revision), let connection = handles[record.generation]?.connection, let validator = record.validator,
              case .object(let object) = arguments else { throw NativeToolError.unavailable }
        try validator.validate(arguments)
        let id = UUID()
        let dispatched = NativeMCPDispatchMark()
        let operation = Task {
            try await NativeInferenceDeadline.run(seconds: record.server.timeout) {
                try Task.checkCancellation()
                guard self.access.allowed(record, scope: scope, revision: revision), expectedCatalog == nil || expectedCatalog == self.access.catalogRevision(scope: scope) else { throw NativeMCPPermissionRevoked() }
                dispatched.mark()
                return try await connection.call(name: record.remoteName, arguments: object)
            }
        }
        active[id] = (record.server.id, record, scope, subject, revision, operation)
        defer { active.removeValue(forKey: id); invalidatedCalls.remove(id) }
        do {
            let result = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            guard access.allowed(record, scope: scope, revision: revision) else { throw NativeMCPPermissionRevoked() }
            if result.pi("isError") == .bool(true) { throw NativeMCPServiceFailure(text: Self.serviceText(record.server.redacted(result))) }
            if let output = record.outputValidator, result.pi("structuredContent") != .null {
                do { try output.validateResult(result.pi("structuredContent")) } catch { throw NativeMCPMismatchedReply() }
            }
            return NativeJSONValue.object(["source": .string(record.server.source), "content": record.server.redacted(result)])
        } catch {
            if let failure = error as? NativeMCPServiceFailure { throw NativeToolError.failed(Self.serviceFailure(failure.text)) }
            if error is NativeMCPMismatchedReply {
                throw NativeToolError.failed(Self.mismatch + (record.state == .change ? " The change may have been made, so check before trying it again." : ""))
            }
            if invalidatedCalls.contains(id) || error is NativeMCPPermissionRevoked {
                if error is CancellationError, Task.isCancelled { throw CancellationError() }
                if record.state == .change, dispatched.sent { throw NativeToolError.failed("Access to this service ended after the change was sent. It may have been made, so check before trying it again.") }
                throw NativeToolError.unavailable
            }
            if case NativeMCPTransportError.remoteFailure = error { throw NativeToolError.failed("The connected service reported a tool error.") }
            if case NativeMCPTransportError.busy = error { throw NativeToolError.failed(record.state == .change ? "Another request to this service is still running, so this change was not sent. Try again when it finishes." : "A read from this service is already running. Try again when it finishes.") }
            if access.snapshot().first(where: { $0.id == record.server.id })?.generation == record.generation { await disconnect(record.server.id, status: Self.message(error), refused: Self.refused(error), expectedGeneration: record.generation) }
            if error is CancellationError { throw CancellationError() }
            if case NativeMCPTransportError.responseTooLarge = error {
                throw NativeToolError.failed(Self.oversized + (record.state == .change ? " The change may have been made, so check before trying it again." : " Ask for a narrower read."))
            }
            throw NativeToolError.failed(Self.message(error))
        }
    }
    static let serviceFailureLead = "The connected service reported a tool error."
    static let serviceTextLabel = "Service-provided error text (untrusted): "
    static let serviceTextLimit = 400
    static let mismatch = "The service returned a result that does not match what it declared, so it was not used."
    static func serviceFailure(_ text: String?) -> String {
        guard let text else { return serviceFailureLead }
        return serviceFailureLead + " " + serviceTextLabel + text
    }
    static func serviceText(_ result: NativeJSONValue) -> String? {
        guard case .array(let items) = result.pi("content") else { return nil }
        let joined = items.compactMap { item -> String? in
            guard item.pi("type") == .string("text"), case .string(let text) = item.pi("text") else { return nil }
            return text
        }.joined(separator: " ")
        let cleaned = String(String.UnicodeScalarView(joined.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        let plain = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !plain.isEmpty else { return nil }
        return plain.count > serviceTextLimit ? String(plain.prefix(serviceTextLimit)) : plain
    }
    static let tokenNeeded = "This service needs a valid token. Enter one and connect again."
    static let oversized = "The service's reply is over \(NativeMCPSDKConnection.responseBytes.formatted(.number.locale(Locale(identifier: "en_US")))) bytes, the most Tandem takes in one reply."
    private static func refused(_ error: Error) -> Bool {
        if case NativeMCPTransportError.authenticationRequired = error { return true }
        return false
    }
    private static func message(_ error: Error) -> String {
        if error is CancellationError { return "Connection canceled. Connect again when ready." }
        if case NativeMCPTransportError.authenticationRequired = error { return tokenNeeded }
        if case NativeMCPTransportError.responseTooLarge = error { return oversized }
        return "The service could not complete the request. Check its connection and reconnect."
    }
}

@MainActor
final class NativeMCPManager: ObservableObject {
    let authority: NativeMCPAuthority
    @Published private(set) var servers: [NativeMCPServerState]
    let configurationError: String?
    @Published var oauthReviews: [String: NativeMCPOAuthReview] = [:]
    @Published var oauthProgress: [String: String] = [:]
    var oauthFlows: [String: NativeMCPOAuthFlow] = [:]
    var configurationGeneration = UUID()
    var replacingConfiguration = false
    let oauthTransport: any NativeMCPOAuthTransport
    let oauthBrowserFactory: @MainActor () -> any NativeMCPOAuthBrowser
    let oauthLifetimeForFixture: TimeInterval?
    static let tokenUnsaved = "The token couldn't be saved in your keychain, so this service was disconnected. Try again."
    static let tokenUnremoved = "The saved token couldn't be removed from your keychain. Choose Disconnect again."
    static let tokenUnused = "Tandem couldn't connect with the new token, so the saved one was kept."
    @Published private(set) var savedTokens: Set<String>
    let reconnectDelays: [Duration]
    static let disconnectUnsaved = "This couldn't be saved, so the service connects again when Tandem opens. Choose Connect, then Disconnect to try again."
    private var disconnectStatuses: [String: String] = [:]
    static let lockedAddress = "This service's address couldn't be read from your keychain. Unlock your keychain and choose Connect, or enter the address again under Manage."
    @Published var unmovedAddresses: Set<String> = []
    var unlock: ((String) -> Bool)?
    var keepsConnection: ((String, Bool) -> Bool)?
    private let keeper: NativeMCPTokenKeeper
    init(servers: [NativeMCPServerConfiguration], enabled: Set<String> = [], configurationError: String? = nil, factory: NativeMCPAuthority.Factory? = nil, authenticatedFactory: NativeMCPAuthority.AuthenticatedFactory? = nil, oauthTransport: any NativeMCPOAuthTransport = NativeMCPOAuthHTTPTransport(), oauthBrowserFactory: @escaping @MainActor () -> any NativeMCPOAuthBrowser = { NativeMCPOAuthSystemBrowser() }, oauthLifetimeForFixture: TimeInterval? = nil, tokens: any NativeCredentialStore = NativeCredentialFixtureStore(), prunesTokens: Bool = false, reconnectDelays: [Duration] = [.zero, .seconds(5), .seconds(15), .seconds(60), .seconds(300)]) {
        self.oauthTransport = oauthTransport
        self.oauthBrowserFactory = oauthBrowserFactory
        self.oauthLifetimeForFixture = oauthLifetimeForFixture
        authority = NativeMCPAuthority(servers: servers, enabled: enabled, factory: factory, authenticatedFactory: authenticatedFactory)
        self.reconnectDelays = reconnectDelays
        keeper = NativeMCPTokenKeeper(store: tokens)
        keeper.load(servers, prunes: prunesTokens)
        savedTokens = keeper.saved
        Self.markUnremoved(keeper, authority.access)
        Self.markLocked(authority.access)
        self.servers = authority.access.snapshot(); self.configurationError = configurationError
        authority.access.observe { [weak self] in Task { @MainActor in self?.refresh() } }
        keepConnected()
    }
    convenience init(raw: [String: Any], enabled: Set<String>, tokens: any NativeCredentialStore) {
        let (servers, failure) = NativeMCPServerConfiguration.load(raw)
        self.init(servers: servers, enabled: enabled, configurationError: failure, tokens: tokens, prunesTokens: failure == nil && !raw.isEmpty)
    }
    func refresh() {
        markLocked()
        servers = authority.access.snapshot()
        for (id, flow) in oauthFlows where !flow.owner.isActive { clearOAuthFlow(id, flow: flow) }
        keepConnected()
    }
    func setEnabled(_ ids: Set<String>) { authority.access.setEnabled(ids); Task { await authority.permissionsChanged() } }
    func connect(_ id: String, token: String? = nil) async {
        guard let server = servers.first(where: { $0.id == id })?.configuration else { return }
        guard server.authentication != .oauth else { return }
        if server.locked {
            guard unlock?(id) == true, let opened = servers.first(where: { $0.id == id })?.configuration, !opened.locked else { return }
            await connect(id, token: token)
            return
        }
        keeper.resume(id)
        let turn = keeper.turn(id)
        if let pending = keeper.inFlight(id) {
            await pending.value
            guard keeper.isCurrent(turn, id: id) else { return }
        }
        guard server.authentication == .bearer else {
            await openPlain(id)
            if keeper.isCurrent(turn, id: id), let state = authority.access.snapshot().first(where: { $0.id == id }),
               state.connected, state.configuration.sameService(server), !state.configuration.staysConnected {
                _ = keepsConnection?(id, true)
            }
            refresh()
            return
        }
        if let token { await open(server, token: token, saving: true) }
        else if let saved = keeper.read(server) { await open(server, token: saved, saving: false) }
        else {
            await authority.connect(id)
            savedTokens = keeper.saved
            Self.markUnremoved(keeper, authority.access)
        }
        refresh()
    }
    private func openPlain(_ id: String) async {
        await authority.connect(id)
        guard keeper.isPaused(id), let state = authority.access.snapshot().first(where: { $0.id == id }), state.connected || state.connecting else { return }
        await authority.disconnect(id, status: disconnectStatuses[id] ?? "Not connected", expectedGeneration: state.generation)
    }
    func hasSavedToken(_ id: String) -> Bool { savedTokens.contains(id) }
    func replaceToken(_ id: String, with token: String) async -> String? {
        if servers.first(where: { $0.id == id })?.configuration.locked == true, unlock?(id) != true { return Self.lockedAddress }
        guard let server = servers.first(where: { $0.id == id })?.configuration, server.authentication == .bearer else { return Self.tokenUnused }
        guard !server.locked else { return Self.lockedAddress }
        let turn = keeper.pause(id)
        await authority.disconnect(id)
        refresh()
        guard keeper.isCurrent(turn, id: id) else { return nil }
        await open(server, token: token, saving: true)
        guard keeper.isCurrent(turn, id: id) else { refresh(); return nil }
        guard authority.access.snapshot().first(where: { $0.id == id })?.connected == true else {
            guard hasSavedToken(id) else { refresh(); return NativeMCPAuthority.tokenNeeded }
            await authority.disconnect(id)
            if keeper.isCurrent(turn, id: id) { keeper.resume(id) }
            refresh()
            return Self.tokenUnused
        }
        keeper.resume(id)
        refresh()
        return nil
    }
    private func open(_ server: NativeMCPServerConfiguration, token: String, saving: Bool) async {
        guard let authorization = try? NativeMCPAuthorization(serverID: server.id, endpoint: server.endpoint, token: token) else {
            await authority.connect(server.id)
            return
        }
        let turn = keeper.turn(server.id)
        keeper.begin(authorization, id: server.id)
        await authority.connect(server.id, authorization: authorization)
        keeper.finish(authorization, id: server.id)
        guard saving, keeper.isCurrent(turn, id: server.id), let state = authority.access.snapshot().first(where: { $0.id == server.id }), state.connected,
              state.configuration.endpoint == server.endpoint, state.configuration.authentication == .bearer,
              authorization.isValid(serverID: server.id, endpoint: server.endpoint) else { return }
        do { try keeper.save(token, server: server); savedTokens = keeper.saved }
        catch { await authority.disconnect(server.id, status: Self.tokenUnsaved) }
    }
    func forgetTokens(leaving servers: [NativeMCPServerConfiguration]) throws {
        defer { savedTokens = keeper.saved }
        for state in authority.access.snapshot() where state.configuration.authentication == .bearer {
            let kept = servers.contains { $0.id == state.id && ($0.endpoint == state.configuration.endpoint || $0.locked || state.configuration.locked) && $0.authentication == .bearer }
            if !kept { try keeper.forget(state.id) }
        }
    }
    func restoreTokens(_ tokens: [String: String]) -> Bool {
        let restored = keeper.restore(tokens)
        savedTokens = keeper.saved
        refresh()
        return restored
    }
    func tokens(leaving servers: [NativeMCPServerConfiguration]) throws -> [String: String] {
        var result: [String: String] = [:]
        for state in authority.access.snapshot() where keeper.saved.contains(state.id) {
            let kept = servers.contains { $0.id == state.id && ($0.endpoint == state.configuration.endpoint || $0.locked || state.configuration.locked) && $0.authentication == .bearer }
            if !kept, let value = try keeper.raw(state.id) { result[state.id] = value }
        }
        return result
    }
    private func wantsConnection(_ id: String) -> Bool {
        guard let state = authority.access.snapshot().first(where: { $0.id == id }) else { return false }
        if state.configuration.locked { return unlock != nil }
        return keeps(state) && !state.connected && !state.connecting && !state.refused
    }
    var startedToolIDs: Set<String> { authority.access.startedIDs() }
    func keeps(_ server: NativeMCPServerState) -> Bool {
        switch server.configuration.authentication {
        case .bearer: return keeper.wants(server.id)
        case .none: return server.configuration.staysConnected && !keeper.isPaused(server.id)
        case .oauth: return false
        }
    }
    func reconnects(_ server: NativeMCPServerState) -> Bool {
        !server.configuration.locked && keeps(server) && !server.connected && !server.refused
    }
    private func markLocked() { Self.markLocked(authority.access) }
    private static func markLocked(_ access: NativeMCPAccess) {
        for var state in access.snapshot() where state.configuration.locked && state.status != lockedAddress {
            state.status = lockedAddress
            state.refused = true
            access.update(state, expectedGeneration: state.generation)
        }
    }
    private static func markUnremoved(_ keeper: NativeMCPTokenKeeper, _ access: NativeMCPAccess) {
        for var state in access.snapshot() where keeper.unremoved.contains(state.id) && !state.connected {
            state.status = tokenUnremoved
            state.refused = true
            access.update(state, expectedGeneration: state.generation)
        }
    }
    func keepConnected() {
        for state in servers {
            if state.connected { keeper.settled(state.id) }
            guard wantsConnection(state.id) else { continue }
            keeper.retry(state.id, delays: reconnectDelays) { [weak self] in await self?.attempt(state.id) } then: { [weak self] in self?.refresh() }
        }
    }
    private func attempt(_ id: String) async {
        guard wantsConnection(id), var server = authority.access.snapshot().first(where: { $0.id == id })?.configuration else { return }
        if server.locked {
            guard unlock?(id) == true, wantsConnection(id), let opened = authority.access.snapshot().first(where: { $0.id == id })?.configuration, !opened.locked else { return }
            server = opened
        }
        guard server.authentication == .bearer else {
            await openPlain(id)
            return
        }
        guard let token = keeper.read(server) else {
            savedTokens = keeper.saved
            Self.markUnremoved(keeper, authority.access)
            return
        }
        await open(server, token: token, saving: false)
    }
    func settleReconnects(scope: String) async {
        refresh()
        let waiting = servers.filter { $0.configuration.scopes.contains(scope) && (reconnects($0) || $0.configuration.locked) }.map(\.id)
        let runs = waiting.map { id in
            keeper.runNow(id) { [weak self] in await self?.attempt(id) } then: { [weak self] in self?.refresh() }
        }
        for run in runs { await run.value }
    }
    func disconnect(_ id: String) async {
        let state = authority.access.snapshot().first(where: { $0.id == id })
        let owner = authority.access.oauthOwner(id)
        cancelOAuthLocally(id)
        var status = "Not connected"
        if state?.configuration.authentication == NativeMCPServerConfiguration.Authentication.none {
            keeper.pause(id)
            if state?.configuration.staysConnected == true, keepsConnection?(id, false) == false { status = Self.disconnectUnsaved }
        }
        if state?.configuration.authentication == .bearer {
            do { try keeper.forget(id) } catch { status = Self.tokenUnremoved }
            savedTokens = keeper.saved
        }
        disconnectStatuses[id] = status
        await authority.disconnect(id, status: status, oauth: owner, expectedGeneration: owner == nil && state?.configuration.authentication == .oauth ? state?.generation : nil)
        refresh()
    }
}
