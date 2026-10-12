import Foundation

enum NativeTaskHTTPError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case status(Int)
    case invalidResponse

    var canRetry: Bool {
        switch self {
        case .unavailable, .invalidResponse: return true
        case .status(let status): return status == 408 || status == 429 || status >= 500
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The research engine couldn't be reached."
        case .status(let status) where status == 401 || status == 403:
            return "The research engine didn't authorize this request."
        case .status(let status) where status == 404:
            return "The research engine couldn't find this task."
        case .status(let status) where status == 409:
            return "The research engine found a conflicting request."
        case .status(let status) where status == 422:
            return "The research engine couldn't accept this request."
        case .status: return "The research engine is unavailable right now."
        case .invalidResponse: return "The research engine returned an unreadable response."
        }
    }
}

final class NativeTaskRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct NativeTaskClient: Sendable {
    let request: @Sendable (String, URL, Data?, TimeInterval) async throws -> (Data, Int)

    static let live = NativeTaskClient { method, url, body, timeout in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: NativeTaskRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw NativeTaskHTTPError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1048576 else { throw NativeTaskHTTPError.invalidResponse }
                data.append(byte)
            }
            return (data, response.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NativeTaskHTTPError {
            throw error
        } catch {
            throw NativeTaskHTTPError.unavailable
        }
    }

    func create(_ reference: NativeTaskReference) async throws -> NativeTaskSnapshot {
        guard try reference.createRequest.encoded() == reference.body else {
            throw NativeTaskError.invalidRequest("The saved research request no longer matches its original payload.")
        }
        let (data, status) = try await request(
            "POST", reference.engine.base.appendingPathComponent("tasks"), reference.body, 5)
        guard (200..<300).contains(status) else { throw NativeTaskHTTPError.status(status) }
        try NativeTaskJSON.validate(data)
        guard data.count <= 1048576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let receivedPayload = object["payload"] as? [String: Any],
              let original = try? JSONSerialization.jsonObject(with: reference.body) as? [String: Any],
              let expectedPayload = original["payload"] as? [String: Any],
              try Self.canonical(receivedPayload) == Self.canonical(expectedPayload),
              let snapshot = try? JSONDecoder().decode(NativeTaskSnapshot.self, from: data),
              snapshot.workerType == reference.createRequest.workerType,
              UUID(uuidString: snapshot.id) != nil else { throw NativeTaskHTTPError.invalidResponse }
        return snapshot
    }

    func fetch(_ reference: NativeTaskReference) async throws -> NativeTaskSnapshot {
        guard let id = reference.remoteTaskID, UUID(uuidString: id) != nil else { throw NativeTaskHTTPError.invalidResponse }
        let (data, status) = try await request("GET", reference.engine.base.appendingPathComponent("tasks/\(id)"), nil, 5)
        guard status == 200 else { throw NativeTaskHTTPError.status(status) }
        try NativeTaskJSON.validate(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let received = object["payload"] as? [String: Any],
              let original = try JSONSerialization.jsonObject(with: reference.body) as? [String: Any],
              let expected = original["payload"] as? [String: Any],
              try Self.canonical(received) == Self.canonical(expected) else { throw NativeTaskHTTPError.invalidResponse }
        let snapshot = try JSONDecoder().decode(NativeTaskSnapshot.self, from: data)
        guard snapshot.id == id, snapshot.workerType == "research" else { throw NativeTaskHTTPError.invalidResponse }
        return snapshot
    }

    func cancel(_ reference: NativeTaskReference) async throws -> NativeTaskSnapshot {
        guard let id = reference.remoteTaskID, UUID(uuidString: id) != nil else {
            throw NativeTaskHTTPError.invalidResponse
        }
        let (data, status) = try await request(
            "POST", reference.engine.base.appendingPathComponent("tasks").appendingPathComponent(id)
                .appendingPathComponent("cancel"), Data("{}".utf8), 5)
        guard (200..<300).contains(status) else { throw NativeTaskHTTPError.status(status) }
        try NativeTaskJSON.validate(data)
        guard data.count <= 1048576,
              let snapshot = try? JSONDecoder().decode(NativeTaskSnapshot.self, from: data),
              snapshot.id == id, snapshot.workerType == "research" else {
            throw NativeTaskHTTPError.invalidResponse
        }
        return snapshot
    }

    static func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
