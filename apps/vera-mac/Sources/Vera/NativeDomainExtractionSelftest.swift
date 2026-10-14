import Foundation
import GRDB

@MainActor
enum NativeDomainExtractionSelftest {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("domain-extraction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try parser()
        print("  parser: PASS (kinds, units, dates, wrong types, cap)")
        try await livestock(directory, reviewLater: false)
        print("  livestock end to end: PASS (baseline, correction across chats, loss, planned care, approve each turn, reopen)")
        try await livestock(directory, reviewLater: true)
        print("  livestock reviewed later: PASS (all four turns pending, correction waits, approve in order, reopen reads 8)")
        try await dismissedTarget(directory)
        print("  dismissed correction target: PASS (correction rebuilt without it, retraction dropped and audited)")
        try await removedReplay(directory)
        print("  removed record replay: PASS (deleted memory not suggested again, audited)")
        try await refreshedSource(directory)
        print("  refreshed source: PASS (stale pending proposal replaced with the new source version)")
        try await subjectKey(directory)
        print("  subject key: PASS (Écrevisses and écrevisses join one subject)")
        try await unreadable(directory)
        print("  unreadable output: PASS (truncated response audited, nothing proposed)")
        try await evidenceModes(directory)
        print("  evidence modes: PASS (negated, hypothetical, reported, ambiguous never move stock)")
        try await spanMismatch(directory)
        print("  span mismatch: PASS (rejected and audited, free-text proposal kept)")
        try await idempotent(directory)
        print("  idempotent rerun: PASS (no duplicate proposals or entries)")
        try await generationOffMidTurn(directory)
        print("  generation off mid-turn: PASS (no domain proposals, no audit)")
        try await runtimeParity(directory)
        print("  native and Pi parity: PASS (same request, same free-text proposals, same candidates)")
        try await malformed(directory)
        print("  malformed entries: PASS (free-text only, each skip audited)")
        try await gating(directory)
        print("  gating: PASS (memory off, excluded, private, credential and sensitive turns)")
        print("domain-extraction: PASS")
    }

    static func require(_ condition: Bool, _ reason: String) throws {
        guard condition else {
            throw NSError(domain: "DomainExtractionTest", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    static func entry(_ subject: String, _ kind: String, quantity: Any? = nil, unit: String? = nil, property: String? = nil,
                      value: String? = nil, date: String? = nil, evidence: String = "asserted", supersedes: String? = nil,
                      span: String, scope: String = "personal") -> [String: Any] {
        [
            "subject": subject, "scope": scope, "kind": kind, "quantity": quantity ?? NSNull(), "unit": unit ?? NSNull(),
            "property": property ?? NSNull(), "value": value ?? NSNull(), "occurred_at": date ?? NSNull(),
            "evidence": evidence, "supersedes": supersedes ?? NSNull(), "span": span,
        ]
    }

    static func content(_ title: String, _ entries: Any) -> String {
        let object: [String: Any] = [
            "proposals": [[
                "kind": "create", "title": title, "summary": "Keeps track of " + title.lowercased(),
                "details": ["The user keeps track of " + title.lowercased()], "group": "Areas", "category": "project",
                "bank": "personal", "durability": "durable", "expiry": NSNull(), "target_ids": [String](),
            ]],
            "domain_entries": entries,
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func settings(enabled: Bool = true, generate: Bool = true,
                         sensitive: NativeMemorySensitiveHandling = .neverStore) -> NativeMemorySettings {
        var settings = NativeMemorySettings.fresh
        settings.enabled = enabled
        settings.generateFromChats = generate
        settings.extractionModel = "fixture-extraction"
        settings.sensitiveHandling = sensitive
        return settings
    }

    static func store(_ repository: LocalChatRepository, _ service: DomainExtractionService,
                      settings: NativeMemorySettings = settings()) -> ChatStore {
        ChatStore(nativeConfig: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!,
            apiKey: nil, model: "local-model", chatTemplateKwargs: nil), nativeTransport: SelfTestNativeTransport(),
            repository: repository, nativeMemorySettings: settings, nativeMemoryService: service)
    }

    static func turn(_ repository: LocalChatRepository, _ text: String, conversation: String = UUID().uuidString,
                     at date: Date = Date()) throws -> NativeMemoryTurnSource {
        let user = Message(role: .user, text: text, createdAt: date)
        try repository.saveConversation(Conversation(id: conversation, title: "Fixture", messages: [], updatedAt: date))
        try repository.saveMessage(user, conversationID: conversation, ordinal: 0)
        try repository.saveMessage(Message(role: .assistant, text: "Noted."), conversationID: conversation, ordinal: 1)
        return NativeMemoryTurnSource(conversationID: conversation, messageID: user.id.uuidString, date: date)
    }

    static func learn(_ store: ChatStore, _ text: String, _ source: NativeMemoryTurnSource?, excluded: Bool = false) async {
        await store.learnFromCompletedTurn(user: text, assistant: Message(role: .assistant, text: "Noted."), source: source,
            turnKey: (source?.conversationID ?? "none") + "|" + (source?.messageID ?? text), conversationExcluded: excluded)
    }

    static func domainPending(_ repository: LocalChatRepository) throws -> [NativeMemoryProposal] {
        try repository.pendingProposals().filter { $0.domain != nil }
    }

    static func audits(_ repository: LocalChatRepository) throws -> [String] {
        try repository.memoryChanges(limit: 500).map(\.note).filter { $0.hasPrefix(LocalChatRepository.domainSkipNote) }
    }

    static func span(_ proposal: NativeMemoryProposal, in text: String) -> String? {
        guard let source = proposal.domain?.entry.source else { return nil }
        let bytes = Array(text.utf8)
        guard source.upperUTF8 <= bytes.count else { return nil }
        return String(bytes: bytes[source.lowerUTF8..<source.upperUTF8], encoding: .utf8)
    }

    static func waitFor(_ reason: String, _ condition: () throws -> Bool) async throws {
        for _ in 0..<600 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "DomainExtractionTest", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    static func send(_ store: ChatStore, _ service: DomainExtractionService, _ text: String) async throws {
        let before = service.finished
        store.sendText(text)
        try await waitFor("turn did not finish: " + text) { !store.generating && service.finished > before }
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)) }
    }

    static func parser() throws {
        let raw = content("Parser", [
            entry("Hens", "baseline", quantity: 1, unit: "dozen", span: "a dozen hens"),
            entry("Feed", "fact", quantity: 2.5, unit: "kilogram", property: "Daily feed", value: "two and a half kilos", span: "feed"),
            entry("Hens", "not_occurred", property: "Vaccination", date: "2026-03-04", evidence: "negated", span: "no vaccine"),
            entry("Hens", "retraction", supersedes: "Hens", span: "ignore that"),
            entry("Hens", "addition", quantity: 1.5, span: "half a hen"),
            entry("Hens", "baseline", quantity: true, span: "true hens"),
        ])
        let parsed = NativeDomainCandidateParser.parse(raw)
        try require(parsed.candidates.count == 4, "parser kept \(parsed.candidates.count) of 4 valid entries")
        try require(parsed.candidates[0].payload == .stock(kind: .baseline, quantity: try NativeDomainQuantity("12", unit: .count)),
                    "dozen did not normalize to a count of 12")
        try require(parsed.candidates[1].payload == .fact(predicate: "Daily feed", value: "two and a half kilos",
                    quantity: try NativeDomainQuantity("2.5", unit: .kilogram)), "fact with quantity mis-parsed")
        try require(parsed.candidates[2].payload == .care(activity: "Vaccination", status: .notOccurred)
                    && parsed.candidates[2].evidence == .negated && day(parsed.candidates[2].occurredAt ?? .distantPast) == "2026-03-04",
                    "care, evidence or date mis-parsed")
        try require(parsed.candidates[3].payload == .retraction && parsed.candidates[3].supersedes == "Hens", "retraction mis-parsed")
        try require(parsed.skipped == ["the quantity is not valid", "the quantity is not a number"],
                    "parser skips were \(parsed.skipped)")
        let capped = NativeDomainCandidateParser.parse(content("Cap", (0..<10).map { entry("Hens", "mention", quantity: $0 + 1, span: "hens") }))
        try require(capped.candidates.count == 8 && capped.skipped == Array(repeating: "more than 8 entries in one turn", count: 2),
                    "cap of 8 not enforced")
        let empty = NativeDomainCandidateParser.parse(#"{"proposals":[]}"#)
        try require(empty.candidates.isEmpty && empty.skipped.isEmpty, "missing entries produced candidates or audits")
    }

    static func livestock(_ directory: URL, reviewLater: Bool) async throws {
        DomainExtractionWire.state.reset()
        let url = directory.appendingPathComponent(reviewLater ? "livestock-later.sqlite" : "livestock.sqlite")
        let repository = try LocalChatRepository(url: url)
        let service = DomainExtractionService()
        let store = store(repository, service)
        let planned = day(Date().addingTimeInterval(30 * 86_400))
        let steps: [(text: String, quote: String, payload: NativeDomainPayload, reply: String)] = [
            ("We have twelve hens.", "We have twelve hens", .stock(kind: .baseline, quantity: try NativeDomainQuantity("12", unit: .count)),
             content("Flock", [entry("Hens", "baseline", quantity: 12, span: "We have twelve hens")])),
            ("Actually it's ten, I miscounted.", "Actually it's ten", .stock(kind: .baseline, quantity: try NativeDomainQuantity("10", unit: .count)),
             content("Flock count", [entry("Hens", "baseline", quantity: 10, supersedes: "Hens", span: "Actually it's ten")])),
            ("We lost two to a fox.", "We lost two to a fox", .stock(kind: .removal, quantity: try NativeDomainQuantity("2", unit: .count)),
             content("Fox", [entry("Hens", "removal", quantity: 2, span: "We lost two to a fox")])),
            ("Vaccination is planned for next month.", "Vaccination is planned for next month", .care(activity: "Vaccination", status: .planned),
             content("Flock care", [entry("Hens", "planned", property: "Vaccination", date: planned, span: "Vaccination is planned for next month")])),
        ]
        for step in steps { DomainExtractionWire.state.respond(step.text, step.reply) }
        store.newConversation()
        let chatA = store.selectedID
        var staged: [NativeMemoryProposal] = []
        for (index, step) in steps.enumerated() {
            if index == 1 {
                store.newConversation()
                try require(store.selectedID != chatA, "second chat reused the first conversation")
            }
            try await send(store, service, step.text)
            let fresh = try domainPending(repository).filter { item in !staged.contains { $0.id == item.id } }
            try require(fresh.count == 1, "expected one typed proposal for \"\(step.text)\", found \(fresh.count)")
            let proposal = fresh[0]
            try require(span(proposal, in: step.text) == step.quote, "proposal span for \"\(step.text)\" was not the exact quoted text")
            try require(proposal.domain?.entry.payload == step.payload, "proposal kind for \"\(step.text)\" was \(String(describing: proposal.domain?.entry.payload))")
            try require(proposal.details.contains("Original evidence: " + step.quote), "review text omitted the original evidence")
            try require(proposal.sourceVersion == LocalChatRepository.domainHash(step.text), "typed proposal missing its source version")
            try require(proposal.domain?.label == "Hens", "typed proposal label was not the subject")
            try require(try repository.pendingProposals().contains { $0.domain == nil && $0.sourceMessageID == proposal.sourceMessageID },
                        "free-text proposal from the same turn missing")
            if index > 0 {
                try require(proposal.domain?.entry.entityID == staged[0].domain?.entry.entityID, "\"\(step.text)\" resolved to a different subject")
            }
            if index == 1 {
                try require(proposal.domain?.entry.supersedes == [staged[0].domain!.entry.id], "correction did not supersede the earlier count")
                try require(proposal.details.contains { $0.hasPrefix("Replaces: Observed count: 12") }
                            && proposal.details.contains("Earlier evidence: We have twelve hens"), "correction review omitted what it replaces")
            } else {
                try require(proposal.domain?.entry.supersedes == [], "\"\(step.text)\" superseded a record")
            }
            staged.append(proposal)
            if index == 0 { try require(try repository.approvedMemories().isEmpty, "typed proposal changed memory before review") }
            if !reviewLater { try require(store.acceptMemoryProposal(proposal), "approving \"\(step.text)\" failed") }
        }
        func current(_ proposal: NativeMemoryProposal) throws -> NativeMemoryProposal {
            guard let found = try repository.pendingProposals().first(where: { $0.id == proposal.id }) else {
                throw NSError(domain: "DomainExtractionTest", code: 5, userInfo: [NSLocalizedDescriptionKey: "pending proposal disappeared before review"])
            }
            return found
        }
        if reviewLater {
            try require(try repository.approvedMemories().isEmpty, "reviewing later changed memory early")
            try require(!store.acceptMemoryProposal(try current(staged[1])), "correction accepted before the record it corrects")
            for proposal in staged {
                try require(store.acceptMemoryProposal(try current(proposal)), "approving \"\(proposal.details.last ?? "")\" in order failed")
            }
        }
        try require(try domainPending(repository).isEmpty, "typed proposals left pending after approval")
        let entity = staged[0].domain!.entry.entityID
        let (baseline, correction, loss, care) = (staged[0], staged[1], staged[2], staged[3])
        try require(day(care.domain!.entry.occurredAt) == planned, "planned care lost its absolute date")

        let reopened = try LocalChatRepository(url: url)
        let fresh = Self.store(reopened, DomainExtractionService())
        fresh.loadMemoryLibrary()
        guard let memory = fresh.memoryRecords.first(where: { $0.domainEntityID == entity }) else {
            throw NSError(domain: "DomainExtractionTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "reopened store lost the Hens memory"])
        }
        try require(memory.title == "Hens" && memory.details.contains("Current count: 8"), "reopened memory read \(memory.details)")
        let upcoming = try reopened.upcomingDomainCare()[memory.id] ?? []
        try require(upcoming.map(\.id) == [care.domain!.entry.id], "planned vaccination not listed as upcoming care")
        let evidence = try reopened.memoryEvidence(memory.id)
        let sources = evidence.first?.domainSources ?? []
        try require(sources.contains { $0.id == correction.domain!.entry.id && $0.text == "Actually it's ten" && !$0.superseded }
                    && sources.contains { $0.id == loss.domain!.entry.id && $0.text == "We lost two to a fox" },
                    "decisive sources for the count missing")
        try require(!sources.contains { $0.id == baseline.domain!.entry.id && !$0.superseded }, "corrected count still decisive")
        let later = Date().addingTimeInterval(32 * 86_400)
        fresh.loadMemoryLibrary(now: later)
        guard let due = fresh.memoryRecords.first(where: { $0.domainEntityID == entity }) else {
            throw NSError(domain: "DomainExtractionTest", code: 4, userInfo: [NSLocalizedDescriptionKey: "Hens memory missing after the planned date"])
        }
        try require(due.details.contains("Current count: 8") && due.details.contains("Vaccination: planned, not completed"),
                    "memory after the planned date read \(due.details)")
        let dueSources = try reopened.domainCitations(due.id, revision: try reopened.memoryEvidence(due.id).first!.revision, now: later)
        try require(dueSources.contains { $0.id == care.domain!.entry.id && $0.text == "Vaccination is planned for next month" },
                    "planned care lost its decisive source")
    }

    static func dismissedTarget(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("dismissed-target.sqlite"))
        let store = store(repository, DomainExtractionService())
        let start = Date().addingTimeInterval(-3_600)
        let texts = ["We have nine geese.", "Correction: seven geese.", "Ignore the geese count."]
        DomainExtractionWire.state.respond(texts[0], content("Geese", [entry("Geese", "baseline", quantity: 9, span: "We have nine geese")]))
        DomainExtractionWire.state.respond(texts[1], content("Geese count", [entry("Geese", "baseline", quantity: 7, supersedes: "Geese", span: "seven geese")]))
        DomainExtractionWire.state.respond(texts[2], content("Geese note", [entry("Geese", "retraction", supersedes: "Geese", span: "Ignore the geese count")]))
        for (index, text) in texts.enumerated() {
            await learn(store, text, try turn(repository, text, at: start.addingTimeInterval(Double(index) * 60)))
        }
        let pending = try domainPending(repository)
        try require(pending.count == 3, "pending corrections were not staged against the pending count, found \(pending.count)")
        let first = pending.first { $0.summary == "Observed count: 9" }!
        let correction = pending.first { $0.summary == "Observed count: 7" }!
        try require(!store.acceptMemoryProposal(correction), "correction accepted before the record it corrects")
        store.dismissMemoryProposal(correction)
        try require(try domainPending(repository).map(\.id) == [first.id], "retraction of a dismissed record was kept")
        try require(try audits(repository).contains(LocalChatRepository.domainSkipNote + "the record it corrects was dismissed"),
                    "dropped retraction was not audited")
        let again = "Correction: eight geese."
        DomainExtractionWire.state.respond(again, content("Geese recount", [entry("Geese", "baseline", quantity: 8, supersedes: "Geese", span: "eight geese")]))
        await learn(store, again, try turn(repository, again, at: start.addingTimeInterval(240)))
        guard let recount = try domainPending(repository).first(where: { $0.summary == "Observed count: 8" }) else {
            throw NSError(domain: "DomainExtractionTest", code: 7, userInfo: [NSLocalizedDescriptionKey: "second correction was not staged"])
        }
        try require(recount.domain?.entry.supersedes == [first.domain!.entry.id], "second correction did not target the pending count")
        store.dismissMemoryProposal(first)
        let left = try domainPending(repository)
        try require(left.count == 1 && left[0].id == recount.id, "dependent records after dismissal were \(left.map(\.summary))")
        try require(left[0].domain?.entry.supersedes == [] && !left[0].details.contains { $0.hasPrefix("Replaces:") },
                    "correction still points at the dismissed record")
        try require(store.acceptMemoryProposal(left[0]), "rebuilt correction could not be accepted")
        try require(try repository.approvedMemories().contains { $0.title == "Geese" && $0.details.contains("Current count: 8") },
                    "rebuilt correction did not become the count")
    }

    static func removedReplay(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("removed-replay.sqlite"))
        let store = store(repository, DomainExtractionService())
        let text = "We keep three alpacas."
        DomainExtractionWire.state.respond(text, content("Alpacas", [entry("Alpacas", "baseline", quantity: 3, span: "We keep three alpacas")]))
        let source = try turn(repository, text)
        await learn(store, text, source)
        let staged = try domainPending(repository)
        try require(staged.count == 1 && store.acceptMemoryProposal(staged[0]), "alpaca count was not staged and approved")
        guard let memory = try repository.approvedMemories().first(where: { $0.title == "Alpacas" }) else {
            throw NSError(domain: "DomainExtractionTest", code: 6, userInfo: [NSLocalizedDescriptionKey: "alpaca memory missing"])
        }
        store.deleteNativeMemory(memory)
        await learn(store, text, source)
        try require(try domainPending(repository).isEmpty, "removed record was suggested again")
        let streams = try await repository.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_domain_streams WHERE disabled = 0") ?? 0
        }
        try require(streams == 0, "removed record created a new subject")
        try require(try audits(repository).contains(LocalChatRepository.domainSkipNote + "this record was removed"),
                    "removed replay was not audited")
    }

    static func refreshedSource(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("refreshed-source.sqlite"))
        let store = store(repository, DomainExtractionService())
        let original = "We keep bees", edited = "We keep bees."
        DomainExtractionWire.state.respond(original, content("Bees", []))
        DomainExtractionWire.state.respond(edited, content("Bees", []))
        let conversation = UUID().uuidString
        let user = Message(role: .user, text: original)
        try repository.saveConversation(Conversation(id: conversation, title: "Fixture", messages: [], updatedAt: Date()))
        try repository.saveMessage(user, conversationID: conversation, ordinal: 0)
        try repository.saveMessage(Message(role: .assistant, text: "Noted."), conversationID: conversation, ordinal: 1)
        let source = NativeMemoryTurnSource(conversationID: conversation, messageID: user.id.uuidString, date: user.createdAt)
        await learn(store, original, source)
        var changed = user
        changed.text = edited
        try repository.saveMessage(changed, conversationID: conversation, ordinal: 0)
        await learn(store, edited, source)
        let pending = try repository.pendingProposals().filter { $0.title == "Bees" }
        try require(pending.count == 1, "refreshed source left \(pending.count) pending proposals")
        try require(pending[0].sourceVersion == LocalChatRepository.memorySourceVersion(edited), "pending proposal kept the stale source version")
        try require(store.acceptMemoryProposal(pending[0]), "refreshed proposal could not be accepted")
    }

    static func subjectKey(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("subject-key.sqlite"))
        let store = store(repository, DomainExtractionService())
        let start = Date().addingTimeInterval(-3_600)
        let first = "We keep twenty Écrevisses in the tank.", second = "We lost three  écrevisses overnight."
        DomainExtractionWire.state.respond(first, content("Crayfish", [entry("Écrevisses", "baseline", quantity: 20, span: "twenty Écrevisses")]))
        DomainExtractionWire.state.respond(second, content("Crayfish loss", [entry("écrevisses ", "removal", quantity: 3, span: "We lost three")]))
        await learn(store, first, try turn(repository, first, at: start))
        let baseline = try domainPending(repository)
        try require(baseline.count == 1 && store.acceptMemoryProposal(baseline[0]), "Écrevisses count was not staged and approved")
        await learn(store, second, try turn(repository, second, at: start.addingTimeInterval(60)))
        let loss = try domainPending(repository)
        try require(loss.count == 1 && loss[0].domain?.entry.entityID == baseline[0].domain?.entry.entityID,
                    "a differently cased subject started a new subject")
        try require(store.acceptMemoryProposal(loss[0]), "removal on the shared subject could not be accepted")
        try require(try repository.approvedMemories().contains { $0.title == "écrevisses" && $0.details.contains("Current count: 17") },
                    "shared subject did not read Current count: 17")
    }

    static func unreadable(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("unreadable.sqlite"))
        let store = store(repository, DomainExtractionService())
        let text = "We have four turkeys."
        let full = content("Turkeys", [entry("Turkeys", "baseline", quantity: 4, span: "We have four turkeys")])
        DomainExtractionWire.state.respond(text, String(full.prefix(full.count / 2)))
        await learn(store, text, try turn(repository, text))
        try require(try repository.pendingProposals().isEmpty, "truncated output produced proposals")
        try require(try audits(repository) == [LocalChatRepository.domainSkipNote + "the typed records could not be read"],
                    "truncated output audits were \(try audits(repository))")
    }

    static func evidenceModes(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("evidence.sqlite"))
        let service = DomainExtractionService()
        let store = store(repository, service)
        let start = Date().addingTimeInterval(-3_600)
        let base = "We have five goats."
        DomainExtractionWire.state.respond(base, content("Goats", [entry("Goats", "baseline", quantity: 5, span: "We have five goats")]))
        await learn(store, base, try turn(repository, base, at: start))
        let first = try domainPending(repository)
        try require(first.count == 1 && store.acceptMemoryProposal(first[0]), "goat baseline was not staged and approved")
        let entity = first[0].domain!.entry.entityID
        let cases: [(NativeDomainEvidence, String, String, String)] = [
            (.negated, "We did not lose a goat.", "We did not lose a goat", "Source denies this: "),
            (.hypothetical, "If we sell two goats we would have three.", "If we sell two goats", "Hypothetical, not established: "),
            (.reported, "My neighbor says we lost three goats.", "My neighbor says we lost three goats", "Reported by someone else, unconfirmed: "),
            (.ambiguous, "Maybe a goat wandered off.", "Maybe a goat wandered off", "Meaning unclear: "),
        ]
        for (offset, (mode, text, quote, prefix)) in cases.enumerated() {
            let amount = [1, 2, 3, 1][offset]
            DomainExtractionWire.state.respond(text, content("Goat note " + String(offset), [
                entry("Goats", "removal", quantity: amount, evidence: mode.rawValue, span: quote)]))
            await learn(store, text, try turn(repository, text, at: start.addingTimeInterval(Double(offset + 1) * 60)))
            let pending = try domainPending(repository)
            try require(pending.count == 1, "\(mode.rawValue) statement did not become one typed proposal")
            try require(pending[0].domain?.entry.evidence == mode && pending[0].domain?.entry.entityID == entity,
                        "\(mode.rawValue) statement lost its evidence mode or subject")
            try require(pending[0].summary.hasPrefix(prefix), "\(mode.rawValue) review text did not qualify the statement")
            try require(store.acceptMemoryProposal(pending[0]), "\(mode.rawValue) approval failed")
            let entries = try repository.domainEntries(entity, scope: "personal")
            try require(entries.contains { $0.evidence == mode }, "\(mode.rawValue) entry missing from the journal")
            let count = try NativeDomainProjection.stock(entries, entity: entity, scope: "personal", at: Date()).quantity?.amount
            try require(count == nil || count == "5", "\(mode.rawValue) statement moved stock to \(count ?? "nil")")
            let memory = try repository.approvedMemories().first { $0.domainEntityID == entity }
            try require(!(memory?.details ?? []).contains { $0.hasPrefix("Current count: ") && $0 != "Current count: 5" },
                        "\(mode.rawValue) statement changed the projected count")
        }
    }

    static func spanMismatch(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("span.sqlite"))
        let store = store(repository, DomainExtractionService())
        let text = "We have 9 ducks on the pond."
        DomainExtractionWire.state.respond(text, content("Ducks", [entry("Ducks", "baseline", quantity: 9, span: "We have nine ducks")]))
        let source = try turn(repository, text)
        await learn(store, text, source)
        try require(try domainPending(repository).isEmpty, "a span that does not match was staged")
        try require(try repository.pendingProposals().contains { $0.title == "Ducks" && $0.sourceMessageID == source.messageID },
                    "free-text proposal from the same turn did not land")
        try require(try audits(repository) == ["domain entry skipped: the quoted text does not match the message"],
                    "span rejection audit was \(try audits(repository))")
        let streams = try await repository.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_domain_streams") ?? 0 }
        try require(streams == 0, "rejected span left a subject behind")
    }

    static func idempotent(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("idempotent.sqlite"))
        let service = DomainExtractionService()
        let store = store(repository, service)
        let text = "The hive holds two supers and the bees are calm."
        DomainExtractionWire.state.respond(text, content("Bees", [
            entry("Bees", "fact", property: "Supers", value: "two", span: "The hive holds two supers"),
            entry("Bees", "fact", property: "Temper", value: "calm", span: "the bees are calm"),
        ]))
        let source = try turn(repository, text)
        await learn(store, text, source)
        await learn(store, text, source)
        try require(service.calls == 2, "rerun did not call extraction twice")
        try require(try domainPending(repository).count == 2, "rerun duplicated typed proposals")
        try require(try repository.pendingProposals().filter { $0.domain == nil }.count == 1, "rerun duplicated the free-text proposal")
        let first = try domainPending(repository)
        try require(store.acceptMemoryProposal(first[0]), "first fact approval failed")
        let rebased = try domainPending(repository)
        try require(rebased.count == 1 && rebased[0].id == first[1].id && rebased[0].domain?.expectedRevision == 1,
                    "sibling typed proposal was not rebased after the first approval")
        try require(store.acceptMemoryProposal(rebased[0]), "second fact from the same turn could not be approved")
        await learn(store, text, source)
        let entity = try domainPending(repository).first?.domain?.entry.entityID
        try require(entity == nil, "rerun after approval staged a new typed proposal")
        let entries = try await repository.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_domain_entries") ?? 0 }
        try require(entries == 2, "rerun after approval added journal entries")
        try require(try repository.approvedMemories().filter { $0.domainEntityID != nil }.count == 1,
                    "both facts did not land on one subject")
    }

    static func generationOffMidTurn(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("midturn.sqlite"))
        let service = DomainExtractionService()
        let store = store(repository, service)
        let text = "We keep four rabbits."
        DomainExtractionWire.state.respond(text, content("Rabbits", [
            entry("Rabbits", "baseline", quantity: 4, span: "We keep four rabbits"),
            entry("Rabbits", "fact", property: "Housing", value: "hutch", span: "rabbits"),
            ["subject": 3],
        ]))
        service.onExtract = { @MainActor in store.updateNativeMemory(settings: settings(generate: false), service: service) }
        await learn(store, text, try turn(repository, text))
        try require(service.calls == 1, "extraction did not run before generation was turned off")
        try require(try repository.pendingProposals().isEmpty, "proposals saved after generation was turned off")
        try require(try audits(repository).isEmpty, "audit records written after generation was turned off")
        service.onExtract = { @MainActor in store.updateNativeMemory(settings: settings(enabled: false), service: service) }
        store.updateNativeMemory(settings: settings(), service: service)
        await learn(store, text, try turn(repository, text))
        try require(try repository.pendingProposals().isEmpty, "proposals saved after memory was turned off")
    }

    static func runtimeParity(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("parity.sqlite"))
        let service = DomainExtractionService()
        let store = store(repository, service)
        let text = "Our orchard has six apple trees."
        DomainExtractionWire.state.respond(text, content("Orchard", [entry("Orchard", "baseline", quantity: 6, span: "six apple trees")]))
        store.newConversation()
        try await send(store, service, text)
        let native = try repository.pendingProposals()
        let bridge = NativeRuntimeMemoryBridge(store: store)
        let before = service.finished
        bridge.learn(conversation: UUID().uuidString.lowercased(), message: UUID().uuidString.lowercased(), user: text, reply: "Native reply")
        try await waitFor("runtime turn never reached extraction") { service.finished > before }
        try await waitFor("runtime proposals never landed") { try repository.pendingProposals().count > native.count }
        let inputs = service.inputs
        try require(inputs.count == 2 && inputs[0] == inputs[1], "native and Pi sent different turn text to extraction")
        let bodies = DomainExtractionWire.state.bodies.map { body -> NSDictionary? in
            let normalized = body.replacingOccurrences(of: #"Current date: \S+?Z\."#, with: "Current date.", options: .regularExpression)
            return (try? JSONSerialization.jsonObject(with: Data(normalized.utf8))) as? NSDictionary
        }
        try require(bodies.count == 2 && bodies[0] != nil && bodies[0] == bodies[1], "native and Pi extraction requests differed")
        try require(service.results.count == 2 && service.results[0] == service.results[1], "native and Pi produced different candidates")
        let runtime = try repository.pendingProposals().filter { item in !native.contains { $0.id == item.id } }
        func shape(_ proposal: NativeMemoryProposal) -> [String] {
            [proposal.kind.rawValue, proposal.title, proposal.summary, proposal.group.rawValue, proposal.category.rawValue,
             proposal.bank, proposal.durability.rawValue] + proposal.details
        }
        try require(native.filter { $0.domain == nil }.map(shape) == runtime.filter { $0.domain == nil }.map(shape),
                    "native and Pi free-text proposals differed")
        try require(native.filter { $0.domain != nil }.count == 1, "native turn did not stage its typed proposal")
        try require(runtime.allSatisfy { $0.domain == nil && $0.sourceMessageID == nil },
                    "Pi turn staged a typed record without a local source")
        try require(try audits(repository) == ["domain entry skipped: source is not saved on this Mac"],
                    "Pi typed candidate was not audited")
    }

    static func malformed(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("malformed.sqlite"))
        let store = store(repository, DomainExtractionService())
        let text = "We have twelve hens and a fox visits next week."
        var wrong = entry("Hens", "baseline", quantity: 12, span: "We have twelve hens")
        wrong["subject"] = 12
        var quantity = entry("Hens", "baseline", span: "We have twelve hens")
        quantity["quantity"] = "twelve"
        DomainExtractionWire.state.respond(text, content("Hens and fox", [
            wrong,
            entry("Hens", "herd", quantity: 12, span: "We have twelve hens"),
            entry("Fox", "planned", property: "Fox visit", date: "next week", span: "a fox visits next week"),
            quantity,
            "a loose sentence",
        ] as [Any]))
        let source = try turn(repository, text)
        await learn(store, text, source)
        try require(try domainPending(repository).isEmpty, "malformed entries were staged")
        try require(try repository.pendingProposals().contains { $0.title == "Hens and fox" && $0.sourceMessageID == source.messageID },
                    "free-text proposal lost to malformed typed entries")
        let expected: Set<String> = Set([
            "the subject is not text", "the kind is unknown", "the date is not an absolute date",
            "the quantity is not a number", "the entry is not an object",
        ].map { LocalChatRepository.domainSkipNote + $0 })
        try require(Set(try audits(repository)) == expected, "malformed audits were \(try audits(repository))")
        let notList = "We have three geese."
        DomainExtractionWire.state.respond(notList, content("Geese", "three geese"))
        await learn(store, notList, try turn(repository, notList))
        try require(try audits(repository).contains(LocalChatRepository.domainSkipNote + "the entries are not a list"),
                    "non-list entries were not audited")
        try require(try repository.pendingProposals().contains { $0.title == "Geese" }, "free-text proposal lost to a non-list")
    }

    static func gating(_ directory: URL) async throws {
        DomainExtractionWire.state.reset()
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("gating.sqlite"))
        let service = DomainExtractionService()
        let typed = "We have seven ducks."
        func respond(_ text: String) {
            DomainExtractionWire.state.respond(text, content("Ducks", [entry("Ducks", "baseline", quantity: 7, span: text.replacingOccurrences(of: ".", with: ""))]))
        }
        respond(typed)
        let off = store(repository, service, settings: settings(enabled: false))
        await learn(off, typed, try turn(repository, typed))
        let noGeneration = store(repository, service, settings: settings(generate: false))
        await learn(noGeneration, typed, try turn(repository, typed))
        let live = store(repository, service)
        await learn(live, typed, try turn(repository, typed), excluded: true)
        for text in ["private: We have seven ducks.", "Do not remember this. We have seven ducks.",
                     "We have seven ducks. password: hunter2-fixture"] {
            respond(text)
            await learn(live, text, try turn(repository, text))
        }
        try require(service.calls == 0, "gated turns reached extraction \(service.calls) times")
        try require(try repository.pendingProposals().isEmpty && audits(repository).isEmpty, "gated turns produced proposals or audits")
        let sensitive = "We have seven ducks {coop}."
        respond(sensitive)
        await learn(live, sensitive, try turn(repository, sensitive))
        try require(service.calls == 0, "a sensitive turn under Never remember reached extraction")
        let review = store(repository, service, settings: settings(sensitive: .reviewOnly))
        await learn(review, sensitive, try turn(repository, sensitive))
        try require(service.calls == 1, "a sensitive turn under review only did not reach extraction")
        try require(try domainPending(repository).isEmpty, "a sensitive turn produced a typed proposal")
        try require(try repository.pendingProposals().contains { $0.sensitiveReview == true }, "sensitive free-text proposal not flagged")
        let credential = "We have seven ducks. api_key=sk-fixture1234567890"
        respond(credential)
        await learn(review, credential, try turn(repository, credential))
        try require(service.calls == 1, "a credential turn reached extraction")
        let excludedID = "excluded-chat"
        let excludedSource = try turn(repository, typed, conversation: excludedID)
        var conversation = try repository.listConversations().first { $0.id == excludedID }!
        conversation.memoryExcluded = true
        try repository.saveConversation(conversation)
        let candidate = NativeDomainCandidateParser.parse(content("Ducks", [entry("Ducks", "baseline", quantity: 7, span: "We have seven ducks")])).candidates[0]
        do {
            _ = try repository.stageExtractedDomainEntry(candidate, conversationID: excludedID, messageID: excludedSource.messageID,
                sourceText: typed, fallbackDate: Date())
            try require(false, "an excluded conversation staged a typed record")
        } catch let skip as NativeDomainExtractionSkip {
            try require(skip.reason == "the message is no longer available", "excluded staging skip was \(skip.reason)")
        }
    }
}

final class DomainExtractionWireState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: String] = [:]
    private var recorded: [String] = []
    var bodies: [String] { lock.withLock { recorded } }
    func reset() { lock.withLock { replies = [:]; recorded = [] } }
    func respond(_ user: String, _ content: String) { lock.withLock { replies[user] = content } }
    func reply(_ body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let messages = object?["messages"] as? [[String: Any]] ?? []
        let input = messages.count > 1 ? messages[1]["content"] as? String ?? "" : ""
        var user = input
        if let start = input.range(of: "USER TURN\n"), let end = input.range(of: "\n\nASSISTANT TURN") {
            user = String(input[start.upperBound..<end.lowerBound])
        }
        return lock.withLock {
            recorded.append(text)
            return replies[user] ?? #"{"proposals":[]}"#
        }
    }
}

final class DomainExtractionWire: URLProtocol, @unchecked Sendable {
    static let state = DomainExtractionWireState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        let body: [String: Any] = ["choices": [["message": ["content": Self.state.reply(data)], "finish_reason": "stop"]]]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class DomainExtractionService: NativeMemoryServing, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: NativeMemoryService
    private var count = 0
    private var done = 0
    private var hook: (@MainActor @Sendable () -> Void)?
    private var turns: [[String]] = []
    private var outputs: [[NativeDomainCandidate]] = []

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DomainExtractionWire.self]
        inner = NativeMemoryService(configuration: NativeMemoryServiceConfiguration(
            baseURL: URL(string: "https://fixture.example/v1")!, apiKey: nil, embeddingsModel: "",
            extractionModel: "fixture-extraction"), session: URLSession(configuration: configuration))
    }

    var calls: Int { lock.withLock { count } }
    var finished: Int { lock.withLock { done } }
    var inputs: [[String]] { lock.withLock { turns } }
    var results: [[NativeDomainCandidate]] { lock.withLock { outputs } }
    var onExtract: (@MainActor @Sendable () -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    func embed(_ text: String) async throws -> [Double] { throw NativeMemoryServiceError.notConfigured }

    func proposals(
        user: String, assistant: String, sourceConversationID: String?, sourceMessageID: String?,
        existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] {
        try await extraction(user: user, assistant: assistant, sourceConversationID: sourceConversationID,
            sourceMessageID: sourceMessageID, sensitiveHandling: .neverStore, existing: existing, now: now).proposals
    }

    func proposal(
        request: String, existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] {
        try await inner.proposal(request: request, existing: existing, now: now)
    }

    func extraction(
        user: String, assistant: String, sourceConversationID: String?, sourceMessageID: String?,
        sensitiveHandling: NativeMemorySensitiveHandling,
        existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> NativeMemoryExtraction {
        let hook = lock.withLock { count += 1; turns.append([user, assistant]); return self.hook }
        let result = try await inner.extraction(user: user, assistant: assistant, sourceConversationID: sourceConversationID,
            sourceMessageID: sourceMessageID, sensitiveHandling: sensitiveHandling, existing: existing, now: now)
        if let hook { await hook() }
        lock.withLock { done += 1; outputs.append(result.domainEntries) }
        return result
    }
}
