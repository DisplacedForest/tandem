import Foundation

struct NativeTaskGenerationMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
}

struct NativeTaskGenerationJob: Codable, Equatable, Sendable {
    let id: String
    let taskID: String
    let bindingID: String
    let enrollmentDigest: String
    let admissionBase: URL
    let phase: String
    let attempt: String
    let messages: [NativeTaskGenerationMessage]
    let messagesDigest: String
    let deadlineSeconds: Double
    let generation: Int

    func reducingDeadline(by seconds: Double) throws -> NativeTaskGenerationJob {
        guard deadlineSeconds > seconds else { throw NativeTaskGenerationFailure(code: "request_timeout") }
        return NativeTaskGenerationJob(id: id, taskID: taskID, bindingID: bindingID,
            enrollmentDigest: enrollmentDigest, admissionBase: admissionBase, phase: phase,
            attempt: attempt, messages: messages, messagesDigest: messagesDigest,
            deadlineSeconds: deadlineSeconds - seconds, generation: generation)
    }

    var key: String { "\(taskID):\(phase):\(attempt)" }

    private enum CodingKeys: String, CodingKey {
        case id, phase, attempt, messages, generation
        case taskID = "task_id"
        case bindingID = "binding_id"
        case enrollmentDigest = "enrollment_digest"
        case admissionBase = "admission_base"
        case messagesDigest = "messages_digest"
        case deadlineSeconds = "deadline_seconds"
    }

    static func decode(_ data: Data) throws -> NativeTaskGenerationJob {
        try NativeTaskJSON.validate(data)
        let expected: Set<String> = ["id", "task_id", "binding_id", "enrollment_digest", "admission_base",
            "phase", "attempt", "messages", "messages_digest", "deadline_seconds", "generation"]
        guard data.count <= 1048576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == expected,
              let messages = object["messages"] as? [[String: Any]],
              messages.allSatisfy({ Set($0.keys) == Set(["role", "content"]) }) else {
            throw NativeTaskHTTPError.invalidResponse
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func validate(reference: NativeTaskReference, enforceInputLimit: Bool = true) throws {
        guard let profile = reference.profile, let binding = reference.createRequest.payload.nativeBinding,
              reference.remoteTaskID == taskID, reference.deliveryState == .accepted,
              !reference.cancelRequested, reference.snapshot?.state.isTerminal != true,
              bindingID == binding.id, enrollmentDigest == binding.enrollmentDigest,
              admissionBase == binding.admissionBase, admissionBase == profile.provider.base,
              ["plan", "synthesize"].contains(phase), (1...80).contains(attempt.utf8.count),
              attempt.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 }),
              UUID(uuidString: id) != nil, generation > 0,
              deadlineSeconds.isFinite, deadlineSeconds > 0, deadlineSeconds <= 180,
              (1...8).contains(messages.count),
              messages.allSatisfy({ ["system", "user", "assistant"].contains($0.role) }),
              Self.digest(messages) == messagesDigest else { throw NativeTaskHTTPError.invalidResponse }
        if enforceInputLimit,
           try JSONSerialization.data(withJSONObject: messages.map { ["role": $0.role, "content": $0.content] }).count
            > profile.limits.maximumInputBytes { throw NativeTaskGenerationFailure(code: "input_limit") }
    }

    static func digest(_ messages: [NativeTaskGenerationMessage]) -> String {
        var bytes = Data()
        for message in messages {
            for text in [message.role, message.content] {
                let encoded = Data(text.utf8)
                bytes.append(Data("\(encoded.count):".utf8))
                bytes.append(encoded)
            }
        }
        return nativeTaskDigest(bytes)
    }
}

enum NativeTaskGenerationReservation: Equatable, Sendable {
    case execute
    case pending
    case completed(String)
    case unavailable(String)
}

protocol NativeTaskGenerationRepository: NativeTaskRepository {
    func reserveTaskGeneration(referenceID: UUID, job: NativeTaskGenerationJob) throws -> NativeTaskGenerationReservation
    func finishTaskGeneration(referenceID: UUID, job: NativeTaskGenerationJob,
                              response: String?, failure: String?) throws
}

struct NativeTaskGenerationResponse: Codable, Sendable {
    let jobID: String
    let bindingID: String
    let generation: Int
    let messagesDigest: String
    let response: String?
    let failure: String?

    private enum CodingKeys: String, CodingKey {
        case generation, response, failure
        case jobID = "job_id"
        case bindingID = "binding_id"
        case messagesDigest = "messages_digest"
    }
}
