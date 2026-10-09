import Foundation
import VeraAssistantUI

actor NativePiAppOwner {
    let session: NativePiRuntimeSession
    let channel: PiPrivatePipe
    let runner: Task<Void, Never>
    let httpTransport: @Sendable (URLRequest) async throws -> (Data, Int)
    let eventTransport: PiOwnedTaskEventTransport
    private var eventStreams: [UUID: (Task<Void, Never>, PiOwnedTaskEventConnection, AsyncThrowingStream<AssistantTaskEvent, Error>.Continuation)] = [:]
    let memoryBridge: NativeRuntimeMemoryBridge?
    private var reader: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<PiValue, Error>] = [:]
    private var ready: PiValue?
    private var startWaiter: CheckedContinuation<PiValue, Error>?
    private var closed = false
    private var assistant: String?
    private var bindings: [String: PiValue] = [:]
    private var granting: [String: Task<Void, Error>] = [:]
    private var commandTimers: [String: Task<Void, Never>] = [:]
    init(arguments: [String], executor: any PiMockModelExecutor, ownerBinding: String, transport: PiTransportKind = .mock, memoryBridge: NativeRuntimeMemoryBridge? = nil, tools: (any NativeRuntimeToolServing)? = nil, httpTransport: @escaping @Sendable (URLRequest) async throws -> (Data, Int) = PiOwnedHTTP.send, eventTransport: PiOwnedTaskEventTransport = .live) throws {
        self.httpTransport = httpTransport
        self.eventTransport = eventTransport
        self.memoryBridge = memoryBridge
        let input = Pipe(), output = Pipe()
        channel = PiPrivatePipe(read: output.fileHandleForReading, write: input.fileHandleForWriting)
        let control = PiPrivatePipe(read: input.fileHandleForReading, write: output.fileHandleForWriting)
        let session = try NativePiRuntimeSession(arguments: arguments, controller: control, executor: executor, ownerBinding: ownerBinding, requestTimeout: 33, transport: transport, tools: tools)
        self.session = session
        runner = Task.detached { await session.run() }
    }
    func start() async throws -> PiValue {
        let channel = self.channel
        reader = Task.detached {
            do { while let frame = try channel.next() { await self.receive(frame) } }
            catch {}
            await self.disconnected()
        }
        if let ready { return ready }
        return try await NativeInferenceDeadline.run(seconds: 12) {
            try await self.waitForReady()
        }
    }
    private func waitForReady() async throws -> PiValue {
        try piCheck(!closed, .unavailable)
        if let ready { return ready }
        return try await withCheckedThrowingContinuation { startWaiter = $0 }
    }
    private func receive(_ frame: PiValue) {
        if frame.pi("op").piString == "ready", ready == nil {
            ready = frame
            startWaiter?.resume(returning: frame)
            startWaiter = nil
        } else if let id = frame.pi("id").piString, let waiter = pending.removeValue(forKey: id) {
            commandTimers.removeValue(forKey: id)?.cancel()
            if frame.pi("op").piString == "refused" { waiter.resume(throwing: PiBrokerError.unauthorized) }
            else { waiter.resume(returning: frame) }
        } else if frame.pi("op").piString == "disconnected" { disconnected() }
        else { disconnected() }
    }
    private func disconnected() {
        closed = true
        cancelEventStreams()
        channel.closeWrite()
        startWaiter?.resume(throwing: PiBrokerError.unavailable)
        startWaiter = nil
        for waiter in pending.values { waiter.resume(throwing: PiBrokerError.unavailable) }
        pending.removeAll()
        for timer in commandTimers.values { timer.cancel() }
        commandTimers.removeAll()
    }
    func endpoint() throws -> URL {
        guard !closed, case .number(let port) = ready?.pi("port") else { throw PiBrokerError.unavailable }
        return URL(string: "http://127.0.0.1:\(Int(port))")!
    }
    func bindAssistant(_ id: UUID) async throws {
        let value = id.uuidString.lowercased()
        try piCheck(assistant == nil || assistant == value, .unauthorized)
        try await memoryBridge?.bindAssistant(value)
        assistant = value
    }
    private func command(_ op: String, binding: PiValue) async throws -> PiValue {
        try piCheck(!closed, .unavailable)
        let id = UUID().uuidString.lowercased()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !closed, !Task.isCancelled else { continuation.resume(throwing: PiBrokerError.unavailable); return }
                pending[id] = continuation
                commandTimers[id] = Task {
                    do { try await Task.sleep(for: .seconds(3)); self.disconnected() } catch {}
                }
                do { try channel.send(.object(["op": .string(op), "id": .string(id), "binding": binding])) }
                catch { disconnected() }
            }
        } onCancel: { Task { await self.disconnected() } }
    }

    private func grant(_ binding: PiValue) async throws {
        let subject = try piUUID(binding.pi("subject"))
        if let existing = bindings[subject] { try piCheck(existing == binding, .unauthorized); return }
        if let task = granting[subject] { try await task.value; try piCheck(bindings[subject] == binding, .unauthorized); return }
        let task = Task {
            _ = try await command("authorize", binding: binding)
            bindings[subject] = binding
        }
        granting[subject] = task
        defer { granting.removeValue(forKey: subject) }
        try await task.value
    }
    private func identifier(_ value: PiValue) throws -> String {
        guard let raw = value.piString, let id = UUID(uuidString: raw) else { throw PiBrokerError.invalid }
        return id.uuidString.lowercased()
    }
    func http(_ request: URLRequest) async throws -> (Data, Int) {
        try piCheck(!closed, .unavailable)
        guard let ready, let assistant, let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              case .number(let port) = ready.pi("port") else { throw PiBrokerError.unavailable }
        try piCheck(parts.scheme == "http" && parts.host == "127.0.0.1" && parts.port == Int(port) && parts.user == nil && parts.password == nil && parts.fragment == nil, .unauthorized)
        let path = parts.path
        let components = path.split(separator: "/").map(String.init)
        let method = request.httpMethod ?? "GET"
        let allowedGet = ["/assistant/messages", "/assistant/capabilities", "/tasks"].contains(path)
        let taskOperation = components.count == 3 && components[0] == "tasks" && ["decision", "cancel"].contains(components[2]) && UUID(uuidString: components[1]) != nil
        try piCheck(method == "GET" && allowedGet || method == "POST" && (path == "/assistant/messages" || taskOperation), .unauthorized)
        if method == "POST", path == "/assistant/messages" {
            guard let data = request.httpBody else { throw PiBrokerError.invalid }
            let body = try PiValue.piRead(data)
            try body.piKeys(["assistant_id", "conversation_id", "message_id", "text", "mode"])
            try piCheck(try identifier(body.pi("assistant_id")) == assistant, .unauthorized)
            let binding: PiValue = .object(["subject": .string(try identifier(body.pi("message_id"))), "assistant": .string(assistant), "conversation": .string(try identifier(body.pi("conversation_id"))), "role": .string("foreground"), "mode": body.pi("mode")])
            guard let query = body.pi("text").piString else { throw PiBrokerError.invalid }
            try await memoryBridge?.authorize(binding, query: query)
            try await grant(binding)
            let response = try await authenticated(request)
            if response.1 == 200, let reply = try PiValue.piRead(response.0).pi("reply_id").piString {
                try await memoryBridge?.recordDelivery(subject: identifier(body.pi("message_id")), messageID: reply)
            }
            return response
        } else if method == "POST", taskOperation {
            let taskID = UUID(uuidString: components[1])!.uuidString.lowercased()
            let inspect = URLRequest(url: URL(string: "http://127.0.0.1:\(Int(port))/tasks/\(taskID)")!)
            let (bytes, status) = try await authenticated(inspect)
            try piCheck(status == 200, .unavailable)
            let task = try PiValue.piRead(bytes), payload = task.pi("payload")
            try piCheck(task.pi("id").piString == taskID && task.pi("worker_type").piString == "pi_worker" && payload.pi("assistant_id").piString == assistant, .unauthorized)
            if components[2] == "cancel" {
                await session.broker.revoke(subject: taskID)
                await memoryBridge?.revoke(taskID)
            }
            if components[2] == "decision" {
                guard let data = request.httpBody else { throw PiBrokerError.invalid }
                let body = try PiValue.piRead(data)
                try body.piKeys(["decision_id", "idempotency_key", "reply"])
                if body.pi("reply") == .object(["approved": .bool(true)]), bindings[taskID] == nil || task.pi("state").piString == "needs_decision" {
                    try piCheck(task.pi("state").piString == "needs_decision" && task.pi("decision").pi("id") == body.pi("decision_id"), .unauthorized)
                    await memoryBridge?.pause(taskID)
                    let response = try await authenticated(request)
                    if response.1 == 200 {
                        let confirmed = try PiValue.piRead(response.0)
                        try piCheck(confirmed.pi("id").piString == taskID && confirmed.pi("payload") == payload && confirmed.pi("cancel_requested") == .bool(false) && confirmed.pi("decision_reply") == body.pi("reply"), .unauthorized)
                        let binding: PiValue = .object(["subject": .string(taskID), "assistant": .string(assistant), "conversation": payload.pi("conversation_id"), "role": .string("worker"), "mode": .string("assistant")])
                        guard let query = payload.pi("objective").piString else { throw PiBrokerError.invalid }
                        try await memoryBridge?.authorize(binding, query: query, generation: identifier(body.pi("decision_id")))
                        try await grant(binding)
                        await memoryBridge?.resume(taskID)
                    }
                    return response
                }
            }
        }
        return try await authenticated(request)
    }
    private func authenticated(_ request: URLRequest) async throws -> (Data, Int) {
        guard let capability = ready?.pi("ui_capability").piString else { throw PiBrokerError.unavailable }
        var request = request
        request.setValue("Bearer " + capability, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await httpTransport(request)
    }
    func events(after: Int64) throws -> AsyncThrowingStream<AssistantTaskEvent, Error> {
        guard !closed, let assistant, let capability = ready?.pi("ui_capability").piString else { throw PiBrokerError.unavailable }
        try piCheck(eventStreams.count < 2, .unavailable)
        let request = try PiOwnedTaskEventTransport.request(endpoint: endpoint(), capability: capability, after: after)
        let connection = eventTransport.open(request)
        let id = UUID()
        let (events, continuation) = AsyncThrowingStream<AssistantTaskEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(PiOwnedTaskEventTransport.maximumBufferedEvents))
        let operation = Task {
            defer { connection.cancel(); eventStreams.removeValue(forKey: id) }
            do {
                for try await event in connection.events {
                    try Task.checkCancellation()
                    try piCheck(!closed && self.assistant == assistant, .unavailable)
                    switch continuation.yield(event) {
                    case .enqueued: break
                    case .dropped: throw PiBrokerError.unavailable
                    case .terminated: return
                    @unknown default: throw PiBrokerError.unavailable
                    }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        eventStreams[id] = (operation, connection, continuation)
        continuation.onTermination = { _ in operation.cancel(); connection.cancel() }
        return events
    }
    private func cancelEventStreams() {
        let active = eventStreams.values
        eventStreams.removeAll()
        for (operation, connection, continuation) in active {
            operation.cancel()
            connection.cancel()
            continuation.finish(throwing: CancellationError())
        }
    }
    func stop() async {
        closed = true
        cancelEventStreams()
        await memoryBridge?.close()
        channel.closeWrite()
        await runner.value
        await reader?.value
        disconnected()
    }
}

final class PiOwnedRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum PiOwnedHTTP {
    static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 125
        let session = URLSession(configuration: configuration, delegate: PiOwnedRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw PiBrokerError.unavailable }
        var data = Data()
        for try await byte in bytes {
            try piCheck(data.count < 4 * 1024 * 1024, .invalid)
            data.append(byte)
        }
        return (data, response.statusCode)
    }
}
