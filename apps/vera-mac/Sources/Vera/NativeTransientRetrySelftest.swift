import Foundation

final class NativeScriptedFailureTransport: NativeChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let failures: [Error]
    private let partialFirst: Bool
    private var started = 0
    var calls: Int { lock.withLock { started } }

    init(failures: [Error], partialFirst: Bool = false) {
        self.failures = failures
        self.partialFirst = partialFirst
    }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        let index = lock.withLock { () -> Int in
            started += 1
            return started - 1
        }
        return AsyncThrowingStream { continuation in
            if partialFirst, index == 0 {
                continuation.yield(NativeChatStreamSnapshot(content: "Partial answer", toolCalls: [], finishReason: nil))
                continuation.finish(throwing: failures[0])
                return
            }
            if index < failures.count {
                continuation.finish(throwing: failures[index])
                return
            }
            continuation.yield(NativeChatStreamSnapshot(content: "Answer after the pause.", toolCalls: [], finishReason: "stop"))
            continuation.finish()
        }
    }
}

@MainActor
extension SelfTest {
    static func runTransientRetry() async throws {
        let require = NativeTaskFixture.require
        let configured = "fixture" + "Passphrase" + "7731"
        let shapedKey = "sk-" + String(repeating: "Qz7", count: 14)
        let client = NativeChatClient(config: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: configured,
                                                               model: "local-model", chatTemplateKwargs: nil))
        let upstreamError: [String: Any] = [
            "message": "Provider returned error", "code": 429, "api_key": shapedKey,
            "metadata": ["raw": "rate limit exceeded for \(configured): 20 requests per minute\nretry later", "provider_name": "Upstream"],
        ]
        let body = try JSONSerialization.data(withJSONObject: ["error": upstreamError])
        let rateLimited = NativeChatClient.ClientError.http(429, NativeChatClient.errorDetail(body, secrets: client.redactionSecrets))
        let providerLimited = NativeChatClient.ClientError.provider(upstreamError, secrets: client.redactionSecrets)
        let unavailable = NativeChatClient.ClientError.http(503, NativeChatClient.errorDetail(
            Data("{\"error\":{\"message\":\"upstream connect error\",\"code\":503}}".utf8), secrets: client.redactionSecrets))

        func requireClean(_ text: String, _ label: String) throws {
            try require(text.contains("Rate limited") && text.contains("429") && text.contains("rate limit exceeded") && text.contains("from Upstream"),
                        "\(label) names the cause, the status, the upstream reason and the provider: \(text)")
            try require(!text.contains(configured) && !text.contains(shapedKey) && !text.contains("sk-") && !text.contains("{") && !text.contains("}")
                        && !text.contains("\"") && !text.contains("retry later"), "\(label) carries no key, secret, braces, quotes or extra lines: \(text)")
        }

        func settle(_ store: ChatStore, _ label: String, timeout: Int = 800, _ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<timeout {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NativeTaskFixture.Failure.assertion(label)
        }

        func store(_ transport: NativeScriptedFailureTransport) throws -> ChatStore {
            let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
                repository: try LocalChatRepository(inMemory: true), artifactPersistenceEnabled: false)
            store.newConversation()
            return store
        }

        func reply(_ store: ChatStore) -> UUID? { store.selected?.messages.last(where: { $0.role == .assistant })?.id }

        try requireClean(NativeTransientFailure.describe(rateLimited), "A rate limit read from the response body")
        try requireClean(NativeTransientFailure.describe(providerLimited), "A rate limit reported inside the stream")
        try require(NativeTransientFailure.describe(providerLimited).hasPrefix("Rate limited by the model endpoint (429): "),
                    "An in-band rate limit is described like the HTTP one")

        let once = NativeScriptedFailureTransport(failures: [rateLimited])
        let recovering = try store(once)
        recovering.sendText("hello after a hiccup")
        try await settle(recovering, "The retry pause shows Trying once more on the reply") {
            reply(recovering).flatMap(recovering.replyStatus) == NativeTransientFailure.retryingStatus
        }
        try await settle(recovering, "A single transient failure recovers into a completed answer") {
            recovering.selected?.messages.last?.state == .complete
        }
        try require(recovering.selected?.messages.last?.text == "Answer after the pause." && recovering.selected?.messages.last?.failure == nil,
                    "The recovered answer carries the full text and no failure")
        try require(once.calls == 2, "Exactly one automatic retry was made")
        try require(reply(recovering).flatMap(recovering.replyStatus) == nil
                    && !recovering.turnStatuses.values.contains(NativeTransientFailure.retryingStatus), "The reply status clears after recovery")

        let twice = NativeScriptedFailureTransport(failures: [unavailable, rateLimited])
        let failing = try store(twice)
        failing.sendText("hello while the endpoint is down")
        try await settle(failing, "The reply shows Trying once more before the second attempt") {
            reply(failing).flatMap(failing.replyStatus) == NativeTransientFailure.retryingStatus
        }
        try await settle(failing, "Two transient failures end the answer") { failing.selected?.messages.last?.state == .interrupted }
        guard let failure = failing.selected?.messages.last?.failure else { throw NativeTaskFixture.Failure.assertion("The failed answer explains itself") }
        try requireClean(failure, "The final failure")
        try require(twice.calls == 2, "A second transient failure is not retried again")
        try require(reply(failing).flatMap(failing.replyStatus) == nil, "The reply status clears after the final failure")
        guard let failingID = failing.selected?.id else { throw NativeTaskFixture.Failure.assertion("The failed chat exists") }
        let stored = try failing.repository?.messages(conversationID: failingID).last?.failure
        try require(stored == failure, "The stored failure text matches what is shown")

        let leaked = NativeTransientFailure.describe(NativeChatClient.ClientError.http(502, "Bad gateway " + shapedKey).redacting([shapedKey]))
        try require(!leaked.contains(shapedKey), "A redacted error never shows its secret in the failure text")
        try require(!NativeTransientFailure.isTransient(NativeChatClient.ClientError.http(400, "bad request"))
                    && !NativeTransientFailure.isTransient(NativeChatClient.ClientError.interrupted)
                    && NativeTransientFailure.isTransient(providerLimited),
                    "Only rate limits, gateway failures and in-band provider errors count as transient")

        let partial = NativeScriptedFailureTransport(failures: [providerLimited], partialFirst: true)
        let streamed = try store(partial)
        streamed.sendText("hello with a partial answer")
        try await settle(streamed, "A failure after streamed content ends the answer without a retry") {
            streamed.selected?.messages.last?.state == .interrupted
        }
        try require(streamed.selected?.messages.last?.text == "Partial answer", "The partial answer is kept")
        try requireClean(streamed.selected?.messages.last?.failure ?? "", "The partial answer's failure")
        try require(partial.calls == 1, "No automatic retry after content has streamed")
        try require(reply(streamed).flatMap(streamed.replyStatus) == nil, "The reply status clears when a partial answer fails")
        for s in [recovering, failing, streamed] { s.conversationTurnLoop?.cancel() }
        print("TRANSIENT RETRY OK")
    }
}
