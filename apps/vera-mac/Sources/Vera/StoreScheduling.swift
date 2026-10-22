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
            let state = (try? projectionRepository.taskProjection(id: reference.id))?.snapshot?.state ?? reference.snapshot?.state
            let status: NativeScheduleTaskStatus
            switch state {
            case .completed: status = .completed
            case .failed: status = .failed
            case .canceled: status = .stopped
            default: status = .active
            }
            return NativeScheduleTaskLink(referenceID: reference.id.uuidString, status: status)
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
                schedule.advance(after: Date(), from: nil)
                guard schedule.nextRunAt != nil else {
                    scheduleError = "Pick a time that is still ahead."
                    return
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
        try? store.delete(id)
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

    func fireSchedule(_ schedule: NativeSchedule, run: NativeScheduleRun, bind: NativeScheduleBind) async -> NativeScheduleFireResult {
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
        await bind(conversationID, reply.id.uuidString)
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
