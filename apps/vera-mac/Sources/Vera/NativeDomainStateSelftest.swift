import Foundation

enum NativeDomainStateSelftest {
    static func entry(entity: UUID, at: Double, learned: Double? = nil, payload: NativeDomainPayload?,
                      id: UUID = UUID(), evidence: NativeDomainEvidence = .asserted, resolved: Bool = true,
                      status: NativeDomainStatus = .supported, until: Double? = nil, supersedes: [UUID] = [], scope: String = "farm") -> NativeDomainEntry {
        NativeDomainEntry(id: id, entityID: entity, scope: scope, occurredAt: Date(timeIntervalSince1970: at),
            validUntil: until.map(Date.init(timeIntervalSince1970:)), learnedAt: Date(timeIntervalSince1970: learned ?? at), actor: status == .deleted ? nil : "user",
            source: status == .deleted ? nil : NativeDomainSource(conversationID: "synthetic-chat", messageID: UUID().uuidString,
                version: String(repeating: "a", count: 64), lowerUTF8: 0, upperUTF8: 10),
            evidence: evidence, entityResolved: resolved, status: status, supersedes: supersedes, payload: payload)
    }

    static func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw NSError(domain: "DomainStateTest", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
    }

    static func run() throws {
        try require(try NativeDomainQuantity("0.5", unit: .dozen) == NativeDomainQuantity("6", unit: .count), "dozen normalization")
        try require(try NativeDomainQuantity("1.25", unit: .liter) == NativeDomainQuantity("1250", unit: .milliliter), "volume normalization")
        try require(try NativeDomainQuantity("0.001", unit: .kilogram) == NativeDomainQuantity("1", unit: .gram), "mass normalization")
        for value in ["-1", "NaN", "1e3", "01", "0.5", "1000000001"] {
            do { _ = try NativeDomainQuantity(value, unit: .count); throw NativeDomainError.conflict }
            catch NativeDomainError.invalid { }
        }
        let entity = UUID(), other = UUID()
        let baseline = entry(entity: entity, at: 10, payload: .stock(kind: .baseline, quantity: try NativeDomainQuantity("14", unit: .count)))
        let loss = entry(entity: entity, at: 20, payload: .stock(kind: .removal, quantity: try NativeDomainQuantity("2", unit: .count)))
        let corrected = entry(entity: entity, at: 10, learned: 40,
            payload: .stock(kind: .baseline, quantity: try NativeDomainQuantity("1", unit: .dozen)), supersedes: [baseline.id])
        let purchase = entry(entity: entity, at: 5, learned: 50,
            payload: .stock(kind: .purchase, quantity: try NativeDomainQuantity("10", unit: .count)))
        let old = entry(entity: entity, at: 2, learned: 60,
            payload: .stock(kind: .baseline, quantity: try NativeDomainQuantity("20", unit: .count)))
        let records = [old, loss, purchase, corrected, baseline, loss]
        let now = Date(timeIntervalSince1970: 100)
        let current = try NativeDomainProjection.stock(records, entity: entity, scope: "farm", at: now)
        try require(current.quantity?.amount == "10" && current.status == .supported, "late evidence resurrected removed stock")
        try require(Set(current.evidenceIDs) == [corrected.id, loss.id], "projection did not cite the correction and loss")
        try require(try NativeDomainProjection.stock(Array(records.reversed()), entity: entity, scope: "farm", at: now) == current, "arrival order changed state")
        let beforeLoss = try NativeDomainProjection.stock(records, entity: entity, scope: "farm", at: Date(timeIntervalSince1970: 15))
        try require(beforeLoss.quantity?.amount == "12", "historical corrected baseline missing")
        let knownThen = try NativeDomainProjection.stock(records, entity: entity, scope: "farm", at: Date(timeIntervalSince1970: 15), knownAt: Date(timeIntervalSince1970: 30))
        try require(knownThen.quantity?.amount == "14", "time learned replaced historical knowledge")
        try require(try NativeDomainProjection.stock(records, entity: other, scope: "farm", at: now).quantity == nil, "entity boundary leaked")
        try require(try NativeDomainProjection.stock(records, entity: entity, scope: "other", at: now).quantity == nil, "scope boundary leaked")
        try require(try NativeDomainProjection.stock([loss, purchase], entity: entity, scope: "farm", at: now).status == .uncertain, "missing baseline invented a count")
        let disagreement = entry(entity: entity, at: 10, payload: .stock(kind: .baseline, quantity: try NativeDomainQuantity("13", unit: .count)))
        try require(try NativeDomainProjection.stock([baseline, disagreement], entity: entity, scope: "farm", at: now).status == .disputed, "same-time conflict silently won")
        for evidence in [NativeDomainEvidence.negated, .hypothetical, .reported, .ambiguous] {
            let unconfirmed = entry(entity: entity, at: 20, payload: .stock(kind: .addition, quantity: try NativeDomainQuantity("4", unit: .count)), evidence: evidence)
            try require(try NativeDomainProjection.stock([baseline, unconfirmed], entity: entity, scope: "farm", at: now).quantity == nil, "unconfirmed statement became stock")
        }
        let ambiguousEntity = entry(entity: entity, at: 10, payload: .stock(kind: .baseline, quantity: try NativeDomainQuantity("3", unit: .count)), resolved: false)
        try require(try NativeDomainProjection.stock([ambiguousEntity], entity: entity, scope: "farm", at: now).quantity == nil, "ambiguous alias selected an entity")
        let care = [NativeCareStatus.planned, .recommended, .possible, .notOccurred].map {
            entry(entity: entity, at: 20, payload: .care(activity: "Vaccination", status: $0))
        }
        try require(try NativeDomainProjection.completedCare(care, entity: entity, scope: "farm", at: now).isEmpty, "noncompleted care became completed")
        let completed = entry(entity: entity, at: 25, payload: .care(activity: "Water change", status: .completed))
        let quoted = entry(entity: entity, at: 25, payload: .care(activity: "Vaccination", status: .completed), evidence: .reported)
        try require(try NativeDomainProjection.completedCare(care + [completed, quoted], entity: entity, scope: "farm", at: now).map(\.id) == [completed.id], "care attribution changed")
        let deletedLoss = entry(entity: entity, at: 20, payload: nil, id: loss.id, status: .deleted)
        try require(try NativeDomainProjection.stock([baseline, deletedLoss, purchase], entity: entity, scope: "farm", at: now).quantity == nil, "deleted loss resurrected stock")
        let restoredBaseline = entry(entity: entity, at: 30, payload: .stock(kind: .baseline, quantity: try NativeDomainQuantity("8", unit: .count)))
        try require(try NativeDomainProjection.stock([baseline, deletedLoss, restoredBaseline], entity: entity, scope: "farm", at: now).quantity?.amount == "8", "new confirmed baseline did not resolve a gap")
        let retract = entry(entity: entity, at: 20, learned: 45, payload: .retraction, supersedes: [loss.id])
        try require(try NativeDomainProjection.stock([baseline, loss, retract], entity: entity, scope: "farm", at: now).quantity?.amount == "14", "explicit retraction did not rebuild state")
        let simultaneousLoss = entry(entity: entity, at: 10, payload: loss.payload)
        try require(try NativeDomainProjection.stock([baseline, simultaneousLoss], entity: entity, scope: "farm", at: now).quantity == nil, "same-time change silently ignored")
        for payload in [loss.payload, baseline.payload, completed.payload, nil] {
            let expiring = entry(entity: entity, at: 20, payload: payload, status: payload == nil ? .deleted : .supported, until: 30)
            do { try expiring.validate(); throw NativeDomainError.conflict }
            catch NativeDomainError.invalid { }
        }
        let deniedCare = entry(entity: entity, at: 25, payload: .care(activity: "Water change", status: .notOccurred))
        let negatedCare = entry(entity: entity, at: 25, payload: completed.payload, evidence: .negated)
        for contradiction in [deniedCare, negatedCare] {
            try require(try NativeDomainProjection.completedCare([completed, contradiction], entity: entity, scope: "farm", at: now).isEmpty, "contradictory care became completed")
        }
        let unrelated = entry(entity: entity, at: 30, payload: .care(activity: "Feeding", status: .planned), supersedes: [loss.id])
        do { _ = try NativeDomainProjection.stock([baseline, loss, unrelated], entity: entity, scope: "farm", at: now); throw NativeDomainError.conflict }
        catch NativeDomainError.invalid { }
        let oldFact = entry(entity: entity, at: 10, payload: .fact(predicate: "Color", value: "red", quantity: nil))
        let deletedCorrection = entry(entity: entity, at: 20, payload: nil, status: .deleted, supersedes: [oldFact.id])
        let remaining = try NativeDomainProjection.active([oldFact, deletedCorrection], entity: entity, scope: "farm", at: now, knownAt: .distantFuture)
        try require(!remaining.contains { $0.id == oldFact.id }, "deleted correction restored an old fact")
        let deletedCareCorrection = entry(entity: entity, at: 30, payload: nil, status: .deleted, supersedes: [completed.id])
        try require(try NativeDomainProjection.completedCare([completed, deletedCareCorrection], entity: entity, scope: "farm", at: now).isEmpty, "deleted correction restored completed care")
        let branchB = entry(entity: entity, at: 20, payload: oldFact.payload, supersedes: [oldFact.id])
        let branchC = entry(entity: entity, at: 20, payload: oldFact.payload, supersedes: [oldFact.id])
        let converged = entry(entity: entity, at: 30, payload: oldFact.payload, supersedes: [branchB.id, branchC.id])
        try require(try NativeDomainProjection.active([oldFact, branchB, branchC, converged], entity: entity, scope: "farm", at: now, knownAt: .distantFuture).map(\.id) == [converged.id], "valid convergent corrections rejected")
        let cycleID = UUID()
        let cycleA = entry(entity: entity, at: 10, payload: oldFact.payload, id: cycleID, supersedes: [branchB.id])
        let cycleB = entry(entity: entity, at: 10, payload: oldFact.payload, id: branchB.id, supersedes: [cycleID])
        do { _ = try NativeDomainProjection.active([cycleA, cycleB], entity: entity, scope: "farm", at: now, knownAt: .distantFuture); throw NativeDomainError.conflict }
        catch NativeDomainError.invalid { }
        print("domain-state: PASS (deterministic units, correction, history, learned time, removal replay, conflicts, scope, typed negation/hypothesis/attribution, care and deletion barriers; no model extraction tested)")
    }
}
