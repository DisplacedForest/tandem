import Foundation

enum LeftToYouAnswer: Int {
    case kept = 1
    case askFirst = 2
}

struct LeftToYouOfferState: Equatable {
    var answer: LeftToYouAnswer?
    var failed = false
    var applies = false

    var shown: Bool { answer != nil || applies || failed }
}

extension ChatStore {
    func loadLeftToYouAnswers() {
        guard let store = ruleOfferStore, let saved = try? store.leftAnswers() else { return }
        leftToYouAnswers = saved.compactMapValues(LeftToYouAnswer.init(rawValue:))
    }

    func leftToYouOffer(cardID: String) -> NativeLeftToYouOffer? {
        guard let reference = nativeTaskReferences.first(where: { $0.id.uuidString == cardID }),
              reference.createRequest.workerType == "companion",
              let snapshot = reference.snapshot, snapshot.workerType == "companion", snapshot.state == .completed,
              let result = snapshot.result, result.kind == "companion_report", let offer = result.offer,
              let action = NativeActionClass(rawValue: offer.action), NativeActionClass.configurable.contains(action),
              offer.source == NativeRuleWhy.Source.settings.rawValue || offer.source == NativeRuleWhy.Source.chat.rawValue,
              !offer.step.isEmpty else { return nil }
        return offer
    }

    func leftToYouStillApplies(_ offer: NativeLeftToYouOffer) -> Bool {
        guard let action = NativeActionClass(rawValue: offer.action), NativeActionClass.configurable.contains(action) else { return false }
        switch NativeRuleWhy.Source(rawValue: offer.source) {
        case .settings?:
            return nativeRules.choice(for: action) == .handOff
        case .chat?:
            guard let threadID = veraThreadID else { return false }
            return conversationRules(for: threadID).choices[action] == .handOff
        case nil:
            return false
        }
    }

    func leftToYouRetry(_ offer: NativeLeftToYouOffer, cardID: String, answer: LeftToYouAnswer) -> Bool {
        guard answer == .askFirst, leftToYouFailed.contains(cardID), let action = NativeActionClass(rawValue: offer.action) else { return false }
        switch NativeRuleWhy.Source(rawValue: offer.source) {
        case .settings?: return nativeRules.choice(for: action) == .ask
        case .chat?: return veraThreadID.map { conversationRules(for: $0).choices[action] != .handOff } ?? false
        case nil: return false
        }
    }

    func leftToYouState(_ card: NativeTaskCardPresentation) -> LeftToYouOfferState? {
        guard card.offer != nil, let offer = leftToYouOffer(cardID: card.id) else { return nil }
        return LeftToYouOfferState(answer: leftToYouAnswers[card.id], failed: leftToYouFailed.contains(card.id),
                                   applies: leftToYouStillApplies(offer))
    }

    func answerLeftToYouOffer(cardID: String, answer: LeftToYouAnswer, config: ConfigStore) {
        answerLeftToYouOffer(cardID: cardID, answer: answer) { config.applyRule(.ask, for: $0, store: self) }
    }

    func answerLeftToYouOffer(cardID: String, answer: LeftToYouAnswer, askEverywhere: (NativeActionClass) -> Bool) {
        guard let offer = leftToYouOffer(cardID: cardID), let action = NativeActionClass(rawValue: offer.action),
              leftToYouAnswers[cardID] == nil, let store = ruleOfferStore,
              (try? store.leftAnswer(reportID: cardID, action: action)) == 0,
              leftToYouStillApplies(offer) || leftToYouRetry(offer, cardID: cardID, answer: answer) else { return }
        if answer == .askFirst {
            switch NativeRuleWhy.Source(rawValue: offer.source) {
            case .settings?:
                guard askEverywhere(action) else {
                    leftToYouFailed.insert(cardID)
                    return
                }
            case .chat?:
                guard let threadID = veraThreadID else { leftToYouFailed.insert(cardID); return }
                tightenConversationRule(.ask, for: action, conversationID: threadID)
                guard conversationRules(for: threadID).choices[action] != .handOff else {
                    leftToYouFailed.insert(cardID)
                    return
                }
            case nil:
                return
            }
        }
        do {
            try store.setLeftAnswer(answer.rawValue, reportID: cardID, action: action)
        } catch {
            leftToYouFailed.insert(cardID)
            return
        }
        leftToYouFailed.remove(cardID)
        leftToYouAnswers[cardID] = answer
    }
}
