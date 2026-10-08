import Foundation
import GRDB

@MainActor
enum NativeMemoryEvidenceSelftest {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vera-memory-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        var repository = try LocalChatRepository(url: url)
        let now = Date()
        let sourceA = Message(role: .user, text: "Current livestock: twelve hens. Vaccination is planned for Friday.")
        let sourceB = Message(role: .user, text: "Correction: current livestock is ten hens. Two hens left the flock. Vaccination is still planned, not completed.")
        for (id, source) in [("chat-a", sourceA), ("chat-b", sourceB)] {
            try repository.saveConversation(Conversation(id: id, title: id, messages: [], updatedAt: now))
            try repository.saveMessage(source, conversationID: id, ordinal: 0)
        }
        var stock = NativeMemoryRecord(id: "stock", title: "Current livestock", summary: "Twelve hens",
            details: ["Current livestock: twelve hens"], group: .areas, category: .project,
            bank: "farm", durability: .durable, expiry: nil, status: .approved, embedding: nil,
            sourceConversationID: "chat-a", sourceMessageID: sourceA.id.uuidString, createdAt: now, updatedAt: now)
        try repository.saveMemory(stock, decision: .accepted, note: "Synthetic user approval")
        try repository.saveMemory(stock, decision: .accepted, note: "Duplicate fixture delivery")
        try require(try repository.memoryEvidence(stock.id).count == 1, "duplicate source created a revision")
        let first = try repository.recallMemory("livestock", bankScope: "farm")
        try require(first.count == 1 && first[0].revision == 1, "approved source missing from lexical recall")
        let originalStock = stock
        stock.summary = "Ten hens"
        stock.details = ["Current livestock: ten hens. Two hens left the flock."]
        stock.sourceConversationID = "chat-b"
        stock.sourceMessageID = sourceB.id.uuidString
        stock.updatedAt = now.addingTimeInterval(1)
        try repository.saveMemory(stock, decision: .edited, note: "Synthetic user correction", expected: originalStock)
        var care = stock
        care.id = "care"
        care.title = "Planned livestock care"
        care.summary = "Vaccination is planned"
        care.details = ["Livestock vaccination is planned, not completed."]
        care.category = .plan
        try repository.saveMemory(care, decision: .accepted, note: "Synthetic user approval")
        repository = try LocalChatRepository(url: url)
        let recalled = try repository.recallMemory("current livestock", bankScope: "farm")
        let packed = NativeMemoryPromptAssembler.section(selected: recalled) ?? ""
        try require(packed.contains("ten hens") && !packed.contains("twelve hens"), "correction did not survive reopen")
        try require(packed.contains("planned, not completed") && packed.contains("Plans are not completed actions"), "planned care lost its qualification")
        let evidence = try repository.memoryEvidence(stock.id)
        try require(evidence.count == 2 && evidence[0].sourceText == sourceB.text && evidence[1].sourceText == sourceA.text,
                    "source archive did not preserve correction evidence")
        try require(evidence[0].sourceVersion != evidence[1].sourceVersion, "source versions were not distinct")
        try require(try repository.recallMemory("livestock", bankScope: "personal").isEmpty, "bank scope leaked")
        try require(try repository.recallMemory("\" OR * NEAR()", bankScope: "farm").isEmpty, "query syntax became an operator")
        try require(try repository.recallMemory("livestock", bankScope: "farm", byteLimit: 4).isEmpty, "context budget overflowed")
        var expired = stock
        expired.id = "expired"
        expired.expiry = now.addingTimeInterval(-60)
        try repository.saveMemory(expired, decision: .accepted, note: "Expired fixture")
        try require(!(try repository.recallMemory("livestock", bankScope: "farm")).contains { $0.record.id == expired.id }, "expired fact recalled")
        let transport = SelfTestNativeTransport()
        let service = SelfTestMemoryService()
        var settings = NativeMemorySettings.fresh
        settings.enabled = true
        settings.bankScope = "farm"
        let store = ChatStore(nativeConfig: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!,
            apiKey: nil, model: "local-model", chatTemplateKwargs: nil), nativeTransport: transport,
            repository: repository, nativeMemorySettings: settings, nativeMemoryService: service)
        await store.connect()
        store.sendText("What is the current livestock and planned care?")
        for _ in 0..<200 where store.generating { try await Task.sleep(for: .milliseconds(10)) }
        let prompt = transport.histories.last?.first?.content ?? ""
        try require(prompt.contains("ten hens") && !prompt.contains("twelve hens"), "native chat did not receive corrected cross-chat evidence")
        try require(service.embedCalls == 0 && service.extractionCalls == 0, "lexical recall called a model service")
        let reply = store.selected?.messages.last
        let citations = reply?.sources.filter { NativeMemoryCitation.recordID($0.url) != nil } ?? []
        try require(citations.count == 2, "native reply lost memory citations")
        let citation = citations.first { NativeMemoryCitation.recordID($0.url) == stock.id }!
        store.inspectMemoryCitation(citation.url)
        try require(store.inspectedMemory?.id == stock.id, "citation did not open editable memory")
        if let conversation = store.selectedID {
            try require(try repository.messages(conversationID: conversation).last?.sources == reply?.sources, "citation did not persist")
        } else { throw NativeMemoryEvidenceError.unavailable }
        let noMemoryTransport = SelfTestNativeTransport()
        let off = ChatStore(nativeConfig: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!,
            apiKey: nil, model: "local-model", chatTemplateKwargs: nil), nativeTransport: noMemoryTransport,
            repository: repository, nativeMemorySettings: .fresh, nativeMemoryService: service)
        await off.connect()
        off.sendText("What is the current livestock?")
        for _ in 0..<200 where off.generating { try await Task.sleep(for: .milliseconds(10)) }
        try require(!(noMemoryTransport.histories.last?.first?.content ?? "").contains("USER-APPROVED MEMORY CONTEXT"), "memory off still retrieved")
        try repository.deleteConversation("chat-a")
        try require(try repository.memoryEvidence(stock.id).last?.sourceText == nil, "deleted original chat survived in archive")
        var excluded = try repository.listConversations().first { $0.id == "chat-b" }!
        excluded.memoryExcluded = true
        try repository.saveConversation(excluded)
        try require(try repository.recallMemory("livestock", bankScope: "farm").isEmpty, "excluded source recalled")
        try require(try repository.memoryEvidence(stock.id).allSatisfy { $0.sourceText == nil }, "excluded source retained archived text")
        try repository.deleteMemory(stock.id)
        repository = try LocalChatRepository(url: url)
        do {
            try repository.saveMemory(stock, decision: .accepted, note: "Stale replay")
            throw NSError(domain: "MemoryEvidenceTest", code: 1)
        } catch NativeMemoryEvidenceError.removed { }
        try require(try await repository.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_memory_revisions WHERE memory_id = 'stock'") == 0
        }, "deleted memory retained revisions")
        try migration(directory)
        try await adversarial(directory)
        try await admissionAndRounds(directory)
        print("native-memory-evidence: PASS (cross-chat correction, reopen, planned care, citation, edit route, scope, expiry, budget, off, removal, replay; zero model calls)")
    }

    private static func migration(_ directory: URL) throws {
        let url = directory.appendingPathComponent("migration.sqlite")
        var repository = try LocalChatRepository(url: url)
        let (source, memory) = try fixture(repository, name: "legacy")
        try repository.database.write { db in
            for name in ["memory_fts_insert", "memory_fts_update", "memory_fts_delete", "memory_source_message_change", "memory_source_message_delete", "memory_source_exclusion", "memory_source_deletion"] {
                try db.execute(sql: "DROP TRIGGER " + name)
            }
            try db.execute(sql: "DROP TABLE native_memory_fts; DROP TABLE native_memory_revisions; DROP TABLE runtime_memory_sources; DELETE FROM grdb_migrations WHERE identifier IN ('nativeMemoryEvidenceV14','runtimeMemorySourcesV15')")
        }
        let original = try repository.messages(conversationID: "legacy")
        repository = try LocalChatRepository(url: url)
        try require(try repository.messages(conversationID: "legacy") == original, "migration rewrote conversation history")
        try require(try repository.allMemories() == [memory], "migration rewrote approved memory")
        try require(try repository.memoryEvidence(memory.id).first?.sourceText == source.text, "migration lost existing provenance")
        try require(try repository.recallMemory("livestock", bankScope: "farm").count == 1, "migration did not seed lexical index")
        repository = try LocalChatRepository(url: url)
        try require(try repository.memoryEvidence(memory.id).count == 1, "migration replay duplicated evidence")
        print("  memory migration: PASS (V13 fixture, unchanged history/facts, seeded provenance/FTS, repeat reopen)")
    }

    private static func fixture(_ repository: LocalChatRepository, name: String) throws -> (Message, NativeMemoryRecord) {
        let now = Date()
        let source = Message(role: .user, text: "Current livestock: twelve hens")
        try repository.saveConversation(Conversation(id: name, title: "Fixture", messages: [], updatedAt: now))
        try repository.saveMessage(source, conversationID: name, ordinal: 0)
        let record = NativeMemoryRecord(id: name, title: "Livestock", summary: "Twelve hens",
            details: [source.text], group: .areas, category: .project, bank: "farm", durability: .durable,
            expiry: nil, status: .approved, embedding: [1, 0], sourceConversationID: name,
            sourceMessageID: source.id.uuidString, createdAt: now, updatedAt: now)
        try repository.saveMemory(record, decision: .accepted, note: "Synthetic approved fixture")
        return (source, record)
    }

    private static func adversarial(_ directory: URL) async throws {
        for change in ["edit", "delete", "exclude", "private"] {
            let repository = try LocalChatRepository(url: directory.appendingPathComponent(change + ".sqlite"))
            var (source, memory) = try fixture(repository, name: change)
            let selected = try repository.recallMemory("livestock", bankScope: "farm")
            switch change {
            case "delete":
                let sourceID = memory.sourceMessageID
                try await repository.database.write { db in
                    try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [sourceID])
                }
            case "exclude":
                var conversation = try repository.listConversations()[0]
                conversation.memoryExcluded = true
                try repository.saveConversation(conversation)
            default:
                source.text = change == "private" ? "\n  private: current livestock is confidential" : "Source was corrected"
                try repository.saveMessage(source, conversationID: change, ordinal: 0)
            }
            try require(try repository.memoryEvidence(memory.id).allSatisfy { $0.sourceText == nil }, "source archive leaked after " + change)
            try require(try repository.recallMemory("livestock", bankScope: "farm").isEmpty, "lexical recall leaked after " + change)
            try require(try repository.eligibleMemory(selected, bankScope: "farm").isEmpty, "semantic selection leaked after " + change)
            let prior = memory
            memory.updatedAt = memory.updatedAt.addingTimeInterval(1)
            memory.summary += " approved correction"
            try repository.saveMemory(memory, decision: .edited, note: "Synthetic correction", expected: prior)
            try require(try repository.memoryEvidence(memory.id).first?.sourceText == (change == "edit" ? source.text : nil), "reviewed source refresh violated privacy")
        }
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("races.sqlite"))
        let (_, old) = try fixture(repository, name: "races")
        let first = try repository.recallMemory("livestock", bankScope: "farm")
        let oldURL = NativeMemoryCitation.sources(first)[0].url
        var corrected = old
        corrected.summary = "Ten hens"
        corrected.details = ["Current livestock: ten hens"]
        corrected.updatedAt = old.updatedAt.addingTimeInterval(1)
        try repository.saveMemory(corrected, decision: .edited, note: "Correction", expected: old)
        do {
            try repository.saveMemoryEmbedding([0, 1], expected: old)
            throw NativeMemoryEvidenceError.unavailable
        } catch NativeMemoryEvidenceError.changed { }
        var stale = old
        stale.updatedAt = corrected.updatedAt.addingTimeInterval(1)
        do {
            try repository.saveMemory(stale, decision: .edited, note: "Stale open editor", expected: old)
            throw NativeMemoryEvidenceError.unavailable
        } catch NativeMemoryEvidenceError.changed { }
        try require(try repository.allMemories().first == corrected, "late embedding or editor restored stale facts")
        let inspector = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository)
        inspector.inspectMemoryCitation(oldURL)
        try require(inspector.inspectedMemoryRevision == 1 && inspector.inspectedMemory?.summary == "Ten hens", "old citation lost its used revision or current editable record")
        let merged = NativeMemoryCitation.merging([PulseSource(n: 1, title: "Web", url: "https://example.test/source")],
            grounding: [PulseSource(n: 101, title: "Document", url: "local")], memories: first)
        try require(merged.map(\.n) == [1, 101, NativeMemoryCitation.offset], "mixed evidence lost memory citations")
        let mixed = Message(role: .assistant, text: "Mixed evidence", sources: merged)
        try repository.saveMessage(mixed, conversationID: "races", ordinal: 1)
        try require(try repository.messages(conversationID: "races").last?.sources == merged, "mixed evidence did not persist")
        for change in ["remove", "exclude", "off"] {
            let delayedRepository = try LocalChatRepository(url: directory.appendingPathComponent("delayed-" + change + ".sqlite"))
            let (_, memory) = try fixture(delayedRepository, name: "delayed")
            var settings = NativeMemorySettings.fresh
            settings.enabled = true
            let transport = SelfTestNativeTransport()
            let gate = NativeMemoryEvidenceGate()
            let store = ChatStore(veraAPI: VeraAPIClient(base: URL(string: "https://unused.example")!),
                nativeConfig: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
                    model: "local-model", chatTemplateKwargs: nil), nativeTransport: transport,
                repository: delayedRepository, nativeMemorySettings: settings)
            store.nativeKnowledgeQuery = { _, _, _ in await gate.wait(); return .ok([]) }
            store.newConversation()
            store.setConversationGrounding(store.selectedID!, ["fixture"])
            store.sendText("Current livestock?")
            for _ in 0..<200 {
                if await gate.arrived { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try require(await gate.arrived, "grounding fixture did not reach held lookup")
            switch change {
            case "remove": try delayedRepository.deleteMemory(memory.id)
            case "exclude":
                var conversation = try delayedRepository.listConversations().first { $0.id == "delayed" }!
                conversation.memoryExcluded = true
                try delayedRepository.saveConversation(conversation)
            default:
                settings.enabled = false
                store.updateNativeMemory(settings: settings, service: nil)
            }
            await gate.release()
            for _ in 0..<200 where store.generating { try await Task.sleep(for: .milliseconds(10)) }
            try require(!transport.histories.isEmpty, "held lookup never resumed")
            try require(!(transport.histories.last?.first?.content ?? "").contains("USER-APPROVED MEMORY CONTEXT"), "memory survived held lookup after " + change)
        }
        print("  memory adversarial: PASS (source edit/delete/privacy/exclusion, stale embedding/editor, revision citations, mixed sources, held lookup remove/exclude/off)")
    }

    private static func admissionAndRounds(_ directory: URL) async throws {
        for streaming in [false, true] {
            for change in ["remove", "exclude", "off"] {
                NativeMemoryAdmissionProtocol.state.reset()
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [NativeMemoryAdmissionProtocol.self]
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                let repository = try LocalChatRepository(url: directory.appendingPathComponent("admission-\(streaming)-\(change).sqlite"))
                let (_, memory) = try fixture(repository, name: "admitted")
                let endpoint = URL(string: "https://fixture.example/v1")!
                let model = NativeChatConfig(baseURL: endpoint, apiKey: nil, model: "local-model", chatTemplateKwargs: nil, streaming: streaming)
                let transport = NativeChatClient(config: model, session: session,
                    admission: NativeInferenceAdmission(baseURL: URL(string: "https://fixture.example")!, session: session))
                var settings = NativeMemorySettings.fresh
                settings.enabled = true
                let store = ChatStore(nativeConfig: model, nativeTransport: transport, repository: repository, nativeMemorySettings: settings)
                store.newConversation()
                store.sendText("Current livestock?")
                for _ in 0..<200 where NativeMemoryAdmissionProtocol.state.acquires == 0 {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try require(NativeMemoryAdmissionProtocol.state.acquires > 0, "actual client never queued for admission")
                switch change {
                case "remove": try repository.deleteMemory(memory.id)
                case "exclude":
                    var conversation = try repository.listConversations().first { $0.id == "admitted" }!
                    conversation.memoryExcluded = true
                    try repository.saveConversation(conversation)
                default:
                    settings.enabled = false
                    store.updateNativeMemory(settings: settings, service: nil)
                }
                NativeMemoryAdmissionProtocol.state.allow()
                for _ in 0..<200 where store.generating { try await Task.sleep(for: .milliseconds(10)) }
                try require(!store.generating && store.selected?.messages.last?.failure != nil, "revoked queued request did not stop visibly")
                try require(NativeMemoryAdmissionProtocol.state.completions == 0, "stale memory reached HTTP after admission")
            }
        }
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("tool-round.sqlite"))
        let (_, memory) = try fixture(repository, name: "tool-round")
        let gate = NativeMemoryEvidenceGate()
        let tool = NativeToolDefinition(id: "fixture-read", name: "fixture_read", title: "Fixture read", description: "Read fixture",
            parameters: .object(["type": .string("object"), "properties": .object([:])]), confirmation: .none,
            isAvailable: { true }, execute: { _ in await gate.wait(); return .object(["ok": .bool(true)]) })
        let transport = ScriptedNativeToolTransport(rounds: [
            [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: "read", name: "fixture_read", arguments: "{}")], finishReason: "tool_calls")],
            [NativeChatStreamSnapshot(content: "Should not send", toolCalls: [], finishReason: "stop")],
        ])
        var settings = NativeMemorySettings.fresh
        settings.enabled = true
        let store = ChatStore(nativeConfig: NativeChatConfig(baseURL: URL(string: "https://fixture.example/v1")!, apiKey: nil,
            model: "local-model", chatTemplateKwargs: nil), nativeTransport: transport, repository: repository,
            nativeEnabledToolIDs: ["fixture-read"], nativeMemorySettings: settings, nativeToolRegistry: NativeToolRegistry(definitions: [tool]))
        store.newConversation()
        store.sendText("Use the fixture read tool to check livestock")
        for _ in 0..<200 {
            if await gate.arrived { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(await gate.arrived, "held tool never ran")
        try repository.deleteMemory(memory.id)
        await gate.release()
        for _ in 0..<200 where store.generating { try await Task.sleep(for: .milliseconds(10)) }
        try require(transport.histories.count == 1, "later tool round resent removed memory")
        print("  memory dispatch: PASS (real client queued admission, streaming/nonstreaming remove/exclude/off, later tool round; zero model HTTP requests in admission fixtures)")
    }

    private static func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw NSError(domain: "MemoryEvidenceTest", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
    }
}

private actor NativeMemoryEvidenceGate {
    var arrived = false
    private var pending: CheckedContinuation<Void, Never>?
    func wait() async {
        arrived = true
        await withCheckedContinuation { pending = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}


private final class NativeMemoryAdmissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var admitted = false
    private var acquireCount = 0
    private var completionCount = 0
    var acquires: Int { lock.withLock { acquireCount } }
    var completions: Int { lock.withLock { completionCount } }
    func reset() { lock.withLock { admitted = false; acquireCount = 0; completionCount = 0 } }
    func allow() { lock.withLock { admitted = true } }
    func acquire() -> String { lock.withLock { acquireCount += 1; return admitted ? "admitted" : "queued" } }
    func complete() { lock.withLock { completionCount += 1 } }
}

private final class NativeMemoryAdmissionProtocol: URLProtocol, @unchecked Sendable {
    static let state = NativeMemoryAdmissionState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable && data.count < 8192 {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let body: [String: Any]
        if url.path.hasSuffix("/inference/admission") {
            body = ["request_id": input?["request_id"] as? String ?? "", "state": Self.state.acquire(),
                "generation_seconds_remaining": 30, "lease_seconds_remaining": 30, "poll_seconds": 0.01,
                "queue_seconds": 30, "queue_wait_seconds": 0]
        } else if url.path.hasSuffix("/release") {
            body = ["request_id": url.deletingLastPathComponent().lastPathComponent, "state": "released",
                "generation_seconds_remaining": 30, "lease_seconds_remaining": 30, "poll_seconds": 0.01,
                "queue_seconds": 30, "queue_wait_seconds": 0]
        } else {
            Self.state.complete()
            body = ["choices": [["message": ["content": "Unexpected model request"], "finish_reason": "stop"]]]
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
