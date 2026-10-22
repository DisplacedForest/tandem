import Foundation

enum NativeScheduleFireResult: Sendable, Equatable {
    case started(conversationID: String, messageID: String, taskReferenceID: String)
    case failed(String)
}

enum NativeScheduleTaskStatus: Sendable, Equatable {
    case active
    case completed
    case failed
    case stopped
    case gone
}

actor NativeScheduler {
    static let defaultGrace: TimeInterval = 300

    let store: NativeScheduleStore
    let now: @Sendable () -> Date
    let grace: TimeInterval
    let fire: @Sendable (NativeSchedule, NativeScheduleRun) async -> NativeScheduleFireResult
    let taskStatus: @Sendable (String) -> NativeScheduleTaskStatus
    private var firing: Set<String> = []

    init(store: NativeScheduleStore, now: @escaping @Sendable () -> Date = { Date() },
         grace: TimeInterval = NativeScheduler.defaultGrace,
         taskStatus: @escaping @Sendable (String) -> NativeScheduleTaskStatus,
         fire: @escaping @Sendable (NativeSchedule, NativeScheduleRun) async -> NativeScheduleFireResult) {
        self.store = store
        self.now = now
        self.grace = grace
        self.taskStatus = taskStatus
        self.fire = fire
    }

    @discardableResult
    func tick() async -> Bool {
        var changed = settleRuns()
        let moment = now()
        guard let due = try? store.due(at: moment) else { return changed }
        for schedule in due where !firing.contains(schedule.id) {
            guard let scheduledFor = schedule.nextRunAt else { continue }
            var next = schedule
            next.advance(after: moment, from: scheduledFor)
            let late = moment.timeIntervalSince(scheduledFor)
            if late > grace {
                let run = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: scheduledFor, finishedAt: moment, outcome: .missed,
                                            detail: "Tandem wasn't running at the scheduled time. It will run next time as planned.")
                try? store.save(next)
                try? store.saveRun(run)
                changed = true
                continue
            }
            if hasActiveRun(schedule.id) {
                let run = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: scheduledFor, finishedAt: moment, outcome: .skipped,
                                            detail: "The previous run was still going.")
                try? store.save(next)
                try? store.saveRun(run)
                changed = true
                continue
            }
            try? store.save(next)
            await start(schedule, scheduledFor: scheduledFor, at: moment, late: late)
            changed = true
        }
        return changed
    }

    func runNow(_ id: String) async -> NativeScheduleRun? {
        guard let schedule = try? store.get(id), !firing.contains(id), !hasActiveRun(id) else { return nil }
        return await start(schedule, scheduledFor: now(), at: now(), late: 0)
    }

    @discardableResult
    private func start(_ schedule: NativeSchedule, scheduledFor: Date, at moment: Date, late: TimeInterval) async -> NativeScheduleRun? {
        firing.insert(schedule.id)
        defer { firing.remove(schedule.id) }
        var run = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: scheduledFor, startedAt: moment, outcome: .running)
        if late >= 60 {
            let minutes = Int(late / 60)
            run.detail = "Started \(minutes) \(minutes == 1 ? "minute" : "minutes") after the scheduled time."
        }
        guard (try? store.saveRun(run)) != nil else { return nil }
        switch await fire(schedule, run) {
        case .started(let conversationID, let messageID, let taskReferenceID):
            run.conversationID = conversationID
            run.messageID = messageID
            run.taskReferenceID = taskReferenceID
        case .failed(let reason):
            run.outcome = .couldNotStart
            run.detail = reason
            run.finishedAt = now()
        }
        try? store.saveRun(run)
        return run
    }

    private func hasActiveRun(_ scheduleID: String) -> Bool {
        ((try? store.activeRuns()) ?? []).contains { $0.scheduleID == scheduleID }
    }

    private func settleRuns() -> Bool {
        guard let active = try? store.activeRuns() else { return false }
        var changed = false
        for var run in active where !firing.contains(run.scheduleID) {
            guard let reference = run.taskReferenceID else {
                run.outcome = .couldNotStart
                run.detail = "The run never reached the task engine."
                run.finishedAt = now()
                try? store.saveRun(run)
                changed = true
                continue
            }
            let outcome: NativeScheduleOutcome
            switch taskStatus(reference) {
            case .active: continue
            case .completed: outcome = .completed
            case .failed: outcome = .failed
            case .stopped: outcome = .stopped
            case .gone:
                outcome = .stopped
                run.detail = "The chat that held this run is gone."
            }
            run.outcome = outcome
            run.finishedAt = now()
            try? store.saveRun(run)
            changed = true
        }
        return changed
    }
}
