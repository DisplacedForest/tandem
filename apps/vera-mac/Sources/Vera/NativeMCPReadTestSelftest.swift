import Foundation

private actor NativeMCPReadTestConnection: NativeMCPConnection {
    let schema: NativeJSONValue
    var calls = 0
    var held = false
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    var result: NativeJSONValue = .object(["content": .array([.object(["type": .string("text"), "text": .string("<b>Plain text</b>\n[not a rendered link](https://example.invalid)")])])])
    init(schema: NativeJSONValue) { self.schema = schema }
    func connect() async throws {}
    func disconnect() async {}
    func listTools(cursor: String?) async throws -> NativeMCPPage {
        .init(tools: [.init(name: "fixture_read", description: "Untrusted text must not become an input default", inputSchema: schema), .init(name: "unapproved", description: "Not granted", inputSchema: schema)], nextCursor: nil)
    }
    func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue {
        calls += 1
        entered = true
        if held { await withCheckedContinuation { continuation = $0 } }
        return result
    }
    func hold() { held = true }
    func release() { continuation?.resume(); continuation = nil; held = false }
}

enum NativeMCPReadTestSelftest {
    static let schema: NativeJSONValue = .object(["type": .string("object"), "properties": .object(["url": .object(["type": .string("string"), "const": .string("https://example.invalid/page"), "maxLength": .number(2048)])]), "required": .array([.string("url")]), "additionalProperties": .bool(false)])

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NativeToolError.failed(message) }
    }

    @MainActor
    static func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw NativeToolError.failed("Read verification fixture timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private static func fixture(schema: NativeJSONValue = schema, scopes: Set<String> = ["focused", "assistant"], enabled: Bool = true) async throws -> (NativeMCPManager, NativeMCPReadTestConnection, NativeMCPToolRecord) {
        let server = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Synthetic service", endpoint: URL(string: "https://fixture.invalid/mcp")!, readTools: ["fixture_read"], scopes: scopes)
        let connection = NativeMCPReadTestConnection(schema: schema)
        let manager = NativeMCPManager(servers: [server], enabled: enabled ? [server.toolID("fixture_read")] : [], factory: { _ in connection })
        await manager.connect(server.id)
        guard let record = manager.servers.first?.tools.first else { throw NativeToolError.unavailable }
        return (manager, connection, record)
    }

    @MainActor
    static func run() async throws {
        let (manager, connection, record) = try await fixture()
        guard let controller = NativeMCPReadTestController(manager: manager, record: record) else { throw NativeToolError.unavailable }
        try require(controller.input.isEmpty && controller.usesPageURL && !controller.canRun, "Read test must begin empty without service instructions")
        controller.updateInput("http://example.invalid/page")
        controller.run()
        try require(controller.error != nil && !controller.running, "Full schema validation must reject invalid arguments")
        try require(await connection.calls == 0, "Invalid arguments must never reach the connection")
        controller.updateInput("https://example.invalid/page")
        controller.run()
        try await wait { !controller.running }
        try require(controller.result?.source == record.server.endpoint.absoluteString && controller.result?.text.hasPrefix("<b>Plain text</b>") == true, "Result must retain exact source and literal text")
        try require(await connection.calls == 1, "One explicit read must invoke the shared authority once")
        controller.updateInput("https://example.invalid/another")
        try require(controller.result == nil, "Editing arguments must clear the previous result")
        controller.updateInput(String(repeating: "x", count: 2049))
        try require(!controller.canRun && controller.error != nil, "Oversized input must not run a previously accepted draft")
        controller.close()
        try require(controller.input.isEmpty && controller.result == nil && !controller.canRun, "Close must clear transient read state")
        let unapproved = manager.servers[0].tools.first { $0.remoteName == "unapproved" }!
        try require(NativeMCPReadTestController(manager: manager, record: unapproved) == nil, "Unapproved tools must not gain test authority")
        manager.setEnabled([])
        try require(NativeMCPReadTestController(manager: manager, record: record) == nil, "Disabled tools must not run")
        await manager.disconnect(record.server.id)
        try require(NativeMCPReadTestController(manager: manager, record: record) == nil, "Disconnected tools must not run")
        let (worker, _, workerRecord) = try await fixture(scopes: ["worker"])
        try require(NativeMCPReadTestController(manager: worker, record: workerRecord) == nil, "Test read must never use worker authority")
        await worker.disconnect(workerRecord.server.id)
        let (assistant, _, assistantRecord) = try await fixture(scopes: ["assistant"])
        let assistantController = NativeMCPReadTestController(manager: assistant, record: assistantRecord)
        try require(assistantController?.scope == "assistant", "Assistant-only explicit read access must retain its existing scope")
        assistantController?.close()
        await assistant.disconnect(assistantRecord.server.id)
        try await complexArguments()
        for event in ["disable", "toggle", "disconnect", "reconnect", "replace", "close", "edit"] { try await lateResponse(event: event) }
        try await revokeAuthorization()
        do {
            _ = try NativeMCPReadTestController.render(.object(["source": .string("https://other.invalid"), "content": .string("wrong")]), source: "https://fixture.invalid/mcp")
            throw NativeToolError.failed("Wrong provenance was accepted")
        } catch NativeToolError.unavailable {}
        print("PASS MCP read controller: existing scoped authority, full arguments, literal output, lifecycle fences")
        try await sdkFixture()
    }

    @MainActor
    private static func complexArguments() async throws {
        let schema: NativeJSONValue = .object(["type": .string("object"), "properties": .object(["rows": .object(["type": .string("array"), "items": .object(["type": .string("integer"), "minimum": .number(1)])])]), "required": .array([.string("rows")]), "additionalProperties": .bool(false)])
        let (manager, connection, record) = try await fixture(schema: schema)
        guard let controller = NativeMCPReadTestController(manager: manager, record: record) else { throw NativeToolError.unavailable }
        try require(!controller.usesPageURL && controller.input.isEmpty, "Complex arguments require an empty JSON editor")
        for text in ["[]", "{\"rows\":[true]}", "{\"rows\":[0]}", "{\"rows\":[1],\"extra\":true}", "{\"rows\":[1],\"rows\":[2]}", "{\"rows\":[9007199254740993]}", "{\"rows\":[0.10000000000000001]}"] {
            controller.updateInput(text)
            controller.run()
            try require(controller.error != nil && !controller.running, "Invalid complex arguments must remain local")
        }
        try require(await connection.calls == 0, "Invalid complex arguments must cause zero connection calls")
        controller.updateInput("{\"rows\":[1]}")
        controller.run()
        try await wait { !controller.running }
        try require(controller.result != nil && controller.error == nil, "JSON numeric arguments must preserve their type")
        controller.close()
        await manager.disconnect(record.server.id)
    }

    @MainActor
    private static func lateResponse(event: String) async throws {
        let (manager, connection, record) = try await fixture()
        guard let controller = NativeMCPReadTestController(manager: manager, record: record) else { throw NativeToolError.unavailable }
        await connection.hold()
        controller.updateInput("https://example.invalid/page")
        controller.run()
        try await wait { await connection.entered }
        switch event {
        case "disable": manager.setEnabled([])
        case "toggle": manager.setEnabled([]); manager.setEnabled([record.id])
        case "disconnect": await manager.disconnect(record.server.id)
        case "reconnect": await manager.disconnect(record.server.id); await manager.connect(record.server.id)
        case "replace": await manager.replaceConfiguration([record.server])
        case "close": controller.close()
        default: controller.updateInput("https://example.invalid/changed")
        }
        try require(controller.result == nil, "Changed authority or input must immediately hide results")
        await connection.release()
        try await wait { !controller.running }
        for _ in 0..<3 { await Task.yield() }
        try require(controller.result == nil, "Late completion must not publish after close, edit, or authority change")
        if ["disable", "toggle", "disconnect", "reconnect", "replace"].contains(event) {
            try await wait { controller.invalidated }
        }
        if event == "reconnect" { try require(manager.authority.access.snapshot().first?.connected == true, "Old completion must not disconnect a new connection") }
        controller.close()
        await manager.disconnect(record.server.id)
    }

    @MainActor
    private static func revokeAuthorization() async throws {
        let server = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Synthetic authorization", endpoint: URL(string: "https://fixture.invalid/mcp")!, readTools: ["fixture_read"], authentication: .bearer)
        let connection = NativeMCPReadTestConnection(schema: schema)
        let manager = NativeMCPManager(servers: [server], enabled: [server.toolID("fixture_read")], authenticatedFactory: { _, _ in connection })
        let lease = try NativeMCPAuthorization(serverID: server.id, endpoint: server.endpoint, token: "synthetic-read-test-lease", expiresAt: Date().addingTimeInterval(60))
        await manager.authority.connect(server.id, authorization: lease)
        manager.refresh()
        guard let record = manager.servers.first?.tools.first, let controller = NativeMCPReadTestController(manager: manager, record: record) else { throw NativeToolError.unavailable }
        await connection.hold()
        controller.updateInput("https://example.invalid/page")
        controller.run()
        try await wait { await connection.entered }
        lease.revoke()
        try require(!controller.current && controller.result == nil, "Revocation must immediately fence read publication")
        await connection.release()
        try await wait { controller.invalidated }
        try require(controller.result == nil, "Revoked read completion must remain hidden")
        controller.close()
        await manager.disconnect(server.id)
    }

    private static func stopFixture(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let limit = Date().addingTimeInterval(1)
            while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }

    @MainActor
    private static func sdkFixture() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vera-mcp-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let portFile = directory.appendingPathComponent("port")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("Tests/MCPRead/server.py").path, portFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            stopFixture(process)
            try? FileManager.default.removeItem(at: directory)
        }
        try await wait { FileManager.default.fileExists(atPath: portFile.path) }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        func calls(_ path: String) -> Int {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: portFile.path + ".counts.json")), let counts = try? JSONDecoder().decode([String: Int].self, from: data) else { return 0 }
            return counts["/" + path + "|tools/call"] ?? 0
        }
        for path in ["ok", "large", "wire-large", "slow", "held"] {
            let server = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Synthetic SDK service", endpoint: URL(string: "http://127.0.0.1:\(port)/\(path)")!, readTools: ["fixture_read"], timeout: path == "slow" ? 2 : 5, allowLoopbackFixture: true)
            let manager = NativeMCPManager(servers: [server], enabled: [server.toolID("fixture_read")])
            await manager.connect(server.id)
            guard let record = manager.servers.first?.tools.first, let controller = NativeMCPReadTestController(manager: manager, record: record) else { throw NativeToolError.failed("SDK read fixture did not connect") }
            controller.updateInput("http://example.invalid/rejected")
            controller.run()
            try require(calls(path) == 0 && controller.error != nil, "Schema rejection must make zero SDK tool requests")
            controller.updateInput("https://example.invalid/page")
            let started = ContinuousClock.now
            controller.run()
            if path == "held" {
                try await wait { calls(path) == 1 }
                manager.setEnabled([])
                try require(controller.result == nil, "SDK disable must fence results immediately")
            }
            try await wait { !controller.running }
            try require(calls(path) == 1, "Each explicit SDK test must make exactly one tool request")
            if path == "ok" {
                try require(controller.result?.text.hasPrefix("<b>Plain synthetic response</b>") == true && controller.result?.source == server.endpoint.absoluteString, "SDK read must preserve plain content and exact source")
            } else {
                try require(controller.result == nil, "Oversize, timeout, and disabled SDK reads must not publish")
            }
            if path == "slow" { try require(started.duration(to: .now) < .seconds(6), "SDK read deadline must remain bounded") }
            controller.close()
            await manager.disconnect(server.id)
        }
        let server = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Synthetic cancellation", endpoint: URL(string: "http://127.0.0.1:\(port)/held")!, readTools: ["fixture_read"], allowLoopbackFixture: true)
        let manager = NativeMCPManager(servers: [server], enabled: [server.toolID("fixture_read")])
        await manager.connect(server.id)
        let record = manager.servers[0].tools[0]
        guard let controller = NativeMCPReadTestController(manager: manager, record: record) else { throw NativeToolError.unavailable }
        controller.updateInput("https://example.invalid/page")
        controller.run()
        try await wait { calls("held") == 2 }
        controller.close()
        try require(controller.result == nil && !controller.running, "SDK close must immediately clear the sheet")
        await manager.disconnect(server.id)
        print("PASS actual SDK read fixture: invalid arguments zero calls, exact source, disable, cancel, deadline,4KiB and network bounds")
    }
}
