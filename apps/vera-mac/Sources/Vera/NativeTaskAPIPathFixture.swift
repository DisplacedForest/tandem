import Foundation

@MainActor
enum NativeTaskAPIPathFixture {
    struct Configuration: Decodable {
        let base: URL
        let database: URL
        let mode: String
        let nativeLead: Bool?
        let live: Bool?
    }

    static func run(_ raw: String) async throws {
        let input = try JSONDecoder().decode(Configuration.self, from: Data(raw.utf8))
        guard input.base.scheme == "http", ["localhost", "127.0.0.1"].contains(input.base.host ?? ""),
              input.database.isFileURL, ["create", "recover", "cancel"].contains(input.mode) else {
            throw NativeTaskHTTPError.invalidResponse
        }
        let repository = try LocalChatRepository(url: input.database)
        let config = NativeChatConfig(baseURL: input.base.appendingPathComponent("v1"),
            apiKey: "synthetic-fixture-key", model: "fixture-model", chatTemplateKwargs: nil, streaming: false)
        var settings = NativeChatSettings.fresh
        settings.profiles = [NativeEndpointProfile(id: "fixture-profile", name: "Fixture", baseURL: config.baseURL.absoluteString,
            discoveredModels: [config.model], selectedModel: config.model, selectionBasis: .user, lastDiscoveryAt: nil)]
        settings.activeProfileID = "fixture-profile"
        let capturedSettings = settings
        let taskConfiguration: NativeTaskConfiguration
        let enrollment: NativeTaskProfileBinding?
        if input.live == true {
            let saved = NativeChatSettings.load(from: ConfigFile.read())
            guard let profile = saved.activeProfile, let url = URL(string: profile.baseURL),
                  url.scheme == "https", url.host == "openrouter.ai", url.path == "/api/v1" else {
                throw NativeTaskHTTPError.invalidResponse
            }
            enrollment = NativeTaskProfileBinding(id: UUID().uuidString, profileID: profile.id,
                provider: try NativeTaskEngineIdentity(url), savedModel: profile.selectedModel,
                executionModel: "qwen/qwen3.8-flash", limits: try NativeTaskGenerationLimits(), requiresCredential: true)
            var options = NativeChatRequestOptions.none
            options.topLevel = [.init(key: "reasoning", value: .object(["enabled": .bool(false)]), source: .override)]
            taskConfiguration = NativeTaskConfiguration(settings: { NativeChatSettings.load(from: ConfigFile.read()) },
                generationOptions: options)
            guard taskConfiguration.isAvailable(enrollment!) else { throw NativeTaskGenerationFailure(code: "credential_unavailable") }
        } else {
            enrollment = nil
            taskConfiguration = NativeTaskConfiguration(settings: { capturedSettings }, credential: { _ in "synthetic-fixture-key" })
        }
        let call = NativeChatToolCall(id: "synthetic-tool-call", name: NativeTaskTools.toolName,
            arguments: "{\"worker_type\":\"research\",\"objective\":\"What color is the fictional moon Luma?\",\"deliverables\":[\"A cited answer\"]}")
        let lead = ScriptedNativeToolTransport(rounds: [
            [.init(content: "", toolCalls: [call], finishReason: "tool_calls")],
            [.init(content: "Research has started. You can keep chatting.", toolCalls: [], finishReason: "stop")],
            [.init(content: "I'm still here while research runs.", toolCalls: [], finishReason: "stop")],
        ])
        let measurements = NativeTaskLeadMeasurements()
        let transport: any NativeChatTransport = input.nativeLead == true
            ? NativeTaskMeasuredTransport(transport: NativeChatClient(config: config,
                admission: NativeInferenceAdmission(baseURL: input.base)), measurements: measurements) : lead
        let store = ChatStore(veraAPI: VeraAPIClient(base: input.base), nativeConfig: config,
            nativeTransport: transport, repository: repository, nativeEnabledToolIDs: [NativeWebTools.researchToolID],
            pulseFeed: SelfTestPulseFeed(.success(cards: [], rawIDs: [])),
            nativeTaskConfiguration: taskConfiguration,
            nativeResearchOptions: NativeTaskResearchOptions(subquestions: 1, pagesPerQuestion: 0),
            nativeTaskEnrollment: enrollment)
        defer { store.stopNativeTaskRecovery() }
        await store.connect()
        if input.mode != "recover" {
            let started = ContinuousClock.now
            store.sendText("Research the fictional moon Luma in the background.")
            try await wait(seconds: 8) { !store.generating }
            guard let reference = try repository.taskReferences(conversationID: nil).first,
                  reference.deliveryState == .accepted || reference.deliveryState == .pending else {
                throw NativeTaskFixture.Failure.assertion("Handoff was not saved")
            }
            emit(["event": "ack", "seconds": nativeTaskSeconds(started.duration(to: .now)),
                  "delivery": reference.deliveryState.rawValue, "first_content_seconds": measurements.snapshot().first ?? 0])
            store.sendText("Can you still respond while research runs?")
            try await wait(seconds: 5) { !store.generating }
            guard store.selected?.messages.last?.text == "I'm still here while research runs." else {
                throw NativeTaskFixture.Failure.assertion("Second typed chat turn failed")
            }
            var request = URLRequest(url: input.base.appendingPathComponent("fixture/chat"))
            request.httpMethod = "POST"
            _ = try await URLSession.shared.data(for: request)
            emit(["event": "chat", "seconds": nativeTaskSeconds(started.duration(to: .now)),
                  "first_content_seconds": measurements.snapshot().last ?? 0])
        }
        if input.mode == "cancel" {
            _ = try await URLSession.shared.data(from: input.base.appendingPathComponent("fixture/provider-started"))
            guard let reference = try repository.taskReferences(conversationID: nil).first,
                  let service = store.nativeTaskService else { throw NativeTaskHTTPError.invalidResponse }
            _ = try await service.requestCancellation(reference.id)
        }
        let client = NativeTaskClient.live
        let deadline = ContinuousClock.now.advanced(by: .seconds(input.live == true ? 140 : 15))
        while ContinuousClock.now < deadline {
            if let reference = try repository.taskReferences(conversationID: nil).first, reference.remoteTaskID != nil {
                let snapshot = try await client.fetch(reference)
                _ = try repository.acknowledgeTaskReference(id: reference.id, snapshot: snapshot)
                if snapshot.state.isTerminal || snapshot.state == .needsDecision {
                    emit(["event": "finished", "state": snapshot.state.rawValue,
                          "report": snapshot.result?.report ?? "", "request_id": reference.id.uuidString])
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NativeTaskFixture.Failure.assertion("Research fixture exceeded its deadline")
    }

    static func wait(seconds: Double, until: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !until() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try NativeTaskFixture.require(until(), "Typed fixture exceeded its deadline")
    }

    static func emit(_ value: [String: Any]) {
        if let data = try? NativeTaskClient.canonical(value) {
            FileHandle.standardOutput.write(Data("TASK_FIXTURE ".utf8) + data + Data("\n".utf8))
        }
    }
}

final class NativeTaskLeadMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; values.append(seconds) }
    func snapshot() -> [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

struct NativeTaskMeasuredTransport: NativeChatTransport {
    let transport: any NativeChatTransport
    let measurements: NativeTaskLeadMeasurements
    func discoverModels() async throws -> [String] { try await transport.discoverModels() }
    func stream(messages: [NativeChatMessage], model: String,
                tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let operation = Task {
                let started = ContinuousClock.now
                var measured = false
                do {
                    for try await snapshot in transport.stream(messages: messages, model: model, tools: tools) {
                        if !measured && !snapshot.content.isEmpty {
                            measured = true
                            measurements.append(nativeTaskSeconds(started.duration(to: .now)))
                        }
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in operation.cancel() }
        }
    }
}
