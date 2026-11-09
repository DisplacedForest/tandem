import Foundation

struct NativeTaskDecisionIntent: Codable, Equatable, Sendable {
    let referenceID: UUID
    let decisionID: String
    let key: UUID
    let choice: String

    init(referenceID: UUID, decisionID: String, key: UUID, choice: String = "retry") {
        self.referenceID = referenceID
        self.decisionID = decisionID
        self.key = key
        self.choice = choice
    }

    private enum CodingKeys: String, CodingKey { case referenceID, decisionID, key, choice }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        referenceID = try container.decode(UUID.self, forKey: .referenceID)
        decisionID = try container.decode(String.self, forKey: .decisionID)
        key = try container.decode(UUID.self, forKey: .key)
        choice = try container.decodeIfPresent(String.self, forKey: .choice) ?? "retry"
    }
}

extension NativeTaskClient {
    static func decisionBody(_ intent: NativeTaskDecisionIntent, digest: String?) throws -> Data {
        var reply: [String: Any] = ["action": intent.choice]
        if let digest { reply["digest"] = digest }
        return try canonical([
            "decision_id": intent.decisionID, "idempotency_key": intent.key.uuidString, "reply": reply,
        ])
    }

    func retry(_ reference: NativeTaskReference, intent: NativeTaskDecisionIntent) async throws -> NativeTaskSnapshot {
        try await decide(reference, intent: intent, digest: nil)
    }

    func decide(_ reference: NativeTaskReference, intent: NativeTaskDecisionIntent, digest: String?) async throws -> NativeTaskSnapshot {
        guard intent.referenceID == reference.id, let id = reference.remoteTaskID,
              UUID(uuidString: id) != nil, !intent.decisionID.isEmpty, !intent.choice.isEmpty else {
            throw NativeTaskHTTPError.invalidResponse
        }
        let body = try Self.decisionBody(intent, digest: digest)
        let (data, status) = try await request(
            "POST", reference.engine.base.appendingPathComponent("tasks/\(id)/decision"), body, 5)
        guard status == 200 else { throw NativeTaskHTTPError.status(status) }
        guard data.count <= 1048576 else { throw NativeTaskHTTPError.invalidResponse }
        try NativeTaskJSON.validate(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let received = object["payload"] as? [String: Any],
              let original = try JSONSerialization.jsonObject(with: reference.body) as? [String: Any],
              let expected = original["payload"] as? [String: Any],
              try Self.canonical(received) == Self.canonical(expected) else { throw NativeTaskHTTPError.invalidResponse }
        let snapshot = try JSONDecoder().decode(NativeTaskSnapshot.self, from: data)
        guard snapshot.id == id, snapshot.workerType == reference.createRequest.workerType else { throw NativeTaskHTTPError.invalidResponse }
        return snapshot
    }
}

struct NativeTaskEventTransport: Sendable {
    let events: @Sendable (NativeTaskEngineIdentity, Int64) -> AsyncThrowingStream<NativeTaskEvent, Error>

    static let live = NativeTaskEventTransport { engine, cursor in
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let operation = Task {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 45
                configuration.timeoutIntervalForResource = 3600
                configuration.httpMaximumConnectionsPerHost = 1
                let session = URLSession(configuration: configuration, delegate: NativeTaskRedirectGuard(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                do {
                    var components = URLComponents(url: engine.base.appendingPathComponent("tasks/events"),
                                                   resolvingAgainstBaseURL: false)
                    components?.queryItems = [URLQueryItem(name: "after", value: String(max(0, cursor)))]
                    guard let url = components?.url else { throw NativeTaskHTTPError.invalidResponse }
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else { throw NativeTaskHTTPError.invalidResponse }
                    guard response.statusCode == 200 else { throw NativeTaskHTTPError.status(response.statusCode) }
                    guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
                        throw NativeTaskHTTPError.invalidResponse
                    }
                    var decoder = NativeTaskEventDecoder()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let event = try decoder.consume(byte: byte) {
                            switch continuation.yield(event) {
                            case .enqueued: break
                            case .dropped: throw NativeTaskHTTPError.unavailable
                            case .terminated: return
                            @unknown default: throw NativeTaskHTTPError.unavailable
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as NativeTaskHTTPError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: NativeTaskHTTPError.unavailable)
                }
            }
            continuation.onTermination = { _ in operation.cancel() }
        }
    }
}
