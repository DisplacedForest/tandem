import Foundation

final class NativeMemoryFixtureService: NativeMemoryServing, @unchecked Sendable {
    private let lock = NSLock()
    private var model: String
    private var reranker: String
    private var embedCount = 0
    private var rerankCount = 0
    var rerankFailure: Error?
    var embedFailure: Error?
    var embedDelayMilliseconds = 0

    init(model: String = "fixture-embed", reranker: String = "") {
        self.model = model
        self.reranker = reranker
    }

    var supportsSemanticRecall: Bool { !embeddingsModelName.isEmpty }
    var embeddingsModelName: String { lock.withLock { model } }
    var rerankModelName: String { lock.withLock { reranker } }
    var embeds: Int { lock.withLock { embedCount } }
    var reranks: Int { lock.withLock { rerankCount } }

    func setModel(_ value: String) { lock.withLock { model = value } }
    func setReranker(_ value: String) { lock.withLock { reranker = value } }

    static let synonyms: [String: String] = [
        "coffee": "brew", "espresso": "brew", "latte": "brew", "cafe": "brew",
        "dog": "pet", "puppy": "pet", "hound": "pet", "canine": "pet",
        "bike": "cycle", "bicycle": "cycle", "cycling": "cycle",
        "garden": "plants", "greenhouse": "plants", "tomatoes": "plants",
    ]

    static func vector(_ text: String) -> [Double] {
        var values = Array(repeating: 0.0, count: 32)
        for raw in text.lowercased().split { !$0.isLetter && !$0.isNumber } {
            let token = synonyms[String(raw)] ?? String(raw)
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in token.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            values[Int(hash % 32)] += 1
        }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? values.map { $0 / norm } : values
    }

    func embed(_ text: String) async throws -> [Double] {
        lock.withLock { embedCount += 1 }
        if let embedFailure { throw embedFailure }
        if embedDelayMilliseconds > 0 { try await Task.sleep(for: .milliseconds(embedDelayMilliseconds)) }
        return Self.vector(text)
    }

    func rerank(query: String, documents: [String]) async throws -> [NativeMemoryRerankScore] {
        lock.withLock { rerankCount += 1 }
        if let rerankFailure { throw rerankFailure }
        let wanted = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return documents.enumerated().map { index, document in
            let words = Set(document.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            let overlap = Double(words.intersection(wanted).count)
            let bonus = document.contains("RERANK-TOP") ? 100.0 : 0
            return NativeMemoryRerankScore(index: index, score: overlap + bonus)
        }.sorted { $0.score > $1.score }
    }

    func probe() async throws -> [String] { [embeddingsModelName, rerankModelName].filter { !$0.isEmpty } }

    func proposals(user: String, assistant: String, sourceConversationID: String?, sourceMessageID: String?,
                   existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date) async throws -> [NativeMemoryProposal] { [] }

    func proposal(request: String, existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date) async throws -> [NativeMemoryProposal] { [] }
}

@MainActor
extension SelfTest {
    static func memoryFixtureRecord(_ id: String, title: String, details: [String], bank: String = "personal", status: NativeMemoryStatus = .approved,
                                    expiry: Date? = nil, durability: NativeMemoryDurability = .durable, now: Date) -> NativeMemoryRecord {
        NativeMemoryRecord(id: id, title: title, summary: details.first ?? title, details: details, group: .profile, category: .preference,
                           bank: bank, durability: durability, expiry: expiry, status: status, embedding: nil,
                           sourceConversationID: nil, sourceMessageID: nil, createdAt: now, updatedAt: now)
    }

    static func runNativeMemoryRetrieval() async throws {
        let require = NativeTaskFixture.require
        let packed = NativeMemoryVectorCodec.pack([0.25, -1.5, 3])
        try require(packed.count == 12 && NativeMemoryVectorCodec.unpack(packed, dimension: 3) == [0.25, -1.5, 3]
                    && NativeMemoryVectorCodec.unpack(packed, dimension: 4) == nil, "Vectors pack to little-endian floats and refuse a wrong dimension")

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let repository = try LocalChatRepository(inMemory: true)
        let records = [
            memoryFixtureRecord("drink", title: "Morning drink", details: ["The user starts the day with an espresso from the cafe downstairs"], now: now),
            memoryFixtureRecord("pet", title: "Family dog", details: ["Their hound Biscuit sleeps on the porch"], now: now),
            memoryFixtureRecord("bike", title: "Commute", details: ["Rides a bicycle to the office when it is dry"], now: now),
            memoryFixtureRecord("plants", title: "Greenhouse", details: ["Grows tomatoes in the greenhouse behind the house"], now: now),
            memoryFixtureRecord("exact", title: "Zymurgy club", details: ["Member of the Tuesday zymurgy club"], now: now),
            memoryFixtureRecord("pending", title: "Suppressed fact", details: ["A suppressed fact about espresso"], status: .suppressed, now: now),
            memoryFixtureRecord("expired", title: "Expired fact", details: ["An expired episodic fact about espresso"],
                                expiry: now.addingTimeInterval(-3600), durability: .episodic, now: now),
            memoryFixtureRecord("work", title: "Work drink", details: ["Drinks espresso at work"], bank: "work", now: now),
        ]
        for record in records { try repository.saveMemory(record, decision: .accepted, note: "fixture") }

        let service = NativeMemoryFixtureService()
        var settings = NativeMemorySettings.fresh
        settings.enabled = true
        settings.embeddingsModel = "fixture-embed"
        settings.bankScope = "personal"
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeMemorySettings: settings, nativeMemoryService: service)
        store.nativeMemoryNow = { now }
        await store.connect()
        try require(try await waitFor(seconds: 10) { store.memoryIndexingProgress == nil && (store.memoryVectorStatus?.complete ?? false) },
                    "The backfill prepares every eligible approved memory: \(String(describing: store.memoryVectorStatus))")
        let status = try repository.memoryVectorStatus(model: "fixture-embed", now: now)
        try require(status.total == 6 && status.ready == 6, "Only approved, unexpired facts count toward vectors: \(status)")
        try require(try repository.memoriesMissingVectors(model: "other-model", now: now).count == 6, "A different model has no vectors yet")

        var noModel = settings
        noModel.embeddingsModel = ""
        let lexicalOnly = await store.retrieveApprovedMemory("coffee", settings: noModel, service: NativeMemoryFixtureService(model: ""))
        try require(lexicalOnly.trace?.mode == .lexical && lexicalOnly.selected.isEmpty, "Without an embeddings model recall is lexical and a paraphrase finds nothing")

        let result = await store.retrieveApprovedMemory("Any zymurgy news? Also where do I get my coffee", settings: settings, service: service)
        guard let trace = result.trace else { throw NativeTaskFixture.Failure.assertion("A trace is produced") }
        try require(trace.mode == .fused, "With vectors ready the fused path runs")
        try require(trace.lexical.contains { $0.id == "exact" } && trace.semantic.contains { $0.id == "drink" },
                    "The exact term comes from the lexical source and the paraphrase from the semantic source: \(trace.summary)")
        let selectedIDs = result.selected.map(\.record.id)
        try require(selectedIDs.contains("exact") && selectedIDs.contains("drink"), "Both facts are injected in the same turn: \(selectedIDs)")
        try require(!selectedIDs.contains("pending") && !selectedIDs.contains("expired") && !selectedIDs.contains("work"),
                    "Suppressed, expired and out-of-scope facts never appear: \(selectedIDs)")
        try require(trace.rerankNote.contains("no rerank model"), "The trace says no rerank ran: \(trace.rerankNote)")
        try require(trace.injected.map(\.id) == selectedIDs && result.selected.allSatisfy { $0.revision != nil }, "Injected entries match the selection and carry citations")
        try require(trace.elapsedMilliseconds >= 0 && trace.elapsedMilliseconds < NativeMemoryRetrievalLimits.latencyBudgetMilliseconds, "Fixture retrieval stays inside the latency budget")

        service.setReranker("fixture-rerank")
        guard let currentBike = try repository.allMemories().first(where: { $0.id == "bike" }) else { throw NativeTaskFixture.Failure.assertion("bike fixture") }
        var boosted = currentBike
        boosted.details = ["Rides a bicycle to the office when it is dry RERANK-TOP"]
        boosted.updatedAt = now.addingTimeInterval(1)
        try repository.saveMemory(boosted, decision: .edited, note: "fixture", expected: currentBike)
        try require(try await waitFor(seconds: 10) {
            store.backfillMemoryVectorsIfNeeded()
            let current = try repository.memoryVectorStatus(model: "fixture-embed", now: now)
            return store.memoryIndexingProgress == nil && current.complete
        }, "An edited memory is re-embedded")
        let reranked = await store.retrieveApprovedMemory("coffee and zymurgy and the office", settings: settings, service: service)
        guard let rerankTrace = reranked.trace else { throw NativeTaskFixture.Failure.assertion("A rerank trace is produced") }
        try require(!rerankTrace.reranked.isEmpty && rerankTrace.rerankNote.hasPrefix("Reranked"), "The trace shows rerank scores: \(rerankTrace.rerankNote)")
        try require(reranked.selected.first?.record.id == "bike" && rerankTrace.reranked.first?.id == "bike", "The injected order follows the rerank scores: \(reranked.selected.map(\.record.id))")
        service.rerankFailure = NativeMemoryServiceError.timeout
        let fallback = await store.retrieveApprovedMemory("coffee and zymurgy", settings: settings, service: service)
        try require(fallback.trace?.rerankNote.hasPrefix("No rerank ran") == true && !fallback.selected.isEmpty, "A failed rerank keeps the fused order and says so")
        service.rerankFailure = nil

        let fused = NativeMemoryRetrieval.fuse(
            lexical: [NativeMemoryCandidate(record: records[0], lexicalRank: 1, lexicalScore: 2), NativeMemoryCandidate(record: records[1], lexicalRank: 2, lexicalScore: 1)],
            semantic: [NativeMemoryCandidate(record: records[1], semanticRank: 1, cosine: 0.9), NativeMemoryCandidate(record: records[3], semanticRank: 2, cosine: 0.5)])
        try require(fused.map(\.record.id) == ["pet", "drink", "plants"], "Reciprocal rank fusion favors a fact found by both sources: \(fused.map(\.record.id))")
        try require(abs(fused[0].fused - (1 / 62 + 1 / 61)) < 1e-9, "Fused scores use the declared constant")
        let heavy = (1...20).map { index in
            NativeMemoryCandidate(record: memoryFixtureRecord("h\(index)", title: "Fact \(index)", details: [String(repeating: "word ", count: 80)], now: now), fused: 1 / Double(index))
        }
        let budgeted = NativeMemoryRetrieval.budget(heavy)
        try require(budgeted.count <= NativeMemoryRetrievalLimits.itemLimit
                    && budgeted.reduce(0) { $0 + NativeMemoryRetrieval.estimatedTokens($1.record) } <= NativeMemoryRetrievalLimits.tokenBudget,
                    "The injected set never exceeds the item or token budget: \(budgeted.count)")
        var typed = memoryFixtureRecord("typed", title: "Greenhouse", details: ["Typed projection of the greenhouse"], now: now)
        typed.domainEntityID = UUID()
        let precedence = NativeMemoryRetrieval.preferTyped([NativeMemoryCandidate(record: records[3], fused: 0.9), NativeMemoryCandidate(record: typed, fused: 0.5)])
        try require(precedence.map(\.record.id) == ["typed"], "A typed projection wins over a free-text fact on the same subject")
        let history = [NativeTurnHistoryMessage(Message(role: .user, text: String(repeating: "a", count: 900))),
                       NativeTurnHistoryMessage(Message(role: .assistant, text: "earlier"))]
        let query = NativeMemoryRetrieval.queryText(current: "now", history: history)
        try require(query.hasSuffix("\nearlier\nnow") && query.count <= NativeMemoryRetrievalLimits.contextWindowCharacters + 20, "The query takes a bounded window plus the current message")
        let cited = [NativeTurnHistoryMessage(Message(role: .assistant, text: "You drink espresso [10001] and ride a bike [10002]."))]
        let citedResult = await store.retrieveApprovedMemory("where is the zymurgy club", history: cited, settings: settings, service: service)
        try require(citedResult.trace?.mode == .fused && !citedResult.trace!.lexical.isEmpty && !citedResult.trace!.query.contains("[10001]"),
                    "Citation markers in earlier answers do not poison the query: \(citedResult.trace?.summary ?? "")")
        let userBrackets = NativeMemoryRetrieval.query(current: "item [42]", history: [NativeTurnHistoryMessage(Message(role: .user, text: "see item [43]")),
                                                                                       NativeTurnHistoryMessage(Message(role: .assistant, text: "Noted [10001]"))])
        try require(userBrackets.current == "item [42]" && userBrackets.context == ["see item [43]", "Noted "], "Only assistant citations are stripped; user-authored numbers stay")
        try repository.saveMemory(memoryFixtureRecord("late", title: "Late fact", details: ["A fact added after the backfill finished"], now: now), decision: .accepted, note: "fixture")
        let lateTurn = await store.retrieveApprovedMemory("late fact", settings: settings, service: service)
        try require(lateTurn.trace?.notes.contains(where: { $0.contains("waiting for vectors") }) == true, "A newly eligible record makes readiness incomplete for that turn")
        try require(try await waitFor(seconds: 10) { store.memoryIndexingProgress == nil && (store.memoryVectorStatus?.complete ?? false) },
                    "That turn schedules the backfill so later turns are semantic again: \(String(describing: store.memoryVectorStatus))")
        let noisy = [NativeTurnHistoryMessage(Message(role: .user, text: Array(repeating: "earlier", count: 60).joined(separator: " ")))]
        let noisyResult = await store.retrieveApprovedMemory("zymurgy", history: noisy, settings: settings, service: service)
        try require(noisyResult.selected.contains { $0.record.id == "exact" }, "The current request's terms come before history in lexical search")
        let heavyText = String(repeating: "\u{8fd9}", count: 600)
        let heavyRecord = memoryFixtureRecord("heavy", title: "Heavy", details: [heavyText, heavyText, heavyText, heavyText], now: now)
        try require(NativeMemoryRetrieval.estimatedTokens(heavyRecord) > NativeMemoryRetrievalLimits.tokenBudget, "Multibyte text is estimated by bytes, not characters")
        try require(NativeMemoryRetrieval.budget([NativeMemoryCandidate(record: heavyRecord, fused: 1)]).isEmpty, "A fact larger than the budget is not injected")
        var farTyped = memoryFixtureRecord("flock-typed", title: "Flock", details: ["Current count: 10"], now: now)
        farTyped.domainEntityID = UUID()
        let flockFree = memoryFixtureRecord("flock-free", title: "Flock", details: ["I have 12 chickens"], now: now)
        let resolved = NativeMemoryRetrieval.preferTyped([NativeMemoryCandidate(record: flockFree, fused: 0.4)], typed: [farTyped])
        try require(resolved.map(\.record.id) == ["flock-typed"], "A typed counterpart outside the candidates still replaces the free-text fact")
        let slowService = NativeMemoryFixtureService(model: "fixture-embed")
        slowService.embedDelayMilliseconds = NativeMemoryRetrievalLimits.latencyBudgetMilliseconds + 400
        let deadlineStart = ContinuousClock.now
        let slowResult = await store.retrieveApprovedMemory("zymurgy news", settings: settings, service: slowService)
        let deadlineElapsed = deadlineStart.duration(to: .now)
        try require(slowResult.trace?.mode == .lexical && slowResult.trace?.notes.contains(where: { $0.contains("deadline") }) == true
                    && slowResult.selected.contains { $0.record.id == "exact" } && deadlineElapsed < .milliseconds(NativeMemoryRetrievalLimits.latencyBudgetMilliseconds + 700),
                    "A slow embeddings call is cut at the deadline and the turn keeps local results: \(slowResult.trace?.summary ?? "")")
        var consented = memoryFixtureRecord("consented", title: "Consented", details: ["A consented sensitive fact about espresso"], now: now)
        consented.sensitiveConsent = true
        try repository.saveMemory(consented, decision: .accepted, note: "fixture")
        let neverStore = try repository.memoryVectorStatus(model: "fixture-embed", now: now, sensitive: .neverStore)
        let reviewOnly = try repository.memoryVectorStatus(model: "fixture-embed", now: now, sensitive: .reviewOnly)
        try require(neverStore.total == 7 && reviewOnly.total == 8, "Readiness counts follow the sensitive setting like the backfill does: \(neverStore) \(reviewOnly)")

        service.setModel("fixture-embed-v2")
        settings.embeddingsModel = "fixture-embed-v2"
        store.updateNativeMemory(settings: settings, service: service)
        try require(try repository.memoryVectorStatus(model: "fixture-embed", now: now).ready == 0, "Changing the model drops the old vectors")
        try require(try await waitFor(seconds: 10) { store.memoryIndexingProgress == nil && (store.memoryVectorStatus?.complete ?? false) && store.memoryVectorStatus?.model == "fixture-embed-v2" },
                    "The new model backfills in the background: \(String(describing: store.memoryVectorStatus))")
        let slow = NativeMemoryFixtureService(model: "fixture-embed-v3")
        settings.embeddingsModel = "fixture-embed-v3"
        let waiting = await store.retrieveApprovedMemory("where do I get my coffee", settings: settings, service: slow)
        try require(waiting.trace?.mode == .lexical && waiting.trace?.notes.contains(where: { $0.contains("waiting for vectors") }) == true && slow.embeds == 0,
                    "Until the backfill for a new model finishes, recall stays lexical and the endpoint is not queried: \(waiting.trace?.summary ?? "")")
        try require(try repository.memoryVectorStatus(model: "fixture-embed-v3", now: now).label.contains("Preparing 0 of 7"), "Settings can show the backfill status")
        print("  native memory retrieval OK (packing, backfill, lexical and semantic sources, fusion, budgets, scope, rerank, rerank fallback, typed precedence, query window, citations stripped, current terms first, byte budget, deadline, sensitive readiness, model change, lexical until ready)")
    }

    static func waitFor(seconds: Double, _ condition: @MainActor () throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try condition()
    }

    static func runNativeMemoryLive(base: String) async throws {
        guard let url = NativeMemoryEndpointSettings.validBaseURL(base) else { throw NativeTaskFixture.Failure.assertion("VERA_MEMORY_LIVE_BASE must end in /v1") }
        let environment = ProcessInfo.processInfo.environment
        let embedModel = environment["VERA_MEMORY_LIVE_EMBED"] ?? "qwen3-embedding"
        let rerankModel = environment["VERA_MEMORY_LIVE_RERANK"] ?? ""
        let service = NativeMemoryService(configuration: NativeMemoryServiceConfiguration(
            baseURL: url, apiKey: environment["VERA_MEMORY_LIVE_KEY"], embeddingsModel: embedModel, extractionModel: "", rerankModel: rerankModel))
        let now = Date()
        let repository = try LocalChatRepository(inMemory: true)
        let subjects = ["coffee", "the family dog", "cycling to work", "the greenhouse tomatoes", "weekend hiking", "the lake house", "piano practice",
                        "the bread starter", "the car's winter tires", "the chess club", "birthday plans", "the reading list"]
        for (index, subject) in subjects.enumerated() {
            for variant in 0..<5 {
                let id = "live-\(index)-\(variant)"
                try repository.saveMemory(memoryFixtureRecord(id, title: "\(subject) \(variant)", details: ["Detail \(variant) about \(subject): the user mentioned this on a weekday."], now: now),
                                          decision: .accepted, note: "live")
            }
        }
        var settings = NativeMemorySettings.fresh
        settings.enabled = true
        settings.embeddingsModel = embedModel
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeMemorySettings: settings, nativeMemoryService: service)
        await store.connect()
        let started = ContinuousClock.now
        guard try await waitFor(seconds: 600, { store.memoryIndexingProgress == nil && (store.memoryVectorStatus?.complete ?? false) }) else {
            throw NativeTaskFixture.Failure.assertion("Backfill did not finish: \(String(describing: store.memoryVectorStatus)) \(store.memoryServiceState)")
        }
        let backfill = started.duration(to: .now)
        print("LIVE backfill of 60 facts with \(embedModel): \(backfill)")
        var timings: [Int] = []
        for query in ["where do I usually drink my morning espresso", "how does the dog like the porch", "what tires are on the car", "tell me about the bread"] {
            let result = await store.retrieveApprovedMemory(query, settings: settings, service: service)
            guard let trace = result.trace else { throw NativeTaskFixture.Failure.assertion("trace missing") }
            timings.append(trace.elapsedMilliseconds)
            print("LIVE query '\(query)': mode \(trace.mode.rawValue), \(trace.lexical.count) lexical, \(trace.semantic.count) semantic, injected \(trace.injected.map(\.title)), rerank: \(trace.rerankNote), \(trace.elapsedMilliseconds) ms")
        }
        print("LIVE fused retrieval timings ms: \(timings), budget \(NativeMemoryRetrievalLimits.latencyBudgetMilliseconds)")
    }
}
