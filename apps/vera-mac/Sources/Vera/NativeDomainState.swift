import Foundation

enum NativeDomainError: LocalizedError {
    case invalid, conflict, sourceUnavailable, changed
    var errorDescription: String? {
        switch self {
        case .invalid: "This proposed record is incomplete or inconsistent."
        case .conflict: "The evidence disagrees. Review the conflicting records before using this value."
        case .sourceUnavailable: "The original evidence is no longer available."
        case .changed: "These records changed. Review the updated evidence before applying this proposal."
        }
    }
}

enum NativeDomainUnit: String, Codable, Sendable {
    case count, dozen, gram, kilogram, milliliter, liter
    var canonical: Self {
        switch self {
        case .dozen: .count
        case .kilogram: .gram
        case .liter: .milliliter
        default: self
        }
    }
    var multiplier: Decimal {
        switch self {
        case .dozen: 12
        case .kilogram, .liter: 1000
        default: 1
        }
    }
}

struct NativeDomainQuantity: Codable, Hashable, Sendable {
    let amount: String
    let unit: NativeDomainUnit
    init(_ amount: String, unit: NativeDomainUnit) throws {
        guard amount.range(of: #"^(0|[1-9][0-9]*)(\.[0-9]{1,6})?$"#, options: .regularExpression) != nil,
              amount.count <= 32, let number = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else { throw NativeDomainError.invalid }
        var normalized = number * unit.multiplier
        guard normalized >= 0, normalized <= 1_000_000_000 else { throw NativeDomainError.invalid }
        if unit.canonical == .count {
            var whole = Decimal()
            NSDecimalRound(&whole, &normalized, 0, .plain)
            guard whole == normalized else { throw NativeDomainError.invalid }
        }
        self.amount = NSDecimalNumber(decimal: normalized).stringValue
        self.unit = unit.canonical
    }
    var decimal: Decimal { Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX"))! }
    func validated() throws -> Self {
        let value = try Self(amount, unit: unit)
        guard value == self else { throw NativeDomainError.invalid }
        return value
    }
}

struct NativeDomainSource: Codable, Hashable, Sendable {
    let conversationID: String
    let messageID: String
    let version: String
    let lowerUTF8: Int
    let upperUTF8: Int
}

enum NativeDomainStatus: String, Codable, Sendable {
    case supported, disputed, superseded, retracted, uncertain, deleted
}

enum NativeDomainEvidence: String, Codable, Sendable {
    case asserted, negated, hypothetical, reported, ambiguous
}

enum NativeStockEvent: String, Codable, Sendable {
    case baseline, addition, removal, purchase, mention
}

enum NativeCareStatus: String, Codable, Sendable {
    case completed, planned, recommended, possible, notOccurred
}

enum NativeDomainPayload: Codable, Hashable, Sendable {
    case fact(predicate: String, value: String, quantity: NativeDomainQuantity?)
    case stock(kind: NativeStockEvent, quantity: NativeDomainQuantity)
    case care(activity: String, status: NativeCareStatus)
    case retraction
}

struct NativeDomainEntry: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let entityID: UUID
    let scope: String
    let occurredAt: Date
    let validUntil: Date?
    let learnedAt: Date
    let actor: String?
    let source: NativeDomainSource?
    let evidence: NativeDomainEvidence
    let entityResolved: Bool
    let status: NativeDomainStatus
    let supersedes: [UUID]
    let payload: NativeDomainPayload?

    func validate() throws {
        guard !scope.isEmpty, scope.utf8.count <= 128, !NativeMemorySafety.containsSensitiveData(scope),
              occurredAt.timeIntervalSince1970.isFinite, learnedAt.timeIntervalSince1970.isFinite,
              validUntil.map({ $0.timeIntervalSince1970.isFinite && $0 > occurredAt }) ?? true,
              Set(supersedes).count == supersedes.count, supersedes.count <= 16, !supersedes.contains(id) else { throw NativeDomainError.invalid }
        if status == .deleted {
            guard payload == nil, source == nil, actor == nil, validUntil == nil else { throw NativeDomainError.invalid }
            return
        }
        guard let payload, let source, let actor, !actor.isEmpty, actor.utf8.count <= 128,
              !NativeMemorySafety.containsSensitiveData(actor), !source.conversationID.isEmpty, !source.messageID.isEmpty,
              source.version.count == 64, source.version.allSatisfy({ "0123456789abcdef".contains($0) }),
              source.lowerUTF8 >= 0, source.upperUTF8 > source.lowerUTF8,
              source.upperUTF8 - source.lowerUTF8 <= 8192 else { throw NativeDomainError.invalid }
        switch payload {
        case .fact(let predicate, let value, let quantity):
            guard !predicate.isEmpty, predicate.utf8.count <= 128, !value.isEmpty, value.utf8.count <= 512 else { throw NativeDomainError.invalid }
            if let quantity { _ = try quantity.validated() }
        case .stock(_, let quantity):
            guard validUntil == nil, try quantity.validated().unit == .count else { throw NativeDomainError.invalid }
        case .care(let activity, let status):
            guard (status != .completed && status != .notOccurred) || validUntil == nil else { throw NativeDomainError.invalid }
            guard !activity.isEmpty, activity.utf8.count <= 256 else { throw NativeDomainError.invalid }
        case .retraction:
            guard !supersedes.isEmpty, validUntil == nil else { throw NativeDomainError.invalid }
        }
    }
}

struct NativeStockProjection: Equatable, Sendable {
    let quantity: NativeDomainQuantity?
    let status: NativeDomainStatus
    let evidenceIDs: [UUID]
    let reason: String?
}

enum NativeDomainProjection {
    static func active(_ entries: [NativeDomainEntry], entity: UUID, scope: String, at: Date, knownAt: Date) throws -> [NativeDomainEntry] {
        var seen: [UUID: NativeDomainEntry] = [:]
        for entry in entries {
            try entry.validate()
            if let previous = seen[entry.id], previous != entry { throw NativeDomainError.conflict }
            seen[entry.id] = entry
        }
        for entry in seen.values {
            for targetID in entry.supersedes {
                guard let target = seen[targetID], target.entityID == entry.entityID, target.scope == entry.scope,
                      target.learnedAt <= entry.learnedAt else { throw NativeDomainError.invalid }
                if target.status != .deleted && entry.status != .deleted {
                    guard compatible(entry.payload, target.payload) else { throw NativeDomainError.invalid }
                }
                var visited: Set<UUID> = [entry.id]
                var pending = [targetID]
                while let id = pending.popLast() {
                    guard id != entry.id else { throw NativeDomainError.invalid }
                    guard visited.insert(id).inserted else { continue }
                    pending.append(contentsOf: seen[id]?.supersedes ?? [])
                }
            }
        }
        let dated = seen.values.filter {
            $0.entityID == entity && $0.scope == scope && $0.occurredAt <= at && $0.learnedAt <= knownAt
        }
        let superseded = Set(dated.filter { ($0.status == .supported || $0.status == .deleted) && $0.entityResolved && $0.evidence == .asserted }.flatMap(\.supersedes))
        return dated.filter { !superseded.contains($0.id) && ![.superseded, .retracted].contains($0.status)
                && ($0.validUntil.map { $0 > at } ?? true) }
            .sorted { $0.occurredAt == $1.occurredAt ? $0.id.uuidString < $1.id.uuidString : $0.occurredAt < $1.occurredAt }
    }

    static func compatible(_ replacement: NativeDomainPayload?, _ target: NativeDomainPayload?) -> Bool {
        switch (replacement, target) {
        case (.retraction, .some): true
        case (.stock(let lhs, _), .stock(let rhs, _)): lhs == rhs
        case (.fact(let lhs, _, _), .fact(let rhs, _, _)): lhs == rhs
        case (.care(let lhs, _), .care(let rhs, _)): lhs == rhs
        default: false
        }
    }

    static func stock(_ entries: [NativeDomainEntry], entity: UUID, scope: String, at: Date, knownAt: Date = .distantFuture) throws -> NativeStockProjection {
        let active = try active(entries, entity: entity, scope: scope, at: at, knownAt: knownAt)
        let baselines = active.filter {
            if case .stock(.baseline, _) = $0.payload { return $0.status == .supported && $0.evidence == .asserted && $0.entityResolved }
            return false
        }
        guard let newest = baselines.map(\.occurredAt).max() else {
            return NativeStockProjection(quantity: nil, status: .uncertain, evidenceIDs: [], reason: "There is no confirmed starting count.")
        }
        let starting = baselines.filter { $0.occurredAt == newest }
        let quantities = Set(starting.compactMap { entry -> NativeDomainQuantity? in
            if case .stock(_, let quantity) = entry.payload { return quantity }
            return nil
        })
        guard quantities.count == 1, let baseline = quantities.first else {
            return NativeStockProjection(quantity: nil, status: .disputed, evidenceIDs: starting.map(\.id), reason: "The starting counts disagree.")
        }
        var value = baseline.decimal
        var evidence = starting.map(\.id)
        for event in active where event.occurredAt >= newest {
            if event.status == .deleted {
                return NativeStockProjection(quantity: nil, status: .uncertain, evidenceIDs: evidence, reason: "A record needed to establish the count was removed.")
            }
            guard case .stock(let kind, let quantity) = event.payload, [.addition, .removal, .baseline].contains(kind) else { continue }
            guard event.status == .supported, event.evidence == .asserted, event.entityResolved else {
                return NativeStockProjection(quantity: nil, status: .uncertain, evidenceIDs: evidence + [event.id], reason: "A stock change needs clarification.")
            }
            guard kind != .baseline else { continue }
            guard event.occurredAt > newest else {
                return NativeStockProjection(quantity: nil, status: .uncertain, evidenceIDs: evidence + [event.id], reason: "The count and change have the same time. Clarify whether the count includes the change.")
            }
            value += kind == .addition ? quantity.decimal : -quantity.decimal
            evidence.append(event.id)
            guard value >= 0, value <= 1_000_000_000 else {
                return NativeStockProjection(quantity: nil, status: .disputed, evidenceIDs: evidence, reason: "The recorded changes do not produce a valid count.")
            }
        }
        return NativeStockProjection(quantity: try NativeDomainQuantity(NSDecimalNumber(decimal: value).stringValue, unit: .count),
            status: .supported, evidenceIDs: evidence, reason: nil)
    }

    static func completedCare(_ entries: [NativeDomainEntry], entity: UUID, scope: String, at: Date,
                              knownAt: Date = .distantFuture) throws -> [NativeDomainEntry] {
        let candidates = try active(entries, entity: entity, scope: scope, at: at, knownAt: knownAt)
        return candidates.filter { entry in
            guard entry.status == .supported, entry.evidence == .asserted, entry.entityResolved,
                  case .care(let activity, .completed) = entry.payload else { return false }
            return !candidates.contains { other in
                guard other.occurredAt == entry.occurredAt, other.id != entry.id else { return false }
                if other.status == .deleted { return true }
                guard case .care(let name, let status) = other.payload, name == activity else { return false }
                return status == .notOccurred || other.evidence == .negated || other.status == .disputed
                    || other.status == .uncertain || !other.entityResolved
            }
        }
    }
}
