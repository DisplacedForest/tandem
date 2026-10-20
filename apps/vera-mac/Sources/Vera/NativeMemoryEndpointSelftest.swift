import Foundation

final class SelfTestOutageMemoryService: NativeMemoryServing, @unchecked Sendable {
    private let lock = NSLock()
    fileprivate var embeds = 0
    fileprivate var extracts = 0
    var failing = true
    var malformedExtraction = false
    var supportsSemanticRecall: Bool { true }

    private var shouldMalform: Bool {
        lock.lock()
        defer { lock.unlock() }
        return malformedExtraction
    }

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
        if shouldMalform { throw NativeMemoryServiceError.malformed }
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
    var refuseConnections = false

    var requests: [(path: String, body: [String: Any]?)] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ path: String, _ body: [String: Any]?) { lock.lock(); recorded.append((path, body)); lock.unlock() }
    func reset() { lock.lock(); recorded = []; modelsStatus = 200; refuseConnections = false; lock.unlock() }
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
            if Self.state.refuseConnections {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
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
        guard written.configs.isEmpty else { fail("startup must not persist the migration before the credential copy") }
        let relaunched = ConfigStore(credentialStore: credentials, readConfiguration: { chatCoupled }, writeConfiguration: { _ in })
        guard relaunched.memoryEndpointAPIKey == "tower-key", relaunched.memoryEndpointResolved?.baseURL.host == "tower.example" else {
            fail("migration must repeat on relaunch until saved")
        }
        do { try config.save() } catch { fail("save \(error)") }
        guard credentials.values[ConfigStore.memoryCredentialID] == "tower-key",
              let firstWrite = written.configs.first,
              let writtenChat = firstWrite["native_chat"] as? [String: Any],
              let writtenEndpoint = writtenChat["memoryEndpoint"] as? [String: Any],
              writtenEndpoint["baseURL"] as? String == "http://tower.example:11434/v1" else {
            fail("credential copied to the memory id and endpoint persisted on save")
        }
        let deniedCredentials = NativeCredentialFixtureStore()
        deniedCredentials.values["tower"] = "tower-key"
        deniedCredentials.denied = ["tower"]
        let deniedWritten = Written()
        let deniedConfig = ConfigStore(credentialStore: deniedCredentials, readConfiguration: { chatCoupled },
                                       writeConfiguration: { deniedWritten.configs.append($0) })
        deniedConfig["appearance"] = "dark"
        do { try deniedConfig.save() } catch { fail("denied save \(error)") }
        guard let deniedChat = deniedWritten.configs.last?["native_chat"] as? [String: Any], deniedChat["memoryEndpoint"] == nil,
              deniedCredentials.values[ConfigStore.memoryCredentialID] == nil else {
            fail("a denied chat key must keep the migration pending instead of persisting an endpoint without a key")
        }
        deniedCredentials.denied = []
        let allowedAgain = ConfigStore(credentialStore: deniedCredentials, readConfiguration: { deniedWritten.configs.last! }, writeConfiguration: { _ in })
        guard allowedAgain.memoryEndpointAPIKey == "tower-key", allowedAgain.memoryEndpointResolved?.baseURL.host == "tower.example" else {
            fail("migration did not resume once the chat key became readable")
        }
        deniedCredentials.denied = ["tower"]
        let editedWritten = Written()
        let edited = ConfigStore(credentialStore: deniedCredentials, readConfiguration: { chatCoupled },
                                 writeConfiguration: { editedWritten.configs.append($0) })
        edited.memoryEndpointBinding(\.baseURL).wrappedValue = "http://keyless.example:11434/v1"
        do { try edited.save() } catch { fail("edited save \(error)") }
        guard let editedChat = editedWritten.configs.last?["native_chat"] as? [String: Any],
              let editedEndpoint = editedChat["memoryEndpoint"] as? [String: Any],
              editedEndpoint["baseURL"] as? String == "http://keyless.example:11434/v1" else {
            fail("a manual endpoint edit must be saved even while the migration waits for a key")
        }
        let cleared = ConfigStore(credentialStore: deniedCredentials, readConfiguration: { chatCoupled },
                                  writeConfiguration: { editedWritten.configs.append($0) })
        cleared.memoryEndpointBinding(\.baseURL).wrappedValue = ""
        do { try cleared.save() } catch { fail("cleared save \(error)") }
        guard let clearedChat = editedWritten.configs.last?["native_chat"] as? [String: Any],
              let clearedEndpoint = clearedChat["memoryEndpoint"] as? [String: Any],
              (clearedEndpoint["baseURL"] as? String ?? "").isEmpty else {
            fail("an explicitly cleared endpoint must be saved as cleared")
        }

        let legacyRaw: [String: Any] = ["model_api_key": "legacy-key", "native_chat": [
            "version": 3,
            "profiles": [["id": "old", "name": "Old", "baseURL": "http://old.example/v1", "discoveredModels": ["emb"], "selectedModel": "emb"]],
            "activeProfileID": "old",
            "memory": ["enabled": true, "embeddingsModel": "emb", "extractionModel": "", "bankScope": "all", "searchPastChats": false, "generateFromChats": false],
        ]]
        let legacyCredentials = NativeCredentialFixtureStore()
        let legacyConfig = ConfigStore(credentialStore: legacyCredentials, readConfiguration: { legacyRaw }, writeConfiguration: { _ in })
        guard legacyConfig.memoryEndpointAPIKey == "legacy-key" else { fail("legacy model_api_key did not reach the memory credential") }
        do { try legacyConfig.save() } catch { fail("legacy save \(error)") }
        guard legacyCredentials.values["old"] == "legacy-key", legacyCredentials.values[ConfigStore.memoryCredentialID] == "legacy-key" else {
            fail("legacy key copies")
        }
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
        do { try config.save() } catch { fail("save unset \(error)") }
        let restored = ConfigStore(credentialStore: credentials, readConfiguration: { written.configs.last! }, writeConfiguration: { _ in })
        guard restored.memoryEndpointAPIKey.isEmpty else { fail("deferred read loaded a key with no endpoint") }
        restored.memoryEndpointBinding(\.baseURL).wrappedValue = "http://tower.example:11434/v1"
        guard restored.memoryEndpointAPIKey == "tower-key", restored.nativeMemoryService?.configuration.apiKey == "tower-key" else {
            fail("existing key not loaded when the endpoint was restored")
        }
        let lockedCredentials = NativeCredentialFixtureStore()
        lockedCredentials.values = credentials.values
        lockedCredentials.denied = [ConfigStore.memoryCredentialID]
        let locked = ConfigStore(credentialStore: lockedCredentials, readConfiguration: { written.configs.last! }, writeConfiguration: { _ in })
        locked.memoryEndpointBinding(\.baseURL).wrappedValue = "http://tower.example:11434/v1"
        let deniedReads = lockedCredentials.reads.filter { $0 == ConfigStore.memoryCredentialID }.count
        _ = locked.memoryEndpointResolved
        guard locked.memoryEndpointAPIKey.isEmpty, locked.credentialError != nil, locked.memoryCredentialNeedsRetry,
              lockedCredentials.reads.filter({ $0 == ConfigStore.memoryCredentialID }).count == deniedReads else {
            fail("a denied deferred read must surface and must not retry on every resolution")
        }
        lockedCredentials.denied = []
        locked.loadMemoryCredentialIfNeeded(retry: true)
        guard locked.memoryEndpointAPIKey == "tower-key", locked.credentialError == nil, !locked.memoryCredentialNeedsRetry else {
            fail("explicit retry did not load the key")
        }
        let envCredentials = NativeCredentialFixtureStore()
        envCredentials.values[ConfigStore.memoryCredentialID] = "env-key"
        envCredentials.denied = [ConfigStore.memoryCredentialID]
        ConfigStore.memoryEnvironmentOverride = ["VERA_MEMORY_BASE": "http://env.example:11434/v1"]
        defer { ConfigStore.memoryEnvironmentOverride = nil }
        let envOnly = ConfigStore(credentialStore: envCredentials, readConfiguration: { written.configs.last! }, writeConfiguration: { _ in })
        guard envOnly.memoryEndpointAPIKey.isEmpty, envOnly.memoryCredentialNeedsRetry,
              envOnly.memoryEndpointResolved?.baseURL.host == "env.example" else {
            fail("environment-only endpoint with a denied read should resolve without a key and need a retry")
        }
        envCredentials.denied = []
        envOnly.loadMemoryCredentialIfNeeded(retry: true)
        guard envOnly.memoryEndpointAPIKey == "env-key", envOnly.memoryEndpointResolved?.apiKey == "env-key" else {
            fail("explicit retry must load the key for an environment-only endpoint")
        }
        ConfigStore.memoryEnvironmentOverride = nil
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
            MemoryEndpointWire.state.reset()
            MemoryEndpointWire.state.refuseConnections = true
            do {
                _ = try await wired.embed("coffee")
                fail("embed succeeded against a refused connection")
            } catch let error as NativeMemoryServiceError {
                guard error.isEndpointOutage else { fail("refused connection was not an outage: \(error)") }
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
            store.newConversation()
            guard let liveConversation = store.selectedID else { fail("no conversation for the queue") }
            let doomedConversation = UUID().uuidString.lowercased()
            store.conversations.append(Conversation(id: doomedConversation, title: "Doomed", messages: [], updatedAt: Date()))
            await store.learnFromCompletedTurn(
                user: "I prefer tea over coffee in the mornings", assistant: reply,
                source: NativeMemoryTurnSource(conversationID: liveConversation, messageID: "m1", date: Date()),
                turnKey: liveConversation + "|m1", conversationExcluded: false)
            await store.learnFromCompletedTurn(
                user: "I prefer tea over coffee in the mornings", assistant: reply,
                source: NativeMemoryTurnSource(conversationID: liveConversation, messageID: "m1", date: Date()),
                turnKey: liveConversation + "|m1", conversationExcluded: false)
            await store.learnFromCompletedTurn(
                user: "My cat is named Juniper", assistant: Message(role: .assistant, text: "Juniper, noted."),
                source: NativeMemoryTurnSource(conversationID: doomedConversation, messageID: "m2", date: Date()),
                turnKey: doomedConversation + "|m2", conversationExcluded: false)
            guard store.queuedMemoryTurns.count == 2 else { fail("two distinct turns should queue, got \(store.queuedMemoryTurns.count)") }
            store.toggleMemoryExclusion(doomedConversation)
            await store.learnFromCompletedTurn(
                user: "I prefer tea over coffee in the mornings", assistant: reply,
                source: NativeMemoryTurnSource(conversationID: liveConversation, messageID: "m1", date: Date()),
                turnKey: liveConversation + "|m1", conversationExcluded: false)
            guard store.queuedMemoryTurns.count == 2, outage.extractionCalls == 4,
                  case .retrievalUnavailable(let waiting) = store.memoryServiceState, waiting.contains("2 suggestions waiting") else {
                fail("queue \(store.queuedMemoryTurns.count) \(store.memoryServiceState)")
            }
            outage.failing = false
            let recovered = await store.probeMemoryEndpoint()
            guard recovered == .connected(models: 2), store.queuedMemoryTurns.isEmpty, outage.extractionCalls == 5,
                  !store.memoryProposals.isEmpty,
                  !store.memoryProposals.contains(where: { $0.sourceConversationID == doomedConversation }) else {
                fail("drain \(recovered) \(store.queuedMemoryTurns.count) \(outage.extractionCalls) \(store.memoryProposals.count)")
            }
            guard store.memoryRecallDescription.contains("semantic") else { fail("recall description \(store.memoryRecallDescription)") }
            outage.failing = true
            await store.learnFromCompletedTurn(
                user: "I take my coffee black", assistant: Message(role: .assistant, text: "Black coffee, noted."),
                source: NativeMemoryTurnSource(conversationID: liveConversation, messageID: "m3", date: Date()),
                turnKey: liveConversation + "|m3", conversationExcluded: false)
            guard store.queuedMemoryTurns.count == 1 else { fail("malformed case setup \(store.queuedMemoryTurns.count)") }
            outage.failing = false
            outage.malformedExtraction = true
            _ = await store.probeMemoryEndpoint()
            guard store.queuedMemoryTurns.isEmpty,
                  case .retrievalUnavailable(let malformedDetail) = store.memoryServiceState,
                  !malformedDetail.contains("waiting to be reviewed") else {
                fail("a fresh extraction failure during the drain must stay visible: \(store.memoryServiceState)")
            }
            outage.malformedExtraction = false
            var envOnly = settings
            envOnly.embeddingsModel = ""
            store.updateNativeMemory(settings: envOnly, service: outage)
            let before = outage.embedCalls
            _ = await store.selectApprovedMemory("tea", settings: envOnly, service: outage)
            guard outage.embedCalls == before + 1, store.memoryRecallDescription.contains("semantic") else {
                fail("effective embeddings model from the service was ignored")
            }
            store.updateNativeMemory(settings: settings, service: nil)
            guard store.memoryRecallDescription.contains("local search only") else { fail("recall description without endpoint") }
        } catch {
            fail("store \(error)")
        }
        print("  memory endpoint OK (resolution, env, migration, keychain copy, profile switch, rerank, probe, lexical fallback, queue and drain)")
    }
}
