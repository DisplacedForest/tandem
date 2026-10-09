import Foundation

actor NativeMCPCountedTools: NativeRuntimeToolServing {
    let authority: NativeMCPAuthority
    private var calls = 0
    init(_ authority: NativeMCPAuthority) { self.authority = authority }
    func revision(scope: PiModelScope) async throws -> String { try await authority.revision(scope: scope) }
    func catalog(scope: PiModelScope) async throws -> [NativeToolSchema] { try await authority.catalog(scope: scope) }
    func call(scope: PiModelScope, id: String, name: String, arguments: NativeJSONValue, expectedRevision: String) async throws -> NativeJSONValue {
        let result = try await authority.call(scope: scope, id: id, name: name, arguments: arguments, expectedRevision: expectedRevision)
        calls += 1
        return result
    }
    func cancel(scope: PiModelScope) async { await authority.cancel(scope: scope) }
    func count() -> Int { calls }
}

@MainActor
enum NativeMCPIntegrationFixture {
    static func run(_ arguments: [String]) async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-shared-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("port")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [source.appendingPathComponent("Tests/MCP/server.py").path, file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit(); try? FileManager.default.removeItem(at: root) }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: file.path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let port = try String(contentsOf: file, encoding: .utf8)
        let configuration = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Synthetic MCP service", endpoint: URL(string: "http://127.0.0.1:\(port)/ok")!, readTools: ["fixture_read"], scopes: ["focused", "assistant", "worker"], allowLoopbackFixture: true)
        let name = configuration.toolID("fixture_read")
        let manager = NativeMCPManager(servers: [configuration], enabled: [name])
        await manager.connect(configuration.id)
        try NativeMCPAuthoritySelftest.check(manager.servers[0].connected, "Shared SDK connection failed")
        let transport = NativeMCPChatFixture(name: name, arguments: "{\"rows\":[{\"n\":1}]}")
        let repository = try LocalChatRepository(inMemory: true)
        let config = NativeChatConfig(baseURL: URL(string: "https://fixture.invalid/v1")!, apiKey: nil, model: "fixture", chatTemplateKwargs: nil)
        let store = ChatStore(nativeConfig: config, nativeTransport: transport, repository: repository, nativeEnabledToolIDs: [name], nativeMCP: manager, artifactPersistenceEnabled: false)
        store.newConversation(); store.sendText("Read the synthetic reference")
        try await NativeSessionFixture.eventually("SDK focused chat did not complete") { !store.generating && store.conversations.flatMap(\.messages).flatMap(\.toolActivities).contains { $0.toolID == name && $0.state == .succeeded } }
        let counted = NativeMCPCountedTools(manager.authority)
        do {
            try await NativePiRuntimeToolFixture.contract(arguments, tools: counted,
                model: PiToolModelFixture(toolName: name, toolArguments: .object(["rows": .array([.object(["n": .number(1)])])])), callCount: { await counted.count() })
            try NativeMCPAuthoritySelftest.check(await counted.count() == 3, "Shared SDK Pi calls missing")
            await manager.disconnect(configuration.id)
        } catch { await manager.disconnect(configuration.id); throw error }
        try await errorContract(arguments, endpoint: URL(string: "http://127.0.0.1:\(port)/tool-error")!)
        print("NATIVE MCP SHARED SDK HTTP AND PI CONTRACT OK")
    }
    static func errorContract(_ arguments: [String], endpoint: URL) async throws {
        let configuration = try NativeMCPServerConfiguration(id: UUID().uuidString, name: "Synthetic error service", endpoint: endpoint, readTools: ["fixture_read"], allowLoopbackFixture: true)
        let name = configuration.toolID("fixture_read")
        let manager = NativeMCPManager(servers: [configuration], enabled: [name])
        await manager.connect(configuration.id)
        var arguments = arguments
        guard let index = arguments.firstIndex(of: "--root") else { throw PiBrokerError.invalid }
        arguments[index + 1] += "/error-contract"
        let owner = try NativePiAppOwner(arguments: arguments, executor: NativeMCPErrorModel(name: name), ownerBinding: "mcp-error-fixture", tools: manager.authority)
        do {
            _ = try await owner.start()
            let assistant = UUID()
            try await owner.bindAssistant(assistant)
            let endpoint = try await owner.endpoint()
            var request = URLRequest(url: endpoint.appendingPathComponent("assistant/messages"))
            request.httpMethod = "POST"
            request.httpBody = try PiValue.object(["assistant_id": .string(assistant.uuidString.lowercased()), "conversation_id": .string(UUID().uuidString.lowercased()), "message_id": .string(UUID().uuidString.lowercased()), "mode": .string("focused"), "text": .string("Read the error fixture")]).piData()
            let (data, status) = try await owner.http(request)
            try piCheck(status == 200 && (try PiValue.piRead(data)).pi("text") == .string("Service error observed"))
            await owner.stop(); await manager.disconnect(configuration.id)
        } catch { await owner.stop(); await manager.disconnect(configuration.id); throw error }
    }

}

struct NativeMCPErrorModel: PiMockModelExecutor {
    let name: String
    func complete(_ request: PiModelRequest) async throws -> PiValue {
        let content: PiValue
        if request.toolCount == 0 {
            content = .object(["type": .string("toolCall"), "id": .string(UUID().uuidString.lowercased()), "name": .string(name), "arguments": .object(["rows": .array([.object(["n": .number(1)])])])])
        } else {
            try piCheck(request.messages.last?.pi("isError") == .bool(true))
            content = .object(["type": .string("text"), "text": .string("Service error observed")])
        }
        return .object(["content": .array([content]), "usage": .object(["input": .number(20), "output": .number(4), "cost_usd": .number(0)])])
    }
}
