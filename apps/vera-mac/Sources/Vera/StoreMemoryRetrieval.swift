import Foundation

struct NativeMemoryRetrievalResult: Sendable {
    var selected: [NativeMemoryRanked]
    var trace: NativeMemoryRetrievalTrace?
}

extension ChatStore {
    func memoryVectorModel(_ service: (any NativeMemoryServing)?, settings: NativeMemorySettings) -> String {
        let configured = settings.embeddingsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let service else { return "" }
        let name = service.embeddingsModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return configured.isEmpty ? (service.supportsSemanticRecall ? "default" : "") : configured
    }

    func refreshMemoryVectorStatus() {
        guard nativeMemorySettings.enabled, let local = repository as? LocalChatRepository else {
            memoryVectorStatus = nil
            return
        }
        let model = memoryVectorModel(nativeMemoryService, settings: nativeMemorySettings)
        memoryVectorStatus = try? local.memoryVectorStatus(model: model, now: nativeMemoryNow())
    }

    func retrieveApprovedMemory(_ text: String, history: [NativeTurnHistoryMessage] = [],
                                settings: NativeMemorySettings? = nil,
                                service: (any NativeMemoryServing)? = nil) async -> NativeMemoryRetrievalResult {
        let settings = settings ?? nativeMemorySettings
        guard settings.enabled, nativeMemorySettings.enabled, let local = repository as? LocalChatRepository else {
            return NativeMemoryRetrievalResult(selected: [], trace: nil)
        }
        let started = ContinuousClock.now
        let semanticService = service ?? nativeMemoryService
        let query = NativeMemoryRetrieval.queryText(current: text, history: history)
        let model = memoryVectorModel(semanticService, settings: settings)
        let sensitive = nativeMemorySettings.sensitiveHandling
        let scope = settings.bankScope
        let now = nativeMemoryNow()
        var trace = NativeMemoryRetrievalTrace(query: query, mode: .lexical, rerankNote: "No rerank ran.", vectorStatus: "")
        if memoryIndexingProgress != nil {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(NativeMemoryRetrievalLimits.backfillWaitMilliseconds))
            while memoryIndexingProgress != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if memoryIndexingProgress != nil { trace.notes.append("Vectors were still being prepared when this turn started.") }
        }
        do {
            try local.refreshDomainProjections(now: now)
            let lexical = try local.lexicalMemoryCandidates(query, bankScope: scope, now: now, sensitive: sensitive)
            trace.lexical = NativeMemoryRetrieval.entries(lexical, source: "lexical") { $0.lexicalScore ?? 0 }
            var semantic: [NativeMemoryCandidate] = []
            let status = try local.memoryVectorStatus(model: model, now: now)
            memoryVectorStatus = status
            trace.vectorStatus = status.label
            var semanticAvailable = false
            if let semanticService, semanticService.supportsSemanticRecall || !settings.embeddingsModel.trimmingCharacters(in: .whitespaces).isEmpty {
                if !status.complete {
                    trace.notes.append("Semantic recall is waiting for vectors, so this turn used local search only.")
                } else if NativeMemorySafety.containsSensitiveData(query) {
                    trace.notes.append("The request looked sensitive, so it was not sent to the memory endpoint.")
                } else {
                    do {
                        let embedded = try await semanticService.embed(query)
                        semantic = try local.semanticMemoryCandidates(query: embedded, model: model, bankScope: scope, now: now, sensitive: sensitive)
                        semanticAvailable = true
                    } catch let error as NativeMemoryServiceError where error.isEndpointOutage {
                        memoryEndpointStatus = .unreachable(error.localizedDescription)
                        trace.notes.append("The memory endpoint could not be reached, so recall used local search.")
                    } catch {
                        trace.notes.append("The embeddings request failed: \(error.localizedDescription)")
                    }
                }
            }
            trace.semantic = NativeMemoryRetrieval.entries(semantic, source: "semantic") { $0.cosine ?? 0 }
            var ordered: [NativeMemoryCandidate]
            if semanticAvailable {
                trace.mode = .fused
                ordered = NativeMemoryRetrieval.fuse(lexical: lexical, semantic: semantic)
            } else {
                ordered = lexical
                for index in ordered.indices { ordered[index].fused = 1 / (NativeMemoryRetrievalLimits.fusionConstant + Double(index + 1)) }
            }
            ordered = NativeMemoryRetrieval.preferTyped(ordered)
            trace.fused = NativeMemoryRetrieval.entries(ordered, source: trace.mode == .fused ? "fused" : "lexical") { $0.fused }
            let rerankModel = semanticService?.rerankModelName.trimmingCharacters(in: .whitespaces) ?? ""
            if !rerankModel.isEmpty, let semanticService, !ordered.isEmpty {
                if NativeMemorySafety.containsSensitiveData(query) {
                    trace.rerankNote = "No rerank ran: the request looked sensitive."
                } else {
                    let head = Array(ordered.prefix(NativeMemoryRetrievalLimits.rerankCount))
                    do {
                        let scores = try await semanticService.rerank(query: query, documents: head.map(\.documentText))
                        if scores.isEmpty {
                            trace.rerankNote = "No rerank ran: the endpoint returned no scores."
                        } else {
                            let reranked = NativeMemoryRetrieval.applyRerank(head, scores: scores)
                            ordered = reranked + Array(ordered.dropFirst(head.count))
                            trace.reranked = NativeMemoryRetrieval.entries(reranked, source: "rerank") { $0.rerank ?? 0 }
                            trace.rerankNote = "Reranked \(reranked.filter { $0.rerank != nil }.count) of \(head.count) candidates with \(rerankModel)."
                        }
                    } catch {
                        trace.rerankNote = "No rerank ran: \(error.localizedDescription)"
                    }
                }
            } else if rerankModel.isEmpty {
                trace.rerankNote = "No rerank ran: no rerank model is set."
            }
            let budgeted = NativeMemoryRetrieval.budget(ordered)
            let ranked = budgeted.map { NativeMemoryRanked(record: $0.record, score: $0.rerank ?? $0.fused, revision: $0.revision) }
            let selected = try local.eligibleMemory(ranked, bankScope: nativeMemorySettings.bankScope, now: now, sensitive: sensitive)
            trace.injected = selected.enumerated().map { index, item in
                NativeMemoryTraceEntry(id: item.record.id, title: item.record.title, source: "injected", rank: index + 1, score: item.score)
            }
            trace.elapsedMilliseconds = Int(started.duration(to: .now).components.seconds * 1000
                + started.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
            if trace.notes.contains(where: { $0.contains("could not be reached") }) {
                memoryServiceState = .retrievalUnavailable("The memory endpoint could not be reached, so recall used local search.")
            } else {
                memoryServiceState = memoryProposals.isEmpty ? .ready : .pendingReview(memoryProposals.count)
            }
            return NativeMemoryRetrievalResult(selected: selected, trace: trace)
        } catch {
            memoryServiceState = .retrievalUnavailable("Saved memory could not be searched on this Mac.")
            trace.notes.append("Local search failed: \(error.localizedDescription)")
            return NativeMemoryRetrievalResult(selected: [], trace: trace)
        }
    }

    func backfillMemoryVectorsIfNeeded() {
        guard nativeMemorySettings.enabled, let service = nativeMemoryService,
              let local = repository as? LocalChatRepository, memoryIndexingProgress == nil else { return }
        let model = memoryVectorModel(service, settings: nativeMemorySettings)
        guard !model.isEmpty else {
            refreshMemoryVectorStatus()
            return
        }
        if let dropped = try? local.invalidateMemoryVectors(exceptModel: model), dropped > 0 { reloadNativeMemory() }
        refreshMemoryVectorStatus()
        guard let missing = try? local.memoriesMissingVectors(model: model, now: nativeMemoryNow()), !missing.isEmpty else { return }
        memoryServiceState = .indexing
        memoryIndexingProgress = NativeMemoryIndexingProgress(completed: 0, total: missing.count)
        Task {
            defer {
                memoryIndexingProgress = nil
                refreshMemoryVectorStatus()
            }
            for (offset, memory) in missing.enumerated() {
                guard nativeMemorySettings.enabled, memoryVectorModel(nativeMemoryService, settings: nativeMemorySettings) == model else { return }
                do {
                    guard NativeMemorySafety.recordIsSafe(memory),
                          !(try local.eligibleMemory([NativeMemoryRanked(record: memory, score: 1)], bankScope: "all", sensitive: nativeMemorySettings.sensitiveHandling)).isEmpty else { continue }
                    let embedding = try await service.embed(memory.details.joined(separator: "\n"))
                    guard nativeMemorySettings.enabled else { return }
                    try local.saveMemoryVector(embedding, model: model, expected: memory)
                    memoryIndexingProgress = NativeMemoryIndexingProgress(completed: offset + 1, total: missing.count)
                } catch NativeMemoryEvidenceError.changed {
                    continue
                } catch {
                    memoryServiceState = .retrievalUnavailable(error.localizedDescription)
                    return
                }
            }
            reloadNativeMemory()
        }
    }
}
