import Combine
import Foundation

public struct AssistantSessionMessage: Identifiable, Sendable {
    public let id: String
    public let isUser: Bool
    public let text: String
}

public struct AssistantSessionTask: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let state: String
    public let status: String
    public let summary: String
    public let canStop: Bool
    public let decisionID: String?
    public let decisionPrompt: String?
    public let savedApproval: Bool?
    public let busy: Bool
    public let error: String?
    public let outputs: [AssistantSessionOutput]
}

public struct AssistantSessionOutput: Identifiable, Sendable {
    public let id: Int
    public let title: String
}

@MainActor
public final class AssistantSession: ObservableObject {
    private let store: PrototypeStore
    private var changes: AnyCancellable?

    init(store: PrototypeStore) {
        self.store = store
        changes = store.objectWillChange.sink { [weak self] in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    public var id: UUID { store.saved.assistant.id }
    public var draft: String { store.saved.assistant.draft }
    public var connected: Bool { store.capabilities?.supported == true && store.connectionError == nil }
    public var connectionLabel: String { store.connectionLabel }
    public var busy: Bool { store.busyConversations.contains(id) }
    public var error: String? { store.conversationErrors[id] ?? store.connectionError }
    public var archivedReplyIDs: Set<UUID> { Set((store.saved.abandonedReplies ?? []).filter { $0.conversationID == id }.map(\.messageID)) }
    public var pendingID: UUID? { store.saved.pending.first { $0.conversationID == id }?.messageID }
    public var pendingText: String? { store.saved.pending.first { $0.conversationID == id }?.text }
    public var canContinue: Bool { selected && store.canAbandonReply }
    public var reviewing: Bool { store.reviewingReply }
    public var canRetry: Bool { selected && pendingID != nil && connected && !busy && !reviewing && store.capabilities?.foreground == true }
    public var canSend: Bool {
        selected && store.canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count <= 8000
    }
    private var selected: Bool { store.destination == .assistant }
    public var messages: [AssistantSessionMessage] {
        (store.transcripts[id] ?? []).filter { ["user", "assistant"].contains($0.role) }.map {
            AssistantSessionMessage(id: $0.id, isUser: $0.role == "user", text: $0.text)
        }
    }
    public var tasks: [AssistantSessionTask] {
        store.tasks.filter { $0.payload.assistantID == store.saved.assistantID && $0.payload.conversationID == id }.map { task in
            AssistantSessionTask(id: task.id, title: task.title, state: task.state, status: task.status,
                summary: task.result?.summary ?? "", canStop: task.canStop && connected,
                decisionID: task.state == "needs_decision" && !task.cancelRequested ? task.decision?.id : nil,
                decisionPrompt: task.decision?.prompt, savedApproval: store.savedReply(task),
                busy: store.busyTasks.contains(task.id), error: store.taskErrors[task.id],
                outputs: (task.result?.artifacts ?? []).enumerated().compactMap { index, artifact in
                    artifact.resolved(in: store.configuration.workspaceRoot) == nil ? nil : AssistantSessionOutput(id: index, title: artifact.title)
                })
        }
    }
    public func select() { store.destination = .assistant }
    public func setDraft(_ text: String) { guard selected else { return }; store.setDraft(text) }
    public func refresh() async { guard selected else { return }; await store.refresh() }
    public func send() async { guard canSend else { return }; await store.send() }
    public func retry(messageID: UUID) async { guard canRetry, pendingID == messageID else { return }; await store.retry() }
    public func review(messageID: UUID) async { guard selected, pendingID == messageID else { return }; await store.reviewUnconfirmedReply() }
    public func continueWithoutReply(messageID: UUID) { guard canContinue, pendingID == messageID else { return }; store.abandonUnconfirmedReply() }
    public func stop(taskID: String) async {
        guard let task = scopedTask(taskID) else { return }
        await store.stop(task)
    }
    public func reply(taskID: String, decisionID: String, approved: Bool) async {
        guard let task = scopedTask(taskID), task.decision?.id == decisionID else { return }
        await store.reply(task, approved: approved)
    }
    public func output(taskID: String, index: Int) -> URL? {
        guard let artifacts = scopedTask(taskID)?.result?.artifacts, artifacts.indices.contains(index) else { return nil }
        return artifacts[index].resolved(in: store.configuration.workspaceRoot)
    }
    private func scopedTask(_ id: String) -> TaskSnapshot? {
        store.tasks.first { $0.id == id && $0.payload.assistantID == store.saved.assistantID && $0.payload.conversationID == self.id }
    }
}
