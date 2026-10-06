import Foundation

struct NativeTaskProvider {
    static func complete(config: NativeChatConfig, binding: NativeTaskProfileBinding,
                         job: NativeTaskGenerationJob) async throws -> String {
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = job.deadlineSeconds
        configuration.timeoutIntervalForResource = job.deadlineSeconds
        let session = URLSession(configuration: configuration, delegate: NativeTaskRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            try Task.checkCancellation()
            var request = try client.request(messages: job.messages.map { NativeChatMessage(role: $0.role, content: $0.content) },
                                             model: binding.executionModel, tools: [])
            request.timeoutInterval = try job.reducingDeadline(
                by: nativeTaskSeconds(started.duration(to: .now))).deadlineSeconds
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw NativeTaskGenerationFailure(code: "provider_response") }
            guard (200..<300).contains(response.statusCode) else {
                throw NativeTaskGenerationFailure(code: failureCode(status: response.statusCode))
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1048576 else { throw NativeTaskGenerationFailure(code: "provider_response") }
                data.append(byte)
            }
            return try completedText(NativeChatClient.completeSnapshot(from: data))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NativeTaskGenerationFailure {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw NativeTaskGenerationFailure(code: "request_timeout")
        } catch {
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
