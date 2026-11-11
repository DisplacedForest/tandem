import Foundation

struct NativeScheduleDraft: Equatable, Sendable {
    var title: String = ""
    var instruction: String = ""
    var workerType: String = "research"
    var owner: NativeScheduleOwner = .conversation
    var cadence: NativeScheduleCadence = .daily(minuteOfDay: 9 * 60)

    init() {}

    init(_ schedule: NativeSchedule) {
        title = schedule.title
        instruction = schedule.instruction
        workerType = schedule.workerType
        owner = schedule.owner
        cadence = schedule.cadence
    }
}

extension ChatStore {
    static let scheduleOriginType = "schedule"

    var keepsRunningInMenuBar: Bool { menuBarPreference ?? !schedules.isEmpty }

    var menuBarIsDefaulted: Bool { menuBarPreference == nil && !schedules.isEmpty }

    var nextScheduledRun: (schedule: NativeSchedule, at: Date)? {
        schedules.compactMap { schedule -> (NativeSchedule, Date)? in
            guard schedule.enabled, let next = schedule.nextRunAt else { return nil }
            return (schedule, next)
        }
        .min { $0.1 < $1.1 }
        .map { (schedule: $0.0, at: $0.1) }
    }

    var runningScheduledWorkCount: Int {
        scheduleRuns.values.flatMap { $0 }.filter { $0.outcome == .running }.count
    }

    var waitingScheduledWorkCount: Int {
        scheduleRuns.values.flatMap { $0 }.filter { $0.outcome == .waiting }.count
    }

    static func checkInKey(taskReferenceID: String, decision: NativeTaskDecision?) -> String {
        taskReferenceID + ":" + (decision?.id ?? "")
    }

    func scheduleRunDecision(_ run: NativeScheduleRun) -> NativeTaskDecision? {
        guard run.outcome == .waiting, let id = run.taskReferenceID, let uuid = UUID(uuidString: id),
              let projectionRepository = repository as? any NativeTaskProjectionRepository else { return nil }
        return (try? projectionRepository.taskProjection(id: uuid))?.snapshot?.decision
    }

    func scheduleRunTitle(_ run: NativeScheduleRun) -> String {
        guard run.outcome == .completed, let id = run.taskReferenceID, let uuid = UUID(uuidString: id),
              let projectionRepository = repository as? any NativeTaskProjectionRepository,
              let reference = try? projectionRepository.taskReference(id: uuid) else { return run.outcome.title }
        let snapshot = (try? projectionRepository.taskProjection(id: uuid))?.snapshot ?? reference.snapshot
        return Self.scheduleRunTitle(run, card: (try? NativeTaskProjection.display(reference: reference, snapshot: snapshot))?.card)
    }

    nonisolated static func scheduleRunTitle(_ run: NativeScheduleRun, card: NativeTaskCardPresentation?) -> String {
        guard run.outcome == .completed, let card else { return run.outcome.title }
        return card.listState(run.outcome.title)
    }

    func scheduleRunIsCompanionWork(_ run: NativeScheduleRun) -> Bool {
        if let id = run.taskReferenceID, let uuid = UUID(uuidString: id) {
            let reference = nativeTaskReferences.first { $0.id == uuid }
                ?? (repository as? any NativeTaskProjectionRepository).flatMap { (projection: any NativeTaskProjectionRepository) -> NativeTaskReference? in
                    (try? projection.taskReference(id: uuid)) ?? nil
                }
            if let reference { return reference.request.workerType == "companion" }
        }
        return schedules.first { $0.id == run.scheduleID }?.isCompanionWork == true
    }

    func scheduleRunNote(_ run: NativeScheduleRun) -> CompanionLine {
        let companionWork = scheduleRunIsCompanionWork(run)
        let detail = NativeScheduler.shownNote(run.detail)
        return CompanionSavedText.line(detail, appWritten: run.noteIsAppWritten(companionWork: companionWork)
                                           || detail.hasPrefix(CompanionSavedText.marker))
    }

    func answerScheduleRun(_ run: NativeScheduleRun, choice: String) {
        guard let reference = run.taskReferenceID else { return }
        switch NativeScheduleAnswer.route(choice) {
        case .retry: retryNativeTask(reference)
        case .stop: cancelNativeTask(reference)
        case .answer: answerNativeTask(reference, choice: choice)
        }
    }

    func postScheduleCheckIns() {
        guard nativeScheduleStore != nil, let repository, let local = repository as? LocalChatRepository,
              let projectionRepository = repository as? any NativeTaskProjectionRepository else { return }
        var posted = false
        for run in scheduleRuns.values.flatMap({ $0 }) where run.outcome == .waiting {
            guard let referenceID = run.taskReferenceID, let uuid = UUID(uuidString: referenceID),
                  let conversationID = run.conversationID,
                  let reference = try? projectionRepository.taskReference(id: uuid),
                  let snapshot = (try? projectionRepository.taskProjection(id: uuid))?.snapshot,
                  snapshot.state == .needsDecision, let decision = snapshot.decision else { continue }
            let key = Self.checkInKey(taskReferenceID: referenceID, decision: decision)
            guard run.checkInKey != key, let schedule = schedules.first(where: { $0.id == run.scheduleID }) else { continue }
            guard let display = try? NativeTaskProjection.display(reference: reference, snapshot: snapshot) else { continue }
            var message = Message(role: .assistant,
                                  text: "The scheduled \(schedule.workTitle.lowercased()) \"\(schedule.title)\" stopped to ask: \(CompanionSavedText.plain(decision.prompt, name: companionName, appWritten: reference.request.workerType == "companion"))",
                                  state: .complete)
            message.displayBlocks = [.taskCard(display.card)]
            guard (try? local.postScheduleCheckIn(message, conversationID: conversationID, runID: run.id, key: key, referenceID: uuid,
                                                  decisionID: decision.id)) == true else { continue }
            if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                if !conversations[index].messages.isEmpty || selectedID == conversationID {
                    conversations[index].messages.append(message)
                }
                conversations[index].updatedAt = Date()
                conversations[index].isPersisted = true
                try? repository.saveConversation(conversations[index])
            } else if let stored = try? repository.listConversations().first(where: { $0.id == conversationID }) {
                conversations.insert(stored, at: 0)
            }
            posted = true
        }
        if posted { reloadSchedules() }
    }

    func startNativeScheduler() {
        guard nativeScheduler == nil, let local = repository as? LocalChatRepository else { return }
        let store = NativeScheduleStore(database: local.database)
        nativeScheduleStore = store
        let projectionRepository = repository as? any NativeTaskProjectionRepository
        let scheduler = NativeScheduler(store: store, lookup: { run in
            guard let projectionRepository else { return nil }
            let reference: NativeTaskReference?
            if let id = run.taskReferenceID, let uuid = UUID(uuidString: id) {
                reference = try? projectionRepository.taskReference(id: uuid)
            } else if let conversationID = run.conversationID, let message = run.messageID, let uuid = UUID(uuidString: message) {
                reference = (try? projectionRepository.taskReferences(conversationID: conversationID))?
                    .first { $0.origin.assistantMessageID == uuid }
            } else {
                reference = nil
            }
            guard let reference else { return nil }
            if reference.deliveryState == NativeTaskDeliveryState.rejected {
                return NativeScheduleTaskLink(referenceID: reference.id.uuidString, status: .failed)
            }
            let snapshot = (try? projectionRepository.taskProjection(id: reference.id))?.snapshot ?? reference.snapshot
            let status: NativeScheduleTaskStatus
            switch snapshot?.state {
            case .completed: status = .completed
            case .failed: status = .failed
            case .canceled: status = .stopped
            case .needsDecision:
                let prompt = snapshot?.decision?.prompt ?? NativeScheduler.waitingNote
                status = .waiting(reference.request.workerType == "companion" ? prompt : CompanionSavedText.sanitized(prompt))
            case .blocked: status = .blocked(NativeScheduler.blockedNote)
            default: status = .active
            }
            let terminal = status == .completed || status == .failed || status == .stopped
            return NativeScheduleTaskLink(referenceID: reference.id.uuidString, status: status,
                                          endedAt: terminal ? snapshot.map { Date(timeIntervalSince1970: $0.updatedAt) } : nil)
        }, fire: { [weak self] schedule, run, bind in
            guard let self else { return .failed("Tandem is closing.") }
            return await self.fireSchedule(schedule, run: run, bind: bind)
        })
        nativeScheduler = scheduler
        reloadSchedules()
        nativeSchedulerLoop = Task { [weak self] in
            while !Task.isCancelled {
                let changed = await scheduler.tick()
                guard let self else { return }
                if changed || self.runningScheduledWorkCount > 0 { self.reloadSchedules() }
                if changed || self.waitingScheduledWorkCount > 0 { self.postScheduleCheckIns() }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    func reloadSchedules() {
        guard let store = nativeScheduleStore else { return }
        let loaded = (try? store.all()) ?? []
        if loaded != schedules { schedules = loaded }
        var runs: [String: [NativeScheduleRun]] = [:]
        for schedule in loaded {
            runs[schedule.id] = (try? store.runs(scheduleID: schedule.id)) ?? []
        }
        if runs != scheduleRuns { scheduleRuns = runs }
    }

    @discardableResult
    func createSchedule(_ draft: NativeScheduleDraft) -> NativeSchedule? {
        guard let store = nativeScheduleStore else {
            scheduleError = "Schedules need local history, which couldn't open."
            return nil
        }
        do {
            var schedule = try NativeSchedule(owner: draft.owner, workerType: draft.workerType, title: draft.title,
                                              instruction: draft.instruction, cadence: draft.cadence, timeZone: .current)
            schedule.advance(after: Date(), from: nil)
            guard schedule.nextRunAt != nil else {
                scheduleError = "Pick a time that is still ahead."
                return nil
            }
            try store.save(schedule)
            scheduleError = nil
            reloadSchedules()
            return schedule
        } catch {
            scheduleError = error.localizedDescription
            return nil
        }
    }

    func scheduleFromChat(_ draft: NativeScheduleDraft) throws -> NativeSchedule {
        if let created = createSchedule(draft) { return created }
        throw NativeScheduleError.invalid(scheduleError ?? "The schedule couldn't be saved.")
    }

    func scheduleToolDefinition() -> NativeToolDefinition? {
        guard nativeScheduleStore != nil else { return nil }
        return NativeScheduleTools.definition(searchAvailable: nativeSearchAvailable, save: { [weak self] draft in
            guard let self else { throw NativeScheduleError.invalid("Tandem is closing.") }
            return try await self.scheduleFromChat(draft)
        })
    }

    func updateSchedule(_ id: String, with draft: NativeScheduleDraft) {
        guard let store = nativeScheduleStore, let existing = try? store.get(id) else { return }
        do {
            var schedule = try NativeSchedule(id: existing.id, owner: draft.owner,
                                              conversationID: draft.owner == existing.owner ? existing.conversationID : nil,
                                              workerType: draft.workerType, title: draft.title, instruction: draft.instruction,
                                              cadence: draft.cadence, timeZone: draft.cadence == existing.cadence ? existing.timeZone : .current,
                                              enabled: existing.enabled, lastRunAt: existing.lastRunAt,
                                              lastOutcome: existing.lastOutcome, createdAt: existing.createdAt)
            if existing.enabled {
                if draft.cadence == existing.cadence, let kept = existing.nextRunAt {
                    schedule.nextRunAt = kept
                } else {
                    schedule.advance(after: Date(), from: nil)
                    guard schedule.nextRunAt != nil else {
                        scheduleError = "Pick a time that is still ahead."
                        return
                    }
                }
            }
            try store.save(schedule)
            scheduleError = nil
            reloadSchedules()
        } catch {
            scheduleError = error.localizedDescription
        }
    }

    func setSchedule(_ id: String, enabled: Bool) {
        guard let store = nativeScheduleStore, var schedule = try? store.get(id) else { return }
        schedule.enabled = enabled
        if enabled {
            schedule.advance(after: Date(), from: nil)
            if schedule.nextRunAt == nil {
                scheduleError = "This one-time schedule has already passed. Edit it to pick a new time."
                return
            }
        } else {
            schedule.nextRunAt = nil
        }
        try? store.save(schedule)
        scheduleError = nil
        reloadSchedules()
    }

    func deleteSchedule(_ id: String) {
        guard let store = nativeScheduleStore else { return }
        guard (try? store.delete(id)) != nil else { reloadSchedules(); return }
        removeRules(for: .schedule(id))
        reloadSchedules()
    }

    func runScheduleNow(_ id: String) {
        guard let scheduler = nativeScheduler else { return }
        Task { [weak self] in
            _ = await scheduler.runNow(id)
            self?.reloadSchedules()
        }
    }

    func stopScheduleRun(_ run: NativeScheduleRun) {
        guard let reference = run.taskReferenceID else { return }
        cancelNativeTask(reference)
    }

    func openScheduleRun(_ run: NativeScheduleRun) {
        guard let conversationID = run.conversationID else { return }
        if !conversations.contains(where: { $0.id == conversationID }), let repository,
           let stored = try? repository.listConversations().first(where: { $0.id == conversationID }) {
            conversations.insert(stored, at: 0)
        }
        guard conversations.contains(where: { $0.id == conversationID }) else {
            scheduleError = "The chat that held this run is gone."
            return
        }
        select(conversationID)
    }

    static let removedScheduleReason = "This schedule was removed."

    func scheduleIsLive(_ id: String) -> Bool {
        guard let store = nativeScheduleStore else { return true }
        return ((try? store.get(id)) ?? nil) != nil
    }

    func fireSchedule(_ schedule: NativeSchedule, run: NativeScheduleRun, bind: NativeScheduleBind) async -> NativeScheduleFireResult {
        guard scheduleIsLive(schedule.id) else { return .skipped(Self.removedScheduleReason) }
        guard dotProfile.allowsScheduledRun(owner: schedule.owner) else { return .skipped("\(CompanionSavedText.marker) is paused.") }
        if dotProfile.missedWhilePaused(owner: schedule.owner, scheduledFor: run.scheduledFor) {
            return .skipped("Missed while \(CompanionSavedText.marker) was paused.")
        }
        guard let repository, let service = nativeTaskService, nativeTaskEngine.base != nil else {
            return .failed("Background work isn't available right now.")
        }
        guard let nativeConfig = currentNativeConfig else { return .failed("No model is set up. Add one in Settings.") }
        let profile = nativeTaskEnrollment ?? (try? nativeTaskConfiguration?.enroll(config: nativeConfig))
        if nativeTaskConfiguration != nil && profile == nil { return .failed("The model profile couldn't be prepared.") }
        if !schedule.isDocument && !nativeSearchAvailable() { return .failed("Search isn't set up. Add a search URL in Settings.") }
        let request: NativeResearchTaskRequest
        do { request = try schedule.taskRequest() } catch { return .failed(error.localizedDescription) }
        guard let conversationID = scheduleConversation(schedule) else {
            return .failed("The chat for this schedule couldn't be created.")
        }
        let user = Message(role: .user, text: schedule.instruction)
        let reply = Message(role: .assistant, text: "", state: .complete, modelID: nativeConfig.model)
        await bind(conversationID, reply.id.uuidString)
        guard scheduleIsLive(schedule.id) else { return .skipped(Self.removedScheduleReason) }
        guard dotProfile.allowsScheduledRun(owner: schedule.owner) else { return .skipped("\(CompanionSavedText.marker) is paused.") }
        if dotProfile.missedWhilePaused(owner: schedule.owner, scheduledFor: run.scheduledFor) {
            return .skipped("Missed while \(CompanionSavedText.marker) was paused.")
        }
        if schedule.owner == .dot && !isVeraThread(conversationID) {
            return .skipped("\(CompanionSavedText.marker) started over before this ran.")
        }
        do {
            let ordinal = try repository.messages(conversationID: conversationID).count
            try repository.saveMessage(user, conversationID: conversationID, ordinal: ordinal)
            try repository.saveMessage(reply, conversationID: conversationID, ordinal: ordinal + 1)
        } catch {
            return .failed("The run couldn't be saved: \(error.localizedDescription)")
        }
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            if !conversations[index].messages.isEmpty || selectedID == conversationID {
                conversations[index].messages.append(contentsOf: [user, reply])
            }
            conversations[index].updatedAt = Date()
            conversations[index].isPersisted = true
            try? repository.saveConversation(conversations[index])
        }
        let origin = NativeTaskOrigin(conversationID: conversationID, userMessageID: user.id, assistantMessageID: reply.id)
        do {
            let reference = try await service.submit(origin: origin, request: request, profile: profile)
            reloadNativeTaskReferences()
            if reference.deliveryState == NativeTaskDeliveryState.rejected {
                return .failed(reference.lastDeliveryError ?? "The task engine refused the run.")
            }
            return .started(taskReferenceID: reference.id.uuidString)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func scheduleConversation(_ schedule: NativeSchedule) -> String? {
        guard let repository, let store = nativeScheduleStore else { return nil }
        if schedule.owner == .dot {
            ensureVeraThread()
            return veraThreadID
        }
        if let existing = schedule.conversationID, conversations.contains(where: { $0.id == existing }) { return existing }
        if let existing = schedule.conversationID,
           let stored = try? repository.listConversations().first(where: { $0.id == existing }) {
            conversations.insert(stored, at: 0)
            return existing
        }
        var conversation = Conversation(id: UUID().uuidString, title: schedule.title, messages: [], updatedAt: Date(),
                                        originType: Self.scheduleOriginType, originID: schedule.id, titleSource: .user)
        do {
            try repository.saveConversation(conversation)
        } catch {
            return nil
        }
        conversation.isPersisted = true
        conversations.insert(conversation, at: 0)
        if var saved = try? store.get(schedule.id) {
            saved.conversationID = conversation.id
            try? store.save(saved)
        }
        return conversation.id
    }
}

enum NativeScheduleAnswer: Equatable {
    case retry
    case stop
    case answer

    static func route(_ choice: String) -> NativeScheduleAnswer {
        switch choice.lowercased() {
        case "retry": return .retry
        case "stop", "cancel": return .stop
        default: return .answer
        }
    }
}
