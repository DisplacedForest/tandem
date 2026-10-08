import Foundation
import VeraAssistantUI

@MainActor
final class NativePiPreparedSession {
    let provider: PiPreparedProvider
    let owner: NativePiAppOwner
    let workspace: AssistantWorkspace
    let memoryBridge: NativeRuntimeMemoryBridge?
    private init(provider: PiPreparedProvider, owner: NativePiAppOwner, workspace: AssistantWorkspace, memoryBridge: NativeRuntimeMemoryBridge?) {
        self.provider = provider; self.owner = owner; self.workspace = workspace; self.memoryBridge = memoryBridge
    }
    static func create(arguments: [String], uiRoot: URL, provider: PiPreparedProvider, store: ChatStore? = nil) async throws -> NativePiPreparedSession {
        try await provider.executor.validateOwner()
        let memoryBridge = store.map { NativeRuntimeMemoryBridge(store: $0) }
        let executor = memoryBridge.map { provider.executor.sharingMemory($0) } ?? provider.executor
        let owner = try NativePiAppOwner(arguments: arguments, executor: executor, ownerBinding: provider.binding.digest, transport: provider.transport, memoryBridge: memoryBridge)
        do {
            let ready = try await owner.start()
            guard case .number(let port) = ready.pi("port"), let identity = ready.pi("profile").piString else { throw PiBrokerError.invalid }
            let root = owner.session.ledger.owner.url
            let workspace = try AssistantWorkspace(dataRoot: uiRoot, endpoint: URL(string: "http://127.0.0.1:\(Int(port))")!, workspaceRoot: root.appendingPathComponent("runtime/workspaces"), runtimeIdentity: piHash(Data((root.path + ":" + identity).utf8))) { request in try await owner.http(request) }
            try await owner.bindAssistant(workspace.assistantID)
            return NativePiPreparedSession(provider: provider, owner: owner, workspace: workspace, memoryBridge: memoryBridge)
        } catch { await owner.stop(); throw error }
    }
}
