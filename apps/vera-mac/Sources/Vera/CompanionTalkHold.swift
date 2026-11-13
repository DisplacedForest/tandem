import Foundation

struct CompanionHoldGate: Sendable {
    let control: CompanionTalkControl
    let turn: NativeConversationTurn
    let typedHere: Bool
    let known: Set<UUID>
    let said: String
    let earlier: String?
    let answerer: NativeInstructionAnswerer
    let timeout: Duration
    let toolTimeout: Duration
    let ledger: CompanionTalkLedger
}

enum CompanionHoldTools {
    static let setAsideName = "set_work_aside"
    static let pickUpName = "pick_work_up"
    static let changeName = "change_work"
    static let names: Set<String> = [setAsideName, pickUpName, changeName]
    static let workLimit = 4000
    static let changeIndex = 900

    static func about(_ ask: String, _ entry: CompanionTalkEntry, among entries: [CompanionTalkEntry], earlier: String?, only: String) -> String {
        ask + CompanionTalkTools.quoted(NativeInstructionCheck.clean(entry.description)) + "."
            + CompanionTalkTools.others(entry, entries) + " Answer true only if the message clearly means this one thing and " + only
            + CompanionTalkTools.context(earlier)
    }

    static func setAside(_ entry: CompanionTalkEntry?) -> String? {
        guard let entry else { return CompanionHoldCopy.notGoing }
        if entry.canSetAside { return nil }
        switch entry.phase {
        case .setAside: return CompanionHoldCopy.alreadyAside
        case .finished: return CompanionTalkCopy.alreadyFinished
        case .couldNotFinish, .stopped: return CompanionTalkCopy.alreadyEnded
        case .stopping: return CompanionTalkCopy.alreadyStopping
        case .newer: return CompanionHoldCopy.newer
        default: return CompanionHoldCopy.notGoing
        }
    }

    static func pickUpRefusal(_ entry: CompanionTalkEntry?) -> String? {
        guard let entry else { return CompanionHoldCopy.notAside }
        if entry.canPickUp { return nil }
        return entry.phase == .newer ? CompanionHoldCopy.newer : CompanionHoldCopy.notAside
    }

    static func change(_ entry: CompanionTalkEntry?) -> String? {
        guard let entry else { return CompanionHoldCopy.cannotChange }
        if entry.phase == .newer { return CompanionHoldCopy.newer }
        if entry.phase == .stopping { return CompanionTalkCopy.alreadyStopping }
        return entry.canStop ? nil : CompanionHoldCopy.cannotChange
    }

    static func carried(reference: NativeTaskReference, firstAsked: String?, snapshots: [NativeTaskSnapshot],
                        done: [String], unsure: [String]) -> NativeCompanionCarried {
        let before = reference.request.dot?.carried
        let typed = reference.request.dot?.typedRequest ?? ""
        let asked = before?.request ?? [firstAsked ?? "", typed, reference.request.objective].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        let newest = snapshots.last
        var sources: [NativeTaskSource] = []
        for source in (newest?.checkpoint.sources ?? []) + (before?.sources ?? []) where !sources.contains(where: { $0.n == source.n }) {
            let fits = source.title.unicodeScalars.count <= NativeCompanionCarried.titleLimit && source.url.utf8.count <= 8192
            if fits, sources.count < NativeCompanionCarried.sourceLimit { sources.append(source) }
        }
        let note = newest?.checkpoint.note.map { CompanionTalkTools.clipped($0.text, NativeCompanionCarried.noteLimit) }
        func kept(_ titles: [String]) -> [String] {
            var seen: [String] = []
            for title in titles.map({ CompanionTalkTools.clipped($0, NativeCompanionCarried.titleLimit) }) where !seen.contains(title) && !title.isEmpty {
                if seen.count < NativeCompanionCarried.effectLimit { seen.append(title) }
            }
            return seen
        }
        return NativeCompanionCarried(request: String(String.UnicodeScalarView(asked.unicodeScalars.prefix(NativeCompanionCarried.requestLimit))),
                                      note: note.flatMap { $0.isEmpty ? nil : $0 }, sources: sources,
                                      done: kept((before?.done ?? []) + done), unsure: kept((before?.unsure ?? []) + unsure))
    }
}

enum CompanionHoldCopy {
    static let guide = "To put one thing aside until the person asks for it again, call set_work_aside. To carry on with something that is put aside, call pick_work_up. To change what one thing should do, call change_work with the whole job as it now stands. Each works only as the very first thing in your reply, only when the person's current message asks for it, and only for one item. If more than one item could be what they mean, ask which one and call nothing. Putting something aside has no time on it and is not a reminder, so never say you'll come back to it by yourself. Afterwards say in one line what you did, in the first person, for example: I've put the library comparison aside."

    static let setAsideDescription = "Put one thing you are doing in this conversation aside until the person asks you to pick it back up. Use it only as the first call in your reply, only when the person's current message asks to pause it, hold it, put it aside or leave it for later without naming a time, and only for an item in this turn's list of your work. item is that entry's item code. If more than one item could be meant, ask which one instead of calling this."
    static let pickUpDescription = "Carry on with one thing that is put aside. Use it only as the first call in your reply, only when the person's current message asks you to pick it back up, resume it or carry on with it, and only for an item in this turn's list of your work whose state is put aside. item is that entry's item code. If more than one item could be meant, ask which one instead of calling this."
    static let changeDescription = "Change what one thing you are doing in this conversation should do. Use it only as the first call in your reply, only when the person's current message changes what they want from it, and only for an item in this turn's list of your work. item is that entry's item code. work is the whole job as it now stands after the change, written so it makes sense by itself. What you had already found is carried over. If more than one item could be meant, ask which one instead of calling this."
    static let setAsideTitle = "Put work aside"
    static let pickUpTitle = "Pick work back up"
    static let changeTitle = "Change work"

    static let invalid = "Nothing was changed. Give one item code from the current list."
    static let invalidChange = "Nothing was changed. Give one item code from the current list and the whole job as it now stands."
    static let notGoing = "Nothing was changed. That one isn't going right now, so there's nothing to put aside. Say so plainly."
    static let alreadyAside = "Nothing was changed. That one is already put aside. Say so plainly."
    static let newer = "Nothing was changed. That one was saved by a newer version of the app, so it can't be touched until the app is updated. Say so plainly."
    static let setAside = "Put aside. It stays where it got to until the person asks you to pick it back up."
    static let settingAside = "Put aside. Anything it had already sent is finishing, and it does nothing more until the person asks you to pick it back up."
    static let couldNotSetAside = "Nothing was changed. It couldn't be put aside just now. Tell the person and suggest trying again."
    static let notAside = "Nothing was changed. That one isn't put aside, so there's nothing to pick back up. Say so plainly."
    static let pickedUp = "Picked back up. It carries on from where it got to."
    static let couldNotPickUp = "Nothing was changed. It couldn't be picked back up just now. Tell the person and suggest trying again."
    static let cannotChange = "Nothing was changed. That one has already ended, so there's nothing to change. If the person wants more, they can ask for it as something new. Say so plainly."
    static let couldNotChange = "Nothing was changed. It couldn't be changed just now. Tell the person and suggest trying again."
    static let resting = "Nothing was changed. You are paused, so nothing new can start. Tell the person to resume you and ask again."
    static let changed = "Changed. What you were doing before has stopped, and you are now doing the job as it stands, with what you had already found."
    static let stoppedOnly = "What you were doing before has stopped, but the changed job couldn't be started. Tell the person plainly and suggest asking for it again."

    static let modelSentences: [String] = [guide, setAsideDescription, pickUpDescription, changeDescription, setAsideTitle, pickUpTitle, changeTitle,
                                           invalid, invalidChange, notGoing, alreadyAside, newer, setAside, settingAside, couldNotSetAside, notAside,
                                           pickedUp, couldNotPickUp, cannotChange, couldNotChange, resting, changed, stoppedOnly,
                                           NativeCompanionWorker.carriedLead]
}

extension ChatStore {
    func companionHoldCleared(_ gate: CompanionHoldGate, handle: String, eligible: @escaping @Sendable (CompanionTalkEntry?) -> String?,
                              about: @Sendable (CompanionTalkEntry) -> String) async throws -> (entry: CompanionTalkEntry?, refusal: NativeJSONValue?) {
        func no(_ sentence: String) -> (entry: CompanionTalkEntry?, refusal: NativeJSONValue?) { (nil, CompanionTalkTools.refusal(sentence)) }
        guard gate.typedHere else { return no(CompanionTalkCopy.notTyped) }
        guard CompanionTalkTools.firstInReply() else { return no(CompanionTalkCopy.notFirst) }
        guard let entry = gate.control.entry(handle) else { return no(CompanionTalkCopy.unknownItem) }
        guard gate.known.contains(entry.referenceID) else { return no(CompanionTalkCopy.startedAfter) }
        let turn = gate.turn
        let live = await MainActor.run { (self.turnOwned(turn), self.companionTalkLive(entry.referenceID)) }
        guard live.0 else { return no(CompanionTalkCopy.notCurrent) }
        if let sentence = eligible(live.1) { return no(sentence) }
        let question = about(entry)
        let said = gate.said
        let answerer = gate.answerer
        let cleared = await NativeInstructionCheck.bounded(gate.timeout) { await answerer(said, question) }
        try Task.checkCancellation()
        guard cleared else { return no(CompanionTalkCopy.unclear) }
        let after = await MainActor.run { (self.turnOwned(turn), self.companionTalkLive(entry.referenceID)) }
        guard after.0 else { return no(CompanionTalkCopy.notCurrent) }
        if let sentence = eligible(after.1) { return no(sentence) }
        return (entry, nil)
    }

    func companionHoldTools(_ gate: CompanionHoldGate) -> [NativeToolDefinition] {
        let entries = gate.control.entries
        let item: NativeJSONValue = .object(["type": .string("string"), "minLength": .number(1),
                                             "maxLength": .number(Double(CompanionTalkTools.handleLimit))])
        let single: NativeJSONValue = .object(["type": .string("object"), "additionalProperties": .bool(false),
                                               "required": .array([.string("item")]), "properties": .object(["item": item])])
        let ledger = gate.ledger
        let kept: @Sendable (String, NativeJSONValue) -> NativeJSONValue = { key, outcome in
            if case .object(let fields) = outcome, fields["changed"] == .bool(true) { ledger.keep(key, outcome) }
            return outcome
        }
        let setAside = NativeToolDefinition(id: CompanionTalkTools.toolID, name: CompanionHoldTools.setAsideName, title: CompanionHoldCopy.setAsideTitle,
            description: CompanionHoldCopy.setAsideDescription, parameters: single,
            confirmation: .none, timeout: gate.toolTimeout, effect: .read, isAvailable: { true },
            execute: { [weak self] arguments in
                guard Set(arguments.keys) == ["item"], let handle = CompanionTalkTools.text(arguments, "item", limit: CompanionTalkTools.handleLimit) else {
                    return CompanionTalkTools.refusal(CompanionHoldCopy.invalid)
                }
                let key = "aside|" + handle
                if let earlierResult = gate.ledger.recall(key) { return earlierResult }
                guard let self else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                let cleared = try await self.companionHoldCleared(gate, handle: handle, eligible: CompanionHoldTools.setAside) { entry in
                    CompanionHoldTools.about("Put this one thing aside for now: ", entry, among: entries, earlier: gate.earlier,
                                             only: "asks to pause it, hold it or put it aside, with no time named.")
                }
                guard let entry = cleared.entry else { return cleared.refusal ?? CompanionTalkTools.refusal(CompanionHoldCopy.couldNotSetAside) }
                return kept(key, await self.companionTalkHold(entry.referenceID, resume: false))
            })
        let pickUp = NativeToolDefinition(id: CompanionTalkTools.toolID, name: CompanionHoldTools.pickUpName, title: CompanionHoldCopy.pickUpTitle,
            description: CompanionHoldCopy.pickUpDescription, parameters: single,
            confirmation: .none, timeout: gate.toolTimeout, effect: .read, isAvailable: { true },
            execute: { [weak self] arguments in
                guard Set(arguments.keys) == ["item"], let handle = CompanionTalkTools.text(arguments, "item", limit: CompanionTalkTools.handleLimit) else {
                    return CompanionTalkTools.refusal(CompanionHoldCopy.invalid)
                }
                let key = "pickup|" + handle
                if let earlierResult = gate.ledger.recall(key) { return earlierResult }
                guard let self else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                let cleared = try await self.companionHoldCleared(gate, handle: handle, eligible: CompanionHoldTools.pickUpRefusal) { entry in
                    CompanionHoldTools.about("Carry on with this one thing that was put aside: ", entry, among: entries, earlier: gate.earlier,
                                             only: "asks to pick it back up, resume it or carry on with it.")
                }
                guard let entry = cleared.entry else { return cleared.refusal ?? CompanionTalkTools.refusal(CompanionHoldCopy.couldNotPickUp) }
                return kept(key, await self.companionTalkHold(entry.referenceID, resume: true))
            })
        let change = NativeToolDefinition(id: CompanionTalkTools.toolID, name: CompanionHoldTools.changeName, title: CompanionHoldCopy.changeTitle,
            description: CompanionHoldCopy.changeDescription,
            parameters: .object(["type": .string("object"), "additionalProperties": .bool(false),
                                 "required": .array([.string("item"), .string("work")]),
                                 "properties": .object(["item": item,
                                                        "work": .object(["type": .string("string"), "minLength": .number(1),
                                                                         "maxLength": .number(Double(CompanionHoldTools.workLimit))])])]),
            confirmation: .none, timeout: gate.toolTimeout, effect: .read, isAvailable: { true },
            execute: { [weak self] arguments in
                guard Set(arguments.keys) == ["item", "work"],
                      let handle = CompanionTalkTools.text(arguments, "item", limit: CompanionTalkTools.handleLimit),
                      let work = CompanionTalkTools.text(arguments, "work", limit: CompanionHoldTools.workLimit) else {
                    return CompanionTalkTools.refusal(CompanionHoldCopy.invalidChange)
                }
                let key = "change|" + handle
                if let earlierResult = gate.ledger.recall(key) { return earlierResult }
                guard let self else { return CompanionTalkTools.refusal(CompanionTalkCopy.notCurrent) }
                guard await MainActor.run(body: { !self.dotProfile.isPaused }) else { return CompanionTalkTools.refusal(CompanionHoldCopy.resting) }
                let cleared = try await self.companionHoldCleared(gate, handle: handle, eligible: CompanionHoldTools.change) { entry in
                    CompanionHoldTools.about("Change what this one thing should do, so that the job becomes "
                                             + CompanionTalkTools.quoted(NativeInstructionCheck.clean(work)) + ". The thing: ",
                                             entry, among: entries, earlier: gate.earlier, only: "asks for this change to it.")
                }
                guard let entry = cleared.entry else { return cleared.refusal ?? CompanionTalkTools.refusal(CompanionHoldCopy.couldNotChange) }
                return kept(key, await self.companionTalkChange(entry.referenceID, work: work, gate: gate))
            })
        return [setAside, pickUp, change]
    }

    func companionTalkHold(_ id: UUID, resume: Bool) async -> NativeJSONValue {
        let failed = resume ? CompanionHoldCopy.couldNotPickUp : CompanionHoldCopy.couldNotSetAside
        guard let tracker = nativeTaskTracker else { return CompanionTalkTools.refusal(failed) }
        let snapshot = await tracker.hold(id, resume: resume)
        reloadNativeTaskReferences()
        guard let snapshot else { return CompanionTalkTools.refusal(failed) }
        if snapshot.state.isTerminal {
            return CompanionTalkTools.refusal(snapshot.state == .completed ? CompanionTalkCopy.alreadyFinished : CompanionTalkCopy.alreadyEnded)
        }
        if resume {
            guard !snapshot.held, snapshot.state != .unknown else { return CompanionTalkTools.refusal(failed) }
            return .object(["result": .string(CompanionHoldCopy.pickedUp), "changed": .bool(true)])
        }
        guard snapshot.held else { return CompanionTalkTools.refusal(failed) }
        let sentence = snapshot.state == .paused ? CompanionHoldCopy.setAside : CompanionHoldCopy.settingAside
        return .object(["result": .string(sentence), "changed": .bool(true)])
    }

    func setCompanionWorkAside(_ item: CompanionActivityItem, resume: Bool) {
        guard case .task(let id) = item.source, let tracker = nativeTaskTracker else { return }
        Task { [weak self] in
            _ = await tracker.hold(id, resume: resume)
            self?.reloadNativeTaskReferences()
        }
    }

    func companionTalkChange(_ id: UUID, work: String, gate: CompanionHoldGate) async -> NativeJSONValue {
        guard let service = nativeTaskService, let projection = repository as? any NativeTaskProjectionRepository,
              let old = (try? projection.taskReference(id: id)) ?? nil else {
            return CompanionTalkTools.refusal(CompanionHoldCopy.couldNotChange)
        }
        let firstAsked = conversations.first { $0.id == old.origin.conversationID }?.messages.first { $0.id == old.origin.userMessageID }?.text
        let stopped = await companionTalkStop(id)
        guard case .object(let fields) = stopped, fields["changed"] == .bool(true) else {
            let ended = companionTalkLive(id).map { !$0.phase.ongoing } ?? true
            return CompanionTalkTools.refusal(ended ? CompanionHoldCopy.cannotChange : CompanionHoldCopy.couldNotChange)
        }
        func titles(_ key: String) -> [String] {
            guard case .array(let values)? = fields[key] else { return [] }
            return values.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
        }
        let done = titles("already_done")
        let unsure = titles("may_have_happened")
        var outcome: [String: NativeJSONValue] = ["changed": .bool(true)]
        var tail = ""
        if !done.isEmpty {
            tail += CompanionTalkCopy.alreadyDone
            outcome["already_done"] = fields["already_done"]
        }
        if !unsure.isEmpty {
            tail += CompanionTalkCopy.maybeDone
            outcome["may_have_happened"] = fields["may_have_happened"]
        }
        let latest = (try? projection.taskReference(id: id)) ?? nil
        let saved = ((try? projection.taskProjection(id: id)) ?? nil)?.snapshot
        let carried = CompanionHoldTools.carried(reference: old, firstAsked: firstAsked,
                                                 snapshots: CompanionTalkTools.oldestFirst(saved, latest?.snapshot ?? old.snapshot), done: done, unsure: unsure)
        let typed = gate.said.unicodeScalars.count <= NativeCompanionTaskPayload.saidLimit ? gate.said : ""
        let origin = NativeTaskOrigin(conversationID: gate.turn.conversationID, userMessageID: gate.turn.userMessageID,
                                      assistantMessageID: gate.turn.assistantMessageID, index: CompanionHoldTools.changeIndex)
        let (profile, enrolled) = askedWorkProfile()
        var started: NativeTaskReference?
        if enrolled, turnOwned(gate.turn),
           let request = try? ChatStore.companionRequest(work, connectedToolIDs: dotProfile.connectedToolIDs?.sorted(), said: typed, carried: carried) {
            started = try? await service.submit(origin: origin, request: request, profile: profile)
        }
        guard let started, started.deliveryState != .rejected, !started.cancelRequested else {
            reloadNativeTaskReferences()
            outcome["result"] = .string(CompanionHoldCopy.stoppedOnly + tail)
            return .object(outcome)
        }
        _ = try? projection.markTaskReplaced(id: id, by: started.id)
        reloadNativeTaskReferences()
        outcome["result"] = .string(CompanionHoldCopy.changed + tail)
        return .object(outcome)
    }
}
