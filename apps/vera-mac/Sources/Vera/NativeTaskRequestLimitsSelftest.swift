import Foundation
import Network

final class TaskLimitsWire: @unchecked Sendable {
    struct Piece: Sendable {
        let at: Double
        let bytes: Data
    }

    private let lock = NSLock()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "request-limits-wire")
    private let contentType: String
    private let pieces: [Piece]
    private let closes: Bool
    private var received: [Data] = []
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var bodies: [Data] { lock.withLock { received } }
    var base: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    init(contentType: String = "text/event-stream", pieces: [Piece], closes: Bool = true) async throws {
        self.contentType = contentType
        self.pieces = pieces
        self.closes = closes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = listener
        let gate = NativePiReadyGate()
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        port = try await withCheckedThrowingContinuation { continuation in
            ready.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish { continuation.resume(returning: ready.port?.rawValue ?? 0) }
                case .failed(let error): gate.finish { continuation.resume(throwing: error) }
                default: break
                }
            }
            ready.start(queue: queue)
        }
        try NativeTaskFixture.require(port != 0, "The limits wire listens")
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock { connections }
        open.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).lowercased()
                let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buffer[end.upperBound...]
                if body.count >= length {
                    lock.withLock { received.append(Data(body.prefix(length))) }
                    respond(connection)
                    return
                }
            }
            guard !complete, error == nil else { return }
            read(connection, buffer)
        }
    }

    private func respond(_ connection: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
        send(connection, index: 0, started: DispatchTime.now())
    }

    private func send(_ connection: NWConnection, index: Int, started: DispatchTime) {
        guard index < pieces.count else {
            guard closes else { return }
            connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        queue.asyncAfter(deadline: started + pieces[index].at) { [self] in
            let bytes = pieces[index].bytes
            var frame = Data(String(bytes.count, radix: 16).utf8)
            frame.append(Data("\r\n".utf8))
            frame.append(bytes)
            frame.append(Data("\r\n".utf8))
            connection.send(content: frame, completion: .idempotent)
            send(connection, index: index + 1, started: started)
        }
    }

    static func event(_ delta: [String: Any], finish: String? = nil) -> Data {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        choice["finish_reason"] = finish ?? NSNull()
        let object: [String: Any] = ["choices": [choice]]
        let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    static let done = Data("data: [DONE]\n\n".utf8)

    static func streamed(_ text: [String], every: Double, from start: Double, finish: String = "stop") -> [Piece] {
        var pieces = [Piece(at: 0, bytes: event(["role": "assistant", "content": ""]))]
        for (index, part) in text.enumerated() {
            pieces.append(Piece(at: start + Double(index) * every, bytes: event(["content": part])))
        }
        let end = start + Double(max(0, text.count - 1)) * every
        pieces.append(Piece(at: end, bytes: event([:], finish: finish)))
        pieces.append(Piece(at: end, bytes: done))
        return pieces
    }
}

@MainActor
extension SelfTest {
    static func taskRequestLimits() async throws {
        try limitsFromEnvironment()
        try await limitsLateFirstReply()
        try await limitsSteadyStream()
        try await limitsSilence()
        try await limitsSilentMidReply()
        try await limitsWholeBody()
        try await limitsStreamedToolCalls()
        try await limitsCutShort()
        try await limitsReplySize()
        try await limitsTemplateOptions()
        try await limitsQueuedRequest()
    }

    private static let scaledLimits = NativeTaskTransportLimits(connectAndSend: 3, firstReply: 3, replyIdle: 0.5, request: 60)

    private static func limitsJob(deadline: Double = 60, tools: [NativeTaskGenerationTool]? = nil) -> NativeTaskGenerationJob {
        let messages = [NativeTaskGenerationMessage(role: "user", content: "Write one section")]
        return NativeTaskGenerationJob(id: UUID().uuidString, taskID: UUID().uuidString, bindingID: UUID().uuidString,
            enrollmentDigest: String(repeating: "a", count: 64), admissionBase: URL(string: "http://127.0.0.1/v1")!,
            phase: tools == nil ? "draft-1" : "work-1", attempt: "initial-0", messages: messages,
            messagesDigest: NativeTaskGenerationJob.digest(messages, tools: tools, toolChoice: tools == nil ? nil : "auto"),
            deadlineSeconds: deadline, generation: 1, tools: tools, toolChoice: tools == nil ? nil : "auto")
    }

    private static func limitsComplete(_ wire: TaskLimitsWire, job: NativeTaskGenerationJob,
                                       limits: NativeTaskTransportLimits = scaledLimits,
                                       template: String? = nil, kwargs: [NativeChatRequestOptions.Entry] = [],
                                       capture: NativeTaskTimingCapture = NativeTaskTimingCapture()) async throws -> NativeTaskGenerationCompletion {
        let binding = NativeTaskProfileBinding(id: UUID().uuidString, profileID: "limits-profile",
            provider: try NativeTaskEngineIdentity(wire.base), savedModel: "limits-model", executionModel: "limits-model",
            limits: try NativeTaskGenerationLimits())
        var options = NativeChatRequestOptions.none
        options.kwargs = kwargs
        let config = NativeChatConfig(baseURL: wire.base, apiKey: "limits-key", model: "limits-model",
                                      chatTemplateKwargs: template, streaming: false, options: options)
        return try await NativeTaskProvider.completion(config: config, binding: binding, job: job, limits: limits,
                                                       diagnostics: { capture.append($0) })
    }

    private static func limitsFailure(_ wire: TaskLimitsWire, job: NativeTaskGenerationJob,
                                      capture: NativeTaskTimingCapture) async throws -> (NativeTaskGenerationFailure, Double) {
        let started = ContinuousClock.now
        do {
            _ = try await limitsComplete(wire, job: job, capture: capture)
            throw NativeTaskFixture.Failure.assertion("The request must fail")
        } catch let failure as NativeTaskGenerationFailure {
            return (failure, nativeTaskSeconds(started.duration(to: .now)))
        }
    }

    private static func limitsFromEnvironment() throws {
        let require = NativeTaskFixture.require
        let defaults = NativeTaskTransportLimits(environment: [:])
        try require(defaults == NativeTaskTransportLimits(connectAndSend: 10, firstReply: 180, replyIdle: 45, request: 600),
                    "Request limits default to 10, 180, 45 and 600 seconds")
        let tuned = NativeTaskTransportLimits(environment: [
            NativeTaskTransportLimits.connectAndSendSetting: "4", NativeTaskTransportLimits.firstReplySetting: " 300 ",
            NativeTaskTransportLimits.replyIdleSetting: "75.5", NativeTaskTransportLimits.requestSetting: "900"])
        try require(tuned == NativeTaskTransportLimits(connectAndSend: 4, firstReply: 300, replyIdle: 75.5, request: 900),
                    "Each request limit reads its own environment setting")
        let invalid = NativeTaskTransportLimits(environment: [
            NativeTaskTransportLimits.connectAndSendSetting: "0", NativeTaskTransportLimits.firstReplySetting: "soon",
            NativeTaskTransportLimits.replyIdleSetting: "-5", NativeTaskTransportLimits.requestSetting: "inf"])
        try require(invalid == defaults, "Unusable settings keep the defaults")
        let ceiling = NativeTaskTransportLimits.configured.request
        try require(NativeResearchWorker.stepTimeoutSeconds >= ceiling * 2 && NativeDocumentWorker.stepTimeoutSeconds >= ceiling * 2
                    && NativeCompanionWorker.stepTimeoutSeconds >= ceiling * 2,
                    "A step fits a queued wait and one full request")
        let job = limitsJob(deadline: ceiling)
        try require(NativeTaskGenerationJob.decode(try nativeTaskEncoded(job)).deadlineSeconds == ceiling,
                    "A job may carry the full request ceiling")
    }

    private static func limitsLateFirstReply() async throws {
        let require = NativeTaskFixture.require
        let wire = try await TaskLimitsWire(pieces: TaskLimitsWire.streamed(["Late ", "but ", "steady."], every: 0.1, from: 1))
        defer { wire.stop() }
        let capture = NativeTaskTimingCapture()
        let result = try await limitsComplete(wire, job: limitsJob(), capture: capture)
        try require(result.content == "Late but steady." && result.finishReason == "stop", "A reply that starts after the idle limit completes")
        try await Task.sleep(for: .milliseconds(50))
        let timing = capture.snapshot
        try require(timing.count == 1 && timing[0].outcome == .completed, "One completed diagnostic is logged")
        let firstByte = timing[0].firstByteSeconds ?? 99
        let firstReply = timing[0].firstReplySeconds ?? 0
        try require(firstReply >= 0.95 && firstByte < firstReply - 0.3,
                    "The diagnostic records the first body byte and the first reply apart: \(timing[0])")
    }

    private static func limitsSteadyStream() async throws {
        let require = NativeTaskFixture.require
        let parts = (0..<40).map { "w\($0) " }
        let wire = try await TaskLimitsWire(pieces: TaskLimitsWire.streamed(parts, every: 0.1, from: 0.1))
        defer { wire.stop() }
        let started = ContinuousClock.now
        let result = try await limitsComplete(wire, job: limitsJob())
        try require(result.content == parts.joined() && nativeTaskSeconds(started.duration(to: .now)) > scaledLimits.firstReply + scaledLimits.replyIdle,
                    "A steady stream longer than every gap limit completes")
    }

    private static func limitsSilence() async throws {
        let require = NativeTaskFixture.require
        let quiet = try await TaskLimitsWire(pieces: [], closes: false)
        defer { quiet.stop() }
        let capture = NativeTaskTimingCapture()
        let (failure, elapsed) = try await limitsFailure(quiet, job: limitsJob(), capture: capture)
        try require(failure.code == "request_timeout", "Silence fails as a slow request: \(failure.code)")
        try require(elapsed >= scaledLimits.firstReply && elapsed < scaledLimits.firstReply + 2,
                    "Silence fails once the first-reply limit passes and not before: \(elapsed)")
        try await Task.sleep(for: .milliseconds(50))
        try require(capture.snapshot.map(\.outcome) == [.first_reply_timeout], "Silence is logged as a missing first reply")

        let opened = try await TaskLimitsWire(pieces: [.init(at: 0, bytes: TaskLimitsWire.event(["role": "assistant", "content": ""]))], closes: false)
        defer { opened.stop() }
        let openedCapture = NativeTaskTimingCapture()
        let (openedFailure, openedElapsed) = try await limitsFailure(opened, job: limitsJob(), capture: openedCapture)
        try require(openedFailure.code == "request_timeout" && openedElapsed >= scaledLimits.firstReply,
                    "An opening role event does not start the idle clock: \(openedElapsed)")
        try await Task.sleep(for: .milliseconds(50))
        try require(openedCapture.snapshot.map(\.outcome) == [.first_reply_timeout], "An empty opening is still waiting for its first reply")
    }

    private static func limitsSilentMidReply() async throws {
        let require = NativeTaskFixture.require
        let wire = try await TaskLimitsWire(pieces: [
            .init(at: 0, bytes: TaskLimitsWire.event(["role": "assistant", "content": ""])),
            .init(at: 0.1, bytes: TaskLimitsWire.event(["content": "Started then"])),
        ], closes: false)
        defer { wire.stop() }
        let capture = NativeTaskTimingCapture()
        let (failure, elapsed) = try await limitsFailure(wire, job: limitsJob(), capture: capture)
        try require(failure.code == "request_timeout", "A reply that goes quiet fails as a slow request")
        try require(elapsed >= 0.1 + scaledLimits.replyIdle && elapsed < scaledLimits.firstReply,
                    "A reply that goes quiet fails at the idle limit: \(elapsed)")
        try await Task.sleep(for: .milliseconds(50))
        try require(capture.snapshot.map(\.outcome) == [.read_idle_timeout], "A quiet reply is logged as idle")
    }

    private static func limitsWholeBody() async throws {
        let require = NativeTaskFixture.require
        let body = TaskReplyCauseWire.choice("A whole answer.", finish: "stop")
        let wire = try await TaskLimitsWire(contentType: "application/json",
            pieces: [.init(at: 1, bytes: body.prefix(10)), .init(at: 1.05, bytes: body.dropFirst(10))])
        defer { wire.stop() }
        let result = try await limitsComplete(wire, job: limitsJob())
        try require(result.content == "A whole answer." && result.finishReason == "stop", "A single JSON answer still reads")
        let sent = wire.bodies.first.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        try require(sent?["stream"] as? Bool == true, "Requests ask for a streamed reply")
    }

    private static func limitsStreamedToolCalls() async throws {
        let require = NativeTaskFixture.require
        let tools = [dotLookupTool]
        let streamed = try await TaskLimitsWire(pieces: [
            .init(at: 0, bytes: TaskLimitsWire.event(["role": "assistant", "content": ""])),
            .init(at: 0.05, bytes: TaskLimitsWire.event(["content": "Checking."])),
            .init(at: 0.1, bytes: TaskLimitsWire.event(["tool_calls": [["index": 0, "id": "call-1", "type": "function",
                                                                          "function": ["name": "lookup_", "arguments": ""]]]])),
            .init(at: 0.15, bytes: TaskLimitsWire.event(["tool_calls": [["index": 0, "function": ["name": "moon", "arguments": "{\"moon\":"]]]])),
            .init(at: 0.2, bytes: TaskLimitsWire.event(["tool_calls": [["index": 0, "function": ["arguments": "\"Luma\"}"]]]])),
            .init(at: 0.25, bytes: TaskLimitsWire.event([:], finish: "tool_calls")),
            .init(at: 0.25, bytes: Data("data: {\"choices\":[],\"usage\":{\"total_tokens\":3}}\n\n".utf8)),
            .init(at: 0.25, bytes: TaskLimitsWire.done),
        ])
        defer { streamed.stop() }
        let whole = try await TaskLimitsWire(contentType: "application/json", pieces: [.init(at: 0, bytes: TaskReplyCauseWire.choice(
            "Checking.", finish: "tool_calls",
            calls: [["id": "call-1", "type": "function", "function": ["name": "lookup_moon", "arguments": "{\"moon\":\"Luma\"}"]]]))])
        defer { whole.stop() }
        let fromStream = try await limitsComplete(streamed, job: limitsJob(tools: tools))
        let fromBody = try await limitsComplete(whole, job: limitsJob(tools: tools))
        try require(fromStream == fromBody && fromStream.toolCalls.first?.name == "lookup_moon"
                    && fromStream.toolCalls.first?.arguments == "{\"moon\":\"Luma\"}" && fromStream.content == "Checking.",
                    "A streamed reply with tool calls matches the single-body reply: \(fromStream) \(fromBody)")
    }

    private static func limitsCutShort() async throws {
        let require = NativeTaskFixture.require
        func expectCut(_ job: NativeTaskGenerationJob, _ what: String, _ run: () async throws -> NativeTaskGenerationCompletion) async throws {
            do {
                _ = try await run()
                throw NativeTaskFixture.Failure.assertion("\(what) must fail")
            } catch let failure as NativeTaskGenerationFailure {
                try require(failure.code == "response_cut_short"
                            && failure.detail == NativeTaskGenerationFailureDetail(phase: job.phase, httpStatus: 200, finishReason: "length"),
                            "\(what) is reported as cut short: \(failure.code) \(String(describing: failure.detail))")
            }
        }
        for offered in [false, true] {
            for partial in [false, true] {
                let job = limitsJob(tools: offered ? [dotLookupTool] : nil)
                let label = "\(offered ? "With" : "Without") tools offered, \(partial ? "a partial call" : "text only")"
                let wire = try await TaskLimitsWire(pieces: [
                    .init(at: 0, bytes: TaskLimitsWire.event(["role": "assistant", "content": ""])),
                    .init(at: 0.05, bytes: TaskLimitsWire.event(["content": TaskReplyCauseWire.partial])),
                ] + (partial ? [.init(at: 0.08, bytes: TaskLimitsWire.event(["tool_calls": [["index": 0, "id": "call-1", "type": "function",
                                                                                              "function": ["name": "lookup_moon", "arguments": "{\"moon\":"]]]]))] : [])
                  + [.init(at: 0.1, bytes: TaskLimitsWire.event([:], finish: "length")), .init(at: 0.1, bytes: TaskLimitsWire.done)])
                defer { wire.stop() }
                try await expectCut(job, "\(label), a streamed reply cut off by the output limit") {
                    try await limitsComplete(wire, job: job)
                }
                try await expectCut(job, "\(label), a single-body reply cut off by the output limit") {
                    try await TaskReplyCauseWire.complete(partial ? "lengthtools" : "length", job: job)
                }
            }
        }
    }

    private static func limitsReplySize() async throws {
        let require = NativeTaskFixture.require
        let cap = NativeTaskReplyReader.maximumBytes
        func tooLarge(_ pieces: [TaskLimitsWire.Piece], _ what: String) async throws {
            let wire = try await TaskLimitsWire(pieces: pieces, closes: false)
            defer { wire.stop() }
            do {
                _ = try await limitsComplete(wire, job: limitsJob(), limits: NativeTaskTransportLimits(connectAndSend: 10, firstReply: 10, replyIdle: 10, request: 60))
                throw NativeTaskFixture.Failure.assertion("\(what) must fail")
            } catch let failure as NativeTaskGenerationFailure {
                try require(failure.code == "response_too_large", "\(what) is too large: \(failure.code)")
            }
        }
        let opening = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"".utf8)
        try await tooLarge([.init(at: 0, bytes: opening + Data(repeating: 97, count: cap + 1024))], "An unterminated data line over the cap")
        try await tooLarge([.init(at: 0, bytes: TaskLimitsWire.event(["content": String(repeating: "b", count: cap + 1024)]))],
                           "A single event over the cap")
        let thinking = (0..<(cap / 100_000 + 2)).map { index in
            TaskLimitsWire.Piece(at: Double(index) * 0.02, bytes: TaskLimitsWire.event(["reasoning_content": String(repeating: "r", count: 100_000)]))
        }
        try await tooLarge(thinking + [.init(at: Double(thinking.count) * 0.02, bytes: TaskLimitsWire.event(["content": "ok"]))], "Reasoning over the cap")
        let named = (0..<2).map { index in
            TaskLimitsWire.Piece(at: Double(index) * 0.02, bytes: TaskLimitsWire.event(["tool_calls": [
                ["index": index, "id": String(repeating: "i", count: cap / 2 + 1024), "function": ["name": "lookup", "arguments": "{}"]]]]))
        }
        try await tooLarge(named, "Call identifiers over the cap")
        let many = TaskLimitsWire.event(["tool_calls": (0...NativeTaskReplyReader.maximumCalls).map { index in
            ["index": index, "id": "call-\(index)", "function": ["name": "lookup", "arguments": "{}"]] as [String: Any]
        }])
        try await tooLarge([.init(at: 0, bytes: many)], "More calls than a reply may carry")

        let word = "abcdefghi "
        let text = String(repeating: word, count: 1000)
        let framing = Data((":" + String(repeating: " ", count: cap / 16) + "\n\n").utf8)
        let batch = framing + TaskLimitsWire.event(["content": text])
        let batches = 20
        var pieces = [TaskLimitsWire.Piece(at: 0, bytes: TaskLimitsWire.event(["role": "assistant", "content": ""]))]
        pieces += (0..<batches).map { TaskLimitsWire.Piece(at: Double($0) * 0.02, bytes: batch) }
        pieces += [.init(at: 0.5, bytes: TaskLimitsWire.event([:], finish: "stop")), .init(at: 0.5, bytes: TaskLimitsWire.done)]
        let raw = pieces.reduce(0) { $0 + $1.bytes.count }
        let wire = try await TaskLimitsWire(pieces: pieces)
        defer { wire.stop() }
        let report = try await limitsComplete(wire, job: limitsJob(),
            limits: NativeTaskTransportLimits(connectAndSend: 10, firstReply: 10, replyIdle: 10, request: 60))
        try require(raw > cap && report.content == String(repeating: text, count: batches) && report.content.utf8.count < cap,
                    "A long report whose stream framing passes the cap still completes: \(raw)")
    }

    private static func limitsTemplateOptions() async throws {
        let require = NativeTaskFixture.require
        func sent(template: String?, kwargs: [NativeChatRequestOptions.Entry]) async throws -> [String: Any]? {
            let wire = try await TaskLimitsWire(pieces: TaskLimitsWire.streamed(["ok"], every: 0, from: 0))
            defer { wire.stop() }
            _ = try await limitsComplete(wire, job: limitsJob(), template: template, kwargs: kwargs)
            let object = wire.bodies.first.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return object.map { $0["chat_template_kwargs"] as? [String: Any] ?? [:] }
        }
        let saved = try await sent(template: "{\"enable_thinking\":false}", kwargs: [])
        try require(saved?["enable_thinking"] as? Bool == false, "Saved chat template options reach the request")
        let resolved = try await sent(template: nil, kwargs: [.init(key: "enable_thinking", value: .bool(true), source: .saved)])
        try require(resolved?["enable_thinking"] as? Bool == true, "Resolved template options reach the request")
        let none = try await sent(template: nil, kwargs: [])
        try require(none?.isEmpty == true, "A profile with no template options sends none")
    }

    private static func limitsQueuedRequest() async throws {
        let require = NativeTaskFixture.require
        let arbiter = NativeInferenceArbiter(cooldown: 0)
        let admission = NativeInferenceAdmission.local(arbiter)
        let endpoint = URL(string: "https://queued.test/v1")!
        let resource = try NativeInferenceAdmission.resource(for: endpoint)
        let foreground = try await arbiter.acquire(resource: resource, priority: .foreground, queueSeconds: 1)
        let queuedAt = ContinuousClock.now
        let queued = Task { () -> (Double, Double) in
            try await admission.perform(endpoint: endpoint, priority: .background, requestedSeconds: 30, queueSeconds: 20) { budget in
                (budget.seconds, nativeTaskSeconds(queuedAt.duration(to: .now)))
            }
        }
        try await Task.sleep(for: .seconds(0.6))
        await arbiter.release(foreground)
        let (granted, waited) = try await queued.value
        try require(waited >= 0.6 && granted == 30,
                    "A request that waited behind foreground work still gets its full window: \(granted) after \(waited)")
        let foregroundAgain = try await arbiter.acquire(resource: resource, priority: .foreground, queueSeconds: 1)
        let gaveUp = Task { () -> String in
            try await admission.perform(endpoint: endpoint, priority: .background, requestedSeconds: 5, queueSeconds: 0.2) { _ in "ran" }
        }
        do {
            _ = try await gaveUp.value
            throw NativeTaskFixture.Failure.assertion("A request queued past its wait must give up")
        } catch NativeInferenceAdmission.AdmissionError.deadline {}
        await arbiter.release(foregroundAgain)
    }
}
