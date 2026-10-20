import Foundation

enum ComfyUIEvent: Equatable, Sendable {
    case progress(completed: Int, total: Int, promptID: String?)
    case finished(promptID: String?)
    case failed(promptID: String?, message: String)
    case interrupted(promptID: String?)
}

struct ComfyUITransport: Sendable {
    let request: @Sendable (URL, String, Data?, TimeInterval) async throws -> (Data, Int)
    let events: @Sendable (URL) -> AsyncThrowingStream<ComfyUIEvent, Error>?

    static let live = ComfyUITransport(
        request: { url, method, body, timeout in
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        },
        events: { url in
            AsyncThrowingStream { continuation in
                let socket = URLSession.shared.webSocketTask(with: url)
                socket.resume()
                let reader = Task {
                    do {
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            guard case .string(let text) = message,
                                  let event = ComfyUIClient.parseEvent(text) else { continue }
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    reader.cancel()
                    socket.cancel(with: .normalClosure, reason: nil)
                }
            }
        })
}

struct ComfyUIOutput: Equatable, Sendable {
    let data: Data
    let fileName: String
}

struct ComfyUIClient: Sendable {
    let base: URL
    let transport: ComfyUITransport
    var pollInterval: Duration = .seconds(1)

    static let clientID = UUID().uuidString.lowercased()

    func systemStats() async throws -> Data {
        let (data, status) = try await transport.request(endpoint("system_stats"), "GET", nil, 6)
        guard (200..<300).contains(status) else {
            throw NativeToolError.failed("ComfyUI answered HTTP \(status)")
        }
        return data
    }

    func generate(
        graph: [String: Any],
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> ComfyUIOutput {
        let eventStream = transport.events(socketURL())
        let promptID = UUID().uuidString.lowercased()
        let submission = ComfyUISubmission()
        return try await withTaskCancellationHandler {
            do {
                try await queue(graph, promptID: promptID)
                await submission.settle(.accepted)
            } catch ComfyUIQueueError.rejected(let message) {
                await submission.settle(.rejected)
                throw NativeToolError.failed(message)
            } catch ComfyUIQueueError.transport(let message) {
                await submission.settle(.unknown)
                throw NativeToolError.failed(message)
            } catch {
                await submission.settle(.unknown)
                throw error
            }
            let signal = ComfyUISignal()
            let listener = Task {
                guard let eventStream else { return }
                do {
                    for try await event in eventStream {
                        switch event {
                        case .progress(let completed, let total, let id) where id == nil || id == promptID:
                            onProgress(completed, total)
                        case .finished(let id) where id == nil || id == promptID:
                            await signal.set(.finished)
                        case .failed(let id, let message) where id == nil || id == promptID:
                            await signal.set(.failed(message))
                        case .interrupted(let id) where id == nil || id == promptID:
                            await signal.set(.interrupted)
                        default:
                            continue
                        }
                    }
                } catch {}
            }
            defer { listener.cancel() }
            while true {
                try Task.checkCancellation()
                if let record = try await history(promptID) {
                    switch record {
                    case .completed(let file):
                        return try await fetch(file)
                    case .failed(let message):
                        throw NativeToolError.failed(message)
                    }
                }
                if case .failed(let message)? = await signal.value {
                    throw NativeToolError.failed(message)
                }
                if case .interrupted? = await signal.value {
                    throw CancellationError()
                }
                try await Task.sleep(for: pollInterval)
            }
        } onCancel: {
            Task.detached {
                guard await submission.outcome(within: .seconds(35)) != .rejected else { return }
                await cancel(promptID)
            }
        }
    }

    static func parseEvent(_ text: String) -> ComfyUIEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let payload = object["data"] as? [String: Any] ?? [:]
        let promptID = payload["prompt_id"] as? String
        switch type {
        case "progress":
            guard let value = (payload["value"] as? NSNumber)?.intValue,
                  let max = (payload["max"] as? NSNumber)?.intValue, max > 0 else { return nil }
            return .progress(completed: value, total: max, promptID: promptID)
        case "executing":
            guard payload["node"] is NSNull || payload["node"] == nil else { return nil }
            return .finished(promptID: promptID)
        case "execution_success":
            return .finished(promptID: promptID)
        case "execution_error":
            let message = (payload["exception_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let node = payload["node_type"] as? String
            return .failed(promptID: promptID, message: Self.describe(message: message, node: node))
        case "execution_interrupted":
            return .interrupted(promptID: promptID)
        default:
            return nil
        }
    }

    static func describe(message: String?, node: String?) -> String {
        switch (message, node) {
        case (let message?, let node?): return "\(node): \(message)"
        case (let message?, nil): return message
        case (nil, let node?): return "The run failed at \(node)"
        case (nil, nil): return "The run failed on the server"
        }
    }

    private enum HistoryRecord {
        case completed(ComfyUIFile)
        case failed(String)
    }

    private struct ComfyUIFile {
        let filename: String
        let subfolder: String
        let type: String
    }

    private func queue(_ graph: [String: Any], promptID: String) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["prompt": graph, "client_id": Self.clientID, "prompt_id": promptID], options: [.sortedKeys])
        let data: Data
        let status: Int
        do {
            (data, status) = try await transport.request(endpoint("prompt"), "POST", body, 30)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ComfyUIQueueError.transport("ComfyUI is unreachable: \(error.localizedDescription)")
        }
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            throw ComfyUIQueueError.rejected(Self.queueError(object, status: status))
        }
        guard object["prompt_id"] as? String == promptID else {
            throw ComfyUIQueueError.transport("ComfyUI accepted the request under a different id")
        }
    }

    static func queueError(_ object: [String: Any], status: Int) -> String {
        var parts: [String] = []
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty { parts.append(message) }
            if let details = error["details"] as? String, !details.isEmpty { parts.append(details) }
        } else if let error = object["error"] as? String, !error.isEmpty {
            parts.append(error)
        }
        if let nodeErrors = object["node_errors"] as? [String: Any] {
            for key in nodeErrors.keys.sorted() {
                guard let node = nodeErrors[key] as? [String: Any],
                      let errors = node["errors"] as? [[String: Any]] else { continue }
                for entry in errors {
                    let message = entry["message"] as? String ?? ""
                    let details = entry["details"] as? String ?? ""
                    let text = [message, details].filter { !$0.isEmpty }.joined(separator: ": ")
                    if !text.isEmpty { parts.append("\(key): \(text)") }
                }
            }
        }
        return parts.isEmpty ? "ComfyUI rejected the request with HTTP \(status)" : parts.joined(separator: ". ")
    }

    private func history(_ promptID: String) async throws -> HistoryRecord? {
        let (data, status) = try await transport.request(endpoint("history/\(promptID)"), "GET", nil, 15)
        guard (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = object[promptID] as? [String: Any] else { return nil }
        let state = record["status"] as? [String: Any] ?? [:]
        if state["status_str"] as? String == "error" {
            return .failed(Self.historyError(state))
        }
        guard state["completed"] as? Bool == true || state["status_str"] as? String == "success" else { return nil }
        let outputs = record["outputs"] as? [String: Any] ?? [:]
        for key in outputs.keys.sorted() {
            guard let node = outputs[key] as? [String: Any],
                  let images = node["images"] as? [[String: Any]] else { continue }
            for image in images where image["type"] as? String == "output" {
                guard let filename = image["filename"] as? String, !filename.isEmpty else { continue }
                return .completed(ComfyUIFile(
                    filename: filename,
                    subfolder: image["subfolder"] as? String ?? "",
                    type: "output"))
            }
        }
        return .failed("The run finished without producing an image")
    }

    static func historyError(_ state: [String: Any]) -> String {
        let messages = state["messages"] as? [[Any]] ?? []
        for entry in messages {
            guard entry.count == 2, entry[0] as? String == "execution_error",
                  let payload = entry[1] as? [String: Any] else { continue }
            return describe(
                message: (payload["exception_message"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                node: payload["node_type"] as? String)
        }
        return "The run failed on the server"
    }

    private func fetch(_ file: ComfyUIFile) async throws -> ComfyUIOutput {
        guard var components = URLComponents(url: endpoint("view"), resolvingAgainstBaseURL: false) else {
            throw NativeToolError.failed("The ComfyUI URL is not valid")
        }
        components.queryItems = [
            URLQueryItem(name: "filename", value: file.filename),
            URLQueryItem(name: "subfolder", value: file.subfolder),
            URLQueryItem(name: "type", value: file.type),
        ]
        guard let url = components.url else { throw NativeToolError.failed("The ComfyUI URL is not valid") }
        let (data, status) = try await transport.request(url, "GET", nil, 60)
        guard (200..<300).contains(status), !data.isEmpty else {
            throw NativeToolError.failed("The finished image could not be fetched (HTTP \(status))")
        }
        return ComfyUIOutput(data: data, fileName: file.filename)
    }

    static let cancelReconcileAttempts = 6

    private func cancel(_ promptID: String) async {
        for attempt in 0..<Self.cancelReconcileAttempts {
            switch await queuePosition(promptID) {
            case .running:
                await interrupt(promptID)
                return
            case .pending:
                if let body = try? JSONSerialization.data(withJSONObject: ["delete": [promptID]]) {
                    _ = try? await transport.request(endpoint("queue"), "POST", body, 10)
                }
            case .absent:
                if (try? await history(promptID)) != nil { return }
            }
            if attempt + 1 < Self.cancelReconcileAttempts {
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private enum QueuePosition {
        case running
        case pending
        case absent
    }

    private func queuePosition(_ promptID: String) async -> QueuePosition {
        guard let (data, _) = try? await transport.request(endpoint("queue"), "GET", nil, 10),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .absent }
        func contains(_ key: String) -> Bool {
            (object[key] as? [[Any]] ?? []).contains { entry in entry.count > 1 && entry[1] as? String == promptID }
        }
        if contains("queue_running") { return .running }
        if contains("queue_pending") { return .pending }
        return .absent
    }

    private func interrupt(_ promptID: String) async {
        guard let body = try? JSONSerialization.data(withJSONObject: ["prompt_id": promptID]) else { return }
        _ = try? await transport.request(endpoint("interrupt"), "POST", body, 10)
    }

    private func endpoint(_ path: String) -> URL {
        var url = base
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        return url
    }

    private func socketURL() -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/ws"
        components.queryItems = [URLQueryItem(name: "clientId", value: Self.clientID)]
        return components.url ?? base
    }
}

enum ComfyUIQueueError: Error, Equatable {
    case rejected(String)
    case transport(String)
}

private actor ComfyUISubmission {
    enum Outcome: Equatable {
        case accepted
        case rejected
        case unknown
    }

    private var settled: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    func settle(_ outcome: Outcome) {
        guard settled == nil else { return }
        settled = outcome
        for waiter in waiters { waiter.resume(returning: outcome) }
        waiters = []
    }

    func outcome(within limit: Duration) async -> Outcome {
        if let settled { return settled }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.settle(.unknown)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            if let settled {
                continuation.resume(returning: settled)
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private actor ComfyUISignal {
    enum Outcome: Equatable {
        case finished
        case failed(String)
        case interrupted
    }

    private(set) var value: Outcome?

    func set(_ outcome: Outcome) {
        if value == nil { value = outcome }
    }
}
