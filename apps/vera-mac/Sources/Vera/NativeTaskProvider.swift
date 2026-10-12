import Foundation

struct NativeTaskProvider {
    static func complete(config: NativeChatConfig, binding: NativeTaskProfileBinding,
                         job: NativeTaskGenerationJob,
                         limits: NativeTaskTransportLimits = .init(),
                         diagnostics: @escaping @Sendable (NativeTaskTransportTiming) -> Void = NativeTaskTransportTiming.log) async throws -> String {
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
        options.topLevel.append(.init(key: "max_tokens", value: .number(Double(binding.limits.maximumOutputTokens)), source: .override))
        let bounded = NativeChatConfig(baseURL: binding.provider.base, apiKey: config.apiKey,
            model: binding.executionModel, chatTemplateKwargs: nil,
            streaming: false, options: options)
        let client = NativeChatClient(config: bounded, admission: nil)
        guard limits.connectAndSend.isFinite, limits.connectAndSend > 0,
              limits.readIdle.isFinite, limits.readIdle > 0,
              let phase = NativeTaskTransportTiming.Phase(rawValue: job.phase) else {
            throw NativeTaskGenerationFailure(code: "provider_response")
        }
        var request = try client.request(messages: job.messages.map { NativeChatMessage(role: $0.role, content: $0.content) },
                                         model: binding.executionModel, tools: [])
        let remaining = try job.reducingDeadline(by: nativeTaskSeconds(started.duration(to: .now))).deadlineSeconds
        request.timeoutInterval = remaining
        let observer = NativeTaskTransportObserver(phase: phase, expectedBytes: request.httpBody?.count ?? 0, overallSeconds: remaining, sink: diagnostics)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = remaining
        let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
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
                do { try await Task.sleep(for: .seconds(min(0.05, limits.readIdle / 4))) } catch { return }
                if observer.finish(.read_idle_timeout, readIdle: limits.readIdle) { session.invalidateAndCancel(); return }
            }
        }
        defer {
            readTimer.cancel()
            setupTimer.cancel()
            overallTimer.cancel()
            session.invalidateAndCancel()
        }
        do {
            let text = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let (bytes, response) = try await session.bytes(for: request, delegate: observer)
                guard let response = response as? HTTPURLResponse else { throw NativeTaskGenerationFailure(code: "provider_response") }
                observer.received(response)
                guard (200..<300).contains(response.statusCode) else {
                    throw NativeTaskGenerationFailure(code: failureCode(status: response.statusCode))
                }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 1048576 else { throw NativeTaskGenerationFailure(code: "provider_response") }
                    observer.receivedByte()
                    data.append(byte)
                }
                return try completedText(NativeChatClient.completeSnapshot(from: data))
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
            return text
        } catch {
            if Task.isCancelled || error is CancellationError {
                observer.finish(.canceled)
                throw CancellationError()
            }
            if let outcome = observer.outcome,
               [.connect_send_timeout, .read_idle_timeout, .overall_timeout, .transport_timeout].contains(outcome) {
                throw NativeTaskGenerationFailure(code: "request_timeout")
            }
            if let error = error as? NativeTaskGenerationFailure {
                observer.finish(NativeTaskTransportTiming.Outcome(rawValue: error.code) ?? .provider_response)
                throw error
            }
            if let error = error as? URLError, error.code == .timedOut {
                observer.finish(.transport_timeout)
                throw NativeTaskGenerationFailure(code: "request_timeout")
            }
            observer.finish(.provider_unavailable)
            throw NativeTaskGenerationFailure(code: "provider_unavailable")
        }
    }

    static func failureCode(status: Int) -> String {
        if status == 401 || status == 403 { return "provider_auth" }
        if status == 402 || status == 429 { return "provider_quota" }
        return "provider_unavailable"
    }

    static func completedText(_ snapshot: NativeChatStreamSnapshot) throws -> String {
        guard snapshot.finishReason == "stop", snapshot.toolCalls.isEmpty,
              !snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              snapshot.content.utf8.count <= 262144 else {
            throw NativeTaskGenerationFailure(code: "provider_response")
        }
        return snapshot.content
    }
}
