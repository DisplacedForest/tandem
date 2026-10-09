import Combine
import Foundation

public struct AssistantSessionMessage: Identifiable, Sendable {
    public let id: String
    public let isUser: Bool
    public let text: String
    public let taskIDs: [String]
}

public struct AssistantSessionTask: Identifiable, Sendable {
    public let id: String
    public let originatingMessageID: UUID?
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
    public var markdown: String? = nil
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
    public var savedEventCursor: Int64 { store.saved.taskEventCursor ?? 0 }
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
    public var canCreateDocument: Bool { selected && store.canSend }
    public var canSend: Bool {
        selected && store.canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count <= 8000
    }
    private var selected: Bool { store.destination == .assistant }
    public var messages: [AssistantSessionMessage] {
        (store.transcripts[id] ?? []).filter { ["user", "assistant"].contains($0.role) }.map {
            AssistantSessionMessage(id: $0.id, isUser: $0.role == "user", text: $0.text, taskIDs: $0.taskIDs)
        }
    }
    public var tasks: [AssistantSessionTask] {
        store.tasks.filter { $0.payload.assistantID == store.saved.assistantID && $0.payload.conversationID == id }.map { task in
            AssistantSessionTask(id: task.id, originatingMessageID: task.payload.originatingMessageID,
                title: task.title, state: task.state, status: task.status,
                summary: task.milestone, canStop: task.canStop && connected,
                decisionID: task.state == "needs_decision" && !task.cancelRequested ? task.decision?.id : nil,
                decisionPrompt: task.decision?.prompt, savedApproval: store.savedReply(task),
                busy: store.busyTasks.contains(task.id), error: store.taskErrors[task.id],
                outputs: outputs(task))
        }
    }
    private func outputs(_ task: TaskSnapshot) -> [AssistantSessionOutput] {
        if task.workerType == "document" {
            guard task.state == "completed", task.result?.kind == "document_report",
                  let title = task.result?.title, title == task.payload.title,
                  let markdown = task.result?.markdown, !markdown.isEmpty, markdown.utf8.count <= 100000 else { return [] }
            return [AssistantSessionOutput(id: 0, title: title, markdown: markdown)]
        }
        return (task.result?.artifacts ?? []).enumerated().compactMap { index, artifact in
            artifact.resolved(in: store.configuration.workspaceRoot) == nil ? nil : AssistantSessionOutput(id: index, title: artifact.title)
        }
    }
    public func createDocument(title: String, brief: String, inputs: String) async {
        guard canCreateDocument else { return }
        await store.createDocument(title: title, brief: brief, inputs: inputs)
    }
    public func select() { store.destination = .assistant }
    public func setDraft(_ text: String) { guard selected else { return }; store.setDraft(text) }
    public func refresh() async { guard selected else { return }; await store.refresh() }
    public func poll() async { guard selected, !store.taskEventsHealthy else { return }; await store.refresh(background: true) }
    public func startEventTracking() { store.startEventTracking() }
    public func stopEventTracking() async { await store.stopEventTracking() }
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
        guard let task = scopedTask(taskID), let artifacts = task.result?.artifacts, artifacts.indices.contains(index) else { return nil }
        guard task.workerType == "document" else { return artifacts[index].resolved(in: store.configuration.workspaceRoot) }
        guard index == 0, task.state == "completed", let root = store.configuration.workspaceRoot,
              let markdown = outputs(task).first?.markdown,
              let url = artifacts[index].resolved(in: root) else { return nil }
        let expected = root.appendingPathComponent(task.id).appendingPathComponent("document.md")
        guard url == expected, expected.standardizedFileURL == expected.resolvingSymlinksInPath(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: expected.path),
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              (attributes[.size] as? NSNumber)?.intValue == markdown.utf8.count,
              let data = try? Data(contentsOf: expected), data == Data(markdown.utf8) else { return nil }
        return url
    }
    private func scopedTask(_ id: String) -> TaskSnapshot? {
        store.tasks.first { $0.id == id && $0.payload.assistantID == store.saved.assistantID && $0.payload.conversationID == self.id }
    }
}
