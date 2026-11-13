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
        return stored.filter { ($0.origin.conversationID == threadID || linked.contains($0.id)) && $0.replacedBy == nil }
    }

    private func companionTalkSnapshot(_ reference: NativeTaskReference) -> (snapshot: NativeTaskSnapshot?, note: String?) {
        let projection = repository as? any NativeTaskProjectionRepository
        let saved = (try? projection?.taskProjection(id: reference.id)) ?? nil
        return (CompanionTalkTools.newest(saved?.snapshot, reference.snapshot), saved?.connectionNote)
    }

    func dropComposerCapture(_ messageID: UUID) {
        for turn in conversationTurns where turn.assistantMessageID == messageID { composerSentTurns[turn.id] = nil }
    }

    func companionTalkCapture() -> CompanionTalkCapture {
        var known: Set<UUID> = []
        var decisions: [UUID: String] = [:]
        for reference in companionTalkReferences() {
            known.insert(reference.id)
            guard let entry = companionTalkEntry(reference), entry.phase == .waiting, let decisionID = entry.decisionID else { continue }
            decisions[reference.id] = decisionID
        }
        return CompanionTalkCapture(known: known, decisions: decisions)
    }

    func companionTalkEntries(now: Date) -> [CompanionTalkEntry] {
        let since = now.timeIntervalSince1970 - CompanionTalkTools.recentWindow
        var drafted: [CompanionTalkEntry] = []
        for reference in companionTalkReferences() {
            guard let entry = companionTalkEntry(reference) else { continue }
            let recent = entry.date >= since
            guard entry.phase.ongoing || recent || entry.changePending else { continue }
            drafted.append(entry)
        }
        let ongoing = drafted.filter { $0.phase.ongoing || $0.changePending }.sorted { $0.date > $1.date }
        let ended = drafted.filter { !$0.phase.ongoing && !$0.changePending }.sorted { $0.date > $1.date }
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
        let waitingNote = phase.ongoing ? CompanionHoldCopy.changeWaiting : CompanionHoldCopy.changeResting
        let noteText = reference.pendingChange != nil ? waitingNote
            : (snapshot?.checkpoint.note?.text).map { CompanionTalkTools.clipped($0, CompanionTalkTools.noteLimit) }
        let date = snapshot?.updatedAt
            ?? conversations.first { $0.id == reference.origin.conversationID }?.messages.first { $0.id == reference.origin.userMessageID }?
                .createdAt.timeIntervalSince1970
            ?? 0
        return CompanionTalkEntry(referenceID: reference.id, what: what, phase: phase,
                                  why: phase == .couldNotFinish ? companionTalkWhy(reference, snapshot: snapshot) : nil,
                                  note: noteText.flatMap { $0.isEmpty ? nil : $0 }, question: question, decisionID: decisionID,
                                  spoken: spoken, buttonOnly: buttonOnly, canStop: (card.canCancel && phase.ongoing) || reference.pendingChange != nil, date: date,
                                  canSetAside: card.canSetAside == true && phase.ongoing, canPickUp: card.canPickUp == true,
                                  changePending: reference.pendingChange != nil)
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
        case .setAside: return .setAside
        case .newer: return .newer
        }
    }

    private func companionTalkWhy(_ reference: NativeTaskReference, snapshot: NativeTaskSnapshot?) -> String? {
        guard let snapshot else { return reference.deliveryState == .rejected ? CompanionTalkCopy.couldNotStart : nil }
        return snapshot.checkpoint.failureReason.flatMap { CompanionTalkCopy.reasons[$0] }
    }

    func companionTalkLive(_ id: UUID) -> CompanionTalkEntry? {
        guard let reference = ((try? nativeTaskRepository?.taskReference(id: id)) ?? nil) else { return nil }
        return companionTalkEntry(reference)
    }

    func companionTalkEarlier(_ turn: NativeConversationTurn) -> String? {
        guard let end = turn.history.firstIndex(where: { $0.id == turn.userMessageID }) else { return nil }
        guard let reply = turn.history[..<end].last(where: { $0.role == "assistant" }) else { return nil }
        let text = CompanionTalkTools.clipped(reply.text, CompanionTalkTools.earlierLimit)
        return text.isEmpty ? nil : text
    }

    func companionTalkTools(_ control: CompanionTalkControl, turn: NativeConversationTurn, typed: NativeTypedWords, capture: CompanionTalkCapture?,
                            answerer: @escaping NativeInstructionAnswerer, timeout: Duration) -> [NativeToolDefinition] {
        let typedHere = CompanionTalkTools.typed(turn, typed, captured: capture != nil)
        let known = capture?.known ?? []
        let decisionsAtSend = capture?.decisions ?? [:]
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
                guard known.contains(entry.referenceID) else { return CompanionTalkTools.refusal(CompanionTalkCopy.startedAfter) }
                guard let self else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                let live = await MainActor.run { () -> (owned: Bool, entry: CompanionTalkEntry?) in
                    (self.turnOwned(turn), self.companionTalkLive(entry.referenceID))
                }
                guard live.owned else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                guard let current = live.entry, current.canStop else {
                    return CompanionTalkTools.refusal(CompanionTalkTools.unstoppable(live.entry?.phase))
                }
                guard CompanionTalkTools.checkable(said) else { return CompanionTalkTools.refusal(CompanionTalkCopy.tooLong) }
                let about = CompanionTalkTools.about(stop: entry, among: entries, earlier: earlier)
                let cleared = await NativeInstructionCheck.bounded(timeout) { await answerer(said, about) }
                try Task.checkCancellation()
                guard cleared else { return CompanionTalkTools.refusal(CompanionTalkCopy.unclear) }
                let after = await MainActor.run { () -> (owned: Bool, entry: CompanionTalkEntry?) in
                    (self.turnOwned(turn), self.companionTalkLive(entry.referenceID))
                }
                guard after.owned else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                guard let still = after.entry, still.canStop else {
                    return CompanionTalkTools.refusal(CompanionTalkTools.unstoppable(after.entry?.phase))
                }
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
                guard decisionsAtSend[entry.referenceID] == decisionID else { return CompanionTalkTools.refusal(CompanionTalkCopy.staleQuestion) }
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
                guard CompanionTalkTools.checkable(said) else { return CompanionTalkTools.refusal(CompanionTalkCopy.tooLong) }
                let about = CompanionTalkTools.about(answer: picked.key, for: entry, among: entries, earlier: earlier)
                let cleared = await NativeInstructionCheck.bounded(timeout) { await answerer(said, about) }
                try Task.checkCancellation()
                guard cleared else { return CompanionTalkTools.refusal(CompanionTalkCopy.unclear) }
                guard await MainActor.run(body: { self.turnOwned(turn) }) else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                let outcome = await self.companionTalkAnswer(entry.referenceID, choice: picked.value, decisionID: decisionID)
                if case .object(let fields) = outcome, fields["changed"] == .bool(true) { ledger.keep(key, outcome) }
                return outcome
            })
        let gate = CompanionHoldGate(control: control, turn: turn, typedHere: typedHere, known: known, said: said, earlier: earlier,
                                     answerer: answerer, timeout: timeout, toolTimeout: toolTimeout, ledger: ledger)
        return [stop, answer] + companionHoldTools(gate)
    }

    func companionTalkStop(_ id: UUID) async -> NativeJSONValue {
        guard let tracker = nativeTaskTracker, let projection = repository as? any NativeTaskProjectionRepository else {
            return CompanionTalkTools.refusal(CompanionTalkCopy.couldNotStop)
        }
        if (try? projection.withdrawTaskChange(id: id)) == true {
            reloadNativeTaskReferences()
            return .object(["result": .string(CompanionHoldCopy.changeWithdrawn), "changed": .bool(true)])
        }
        if ((try? projection.taskProjection(id: id)) ?? nil) == nil { _ = try? projection.projectTask(id: id, snapshot: nil, cursor: 0, connectionNote: nil, lease: nil, generation: nil) }
        await tracker.cancel(id)
        guard let reference = (try? projection.taskReference(id: id)) ?? nil, reference.cancelRequested else {
            return CompanionTalkTools.refusal(CompanionTalkCopy.couldNotStop)
        }
        reloadNativeTaskReferences()
        let projected = ((try? projection.taskProjection(id: id)) ?? nil)?.snapshot
        let snapshot = CompanionTalkTools.newest(projected, reference.snapshot)
        let settled = snapshot?.state == .canceled
        let endedFirst = snapshot.map { $0.state.isTerminal && $0.state != .canceled } ?? false
        if endedFirst {
            return CompanionTalkTools.refusal(snapshot?.state == .completed ? CompanionTalkCopy.alreadyFinished : CompanionTalkCopy.alreadyEnded)
        }
        var (doneTitles, unsure) = CompanionTalkTools.effects(CompanionTalkTools.oldestFirst(projected, reference.snapshot))
        let saved = [projected, reference.snapshot].compactMap { $0?.checkpoint.effects }.max { $0.count < $1.count } ?? []
        let unsaved = companionTalkUnsaved(reference, notes: saved)
        for title in unsaved.done where !doneTitles.contains(title) { doneTitles.append(title) }
        for title in unsaved.unsure where !unsure.contains(title) { unsure.append(title) }
        let done = doneTitles.map { CompanionTalkTools.clipped($0, CompanionTalkTools.noteLimit) }
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

    private func companionTalkUnsaved(_ reference: NativeTaskReference, notes: [NativeCompanionEffectNote]) -> (done: [String], unsure: [String]) {
        guard let remote = reference.remoteTaskID, let local = repository as? LocalChatRepository,
              let records = try? NativeEffectLedgerStore(database: local.database).records(taskID: remote) else { return ([], []) }
        return CompanionTalkTools.unsaved(records, notes: notes)
    }

    func companionTalkAnswer(_ id: UUID, choice: String, decisionID: String) async -> NativeJSONValue {
        guard let tracker = nativeTaskTracker else { return CompanionTalkTools.refusal(CompanionTalkCopy.couldNotAnswer) }
        let delivery = await tracker.answer(id, choice: choice, expecting: decisionID)
        reloadNativeTaskReferences()
        guard let delivery else {
            let current = companionTalkLive(id)
            return CompanionTalkTools.refusal(current?.decisionID == decisionID ? CompanionTalkCopy.couldNotAnswer : CompanionTalkCopy.staleQuestion)
        }
        let stopped = ((try? nativeTaskRepository?.taskReference(id: id)) ?? nil)?.cancelRequested == true
        if stopped && delivery != .sent { return CompanionTalkTools.refusal(CompanionTalkCopy.stoppedBeforeAnswer) }
        if stopped { return .object(["result": .string(CompanionTalkCopy.stoppedAfterAnswer), "changed": .bool(true)]) }
        if delivery == .dropped { return CompanionTalkTools.refusal(CompanionTalkCopy.staleQuestion) }
        let ends = choice == CompanionTalkTools.endingChoice
        return .object(["result": .string(ends ? CompanionTalkCopy.answeredAndEnds : CompanionTalkCopy.answered), "changed": .bool(true)])
    }
}
