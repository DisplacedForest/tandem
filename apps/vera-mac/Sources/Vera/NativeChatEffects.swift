import Foundation
import CryptoKit

enum NativeStaleAnswerPolicy: Sendable, Equatable {
    case refuse
    case decideAgain
}

enum NativeChatEffects {
    static let staleAnswers: NativeStaleAnswerPolicy = .decideAgain
    static let admissionAttempts = 3
    static let interruptedReason = "interrupted"

    static func records(_ definition: NativeToolDefinition, _ arguments: [String: NativeJSONValue]) -> Bool {
        definition.effect == .write && !definition.proposes && definition.proposesFor?(arguments) != true
            && definition.id != NativeTaskTools.toolID
    }

    static func idempotencyKey(turnID: String, attempt: String, round: Int, call: String) -> String {
        let digest = SHA256.hash(data: Data("turn|\(turnID)|\(attempt)|\(round)|\(call)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    static func marksBoundary(_ definition: NativeToolDefinition) -> Bool {
        definition.governed || definition.id == NativeCompanionProfileTools.toolID
    }

    static func settlement(for error: Error, boundary: NativeEffectBoundary, marks: Bool) -> NativeChatEffectOutcome {
        if error is CancellationError { return .uncertain("stopped") }
        if case .failed(let detail)? = error as? NativeToolError, detail == NativeToolLoop.timedOutMessage { return .uncertain("timeout") }
        if boundary.reached { return .uncertain("no_receipt") }
        if marks || NativeCompanionWorker.definite(error) || error is NativeRuleRefusal { return .absent("refused") }
        return .uncertain("no_receipt")
    }

    static func settlement(for value: NativeJSONValue, toolName: String) -> NativeChatEffectOutcome {
        if NativeCompanionWorker.interrupted(value) { return .uncertain("interrupted_run") }
        if NativeToolLoop.resultFailed(value, toolName: toolName) { return .uncertain("failed_result") }
        return .completed(value)
    }

    static func reply(_ answer: NativeCardAnswer, digest: String) -> NativeJSONValue {
        .object(["action": .string(answer.kind.rawValue), "digest": .string(digest)])
    }
}

final class NativeEffectBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    var reached: Bool { lock.withLock { marked } }

    func mark() { lock.withLock { marked = true } }
}

struct NativeChatDecision: Sendable, Equatable {
    let action: NativeActionClass
    let decision: NativeRuleDecision
}

struct NativeCardAnswer: Sendable, Equatable {
    let kind: NativeCardChoiceKind
    let byPerson: Bool
}

struct NativeChatEffectRevisions: Sendable, Equatable {
    let rules: Int
    let grants: Int
}

struct NativeChatEffectCall: Sendable {
    let definition: NativeToolDefinition
    let arguments: [String: NativeJSONValue]
    let activity: NativeToolActivity
    let action: NativeActionClass
    let revisions: NativeChatEffectRevisions
}

struct NativeChatEffectTicket: Sendable, Equatable {
    let digest: String
    let proposal: NativeEffectProposal
    let activityID: String
    var instruction: String? = nil
}

enum NativeChatEffectAdmission: Sendable, Equatable {
    case admitted
    case stale
    case refused
}

enum NativeChatEffectOutcome: Sendable, Equatable {
    case completed(NativeJSONValue)
    case absent(String)
    case uncertain(String)
}

struct NativeChatEffectHook: Sendable {
    var revisions: @Sendable () -> NativeChatEffectRevisions
    var propose: @Sendable (NativeChatEffectCall) async -> NativeChatEffectTicket?
    var admit: @Sendable (NativeChatEffectTicket, NativeRuleDecision, NativeCardAnswer?) async -> NativeChatEffectAdmission
    var decline: @Sendable (NativeChatEffectTicket, NativeCardAnswer) async -> Void
    var confirm: @Sendable (NativeToolActivity, String) async -> NativeCardAnswer
    var answered: @Sendable (NativeToolActivity, NativeCardAnswer) async -> Void
    var settle: @Sendable (NativeChatEffectTicket, NativeChatEffectOutcome) async -> Void
    var staleAnswers: NativeStaleAnswerPolicy = NativeChatEffects.staleAnswers
}

struct NativeChatEffectLedger: Sendable {
    let ledger: NativeEffectLedgerStore
    let rules: NativeRuleSource
    let grants: NativeFolderGrantSource
    let records: NativeRuleRecordStore?
    let conversationID: String
    let turnID: String
    let attempt: String
    var userMessageID: UUID? = nil

    func revisions() -> NativeChatEffectRevisions {
        NativeChatEffectRevisions(rules: rules.revision, grants: grants.revision)
    }

    func proposal(_ call: NativeChatEffectCall) -> NativeEffectProposal {
        NativeEffectProposal(
            id: UUID().uuidString.lowercased(), taskID: NativeEffectProposal.turnTaskID(turnID), generation: 0,
            toolID: call.definition.id, function: call.definition.name,
            argumentsJSON: NativeEffectProposal.canonicalArguments(.object(call.arguments)),
            target: NativeCompanionWorker.target(call.arguments), action: call.action,
            rulesRevision: call.revisions.rules, grantsRevision: call.revisions.grants, conversationID: conversationID,
            expiresAtMilliseconds: NativeEffectProposal.expiry(from: ledger.now()),
            idempotencyKey: NativeChatEffects.idempotencyKey(turnID: turnID, attempt: attempt, round: call.activity.round, call: call.activity.id),
            turnID: turnID, turnAttempt: attempt)
    }

    func propose(_ call: NativeChatEffectCall) async -> NativeChatEffectTicket? {
        let proposal = proposal(call)
        let ledger = ledger
        return await Task.detached(priority: .userInitiated) { () -> NativeChatEffectTicket? in
            guard let record = try? ledger.propose(proposal) else { return nil }
            return NativeChatEffectTicket(digest: record.digest, proposal: record.proposal, activityID: call.activity.id)
        }.value
    }

    func admit(_ ticket: NativeChatEffectTicket, decision: NativeRuleDecision, answer: NativeCardAnswer?) async -> NativeChatEffectAdmission {
        let ledger = ledger
        let rules = rules
        let grants = grants
        let records = records
        let reply = answer.map { NativeChatEffects.reply($0, digest: ticket.digest) }
        let decisionID: String? = answer == nil ? nil : ticket.activityID
        let spend = spend(ticket, decision: decision)
        return await Task.detached(priority: .userInitiated) { () -> NativeChatEffectAdmission in
            let admission: NativeEffectAdmission
            do {
                admission = try ledger.admit(digest: ticket.digest, generation: 0, rulesRevision: ticket.proposal.rulesRevision,
                                             grantsRevision: ticket.proposal.grantsRevision, decision: decision, decisionID: decisionID,
                                             reply: reply, live: { (rules.revision, grants.revision) }, rulesDurable: rules.isDurable,
                                             authorizedBy: [], instruction: spend)
            } catch {
                return .refused
            }
            switch admission {
            case .admitted: return .admitted
            case .refused(.staleRules), .refused(.staleGrants), .refused(.grantSpent):
                if let records, rules.isDurable { ChatStore.reloadRules(rules, from: records) }
                return .stale
            case .refused: return .refused
            }
        }.value
    }

    func spend(_ ticket: NativeChatEffectTicket, decision: NativeRuleDecision) -> NativeInstructionSpend? {
        guard decision == .act(.instruction), let signature = ticket.instruction, let userMessageID else { return nil }
        return NativeInstructionSpend(messageID: userMessageID, conversationID: conversationID, signature: signature,
                                      holder: ticket.proposal.idempotencyKey)
    }

    func decline(_ ticket: NativeChatEffectTicket, answer: NativeCardAnswer) async {
        let ledger = ledger
        let reply = NativeChatEffects.reply(answer, digest: ticket.digest)
        await Task.detached(priority: .userInitiated) {
            try? ledger.decline(digest: ticket.digest, decisionID: ticket.activityID, reply: reply)
        }.value
    }

    func settle(_ ticket: NativeChatEffectTicket, _ outcome: NativeChatEffectOutcome) async {
        let ledger = ledger
        await Task.detached(priority: .userInitiated) {
            switch outcome {
            case .completed(let receipt):
                try? ledger.settle(digest: ticket.digest, receipt: receipt, modelClaim: nil)
            case .absent(let reason):
                try? ledger.markUncertain(digest: ticket.digest, reason: reason)
                try? ledger.observe(digest: ticket.digest, .absent)
            case .uncertain(let reason):
                try? ledger.markUncertain(digest: ticket.digest, reason: reason)
            }
        }.value
    }
}
