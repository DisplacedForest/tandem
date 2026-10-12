import Foundation

final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct PrototypeClient: Sendable {
    let base: URL
    let send: @Sendable (URLRequest) async throws -> (Data, Int)

    init(base: URL, send: (@Sendable (URLRequest) async throws -> (Data, Int))? = nil) {
        self.base = base
        self.send = send ?? { request in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 125
            let session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { throw PrototypeError.invalidResponse }
                var body = Data()
                for try await byte in bytes {
                    guard body.count < 4 * 1024 * 1024 else { throw PrototypeError.invalidResponse }
                    body.append(byte)
                }
                return (body, response.statusCode)
            } catch is CancellationError { throw CancellationError() }
            catch let error as PrototypeError { throw error }
            catch { throw PrototypeError.unavailable }
        }
    }

    func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else { throw PrototypeError.status(status) }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw PrototypeError.invalidResponse }
        return decoded
    }

    func capabilities() async throws -> Capabilities { try await request("assistant/capabilities") }
    func messages(_ id: UUID) async throws -> [Message] {
        let response: TranscriptResponse = try await request("assistant/messages", query: [.init(name: "conversation_id", value: id.uuidString)])
        guard Set(response.messages.map(\.id)).count == response.messages.count else { throw PrototypeError.invalidResponse }
        return response.messages
    }
    func message(_ body: MessageRequest) async throws -> MessageResponse {
        let response: MessageResponse = try await request("assistant/messages", body: JSONEncoder().encode(body))
        guard response.messageID == body.messageID else { throw PrototypeError.invalidResponse }
        return response
    }
    func tasks() async throws -> [TaskSnapshot] {
        var tasks: [TaskSnapshot] = []
        var index: [String: Int] = [:]
        func walk(states: String?, pages: Int) async throws -> Bool {
            var before: String?
            for _ in 0..<pages {
                var query = [URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "compact", value: "true")]
                if let states { query.append(.init(name: "states", value: states)) }
                if let before { query.append(.init(name: "before", value: before)) }
                let page: TaskPage = try await request("tasks", query: query)
                for task in page.tasks {
                    guard UUID(uuidString: task.id) != nil else { throw PrototypeError.invalidResponse }
                    if let position = index[task.id] {
                        if task.updatedAt >= tasks[position].updatedAt { tasks[position] = task }
                    } else {
                        index[task.id] = tasks.count
                        tasks.append(task)
                    }
                }
                if page.tasks.count < 25 { return true }
                before = page.tasks.last?.id
            }
            return false
        }
        if try await walk(states: nil, pages: 100) { return tasks }
        guard try await walk(states: "queued,running,blocked,needs_decision", pages: 4000) else { throw PrototypeError.invalidResponse }
        return tasks
    }
    func cancel(_ id: String) async throws -> TaskSnapshot {
        guard UUID(uuidString: id) != nil else { throw PrototypeError.invalidResponse }
        let task: TaskSnapshot = try await request("tasks/\(id)/cancel", body: Data("{}".utf8))
        guard task.id == id else { throw PrototypeError.invalidResponse }
        return task
    }
    func decision(_ id: String, body: DecisionRequest) async throws -> TaskSnapshot {
        guard UUID(uuidString: id) != nil else { throw PrototypeError.invalidResponse }
        let task: TaskSnapshot = try await request("tasks/\(id)/decision", body: JSONEncoder().encode(body))
        guard task.id == id else { throw PrototypeError.invalidResponse }
        return task
    }
}
