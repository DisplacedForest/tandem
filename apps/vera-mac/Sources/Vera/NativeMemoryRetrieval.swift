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
    static let lexicalTerms = 48
    static let bytesPerToken = 3
    static let framingTokens = 60
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

struct NativeMemoryQuery: Equatable, Sendable {
    let current: String
    let context: [String]

    var semanticText: String {
        String((context + [current]).joined(separator: "\n").suffix(NativeMemoryRetrievalLimits.queryCharacters))
    }

    var lexicalTerms: [String] {
        var seen: Set<String> = []
        var terms: [String] = []
        for text in [current] + context.reversed() {
            for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let term = String(raw)
                guard terms.count < NativeMemoryRetrievalLimits.lexicalTerms, seen.insert(term).inserted else { continue }
                terms.append(term)
            }
        }
        return terms
    }
}

enum NativeMemoryRetrieval {
    static func stripCitations(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[\d{1,6}\]"#, with: "", options: .regularExpression)
    }

    static func query(current: String, history: [NativeTurnHistoryMessage]) -> NativeMemoryQuery {
        let window = history.filter { !$0.text.isEmpty }.suffix(NativeMemoryRetrievalLimits.contextWindowMessages)
        let context = window.map { message in
            let text = message.role == "assistant" ? stripCitations(message.text) : message.text
            return String(text.prefix(NativeMemoryRetrievalLimits.contextWindowCharacters))
        }
        return NativeMemoryQuery(current: current, context: context)
    }

    static func queryText(current: String, history: [NativeTurnHistoryMessage]) -> String {
        query(current: current, history: history).semanticText
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

    static func preferTyped(_ candidates: [NativeMemoryCandidate], typed: [NativeMemoryRecord] = []) -> [NativeMemoryCandidate] {
        var typedBySubject: [String: NativeMemoryRecord] = [:]
        for record in typed where record.domainEntityID != nil && !subjectKey(record).isEmpty {
            typedBySubject[subjectKey(record)] = record
        }
        for candidate in candidates where candidate.record.domainEntityID != nil && !subjectKey(candidate.record).isEmpty {
            typedBySubject[subjectKey(candidate.record)] = candidate.record
        }
        var result: [NativeMemoryCandidate] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let key = subjectKey(candidate.record)
            if candidate.record.domainEntityID == nil, !key.isEmpty, let authority = typedBySubject[key] {
                guard seen.insert(authority.id).inserted else { continue }
                var replacement = candidate
                replacement.record = authority
                replacement.revision = nil
                result.append(replacement)
            } else {
                guard seen.insert(candidate.record.id).inserted else { continue }
                result.append(candidate)
            }
        }
        return result
    }

    static func renderedLine(_ record: NativeMemoryRecord) -> String {
        let detail = record.details.joined(separator: "; ")
        return "- \(record.title): \(detail.isEmpty ? record.summary : detail) [00000]"
    }

    static func estimatedTokens(_ record: NativeMemoryRecord) -> Int {
        max(1, (renderedLine(record).utf8.count + NativeMemoryRetrievalLimits.bytesPerToken - 1) / NativeMemoryRetrievalLimits.bytesPerToken)
    }

    static func budget(_ ordered: [NativeMemoryCandidate], itemLimit: Int = NativeMemoryRetrievalLimits.itemLimit,
                       tokenBudget: Int = NativeMemoryRetrievalLimits.tokenBudget) -> [NativeMemoryCandidate] {
        var selected: [NativeMemoryCandidate] = []
        var tokens = NativeMemoryRetrievalLimits.framingTokens
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
