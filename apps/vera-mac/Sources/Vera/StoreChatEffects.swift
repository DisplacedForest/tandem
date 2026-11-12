import Foundation

extension ChatStore {
    func chatEffectHook(for turn: NativeConversationTurn, definitions: [NativeToolDefinition], typed: NativeTypedWords) -> NativeChatEffectHook? {
        guard let local = repository as? LocalChatRepository, let attempt = turn.attempt else { return nil }
        let ledger = NativeChatEffectLedger(
            ledger: NativeEffectLedgerStore(database: local.database, now: chatEffectClock), rules: nativeRuleSource,
            grants: nativeGrantSource, records: nativeRuleRecordStore, conversationID: turn.conversationID,
            turnID: turn.id.uuidString, attempt: attempt.uuidString)
        var hook = NativeChatEffectHook(
            revisions: { ledger.revisions() },
            propose: { await ledger.propose($0) },
            admit: { await ledger.admit($0, decision: $1, answer: $2) },
            decline: { await ledger.decline($0, answer: $1) },
            confirm: { [weak self] activity, digest in
                guard let self else { return NativeCardAnswer(kind: .decline, byPerson: false) }
                let subject = ChatStore.cardSubject(for: activity, definitions: definitions)
                await self.noteRuleOfferWhy(activity, turn: turn, definitions: definitions, typed: typed)
                return await self.awaitTurnAnswer(activity, turn: turn, subject: subject, digest: digest)
            },
            answered: { [weak self] activity, answer in
                await self?.commitTurnAnswer(activity, answer: answer, turn: turn)
            },
            settle: { await ledger.settle($0, $1) })
        hook.staleAnswers = chatStaleAnswers
        return hook
    }
}
