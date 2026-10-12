import Foundation
import SwiftUI

enum Destination: Hashable { case assistant, conversation(UUID) }
enum SidePanel: String, CaseIterable { case activity = "Activity", outputs = "Outputs", computers = "Computers" }

@MainActor
final class PrototypeStore: ObservableObject {
    let configuration: PrototypeConfiguration
    let client: PrototypeClient?
    @Published private(set) var saved: SavedState
    @Published var destination: Destination = .assistant
    @Published var panel: SidePanel = .activity
    @Published private(set) var capabilities: Capabilities?
    @Published private(set) var transcripts: [UUID: [Message]] = [:]
    @Published private(set) var tasks: [TaskSnapshot] = []
    @Published private(set) var busyConversations = Set<UUID>()
    @Published private(set) var busyTasks = Set<String>()
    @Published private(set) var taskErrors: [String: String] = [:]
    @Published private(set) var conversationErrors: [UUID: String] = [:]
    @Published private(set) var connectionError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var reviewingReply = false
    @Published private(set) var reviewedReplyID: UUID?
    private let stateURL: URL
    private var refreshVersion = 0
    private var refreshInFlight = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: PrototypeConfiguration, client: PrototypeClient? = nil) throws {
        self.configuration = configuration
        self.client = client ?? configuration.endpoint.map { PrototypeClient(base: $0) }
        stateURL = configuration.dataRoot.appendingPathComponent("assistant-ui.json")
        try Self.validateStateURL(stateURL)
        let fm = FileManager.default
        if fm.fileExists(atPath: stateURL.path) {
            saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
            guard saved.runtimeIdentity == configuration.runtimeIdentity else { throw PrototypeError.configuration }
            if configuration.runtimeIdentity == nil {
                guard saved.endpoint == configuration.endpoint else { throw PrototypeError.configuration }
            } else if saved.endpoint != configuration.endpoint {
                var candidate = saved
                candidate.endpoint = configuration.endpoint
                try commit(candidate)
            }
        } else {
            if fm.fileExists(atPath: configuration.dataRoot.path) {
                guard try fm.contentsOfDirectory(atPath: configuration.dataRoot.path).isEmpty else { throw PrototypeError.configuration }
            }
            try fm.createDirectory(at: configuration.dataRoot, withIntermediateDirectories: true)
            saved = SavedState(endpoint: configuration.endpoint, runtimeIdentity: configuration.runtimeIdentity)
            try JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
        }
    }

    var conversation: Conversation {
        switch destination {
        case .assistant: return saved.assistant
        case .conversation(let id): return saved.conversations.first { $0.id == id } ?? saved.assistant
        }
    }
    var messages: [Message] { transcripts[conversation.id] ?? [] }
    var pending: MessageRequest? { saved.pending.first { $0.conversationID == conversation.id } }
    var conversationError: String? { conversationErrors[conversation.id] }
    var visibleTasks: [TaskSnapshot] {
        tasks.filter { $0.payload.assistantID == saved.assistantID && $0.payload.conversationID == conversation.id }
    }
    var canAbandonReply: Bool {
        guard let pending else { return false }
        return reviewedReplyID == pending.messageID && !reviewingReply && connectionError == nil
            && !busyConversations.contains(pending.conversationID)
    }
    var pendingTasks: [TaskSnapshot] {
        guard let pending else { return [] }
        let linkedIDs = Set(messages.filter { UUID(uuidString: $0.id) == pending.messageID }.flatMap(\.taskIDs))
        return visibleTasks.filter { $0.payload.originatingMessageID == pending.messageID || linkedIDs.contains($0.id) }
    }
    func accepts(_ text: String) -> Bool { capabilities?.accepts(text) ?? false }
    var canSend: Bool { capabilities?.supported == true && capabilities?.foreground == true && connectionError == nil && !busyConversations.contains(conversation.id) && pending == nil }
    var connectionLabel: String {
        guard let capabilities, connectionError == nil else { return "Not connected" }
        return capabilities.connectionLabel
    }

    private static func validateStateURL(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw PrototypeError.configuration }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let count = attributes[.referenceCount] as? NSNumber, count.intValue > 1 { throw PrototypeError.configuration }
    }

    private func commit(_ candidate: SavedState) throws {
        try Self.validateStateURL(stateURL)
        do { try JSONEncoder().encode(candidate).write(to: stateURL, options: .atomic) }
        catch { throw PrototypeError.persistence }
        saved = candidate
    }

    func newChat() {
        let chat = Conversation(id: UUID(), title: "New chat")
        var candidate = saved
        candidate.conversations.insert(chat, at: 0)
        do { try commit(candidate); destination = .conversation(chat.id) }
        catch { conversationErrors[conversation.id] = error.localizedDescription }
    }

    func setDraft(_ text: String) {
        var candidate = saved
        if conversation.id == saved.assistant.id { candidate.assistant.draft = text }
        else if let index = candidate.conversations.firstIndex(where: { $0.id == conversation.id }) { candidate.conversations[index].draft = text }
        do { try commit(candidate) }
        catch { conversationErrors[conversation.id] = error.localizedDescription }
    }

    func refresh(background: Bool = false) async {
        guard let client, !refreshing, !reviewingReply else { return }
        if background && refreshInFlight { return }
        if !background { refreshing = true }
        defer { if !background { refreshing = false } }
        if !background { await waitForRefresh() }
        guard !Task.isCancelled, !reviewingReply else { return }
        refreshInFlight = true
        defer {
            refreshInFlight = false
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let id = conversation.id
        let version = refreshVersion
        do {
            let caps = try await client.capabilities()
            guard caps.supported else { throw PrototypeError.invalidResponse }
            if capabilities != caps { capabilities = caps }
            async let newTasks = client.tasks()
            async let newMessages = client.messages(id)
            let (receivedTasks, receivedMessages) = try await (newTasks, newMessages)
            if version == refreshVersion {
                let scopedTasks = receivedTasks.filter { $0.workerType == "pi_worker" && $0.payload.assistantID == saved.assistantID }
                if tasks != scopedTasks { tasks = scopedTasks }
                if !busyConversations.contains(id), transcripts[id] != receivedMessages { transcripts[id] = receivedMessages }
            }
            if connectionError != nil { connectionError = nil }
        } catch is CancellationError { }
        catch {
            if connectionError != error.localizedDescription { connectionError = error.localizedDescription }
            if reviewedReplyID != nil { reviewedReplyID = nil }
        }
    }

    private func waitForRefresh() async {
        while refreshInFlight {
            await withCheckedContinuation { refreshWaiters.append($0) }
        }
    }

    func send() async {
        guard canSend else { return }
        let text = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepts(text) else { return }
        let request = MessageRequest(assistantID: saved.assistantID, conversationID: conversation.id,
                                     messageID: UUID(), text: text, mode: destination == .assistant ? "assistant" : "focused")
        var candidate = saved
        candidate.pending.append(request)
        do { try commit(candidate) }
        catch { conversationErrors[request.conversationID] = error.localizedDescription; return }
        await deliver(request)
    }

    func retry() async {
        guard let pending, capabilities?.supported == true, capabilities?.foreground == true,
              !reviewingReply, !busyConversations.contains(pending.conversationID), connectionError == nil else { return }
        await deliver(pending)
    }

    func reviewUnconfirmedReply() async {
        guard let request = pending, let client, !reviewingReply,
              !busyConversations.contains(request.conversationID) else { return }
        reviewingReply = true
        reviewedReplyID = nil
        panel = .activity
        defer { reviewingReply = false }
        await waitForRefresh()
        guard !Task.isCancelled, pending?.messageID == request.messageID,
              !busyConversations.contains(request.conversationID) else { return }
        let version = refreshVersion
        do {
            let caps = try await client.capabilities()
            guard caps.supported else { throw PrototypeError.invalidResponse }
            async let newTasks = client.tasks()
            async let newMessages = client.messages(request.conversationID)
            let (receivedTasks, receivedMessages) = try await (newTasks, newMessages)
            guard pending?.messageID == request.messageID, version == refreshVersion else { return }
            capabilities = caps
            tasks = receivedTasks.filter { $0.workerType == "pi_worker" && $0.payload.assistantID == saved.assistantID }
            transcripts[request.conversationID] = receivedMessages
            connectionError = nil
            reviewedReplyID = request.messageID
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func abandonUnconfirmedReply() {
        guard canAbandonReply, let request = pending else { return }
        var candidate = saved
        candidate.pending.removeAll { $0.messageID == request.messageID }
        var abandoned = candidate.abandonedReplies ?? []
        if !abandoned.contains(where: { $0.messageID == request.messageID }) { abandoned.append(request) }
        candidate.abandonedReplies = abandoned
        if candidate.assistant.id == request.conversationID {
            if candidate.assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines) == request.text { candidate.assistant.draft = "" }
        } else if let index = candidate.conversations.firstIndex(where: { $0.id == request.conversationID }),
                  candidate.conversations[index].draft.trimmingCharacters(in: .whitespacesAndNewlines) == request.text {
            candidate.conversations[index].draft = ""
        }
        do {
            try commit(candidate)
            reviewedReplyID = nil
            conversationErrors[request.conversationID] = nil
            refreshVersion += 1
        } catch { conversationErrors[request.conversationID] = error.localizedDescription }
    }

    private func deliver(_ request: MessageRequest) async {
        guard let client else { return }
        let id = request.conversationID
        busyConversations.insert(id)
        reviewedReplyID = nil
        conversationErrors[id] = nil
        refreshVersion += 1
        defer { busyConversations.remove(id) }
        do {
            let response = try await client.message(request)
            var candidate = saved
            candidate.pending.removeAll { $0.messageID == request.messageID }
            if candidate.assistant.id == id {
                if candidate.assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines) == request.text { candidate.assistant.draft = "" }
            } else if let index = candidate.conversations.firstIndex(where: { $0.id == id }) {
                if candidate.conversations[index].draft.trimmingCharacters(in: .whitespacesAndNewlines) == request.text { candidate.conversations[index].draft = "" }
                if candidate.conversations[index].title == "New chat" { candidate.conversations[index].title = String(request.text.prefix(64)) }
            }
            try commit(candidate)
            var messages = transcripts[id] ?? []
            messages.removeAll { $0.id.caseInsensitiveCompare(request.messageID.uuidString) == .orderedSame || $0.id == response.replyID }
            messages.append(Message(id: request.messageID.uuidString, role: "user", text: request.text, taskIDs: []))
            messages.append(Message(id: response.replyID, role: "assistant", text: response.text, taskIDs: response.taskIDs))
            transcripts[id] = messages
            refreshVersion += 1
        } catch {
            if case PrototypeError.status(let status) = error, [400, 413, 415, 422].contains(status) {
                var candidate = saved
                candidate.pending.removeAll { $0.messageID == request.messageID }
                do { try commit(candidate) }
                catch { conversationErrors[id] = error.localizedDescription; return }
            }
            switch error {
            case PrototypeError.unavailable, PrototypeError.status(409):
                conversationErrors[id] = PrototypeError.replyUnconfirmed.localizedDescription
            default:
                conversationErrors[id] = error.localizedDescription
            }
        }
    }

    func stop(_ task: TaskSnapshot) async {
        guard task.canStop, !busyTasks.contains(task.id), let client, connectionError == nil else { return }
        busyTasks.insert(task.id)
        taskErrors[task.id] = nil
        defer { busyTasks.remove(task.id) }
        do { try apply(try await client.cancel(task.id), replacing: task) }
        catch { taskErrors[task.id] = error.localizedDescription }
    }

    func reply(_ task: TaskSnapshot, approved: Bool) async {
        guard task.state == "needs_decision", let decision = task.decision, !task.cancelRequested,
              !busyTasks.contains(task.id), let client, connectionError == nil else { return }
        busyTasks.insert(task.id)
        taskErrors[task.id] = nil
        defer { busyTasks.remove(task.id) }
        do {
            let key = task.id + ":" + decision.id
            let body = saved.decisions[key] ?? DecisionRequest(decisionID: decision.id, idempotencyKey: UUID(), reply: .init(approved: approved))
            guard body.reply.approved == approved else { throw PrototypeError.status(409) }
            var candidate = saved
            candidate.decisions[key] = body
            try commit(candidate)
            try apply(try await client.decision(task.id, body: body), replacing: task)
        } catch { taskErrors[task.id] = error.localizedDescription }
    }

    func savedReply(_ task: TaskSnapshot) -> Bool? {
        guard let decision = task.decision else { return nil }
        return saved.decisions[task.id + ":" + decision.id]?.reply.approved
    }

    private func apply(_ incoming: TaskSnapshot, replacing previous: TaskSnapshot) throws {
        guard incoming.payload.assistantID == previous.payload.assistantID,
              incoming.payload.conversationID == previous.payload.conversationID,
              incoming.workerType == previous.workerType else { throw PrototypeError.invalidResponse }
        refreshVersion += 1
        if let index = tasks.firstIndex(where: { $0.id == incoming.id }), incoming.updatedAt >= tasks[index].updatedAt {
            tasks[index] = incoming
        }
    }
}
