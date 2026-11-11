import Foundation

struct NativeRuleWhy: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case unsaved
        case outside
        case rule
        case held
        case tool
        case folder
        case unnamed
    }

    enum Source: String, Codable, Sendable {
        case settings
        case chat
    }

    struct Rule: Codable, Hashable, Sendable {
        var id: String
        var scope: NativeRuleScope
        var action: NativeActionClass?
        var toolID: String?
        var target: NativeRuleTarget?
        var effect: NativeRuleEffect
        var statement: String

        init(_ record: NativeRuleRecord) {
            id = record.id
            scope = record.scope
            action = record.action
            toolID = record.toolID
            target = record.target
            effect = record.effect
            statement = record.statement
        }

        var record: NativeRuleRecord {
            NativeRuleRecord(id: id, scope: scope, action: action, toolID: toolID, target: target, effect: effect, statement: statement)
        }
    }

    struct Trigger: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable {
            case program
            case path
            case feature
        }

        var kind: Kind
        var text: String

        static let limit = 200

        init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = kind == .path && !Self.isPlainPath(text) ? "" : String(text.prefix(Self.limit))
        }

        static func isPlainPath(_ text: String) -> Bool {
            if NativeCommandClassifier.sensitiveFragments.contains(text.lowercased()) { return true }
            guard ["/", "~/", "./", "../"].contains(where: { text.hasPrefix($0) }), !text.hasPrefix("//") else { return false }
            return !text.contains("://") && !text.contains("@") && !text.contains("=") && !text.contains("?")
        }
    }

    var kind: Kind
    var action: NativeActionClass
    var handsOff: Bool
    var choice: NativeRuleChoice?
    var source: Source?
    var rule: Rule?
    var item: String?
    var subject: String?
    var trigger: Trigger?

    static let subjectLimit = 300

    init(kind: Kind, action: NativeActionClass, handsOff: Bool, choice: NativeRuleChoice? = nil, source: Source? = nil, rule: Rule? = nil,
         item: NativeFloorItem? = nil, subject: String? = nil, trigger: Trigger? = nil) {
        self.kind = kind
        self.action = action
        self.handsOff = handsOff
        self.choice = choice
        self.source = source
        self.rule = rule
        self.item = item?.rawValue
        self.subject = subject.map { String($0.prefix(Self.subjectLimit)) }
        self.trigger = trigger
    }

    var floorItem: NativeFloorItem? { item.flatMap(NativeFloorItem.init(rawValue:)) }

    func with(_ trigger: Trigger?) -> NativeRuleWhy {
        guard let trigger, self.trigger == nil else { return self }
        var copy = self
        copy.trigger = trigger
        return copy
    }

    static func tool(_ action: NativeActionClass) -> NativeRuleWhy {
        NativeRuleWhy(kind: .tool, action: action, handsOff: false)
    }

    static func folder(_ action: NativeActionClass, path: String) -> NativeRuleWhy {
        NativeRuleWhy(kind: .folder, action: action, handsOff: true, subject: path, trigger: Trigger(.path, path))
    }
}

extension NativeRuleMatcher {
    static func unmatchedAllow(_ records: [NativeRuleRecord], query: NativeRuleQuery, context: NativeRuleContext?, at now: Date,
                               honoringLimitedUse: Bool) -> NativeRuleRecord? {
        records.filter { record in
            guard record.effect == .allow, record.target != nil, record.scope.applies(in: context) else { return false }
            if !honoringLimitedUse && record.remainingUses != nil { return false }
            return record.applies(to: query, at: now) && !query.parts.allSatisfy { record.matches($0, at: now) }
        }.sorted(by: precedes).first
    }

    static func untargetedRestriction(_ records: [NativeRuleRecord], query: NativeRuleQuery, context: NativeRuleContext?, at now: Date) -> NativeRuleRecord? {
        records.filter { record in
            guard record.effect.restricts, let target = record.target, record.scope.applies(in: context),
                  record.applies(to: query, at: now) else { return false }
            return !query.targets.contains { $0.kind == target.kind }
        }.sorted(by: precedes).first
    }
}

extension NativeRuleResolver {
    func source(for action: NativeActionClass) -> NativeRuleWhy.Source {
        guard let tightened = conversation.choices[action] else { return .settings }
        return tightened.strictness > global.choice(for: action).strictness ? .chat : .settings
    }

    func why(_ query: NativeRuleQuery, decision: NativeRuleDecision, resolution: NativeRuleResolution?, honoringLimitedUse: Bool) -> NativeRuleWhy? {
        if case .act = decision { return nil }
        let handsOff = decision == .handOff
        if let item = query.action.floorItem, global.holds(query.action) {
            return NativeRuleWhy(kind: .held, action: query.action, handsOff: true, item: item)
        }
        if let winner = resolution?.decidedBy, winner.effect.restricts {
            return NativeRuleWhy(kind: .rule, action: query.action, handsOff: handsOff, rule: .init(winner))
        }
        if overruled(resolution, for: query.action) {
            return NativeRuleWhy(kind: .unsaved, action: query.action, handsOff: handsOff, choice: choice(for: query.action), source: .chat)
        }
        if decision == .ask, let target = unnamed(in: query, honoringLimitedUse: honoringLimitedUse),
           case .act = settle(query, honoringLimitedUse: honoringLimitedUse).decision {
            return NativeRuleWhy(kind: .unnamed, action: query.action, handsOff: false, subject: target.value)
        }
        let allowed = resolution?.decidedBy.effect == .allow
        let settled = choice(for: query.action)
        let wouldAct = allowed || (resolution == nil && settled == .act)
        if decision == .ask, wouldAct,
           let restriction = NativeRuleMatcher.untargetedRestriction(records, query: query, context: context, at: now) {
            return NativeRuleWhy(kind: .rule, action: query.action, handsOff: false, rule: .init(restriction))
        }
        if wouldAct { return NativeRuleWhy(kind: .unsaved, action: query.action, handsOff: handsOff) }
        if let allow = NativeRuleMatcher.unmatchedAllow(records, query: query, context: context, at: now, honoringLimitedUse: honoringLimitedUse),
           let target = allow.target {
            let differed = target.kind == .commandPrefix ? nil
                : query.parts.first { !allow.matches($0, at: now) }?.targets.first { $0.kind == target.kind }?.value
            return NativeRuleWhy(kind: .outside, action: query.action, handsOff: handsOff, choice: choice(for: query.action),
                                 source: source(for: query.action), rule: .init(allow), subject: differed)
        }
        return NativeRuleWhy(kind: .unsaved, action: query.action, handsOff: handsOff, choice: choice(for: query.action), source: source(for: query.action))
    }

    func judge(_ action: NativeActionClass, command: String? = nil, honoringLimitedUse: Bool)
        -> (decision: NativeRuleDecision, authorizedBy: [String], why: NativeRuleWhy?) {
        let query = query(for: action, command: command)
        let resolved = resolve(query, honoringLimitedUse: honoringLimitedUse)
        return (resolved.decision, resolved.authorizedBy,
                why(query, decision: resolved.decision, resolution: resolved.resolution, honoringLimitedUse: honoringLimitedUse))
    }

    func explain(for action: NativeActionClass, honoringLimitedUse: Bool = false) -> NativeRuleWhy? {
        let query = query(for: action)
        let resolved = resolve(query, honoringLimitedUse: honoringLimitedUse)
        return why(query, decision: resolved.decision, resolution: resolved.resolution, honoringLimitedUse: honoringLimitedUse)
    }

    func explain(forCommand command: String, honoringLimitedUse: Bool = false) -> NativeRuleWhy? {
        let query = query(for: .commands, command: command)
        let resolved = resolve(query, honoringLimitedUse: honoringLimitedUse)
        return why(query, decision: resolved.decision, resolution: resolved.resolution, honoringLimitedUse: honoringLimitedUse)
    }
}
