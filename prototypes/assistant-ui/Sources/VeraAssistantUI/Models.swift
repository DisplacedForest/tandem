import Foundation

enum PrototypeError: Error, LocalizedError {
    case configuration, unavailable, invalidResponse, status(Int), persistence, artifact, replyUnconfirmed

    var errorDescription: String? {
        switch self {
        case .configuration: return "Choose a separate data folder and a loopback prototype address."
        case .unavailable: return "The prototype runtime isn't connected."
        case .replyUnconfirmed: return "Review the reply and tasks before continuing."
        case .invalidResponse: return "The runtime returned an unreadable response."
        case .status(409): return "This request changed or is already running. Refresh and try again."
        case .status: return "The runtime couldn't complete this request."
        case .persistence: return "Your changes couldn't be saved."
        case .artifact: return "This output isn't available in the configured workspace."
        }
    }
}

struct PrototypeConfiguration: Sendable {
    let dataRoot: URL
    let endpoint: URL?
    let workspaceRoot: URL?
    let runtimeIdentity: String?

    init(dataRoot: URL, endpoint: URL?, workspaceRoot: URL?, runtimeIdentity: String? = nil) throws {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        let live = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vera").resolvingSymlinksInPath()
        guard dataRoot.isFileURL, root.path != "/", root.path != live.path,
              !root.path.hasPrefix(live.path + "/"), !live.path.hasPrefix(root.path + "/") else {
            throw PrototypeError.configuration
        }
        if let endpoint {
            guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
                  parts.scheme == "http", ["127.0.0.1", "localhost", "[::1]", "::1"].contains(parts.host),
                  let port = parts.port, port > 0, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else {
                throw PrototypeError.configuration
            }
        }
        if let runtimeIdentity {
            guard !runtimeIdentity.isEmpty, runtimeIdentity.utf8.count <= 256,
                  !runtimeIdentity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw PrototypeError.configuration
            }
        }
        self.runtimeIdentity = runtimeIdentity
        self.dataRoot = root
        self.endpoint = endpoint
        self.workspaceRoot = workspaceRoot?.standardizedFileURL.resolvingSymlinksInPath()
    }
}

struct Capabilities: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let foreground: Bool
    let worker: Bool
    let computers: Bool
    let transport: String
    let transportDetail: String?
    let provider: String?
    let model: String?

    var supported: Bool {
        guard protocolVersion == 1 else { return false }
        switch transport {
        case "mock": return true
        case "cloud":
            return transportDetail == "app-owned-openrouter" && provider == "openrouter" && model == "qwen/qwen3.8-flash"
        default: return false
        }
    }

    var connectionLabel: String {
        guard supported else { return "Not connected" }
        return transport == "mock" ? "Test runtime" : "Cloud model"
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case foreground, worker, computers, transport, provider, model
        case transportDetail = "transport_detail"
    }
}

struct Conversation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var draft: String = ""
}

struct Message: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let role: String
    let text: String
    let taskIDs: [String]
    enum CodingKeys: String, CodingKey { case id, role, text; case taskIDs = "task_ids" }
}

struct MessageRequest: Codable, Sendable {
    let assistantID: UUID
    let conversationID: UUID
    let messageID: UUID
    let text: String
    let mode: String
    enum CodingKeys: String, CodingKey {
        case assistantID = "assistant_id", conversationID = "conversation_id", messageID = "message_id"
        case text, mode
    }
}

struct MessageResponse: Decodable, Sendable {
    let messageID: UUID
    let replyID: String
    let text: String
    let taskIDs: [String]
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id", replyID = "reply_id", taskIDs = "task_ids", text
    }
}

struct TranscriptResponse: Decodable, Sendable { let messages: [Message] }

struct TaskPayload: Decodable, Equatable, Sendable {
    let assistantID: UUID?
    let conversationID: UUID?
    let originatingMessageID: UUID?
    let objective: String?
    enum CodingKeys: String, CodingKey {
        case assistantID = "assistant_id", conversationID = "conversation_id", originatingMessageID = "originating_message_id", objective
    }
}

struct TaskDecision: Decodable, Equatable, Sendable {
    let id: String
    let prompt: String
}

struct TaskArtifact: Decodable, Equatable, Sendable {
    let kind: String
    let path: String
    let title: String

    func resolved(in root: URL?) -> URL? {
        guard kind == "file", let suppliedRoot = root, !path.isEmpty else { return nil }
        let root = suppliedRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard suppliedRoot.standardizedFileURL.path == root.path else { return nil }
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return candidate
    }
}

struct TaskResult: Decodable, Equatable, Sendable {
    let summary: String?
    let artifacts: [TaskArtifact]?
}

struct TaskSnapshot: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let workerType: String
    let payload: TaskPayload
    let state: String
    let result: TaskResult?
    let decision: TaskDecision?
    let cancelRequested: Bool
    let updatedAt: Double
    enum CodingKeys: String, CodingKey {
        case id, payload, state, result, decision
        case workerType = "worker_type", cancelRequested = "cancel_requested", updatedAt = "updated_at"
    }
    var terminal: Bool { ["completed", "failed", "canceled"].contains(state) }
    var canStop: Bool { ["queued", "running", "blocked", "needs_decision"].contains(state) && !cancelRequested }
    var title: String { payload.objective?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? "Untitled task" }
    var status: String {
        if cancelRequested && !terminal { return "Stopping" }
        switch state {
        case "queued": return "Queued"
        case "running": return "Working"
        case "blocked": return "Waiting"
        case "needs_decision": return "Needs your reply"
        case "completed": return "Complete"
        case "failed": return "Failed"
        case "canceled": return "Stopped"
        default: return "Status unavailable"
        }
    }
}

struct TaskPage: Decodable, Sendable { let tasks: [TaskSnapshot] }

struct DecisionRequest: Codable, Sendable {
    let decisionID: String
    let idempotencyKey: UUID
    let reply: Approval
    struct Approval: Codable, Sendable { let approved: Bool }
    enum CodingKeys: String, CodingKey {
        case decisionID = "decision_id", idempotencyKey = "idempotency_key", reply
    }
}

struct SavedState: Codable, Sendable {
    var assistantID = UUID()
    var assistant = Conversation(id: UUID(), title: "Vera")
    var conversations: [Conversation] = []
    var pending: [MessageRequest] = []
    var abandonedReplies: [MessageRequest]?
    var decisions: [String: DecisionRequest] = [:]
    var endpoint: URL?
    var runtimeIdentity: String?
}

extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
