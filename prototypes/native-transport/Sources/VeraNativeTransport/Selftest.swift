import Foundation
import CSQLite
import Darwin

func ensure(_ condition: Bool) throws { try require(condition) }

final class FixtureCredential: CredentialSource, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let missing: Bool
    let sentinel = "synthetic-broker-key-never-real-7b52"
    init(missing: Bool = false) { self.missing = missing }
    func read(profile: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if missing { throw Failure.credentialUnavailable }
        return sentinel
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
}

actor FixtureHTTP: HTTPTransport {
    let delay: Duration
    let scripted: Bool
    var paid = 0
    var stopped = 0
    var body: Data?
    var response: Data?
    var usage: Decimal
    init(delay: Duration = .zero, response: Data? = nil, usage: Decimal = 0, scripted: Bool = false) { self.scripted = scripted; self.delay = delay; self.response = response; self.usage = usage }
    static let catalog: J = .object(["data": .array([.object(["id": .string(modelID), "supported_parameters": .array(["tools", "max_tokens", "reasoning"].map(J.string)), "reasoning": .object(["mandatory": .bool(false)]), "pricing": .object(["prompt": .string("0.000001"), "completion": .string("0.000002")])])])])
    static let answer: J = .object(["model": .string(modelID), "choices": .array([.object(["finish_reason": .string("stop"), "message": .object(["role": .string("assistant"), "content": .string("Fixture response")])])]), "usage": .object(["prompt_tokens": .number(20), "completion_tokens": .number(4), "cost": .number(Decimal(string: "0.000028")!)])])
    static func script(_ body: J) throws -> J {
        let messages = body["messages"].array ?? []
        let names = Set(body["tools"].array?.compactMap { $0["function"]["name"].string } ?? [])
        let calls = messages.flatMap { $0["tool_calls"].array ?? [] }.count
        var name: String?, args: J = .object([:])
        var text = "Native helper fixture reply."
        if messages.last?["content"].string?.hasPrefix("Tool failed:") == true { text = "Native helper fixture stopped after a tool failure." }
        else if names.contains("read_file") {
            if calls < 3 {
                name = ["read_file", "write_file", "check_python"][calls]
                args = .object(["path": .string("sum.py")])
                if calls == 1 { args = changed(args, "content", .string("def add(a, b):\n    return a + b\n")) }
            } else { text = "Native helper fixture updated sum.py and passed validation." }
        } else if names.contains("delegate"), messages.last?["role"].string == "user", let user = messages.last?["content"].string, user.hasPrefix("/task ") {
            name = "delegate"; args = .object(["objective": .string(String(user.dropFirst(6)))])
        } else if messages.last?["role"].string == "tool" { text = "Your task is accepted and awaits approval. I am available for another message." }
        var message: J = .object(["role": .string("assistant"), "content": .string(text)])
        if let name {
            let call: J = .object(["id": .string(UUID().uuidString.lowercased()), "type": .string("function"), "function": .object(["name": .string(name), "arguments": .string(String(decoding: try args.data(), as: UTF8.self))])])
            message = .object(["role": .string("assistant"), "content": .null, "tool_calls": .array([call])])
        }
        return changed(Self.answer, "choices", .array([.object(["finish_reason": .string(name == nil ? "stop" : "tool_calls"), "message": message])]))
    }
    func send(path: String, body: Data?, credential: String, limit: Int) async throws -> Data {
        if path == "models" { return try Self.catalog.data() }
        if path == "key" { return try J.object(["data": .object(["usage": .number(usage)])]).data() }
        paid += 1
        self.body = body
        do { try await Task.sleep(for: delay) }
        catch { stopped += 1; throw error }
        if scripted, let body { return try Self.script(J.parse(body)).data() }
        return try response ?? Self.answer.data()
    }
}

struct Fixture {
    let root: URL
    let value: J
    let permit: Permit
    let ledger: Ledger
    init(baseline: String = "0", budget: String = "1") throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vera-native-test-" + UUID().uuidString)
        let now = Date().timeIntervalSince1970
        value = .object(["experiment_id": .string(UUID().uuidString.lowercased()), "reconciliation_id": .string(UUID().uuidString.lowercased()), "profile_id": .string(UUID().uuidString), "issued_at": .number(Decimal(now - 1)), "expires_at": .number(Decimal(now + 600)), "prior_test_spend_usd": .string(baseline), "exclusive_test_owner": .bool(true), "budget_scope": .string("vera-tests"), "budget_usd": .string(budget), "max_requests": .number(12), "credential_access": .string("noninteractive-once"), "transport": .string("mock"), "sessions": .array(["foreground", "worker"].map { .object(["id": .string(UUID().uuidString.lowercased()), "task_id": .string(UUID().uuidString.lowercased()), "role": .string($0)]) })])
        permit = try Permit(value)
        ledger = try Ledger(root: root)
        try ledger.bind(permit)
    }
    func request(role: String = "foreground", text: String = "Respond to this disposable test.") -> J {
        let session = permit.sessions.values.first { $0.role == role }!
        return .object(["op": .string("complete"), "mode": .string("assistant"), "request_id": .string(UUID().uuidString.lowercased()), "session_id": .string(session.id), "task_id": .string(session.taskID), "role": .string(role), "messages": .array([.object(["role": .string("user"), "content": .string(text)])])])
    }
    func authorization(_ request: J) throws -> J {
        .object(["request_id": request["request_id"], "input_sha256": .string(try request.digest()), "experiment_id": .string(permit.experiment)])
    }
    func completion(_ value: J) throws -> Completion { try Completion(value, permit: permit, requestPermit: authorization(value)) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

func changed(_ value: J, _ key: String, _ replacement: J) -> J { var fields = value.object!; fields[key] = replacement; return .object(fields) }

final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "openrouter.ai", request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" else { client?.urlProtocol(self, didFailWithError: Failure.unauthorized); return }
        let status = url.path.hasSuffix("models") ? 302 : 200
        let body = Data(repeating: 65, count: url.path.hasSuffix("key") ? 100 : 10)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Location": "https://invalid.example/"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HTTPObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    func start() { lock.lock(); starts += 1; lock.unlock() }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (starts, stops) }
}

final class HangingProtocol: URLProtocol, @unchecked Sendable {
    static let observation = HTTPObservation()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.observation.start()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    override func stopLoading() { Self.observation.stop() }
}

enum Selftest {
    static func expect(_ failure: Failure? = nil, _ operation: () throws -> Void) throws {
        do { try operation() } catch {
            if let failure { try ensure((error as? Failure) == failure) }
            return
        }
        throw Failure.invalidRequest
    }
    static func expectAsync(_ failure: Failure? = nil, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch {
            if let failure { try ensure((error as? Failure) == failure) }
            return
        }
        throw Failure.invalidRequest
    }
    static func corrupt(_ root: URL, _ sql: String) throws {
        var db: OpaquePointer?
        try ensure(sqlite3_open(root.appendingPathComponent("spend.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try ensure(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
    static func run() async throws {
        var count = 0
        func passed(_ name: String) { count += 1; print("PASS " + name) }
        try expect { _ = try J.parse(Data("{\"a\":1,\"\\u0061\":2}".utf8)) }
        try expect { _ = try J.parse(Data((String(repeating: "[", count: 21) + "0" + String(repeating: "]", count: 21)).utf8)) }
        try expect { _ = try J.parse(Data([34, 255, 34])) }
        passed("strict JSON duplicates depth Unicode")
        let f = try Fixture(); defer { f.cleanup() }
        let r = f.request(), rp = try f.authorization(r)
        for (key, value) in [("host", J.string("https://invalid.example")), ("model", .string("other")), ("role", .string("ambient")), ("session_id", .string(UUID().uuidString.lowercased()))] {
            let invalid = changed(r, key, value)
            try expect { _ = try f.completion(invalid) }
        }
        try expect { _ = try f.completion(f.request(text: String(repeating: "x", count: 8193))) }
        try expect(.unauthorized) { _ = try Completion(r, permit: f.permit, requestPermit: changed(rp, "input_sha256", .string("wrong"))) }
        try expect { _ = try Permit(changed(f.value, "max_requests", .bool(true))) }
        passed("request scopes digest schemas bounds before credentials")
        let key = FixtureCredential(), http = FixtureHTTP()
        let broker = try Broker(permit: f.permit, ledger: f.ledger, credentials: key, http: http)
        try await expectAsync { _ = try await broker.complete(changed(r, "url", .string("invalid")), requestPermit: rp) }
        try ensure(key.count == 0)
        let answer = try await broker.complete(r, requestPermit: rp)
        try ensure(answer["ok"].boolean == true && key.count == 1)
        try await expectAsync(.duplicate) { _ = try await broker.complete(r, requestPermit: rp) }
        try ensure(await http.paid == 1)
        let rows = try f.ledger.snapshot()
        try ensure(rows.count == 1 && rows[0]["status"] == "completed" && rows[0]["charged"] == "28000")
        try ensure(!String(describing: rows).contains(key.sentinel))
        let body = try J.parse(await http.body!)
        try ensure(body["model"].string == modelID && body["provider"]["allow_fallbacks"].boolean == false && body["reasoning"]["enabled"].boolean == false)
        passed("one native credential read bounded provider request duplicate receipt redaction")
        let restartedKey = FixtureCredential()
        let reopened = try Broker(permit: f.permit, ledger: f.ledger, credentials: restartedKey, http: FixtureHTTP())
        let fresh = f.request()
        try await expectAsync(.credentialUnavailable) { _ = try await reopened.complete(fresh, requestPermit: f.authorization(fresh)) }
        try ensure(restartedKey.count == 0)
        passed("durable once-only credential allowance survives broker restart")
        let badResult = J.array([.object(["role": .string("assistant"), "content": .array([.object(["type": .string("toolCall"), "id": .string("call-1"), "name": .string("read_file"), "arguments": .object(["path": .string("sum.py")])])])]), .object(["role": .string("toolResult"), "toolCallId": .string("call-1"), "toolName": .string("delete"), "isError": .string("false"), "content": .string("result")])])
        try expect { _ = try Transcript.convert(badResult, role: "worker") }
        try expect { _ = try Transcript.convert(.array([.object(["role": .string("toolResult"), "toolCallId": .string("missing"), "content": .string("result")])]), role: "worker") }
        passed("tool result pairing and metadata")
        let history: J = .array([badResult.array![0], .object(["role": .string("toolResult"), "toolCallId": .string("call-1"), "toolName": .string("read_file"), "isError": .bool(false), "content": .string("fixture")])])
        let toolRequest = try f.completion(changed(f.request(role: "worker"), "messages", history))
        let function: J = .object(["name": .string("check_python"), "arguments": .string("{\"path\":\"sum.py\"}")])
        let call: J = .object(["id": .string("call-2"), "type": .string("function"), "function": function])
        func toolReply(_ call: J) -> J {
            changed(FixtureHTTP.answer, "choices", .array([.object(["finish_reason": .string("tool_calls"), "message": .object(["role": .string("assistant"), "content": .null, "tool_calls": .array([call])])])]))
        }
        let validToolReply = try Reply(toolReply(call).data(), request: toolRequest)
        try ensure(validToolReply.toolCount == 1 && validToolReply.content[0]["name"].string == "check_python")
        try expect(.providerResponse) { _ = try Reply(toolReply(changed(call, "id", .string("call-1"))).data(), request: toolRequest) }
        passed("typed tool reply roundtrip rejects reused historical call IDs")
        let selected = FixtureHTTP.catalog["data"].array![0]
        try expect { _ = try Pricing(catalog: .object(["data": .array([changed(selected, "reasoning", .object(["mandatory": .bool(true)]))])])) }
        try expect { _ = try Pricing(catalog: .object(["data": .array([changed(selected, "pricing", .object(["prompt": .string("0.1"), "completion": .string("0.1"), "request": .string("0.01")]))])])) }
        passed("mandatory reasoning and unknown billable pricing fail closed")
        let cap = try Fixture(); defer { cap.cleanup() }
        let a = try cap.completion(cap.request()), b = try cap.completion(cap.request(role: "worker"))
        try cap.ledger.reserve(a, permit: cap.permit, amount: 80_000_000, keyUsage: 199_900_000_000)
        try expect(.budget) { try cap.ledger.reserve(b, permit: cap.permit, amount: 80_000_000, keyUsage: 199_900_000_000) }
        passed("stale account usage still counts concurrent foreground reservation")
        let small = try Fixture(budget: "0.01"); defer { small.cleanup() }
        try expect(.budget) { try small.ledger.reserve(small.completion(small.request()), permit: small.permit, amount: 20_000_000, keyUsage: 0) }
        let near = try Fixture(baseline: "199.99"); defer { near.cleanup() }
        try expect(.budget) { try near.ledger.reserve(near.completion(near.request()), permit: near.permit, amount: 20_000_000, keyUsage: 0) }
        passed("experiment and shared total budgets")
        let rounds = try Fixture(); defer { rounds.cleanup() }
        for _ in 0..<4 {
            let rr = try rounds.completion(rounds.request())
            try rounds.ledger.reserve(rr, permit: rounds.permit, amount: 100, keyUsage: 0)
            try rounds.ledger.settle(rr, charged: 1, input: 1, output: 1, tools: 2)
        }
        try expect(.budget) { try rounds.ledger.reserve(rounds.completion(rounds.request()), permit: rounds.permit, amount: 100, keyUsage: 0) }
        passed("four calls eight tools per session")
        let parallel = try Fixture(); defer { parallel.cleanup() }
        let slow = FixtureHTTP(delay: .milliseconds(60)), pr = parallel.request()
        let pb = try Broker(permit: parallel.permit, ledger: parallel.ledger, credentials: FixtureCredential(), http: slow)
        let tasks = (0..<2).map { _ in Task { try? await pb.complete(pr, requestPermit: parallel.authorization(pr)) } }
        var successes = 0
        for task in tasks { if await task.value != nil { successes += 1 } }
        try ensure((await slow.paid) == 1 && successes == 1)
        passed("concurrent duplicates issue exactly one paid request")
        let canceled = try Fixture(); defer { canceled.cleanup() }
        let waiting = FixtureHTTP(delay: .seconds(10)), cr = canceled.request()
        let cb = try Broker(permit: canceled.permit, ledger: canceled.ledger, credentials: FixtureCredential(), http: waiting)
        let task = Task { try await cb.complete(cr, requestPermit: canceled.authorization(cr)) }
        for _ in 0..<200 { if await waiting.paid > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        try ensure(await waiting.paid == 1)
        task.cancel()
        try await expectAsync { _ = try await task.value }
        try ensure(await waiting.stopped == 1)
        try ensure(try canceled.ledger.snapshot()[0]["status"] == "uncertain")
        try expect(.uncertain) { try canceled.ledger.check(canceled.completion(canceled.request(role: "worker"))) }
        passed("cancellation stops transport and retains uncertain spend")
        let timeout = try Fixture(); defer { timeout.cleanup() }
        let th = FixtureHTTP(delay: .seconds(10)), tr = timeout.request()
        let tb = try Broker(permit: timeout.permit, ledger: timeout.ledger, credentials: FixtureCredential(), http: th, timeout: .milliseconds(30))
        try await expectAsync(.deadline) { _ = try await tb.complete(tr, requestPermit: timeout.authorization(tr)) }
        try ensure(await th.stopped == 1)
        passed("whole request deadline cancels inference")
        for bad in [Data("{}".utf8), Data("not-json".utf8), try changed(FixtureHTTP.answer, "usage", .object([:])).data(), try changed(FixtureHTTP.answer, "choices", .array([.object(["finish_reason": .string("stop"), "message": .object(["role": .string("assistant"), "content": .string(key.sentinel)])])])).data()] {
            let broken = try Fixture(); defer { broken.cleanup() }
            let br = broken.request(), bh = FixtureHTTP(response: bad)
            let bb = try Broker(permit: broken.permit, ledger: broken.ledger, credentials: FixtureCredential(), http: bh)
            try await expectAsync { _ = try await bb.complete(br, requestPermit: broken.authorization(br)) }
            try ensure(try broken.ledger.snapshot()[0]["status"] == "uncertain")
        }
        passed("malformed missing cost and echoed secret retain reservation")
        let missing = try Fixture(); defer { missing.cleanup() }
        let mk = FixtureCredential(missing: true), mh = FixtureHTTP()
        let mb = try Broker(permit: missing.permit, ledger: missing.ledger, credentials: mk, http: mh)
        for _ in 0..<2 {
            let mr = missing.request()
            try await expectAsync(.credentialUnavailable) { _ = try await mb.complete(mr, requestPermit: missing.authorization(mr)) }
        }
        try ensure((await mh.paid) == 0 && mk.count == 1)
        passed("missing credential fails once with no retry or inference")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let transport = URLTransport(configuration: config)
        try await expectAsync(.providerResponse) { _ = try await transport.send(path: "models", body: nil, credential: "fixture", limit: 1000) }
        try await expectAsync(.providerResponse) { _ = try await transport.send(path: "key", body: nil, credential: "fixture", limit: 10) }
        try await expectAsync(.unauthorized) { _ = try await transport.send(path: "https://invalid.example", body: nil, credential: "fixture", limit: 10) }
        passed("URLSession fixed origin redirect rejection streaming size cap")
        let hangingConfig = URLSessionConfiguration.ephemeral
        hangingConfig.protocolClasses = [HangingProtocol.self]
        let hangingTransport = URLTransport(configuration: hangingConfig)
        let networkTask = Task { try await hangingTransport.send(path: "chat/completions", body: Data("{}".utf8), credential: "fixture", limit: 1024) }
        for _ in 0..<200 { if HangingProtocol.observation.counts.0 > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        try ensure(HangingProtocol.observation.counts.0 == 1)
        networkTask.cancel()
        try await expectAsync(.canceled) { _ = try await networkTask.value }
        for _ in 0..<200 { if HangingProtocol.observation.counts.1 > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        try ensure(HangingProtocol.observation.counts.1 == 1)
        passed("actual URLSession cancellation reaches protocol stopLoading")
        for sql in ["UPDATE requests SET charged=-100", "UPDATE requests SET status='unknown'", "DELETE FROM sessions"] {
            let corrupt = try Fixture(); defer { corrupt.cleanup() }
            let rr = try corrupt.completion(corrupt.request())
            try corrupt.ledger.reserve(rr, permit: corrupt.permit, amount: 100, keyUsage: 0)
            try Self.corrupt(corrupt.root, sql)
            try expect(.storage) { try corrupt.ledger.check(corrupt.completion(corrupt.request(role: "worker"))) }
        }
        let offset = try Fixture(); defer { offset.cleanup() }
        for role in ["foreground", "worker"] {
            let rr = try offset.completion(offset.request(role: role))
            try offset.ledger.reserve(rr, permit: offset.permit, amount: 100, keyUsage: 0)
            try offset.ledger.settle(rr, charged: 100, input: 1, output: 1, tools: 0)
        }
        try Self.corrupt(offset.root, "UPDATE requests SET charged=-100 WHERE rowid=(SELECT MIN(rowid) FROM requests)")
        try expect(.storage) { try offset.ledger.check(offset.completion(offset.request())) }
        passed("corrupt negative rows unknown states missing sessions and offset sums fail closed")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--lock-test", f.root.path]
        child.standardOutput = Pipe(); child.standardError = Pipe()
        try child.run(); child.waitUntilExit()
        try ensure(child.terminationStatus != 0)
        passed("second process cannot own ledger")
        let unsafe = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vera-native-unsafe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: unsafe) }
        let target = unsafe.appendingPathComponent("target")
        try Data("unmodified".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: unsafe.appendingPathComponent("spend.sqlite"), withDestinationURL: target)
        try expect(.storage) { _ = try Ledger(root: unsafe) }
        try ensure(try Data(contentsOf: target) == Data("unmodified".utf8))
        passed("symlink database denied before modification")
        try await ScopeSelftest.binding()
        passed("late binding rejects invalid input and raced rebinding across restart")
        try ScopeSelftest.focused()
        passed("focused mode rejects delegate in transcript and response")
        try ScopeSelftest.mode()
        passed("mock permits cannot authorize live transport")
        print("PASS native transport selftest \(count) groups; synthetic credentials and fixture HTTP only")
    }
}
