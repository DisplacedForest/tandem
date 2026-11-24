import Foundation

final class RuleOfferSession {
    var whys: [String: NativeRuleWhy] = [:]
    var candidates: [UUID: [RuleOfferSubject]] = [:]
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
            let directory = arguments.folderString("directory")
            if NativeCommandClassifier.unplain(command, grants: grants, directory: directory) != nil { return nil }
            let closures = commandLive(rules, store: records, conversationID: conversationID, requestText: typed.said, typed: typed)
            return NativeCommandTools.assess(command: command, directory: directory, grants: grants, fallback: .handOff,
                                             live: closures.live, liveTargets: closures.liveTargets).why
        }
        let subjects = definition.ruleSubjects?(arguments) ?? []
        if action == .networkSends,
           subjects.flatMap({ $0 }).contains(where: { ($0.kind == .recipient || $0.kind == .service) && !typed.names($0) }) { return nil }
        return toolDecision(rules, store: records, conversationID: conversationID, requestText: typed.said, typed: typed, toolID: definition.id,
                            action: action, subjects: subjects).why
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
        case .commandsOnly: return subject.action == .riskyCommands
        case .wholeTool: return NativeCardChoices.remembers(subject)
        case .commandPrefix, .folders, .sendTargets: return true
        }
    }

    nonisolated static func ruleOfferSubject(_ subject: NativeCardSubject?, action: NativeActionClass) -> RuleOfferSubject? {
        guard action == .serviceChanges else { return .action(action) }
        guard let subject, let service = subject.service, service.fits else { return nil }
        return .tool(id: subject.toolID, service: service)
    }

    func recordRuleOfferDecision(_ decision: NativeCardChoiceKind, request: NativeToolConfirmationRequest?, turn: NativeConversationTurn, chosen: Bool) {
        guard let request else { return }
        let why = ruleOfferSession.whys.removeValue(forKey: Self.ruleOfferKey(turn: turn, request: request.id))
        guard chosen, Self.ruleOfferCard(request.subject), let why, let store = ruleOfferStore,
              let offered = Self.ruleOfferSubject(request.subject, action: why.action),
              (try? store.record(RuleOffer.event(decision, why: why), conversationID: turn.conversationID, key: offered.key)) == true else { return }
        var candidates = ruleOfferSession.candidates[turn.id] ?? []
        if !candidates.contains(where: { $0.key == offered.key }) { candidates.append(offered) }
        ruleOfferSession.candidates[turn.id] = candidates
    }

    func forgetRuleOfferCandidates(_ turn: NativeConversationTurn) {
        ruleOfferSession.candidates[turn.id] = nil
    }

    func ruleOfferStillAsks(_ action: NativeActionClass, conversationID: String) -> Bool {
        RuleOffer.stillAsks(action, global: nativeRules, chat: conversationRules(for: conversationID))
    }

    func ruleOfferStillAsks(_ subject: RuleOfferSubject, conversationID: String) -> Bool {
        ruleOfferStillAsks(subject.action, conversationID: conversationID)
            && !RuleOffer.settled(subject, records: ruleRecords, conversationID: conversationID)
    }

    func ruleOfferWaiting(in conversationID: String) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return false }
        return conversation.messages.flatMap(\.displayBlocks).contains { block in
            if case .ruleOffer(let offer) = block { return offer.open }
            return false
        }
    }

    func offerToStopAsking(after turn: NativeConversationTurn) {
        guard let candidates = ruleOfferSession.candidates.removeValue(forKey: turn.id), let store = ruleOfferStore,
              !ruleOfferWaiting(in: turn.conversationID) else { return }
        let ordered = NativeActionClass.configurable.flatMap { action in candidates.filter { $0.action == action } }
        for subject in ordered {
            guard ruleOfferStillAsks(subject, conversationID: turn.conversationID),
                  let state = try? store.state(conversationID: turn.conversationID, key: subject.key),
                  !state.answered, state.approvals >= RuleOffer.approvalsBeforeOffer,
                  (try? store.turnedOff(subject.key)) == false else { continue }
            attachDisplayBlock(.ruleOffer(NativeRuleOffer(subject: subject)), turn: turn)
            return
        }
    }

    func answerRuleOffer(_ answer: RuleOfferAnswer, messageID: UUID, blockID: String, config: ConfigStore, confirmed: ServiceAllowConfirmed? = nil) {
        answerRuleOffer(answer, messageID: messageID, blockID: blockID, confirmed: confirmed) { config.applyRule(.act, for: $0, store: self) }
    }

    func answerRuleOffer(_ answer: RuleOfferAnswer, messageID: UUID, blockID: String, confirmed: ServiceAllowConfirmed? = nil, everywhere: (NativeActionClass) -> Bool) {
        guard let conversation = conversations.first(where: { $0.messages.contains { $0.id == messageID } }),
              let message = conversation.messages.first(where: { $0.id == messageID }),
              case .ruleOffer(var offer)? = message.displayBlocks.first(where: { $0.id == blockID }),
              offer.state == .waiting, let subject = offer.subject else { return }
        let action = subject.action
        let conversationID = conversation.id
        guard let store = ruleOfferStore else { return }
        func show(_ state: NativeRuleOffer.State, failed: Bool = false) {
            offer.state = state
            offer.failed = failed
            updateRuleOffer(offer, messageID: messageID)
        }
        func settle(_ state: NativeRuleOffer.State) {
            do {
                try store.settle(conversationID: conversationID, key: subject.key, everyChat: answer == .neverOffer)
                show(state)
            } catch {
                show(.waiting, failed: true)
            }
        }
        guard offer.open else { show(.closed); return }
        guard (try? store.state(conversationID: conversationID, key: subject.key).answered) == false else { show(.closed); return }
        let wanted = RuleOffer.record(subject, conversationID: conversationID)
        let held = ruleRecords.first { RuleOffer.same($0, wanted) }
        func withdrawn() -> Bool {
            guard let held, !revokeRuleRecord(id: held.id) else { return true }
            show(.waiting, failed: true)
            return false
        }
        switch answer {
        case .decline, .neverOffer:
            guard withdrawn() else { return }
            settle(.closed)
        case .allow:
            guard held != nil || ruleOfferStillAsks(subject, conversationID: conversationID) else { settle(.closed); return }
            guard held != nil || addRuleRecord(wanted) != nil else { show(.waiting, failed: true); return }
            settle(.allowedHere)
        case .allowEverywhere:
            if let service = subject.service {
                guard ServiceAllowConfirm.tool(service).accepts(confirmed) else { return }
                let wide = RuleOffer.record(subject, conversationID: conversationID, everywhere: true)
                let kept = ruleRecords.contains { RuleOffer.same($0, wide) }
                guard kept || held != nil || ruleOfferStillAsks(subject, conversationID: conversationID) else { settle(.closed); return }
                guard kept || addRuleRecord(wide) != nil else { show(.waiting, failed: true); return }
                guard withdrawn() else { return }
                settle(.allowedEverywhere)
                return
            }
            guard withdrawn() else { return }
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
