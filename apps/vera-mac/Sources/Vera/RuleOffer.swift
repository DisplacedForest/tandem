import Foundation

struct RuleOfferState: Equatable, Sendable {
    var approvals = 0
    var answered = false
}

enum RuleOfferEvent: Equatable, Sendable {
    case approved(NativeRuleWhy?)
    case declined(NativeRuleWhy?)
    case standing
    case answered
}

enum RuleOfferAnswer: String, CaseIterable, Sendable {
    case allow
    case allowEverywhere = "allow_everywhere"
    case decline
    case neverOffer = "never_offer"
}

enum RuleOffer {
    static let approvalsBeforeOffer = 3
    static let everyChat = ""

    static func offerable(_ action: NativeActionClass) -> Bool {
        action.floorItem == nil && NativeActionClass.configurable.contains(action)
    }

    static func counts(_ why: NativeRuleWhy?) -> Bool {
        guard let why, why.kind == .unsaved, why.source == .settings, !why.handsOff,
              why.choice == .ask || why.choice == .actIfPreapproved else { return false }
        return offerable(why.action)
    }

    static func event(_ decision: NativeCardChoiceKind, why: NativeRuleWhy?) -> RuleOfferEvent {
        switch decision {
        case .allowOnce: return .approved(why)
        case .decline, .never: return .declined(why)
        case .allowHere, .allowAlways, .allowSchedule: return .standing
        }
    }

    static func apply(_ event: RuleOfferEvent, to state: RuleOfferState, turnedOff: Bool) -> (state: RuleOfferState, offer: Bool) {
        var next = state
        switch event {
        case .approved(let why):
            guard counts(why) else { return (state, false) }
            next.approvals += 1
        case .declined(let why):
            guard counts(why) else { return (state, false) }
            next.approvals = 0
        case .standing:
            return (state, false)
        case .answered:
            next.approvals = 0
            next.answered = true
            return (next, false)
        }
        return (next, next.approvals >= approvalsBeforeOffer && !next.answered && !turnedOff)
    }

    static func stillAsks(_ action: NativeActionClass, global: NativeRules, chat: NativeConversationRules) -> Bool {
        guard offerable(action), !global.holds(action) else { return false }
        let base = global.choice(for: action)
        guard base == .ask || base == .actIfPreapproved else { return false }
        if let tightened = chat.choices[action], tightened.strictness > base.strictness { return false }
        return true
    }

    static func record(_ action: NativeActionClass, conversationID: String, now: Date = Date()) -> NativeRuleRecord {
        NativeRuleRecord(scope: .conversation(conversationID), action: action, toolID: nil, target: nil, effect: .allow,
                         statement: RuleOfferCopy.statement(action), origin: .confirmCard, originConversationID: conversationID,
                         reason: RuleOfferCopy.reason, createdAt: now)
    }
}

enum RuleOfferCopy {
    static func words(_ action: NativeActionClass) -> String {
        switch action {
        case .fileEdits: return "file edits"
        case .commands: return "running commands"
        case .trash: return "moving files to the Trash"
        case .networkSends: return "sending on your behalf"
        case .riskyCommands: return "running risky commands"
        case .reminders: return "changing reminders"
        case .serviceChanges: return "making changes through connected services"
        case .otherChanges: return "making other changes"
        case .credentialEntry, .payments, .permanentDeletion: return RuleRows.doing(action)
        }
    }

    static func question(_ action: NativeActionClass) -> String { "Stop asking before \(words(action)) in this chat?" }
    static func allowedHere(_ action: NativeActionClass) -> String { "Stopped asking before \(words(action)) in this chat." }
    static func allowedEverywhere(_ action: NativeActionClass) -> String { "Stopped asking before \(words(action)) everywhere." }
    static func statement(_ action: NativeActionClass) -> String { "Always allow \(words(action))" }
    static let failed = "That couldn't be saved. Try again."
    static let allowEverywhere = "Allow everywhere"
    static let neverOffer = "Don't offer this again"
    static let reason = "You chose this on a confirmation card."

    static func strings(_ action: NativeActionClass) -> [String] {
        let answers = CardAnswers.offer()
        return [question(action), allowedHere(action), allowedEverywhere(action), failed, answers.allowTitle, answers.declineTitle,
                RefusalCopy.changeInRules, statement(action)]
            + (answers.allowMenu + answers.declineMenu).map(\.spoken)
            + RuleOfferCard.spoken(question(action), answers: answers)
    }
}

struct NativeRuleOffer: Codable, Hashable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case waiting
        case allowedHere = "allowed_here"
        case allowedEverywhere = "allowed_everywhere"
        case closed
    }

    var id: String
    var actionName: String
    var state: State
    var failed = false

    init(id: String = UUID().uuidString.lowercased(), action: NativeActionClass, state: State = .waiting, failed: Bool = false) {
        self.id = id
        self.actionName = action.rawValue
        self.state = state
        self.failed = failed
    }

    var action: NativeActionClass? { NativeActionClass(rawValue: actionName) }
    var blockID: String { "offer:" + id }

    private enum CodingKeys: String, CodingKey {
        case id, state, failed
        case actionName = "action"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        actionName = (try? container.decode(String.self, forKey: .actionName)) ?? ""
        state = (try? container.decode(State.self, forKey: .state)) ?? .closed
        failed = (try? container.decodeIfPresent(Bool.self, forKey: .failed)) ?? false
    }
}
