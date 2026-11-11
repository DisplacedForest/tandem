import Foundation

final class RuleOfferSession {
    var whys: [String: NativeRuleWhy] = [:]
    var candidates: [UUID: [NativeActionClass]] = [:]
}

extension ChatStore {
    var ruleOfferStore: RuleOfferStore? {
        (repository as? LocalChatRepository).map { RuleOfferStore(database: $0.database) }
    }

    static func ruleOfferKey(turn: NativeConversationTurn, request: String) -> String {
        turn.id.uuidString.lowercased() + ":" + request
    }

    nonisolated static func offerWhy(for activity: NativeToolActivity, definitions: [NativeToolDefinition], rules: NativeRuleSource,
                                     conversationID: String, typed: NativeTypedWords) -> NativeRuleWhy? {
        guard let definition = definitions.first(where: { $0.name == activity.name && $0.id == activity.toolID }), definition.governed,
              let data = activity.request.data(using: .utf8), let arguments = try? NativeJSONValue.piRead(data).piObject,
              definition.proposesFor?(arguments) != true,
              let action = definition.actionClass(for: arguments) else { return nil }
        let resolver = rules.resolver(for: conversationID, requestText: typed.said, typed: typed)
        if let ruleWhy = definition.ruleWhy { return ruleWhy(arguments, resolver) }
        var command: String?
        if case .string(let value)? = arguments["command"], definition.id == NativeCommandTools.toolID { command = value }
        let scoped = resolver.tool(definition.id, subjects: definition.ruleSubjects?(arguments) ?? [])
        return scoped.judge(action, command: action == .commands ? command : nil, honoringLimitedUse: scoped.durable).why
    }

    func noteRuleOfferWhy(_ activity: NativeToolActivity, turn: NativeConversationTurn, definitions: [NativeToolDefinition], typed: NativeTypedWords) {
        let key = Self.ruleOfferKey(turn: turn, request: activity.id)
        ruleOfferSession.whys[key] = Self.offerWhy(for: activity, definitions: definitions, rules: nativeRuleSource,
                                                    conversationID: turn.conversationID, typed: typed)
    }

    func recordRuleOfferDecision(_ decision: NativeCardChoiceKind, request: NativeToolConfirmationRequest?, turn: NativeConversationTurn, chosen: Bool) {
        guard let request else { return }
        let why = ruleOfferSession.whys.removeValue(forKey: Self.ruleOfferKey(turn: turn, request: request.id))
        guard chosen, let why, let store = ruleOfferStore,
              (try? store.record(RuleOffer.event(decision, why: why), conversationID: turn.conversationID, action: why.action)) == true else { return }
        var candidates = ruleOfferSession.candidates[turn.id] ?? []
        if !candidates.contains(why.action) { candidates.append(why.action) }
        ruleOfferSession.candidates[turn.id] = candidates
    }

    func forgetRuleOfferCandidates(_ turn: NativeConversationTurn) {
        ruleOfferSession.candidates[turn.id] = nil
    }

    func ruleOfferStillAsks(_ action: NativeActionClass, conversationID: String) -> Bool {
        RuleOffer.stillAsks(action, global: nativeRules, chat: conversationRules(for: conversationID))
    }

    func ruleOfferWaiting(in conversationID: String) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return false }
        return conversation.messages.flatMap(\.displayBlocks).contains { block in
            if case .ruleOffer(let offer) = block { return offer.state == .waiting && offer.action != nil }
            return false
        }
    }

    func offerToStopAsking(after turn: NativeConversationTurn) {
        guard let candidates = ruleOfferSession.candidates.removeValue(forKey: turn.id), let store = ruleOfferStore,
              !ruleOfferWaiting(in: turn.conversationID) else { return }
        for action in NativeActionClass.configurable where candidates.contains(action) {
            guard ruleOfferStillAsks(action, conversationID: turn.conversationID),
                  let state = try? store.state(conversationID: turn.conversationID, action: action),
                  !state.answered, state.approvals >= RuleOffer.approvalsBeforeOffer,
                  (try? store.turnedOff(action)) == false else { continue }
            attachDisplayBlock(.ruleOffer(NativeRuleOffer(action: action)), turn: turn)
            return
        }
    }

    func answerRuleOffer(_ answer: RuleOfferAnswer, messageID: UUID, blockID: String, config: ConfigStore) {
        answerRuleOffer(answer, messageID: messageID, blockID: blockID) { config.applyRule(.act, for: $0, store: self) }
    }

    func answerRuleOffer(_ answer: RuleOfferAnswer, messageID: UUID, blockID: String, everywhere: (NativeActionClass) -> Bool) {
        guard let conversation = conversations.first(where: { $0.messages.contains { $0.id == messageID } }),
              let message = conversation.messages.first(where: { $0.id == messageID }),
              case .ruleOffer(var offer)? = message.displayBlocks.first(where: { $0.id == blockID }),
              offer.state == .waiting, let action = offer.action else { return }
        let conversationID = conversation.id
        let store = ruleOfferStore
        func close(_ state: NativeRuleOffer.State) {
            offer.state = state
            offer.failed = false
            try? store?.record(.answered, conversationID: conversationID, action: action)
            if answer == .neverOffer { try? store?.turnOff(action) }
            updateRuleOffer(offer, messageID: messageID)
        }
        switch answer {
        case .decline, .neverOffer:
            close(.closed)
        case .allow, .allowEverywhere:
            let retrying = offer.failed && answer == .allowEverywhere && nativeRules.choice(for: action) == .act
            guard retrying || ruleOfferStillAsks(action, conversationID: conversationID) else { close(.closed); return }
            let saved = answer == .allow
                ? addRuleRecord(RuleOffer.record(action, conversationID: conversationID)) != nil
                : everywhere(action)
            guard saved else {
                offer.failed = true
                updateRuleOffer(offer, messageID: messageID)
                return
            }
            close(answer == .allow ? .allowedHere : .allowedEverywhere)
        }
    }

    func updateRuleOffer(_ offer: NativeRuleOffer, messageID: UUID) {
        let block = NativeDisplayBlock.ruleOffer(offer)
        let stored = try? (repository as? LocalChatRepository)?.replaceDisplayBlock(block, messageID: messageID)
        guard let ci = conversations.firstIndex(where: { $0.messages.contains { $0.id == messageID } }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        if let stored {
            conversations[ci].messages[mi].displayBlocks = stored
        } else if let index = conversations[ci].messages[mi].displayBlocks.firstIndex(where: { $0.id == block.id }) {
            conversations[ci].messages[mi].displayBlocks[index] = block
        }
    }

    func removeRuleOffers(conversationID: String) {
        try? ruleOfferStore?.remove(conversationID: conversationID)
    }
}
