import Foundation
import GRDB
import Darwin

func piCanonical(_ url: URL) throws -> URL {
    if let resolved = realpath(url.path, nil) {
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
    try piCheck(errno == ENOENT && url.path != "/", .storage)
    return try piCanonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
}

final class PiExperimentRoot: @unchecked Sendable {
    let url: URL
    private var lock: Int32 = -1
    init(_ url: URL) throws {
        var original = stat()
        if lstat(url.path, &original) == 0 { try piCheck((original.st_mode & S_IFMT) == S_IFDIR, .storage) }
        let path = try piCanonical(url)
        let home = try piCanonical(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vera")).path
        try piCheck(path.path != "/" && path.path != home && !path.path.hasPrefix(home + "/") && !home.hasPrefix(path.path + "/"), .storage)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        try piCheck(lstat(path.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o077 == 0, .storage)
        for name in ["broker.lock", "broker.sqlite", "broker.sqlite-wal", "broker.sqlite-shm", "broker.sqlite-journal"] {
            let file = path.appendingPathComponent(name)
            if lstat(file.path, &info) == 0 { try piCheck((info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o077 == 0, .storage) }
            else { try piCheck(errno == ENOENT, .storage) }
        }
        lock = open(path.appendingPathComponent("broker.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else { if lock >= 0 { close(lock) }; lock = -1; throw PiBrokerError.storage }
        self.url = path
    }
    deinit { if lock >= 0 { close(lock) } }
}

final class PiModelLedger: @unchecked Sendable {
    let owner: PiExperimentRoot
    let database: DatabaseQueue
    let profile: String
    let budget: Int64
    let baseline: Int64
    let requestLimit: Int
    var reservation: Int64 { requestLimit > 12 ? 10_000_000 : 1_000_000 }
    init(root: URL, manifest: String, budget: Int64 = 1_000_000_000, baseline: Int64 = 0, ownerBinding: String = "fixture", transport: PiTransportKind = .mock, requestLimit: Int = 12) throws {
        try piCheck((12...1000).contains(requestLimit))
        self.requestLimit = requestLimit
        try piCheck(budget > 0 && budget <= 200_000_000_000 && baseline >= 0 && baseline <= budget, .budget)
        owner = try PiExperimentRoot(root)
        self.budget = budget
        self.baseline = baseline
        let file = owner.url.appendingPathComponent("broker.sqlite")
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        try piCheck(fd >= 0, .storage)
        close(fd)
        var configuration = Configuration()
        configuration.busyMode = .timeout(0.25)
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous=FULL") }
        database = try DatabaseQueue(path: file.path, configuration: configuration)
        profile = try database.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS bindings(subject TEXT PRIMARY KEY,binding TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS requests(id TEXT PRIMARY KEY,subject TEXT NOT NULL,digest TEXT NOT NULL,status TEXT NOT NULL,reserved INTEGER NOT NULL,charged INTEGER,reply BLOB)")
            for (key, value) in [("manifest", manifest), ("transport", transport.rawValue), ("budget", String(budget)), ("baseline", String(baseline)), ("owner_binding", ownerBinding)] {
                try db.execute(sql: "INSERT OR IGNORE INTO metadata VALUES(?,?)", arguments: [key, value])
                try piCheck(try Self.storedString(db, sql: "SELECT value FROM metadata WHERE key=?", arguments: [key]) == value, .unauthorized)
            }
            let generated = UUID().uuidString.lowercased()
            try db.execute(sql: "INSERT OR IGNORE INTO metadata VALUES('profile',?)", arguments: [generated])
            guard let profile = try Self.storedString(db, sql: "SELECT value FROM metadata WHERE key='profile'") else { throw PiBrokerError.storage }
            _ = try piUUID(.string(profile))
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS runtime_tools(subject TEXT NOT NULL,id TEXT NOT NULL,digest TEXT NOT NULL,state TEXT NOT NULL,result BLOB,PRIMARY KEY(subject,id))")
            try db.execute(sql: "UPDATE runtime_tools SET state='uncertain' WHERE state='reserved'")
            try db.execute(sql: "UPDATE requests SET status='uncertain' WHERE status='reserved'")
            try Self.validateRows(db, budget: budget - baseline, requestLimit: requestLimit)
            return profile
        }
    }
    static func storedString(_ db: Database, sql: String, arguments: StatementArguments = []) throws -> String? {
        guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return nil }
        let value: DatabaseValue = row[0]
        guard case .string(let result) = value.storage else { throw PiBrokerError.storage }
        return result
    }
    static func validateRows(_ db: Database, budget: Int64, requestLimit: Int = 12) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM requests")
        try piCheck(rows.count <= requestLimit, .storage)
        var exposure: Int64 = 0, counts: [String: Int] = [:]
        for row in rows {
            let idValue: DatabaseValue = row["id"], subjectValue: DatabaseValue = row["subject"], digestValue: DatabaseValue = row["digest"], statusValue: DatabaseValue = row["status"]
            let reservedValue: DatabaseValue = row["reserved"], chargedValue: DatabaseValue = row["charged"], replyValue: DatabaseValue = row["reply"]
            guard case .string(let id) = idValue.storage, case .string(let subject) = subjectValue.storage, case .string(let digest) = digestValue.storage, case .string(let status) = statusValue.storage, case .int64(let reserved) = reservedValue.storage else { throw PiBrokerError.storage }
            _ = try piUUID(.string(id)); _ = try piUUID(.string(subject))
            let charged: Int64?, reply: Data?
            switch chargedValue.storage { case .null: charged = nil; case .int64(let value): charged = value; default: throw PiBrokerError.storage }
            switch replyValue.storage { case .null: reply = nil; case .blob(let value): reply = value; default: throw PiBrokerError.storage }
            try piCheck(digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) } && ["reserved", "completed", "uncertain", "abandoned", "not_sent"].contains(status) && reserved == (requestLimit > 12 ? 10_000_000 : 1_000_000), .storage)
            if status == "completed" {
                try piCheck(charged != nil && reply != nil, .storage)
                let saved = try PiValue.piRead(reply!)
                try PiModelReply.validate(saved)
                try piCheck(charged == PiModelReply.costNanos(saved) && charged! <= reserved, .storage)
            } else if status == "not_sent" { try piCheck(charged == 0 && reply == nil, .storage) }
            else { try piCheck(charged == nil && reply == nil, .storage) }
            let document = try isDocument(db, subject: subject)
            try piCheck(status != "abandoned" || document, .storage)
            if let reply {
                let output = try PiValue.piRead(reply).pi("usage").pi("output")
                guard case .number(let count) = output else { throw PiBrokerError.storage }
                try piCheck(count <= (document ? 1024 : 256), .storage)
            }
            counts[subject, default: 0] += 1
            try piCheck(counts[subject]! <= (document ? 12 : 4), .storage)
            exposure += charged ?? reserved
        }
        try piCheck(exposure <= budget, .storage)
    }
    static func isDocument(_ db: Database, subject: String) throws -> Bool {
        let binding = try storedString(db, sql: "SELECT binding FROM bindings WHERE subject=?", arguments: [subject])
        let parts = binding?.split(separator: ":") ?? []
        return parts.count == 6 && parts[3] == "document" && parts[4] == "assistant"
    }
    static func unresolved(_ db: Database, subject: String? = nil) throws -> Bool {
        for row in try Row.fetchAll(db, sql: "SELECT subject FROM requests WHERE status='uncertain'") {
            let owner: String = row["subject"]
            let document = try isDocument(db, subject: owner)
            if owner == subject || !document { return true }
        }
        return false
    }
    func hasUncertainty() throws -> Bool { try database.read { try Self.unresolved($0) } }
    func retryDocument(_ subject: String) throws {
        try database.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM requests WHERE subject=?", arguments: [subject]) ?? 0
            if count == 0 { return }
            try piCheck(try Self.isDocument(db, subject: subject), .unauthorized)
            try db.execute(sql: "UPDATE requests SET status='abandoned' WHERE subject=? AND status='uncertain'", arguments: [subject])
            try Self.validateRows(db, budget: budget - baseline, requestLimit: requestLimit)
        }
    }
    func bind(_ scope: PiModelScope) throws {
        try database.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO bindings VALUES(?,?)", arguments: [scope.subject, scope.binding])
            try piCheck(try Self.storedString(db, sql: "SELECT binding FROM bindings WHERE subject=?", arguments: [scope.subject]) == scope.binding, .unauthorized)
        }
    }
    func reserve(_ request: PiModelRequest) throws -> PiValue? {
        try database.write { db in
            try Self.validateRows(db, budget: budget - baseline, requestLimit: requestLimit)
            if let row = try Row.fetchOne(db, sql: "SELECT digest,status,reply FROM requests WHERE id=?", arguments: [request.id]) {
                try piCheck(row["digest"] as String == request.digest, .duplicate)
                guard row["status"] as String == "completed", let data: Data = row["reply"] else { throw PiBrokerError.uncertain }
                return try PiValue.piRead(data)
            }
            try piCheck(try !Self.unresolved(db, subject: request.scope.subject), .uncertain)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM requests") ?? 12
            let own = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM requests WHERE subject=?", arguments: [request.scope.subject]) ?? 4
            let exposure = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(COALESCE(charged,reserved)),0) FROM requests") ?? budget
            try piCheck(count < requestLimit && own < (request.scope.role == "document" ? 12 : 4) && exposure <= budget - baseline - reservation, .budget)
            try db.execute(sql: "INSERT INTO requests VALUES(?,?,?,'reserved',?,NULL,NULL)", arguments: [request.id, request.scope.subject, request.digest, reservation])
            return nil
        }
    }
    func settle(_ id: String, reply: PiValue) throws {
        let data = try reply.piData()
        try PiModelReply.validate(reply)
        let charged = PiModelReply.costNanos(reply)
        try piCheck(charged >= 0 && charged <= reservation, .budget)
        try database.write { db in
            try db.execute(sql: "UPDATE requests SET status='completed',charged=?,reply=? WHERE id=? AND status='reserved'", arguments: [charged, data, id])
            try piCheck(db.changesCount == 1, .storage)
        }
    }
    func notSent(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE requests SET status='not_sent',charged=0 WHERE id=? AND status='reserved'", arguments: [id])
            try piCheck(db.changesCount == 1, .storage)
        }
    }
    func uncertain(_ id: String) {
        try? database.write { db in try db.execute(sql: "UPDATE requests SET status='uncertain' WHERE id=? AND status='reserved'", arguments: [id]) }
    }
    func snapshot() throws -> PiValue {
        try database.read { db in
            try Self.validateRows(db, budget: budget - baseline, requestLimit: requestLimit)
            let rows = try Row.fetchAll(db, sql: "SELECT id,status,reserved,charged FROM requests ORDER BY rowid")
            return .array(rows.map { row in .object(["id": .string(row["id"]), "status": .string(row["status"]), "reserved": .number(Double(row["reserved"] as Int64)), "charged": (row["charged"] as Int64?).map { .number(Double($0)) } ?? .null]) })
        }
    }
}

enum PiModelReply {
    static func costNanos(_ reply: PiValue) -> Int64 {
        guard case .number(let cost) = reply.pi("usage").pi("cost_usd"), cost.isFinite, cost >= 0, cost <= 0.01 else { return -1 }
        return Int64((cost * 1_000_000_000).rounded(.up))
    }
    static func validate(_ reply: PiValue, request: PiModelRequest? = nil) throws {
        try reply.piKeys(["content", "usage"])
        try reply.pi("usage").piKeys(["input", "output", "cost_usd"])
        guard case .number(let input) = reply.pi("usage").pi("input"), case .number(let output) = reply.pi("usage").pi("output") else { throw PiBrokerError.invalid }
        try piCheck(input.isFinite && input.rounded() == input && (0...16384).contains(input) && output.isFinite && output.rounded() == output && (0...(request == nil || request?.scope.role == "document" ? 1024 : 256)).contains(output) && costNanos(reply) >= 0 && (try reply.piData()).count <= 65536)
        guard let content = reply.pi("content").piArray, !content.isEmpty, content.count <= 9 else { throw PiBrokerError.invalid }
        var ids = Set<String>()
        for block in content {
            if block.pi("type").piString == "text" { try PiModelRequest.text(block) }
            else {
                try block.piKeys(["type", "id", "name", "arguments"])
                try piCheck(block.pi("type").piString == "toolCall")
                let id = try piToolID(block.pi("id"))
                try piCheck(ids.insert(id).inserted && ids.count <= 8)
                if let request {
                    try piCheck(request.toolCount + ids.count <= 8 && !request.toolIDs.contains(id))
                    try PiModelRequest.arguments(block.pi("arguments"), name: block.pi("name").piString ?? "", scope: request.scope, hostTools: request.hostTools)
                } else {
                    try piCheck(block.pi("name").piString != nil && block.pi("arguments").piObject != nil)
                }
            }
        }
    }
}

final class PiModelRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PiValue, Error>?
    private var result: Result<PiValue, Error>?
    func install(_ continuation: CheckedContinuation<PiValue, Error>) {
        lock.lock(); defer { lock.unlock() }
        if let result { continuation.resume(with: result) }
        else { self.continuation = continuation }
    }
    func resolve(_ result: Result<PiValue, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

actor NativePiModelBroker {
    let ledger: PiModelLedger
    let channel: String
    let expires: Date
    let executor: any PiMockModelExecutor
    let timeout: Duration
    let tools: (any NativeRuntimeToolServing)?
    private var toolSnapshots: [String: PiRuntimeToolSnapshot] = [:]
    private var scopes: [String: PiModelScope] = [:]
    private var active: [String: (String, Task<PiValue, Error>, PiModelRace)] = [:]
    private var toolActive: [String: (PiModelScope, Task<PiValue, Error>, PiModelRace)] = [:]
    private var canceled = Set<String>()
    private var closed = false
    private var quarantined = false
    init(ledger: PiModelLedger, channel: String, executor: any PiMockModelExecutor = PiFixtureModel(), expires: Date = Date().addingTimeInterval(600), timeout: Duration = .seconds(3), tools: (any NativeRuntimeToolServing)? = nil) {
        self.tools = tools
        self.ledger = ledger; self.channel = channel; self.executor = executor; self.expires = expires; self.timeout = timeout
    }
    func retryDocument(_ subject: String) async throws {
        try piCheck(!closed && Date() < expires, .unauthorized)
        try await executor.retryDocument(subject)
        try ledger.retryDocument(subject)
        quarantined = try ledger.hasUncertainty()
    }
    func authorize(_ value: PiValue) throws -> PiModelScope {
        try piCheck(!closed && !quarantined && Date() < expires && scopes.count < ledger.requestLimit + 4, .unauthorized)
        let scope = try PiModelScope(value, profile: ledger.profile)
        try piCheck(!scopes.values.contains { $0.subject == scope.subject }, .duplicate)
        try ledger.bind(scope)
        scopes[scope.id] = scope
        return scope
    }
    func complete(_ value: PiValue) async throws -> PiValue {
        try await executor.validateOwner()
        try piCheck(!closed && Date() < expires, .unauthorized)
        try piCheck(!quarantined, .uncertain)
        let scope = try toolRequestScope(value)
        let snapshot = try await toolSnapshot(scope)
        let request = try await executor.prepareRequest(PiModelRequest(value, scope: scope, channel: channel, hostTools: snapshot.schemas, hostToolRevision: snapshot.revision, hostToolAuthority: tools))
        try await executor.validateRequest(request)
        try piCheck(!closed && !quarantined && Date() < expires && scopes[scope.id]?.binding == scope.binding, .unauthorized)
        try piCheck(!canceled.contains(request.id), .canceled)
        try piCheck(!active.values.contains { $0.0 == scope.role }, .unavailable)
        if let saved = try ledger.reserve(request) {
            try await executor.validateOwner()
            try piCheck(!closed && !quarantined && !canceled.contains(request.id), .unauthorized)
            try await executor.validateRequest(request)
            try piCheck(!closed && !quarantined && Date() < expires && !canceled.contains(request.id) && scopes[scope.id]?.binding == scope.binding, .unauthorized)
            try piCheck(try await toolSnapshot(scope) == snapshot, .unauthorized)
            try PiModelReply.validate(saved, request: request)
            return saved
        }
        let operation = Task { [executor] in
            try await request.validateHostTools()
            return try await executor.complete(request)
        }
        let race = PiModelRace()
        active[request.id] = (scope.role, operation, race)
        let receiver = Task { race.resolve(await operation.result) }
        let timer = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { operation.cancel(); race.resolve(.failure(PiBrokerError.unavailable)) }
        }
        defer { timer.cancel(); receiver.cancel(); active.removeValue(forKey: request.id) }
        let reply: PiValue
        var rejection: Error?
        do {
            reply = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { race.install($0) }
            } onCancel: {
                operation.cancel(); race.resolve(.failure(CancellationError()))
            }
            try Task.checkCancellation()
            try piCheck(!closed && Date() < expires && !operation.isCancelled, .canceled)
            do { try await executor.validateRequest(request) } catch { rejection = error }
            try piCheck(!closed && !quarantined && Date() < expires && !canceled.contains(request.id) && scopes[scope.id]?.binding == scope.binding, .unauthorized)
            try piCheck(try await toolSnapshot(scope) == snapshot, .unauthorized)
            try PiModelReply.validate(reply, request: request)
            try ledger.settle(request.id, reply: reply)
        } catch {
            if error is PiInferenceNotDispatched {
                try ledger.notSent(request.id)
            } else {
                if request.scope.role != "document" { quarantined = true }
                ledger.uncertain(request.id)
            }
            throw error
        }
        if let rejection { throw rejection }
        return reply
    }
    func toolCatalog(_ scope: PiModelScope) async throws -> [NativeToolSchema] {
        try await toolSnapshot(scope).schemas
    }
    func toolSnapshot(_ scope: PiModelScope) async throws -> PiRuntimeToolSnapshot {
        try await executor.validateOwner()
        try piCheck(!closed && !quarantined && Date() < expires && scopes[scope.id]?.binding == scope.binding, .unauthorized)
        let result = try await PiRuntimeToolSnapshot.capture(scope: scope, authority: tools)
        if let expected = toolSnapshots[scope.id] { try piCheck(expected == result, .unauthorized) }
        else { toolSnapshots[scope.id] = result }
        try piCheck(!closed && !quarantined && Date() < expires && scopes[scope.id]?.binding == scope.binding, .unauthorized)
        return result
    }
    func toolRequestScope(_ value: PiValue) throws -> PiModelScope {
        guard let scope = scopes[value.pi("scope").piString ?? ""] else { throw PiBrokerError.unauthorized }
        try piCheck(value.pi("channel").piString == channel && value.pi("profile").piString == scope.profile && value.pi("subject").piString == scope.subject && value.pi("role").piString == scope.role && value.pi("mode").piString == scope.mode && value.pi("assistant").piString == scope.assistant && value.pi("conversation").piString == scope.conversation, .unauthorized)
        return scope
    }
    func validateDocumentHandoff(_ value: PiValue) async throws {
        try value.piKeys(["op", "id", "channel", "profile", "scope", "subject", "role", "mode", "assistant", "conversation", "task_id"])
        _ = try piUUID(value.pi("id"))
        _ = try piUUID(value.pi("task_id"))
        let scope = try toolRequestScope(value)
        try piCheck(scope.role == "foreground" && scope.mode == "assistant", .unauthorized)
        _ = try await toolSnapshot(scope)
    }
    func toolOperation(_ value: PiValue) async throws -> PiValue {
        let op = value.pi("op").piString
        var keys: Set<String> = ["op", "id", "channel", "profile", "scope", "subject", "role", "mode", "assistant", "conversation"]
        if op == "tool_call" { keys.formUnion(["call_id", "name", "arguments"]) }
        try value.piKeys(keys)
        let id = try piUUID(value.pi("id"))
        let scope = try toolRequestScope(value)
        let snapshot = try await toolSnapshot(scope)
        let catalog = snapshot.schemas
        try piCheck(!canceled.contains(id), .canceled)
        if op == "tool_catalog" { return .object(["tools": PiRuntimeTools.wire(catalog)]) }
        try piCheck(op == "tool_call", .unauthorized)
        guard let tools, let revision = snapshot.revision, let name = value.pi("name").piString, catalog.contains(where: { $0.name == name }) else { throw PiBrokerError.unauthorized }
        let callID = try piToolID(value.pi("call_id")), arguments = value.pi("arguments")
        try PiModelRequest.arguments(arguments, name: name, scope: scope, hostTools: catalog)
        try piCheck(toolActive[id] == nil && !toolActive.values.contains(where: { $0.0.id == scope.id }), .duplicate)
        let digest = piHash(try PiValue.object(["binding": .string(scope.binding), "name": .string(name), "arguments": arguments, "revision": snapshot.revision.map(PiValue.string) ?? .null, "catalog": PiRuntimeTools.wire(snapshot.schemas)]).piData())
        if let saved = try ledger.reserveTool(scope: scope, id: callID, digest: digest) {
            try piCheck(try await toolSnapshot(scope) == snapshot, .unauthorized)
            try piCheck(!canceled.contains(id), .canceled)
            return .object(["value": saved])
        }
        let operation = Task {
            try piCheck(try await self.toolSnapshot(scope) == snapshot, .unauthorized)
            try Task.checkCancellation()
            return try await tools.call(scope: scope, id: callID, name: name, arguments: arguments, expectedRevision: revision)
        }
        let race = PiModelRace()
        toolActive[id] = (scope, operation, race)
        let receiver = Task { race.resolve(await operation.result) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { operation.cancel(); race.resolve(.failure(PiBrokerError.unavailable)) }
        }
        defer { timer.cancel(); receiver.cancel(); toolActive.removeValue(forKey: id) }
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { race.install($0) }
            } onCancel: { operation.cancel(); race.resolve(.failure(CancellationError())) }
            try Task.checkCancellation()
            let current = try await toolSnapshot(scope)
            try piCheck(!canceled.contains(id) && !operation.isCancelled, .canceled)
            try piCheck(current == snapshot, .unauthorized)
            try piCheck(try result.piData().count <= 8192)
            try ledger.settleTool(scope: scope, id: callID, result: result)
            return .object(["value": result])
        } catch {
            operation.cancel()
            ledger.uncertainTool(scope: scope, id: callID)
            await tools.cancel(scope: scope)
            throw error
        }
    }
    func cancel(_ id: String) async {
        guard canceled.count < 128 else { await close(); return }
        canceled.insert(id)
        if let value = toolActive[id] {
            value.1.cancel(); value.2.resolve(.failure(CancellationError()))
            await tools?.cancel(scope: value.0)
        }
        if let value = active[id] { value.1.cancel(); value.2.resolve(.failure(CancellationError())) }
    }
    func revoke(subject: String) async {
        let owned = scopes.values.filter { $0.subject == subject }
        for scope in owned { scopes.removeValue(forKey: scope.id); toolSnapshots.removeValue(forKey: scope.id) }
        let calls = toolActive.filter { $0.value.0.subject == subject }.map(\.key)
        for id in calls { await cancel(id) }
        for scope in owned { await tools?.cancel(scope: scope) }
    }
    func close() async {
        closed = true
        for value in toolActive.values { value.1.cancel(); value.2.resolve(.failure(CancellationError())) }
        for value in active.values { value.1.cancel(); value.2.resolve(.failure(CancellationError())) }
        let owned = Array(scopes.values)
        scopes.removeAll()
        toolSnapshots.removeAll()
        for scope in owned { await tools?.cancel(scope: scope) }
    }
}
