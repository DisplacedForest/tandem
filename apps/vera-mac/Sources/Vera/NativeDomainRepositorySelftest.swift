import Foundation
import GRDB

@MainActor
enum NativeDomainRepositorySelftest {
    static func require(_ condition: Bool, _ reason: String) throws {
        try NativeDomainStateSelftest.require(condition, reason)
    }

    static func rejected(line: Int = #line, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "DomainRepositoryTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected rejection at line \(line)"])
    }

    static func fixture(_ repository: LocalChatRepository, entity: UUID, text: String, at: Double,
                        payload: NativeDomainPayload, supersedes: [UUID] = [], conversation: String = UUID().uuidString) throws -> NativeDomainEntry {
        let source = Message(role: .user, text: text)
        try repository.saveConversation(Conversation(id: conversation, title: "Synthetic evidence", messages: [], updatedAt: Date()))
        try repository.saveMessage(source, conversationID: conversation, ordinal: 0)
        return NativeDomainEntry(id: UUID(), entityID: entity, scope: "farm", occurredAt: Date(timeIntervalSince1970: at),
            validUntil: nil, learnedAt: Date(timeIntervalSince1970: 0), actor: "user",
            source: NativeDomainSource(conversationID: conversation, messageID: source.id.uuidString,
                version: LocalChatRepository.domainHash(text), lowerUTF8: 0, upperUTF8: text.utf8.count),
            evidence: .asserted, entityResolved: true, status: .supported, supersedes: supersedes, payload: payload)
    }

    static func futureClear(_ directory: URL) throws {
        let url = directory.appendingPathComponent("future-clear.sqlite")
        var repository = try LocalChatRepository(url: url)
        let entity = UUID()
        let tomorrow = Date().addingTimeInterval(86_400)
        let fact = try fixture(repository, entity: entity, text: "The flock moves to the south pasture tomorrow.",
            at: tomorrow.timeIntervalSince1970, payload: .fact(predicate: "Pasture", value: "south", quantity: nil))
        try repository.approveDomainProposal(repository.stageDomainProposal(fact, label: "Pasture")!)
        try require(try repository.approvedMemories().isEmpty, "future fact projected before its date")
        var settings = NativeMemorySettings.fresh
        settings.enabled = true
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeMemorySettings: settings)
        store.clearNativeMemory()
        try require(try repository.domainEntries(entity, scope: "farm").allSatisfy { $0.payload == nil && $0.source == nil }, "cleared future fact retained private payload")
        let later = tomorrow.addingTimeInterval(86_400)
        try repository.refreshDomainProjections(now: later)
        repository = try LocalChatRepository(url: url)
        try repository.refreshDomainProjections(now: later)
        try require(try repository.approvedMemories().isEmpty, "cleared future fact became approved memory without a new approval")
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("domain-memory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        var repository = try LocalChatRepository(url: url)
        let entity = UUID()
        let baseline = try fixture(repository, entity: entity, text: "Observed livestock count was fourteen hens.", at: 10,
            payload: .stock(kind: .baseline, quantity: NativeDomainQuantity("14", unit: .count)), conversation: "chat-a")
        let proposal = try repository.stageDomainProposal(baseline, label: "Livestock")!
        try require(try repository.approvedMemories().isEmpty && repository.domainEntries(entity, scope: "farm").isEmpty,
                    "unreviewed entry became approved memory")
        try repository.approveDomainProposal(proposal)
        try repository.approveDomainProposal(proposal)
        try require(try repository.domainEntries(entity, scope: "farm").count == 1, "duplicate approval appended an event")
        try require(try repository.stageDomainProposal(baseline, label: "Livestock") == nil, "duplicate event did not become a no-op")
        let first = try repository.recallMemory("Livestock", bankScope: "farm")
        try require(first.count == 1 && first[0].record.summary == "Current count: 14", "baseline projection missing")
        try require(try repository.domainEntries(entity, scope: "farm")[0].learnedAt > baseline.learnedAt, "caller controlled ingestion time")
        let loss = try fixture(repository, entity: entity, text: "Two hens left the flock.", at: 20,
            payload: .stock(kind: .removal, quantity: NativeDomainQuantity("2", unit: .count)), conversation: "chat-b")
        let lossProposal = try repository.stageDomainProposal(loss, label: "Livestock")!
        let care = try fixture(repository, entity: entity, text: "Vaccination is planned, not completed.", at: 21,
            payload: .care(activity: "Vaccination", status: .planned))
        let stale = try repository.stageDomainProposal(care, label: "Livestock")!
        try repository.approveDomainProposal(lossProposal)
        try rejected { try repository.approveDomainProposal(stale) }
        try require(try repository.domainEntries(entity, scope: "farm").count == 2, "stale approval partially committed")
        try repository.decideProposal(stale.id, status: .dismissed)
        try require(try repository.stageDomainProposal(care, label: "Livestock", proposalID: stale.id) == nil, "dismissed proposal replayed")
        try rejected { try repository.approveDomainProposal(stale) }
        let careProposal = try repository.stageDomainProposal(care, label: "Livestock")!
        try repository.approveDomainProposal(careProposal)
        let corrected = try fixture(repository, entity: entity, text: "Correction: the original count was twelve hens, before the two left.", at: 10,
            payload: .stock(kind: .baseline, quantity: NativeDomainQuantity("12", unit: .count)), supersedes: [baseline.id])
        let correction = try repository.stageDomainProposal(corrected, label: "Livestock")!
        try repository.approveDomainProposal(correction)
        let fact = try fixture(repository, entity: entity, text: "The flock is housed in the north shelter.", at: 25,
            payload: .fact(predicate: "Shelter", value: "north", quantity: nil))
        try repository.approveDomainProposal(repository.stageDomainProposal(fact, label: "Livestock")!)
        let oldPurchase = try fixture(repository, entity: entity, text: "Ten hens were purchased earlier; this is not a current count.", at: 5,
            payload: .stock(kind: .purchase, quantity: NativeDomainQuantity("10", unit: .count)))
        try repository.approveDomainProposal(repository.stageDomainProposal(oldPurchase, label: "Livestock")!)
        repository = try LocalChatRepository(url: url)
        let recalled = try repository.recallMemory("Livestock", bankScope: "farm")
        try require(recalled.count == 1 && recalled[0].record.summary == "Current count: 10", "correction/restart resurrected stock")
        try require(recalled[0].record.details.contains("Vaccination: planned, not completed") && recalled[0].record.details.contains("Shelter: north"), "typed fact or care lost qualification")
        let evidence = try repository.memoryEvidence(recalled[0].id)
        try require(Set(evidence[0].domainSources.map(\.id)).isSuperset(of: [corrected.id, loss.id, care.id, fact.id]), "derived memory lost exact source evidence")
        try require(evidence[0].domainSources.contains { $0.id == loss.id && $0.text == "Two hens left the flock." }, "loss source span not preserved")
        try require(try repository.eligibleMemory(first, bankScope: "farm").isEmpty, "stale admitted projection remained valid")
        let entries = try repository.domainEntries(entity, scope: "farm")
        try require(try NativeDomainProjection.stock(entries, entity: entity, scope: "farm", at: Date(timeIntervalSince1970: 15)).quantity?.amount == "12", "historical state missing")
        var settings = NativeMemorySettings.fresh
        settings.enabled = true
        settings.bankScope = "farm"
        let model = SelfTestNativeTransport(), service = SelfTestMemoryService()
        let store = ChatStore(nativeConfig: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!,
            apiKey: nil, model: "local-model", chatTemplateKwargs: nil), nativeTransport: model,
            repository: repository, nativeMemorySettings: settings, nativeMemoryService: service)
        store.newConversation()
        store.sendText("Current livestock and care?")
        for _ in 0..<200 where store.generating { try await Task.sleep(for: .milliseconds(10)) }
        let nativePrompt = model.histories.last?.first?.content ?? ""
        try require(nativePrompt.contains("Current count: 10") && nativePrompt.contains("planned, not completed"), "native foreground missed typed state")
        let bridge = NativeRuntimeMemoryBridge(store: store)
        let assistant = UUID().uuidString.lowercased()
        try bridge.bindAssistant(assistant)
        for (role, mode) in [("foreground", "focused"), ("foreground", "assistant"), ("worker", "assistant")] {
            let binding = NativeRuntimeMemorySelftest.binding(assistant, role: role, mode: mode)
            try bridge.authorize(binding, query: "Current livestock and care?")
            let request = try await bridge.prepare(NativeRuntimeMemorySelftest.request(binding))
            let prompt = request.messages.first!.pi("content").piString!
            try require(prompt.contains("Current count: 10") && prompt.contains("planned, not completed"), "Pi entry point missed shared domain state")
            try require(request.memoryContext?.selected.map(\.id) == recalled.map(\.id), "Pi selected a different domain identity")
        }
        try require(service.embedCalls == 0 && service.extractionCalls == 0, "synthetic typed state test called a model")
        var bypass = recalled[0].record
        bypass.domainEntityID = nil
        bypass.domainRevision = nil
        bypass.summary = "Current count: 999"
        try rejected { try repository.saveMemory(bypass, decision: .edited, note: "Synthetic bypass", expected: recalled[0].record) }
        var proposalBypass = correction
        proposalBypass.domain = nil
        try rejected { try repository.saveProposal(proposalBypass) }
        let source = loss.source!
        try await repository.database.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [source.messageID])
        }
        try require(try repository.recallMemory("Livestock", bankScope: "farm").isEmpty, "deleted source left derived FTS text")
        let tombstone = try repository.domainEntries(entity, scope: "farm").first { $0.id == loss.id }!
        try require(tombstone.status == .deleted && tombstone.payload == nil && tombstone.source == nil && tombstone.actor == nil, "deleted source payload retained")
        try require(!store.memorySelectionIsCurrent(recalled), "deleted source survived admission validation")
        try repository.refreshDomainProjections()
        let uncertain = try repository.approvedMemories().first!
        try require(uncertain.summary.contains("removed") && !uncertain.details.contains("Current count: 12"), "deleted loss resurrected animals")
        try require(uncertain.id != recalled[0].id, "source invalidation reused historical citation identity")
        try rejected { try repository.stageDomainProposal(loss, label: "Livestock").map { _ in () } }
        try repository.deleteMemory(uncertain.id)
        repository = try LocalChatRepository(url: url)
        try repository.refreshDomainProjections()
        try require(try repository.approvedMemories().isEmpty, "deleted projection recreated after restart")
        try require(try repository.domainEntries(entity, scope: "farm").allSatisfy { $0.payload == nil && $0.source == nil }, "projection deletion retained private payload")
        try require(try repository.stageDomainProposal(fact, label: "Livestock") == nil, "deleted identity replayed")
        try await privacyAndValidation()
        try await migrationAndRestore(directory)
        try await correctionPrivacy()
        try futureClear(directory)
        print("domain-repository: PASS (review transaction, CAS, duplicate/rejection, exact spans, correction/history/restart, native/Pi shared retrieval, privacy and deletion; synthetic typed inputs)")
    }

    static func privacyAndValidation() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let entity = UUID()
        let valid = try fixture(repository, entity: entity, text: "Café flock has four hens.", at: 10,
            payload: .stock(kind: .baseline, quantity: NativeDomainQuantity("4", unit: .count)))
        let source = valid.source!
        let broken = NativeDomainEntry(id: UUID(), entityID: entity, scope: valid.scope, occurredAt: valid.occurredAt,
            validUntil: nil, learnedAt: valid.learnedAt, actor: valid.actor,
            source: NativeDomainSource(conversationID: source.conversationID, messageID: source.messageID, version: source.version, lowerUTF8: 4, upperUTF8: 5),
            evidence: .asserted, entityResolved: true, status: .supported, supersedes: [], payload: valid.payload)
        try rejected { _ = try repository.stageDomainProposal(broken, label: "Flock") }
        let pending = try repository.stageDomainProposal(valid, label: "Flock")!
        try await repository.database.write { db in
            try db.execute(sql: "UPDATE messages SET content = 'Changed source' WHERE id = ?", arguments: [source.messageID])
        }
        try rejected { try repository.approveDomainProposal(pending) }
        try require(try repository.pendingProposals().isEmpty, "source edit retained pending private evidence")
        let label = try await repository.database.read { db in try String.fetchOne(db, sql: "SELECT label FROM native_domain_streams WHERE entity_id = ?", arguments: [entity.uuidString]) }
        try require(label == "Saved record", "unapproved label survived source invalidation")
        for operation in ["exclude", "delete"] {
            let entry = try fixture(repository, entity: UUID(), text: "Synthetic private flock has seven hens.", at: 10,
                payload: .stock(kind: .baseline, quantity: NativeDomainQuantity("7", unit: .count)))
            try repository.approveDomainProposal(repository.stageDomainProposal(entry, label: "Flock")!)
            try await repository.database.write { db in
                if operation == "exclude" {
                    try db.execute(sql: "UPDATE conversations SET memory_excluded = 1 WHERE id = ?", arguments: [entry.source!.conversationID])
                } else { try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [entry.source!.conversationID]) }
            }
            try require(try repository.domainEntries(entry.entityID, scope: "farm").allSatisfy { $0.payload == nil }, "source privacy did not redact journal")
        }
    }
    static func migrationAndRestore(_ directory: URL) async throws {
        let path = directory.appendingPathComponent("populated-v15.sqlite")
        let backup = directory.appendingPathComponent("rollback-v15.sqlite")
        var legacy: LocalChatRepository? = try LocalChatRepository(url: path)
        _ = try NativeRuntimeMemorySelftest.fixture(legacy!)
        let original = try legacy!.allMemories()
        try await legacy!.database.write { db in
            for name in ["domain_entry_redaction", "domain_source_message_change", "domain_source_message_delete", "domain_source_exclusion", "domain_source_conversation_delete"] {
                try db.execute(sql: "DROP TRIGGER " + name)
            }
            try db.execute(sql: "DROP TABLE native_domain_projection_sources; DROP TABLE native_domain_entries; DROP TABLE native_domain_streams; DELETE FROM grdb_migrations WHERE identifier = 'nativeDomainStateV16'")
        }
        try await legacy!.database.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [backup.path])
        }
        legacy = nil
        var migrated: LocalChatRepository? = try LocalChatRepository(url: path)
        try require(try migrated!.allMemories() == original, "V16 migration changed populated legacy records")
        let migrations = try await migrated!.database.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        try require(migrations.contains("nativeDomainStateV16"), "populated migration did not run")
        let typed = try fixture(migrated!, entity: UUID(), text: "Migration fixture has five hens.", at: 10,
            payload: .stock(kind: .baseline, quantity: NativeDomainQuantity("5", unit: .count)))
        try migrated!.approveDomainProposal(migrated!.stageDomainProposal(typed, label: "Migration fixture")!)
        migrated = nil
        let reopened = try LocalChatRepository(url: path)
        try require(try reopened.domainEntries(typed.entityID, scope: "farm").count == 1, "typed migration state did not reopen")
        let restoredPath = directory.appendingPathComponent("restored.sqlite")
        try FileManager.default.copyItem(at: backup, to: restoredPath)
        let restored = try DatabaseQueue(path: restoredPath.path)
        let restoredState = try await restored.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'nativeDomainStateV16'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_memories"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages"),
             try String.fetchOne(db, sql: "PRAGMA integrity_check"))
        }
        try require(restoredState.0 == 0 && restoredState.1 == original.count && restoredState.2 == 1 && restoredState.3 == "ok",
                    "restored pre-migration copy did not retain schema/data integrity")
    }

    static func correctionPrivacy() async throws {
        for accepted in [false, true] {
            let repository = try LocalChatRepository(inMemory: true)
            let entity = UUID()
            let old = try fixture(repository, entity: entity, text: "Private marker cedar: shelter is red.", at: 10,
                payload: .fact(predicate: "Shelter color", value: "red cedar", quantity: nil))
            try repository.approveDomainProposal(repository.stageDomainProposal(old, label: "Cedar shelter")!)
            let correction = try fixture(repository, entity: entity, text: "Correction: shelter is blue.", at: 20,
                payload: .fact(predicate: "Shelter color", value: "blue", quantity: nil), supersedes: [old.id])
            let proposal = try repository.stageDomainProposal(correction, label: "Shelter")!
            let display = proposal.details.joined(separator: "\n")
            try require(display.contains("Applies from:") && display.contains("Library: farm") && display.contains("Attributed to: user")
                && display.contains("Replaces:") && display.contains("Private marker cedar"), "typed review omitted material meaning or target evidence")
            if accepted { try repository.approveDomainProposal(proposal) }
            try await repository.database.write { db in
                try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [old.source!.messageID])
            }
            let residue = try await repository.database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_memory_proposals WHERE proposal_json LIKE '%cedar%'")
            }
            try require(residue == 0, "cross-source correction retained deleted target payload")
            try repository.refreshDomainProjections()
            let records = try repository.approvedMemories()
            try require(!records.contains { $0.details.joined().contains("red cedar") }, "deleted old fact was restored")
            if accepted {
                try await repository.database.write { db in try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [correction.source!.messageID]) }
                try repository.refreshDomainProjections()
                try require(!(try repository.approvedMemories()).contains { $0.details.joined().contains("red cedar") }, "deleted correction restored old fact")
            }
        }
        let repository = try LocalChatRepository(inMemory: true)
        let entity = UUID()
        let completed = try fixture(repository, entity: entity, text: "Vaccination completed.", at: 10,
            payload: .care(activity: "Vaccination", status: .completed))
        try repository.approveDomainProposal(repository.stageDomainProposal(completed, label: "Care")!)
        let correction = try fixture(repository, entity: entity, text: "Correction: vaccination did not occur.", at: 20,
            payload: .care(activity: "Vaccination", status: .notOccurred), supersedes: [completed.id])
        try repository.approveDomainProposal(repository.stageDomainProposal(correction, label: "Care")!)
        try await repository.database.write { db in try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [correction.source!.messageID]) }
        try repository.refreshDomainProjections()
        try require(!(try repository.approvedMemories()).contains { $0.details.contains("Vaccination: completed") }, "care correction deletion restored completion")
    }

}
