import Foundation
import Darwin
import GRDB

actor PiCountingFixture: PiMockModelExecutor {
    var calls = 0
    let invalid: Bool
    init(invalid: Bool = false) { self.invalid = invalid }
    func complete(_ request: PiModelRequest) async throws -> PiValue {
        calls += 1
        if invalid { return .object(["credential": .string("fixture-only")]) }
        return try await PiFixtureModel().complete(request)
    }
}

struct PiUncooperativeFixture: PiMockModelExecutor {
    func complete(_ request: PiModelRequest) async throws -> PiValue {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { continuation.resume() }
        }
        return .null
    }
}

actor PiHeldValidationFixture: PiMockModelExecutor {
    var waiting = false
    var calls = 0
    private var held = false
    private let checksCancellation: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(checksCancellation: Bool = true) { self.checksCancellation = checksCancellation }
    func validateRequest(_ request: PiModelRequest) async throws {
        if calls == 1 && !held {
            held = true; waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        if checksCancellation { try Task.checkCancellation() }
    }
    func release() { continuation?.resume(); continuation = nil }
    func complete(_ request: PiModelRequest) async throws -> PiValue {
        calls += 1
        return try await PiFixtureModel().complete(request)
    }
}

enum NativePiModelBrokerFixture {
    static func check(_ condition: Bool, file: StaticString = #fileID, line: UInt = #line) throws {
        guard condition else {
            print("FAIL: broker fixture assertion \(file):\(line)")
            throw PiBrokerError.invalid
        }
    }
    static func stage(_ name: String, _ operation: () async throws -> Void) async throws {
        let start = ContinuousClock.now
        do {
            try await operation()
            print("PASS: broker fixture \(name) (\(start.duration(to: .now)))")
        } catch {
            let category = (error as? PiBrokerError)?.rawValue ?? String(describing: type(of: error))
            print("FAIL: broker fixture \(name): \(category) (\(start.duration(to: .now)))")
            throw error
        }
    }
    static func binding(role: String = "foreground", mode: String = "assistant") -> PiValue {
        .object(["subject": .string(UUID().uuidString.lowercased()), "assistant": .string(UUID().uuidString.lowercased()), "conversation": .string(UUID().uuidString.lowercased()), "role": .string(role), "mode": .string(mode)])
    }
    static func request(_ scope: PiModelScope, channel: String, id: String = UUID().uuidString.lowercased(), text: String = "fixture") -> PiValue {
        .object(["op": .string("complete"), "id": .string(id), "channel": .string(channel), "profile": .string(scope.profile), "scope": .string(scope.id), "subject": .string(scope.subject), "role": .string(scope.role), "mode": .string(scope.mode), "assistant": .string(scope.assistant), "conversation": .string(scope.conversation), "messages": .array([.object(["role": .string("user"), "content": .string(text)])])])
    }
    static func changed(_ value: PiValue, _ key: String, _ replacement: PiValue) -> PiValue {
        var object = value.piObject!; object[key] = replacement; return .object(object)
    }
    static func rejected(_ expected: PiBrokerError? = nil, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch {
            let unwrapped = (error as? PiNoSpendRejection)?.error ?? error
            guard let category = unwrapped as? PiBrokerError else { throw PiBrokerError.invalid }
            if let expected, category != expected { print("Rejected category mismatch: expected \(expected.rawValue), received \(category.rawValue)") }
            try check(expected == nil || category == expected); return
        }
        throw PiBrokerError.invalid
    }
    static func exercise(_ root: URL) async throws {
        let ledger = try PiModelLedger(root: root.appendingPathComponent("main"), manifest: "fixture")
        let counter = PiCountingFixture()
        let broker = NativePiModelBroker(ledger: ledger, channel: "fixture-channel", executor: counter)
        let binding = binding()
        let scope = try await broker.authorize(binding)
        let value = request(scope, channel: "fixture-channel")
        for (role, mode) in [("foreground", "focused"), ("worker", "assistant"), ("document", "assistant")] {
            let denied = try await broker.authorize(self.binding(role: role, mode: mode))
            var handoff = request(denied, channel: "fixture-channel").piObject!
            handoff.removeValue(forKey: "messages")
            handoff["op"] = .string("document_handoff")
            handoff["task_id"] = .string(UUID().uuidString.lowercased())
            let frame = PiValue.object(handoff)
            try await rejected(.unauthorized) { try await broker.validateDocumentHandoff(frame) }
            try await rejected(.unauthorized) { try PiModelRequest.arguments(.object(["title": .string("Draft")]), name: "create_document", scope: denied) }
        }
        try check(try ledger.snapshot().piArray!.isEmpty)
        for key in ["channel", "profile", "scope", "subject", "role", "mode", "assistant", "conversation"] {
            try await rejected(.unauthorized) { _ = try await broker.complete(changed(value, key, .string("wrong"))) }
        }
        try await rejected(.invalid) { _ = try await broker.complete(changed(value, "endpoint", .string("https://invalid.example"))) }
        try await rejected(.duplicate) { _ = try await broker.authorize(binding) }
        let first = try await broker.complete(value)
        let repeated = try await broker.complete(value)
        let firstCount = await counter.calls
        try check(first == repeated && firstCount == 1)
        try await rejected(.duplicate) { _ = try await broker.complete(changed(value, "messages", .array([.object(["role": .string("user"), "content": .string("changed")])]))) }
        let focused = try await broker.authorize(self.binding(mode: "focused"))
        let reply = try await broker.complete(request(focused, channel: "fixture-channel", text: "/task not delegated"))
        try check(reply.pi("content").piArray?.first?.pi("type").piString == "text")
        try await rejected(.unauthorized) { try PiModelRequest.arguments(.object(["objective": .string("work")]), name: "delegate", scope: focused) }
        let worker = try await broker.authorize(self.binding(role: "worker"))
        try await rejected(.unauthorized) { try PiModelRequest.arguments(.object(["path": .string("../outside")]), name: "read_file", scope: worker) }
        let workerRequest = request(worker, channel: "fixture-channel")
        let running = Task { try await broker.complete(workerRequest) }
        try await Task.sleep(for: .milliseconds(50))
        try await rejected(.unavailable) { _ = try await broker.complete(request(worker, channel: "fixture-channel")) }
        let start = ContinuousClock.now
        _ = try await broker.complete(request(scope, channel: "fixture-channel"))
        try check(start.duration(to: .now) < .milliseconds(450))
        await broker.cancel(workerRequest.pi("id").piString!)
        do { _ = try await running.value; throw PiBrokerError.invalid } catch is CancellationError {}
        let rows = try ledger.snapshot().piArray!
        try check(rows.count == 4 && rows.filter { $0.pi("status").piString == "uncertain" }.count == 1)
        try await rejected(.uncertain) { _ = try await broker.complete(request(scope, channel: "fixture-channel")) }
        await broker.close()
        try await rejected(.unauthorized) { _ = try await broker.complete(value) }
        let expired = NativePiModelBroker(ledger: ledger, channel: "expired", expires: .distantPast)
        try await rejected(.unauthorized) { _ = try await expired.authorize(self.binding()) }
        let badLedger = try PiModelLedger(root: root.appendingPathComponent("invalid"), manifest: "fixture")
        let badBroker = NativePiModelBroker(ledger: badLedger, channel: "bad", executor: PiCountingFixture(invalid: true))
        let badScope = try await badBroker.authorize(self.binding())
        try await rejected(.invalid) { _ = try await badBroker.complete(request(badScope, channel: "bad")) }
        try check(try badLedger.snapshot().piArray!.first!.pi("status").piString == "uncertain")
        let smallLedger = try PiModelLedger(root: root.appendingPathComponent("budget"), manifest: "fixture", budget: 1_000_000)
        let small = NativePiModelBroker(ledger: smallLedger, channel: "small")
        let smallScope = try await small.authorize(self.binding())
        _ = try await small.complete(request(smallScope, channel: "small"))
        try await rejected(.budget) { _ = try await small.complete(request(smallScope, channel: "small")) }
        do { _ = try PiValue.piRead(Data("{\"op\":1,\"op\":2}".utf8)); throw PiBrokerError.invalid }
        catch is NativeTaskHTTPError {}
    }
    static func restart(_ root: URL) async throws {
        let bound = binding()
        let id = UUID().uuidString.lowercased()
        var result: PiValue = .null
        var profile = ""
        weak var previousOwner: PiExperimentRoot?
        do {
            let ledger = try PiModelLedger(root: root, manifest: "fixture")
            previousOwner = ledger.owner
            profile = ledger.profile
            let broker = NativePiModelBroker(ledger: ledger, channel: "before")
            let scope = try await broker.authorize(bound)
            result = try await broker.complete(request(scope, channel: "before", id: id))
            await broker.close()
            try withExtendedLifetime(ledger) {
                var refused = false
                do { _ = try PiModelLedger(root: root, manifest: "fixture") }
                catch PiBrokerError.storage { refused = true }
                try check(refused)
            }
        }
        try check(previousOwner == nil)
        let ledger = try PiModelLedger(root: root, manifest: "fixture")
        try check(ledger.profile == profile)
        let counter = PiCountingFixture()
        let broker = NativePiModelBroker(ledger: ledger, channel: "after", executor: counter)
        let scope = try await broker.authorize(bound)
        let replay = try await broker.complete(request(scope, channel: "after", id: id))
        let replayCount = await counter.calls
        try check(replay == result && replayCount == 0)
        try check(try ledger.snapshot().piArray!.count == 1)
        let changedBroker = NativePiModelBroker(ledger: ledger, channel: "changed")
        try await rejected(.unauthorized) { _ = try await changedBroker.authorize(changed(bound, "conversation", .string(UUID().uuidString.lowercased()))) }
    }
    static func boundaries(_ root: URL) async throws {
        let ledger = try PiModelLedger(root: root, manifest: "fixture")
        let counter = PiCountingFixture()
        let broker = NativePiModelBroker(ledger: ledger, channel: "test", executor: counter)
        let scope = try await broker.authorize(binding())
        let value = request(scope, channel: "test")
        await broker.cancel(value.pi("id").piString!)
        try await rejected(.canceled) { _ = try await broker.complete(value) }
        try check(try ledger.snapshot().piArray!.isEmpty)
        let clean = request(scope, channel: "test")
        _ = try await broker.complete(clean)
        try await ledger.database.write { db in try db.execute(sql: "UPDATE requests SET charged=-1") }
        try await rejected(.storage) { _ = try await broker.complete(clean) }
        try await ledger.database.write { db in try db.execute(sql: "UPDATE requests SET charged=28000,reply=?", arguments: [Data("{}".utf8)]) }
        try await rejected(.invalid) { _ = try await broker.complete(clean) }
        let calls = await counter.calls
        try check(calls == 1)
        let slowLedger = try PiModelLedger(root: root.appendingPathComponent("slow"), manifest: "fixture")
        let slow = NativePiModelBroker(ledger: slowLedger, channel: "slow", executor: PiUncooperativeFixture(), timeout: .milliseconds(50))
        let slowScope = try await slow.authorize(binding())
        let start = ContinuousClock.now
        try await rejected(.unavailable) { _ = try await slow.complete(request(slowScope, channel: "slow")) }
        try check(start.duration(to: .now) < .milliseconds(300))
        try await rejected(.uncertain) { _ = try await slow.complete(request(slowScope, channel: "slow")) }
        let lockedLedger = try PiModelLedger(root: root.appendingPathComponent("locked"), manifest: "fixture")
        let locked = NativePiModelBroker(ledger: lockedLedger, channel: "locked")
        let worker = try await locked.authorize(binding(role: "worker"))
        let lockedRequest = request(worker, channel: "locked")
        let running = Task { try await locked.complete(lockedRequest) }
        try await Task.sleep(for: .milliseconds(50))
        var blockerConfiguration = Configuration()
        blockerConfiguration.allowsUnsafeTransactions = true
        let blocker = try DatabaseQueue(path: lockedLedger.owner.url.appendingPathComponent("broker.sqlite").path, configuration: blockerConfiguration)
        try await blocker.writeWithoutTransaction { db in try db.execute(sql: "BEGIN IMMEDIATE") }
        await locked.cancel(lockedRequest.pi("id").piString!)
        do { _ = try await running.value; throw PiBrokerError.invalid } catch is CancellationError {}
        try await rejected(.uncertain) { _ = try await locked.complete(request(worker, channel: "locked")) }
        try await blocker.writeWithoutTransaction { db in try db.execute(sql: "ROLLBACK") }
        try check(try lockedLedger.snapshot().piArray!.first!.pi("status").piString == "reserved")
        let callID = UUID().uuidString.lowercased()
        let block: PiValue = .object(["type": .string("toolCall"), "id": .string(callID), "name": .string("read_file"), "arguments": .object(["path": .string("sum.py")])])
        let history: PiValue = .array([.object(["role": .string("user"), "content": .string("fixture")]), .object(["role": .string("assistant"), "content": .array([block])]), .object(["role": .string("toolResult"), "toolCallId": .string(callID), "toolName": .string("read_file"), "content": .array([.object(["type": .string("text"), "text": .string("fixture")])])])])
        let parsed = try PiModelRequest(changed(request(worker, channel: "locked"), "messages", history), scope: worker, channel: "locked")
        let repeated: PiValue = .object(["content": .array([block]), "usage": .object(["input": .number(20), "output": .number(4), "cost_usd": .number(0.000028)])])
        try await rejected(.invalid) { try PiModelReply.validate(repeated, request: parsed) }
    }
    static func rearming(_ root: URL) async throws {
        let scope = try PiModelScope(binding(), profile: UUID().uuidString.lowercased())
        func parsed(_ ledgerRoot: URL, id: String) throws -> PiModelRequest {
            try PiModelRequest(request(scope, channel: "rearm", id: id), scope: scope, channel: "rearm")
        }
        let uncertainLedger = try PiModelLedger(root: root.appendingPathComponent("uncertain"), manifest: "fixture")
        let first = try parsed(root, id: UUID().uuidString.lowercased())
        let second = try parsed(root, id: UUID().uuidString.lowercased())
        try piCheck(try uncertainLedger.reserve(first) == nil)
        uncertainLedger.reject(first.id)
        try piCheck(try uncertainLedger.reserve(second) == nil)
        uncertainLedger.uncertain(second.id)
        try await rejected(.uncertain) { _ = try uncertainLedger.reserve(first) }
        try piCheck(try uncertainLedger.snapshot().piArray!.map { $0.pi("status").piString! } == ["rejected", "uncertain"])
        let budgetLedger = try PiModelLedger(root: root.appendingPathComponent("budget"), manifest: "fixture", budget: 1_000_000)
        let third = try parsed(root, id: UUID().uuidString.lowercased())
        let fourth = try parsed(root, id: UUID().uuidString.lowercased())
        try piCheck(try budgetLedger.reserve(third) == nil)
        budgetLedger.reject(third.id)
        try piCheck(try budgetLedger.reserve(fourth) == nil)
        let spent: PiValue = .object(["content": .array([.object(["type": .string("text"), "text": .string("fixture")])]), "usage": .object(["input": .number(20), "output": .number(4), "cost_usd": .number(0.001)])])
        try budgetLedger.settle(fourth.id, reply: spent)
        try await rejected(.budget) { _ = try budgetLedger.reserve(third) }
        try piCheck(try budgetLedger.snapshot().piArray!.map { $0.pi("status").piString! } == ["rejected", "completed"])
        let documentLedger = try PiModelLedger(root: root.appendingPathComponent("document"), manifest: "fixture", budget: 10_000_000, requestLimit: 13)
        let fifth = try parsed(root, id: UUID().uuidString.lowercased())
        let sixth = try parsed(root, id: UUID().uuidString.lowercased())
        try piCheck(try documentLedger.reserve(fifth) == nil)
        documentLedger.reject(fifth.id)
        try piCheck(try documentLedger.reserve(sixth) == nil)
        let partial: PiValue = .object(["content": .array([.object(["type": .string("text"), "text": .string("fixture")])]), "usage": .object(["input": .number(20), "output": .number(4), "cost_usd": .number(0.006)])])
        try documentLedger.settle(sixth.id, reply: partial)
        try await rejected(.budget) { _ = try documentLedger.reserve(fifth) }
        try piCheck(try documentLedger.snapshot().piArray!.map { $0.pi("status").piString! } == ["rejected", "completed"])
        let unsentLedger = try PiModelLedger(root: root.appendingPathComponent("unsent"), manifest: "fixture")
        let seventh = try parsed(root, id: UUID().uuidString.lowercased())
        let eighth = try parsed(root, id: UUID().uuidString.lowercased())
        try piCheck(try unsentLedger.reserve(seventh) == nil)
        unsentLedger.reject(seventh.id)
        try piCheck(try unsentLedger.reserve(eighth) == nil)
        try unsentLedger.notSent(eighth.id)
        try piCheck(try unsentLedger.reserve(seventh) == nil)
        try piCheck(try unsentLedger.snapshot().piArray!.map { $0.pi("status").piString! } == ["reserved", "not_sent"])
    }
    static func cancellationDuringValidation(_ root: URL) async throws {
        for (name, checksCancellation) in [("throwing", true), ("silent", false)] {
            let ledger = try PiModelLedger(root: root.appendingPathComponent(name), manifest: "fixture")
            let held = PiHeldValidationFixture(checksCancellation: checksCancellation)
            let broker = NativePiModelBroker(ledger: ledger, channel: "held", executor: held, timeout: .seconds(10))
            let scope = try await broker.authorize(binding())
            let value = request(scope, channel: "held")
            let running = Task { try await broker.complete(value) }
            for _ in 0..<400 where !(await held.waiting) { try await Task.sleep(for: .milliseconds(5)) }
            let calls = await held.calls
            try piCheck(await held.waiting && calls == 1)
            running.cancel()
            await held.release()
            do { _ = try await running.value; throw PiBrokerError.invalid } catch is CancellationError {}
            try piCheck(try ledger.snapshot().piArray!.map { $0.pi("status").piString! } == ["uncertain"])
            try await rejected(.uncertain) { _ = try await broker.complete(request(scope, channel: "held")) }
        }
    }
    static func run() async {
        umask(0o077)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("pi-app-selftest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await NativePiTaskEventSelftest.run()
            try await stage("pipe lifecycle") { try await NativePiPipeFixture.exercise() }
            try await stage("runtime tools") { try await NativePiRuntimeToolFixture.exercise(root.appendingPathComponent("runtime-tools")) }
            try await stage("runtime tool restart") { try await NativePiRuntimeToolFixture.restart(root.appendingPathComponent("runtime-tools-restart")) }
            try await stage("tool revisions") { try await NativePiToolRevisionFixture.exercise(root.appendingPathComponent("tool-revisions")) }
            try await stage("model execution") { try await exercise(root) }
            try await stage("model boundaries") { try await boundaries(root.appendingPathComponent("boundaries")) }
            try await stage("model restart") { try await restart(root.appendingPathComponent("restart")) }
            try await stage("re-arm guard") { try await rearming(root.appendingPathComponent("rearming")) }
            try await stage("late cancellation") { try await cancellationDuringValidation(root.appendingPathComponent("cancellation")) }
            print("PASS: app-owned mock scope, accounting, duplicate, cancellation, responsiveness, restart, re-arm guard and late cancellation tests")
        } catch { print("FAIL: app-owned mock broker selftest \(type(of: error))"); exit(1) }
    }
}
