import Foundation

final class SelfTestOutageMemoryService: NativeMemoryServing, @unchecked Sendable {
    private let lock = NSLock()
    fileprivate var embeds = 0
    fileprivate var extracts = 0
    var failing = true

    var embedCalls: Int { lock.lock(); defer { lock.unlock() }; return embeds }
    var extractionCalls: Int { lock.lock(); defer { lock.unlock() }; return extracts }

    private func outage() -> NativeMemoryServiceError {
        .unavailable("The memory endpoint could not be reached: connection refused")
    }

    private func count(_ keyPath: ReferenceWritableKeyPath<SelfTestOutageMemoryService, Int>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self[keyPath: keyPath] += 1
        return failing
    }

    private var shouldFail: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failing
    }

    func embed(_ text: String) async throws -> [Double] {
        if count(\.embeds) { throw outage() }
        return [1, 0]
    }

    func probe() async throws -> [String] {
        if shouldFail { throw outage() }
        return ["embed-model", "extract-model"]
    }

    func proposals(
        user: String, assistant: String, sourceConversationID: String?, sourceMessageID: String?,
        existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] {
        if count(\.extracts) { throw outage() }
        return [NativeMemoryProposal(
            id: UUID().uuidString, kind: .create, title: "Queued preference",
            summary: "Prefers tea", details: ["The user prefers tea"],
            group: .profile, category: .preference, bank: "personal", durability: .durable,
            expiry: nil, targetIDs: [], sourceConversationID: sourceConversationID,
            sourceMessageID: sourceMessageID, createdAt: now, status: .pending)]
    }

    func proposal(
        request: String, existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] {
        if count(\.extracts) { throw outage() }
        return []
    }
}

final class MemoryEndpointWireState: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(path: String, body: [String: Any]?)] = []
    var modelsStatus = 200

    var requests: [(path: String, body: [String: Any]?)] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ path: String, _ body: [String: Any]?) { lock.lock(); recorded.append((path, body)); lock.unlock() }
    func reset() { lock.lock(); recorded = []; modelsStatus = 200; lock.unlock() }
}

final class MemoryEndpointWire: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let state = MemoryEndpointWireState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable && data.count < 65536 {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        Self.state.record(url.path, input)
        var status = 200
        let body: [String: Any]
        if url.path.hasSuffix("/rerank") {
            body = ["model": input?["model"] ?? "", "results": [
                ["index": 1, "relevance_score": 0.91], ["index": 0, "relevance_score": 0.12], ["index": 9, "relevance_score": 0.5],
            ]]
        } else if url.path.hasSuffix("/models") {
            status = Self.state.modelsStatus
            body = ["object": "list", "data": [["id": "qwen3-embedding"], ["id": "qwen3-reranker"]]]
        } else if url.path.hasSuffix("/embeddings") {
            body = ["data": [["embedding": [0.5, 0.5]]]]
        } else {
            body = ["error": ["message": "unexpected"]]
            status = 500
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
extension SelfTest {
    static func runNativeMemoryEndpoint() async {
        func fail(_ message: String) -> Never {
            print("SELFTEST ERROR: memory endpoint \(message)"); exit(1)
        }
        var memory = NativeMemorySettings.fresh
        memory.enabled = true
        memory.embeddingsModel = "qwen3-embedding"
        memory.extractionModel = "qwen3-30b"
        let endpoint = NativeMemoryEndpointSettings(baseURL: "http://memory.example:11434/v1", rerankModel: "qwen3-reranker")
        guard let resolved = NativeMemoryEndpointConfig.resolve(endpoint: endpoint, memory: memory, apiKey: " secret ", environment: [:]),
              resolved.baseURL.absoluteString == "http://memory.example:11434/v1", resolved.apiKey == "secret",
              resolved.embeddingsModel == "qwen3-embedding", resolved.extractionModel == "qwen3-30b", resolved.rerankModel == "qwen3-reranker" else {
            fail("resolution")
        }
        guard NativeMemoryEndpointConfig.resolve(endpoint: .fresh, memory: memory, apiKey: "k", environment: [:]) == nil,
              NativeMemoryEndpointConfig.resolve(endpoint: NativeMemoryEndpointSettings(baseURL: "http://memory.example:11434"), memory: memory, apiKey: "", environment: [:]) == nil,
              NativeMemoryEndpointConfig.resolve(endpoint: .fresh, memory: memory, apiKey: "",
                  environment: ["VERA_MEMORY_BASE": "https://env.example/v1", "VERA_MEMORY_RERANK_MODEL": "env-rerank", "VERA_MEMORY_API_KEY": "env-key"])
                  .map { $0.baseURL.host == "env.example" && $0.rerankModel == "env-rerank" && $0.apiKey == "env-key" } == true else {
            fail("unset, malformed and environment cases")
        }

        let chatCoupled: [String: Any] = ["native_chat": [
            "version": 3,
            "profiles": [
                ["id": "tower", "name": "Tower", "baseURL": "http://tower.example:11434/v1", "discoveredModels": ["qwen3-embedding", "qwen3-30b"], "selectedModel": "qwen3-30b"],
                ["id": "cloud", "name": "Cloud", "baseURL": "https://cloud.example/api/v1", "discoveredModels": ["cloud-model"], "selectedModel": "cloud-model"],
            ],
            "activeProfileID": "tower",
            "memory": ["enabled": true, "embeddingsModel": "qwen3-embedding", "extractionModel": "qwen3-30b", "bankScope": "all", "searchPastChats": false, "generateFromChats": true],
        ]]
        let migrated = NativeChatSettings.load(from: chatCoupled)
        guard NativeChatSettings.needsMemoryEndpointMigration(chatCoupled),
              migrated.memoryEndpoint.baseURL == "http://tower.example:11434/v1",
              migrated.memoryEndpoint.discoveredModels == ["qwen3-embedding", "qwen3-30b"],
              migrated.memoryEndpoint.rerankModel.isEmpty else {
            fail("settings migration")
        }
        var disabled = chatCoupled
        var nativeChat = disabled["native_chat"] as! [String: Any]
        nativeChat["memory"] = ["enabled": false, "embeddingsModel": "qwen3-embedding", "extractionModel": "", "bankScope": "all", "searchPastChats": false, "generateFromChats": false]
        disabled["native_chat"] = nativeChat
        var alreadySet = chatCoupled
        nativeChat = alreadySet["native_chat"] as! [String: Any]
        nativeChat["memoryEndpoint"] = ["baseURL": "", "rerankModel": "", "discoveredModels": []]
        alreadySet["native_chat"] = nativeChat
        guard !NativeChatSettings.needsMemoryEndpointMigration(disabled), NativeChatSettings.load(from: disabled).memoryEndpoint.baseURL.isEmpty,
              !NativeChatSettings.needsMemoryEndpointMigration(alreadySet), NativeChatSettings.load(from: alreadySet).memoryEndpoint.baseURL.isEmpty else {
            fail("migration guards")
        }

        let credentials = NativeCredentialFixtureStore()
        credentials.values["tower"] = "tower-key"
        final class Written: @unchecked Sendable { var configs: [[String: Any]] = [] }
        let written = Written()
        let config = ConfigStore(credentialStore: credentials, readConfiguration: { chatCoupled },
                                 writeConfiguration: { written.configs.append($0) })
        guard config.memoryEndpointAPIKey == "tower-key",
              config.memoryEndpointResolved?.baseURL.absoluteString == "http://tower.example:11434/v1",
              config.nativeMemoryService?.configuration.baseURL.absoluteString == "http://tower.example:11434/v1",
              config.nativeMemoryService?.configuration.embeddingsModel == "qwen3-embedding",
              config.nativeMemoryService?.configuration.apiKey == "tower-key" else {
            fail("config store migration")
        }
        guard let firstWrite = written.configs.first,
              let writtenChat = firstWrite["native_chat"] as? [String: Any],
              let writtenEndpoint = writtenChat["memoryEndpoint"] as? [String: Any],
              writtenEndpoint["baseURL"] as? String == "http://tower.example:11434/v1" else {
            fail("migrated endpoint persisted at startup")
        }
        do { try config.save() } catch { fail("save \(error)") }
        guard credentials.values[ConfigStore.memoryCredentialID] == "tower-key" else { fail("credential copied to the memory id") }
        for configuration in written.configs {
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: configuration), as: UTF8.self)
            if text.contains("tower-key") { fail("key leaked into config.json") }
        }
        config.nativeSettings.activeProfileID = "cloud"
        guard config.nativeResolved?.baseURL.host == "cloud.example",
              config.nativeMemoryService?.configuration.baseURL.host == "tower.example",
              config.memoryEndpointLocation?.hasPrefix("Memory endpoint: tower.example") == true else {
            fail("chat profile switch moved memory")
        }
        config.nativeSettings.memoryEndpoint.baseURL = ""
        guard config.nativeMemoryService == nil, config.memoryEndpointLocation == nil else { fail("unset endpoint still resolves") }
        config.nativeSettings.memoryEndpoint.baseURL = "https://memory.example/v1"
        config.memoryEndpointAPIKey = "memory-key"
        do { try config.save() } catch { fail("save after key change \(error)") }
        guard credentials.values[ConfigStore.memoryCredentialID] == "memory-key",
              config.nativeMemoryService?.configuration.apiKey == "memory-key" else { fail("memory key update") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemoryEndpointWire.self]
        let session = URLSession(configuration: configuration)
        let wired = NativeMemoryService(configuration: NativeMemoryServiceConfiguration(
            baseURL: URL(string: "https://memory.example/v1")!, apiKey: "memory-key",
            embeddingsModel: "qwen3-embedding", extractionModel: "", rerankModel: "qwen3-reranker"), session: session)
        do {
            MemoryEndpointWire.state.reset()
            let scores = try await wired.rerank(query: "coffee", documents: ["a red car", "espresso beans"])
            guard scores == [NativeMemoryRerankScore(index: 1, score: 0.91), NativeMemoryRerankScore(index: 0, score: 0.12)],
                  let call = MemoryEndpointWire.state.requests.first, call.path == "/v1/rerank",
                  call.body?["model"] as? String == "qwen3-reranker", (call.body?["documents"] as? [String])?.count == 2,
                  call.body?["top_n"] as? Int == 2 else {
                fail("rerank fixture \(MemoryEndpointWire.state.requests.map(\.path))")
            }
            MemoryEndpointWire.state.reset()
            let silent = NativeMemoryService(configuration: NativeMemoryServiceConfiguration(
                baseURL: URL(string: "https://memory.example/v1")!, apiKey: nil,
                embeddingsModel: "qwen3-embedding", extractionModel: "", rerankModel: ""), session: session)
            guard try await silent.rerank(query: "coffee", documents: ["a"]).isEmpty, MemoryEndpointWire.state.requests.isEmpty else {
                fail("rerank ran without a model")
            }
            let models = try await wired.probe()
            guard models == ["qwen3-embedding", "qwen3-reranker"], MemoryEndpointWire.state.requests.last?.path == "/v1/models" else {
                fail("probe")
            }
            MemoryEndpointWire.state.modelsStatus = 503
            do {
                _ = try await wired.probe()
                fail("probe accepted a 503")
            } catch let error as NativeMemoryServiceError {
                guard error.isEndpointOutage else { fail("probe outage classification") }
            }
        } catch {
            fail("wire \(error)")
        }

        do {
            let repository = try LocalChatRepository(inMemory: true)
            let outage = SelfTestOutageMemoryService()
            var settings = NativeMemorySettings.fresh
            settings.enabled = true
            settings.embeddingsModel = "qwen3-embedding"
            settings.extractionModel = "qwen3-30b"
            settings.generateFromChats = true
            let chatConfig = NativeChatConfig(
                baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
            let store = ChatStore(
                nativeConfig: chatConfig, nativeTransport: SelfTestNativeTransport(), repository: repository,
                nativeMemorySettings: settings, nativeMemoryService: outage)
            let status = await store.probeMemoryEndpoint()
            guard case .unreachable = status else { fail("unreachable status \(status)") }
            let selected = await store.selectApprovedMemory("what do I drink", settings: settings, service: outage)
            guard selected.isEmpty, outage.embedCalls == 1,
                  case .retrievalUnavailable(let detail) = store.memoryServiceState, detail.contains("local search") else {
                fail("lexical fallback \(store.memoryServiceState)")
            }
            let reply = Message(role: .assistant, text: "Noted, you prefer tea in the morning.")
            await store.learnFromCompletedTurn(
                user: "I prefer tea over coffee in the mornings", assistant: reply,
                source: NativeMemoryTurnSource(conversationID: "c1", messageID: "m1", date: Date()),
                turnKey: "c1|m1", conversationExcluded: false)
            await store.learnFromCompletedTurn(
                user: "I prefer tea over coffee in the mornings", assistant: reply,
                source: NativeMemoryTurnSource(conversationID: "c1", messageID: "m1", date: Date()),
                turnKey: "c1|m1", conversationExcluded: false)
            guard store.queuedMemoryTurns.count == 1, outage.extractionCalls == 2,
                  case .retrievalUnavailable(let waiting) = store.memoryServiceState, waiting.contains("1 suggestion waiting") else {
                fail("queue \(store.queuedMemoryTurns.count) \(store.memoryServiceState)")
            }
            outage.failing = false
            let recovered = await store.probeMemoryEndpoint()
            guard recovered == .connected(models: 2), store.queuedMemoryTurns.isEmpty, outage.extractionCalls == 3,
                  !store.memoryProposals.isEmpty else {
                fail("drain \(recovered) \(store.queuedMemoryTurns.count) \(outage.extractionCalls) \(store.memoryProposals.count)")
            }
            guard store.memoryRecallDescription.contains("semantic") else { fail("recall description \(store.memoryRecallDescription)") }
            store.updateNativeMemory(settings: settings, service: nil)
            guard store.memoryRecallDescription.contains("local search only") else { fail("recall description without endpoint") }
        } catch {
            fail("store \(error)")
        }
        print("  memory endpoint OK (resolution, env, migration, keychain copy, profile switch, rerank, probe, lexical fallback, queue and drain)")
    }
}
