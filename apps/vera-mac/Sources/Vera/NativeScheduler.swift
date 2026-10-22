import Foundation

enum NativeScheduleFireResult: Sendable, Equatable {
    case started(taskReferenceID: String)
    case failed(String)
}

enum NativeScheduleTaskStatus: Sendable, Equatable {
    case active
    case completed
    case failed
    case stopped
}

struct NativeScheduleTaskLink: Sendable, Equatable {
    let referenceID: String
    let status: NativeScheduleTaskStatus
}

typealias NativeScheduleBind = @Sendable (String, String) async -> Void

actor NativeScheduler {
    static let defaultGrace: TimeInterval = 300
    static let defaultDowntime: TimeInterval = 60
    static let missedHistoryCap = 24
    static let missedNote = "Tandem wasn't running at the scheduled time. It will run next time as planned."

    let store: NativeScheduleStore
    let now: @Sendable () -> Date
    let grace: TimeInterval
    let downtime: TimeInterval
    let lookup: @Sendable (NativeScheduleRun) -> NativeScheduleTaskLink?
    let fire: @Sendable (NativeSchedule, NativeScheduleRun, NativeScheduleBind) async -> NativeScheduleFireResult
    private var firing: Set<String> = []

    init(store: NativeScheduleStore, now: @escaping @Sendable () -> Date = { Date() },
         grace: TimeInterval = NativeScheduler.defaultGrace, downtime: TimeInterval = NativeScheduler.defaultDowntime,
         lookup: @escaping @Sendable (NativeScheduleRun) -> NativeScheduleTaskLink?,
         fire: @escaping @Sendable (NativeSchedule, NativeScheduleRun, NativeScheduleBind) async -> NativeScheduleFireResult) {
        self.store = store
        self.now = now
        self.grace = grace
        self.downtime = downtime
        self.lookup = lookup
        self.fire = fire
    }

    @discardableResult
    func tick() async -> Bool {
        let moment = now()
        let previousHeartbeat = try? store.heartbeat()
        try? store.recordHeartbeat(moment)
        let offlineSince: Date? = previousHeartbeat.flatMap { moment.timeIntervalSince($0) > downtime ? $0 : nil }
        var changed = settleRuns()
        guard let due = try? store.due(at: moment) else { return changed }
        for schedule in due where !firing.contains(schedule.id) {
            guard let scheduledFor = schedule.nextRunAt else { continue }
            var occurrences = [scheduledFor]
            var cursor = scheduledFor
            while let following = schedule.cadence.nextRun(after: cursor, previous: cursor, timeZone: schedule.timeZone), following <= moment {
                occurrences.append(following)
                cursor = following
            }
            let last = occurrences[occurrences.count - 1]
            let late = moment.timeIntervalSince(last)
            let lastMissed = late > grace || (offlineSince.map { last > $0 } ?? false)
            var next = schedule
            next.advance(after: moment, from: last)
            guard (try? store.claim(schedule.id, expectedNextRunAt: scheduledFor, nextRunAt: next.nextRunAt, enabled: next.enabled)) == true else { continue }
            changed = true
            let missed = lastMissed ? occurrences : Array(occurrences.dropLast())
            recordMissed(schedule.id, occurrences: missed, at: moment)
            if lastMissed { continue }
            if hasActiveRun(schedule.id) {
                try? store.saveRun(NativeScheduleRun(scheduleID: schedule.id, scheduledFor: last, finishedAt: moment, outcome: .skipped,
                                                     detail: "The previous run was still going."))
                continue
            }
            await start(schedule, scheduledFor: last, at: moment, late: late)
        }
        return changed
    }

    func runNow(_ id: String) async -> NativeScheduleRun? {
        guard let schedule = try? store.get(id), !firing.contains(id), !hasActiveRun(id) else { return nil }
        return await start(schedule, scheduledFor: now(), at: now(), late: 0)
    }

    private func recordMissed(_ scheduleID: String, occurrences: [Date], at moment: Date) {
        guard !occurrences.isEmpty else { return }
        let overflow = max(0, occurrences.count - Self.missedHistoryCap)
        for (index, occurrence) in occurrences.enumerated() where index >= overflow {
            var detail = Self.missedNote
            if overflow > 0 && index == overflow {
                detail = "\(overflow) earlier \(overflow == 1 ? "run was" : "runs were") also missed while Tandem wasn't running."
            }
            try? store.saveRun(NativeScheduleRun(scheduleID: scheduleID, scheduledFor: occurrence, finishedAt: moment, outcome: .missed, detail: detail))
        }
    }

    private func bind(_ runID: String, conversationID: String, messageID: String) {
        guard var run = try? store.run(runID) else { return }
        run.conversationID = conversationID
        run.messageID = messageID
        try? store.saveRun(run)
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
        let runID = run.id
        let result = await fire(schedule, run) { [weak self] conversationID, messageID in
            await self?.bind(runID, conversationID: conversationID, messageID: messageID)
        }
        guard var saved = try? store.run(runID) else { return nil }
        switch result {
        case .started(let taskReferenceID):
            saved.taskReferenceID = taskReferenceID
        case .failed(let reason):
            saved.outcome = .couldNotStart
            saved.detail = reason
            saved.finishedAt = now()
        }
        try? store.saveRun(saved)
        return saved
    }

    private func hasActiveRun(_ scheduleID: String) -> Bool {
        ((try? store.activeRuns()) ?? []).contains { $0.scheduleID == scheduleID }
    }

    private func settleRuns() -> Bool {
        guard let active = try? store.activeRuns() else { return false }
        var changed = false
        for var run in active where !firing.contains(run.scheduleID) {
            guard let link = lookup(run) else {
                if run.taskReferenceID == nil {
                    run.outcome = .couldNotStart
                    run.detail = run.messageID == nil ? "The run never reached the task engine."
                        : "Tandem closed before this run reached the task engine."
                } else {
                    run.outcome = .stopped
                    run.detail = "The chat that held this run is gone."
                }
                run.finishedAt = now()
                try? store.saveRun(run)
                changed = true
                continue
            }
            if run.taskReferenceID != link.referenceID {
                run.taskReferenceID = link.referenceID
                try? store.saveRun(run)
                changed = true
            }
            let outcome: NativeScheduleOutcome
            switch link.status {
            case .active: continue
            case .completed: outcome = .completed
            case .failed: outcome = .failed
            case .stopped: outcome = .stopped
            }
            run.outcome = outcome
            run.finishedAt = now()
            try? store.saveRun(run)
            changed = true
        }
        return changed
    }
}
