import Foundation

enum NativeMemoryRetrievalLimits {
    static let lexicalCandidates = 24
    static let semanticCandidates = 24
    static let fusionConstant = 60.0
    static let rerankCount = 16
    static let itemLimit = 8
    static let tokenBudget = 700
    static let contextWindowMessages = 4
    static let contextWindowCharacters = 400
    static let queryCharacters = 2_000
    static let minimumCosine = 0.2
    static let latencyBudgetMilliseconds = 1_500
    static let backfillWaitMilliseconds = 1_000
}

enum NativeMemoryVectorCodec {
    static func pack(_ vector: [Double]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var bits = Float(value).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpack(_ data: Data, dimension: Int) -> [Double]? {
        guard dimension > 0, data.count == dimension * 4 else { return nil }
        var vector: [Double] = []
        vector.reserveCapacity(dimension)
        data.withUnsafeBytes { raw in
            for index in 0..<dimension {
                let bits = raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                vector.append(Double(Float(bitPattern: UInt32(littleEndian: bits))))
            }
        }
        return vector
    }
}

struct NativeMemoryVectorStatus: Equatable, Sendable {
    let model: String
    let ready: Int
    let total: Int

    var complete: Bool { ready >= total }

    var label: String {
        guard !model.isEmpty else { return "Set an embeddings model to add semantic recall. Recall uses local search." }
        if total == 0 { return "No approved memories to prepare for \(model)." }
        if complete { return "Semantic recall ready: \(total) \(total == 1 ? "memory" : "memories") prepared for \(model)." }
        return "Preparing \(ready) of \(total) memories for \(model). Recall uses local search until this finishes."
    }
}

struct NativeMemoryTraceEntry: Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let source: String
    let rank: Int
    let score: Double
}

struct NativeMemoryRetrievalTrace: Equatable, Sendable {
    enum Mode: String, Sendable { case lexical, fused }

    var query: String
    var mode: Mode
    var lexical: [NativeMemoryTraceEntry] = []
    var semantic: [NativeMemoryTraceEntry] = []
    var fused: [NativeMemoryTraceEntry] = []
    var reranked: [NativeMemoryTraceEntry] = []
    var rerankNote: String
    var injected: [NativeMemoryTraceEntry] = []
    var vectorStatus: String
    var elapsedMilliseconds: Int = 0
    var notes: [String] = []

    func entry(for id: String) -> [NativeMemoryTraceEntry] {
        (lexical + semantic + fused + reranked + injected).filter { $0.id == id }
    }

    var summary: String {
        var lines: [String] = []
        lines.append("Mode: \(mode == .fused ? "lexical plus semantic, fused" : "lexical only")")
        lines.append("Query: \(query)")
        lines.append("Vectors: \(vectorStatus)")
        func block(_ title: String, _ entries: [NativeMemoryTraceEntry]) {
            lines.append(title + (entries.isEmpty ? ": none" : ""))
            for entry in entries { lines.append("  \(entry.rank). \(entry.title) [\(entry.source) \(String(format: "%.3f", entry.score))]") }
        }
        block("Lexical candidates", lexical)
        block("Semantic candidates", semantic)
        block("Fused order", fused)
        lines.append("Rerank: \(rerankNote)")
        if !reranked.isEmpty { block("Reranked order", reranked) }
        block("Injected", injected)
        for note in notes { lines.append("Note: " + note) }
        lines.append("Elapsed: \(elapsedMilliseconds) ms (budget \(NativeMemoryRetrievalLimits.latencyBudgetMilliseconds) ms)")
        return lines.joined(separator: "\n")
    }
}

struct NativeMemoryCandidate: Sendable {
    var record: NativeMemoryRecord
    var revision: Int?
    var lexicalRank: Int?
    var lexicalScore: Double?
    var semanticRank: Int?
    var cosine: Double?
    var fused: Double = 0
    var rerank: Double?

    var documentText: String {
        let detail = record.details.joined(separator: "; ")
        return record.title + ": " + (detail.isEmpty ? record.summary : detail)
    }
}

enum NativeMemoryRetrieval {
    static func queryText(current: String, history: [NativeTurnHistoryMessage]) -> String {
        let window = history.filter { !$0.text.isEmpty }.suffix(NativeMemoryRetrievalLimits.contextWindowMessages)
        let context = window.map { String($0.text.prefix(NativeMemoryRetrievalLimits.contextWindowCharacters)) }
        let combined = (context + [current]).joined(separator: "\n")
        return String(combined.suffix(NativeMemoryRetrievalLimits.queryCharacters))
    }

    static func fuse(lexical: [NativeMemoryCandidate], semantic: [NativeMemoryCandidate],
                     constant: Double = NativeMemoryRetrievalLimits.fusionConstant) -> [NativeMemoryCandidate] {
        var merged: [String: NativeMemoryCandidate] = [:]
        var order: [String] = []
        for candidate in lexical {
            var entry = merged[candidate.record.id] ?? candidate
            entry.lexicalRank = candidate.lexicalRank
            entry.lexicalScore = candidate.lexicalScore
            if merged[candidate.record.id] == nil { order.append(candidate.record.id) }
            merged[candidate.record.id] = entry
        }
        for candidate in semantic {
            var entry = merged[candidate.record.id] ?? candidate
            entry.semanticRank = candidate.semanticRank
            entry.cosine = candidate.cosine
            if merged[candidate.record.id] == nil { order.append(candidate.record.id) }
            merged[candidate.record.id] = entry
        }
        var fused = order.compactMap { merged[$0] }
        for index in fused.indices {
            var score = 0.0
            if let rank = fused[index].lexicalRank { score += 1 / (constant + Double(rank)) }
            if let rank = fused[index].semanticRank { score += 1 / (constant + Double(rank)) }
            fused[index].fused = score
        }
        return fused.sorted { left, right in
            if left.fused != right.fused { return left.fused > right.fused }
            if left.record.updatedAt != right.record.updatedAt { return left.record.updatedAt > right.record.updatedAt }
            return left.record.id < right.record.id
        }
    }

    static func subjectKey(_ record: NativeMemoryRecord) -> String {
        record.title.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    static func preferTyped(_ candidates: [NativeMemoryCandidate]) -> [NativeMemoryCandidate] {
        let typedSubjects = Set(candidates.filter { $0.record.domainEntityID != nil }.map { subjectKey($0.record) })
        return candidates.filter { $0.record.domainEntityID != nil || !typedSubjects.contains(subjectKey($0.record)) }
    }

    static func estimatedTokens(_ record: NativeMemoryRecord) -> Int {
        max(1, (record.title.count + record.summary.count + record.details.joined().count + 3) / 4)
    }

    static func budget(_ ordered: [NativeMemoryCandidate], itemLimit: Int = NativeMemoryRetrievalLimits.itemLimit,
                       tokenBudget: Int = NativeMemoryRetrievalLimits.tokenBudget) -> [NativeMemoryCandidate] {
        var selected: [NativeMemoryCandidate] = []
        var tokens = 0
        for candidate in ordered {
            let cost = estimatedTokens(candidate.record)
            guard selected.count < itemLimit, tokens + cost <= tokenBudget else { continue }
            selected.append(candidate)
            tokens += cost
        }
        return selected
    }

    static func applyRerank(_ ordered: [NativeMemoryCandidate], scores: [NativeMemoryRerankScore]) -> [NativeMemoryCandidate] {
        var reranked = ordered
        for score in scores where reranked.indices.contains(score.index) { reranked[score.index].rerank = score.score }
        let scored = reranked.filter { $0.rerank != nil }.sorted { left, right in
            if left.rerank != right.rerank { return (left.rerank ?? 0) > (right.rerank ?? 0) }
            return left.fused > right.fused
        }
        let unscored = reranked.filter { $0.rerank == nil }
        return scored + unscored
    }

    static func entries(_ candidates: [NativeMemoryCandidate], source: String, score: (NativeMemoryCandidate) -> Double) -> [NativeMemoryTraceEntry] {
        candidates.enumerated().map { index, candidate in
            NativeMemoryTraceEntry(id: candidate.record.id, title: candidate.record.title, source: source, rank: index + 1, score: score(candidate))
        }
    }
}
