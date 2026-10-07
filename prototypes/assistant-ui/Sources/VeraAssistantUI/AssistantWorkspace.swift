import Foundation
import SwiftUI

@MainActor
public final class AssistantWorkspace {
    let store: PrototypeStore

    public init(dataRoot: URL, endpoint: URL, workspaceRoot: URL, runtimeIdentity: String,
                send: @escaping @Sendable (URLRequest) async throws -> (Data, Int)) throws {
        let configuration = try PrototypeConfiguration(dataRoot: dataRoot, endpoint: endpoint,
                                                       workspaceRoot: workspaceRoot, runtimeIdentity: runtimeIdentity)
        store = try PrototypeStore(configuration: configuration, client: PrototypeClient(base: endpoint, send: send))
    }

    public var assistantID: UUID { store.saved.assistantID }

    public func verifyRecovery(requireFreshReply: Bool = true) async throws -> Data {
        try await BridgeContractTest.recovery(store: store, requireFreshReply: requireFreshReply)
    }

    public func verifyWorkflow() async throws -> Data {
        try await BridgeContractTest.workflow(store: store, requireActiveWorker: true)
    }
}

@MainActor
public struct AssistantWorkspaceView: View {
    private let workspace: AssistantWorkspace

    public init(workspace: AssistantWorkspace) {
        self.workspace = workspace
    }

    public var body: some View {
        PrototypeView(store: workspace.store)
    }
}
