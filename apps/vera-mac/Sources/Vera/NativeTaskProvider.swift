import Foundation

struct NativeTaskProvider {
    static func complete(config: NativeChatConfig, binding: NativeTaskProfileBinding,
                         job: NativeTaskGenerationJob,
                         limits: NativeTaskTransportLimits = .init(),
                         diagnostics: @escaping @Sendable (NativeTaskTransportTiming) -> Void = NativeTaskTransportTiming.log) async throws -> String {
        let result = try await completion(config: config, binding: binding, job: job, limits: limits, diagnostics: diagnostics)
        guard result.toolCalls.isEmpty else { throw NativeTaskGenerationFailure(code: "provider_response") }
        return result.content
    }

    static func completion(config: NativeChatConfig, binding: NativeTaskProfileBinding,
                           job: NativeTaskGenerationJob,
                           limits: NativeTaskTransportLimits = .init(),
                           protocolClasses: [AnyClass] = [],
                           diagnostics: @escaping @Sendable (NativeTaskTransportTiming) -> Void = NativeTaskTransportTiming.log) async throws -> NativeTaskGenerationCompletion {
        let started = ContinuousClock.now
        guard try NativeTaskEngineIdentity(config.baseURL) == binding.provider,
              config.model == binding.executionModel else {
            throw NativeTaskGenerationFailure(code: "profile_changed")
        }
        var options = NativeChatRequestOptions.none
        let sampling: Set<String> = ["temperature", "top_p", "top_k", "min_p", "seed", "frequency_penalty", "presence_penalty", "repetition_penalty"]
        options.topLevel = config.options.topLevel.filter { entry in
            guard sampling.contains(entry.key), case .number(let number) = entry.value else { return false }
            return number.isFinite
        }
        if let entry = config.options.topLevel.first(where: { $0.key == "reasoning" }),
           case .object(let values) = entry.value {
            var reasoning: [String: NativeJSONValue] = [:]
            if case .bool(let enabled) = values["enabled"] { reasoning["enabled"] = .bool(enabled) }
            if case .string(let effort) = values["effort"],
               ["none", "minimal", "low", "medium", "high"].contains(effort) { reasoning["effort"] = .string(effort) }
            if !reasoning.isEmpty { options.topLevel.append(.init(key: "reasoning", value: .object(reasoning), source: .saved)) }
        }
        if let limit = NativeTaskConfiguration.outputLimit(config.options) {
            options.topLevel.append(.init(key: "max_tokens", value: .number(Double(limit)), source: .saved))
        }
        options.kwargs = config.options.kwargs
        let bounded = NativeChatConfig(baseURL: binding.provider.base, apiKey: config.apiKey,
            model: binding.executionModel, chatTemplateKwargs: config.chatTemplateKwargs,
            streaming: true, options: options)
        let client = NativeChatClient(config: bounded, admission: nil)
        guard limits.valid, let phase = NativeTaskTransportTiming.Phase(jobPhase: job.phase) else {
            throw NativeTaskGenerationFailure(code: "provider_response")
        }
        var request = try client.request(messages: job.messages.map {
                NativeChatMessage(role: $0.role, content: $0.content, toolCallID: $0.toolCallID, toolCalls: $0.toolCalls ?? [])
            }, model: binding.executionModel, tools: job.tools ?? [])
        if job.toolChoice == "none", job.tools != nil, let body = request.httpBody,
           var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            object["tool_choice"] = "none"
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
        }
        let remaining = try job.reducingDeadline(by: nativeTaskSeconds(started.duration(to: .now))).deadlineSeconds
        request.timeoutInterval = remaining
        let observer = NativeTaskTransportObserver(phase: phase, expectedBytes: request.httpBody?.count ?? 0, overallSeconds: remaining, sink: diagnostics)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = remaining
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? []) }
        let session = OutboundGuard.session(configuration: configuration, delegate: observer, delegateQueue: nil)
        let setupTimer = Task {
            do { try await Task.sleep(for: .seconds(min(limits.connectAndSend, remaining))) } catch { return }
            if observer.finish(.connect_send_timeout, onlyBeforeSetup: true) { session.invalidateAndCancel() }
        }
        let overallTimer = Task {
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            if observer.finish(.overall_timeout) { session.invalidateAndCancel() }
        }
        let readTimer = Task {
            while observer.outcome == nil {
                do { try await Task.sleep(for: .seconds(min(0.05, limits.firstReply / 4, limits.replyIdle / 4))) } catch { return }
                if observer.finishIfStalled(limits) { session.invalidateAndCancel(); return }
            }
        }
        defer {
            readTimer.cancel()
            setupTimer.cancel()
            overallTimer.cancel()
            session.invalidateAndCancel()
        }
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let (bytes, response) = try await session.bytes(for: request, delegate: observer)
                guard let response = response as? HTTPURLResponse else { throw NativeTaskGenerationFailure(code: "response_unreadable") }
                observer.received(response)
                guard (200..<300).contains(response.statusCode) else {
                    throw NativeTaskGenerationFailure(code: failureCode(status: response.statusCode))
                }
                var reader = NativeTaskReplyReader()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    observer.receivedBytes()
                    if try reader.append(byte) { observer.replied() }
                    if reader.finished { break }
                }
                return try completed(reader.snapshot(), job: job)
            } onCancel: {
                observer.finish(.canceled)
                session.invalidateAndCancel()
            }
            try Task.checkCancellation()
            guard started.duration(to: .now) < .seconds(job.deadlineSeconds), observer.outcome == nil else {
                observer.finish(.overall_timeout)
                throw NativeTaskGenerationFailure(code: "request_timeout")
            }
            guard observer.finish(.completed), observer.outcome == .completed else {
                throw NativeTaskGenerationFailure(code: "request_timeout")
            }
            return result
        } catch {
            func failure(_ code: String, finishReason: String? = nil) -> NativeTaskGenerationFailure {
                NativeTaskGenerationFailure(code: code, detail: NativeTaskGenerationFailureDetail(
                    phase: job.phase, httpStatus: observer.httpStatus, finishReason: finishReason))
            }
            if Task.isCancelled || error is CancellationError {
                observer.finish(.canceled)
                throw CancellationError()
            }
            if let outcome = observer.outcome, NativeTaskTransportObserver.timedOut.contains(outcome) {
                throw failure("request_timeout")
            }
            if let error = error as? NativeTaskGenerationFailure {
                observer.finish(NativeTaskTransportTiming.Outcome(rawValue: error.code) ?? .provider_response)
                throw failure(error.code, finishReason: error.detail?.finishReason)
            }
            if let error = error as? URLError, error.code == .timedOut {
                observer.finish(.transport_timeout)
                throw failure("request_timeout")
            }
            observer.finish(.provider_unavailable)
            throw failure("provider_unavailable")
        }
    }

    static func snapshot(from data: Data) throws -> NativeChatStreamSnapshot {
        do {
            return try NativeChatClient.completeSnapshot(from: data)
        } catch let error as NativeChatClient.ClientError {
            if case .provider = error { throw NativeTaskGenerationFailure(code: "provider_error") }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choice = (object["choices"] as? [[String: Any]])?.first,
               choice["finish_reason"] as? String == "length" {
                throw cutShort()
            }
            throw NativeTaskGenerationFailure(code: "response_unreadable")
        }
    }

    static func cutShort() -> NativeTaskGenerationFailure {
        NativeTaskGenerationFailure(code: "response_cut_short", detail: NativeTaskGenerationFailureDetail(phase: nil, finishReason: "length"))
    }

    static func failureCode(status: Int) -> String {
        if status == 401 || status == 403 { return "provider_auth" }
        if status == 402 || status == 429 { return "provider_quota" }
        return "provider_unavailable"
    }

    static func completed(_ snapshot: NativeChatStreamSnapshot, job: NativeTaskGenerationJob) throws -> NativeTaskGenerationCompletion {
        if snapshot.finishReason == "length" { throw cutShort() }
        guard job.tools != nil else { return .text(try completedText(snapshot)) }
        let finish = snapshot.finishReason ?? ""
        return try NativeTaskGenerationCompletion(content: snapshot.content, toolCalls: snapshot.toolCalls,
                                                  finishReason: finish).validated(for: job)
    }

    static func completedText(_ snapshot: NativeChatStreamSnapshot) throws -> String {
        func failure(_ code: String) -> NativeTaskGenerationFailure {
            NativeTaskGenerationFailure(code: code, detail: NativeTaskGenerationFailureDetail(phase: nil, finishReason: snapshot.finishReason))
        }
        if snapshot.finishReason == "length" { throw failure("response_cut_short") }
        guard snapshot.toolCalls.isEmpty else { throw failure("response_tool_calls") }
        guard snapshot.finishReason == "stop" else { throw failure("response_finish") }
        guard !snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("response_empty") }
        guard snapshot.content.utf8.count <= 262144 else { throw failure("response_too_large") }
        return snapshot.content
    }
}

struct NativeTaskReplyReader {
    static let maximumBytes = 1048576

    private enum Mode { case undecided, body, events }

    private var mode = Mode.undecided
    private var body = Data()
    private var pending = Data()
    private var decoder = ChatSSEDecoder()
    private var accumulator = NativeChatDeltaAccumulator()
    private var latest = NativeChatStreamSnapshot(content: "", toolCalls: [], finishReason: nil)
    private var finishReason: String?
    private(set) var finished = false
    private var done = false
    private var eventBytes = 0
    private var reasoningBytes = 0
    private var window: UInt32 = 0

    mutating func append(_ byte: UInt8) throws -> Bool {
        var started = false
        if mode == .undecided, ![9, 10, 13, 32].contains(byte) {
            if byte == 123 || byte == 91 {
                mode = .body
                started = true
            } else {
                mode = .events
                body.removeAll()
            }
        }
        if mode != .events {
            body.append(byte)
            guard body.count <= Self.maximumBytes else { throw NativeTaskGenerationFailure(code: "response_too_large") }
            return started
        }
        pending.append(byte)
        eventBytes += 1
        window = window << 8 | UInt32(byte)
        if window & 0xFFFF == 0x0A0A || window == 0x0D0A0D0A { eventBytes = 0 }
        guard eventBytes <= Self.maximumBytes else { throw NativeTaskGenerationFailure(code: "response_too_large") }
        guard byte == 10 else { return false }
        return try drain(finishing: false)
    }

    private mutating func drain(finishing: Bool) throws -> Bool {
        var replied = false
        let payloads: [String]
        do { payloads = try decoder.feed(pending, finishing: finishing) }
        catch { throw NativeTaskGenerationFailure(code: "response_unreadable") }
        pending.removeAll(keepingCapacity: true)
        for payload in payloads where !done {
            if payload == "[DONE]" { done = true; finished = true; break }
            let (kind, reasoning) = Self.kind(of: payload)
            if kind == .bookkeeping { continue }
            reasoningBytes += reasoning
            if kind == .reply { replied = true }
            do { latest = try accumulator.consume(payload) }
            catch let error as NativeChatClient.ClientError {
                if case .provider = error { throw NativeTaskGenerationFailure(code: "provider_error") }
                throw NativeTaskGenerationFailure(code: "response_unreadable")
            }
            if let reason = latest.finishReason { finishReason = reason }
            let size = reasoningBytes + latest.content.utf8.count
                + latest.toolCalls.reduce(0) { $0 + $1.arguments.utf8.count + $1.name.utf8.count }
            guard size <= Self.maximumBytes else { throw NativeTaskGenerationFailure(code: "response_too_large") }
        }
        return replied
    }

    enum EventKind { case opening, reply, bookkeeping }

    static func kind(of payload: String) -> (EventKind, Int) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return (.reply, 0) }
        if object["error"] != nil { return (.reply, 0) }
        if let choices = object["choices"] as? [Any], choices.isEmpty { return (.bookkeeping, 0) }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return (.reply, 0) }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        let reasoning = ["reasoning_content", "reasoning"].reduce(0) { $0 + ((delta[$1] as? String)?.utf8.count ?? 0) }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty { return (.reply, reasoning) }
        if reasoning > 0 || (delta["content"] as? String)?.isEmpty == false || (delta["tool_calls"] as? [Any])?.isEmpty == false {
            return (.reply, reasoning)
        }
        return (.opening, 0)
    }

    mutating func snapshot() throws -> NativeChatStreamSnapshot {
        switch mode {
        case .undecided, .body:
            return try NativeTaskProvider.snapshot(from: body)
        case .events:
            if !done { _ = try drain(finishing: true) }
            let snapshot = NativeChatStreamSnapshot(content: latest.content, toolCalls: latest.toolCalls, finishReason: finishReason)
            guard done || finishReason != nil else { throw NativeTaskGenerationFailure(code: "response_unreadable") }
            if snapshot.finishReason == "length" { throw NativeTaskProvider.cutShort() }
            if !snapshot.toolCalls.isEmpty,
               snapshot.finishReason != "tool_calls" || snapshot.toolCalls.contains(where: { $0.id.isEmpty || $0.name.isEmpty }) {
                throw NativeTaskGenerationFailure(code: "response_unreadable")
            }
            return snapshot
        }
    }
}
