import Foundation

enum NativeMCPTransportSelftest {
    enum Failure: Error { case assertion(String) }

    static func run() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vera-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let portFile = directory.appendingPathComponent("port")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("Tests/MCP/server.py").path, portFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        func connection(_ path: String, timeout: TimeInterval = 2) throws -> NativeMCPSDKConnection {
            try NativeMCPSDKConnection(endpoint: URL(string: "http://127.0.0.1:\(port)/\(path)")!, timeout: timeout, maximumResponseBytes: 8192)
        }
        for endpoint in ["http://example.com/mcp", "https://user:pass@example.com/mcp", "https://example.com/mcp?token=secret"] {
            do {
                _ = try NativeMCPSDKConnection(endpoint: URL(string: endpoint)!)
                throw Failure.assertion("Unsafe endpoint accepted")
            } catch NativeMCPTransportError.invalidEndpoint {}
        }
        let client = try connection("ok")
        try await client.connect()
        let page = try await client.listTools(cursor: nil)
        try require(page.tools.count == 1 && page.nextCursor == "next", "Discovery and pagination")
        if case .object(let schema) = page.tools[0].inputSchema {
            try require(schema["additionalProperties"] == .bool(false), "Complete schema retained")
            try require(schema["required"] == .array([.string("rows")]), "Required retained")
            if case .object(let properties) = schema["properties"], case .object(let rows) = properties["rows"], case .object(let item) = rows["items"], case .object(let nested) = item["properties"], case .object(let number) = nested["n"] {
                try require(number["minimum"] == .number(1), "Numeric schema retained")
            } else { throw Failure.assertion("Nested schema lost") }
        } else { throw Failure.assertion("Schema lost") }
        let next = try await client.listTools(cursor: page.nextCursor)
        try require(next.tools.isEmpty && next.nextCursor == nil, "Final page")
        let result = try await client.call(name: "fixture_read", arguments: ["rows": .array([])])
        if case .object(let object) = result {
            try require(object["structuredContent"] == .object(["count": .number(1), "ok": .bool(true)]), "Structured result retained")
        } else { throw Failure.assertion("Result lost") }
        let toolError = try await client.call(name: "error", arguments: [:])
        if case .object(let object) = toolError {
            try require(object["isError"] == .bool(true), "Tool error retained")
        }
        await client.disconnect()
        do { _ = try await client.listTools(cursor: nil); throw Failure.assertion("Disconnected call") }
        catch NativeMCPTransportError.disconnected {}
        try await client.connect()
        _ = try await client.listTools(cursor: nil)
        await client.disconnect()
        for (path, expected) in [("auth", NativeMCPTransportError.authenticationRequired), ("redirect", .redirectDenied), ("version", .unsupportedProtocol), ("large", .responseTooLarge), ("chunked", .responseTooLarge), ("malformed", .malformedResponse), ("shape", .malformedResponse), ("slow", .timeout), ("remote-error", .remoteFailure), ("disconnect", .network), ("duplicate", .malformedResponse), ("duplicate-sse", .malformedResponse), ("canonical", .malformedResponse), ("numeric", .malformedResponse), ("decimal", .malformedResponse), ("invalid-utf8", .malformedResponse)] {
            let candidate = try connection(path, timeout: 0.5)
            do {
                try await candidate.connect()
                throw Failure.assertion("Failure accepted: \(path)")
            } catch let error as NativeMCPTransportError {
                try require(error == expected, "Wrong failure for \(path): \(error)")
            }
            await candidate.disconnect()
        }
        try require(!FileManager.default.fileExists(atPath: portFile.path + ".redirected"), "Redirect followed")
        let dataSchema = try connection("data-schema")
        try await dataSchema.connect()
        do { _ = try await dataSchema.listTools(cursor: nil); throw Failure.assertion("Data URL schema was silently rewritten") }
        catch NativeMCPTransportError.malformedResponse {}
        await dataSchema.disconnect()
        let dataResult = try connection("data-result")
        try await dataResult.connect()
        do { _ = try await dataResult.call(name: "fixture_read", arguments: [:]); throw Failure.assertion("Data URL result was silently rewritten") }
        catch NativeMCPTransportError.malformedResponse {}
        await dataResult.disconnect()
        let sse = try connection("sse")
        try await sse.connect()
        _ = try await sse.listTools(cursor: nil)
        await sse.disconnect()
        let cancellable = try connection("ok")
        try await cancellable.connect()
        let start = ContinuousClock.now
        let pending = Task { try await cancellable.call(name: "slow", arguments: [:]) }
        try await Task.sleep(for: .milliseconds(50))
        do { _ = try await cancellable.listTools(cursor: nil); throw Failure.assertion("Concurrent call accepted") }
        catch NativeMCPTransportError.busy {}
        pending.cancel()
        do { _ = try await pending.value; throw Failure.assertion("Cancellation ignored") }
        catch is CancellationError {}
        try require(start.duration(to: .now) < .seconds(1), "Cancellation did not promptly finish")
        await cancellable.disconnect()
        try await NativeMCPAuthorizationSelftest.run(port: port, counterFile: URL(fileURLWithPath: portFile.path + ".counts.json"))
        print("MCP TRANSPORT SELFTEST OK")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }
}
