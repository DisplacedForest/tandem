import Foundation

extension ChatStore {
    func companionTalkOffered(_ turn: NativeConversationTurn) -> Bool {
        let companion = isVeraThread(turn.conversationID)
        let plainChat = turn.mode == .chat
        let ownTurn = turn.companionEvent == nil
        let canAct = nativeTaskTracker != nil && repository is any NativeTaskProjectionRepository
        return companion && plainChat && ownTurn && canAct
    }

    func companionTalkControl(for turn: NativeConversationTurn, supportsTools: Bool, now: Date = Date()) -> CompanionTalkControl? {
        guard companionTalkOffered(turn), supportsTools, turnToolAuthority(for: turn).0.allowsTools else { return nil }
        let entries = companionTalkEntries(now: now)
        guard !entries.isEmpty else { return nil }
        return CompanionTalkControl(entries: entries)
    }

    private func companionTalkReferences() -> [NativeTaskReference] {
        guard let threadID = veraThreadID else { return [] }
        let owned = Set(schedules.filter { $0.owner == .dot }.map(\.id))
        let linked = Set(scheduleRuns.values.flatMap { $0 }.filter { owned.contains($0.scheduleID) }
            .compactMap { $0.taskReferenceID.flatMap(UUID.init(uuidString:)) })
        let stored = ((try? nativeTaskRepository?.taskReferences(conversationID: nil)) ?? nil) ?? nativeTaskReferences
        return stored.filter { $0.origin.conversationID == threadID || linked.contains($0.id) }
    }

    private func companionTalkSnapshot(_ reference: NativeTaskReference) -> (snapshot: NativeTaskSnapshot?, note: String?) {
        let projection = repository as? any NativeTaskProjectionRepository
        let saved = (try? projection?.taskProjection(id: reference.id)) ?? nil
        return (saved?.snapshot ?? reference.snapshot, saved?.connectionNote)
    }

    func companionTalkEntries(now: Date) -> [CompanionTalkEntry] {
        let since = now.timeIntervalSince1970 - CompanionTalkTools.recentWindow
        var drafted: [CompanionTalkEntry] = []
        for reference in companionTalkReferences() {
            guard let entry = companionTalkEntry(reference) else { continue }
            let recent = entry.date >= since
            guard entry.phase.ongoing || recent else { continue }
            drafted.append(entry)
        }
        let ongoing = drafted.filter { $0.phase.ongoing }.sorted { $0.date > $1.date }
        let ended = drafted.filter { !$0.phase.ongoing }.sorted { $0.date > $1.date }
        return Array((ongoing + ended).prefix(CompanionTalkTools.listLimit))
    }

    private func companionTalkEntry(_ reference: NativeTaskReference) -> CompanionTalkEntry? {
        let (snapshot, connectionNote) = companionTalkSnapshot(reference)
        guard let display = try? NativeTaskProjection.display(reference: reference, snapshot: snapshot, connectionNote: connectionNote) else { return nil }
        let card = display.card
        let workerType = reference.createRequest.workerType
        let title = CompanionTalkTools.clipped(card.title, CompanionTalkTools.titleLimit)
        let what = CompanionCurrentWork.words(workerType: workerType, phase: snapshot?.checkpoint.phase, title: title)
        let phase = companionTalkPhase(card.status, state: snapshot?.state)
        var spoken: [String: String] = [:]
        var buttonOnly: [String: String] = [:]
        var question: String?
        var decisionID: String?
        if phase == .waiting, let decision = snapshot?.decision {
            decisionID = decision.id
            let shown = CompanionSavedText.plain(decision.prompt, name: companionName, appWritten: workerType == "companion")
            question = CompanionTalkTools.clipped(shown, CompanionTalkTools.questionLimit)
            for wire in decision.choices where !NativeTaskProjection.carryOnChoices.contains(wire) {
                guard let choiceTitle = NativeTaskCardPresentation.choiceTitle(wire) else { continue }
                let kind = NativeCardChoices.kind(wire: wire)
                let approves = kind?.approves == true
                let saves = kind?.saves == true
                if approves || saves { buttonOnly[choiceTitle] = wire } else { spoken[choiceTitle] = wire }
            }
        }
        let noteText = (snapshot?.checkpoint.note?.text).map { CompanionTalkTools.clipped($0, CompanionTalkTools.noteLimit) }
        let date = snapshot?.updatedAt
            ?? conversations.first { $0.id == reference.origin.conversationID }?.messages.first { $0.id == reference.origin.userMessageID }?
                .createdAt.timeIntervalSince1970
            ?? 0
        return CompanionTalkEntry(referenceID: reference.id, what: what, phase: phase,
                                  why: phase == .couldNotFinish ? companionTalkWhy(reference, snapshot: snapshot) : nil,
                                  note: noteText.flatMap { $0.isEmpty ? nil : $0 }, question: question, decisionID: decisionID,
                                  spoken: spoken, buttonOnly: buttonOnly, canStop: card.canCancel && phase.ongoing, date: date)
    }

    private func companionTalkPhase(_ status: NativeTaskCardPresentation.Status, state: NativeTaskState?) -> CompanionTalkPhase {
        switch status {
        case .preparing: return .starting
        case .queued: return state == .blocked ? .waitingToContinue : .going
        case .working: return .going
        case .stopping: return .stopping
        case .needsInput: return .waiting
        case .completed: return .finished
        case .stopped: return .stopped
        case .failed: return .couldNotFinish
        }
    }

    private func companionTalkWhy(_ reference: NativeTaskReference, snapshot: NativeTaskSnapshot?) -> String? {
        guard let snapshot else { return reference.deliveryState == .rejected ? CompanionTalkCopy.couldNotStart : nil }
        return snapshot.checkpoint.failureReason.flatMap { CompanionTalkCopy.reasons[$0] }
    }

    private func companionTalkLive(_ id: UUID) -> CompanionTalkEntry? {
        guard let reference = ((try? nativeTaskRepository?.taskReference(id: id)) ?? nil) else { return nil }
        return companionTalkEntry(reference)
    }

    private func companionTalkEarlier(_ turn: NativeConversationTurn) -> String? {
        guard let end = turn.history.firstIndex(where: { $0.id == turn.userMessageID }) else { return nil }
        guard let reply = turn.history[..<end].last(where: { $0.role == "assistant" }) else { return nil }
        let text = CompanionTalkTools.clipped(reply.text, CompanionTalkTools.earlierLimit)
        return text.isEmpty ? nil : text
    }

    func companionTalkTools(_ control: CompanionTalkControl, turn: NativeConversationTurn, typed: NativeTypedWords,
                            answerer: @escaping NativeInstructionAnswerer, timeout: Duration) -> [NativeToolDefinition] {
        let typedHere = CompanionTalkTools.typed(turn, typed)
        let said = typed.said
        let earlier = companionTalkEarlier(turn)
        let ledger = CompanionTalkLedger()
        let entries = control.entries
        let toolTimeout = timeout + .seconds(CompanionTalkTools.extraSeconds)
        let stop = NativeToolDefinition(id: CompanionTalkTools.toolID, name: CompanionTalkTools.stopName, title: CompanionTalkCopy.stopTitle,
            description: CompanionTalkCopy.stopDescription,
            parameters: .object(["type": .string("object"), "additionalProperties": .bool(false),
                                 "required": .array([.string("item")]),
                                 "properties": .object(["item": .object(["type": .string("string"), "minLength": .number(1),
                                                                         "maxLength": .number(Double(CompanionTalkTools.handleLimit))])])]),
            confirmation: .none, timeout: toolTimeout, effect: .read, isAvailable: { true },
            execute: { [weak self] arguments in
                guard Set(arguments.keys) == ["item"], let handle = CompanionTalkTools.text(arguments, "item", limit: CompanionTalkTools.handleLimit) else {
                    return CompanionTalkTools.refusal(CompanionTalkCopy.invalid)
                }
                let key = "stop|" + handle
                if let earlierResult = ledger.recall(key) { return earlierResult }
                guard typedHere else { return CompanionTalkTools.refusal(CompanionTalkCopy.notTyped) }
                guard CompanionTalkTools.firstInReply() else { return CompanionTalkTools.refusal(CompanionTalkCopy.notFirst) }
                guard let entry = control.entry(handle) else { return CompanionTalkTools.refusal(CompanionTalkCopy.unknownItem) }
                guard let self else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                let live = await MainActor.run { () -> (owned: Bool, entry: CompanionTalkEntry?) in
                    (self.turnOwned(turn), self.companionTalkLive(entry.referenceID))
                }
                guard live.owned else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                guard let current = live.entry, current.canStop else {
                    return CompanionTalkTools.refusal(live.entry?.phase == .stopping ? CompanionTalkCopy.alreadyStopping : CompanionTalkCopy.notGoing)
                }
                let about = CompanionTalkTools.about(stop: entry, among: entries, earlier: earlier)
                let cleared = await NativeInstructionCheck.bounded(timeout) { await answerer(said, about) }
                try Task.checkCancellation()
                guard cleared else {
                    return CompanionTalkTools.refusal(CompanionTalkCopy.unclear, candidates: entries.filter(\.canStop))
                }
                guard await MainActor.run(body: { self.turnOwned(turn) }) else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                let outcome = await self.companionTalkStop(entry.referenceID)
                if case .object(let fields) = outcome, fields["changed"] == .bool(true) { ledger.keep(key, outcome) }
                return outcome
            })
        let answer = NativeToolDefinition(id: CompanionTalkTools.toolID, name: CompanionTalkTools.answerName, title: CompanionTalkCopy.answerTitle,
            description: CompanionTalkCopy.answerDescription,
            parameters: .object(["type": .string("object"), "additionalProperties": .bool(false),
                                 "required": .array([.string("item"), .string("answer")]),
                                 "properties": .object([
                                    "item": .object(["type": .string("string"), "minLength": .number(1),
                                                     "maxLength": .number(Double(CompanionTalkTools.handleLimit))]),
                                    "answer": .object(["type": .string("string"), "minLength": .number(1),
                                                       "maxLength": .number(Double(CompanionTalkTools.answerLimit))]),
                                 ])]),
            confirmation: .none, timeout: toolTimeout, effect: .read, isAvailable: { true },
            execute: { [weak self] arguments in
                guard Set(arguments.keys) == ["item", "answer"],
                      let handle = CompanionTalkTools.text(arguments, "item", limit: CompanionTalkTools.handleLimit),
                      let title = CompanionTalkTools.text(arguments, "answer", limit: CompanionTalkTools.answerLimit) else {
                    return CompanionTalkTools.refusal(CompanionTalkCopy.invalid)
                }
                let key = "answer|" + handle + "|" + title.lowercased()
                if let earlierResult = ledger.recall(key) { return earlierResult }
                guard typedHere else { return CompanionTalkTools.refusal(CompanionTalkCopy.notTyped) }
                guard CompanionTalkTools.firstInReply() else { return CompanionTalkTools.refusal(CompanionTalkCopy.notFirst) }
                guard let entry = control.entry(handle) else { return CompanionTalkTools.refusal(CompanionTalkCopy.unknownItem) }
                guard let decisionID = entry.decisionID else { return CompanionTalkTools.refusal(CompanionTalkCopy.notWaiting) }
                let matches = { (offered: [String: String]) in offered.first { $0.key.lowercased() == title.lowercased() } }
                if matches(entry.buttonOnly) != nil { return CompanionTalkTools.refusal(CompanionTalkCopy.needsButton) }
                guard let picked = matches(entry.spoken) else { return CompanionTalkTools.refusal(CompanionTalkCopy.notOffered) }
                guard let self else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                let live = await MainActor.run { () -> (owned: Bool, entry: CompanionTalkEntry?) in
                    (self.turnOwned(turn), self.companionTalkLive(entry.referenceID))
                }
                guard live.owned else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                guard let current = live.entry, current.decisionID == decisionID, current.spoken[picked.key] == picked.value else {
                    return CompanionTalkTools.refusal(CompanionTalkCopy.staleQuestion)
                }
                let about = CompanionTalkTools.about(answer: picked.key, for: entry, among: entries, earlier: earlier)
                let cleared = await NativeInstructionCheck.bounded(timeout) { await answerer(said, about) }
                try Task.checkCancellation()
                guard cleared else {
                    return CompanionTalkTools.refusal(CompanionTalkCopy.unclear, candidates: entries.filter { $0.decisionID != nil })
                }
                guard await MainActor.run(body: { self.turnOwned(turn) }) else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                let outcome = await self.companionTalkAnswer(entry.referenceID, choice: picked.value, decisionID: decisionID)
                if case .object(let fields) = outcome, fields["changed"] == .bool(true) { ledger.keep(key, outcome) }
                return outcome
            })
        return [stop, answer]
    }

    func companionTalkStop(_ id: UUID) async -> NativeJSONValue {
        guard let tracker = nativeTaskTracker, let projection = repository as? any NativeTaskProjectionRepository else {
            return CompanionTalkTools.refusal(CompanionTalkCopy.couldNotStop)
        }
        if ((try? projection.taskProjection(id: id)) ?? nil) == nil { _ = try? projection.projectTask(id: id, snapshot: nil, cursor: 0, connectionNote: nil, lease: nil, generation: nil) }
        await tracker.cancel(id)
        guard let reference = (try? projection.taskReference(id: id)) ?? nil, reference.cancelRequested else {
            return CompanionTalkTools.refusal(CompanionTalkCopy.couldNotStop)
        }
        reloadNativeTaskReferences()
        let snapshot = ((try? projection.taskProjection(id: id)) ?? nil)?.snapshot ?? reference.snapshot
        let settled = snapshot?.state == .canceled
        let effects = snapshot?.checkpoint.effects ?? []
        let done = effects.filter { $0.outcome.hasPrefix("done") }.map { CompanionTalkTools.clipped($0.title, CompanionTalkTools.noteLimit) }
        var unsure = effects.filter { $0.outcome == "failed" || $0.outcome == "unconfirmed" }.map(\.title)
        for title in snapshot?.checkpoint.unconfirmedEffects ?? [] where !unsure.contains(title) { unsure.append(title) }
        var sentence = settled ? CompanionTalkCopy.stopped : CompanionTalkCopy.stopping
        var fields: [String: NativeJSONValue] = ["changed": .bool(true)]
        if !done.isEmpty {
            sentence += CompanionTalkCopy.alreadyDone
            fields["already_done"] = .array(done.map { .string($0) })
        }
        if !unsure.isEmpty {
            sentence += CompanionTalkCopy.maybeDone
            fields["may_have_happened"] = .array(unsure.map { .string(CompanionTalkTools.clipped($0, CompanionTalkTools.noteLimit)) })
        }
        fields["result"] = .string(sentence)
        return .object(fields)
    }

    func companionTalkAnswer(_ id: UUID, choice: String, decisionID: String) async -> NativeJSONValue {
        guard let tracker = nativeTaskTracker else { return CompanionTalkTools.refusal(CompanionTalkCopy.couldNotAnswer) }
        let saved = await tracker.decide(id, choice: choice, expecting: decisionID)
        guard saved else {
            let current = companionTalkLive(id)
            return CompanionTalkTools.refusal(current?.decisionID == decisionID ? CompanionTalkCopy.couldNotAnswer : CompanionTalkCopy.staleQuestion)
        }
        reloadNativeTaskReferences()
        return .object(["result": .string(CompanionTalkCopy.answered), "changed": .bool(true)])
    }
}
