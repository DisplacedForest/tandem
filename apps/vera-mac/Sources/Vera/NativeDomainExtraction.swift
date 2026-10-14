import Foundation
import GRDB

struct NativeDomainCandidate: Codable, Hashable, Sendable {
    let subject: String
    let scope: String
    let payload: NativeDomainPayload
    let occurredAt: Date?
    let evidence: NativeDomainEvidence
    let supersedes: String?
    let span: String
}

struct NativeMemoryExtraction: Sendable {
    var proposals: [NativeMemoryProposal]
    var domainEntries: [NativeDomainCandidate] = []
    var skippedDomainEntries: [String] = []
}

struct NativeMemoryTurnSource: Sendable {
    let conversationID: String
    let messageID: String
    let date: Date
}

struct NativeDomainExtractionSkip: Error, Equatable {
    let reason: String
}

enum NativeDomainCandidateParser {
    static let limit = 8

    static let instructions = """
    Also list typed records in "domain_entries" (at most 8) when the user states a count, a change to a count, care for something they keep, or a fact about it. Each item: {"subject":"short name of the thing, like Hens","scope":"personal|work|family|projects","kind":"fact|baseline|addition|removal|purchase|mention|completed|planned|recommended|possible|not_occurred|retraction","quantity":number or null,"unit":"count|dozen|gram|kilogram|milliliter|liter or null","property":"fact name or care activity, or null","value":"fact value or null","occurred_at":"YYYY-MM-DD or null","evidence":"asserted|negated|hypothetical|reported|ambiguous","supersedes":"subject whose latest record this corrects, or null","span":"exact text from the user turn"}. Take records only from the user's own words, never from the assistant turn. baseline is a counted total; addition and removal change it; purchase and mention do not show ownership. completed is care that happened; planned, recommended and possible are not completed; not_occurred means it did not happen. For care, put the activity in property. Use negated, hypothetical, reported or ambiguous when the user denies it, imagines it, repeats someone else, or is unclear. occurred_at is an absolute date or null, never a relative word. A correction sets supersedes to the subject it corrects. Copy span verbatim from the user turn, character for character.
    """

    private static let relativeWords = ["today", "tonight", "tomorrow", "yesterday", "this weekend", "next week", "next month", "last week", "last month", "soon"]

    static func parse(_ raw: String) -> (candidates: [NativeDomainCandidate], skipped: [String]) {
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count <= 30_000, let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], ["the typed records could not be read"])
        }
        guard let value = object["domain_entries"], !(value is NSNull) else { return ([], []) }
        guard let rows = value as? [Any] else { return ([], ["the entries are not a list"]) }
        var candidates: [NativeDomainCandidate] = []
        var skipped: [String] = []
        for (index, row) in rows.enumerated() {
            guard index < limit else {
                skipped.append("more than \(limit) entries in one turn")
                continue
            }
            do { candidates.append(try candidate(row)) }
            catch let skip as NativeDomainExtractionSkip { skipped.append(skip.reason) }
            catch { skipped.append("the entry is not valid") }
        }
        return (candidates, skipped)
    }

    static func candidate(_ value: Any) throws -> NativeDomainCandidate {
        guard let row = value as? [String: Any] else { throw skip("the entry is not an object") }
        guard let subject = try text(row["subject"], field: "subject", maximum: 80) else { throw skip("the subject is missing") }
        let scope = try text(row["scope"], field: "scope", maximum: 40)?.lowercased() ?? "personal"
        guard let kind = row["kind"] as? String else { throw skip("the kind is missing or not text") }
        guard let evidenceRaw = row["evidence"] as? String, let evidence = NativeDomainEvidence(rawValue: evidenceRaw) else {
            throw skip("the evidence mode is missing or unknown")
        }
        let quantity = try quantity(row["quantity"], unit: row["unit"])
        let property = try text(row["property"], field: "property", maximum: 128)
        let fieldValue = try text(row["value"], field: "value", maximum: 512)
        let supersedes = try text(row["supersedes"], field: "correction", maximum: 80)
        let occurredAt = try date(row["occurred_at"])
        guard let span = row["span"] as? String else { throw skip("the quoted text is missing or not text") }
        guard !span.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, span.utf8.count <= 8_192 else {
            throw skip("the quoted text is empty or too long")
        }
        let payload: NativeDomainPayload
        switch kind {
        case "fact":
            guard let property, let fieldValue else { throw skip("a fact needs a property and a value") }
            payload = .fact(predicate: property, value: fieldValue, quantity: quantity)
        case "baseline", "addition", "removal", "purchase", "mention":
            guard let quantity, quantity.unit == .count, let event = NativeStockEvent(rawValue: kind) else {
                throw skip("a count needs a whole number")
            }
            payload = .stock(kind: event, quantity: quantity)
        case "completed", "planned", "recommended", "possible", "not_occurred":
            guard let property else { throw skip("care needs an activity") }
            payload = .care(activity: property, status: kind == "not_occurred" ? .notOccurred : NativeCareStatus(rawValue: kind) ?? .possible)
        case "retraction":
            guard supersedes != nil else { throw skip("a retraction needs the subject it retracts") }
            payload = .retraction
        default:
            throw skip("the kind is unknown")
        }
        return NativeDomainCandidate(subject: subject, scope: scope, payload: payload, occurredAt: occurredAt,
            evidence: evidence, supersedes: supersedes, span: span)
    }

    private static func skip(_ reason: String) -> NativeDomainExtractionSkip {
        NativeDomainExtractionSkip(reason: reason)
    }

    private static func text(_ value: Any?, field: String, maximum: Int) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String else { throw skip("the \(field) is not text") }
        let result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        guard result.count <= maximum else { throw skip("the \(field) is too long") }
        guard !NativeMemorySafety.containsSensitiveData(result) else { throw skip("the \(field) looks sensitive") }
        let lower = result.lowercased()
        guard !relativeWords.contains(where: { lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }) else {
            throw skip("the \(field) uses a relative date")
        }
        return result
    }

    private static func quantity(_ value: Any?, unit: Any?) throws -> NativeDomainQuantity? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw skip("the quantity is not a number")
        }
        var resolved = NativeDomainUnit.count
        if let unit, !(unit is NSNull) {
            guard let raw = unit as? String, let parsed = NativeDomainUnit(rawValue: raw.lowercased()) else {
                throw skip("the unit is unknown")
            }
            resolved = parsed
        }
        do { return try NativeDomainQuantity(NSDecimalNumber(decimal: number.decimalValue).stringValue, unit: resolved) }
        catch { throw skip("the quantity is not valid") }
    }

    private static func date(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String else { throw skip("the date is not text") }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            if let day = formatter.date(from: trimmed) { return day }
        }
        let instant = ISO8601DateFormatter()
        if let date = instant.date(from: trimmed) { return date }
        instant.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = instant.date(from: trimmed) { return date }
        throw skip("the date is not an absolute date")
    }
}

extension LocalChatRepository {
    static let domainSkipNote = "domain entry skipped: "

    static func domainExtractionID(_ key: String) -> String {
        let hex = Array(domainHash(key))
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }.joined(separator: "-").uppercased()
    }

    func recordDomainExtractionSkip(_ reason: String, key: String, now: Date = Date()) throws {
        try database.write { db in try Self.writeDomainSkip(reason, key: key, now: now, db: db) }
    }

    static func writeDomainSkip(_ reason: String, key: String, now: Date = Date(), db: Database) throws {
        let change = NativeMemoryChange(id: domainExtractionID("skip|" + key + "|" + reason), memoryID: nil, proposalID: nil,
            decision: .dismissed, note: domainSkipNote + reason, createdAt: now)
        try db.execute(sql: """
            INSERT OR IGNORE INTO native_memory_changes (id, memory_id, proposal_id, decision, note, created_at, change_json)
            VALUES (?, NULL, NULL, ?, ?, ?, ?)
            """, arguments: [change.id, change.decision.rawValue, change.note, now.timeIntervalSince1970, try domainJSON(change)])
    }

    static func domainSubjectKey(_ label: String) -> String {
        label.folding(options: .caseInsensitive, locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func domainRemovalKey(conversationID: String, messageID: String, subject: String, scope: String,
                                 payload: NativeDomainPayload) -> String {
        let fact: String = switch payload {
        case .stock(let kind, let quantity): "stock|" + kind.rawValue + "|" + quantity.amount + "|" + quantity.unit.rawValue
        case .fact(let predicate, let value, let quantity):
            "fact|" + domainSubjectKey(predicate) + "|" + domainSubjectKey(value) + "|"
                + (quantity.map { $0.amount + "|" + $0.unit.rawValue } ?? "")
        case .care(let activity, let status): "care|" + domainSubjectKey(activity) + "|" + status.rawValue
        case .retraction: "retraction"
        }
        return domainExtractionID(["removed", conversationID, messageID, domainSubjectKey(subject),
            domainSubjectKey(scope), fact].joined(separator: "|"))
    }

    func approvedDomainStream(label: String, scope: String) throws -> UUID? {
        let key = Self.domainSubjectKey(label)
        return try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.entity_id, s.label FROM native_domain_streams s
                WHERE s.scope = ? AND s.disabled = 0
                  AND EXISTS (SELECT 1 FROM native_domain_entries e WHERE e.entity_id = s.entity_id AND e.scope = s.scope)
                ORDER BY s.revision DESC, s.entity_id
                """, arguments: [scope]).first { Self.domainSubjectKey($0["label"]) == key }
                .flatMap { UUID(uuidString: $0["entity_id"]) }
        }
    }

    func domainSubject(label: String, scope: String) throws -> UUID? {
        if let stream = try approvedDomainStream(label: label, scope: scope) { return stream }
        let key = Self.domainSubjectKey(label)
        return try pendingProposals().compactMap(\.domain).first {
            Self.domainSubjectKey($0.label) == key && $0.entry.scope == scope
        }?.entry.entityID
    }

    static func correctionTarget(for payload: NativeDomainPayload, in entries: [NativeDomainEntry]) -> NativeDomainEntry? {
        entries.filter { entry in
            guard entry.status == .supported, let target = entry.payload else { return false }
            if case .retraction = target { return false }
            return NativeDomainProjection.compatible(payload, target)
                && !supersession(of: entry, in: entries, now: .distantFuture).superseded
        }.max { $0.occurredAt == $1.occurredAt ? $0.learnedAt < $1.learnedAt : $0.occurredAt < $1.occurredAt }
    }

    func stageExtractedDomainEntry(_ candidate: NativeDomainCandidate, conversationID: String, messageID: String,
                                   sourceText: String, fallbackDate: Date, now: Date = Date()) throws -> NativeMemoryProposal? {
        let proposalID = Self.domainExtractionID("entry|" + conversationID + "|" + messageID + "|" + (try Self.domainJSON(candidate)))
        let removal = Self.domainRemovalKey(conversationID: conversationID, messageID: messageID,
            subject: candidate.subject, scope: candidate.scope, payload: candidate.payload)
        let (known, removed) = try database.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_memory_proposals WHERE id = ?", arguments: [proposalID]) ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_domain_removed_proposals WHERE id = ?", arguments: [removal]) ?? 0)
        }
        if removed > 0 { throw NativeDomainExtractionSkip(reason: "this record was removed") }
        if known > 0 { return nil }
        guard let range = sourceText.range(of: candidate.span, options: .literal) else {
            throw NativeDomainExtractionSkip(reason: "the quoted text does not match the message")
        }
        let lower = sourceText.utf8.distance(from: sourceText.utf8.startIndex, to: range.lowerBound)
        let upper = lower + candidate.span.utf8.count
        var entity = try domainSubject(label: candidate.subject, scope: candidate.scope)
        var supersedes: [UUID] = []
        if let target = candidate.supersedes {
            guard let stream = try domainSubject(label: target, scope: candidate.scope) else {
                throw NativeDomainExtractionSkip(reason: "there is no earlier record to correct")
            }
            if let entity, entity != stream { throw NativeDomainExtractionSkip(reason: "the correction names a different subject") }
            entity = stream
            let approved = try domainEntries(stream, scope: candidate.scope)
            let pending = try pendingProposals().compactMap(\.domain).map(\.entry)
                .filter { $0.entityID == stream && $0.scope == candidate.scope }
            guard let latest = Self.correctionTarget(for: candidate.payload, in: approved + pending) else {
                throw NativeDomainExtractionSkip(reason: "there is no earlier record to correct")
            }
            supersedes = [latest.id]
        }
        let entry = NativeDomainEntry(id: UUID(), entityID: entity ?? UUID(), scope: candidate.scope,
            occurredAt: candidate.occurredAt ?? fallbackDate, validUntil: nil, learnedAt: now, actor: "user",
            source: NativeDomainSource(conversationID: conversationID, messageID: messageID,
                version: Self.domainHash(sourceText), lowerUTF8: lower, upperUTF8: upper),
            evidence: candidate.evidence, entityResolved: true, status: .supported, supersedes: supersedes, payload: candidate.payload)
        do { try entry.validate() } catch { throw NativeDomainExtractionSkip(reason: "the entry is incomplete") }
        do {
            return try stageDomainProposal(entry, label: candidate.subject, proposalID: proposalID)
        } catch NativeDomainError.sourceUnavailable {
            throw NativeDomainExtractionSkip(reason: "the message is no longer available")
        } catch NativeDomainError.changed {
            throw NativeDomainExtractionSkip(reason: "the subject was removed from memory")
        } catch {
            throw NativeDomainExtractionSkip(reason: "the entry conflicts with saved records")
        }
    }
}
