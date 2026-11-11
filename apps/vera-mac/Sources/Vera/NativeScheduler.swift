import Foundation

enum NativeScheduleFireResult: Sendable, Equatable {
    case started(taskReferenceID: String)
    case failed(String)
    case skipped(String)
}

enum NativeScheduleTaskStatus: Sendable, Equatable {
    case active
    case waiting(String)
    case blocked(String)
    case completed
    case failed
    case stopped
}

struct NativeScheduleTaskLink: Sendable, Equatable {
    let referenceID: String
    let status: NativeScheduleTaskStatus
    var endedAt: Date? = nil
}

typealias NativeScheduleBind = @Sendable (String, String) async -> Void

actor NativeScheduler {
    static let defaultGrace: TimeInterval = 300
    static let defaultDowntime: TimeInterval = 60
    static let defaultCatchUp: TimeInterval = 86_400
    static let missedHistoryCap = 24
    static let missedNote = "Tandem wasn't running at the scheduled time."
    static let caughtUpNote = "Caught up after Tandem wasn't running at the scheduled time."
    static let retiredMissedNote = missedNote + " It will run next time as planned."

    static func shownNote(_ saved: String) -> String {
        saved == retiredMissedNote ? missedNote : saved
    }
    static let waitingNote = "Waiting for your answer."
    static let blockedNote = "Open Tandem with the saved model profile so this run can continue."

    let store: NativeScheduleStore
    let now: @Sendable () -> Date
    let grace: TimeInterval
    let downtime: TimeInterval
    let catchUp: TimeInterval
    let lookup: @Sendable (NativeScheduleRun) -> NativeScheduleTaskLink?
    let fire: @Sendable (NativeSchedule, NativeScheduleRun, NativeScheduleBind) async -> NativeScheduleFireResult
    private var firing: Set<String> = []

    init(store: NativeScheduleStore, now: @escaping @Sendable () -> Date = { Date() },
         grace: TimeInterval = NativeScheduler.defaultGrace, downtime: TimeInterval = NativeScheduler.defaultDowntime,
         catchUp: TimeInterval = NativeScheduler.defaultCatchUp,
         lookup: @escaping @Sendable (NativeScheduleRun) -> NativeScheduleTaskLink?,
         fire: @escaping @Sendable (NativeSchedule, NativeScheduleRun, NativeScheduleBind) async -> NativeScheduleFireResult) {
        self.store = store
        self.now = now
        self.grace = grace
        self.downtime = downtime
        self.catchUp = catchUp
        self.lookup = lookup
        self.fire = fire
    }

    @discardableResult
    func tick() async -> Bool {
        let tickStart = now()
        let savedHeartbeat: Date? = (try? store.heartbeat()) ?? nil
        let baseline = savedHeartbeat ?? tickStart
        var changed = settleRuns()
        var committed = true
        var verified = tickStart
        var passes = 0
        while true {
            verified = now()
            guard let due = try? store.due(at: verified) else { return changed }
            if due.isEmpty { break }
            let pending = due.filter { !firing.contains($0.id) }
            passes += 1
            if pending.isEmpty || passes > 8 {
                committed = false
                break
            }
            for schedule in pending {
                guard let scheduledFor = schedule.nextRunAt else { continue }
                let moment = now()
                guard scheduledFor <= moment else { continue }
                let offlineSince: Date? = moment.timeIntervalSince(baseline) > downtime ? baseline : nil
                var occurrences = [scheduledFor]
                var cursor = scheduledFor
                while let following = schedule.cadence.nextRun(after: cursor, previous: cursor, timeZone: schedule.timeZone), following <= moment {
                    occurrences.append(following)
                    cursor = following
                }
                let last = occurrences[occurrences.count - 1]
                let late = moment.timeIntervalSince(last)
                let offline = savedHeartbeat == nil ? late > grace : (offlineSince.map { last > $0 } ?? false)
                let lastMissed = late > grace || offline
                let catchingUp = lastMissed && late <= catchUp
                var next = schedule
                next.advance(after: moment, from: last)
                let recordedMissed = lastMissed && !catchingUp ? occurrences : Array(occurrences.dropLast())
                var records = missedRuns(schedule.id, occurrences: recordedMissed, at: moment)
                var starting: NativeScheduleRun?
                if !lastMissed || catchingUp {
                    if hasActiveRun(schedule.id) {
                        records.append(NativeScheduleRun(scheduleID: schedule.id, scheduledFor: last, finishedAt: moment, outcome: .skipped,
                                                         detail: "The previous run was still going."))
                    } else {
                        var run = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: last, startedAt: moment, outcome: .running)
                        if catchingUp && offline {
                            run.detail = Self.caughtUpNote
                        } else if late >= 60 {
                            let minutes = Int(late / 60)
                            run.detail = "Started \(minutes) \(minutes == 1 ? "minute" : "minutes") after the scheduled time."
                        }
                        records.append(run)
                        starting = run
                    }
                }
                let claimed: Bool
                do {
                    claimed = try store.claim(schedule.id, expectedNextRunAt: scheduledFor, nextRunAt: next.nextRunAt, enabled: next.enabled,
                                              recording: records)
                } catch {
                    committed = false
                    continue
                }
                guard claimed else { continue }
                changed = true
                if let starting { await start(schedule, run: starting) }
            }
        }
        if committed { try? store.recordHeartbeat(verified) }
        return changed
    }

    func runNow(_ id: String) async -> NativeScheduleRun? {
        guard let schedule = try? store.get(id), !firing.contains(id), !hasActiveRun(id) else { return nil }
        let run = NativeScheduleRun(scheduleID: id, scheduledFor: now(), startedAt: now(), outcome: .running)
        guard (try? store.saveRun(run)) != nil else { return nil }
        return await start(schedule, run: run)
    }

    private func missedRuns(_ scheduleID: String, occurrences: [Date], at moment: Date) -> [NativeScheduleRun] {
        guard !occurrences.isEmpty else { return [] }
        let overflow = max(0, occurrences.count - Self.missedHistoryCap)
        var runs: [NativeScheduleRun] = []
        for (index, occurrence) in occurrences.enumerated() where index >= overflow {
            var detail = Self.missedNote
            if overflow > 0 && index == overflow {
                detail = "\(overflow) earlier \(overflow == 1 ? "run was" : "runs were") also missed while Tandem wasn't running."
            }
            runs.append(NativeScheduleRun(scheduleID: scheduleID, scheduledFor: occurrence, finishedAt: moment, outcome: .missed, detail: detail))
        }
        return runs
    }

    private func bind(_ runID: String, conversationID: String, messageID: String) {
        guard var run = try? store.run(runID) else { return }
        run.conversationID = conversationID
        run.messageID = messageID
        try? store.saveRun(run)
    }

    @discardableResult
    private func start(_ schedule: NativeSchedule, run: NativeScheduleRun) async -> NativeScheduleRun? {
        firing.insert(schedule.id)
        defer { firing.remove(schedule.id) }
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
            saved.detail = CompanionSavedText.sanitized(reason)
            saved.finishedAt = now()
        case .skipped(let reason):
            saved.outcome = .skipped
            saved.detail = reason
            saved.finishedAt = now()
        }
        try? store.saveRun(saved)
        return saved
    }

    private func hasActiveRun(_ scheduleID: String) -> Bool {
        ((try? store.runningRuns()) ?? []).contains { $0.scheduleID == scheduleID }
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
            case .active:
                guard run.outcome != .running else { continue }
                run.outcome = .running
                run.detail = "Picked up again."
                try? store.saveRun(run)
                changed = true
                continue
            case .waiting(let prompt):
                guard run.outcome != .waiting || run.detail != prompt else { continue }
                run.outcome = .waiting
                run.detail = prompt
                try? store.saveRun(run)
                changed = true
                continue
            case .blocked(let message):
                guard run.outcome != .blocked || run.detail != message else { continue }
                run.outcome = .blocked
                run.detail = message
                try? store.saveRun(run)
                changed = true
                continue
            case .completed: outcome = .completed
            case .failed: outcome = .failed
            case .stopped: outcome = .stopped
            }
            run.outcome = outcome
            let moment = now()
            let ended = link.endedAt.flatMap { (ended: Date) -> Date? in
                ended <= moment && ended >= (run.startedAt ?? run.scheduledFor) ? ended : nil
            }
            run.finishedAt = ended ?? moment
            try? store.saveRun(run)
            changed = true
        }
        return changed
    }
}
