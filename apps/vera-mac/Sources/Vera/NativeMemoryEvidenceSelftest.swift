import Combine
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
        try await extractionRevocation(directory)
        try libraryPresentation(directory)
        try await liveMemoryControls(directory)
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

    private static func extractionRevocation(_ directory: URL) async throws {
        for queued in [false, true] {
            NativeMemoryAdmissionProtocol.state.reset()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [NativeMemoryAdmissionProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let repository = try LocalChatRepository(url: directory.appendingPathComponent("extraction-\(queued).sqlite"))
            let (_, revoked) = try fixture(repository, name: "revoked")
            let now = Date()
            let kept = NativeMemoryRecord(id: "kept", title: "Drinks", summary: "Prefers green tea",
                details: ["The user prefers green tea"], group: .profile, category: .preference, bank: "personal",
                durability: .durable, expiry: nil, status: .approved, embedding: nil, sourceConversationID: nil,
                sourceMessageID: nil, createdAt: now, updatedAt: now)
            try repository.saveMemory(kept, decision: .accepted, note: "Synthetic approved fixture")
            func exclude() throws {
                var conversation = try repository.listConversations().first { $0.id == "revoked" }!
                conversation.memoryExcluded = true
                try repository.saveConversation(conversation)
            }
            if !queued {
                try exclude()
                NativeMemoryAdmissionProtocol.state.allow()
            }
            let service = NativeMemoryService(configuration: NativeMemoryServiceConfiguration(
                baseURL: URL(string: "https://fixture.example/v1")!, apiKey: nil, embeddingsModel: "",
                extractionModel: "fixture-extraction"), session: session,
                admission: NativeInferenceAdmission(baseURL: URL(string: "https://fixture.example")!, session: session))
            var settings = NativeMemorySettings.fresh
            settings.enabled = true
            settings.generateFromChats = true
            let store = ChatStore(nativeConfig: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!,
                apiKey: nil, model: "local-model", chatTemplateKwargs: nil), nativeTransport: SelfTestNativeTransport(),
                repository: repository, nativeMemorySettings: settings, nativeMemoryService: service)
            store.newConversation()
            store.sendText("I like morning walks before work")
            if queued {
                for _ in 0..<300 where NativeMemoryAdmissionProtocol.state.acquires == 0 {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try require(NativeMemoryAdmissionProtocol.state.acquires > 0, "extraction never queued for admission")
                try exclude()
                NativeMemoryAdmissionProtocol.state.allow()
            }
            for _ in 0..<300 where NativeMemoryAdmissionProtocol.state.bodies.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            let body = NativeMemoryAdmissionProtocol.state.bodies.joined()
            try require(body.contains(kept.summary), "extraction request lost eligible memory")
            try require(!body.contains(revoked.summary) && !body.contains(revoked.details[0]) && !body.contains(revoked.id),
                        "excluded source reached extraction " + (queued ? "after queued admission" : "request"))
        }
        print("  memory extraction: PASS (excluded source absent from extraction before and during queued admission)")
    }

    private static func libraryPresentation(_ directory: URL) throws {
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("library.sqlite"))
        let now = Date()
        try require(NativeMemoryCategory.project.defaultGroup == .projects && NativeMemoryCategory.plan.defaultGroup == .areas
            && NativeMemoryCategory.preference.defaultGroup == .profile, "category default groups changed")
        let project = NativeMemoryRecord(id: "project", title: "Barn rebuild", summary: "Rebuilding the barn",
            details: ["Rebuilding the barn this year"], group: NativeMemoryCategory.project.defaultGroup, category: .project,
            bank: "farm", durability: .durable, expiry: nil, status: .approved, embedding: nil,
            sourceConversationID: nil, sourceMessageID: nil, createdAt: now, updatedAt: now)
        var legacyProject = project
        legacyProject.id = "legacy-project"
        legacyProject.group = .areas
        try repository.saveMemory(project, decision: .accepted, note: "Synthetic user approval")
        try repository.saveMemory(legacyProject, decision: .accepted, note: "Synthetic user approval")
        let reopened = try repository.allMemories()
        let projects = NativeMemoryLibraryFilter(group: .projects)
        try require(Set(reopened.filter { projects.matches($0) }.map(\.id)) == ["project", "legacy-project"], "project memory missing from Projects")
        try require(!reopened.contains { NativeMemoryLibraryFilter(group: .areas).matches($0) }, "project memory still listed in Areas")
        var legacy = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        legacy = legacy.replacingOccurrences(of: "\"Projects\"", with: "\"You\"")
        let decoded = try JSONDecoder().decode(NativeMemoryRecord.self, from: Data(legacy.utf8))
        try require(decoded.group == .profile && decoded.libraryGroup == .profile, "old You group did not decode to Profile and Preferences")
        try require(NativeMemoryProposalKind.allCases.allSatisfy { !$0.label.isEmpty && $0.label != $0.rawValue }
            && NativeMemoryProposalKind.update.label == "Change", "proposal kinds shown as raw values")
        let source = Message(role: .user, text: "I prefer tea in the morning.")
        try repository.saveConversation(Conversation(id: "chat-source", title: "Source", messages: [], updatedAt: now))
        try repository.saveMessage(source, conversationID: "chat-source", ordinal: 0)
        let sourced = NativeMemoryRecord(id: "sourced", title: "Morning drink", summary: "Prefers tea",
            details: ["Prefers tea in the morning"], group: .profile, category: .preference, bank: "personal",
            durability: .durable, expiry: nil, status: .approved, embedding: nil, sourceConversationID: "chat-source",
            sourceMessageID: source.id.uuidString, createdAt: now, updatedAt: now)
        try repository.saveMemory(sourced, decision: .accepted, note: "Synthetic user approval")
        try require(try repository.memoriesWithUnavailableSources().isEmpty, "eligible source reported unavailable")
        try repository.deleteConversation("chat-source")
        try require(try repository.memoriesWithUnavailableSources() == ["sourced"], "deleted source not reported unavailable")
        print("  memory library: PASS (Projects group, legacy You decode, plain proposal kinds, unavailable source)")
    }

    private static func liveMemoryControls(_ directory: URL) async throws {
        func makeStore(_ repository: LocalChatRepository, _ settings: NativeMemorySettings,
                       _ service: any NativeMemoryServing) -> ChatStore {
            ChatStore(nativeConfig: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!,
                apiKey: nil, model: "local-model", chatTemplateKwargs: nil), nativeTransport: SelfTestNativeTransport(),
                repository: repository, nativeMemorySettings: settings, nativeMemoryService: service)
        }
        var generating = NativeMemorySettings.fresh
        generating.enabled = true
        generating.generateFromChats = true
        for flip in [false, true] {
            let repository = try LocalChatRepository(url: directory.appendingPathComponent("live-generate-\(flip).sqlite"))
            let service = SelfTestMemoryService()
            let store = makeStore(repository, generating, service)
            var flipped = false
            var off = generating
            off.generateFromChats = false
            let watcher = store.$conversations.sink { conversations in
                guard flip, !flipped,
                      let reply = conversations.first(where: { $0.id == store.selectedID })?.messages.last,
                      reply.role == .assistant, reply.state == .complete, !reply.text.isEmpty else { return }
                flipped = true
                store.updateNativeMemory(settings: off, service: service)
            }
            store.newConversation()
            store.sendText("I like morning walks before work")
            for _ in 0..<200 where store.generating { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(300))
            watcher.cancel()
            if flip {
                try require(flipped, "settings never flipped between completion and extraction")
                try require(service.extractionCalls == 0, "extraction ran after generation was turned off")
                try require(try repository.pendingProposals().isEmpty, "proposal saved after generation was turned off")
            } else {
                try require(service.extractionCalls == 1, "control turn did not extract")
            }
        }

        let scanRepository = try LocalChatRepository(url: directory.appendingPathComponent("live-scan.sqlite"))
        let now = Date()
        for index in 0..<4 {
            let id = "scan-\(index)"
            try scanRepository.saveConversation(Conversation(id: id, title: id, messages: [], updatedAt: now.addingTimeInterval(Double(index))))
            try scanRepository.saveMessage(Message(role: .user, text: "I keep bees in garden plot \(index)"), conversationID: id, ordinal: 0)
            try scanRepository.saveMessage(Message(role: .assistant, text: "Noted, plot \(index)."), conversationID: id, ordinal: 1)
        }
        var scanning = NativeMemorySettings.fresh
        scanning.enabled = true
        scanning.searchPastChats = true
        let scanService = NativeMemoryScanStub()
        let scanStore = makeStore(scanRepository, scanning, scanService)
        await scanStore.connect()
        let scanOff = NativeMemorySettings(
            enabled: true, embeddingsModel: "", extractionModel: "", bankScope: "all",
            searchPastChats: false, generateFromChats: false)
        scanService.onExtract = { await MainActor.run { scanStore.updateNativeMemory(settings: scanOff, service: scanService) } }
        scanStore.searchPastChatsForMemory()
        for _ in 0..<300 where scanService.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        try require(scanService.calls == 1, "past-chat scan kept reviewing turns after Search past chats was turned off")
        try require(try scanRepository.pendingProposals().isEmpty, "past-chat scan saved proposals after it was turned off")
        try require(scanStore.memoryServiceState == .ready, "stopped scan was reported as a failure")
        scanStore.scanPastChatsIfAllowed()
        try await Task.sleep(for: .milliseconds(100))
        try require(scanService.calls == 1 && scanStore.memoryServiceState == .notice("Turn on Search past chats in Settings to scan."),
                    "scan request ran or enabled Search past chats while it was off")

        let sourceMessage = try scanRepository.messages(conversationID: "scan-1")[0]
        scanStore.openMemorySource(conversationID: "scan-1", messageID: sourceMessage.id.uuidString)
        try require(scanStore.selectedID == "scan-1" && scanStore.pendingHighlightMessageID == sourceMessage.id,
                    "source opening did not target the exact message")
        scanStore.openMemorySource(conversationID: "scan-2", messageID: UUID().uuidString)
        try require(scanStore.selectedID == "scan-2" && scanStore.pendingHighlightMessageID == nil
                    && scanStore.memoryServiceState == .notice("The source message was deleted or changed, so Vera opened the conversation instead."),
                    "missing source message was not explained")
        var excludedSource = try scanRepository.listConversations().first { $0.id == "scan-3" }!
        excludedSource.memoryExcluded = true
        try scanRepository.saveConversation(excludedSource)
        await scanStore.connect()
        let excludedMessage = try scanRepository.messages(conversationID: "scan-3")[0]
        scanStore.openMemorySource(conversationID: "scan-3", messageID: excludedMessage.id.uuidString)
        try require(scanStore.selectedID == "scan-3" && scanStore.pendingHighlightMessageID == excludedMessage.id
                    && scanStore.memoryServiceState == .notice("This conversation is excluded from memory suggestions."),
                    "excluded source conversation was not opened with an explanation")

        let sensitiveUser = "settings: I prefer dark mode everywhere"
        let secretUser = "password: hunter2hunter2 for the router"
        for handling in NativeMemorySensitiveHandling.allCases {
            for (index, user) in [sensitiveUser, secretUser].enumerated() {
                let repository = try LocalChatRepository(url: directory.appendingPathComponent("sensitive-\(handling.rawValue)-\(index).sqlite"))
                let service = SelfTestMemoryService()
                var settings = generating
                settings.sensitiveHandling = handling
                let store = makeStore(repository, settings, service)
                store.newConversation()
                store.sendText(user)
                for _ in 0..<200 where store.generating { try await Task.sleep(for: .milliseconds(10)) }
                try await Task.sleep(for: .milliseconds(300))
                let pending = try repository.pendingProposals()
                if handling == .reviewOnly && user == sensitiveUser {
                    try require(service.extractionCalls == 1 && pending.count == 1
                                && pending[0].summary.hasPrefix("Contains sensitive text:"),
                                "review-only sensitive turn was not flagged for review")
                    try require(try repository.approvedMemories().isEmpty
                                && (try repository.recallMemory("morning meetings", bankScope: "all")).isEmpty,
                                "sensitive proposal was stored or recalled without acceptance")
                    try require(store.acceptMemoryProposal(pending[0]), "flagged proposal could not be accepted")
                    try require(try repository.approvedMemories().first?.summary == "Prefers morning meetings",
                                "accepted memory kept the review flag in its summary")
                    let reopened = try LocalChatRepository(url: directory.appendingPathComponent("sensitive-\(handling.rawValue)-\(index).sqlite"))
                    let recalled = try reopened.recallMemory("morning meetings", bankScope: "all", sensitive: .reviewOnly)
                    try require(recalled.count == 1 && recalled[0].record.sensitiveConsent == true,
                                "accepted review-only memory was not recalled after reopen")
                    try require(try reopened.eligibleMemory(recalled, bankScope: "all", sensitive: .reviewOnly).count == 1,
                                "accepted review-only memory failed admission")
                    try require(try reopened.recallMemory("morning meetings", bankScope: "all").isEmpty
                                && (try reopened.eligibleMemory(recalled, bankScope: "all")).isEmpty,
                                "consented sensitive memory was recalled under never remember")
                    var switched = settings
                    switched.sensitiveHandling = .neverStore
                    store.updateNativeMemory(settings: switched, service: service)
                    try require(await store.selectApprovedMemory("morning meetings").isEmpty,
                                "switching to never remember did not stop recall")
                    try require(try repository.approvedMemories().count == 1,
                                "switching to never remember removed the stored memory")
                    store.updateNativeMemory(settings: settings, service: service)
                    try require(await store.selectApprovedMemory("morning meetings").count == 1,
                                "switching back to review only did not restore recall")
                    try require(try reopened.memoryEvidence(recalled[0].record.id).first?.sourceText == user,
                                "accepted review-only memory lost its source snapshot")
                } else if handling == .neverStore && user == sensitiveUser {
                    try require(service.extractionCalls == 0 && pending.isEmpty,
                                "sensitive turn reached extraction under never remember")
                    var stale = NativeMemoryProposal(
                        id: UUID().uuidString, kind: .create, title: "Meeting preference",
                        summary: "Prefers morning meetings", details: ["The user prefers morning meetings"],
                        group: .profile, category: .preference, bank: "personal", durability: .durable,
                        expiry: nil, targetIDs: [], sourceConversationID: store.selectedID,
                        sourceMessageID: store.selected?.messages.first?.id.uuidString, createdAt: Date(), status: .pending)
                    stale = NativeMemorySensitiveHandling.flagged(stale)
                    try repository.saveProposal(stale)
                    try require(!store.acceptMemoryProposal(stale) && (try repository.approvedMemories()).isEmpty,
                                "flagged proposal became memory under never remember")
                } else {
                    try require(service.extractionCalls == 0 && pending.isEmpty,
                                "sensitive turn reached extraction under \(handling.rawValue)")
                }
            }
        }
        let legacy = try JSONDecoder().decode(NativeMemorySettings.self, from: Data(#"{"enabled":true,"embeddingsModel":"","extractionModel":"","bankScope":"all","searchPastChats":false,"generateFromChats":true}"#.utf8))
        try require(legacy.sensitiveHandling == .neverStore, "saved settings without a sensitive choice did not default to never remember")
        print("  memory controls: PASS (generation off after completion skips extraction, scan stops when turned off, scan request never forces the toggle, exact source opening, sensitive review accepted and recalled after reopen, refused under never remember, credentials blocked in both modes)")
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
    private var completionBodies: [String] = []
    var acquires: Int { lock.withLock { acquireCount } }
    var completions: Int { lock.withLock { completionCount } }
    var bodies: [String] { lock.withLock { completionBodies } }
    func reset() { lock.withLock { admitted = false; acquireCount = 0; completionCount = 0; completionBodies = [] } }
    func allow() { lock.withLock { admitted = true } }
    func acquire() -> String { lock.withLock { acquireCount += 1; return admitted ? "admitted" : "pending" } }
    func complete(_ body: Data) { lock.withLock { completionCount += 1; completionBodies.append(String(decoding: body, as: UTF8.self)) } }
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
            while stream.hasBytesAvailable && data.count < 65536 {
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
            Self.state.complete(data)
            body = ["choices": [["message": ["content": "Unexpected model request"], "finish_reason": "stop"]]]
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class NativeMemoryScanStub: NativeMemoryServing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var hook: (@Sendable () async -> Void)?
    var calls: Int { lock.withLock { count } }
    var onExtract: (@Sendable () async -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    func embed(_ text: String) async throws -> [Double] { [1, 0] }

    func proposals(
        user: String, assistant: String, sourceConversationID: String?, sourceMessageID: String?,
        existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] {
        let first = lock.withLock { count += 1; return count == 1 }
        if first, let hook = onExtract { await hook() }
        return [NativeMemoryProposal(
            id: UUID().uuidString, kind: .create, title: "Bees",
            summary: "Keeps bees", details: ["The user keeps bees"],
            group: .profile, category: .interest, bank: "personal", durability: .durable,
            expiry: nil, targetIDs: [], sourceConversationID: sourceConversationID,
            sourceMessageID: sourceMessageID, createdAt: now, status: .pending)]
    }

    func proposal(
        request: String, existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] { [] }
}
