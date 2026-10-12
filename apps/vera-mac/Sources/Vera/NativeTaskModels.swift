import Foundation
import CryptoKit

enum NativeTaskError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case invalidEngine
    case engineChanged
    case invalidResponse
    case persistenceUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return message
        case .invalidEngine: return "Configure a valid research engine address first."
        case .engineChanged: return "This research request belongs to a different engine."
        case .invalidResponse: return "The research engine returned an unreadable response."
        case .persistenceUnavailable: return "The research request couldn't be saved locally."
        }
    }
}

struct NativeTaskEngineIdentity: Codable, Equatable, Hashable, Sendable {
    let base: URL

    init(_ url: URL) throws {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil else { throw NativeTaskError.invalidEngine }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) {
            parts.port = nil
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let normalized = parts.url else { throw NativeTaskError.invalidEngine }
        base = normalized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(URL.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base)
    }
}

struct NativeResearchTaskRequest: Codable, Equatable, Hashable, Sendable {
    let objective: String
    let deliverables: [String]

    init(objective: String, deliverables: [String]) throws {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 5000 else {
            throw NativeTaskError.invalidRequest("The research objective must contain 1 to 5,000 characters.")
        }
        guard (1...5).contains(deliverables.count) else {
            throw NativeTaskError.invalidRequest("Provide 1 to 5 research deliverables.")
        }
        let items = deliverables.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard items.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= 500 }) else {
            throw NativeTaskError.invalidRequest("Each deliverable must contain 1 to 500 characters.")
        }
        self.objective = trimmed
        self.deliverables = items
    }

    private enum CodingKeys: String, CodingKey { case objective, deliverables }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(objective: container.decode(String.self, forKey: .objective),
                      deliverables: container.decode([String].self, forKey: .deliverables))
    }
}

struct NativeTaskResearchOptions: Sendable {
    let subquestions: Int
    let pagesPerQuestion: Int
    static let standard = NativeTaskResearchOptions(subquestions: 4, pagesPerQuestion: 2)
}

struct NativeResearchTaskPayload: Codable, Equatable, Hashable, Sendable {
    let query: String
    let deliverables: [String]
    let useRAG: Bool
    let subquestions: Int
    let pagesPerQuestion: Int
    let nativeBinding: NativeTaskAdmissionBinding?

    init(request: NativeResearchTaskRequest, nativeBinding: NativeTaskAdmissionBinding? = nil,
         options: NativeTaskResearchOptions = .standard) {
        query = request.objective
        deliverables = request.deliverables
        useRAG = false
        subquestions = options.subquestions
        pagesPerQuestion = options.pagesPerQuestion
        self.nativeBinding = nativeBinding
    }

    private enum CodingKeys: String, CodingKey {
        case query, deliverables, subquestions
        case pagesPerQuestion = "pages_per_q"
        case useRAG = "use_rag"
        case nativeBinding = "native_binding"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decode(String.self, forKey: .query)
        deliverables = try container.decodeIfPresent([String].self, forKey: .deliverables) ?? []
        useRAG = try container.decodeIfPresent(Bool.self, forKey: .useRAG) ?? true
        subquestions = try container.decodeIfPresent(Int.self, forKey: .subquestions) ?? 4
        pagesPerQuestion = try container.decodeIfPresent(Int.self, forKey: .pagesPerQuestion) ?? 2
        nativeBinding = try container.decodeIfPresent(NativeTaskAdmissionBinding.self, forKey: .nativeBinding)
    }
}

struct NativeTaskCreateRequest: Codable, Equatable, Hashable, Sendable {
    let workerType: String
    let payload: NativeResearchTaskPayload
    let idempotencyKey: String

    init(request: NativeResearchTaskRequest, idempotencyKey: UUID,
         nativeBinding: NativeTaskAdmissionBinding? = nil, options: NativeTaskResearchOptions = .standard) {
        workerType = "research"
        payload = NativeResearchTaskPayload(request: request, nativeBinding: nativeBinding, options: options)
        self.idempotencyKey = idempotencyKey.uuidString
    }

    private enum CodingKeys: String, CodingKey {
        case payload
        case workerType = "worker_type"
        case idempotencyKey = "idempotency_key"
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

struct NativeTaskAdmissionBinding: Codable, Equatable, Hashable, Sendable {
    let id: String
    let admissionBase: URL
    let enrollmentDigest: String

    private enum CodingKeys: String, CodingKey {
        case id
        case admissionBase = "admission_base"
        case enrollmentDigest = "enrollment_digest"
    }
}

struct NativeTaskGenerationLimits: Codable, Equatable, Hashable, Sendable {
    let maximumRequests: Int
    let maximumInputBytes: Int
    let maximumOutputTokens: Int

    init(maximumRequests: Int = 4, maximumInputBytes: Int = 65536,
         maximumOutputTokens: Int = 1024) throws {
        guard (1...16).contains(maximumRequests), (1...262144).contains(maximumInputBytes),
              (1...8192).contains(maximumOutputTokens) else {
            throw NativeTaskError.invalidRequest("Background generation limits must be finite and bounded.")
        }
        self.maximumRequests = maximumRequests
        self.maximumInputBytes = maximumInputBytes
        self.maximumOutputTokens = maximumOutputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case maximumRequests, maximumInputBytes, maximumOutputTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maximumRequests: container.decode(Int.self, forKey: .maximumRequests),
                      maximumInputBytes: container.decode(Int.self, forKey: .maximumInputBytes),
                      maximumOutputTokens: container.decode(Int.self, forKey: .maximumOutputTokens))
    }

}

struct NativeTaskProfileBinding: Codable, Equatable, Hashable, Sendable {
    let id: String
    let profileID: String
    let provider: NativeTaskEngineIdentity
    let savedModel: String
    let executionModel: String
    let limits: NativeTaskGenerationLimits
    let requiresCredential: Bool

    init(id: String, profileID: String, provider: NativeTaskEngineIdentity, savedModel: String,
         executionModel: String, limits: NativeTaskGenerationLimits, requiresCredential: Bool = false) {
        self.id = id
        self.profileID = profileID
        self.provider = provider
        self.savedModel = savedModel
        self.executionModel = executionModel
        self.limits = limits
        self.requiresCredential = requiresCredential
    }
}

struct NativeTaskOrigin: Codable, Equatable, Hashable, Sendable {
    let conversationID: String
    let userMessageID: UUID
    let assistantMessageID: UUID
}

enum NativeTaskDeliveryState: String, Codable, Equatable, Hashable, Sendable {
    case pending, accepted, rejected
}

struct NativeTaskReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let origin: NativeTaskOrigin
    let engine: NativeTaskEngineIdentity
    let request: NativeResearchTaskRequest
    let createRequest: NativeTaskCreateRequest
    let body: Data
    let profile: NativeTaskProfileBinding?
    var remoteTaskID: String?
    var deliveryState: NativeTaskDeliveryState
    var cancelRequested: Bool
    var cancelDelivered: Bool
    var lastDeliveryError: String?
    var snapshot: NativeTaskSnapshot?
}

enum NativeTaskState: String, Codable, Equatable, Hashable, Sendable {
    case queued, running, blocked, completed, failed, canceled
    case needsDecision = "needs_decision"

    var isTerminal: Bool { [.completed, .failed, .canceled].contains(self) }
}

struct NativeTaskSource: Codable, Equatable, Hashable, Sendable {
    let n: Int
    let title: String
    let url: String
}

struct NativeTaskDecision: Codable, Equatable, Hashable, Sendable {
    let id: String
    let prompt: String
    let choices: [String]
}

struct NativeTaskCheckpoint: Codable, Equatable, Hashable, Sendable {
    let phase: String?
    let nextQuery: Int
    let sources: [NativeTaskSource]
    let nativeUnavailable: String?
    let failureReason: String?

    private enum CodingKeys: String, CodingKey {
        case phase, sources
        case nativeUnavailable = "native_unavailable"
        case failureReason = "failure_reason"
        case nextQuery = "next_query"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        nextQuery = try container.decodeIfPresent(Int.self, forKey: .nextQuery) ?? 0
        sources = try container.decodeIfPresent([NativeTaskSource].self, forKey: .sources) ?? []
        nativeUnavailable = try container.decodeIfPresent(String.self, forKey: .nativeUnavailable)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
    }
}

struct NativeResearchTaskResult: Codable, Equatable, Hashable, Sendable {
    let kind: String
    let query: String
    let report: String
    let sources: [NativeTaskSource]
}

struct NativeTaskSnapshot: Codable, Equatable, Hashable, Sendable {
    let id: String
    let workerType: String
    let payload: NativeResearchTaskPayload
    let state: NativeTaskState
    let checkpoint: NativeTaskCheckpoint
    let result: NativeResearchTaskResult?
    let decision: NativeTaskDecision?
    let cancelRequested: Bool
    let generation: Int
    let updatedAt: Double

    private enum CodingKeys: String, CodingKey {
        case id, payload, state, checkpoint, result, decision, generation
        case workerType = "worker_type"
        case cancelRequested = "cancel_requested"
        case updatedAt = "updated_at"
    }
}

func nativeTaskDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func nativeTaskEncoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
