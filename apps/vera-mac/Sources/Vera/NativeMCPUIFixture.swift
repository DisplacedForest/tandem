import Foundation

@MainActor
final class NativeMCPUIFixture {
    static private(set) var current: NativeMCPUIFixture?
    let manager: NativeMCPManager
    let model: PiToolModelFixture
    let chat: NativeMCPChatFixture
    private init(endpoint: URL) throws {
        let server = try NativeMCPServerConfiguration(id: "b3a0c29f-142b-4fb0-a12f-1393fc83239f", name: "Synthetic test service", endpoint: endpoint,
            readTools: ["fixture_read"], scopes: ["focused", "assistant", "worker"], authentication: endpoint.path == "/bearer" ? .bearer : .none, allowLoopbackFixture: true)
        let name = server.toolID("fixture_read")
        manager = NativeMCPManager(servers: [server])
        model = PiToolModelFixture(toolName: name, toolArguments: .object(["rows": .array([.object(["n": .number(1)])])]))
        chat = NativeMCPChatFixture(name: name, arguments: "{\"rows\":[{\"n\":1}]}")
    }
    static func prepareIfRequested() throws -> NativeMCPUIFixture? {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["VERA_MCP_UI_FIXTURE"] else { return nil }
        guard CommandLine.arguments.dropFirst().first == "--pi-candidate-mock", let endpoint = URL(string: address),
              endpoint.scheme == "http", endpoint.host == "127.0.0.1", ["/ok", "/bearer"].contains(endpoint.path) else { throw PiBrokerError.invalid }
        let fixture = try NativeMCPUIFixture(endpoint: endpoint)
        current = fixture
        return fixture
    }
}
