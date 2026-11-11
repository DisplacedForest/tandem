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
                                     records: NativeRuleRecordStore?, grants: [FolderGrant], conversationID: String,
                                     typed: NativeTypedWords) -> NativeRuleWhy? {
        guard let definition = definitions.first(where: { $0.name == activity.name && $0.id == activity.toolID }),
              definition.governed, !definition.alwaysAsks,
              let data = activity.request.data(using: .utf8), let arguments = try? NativeJSONValue.piRead(data).piObject,
              definition.proposesFor?(arguments) != true,
              let action = definition.actionClass(for: arguments) else { return nil }
        if definition.id == NativeCommandTools.toolID {
            guard case .string(let command)? = arguments["command"] else { return nil }
            let closures = commandLive(rules, store: records, conversationID: conversationID, requestText: typed.said, typed: typed)
            return NativeCommandTools.assess(command: command, directory: arguments.folderString("directory"), grants: grants, fallback: .handOff,
                                             live: closures.live, liveTargets: closures.liveTargets).why
        }
        return toolDecision(rules, store: records, conversationID: conversationID, requestText: typed.said, typed: typed, toolID: definition.id,
                            action: action, subjects: definition.ruleSubjects?(arguments) ?? []).why
    }

    func noteRuleOfferWhy(_ activity: NativeToolActivity, turn: NativeConversationTurn, definitions: [NativeToolDefinition], typed: NativeTypedWords) {
        let key = Self.ruleOfferKey(turn: turn, request: activity.id)
        ruleOfferSession.whys[key] = Self.offerWhy(for: activity, definitions: definitions, rules: nativeRuleSource, records: nativeRuleRecordStore,
                                                    grants: grants(for: turn.conversationID), conversationID: turn.conversationID, typed: typed)
    }

    nonisolated static func ruleOfferCard(_ subject: NativeCardSubject?) -> Bool {
        guard let subject, subject.governed, !subject.alwaysAsks else { return false }
        switch NativeCardChoices.coverage(subject) {
        case .none: return false
        case .commandsOnly: return subject.action != .commands
        case .wholeTool: return NativeCardChoices.remembers(subject)
        case .commandPrefix, .folders, .sendTargets: return true
        }
    }

    func recordRuleOfferDecision(_ decision: NativeCardChoiceKind, request: NativeToolConfirmationRequest?, turn: NativeConversationTurn, chosen: Bool) {
        guard let request else { return }
        let why = ruleOfferSession.whys.removeValue(forKey: Self.ruleOfferKey(turn: turn, request: request.id))
        guard chosen, Self.ruleOfferCard(request.subject), let why, let store = ruleOfferStore,
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
        guard let store = ruleOfferStore else { return }
        func show(_ state: NativeRuleOffer.State, failed: Bool = false) {
            offer.state = state
            offer.failed = failed
            updateRuleOffer(offer, messageID: messageID)
        }
        func settle(_ state: NativeRuleOffer.State) {
            do {
                try store.record(.answered, conversationID: conversationID, action: action)
                if answer == .neverOffer { try store.turnOff(action) }
                show(state)
            } catch {
                show(.waiting, failed: true)
            }
        }
        guard (try? store.state(conversationID: conversationID, action: action).answered) == false else { show(.closed); return }
        switch answer {
        case .decline, .neverOffer:
            settle(.closed)
        case .allow:
            let wanted = RuleOffer.record(action, conversationID: conversationID)
            let held = ruleRecords.contains { RuleOffer.same($0, wanted) }
            guard held || ruleOfferStillAsks(action, conversationID: conversationID) else { settle(.closed); return }
            guard held || addRuleRecord(wanted) != nil else { show(.waiting, failed: true); return }
            settle(.allowedHere)
        case .allowEverywhere:
            let applied = nativeRules.choice(for: action) == .act
            guard offer.failed && applied || ruleOfferStillAsks(action, conversationID: conversationID) else { settle(.closed); return }
            guard everywhere(action) else { show(.waiting, failed: true); return }
            settle(.allowedEverywhere)
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
}
