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
        let rateLimited = NativeChatClient.ClientError.http(429, """
            {"error":{"message":"Provider returned error","code":429,"metadata":{"raw":"rate limit exceeded: 20 requests per minute","provider_name":"Upstream"}}}
            """)
        let unavailable = NativeChatClient.ClientError.http(503, "{\"error\":{\"message\":\"upstream connect error\",\"code\":503}}")

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

        let once = NativeScriptedFailureTransport(failures: [rateLimited])
        let recovering = try store(once)
        recovering.sendText("hello after a hiccup")
        try await settle(recovering, "The retry pause shows Trying once more") {
            recovering.turnStatuses.values.contains(NativeTransientFailure.retryingStatus)
        }
        try await settle(recovering, "A single transient failure recovers into a completed answer") {
            recovering.selected?.messages.last?.state == .complete
        }
        try require(recovering.selected?.messages.last?.text == "Answer after the pause." && recovering.selected?.messages.last?.failure == nil,
                    "The recovered answer carries the full text and no failure")
        try require(once.calls == 2, "Exactly one automatic retry was made")
        try require(!recovering.turnStatuses.values.contains(NativeTransientFailure.retryingStatus), "The retry status clears after recovery")

        let twice = NativeScriptedFailureTransport(failures: [rateLimited, unavailable])
        let failing = try store(twice)
        failing.sendText("hello while the endpoint is down")
        try await settle(failing, "Two transient failures end the answer") { failing.selected?.messages.last?.state == .interrupted }
        guard let failure = failing.selected?.messages.last?.failure else { throw NativeTaskFixture.Failure.assertion("The failed answer explains itself") }
        try require(failure.contains("unavailable") && failure.contains("503") && failure.contains("upstream connect error"),
                    "The failure names the cause, the status and the upstream reason in plain words: \(failure)")
        try require(!failure.contains("{") && !failure.contains("}") && !failure.contains("\""), "The failure text is not raw JSON")
        try require(twice.calls == 2, "A second transient failure is not retried again")
        guard let failingID = failing.selected?.id else { throw NativeTaskFixture.Failure.assertion("The failed chat exists") }
        let stored = try failing.repository?.messages(conversationID: failingID).last?.failure
        try require(stored == failure, "The stored failure text matches what is shown")

        let described = NativeTransientFailure.describe(rateLimited)
        try require(described.hasPrefix("Rate limited by the model endpoint (429)") && described.contains("rate limit exceeded") && described.contains("from Upstream")
                    && !described.contains("{"), "A rate limit is described in plain words with the upstream reason: \(described)")
        let secret = "sk-" + String(repeating: "Qz7", count: 14)
        let leaked = NativeTransientFailure.describe(NativeChatClient.ClientError.http(502, "Bad gateway " + secret).redacting([secret]))
        try require(!leaked.contains(secret), "A redacted error never shows its secret in the failure text")
        try require(!NativeTransientFailure.isTransient(NativeChatClient.ClientError.http(400, "bad request"))
                    && !NativeTransientFailure.isTransient(NativeChatClient.ClientError.interrupted)
                    && NativeTransientFailure.isTransient(NativeChatClient.ClientError.provider("boom", "{}")),
                    "Only rate limits, gateway failures and in-band provider errors count as transient")

        let partial = NativeScriptedFailureTransport(failures: [unavailable], partialFirst: true)
        let streamed = try store(partial)
        streamed.sendText("hello with a partial answer")
        try await settle(streamed, "A failure after streamed content ends the answer without a retry") {
            streamed.selected?.messages.last?.state == .interrupted
        }
        try require(streamed.selected?.messages.last?.text == "Partial answer", "The partial answer is kept")
        try require(streamed.selected?.messages.last?.failure?.contains("unavailable") == true, "The partial answer shows the failure")
        try require(partial.calls == 1, "No automatic retry after content has streamed")
        for s in [recovering, failing, streamed] { s.conversationTurnLoop?.cancel() }
        print("TRANSIENT RETRY OK")
    }
}
