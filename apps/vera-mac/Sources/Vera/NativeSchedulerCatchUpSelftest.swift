import Foundation
import GRDB

private struct CatchUpFixture {
    let repository: LocalChatRepository
    let store: NativeScheduleStore
    let clock: NativeSchedulerClock
    let log: NativeSchedulerFireLog
    let scheduler: NativeScheduler

    init(start: Date, window: TimeInterval = NativeScheduler.defaultCatchUp, repository: LocalChatRepository? = nil) throws {
        let repository = try repository ?? LocalChatRepository(inMemory: true)
        let store = NativeScheduleStore(database: repository.database)
        let clock = NativeSchedulerClock(start)
        let log = NativeSchedulerFireLog()
        self.repository = repository
        self.store = store
        self.clock = clock
        self.log = log
        scheduler = NativeScheduler(store: store, now: { clock.now }, grace: 300, downtime: 60, catchUp: window,
                                    lookup: { run in log.link(run) },
                                    fire: { schedule, run, bind in
                                        await bind("conversation", "message")
                                        return log.record(schedule, run)
                                    })
    }

    func schedule(_ cadence: NativeScheduleCadence, next: Date, zone: TimeZone, owner: NativeScheduleOwner = .conversation,
                  workerType: String = "research") throws -> NativeSchedule {
        let schedule = try NativeSchedule(owner: owner, workerType: workerType, title: "Catch-up check", instruction: "Look into the fictional moon",
                                          cadence: cadence, timeZone: zone, nextRunAt: next)
        try store.save(schedule)
        return schedule
    }

    func closed(from start: Date, until end: Date) throws {
        try store.recordHeartbeat(start)
        clock.set(end)
    }

    func runs(_ id: String) throws -> [NativeScheduleRun] {
        try store.runs(scheduleID: id, limit: 100).sorted { $0.scheduledFor < $1.scheduledFor }
    }
}

private final class CatchUpPeak: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var peak = 0
    private(set) var samples = 0

    func note(_ running: Int) {
        lock.lock(); defer { lock.unlock() }
        peak = max(peak, running)
        samples += 1
    }
}

@MainActor
extension SelfTest {
    static func runNativeSchedulerCatchUp() async throws {
        let require = NativeTaskFixture.require
        let zone = TimeZone(identifier: "America/Chicago")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
        }
        let window = NativeScheduler.defaultCatchUp
        let oldSentence = "It will run next time" + " as planned"

        try require(NativeScheduler.missedNote == "Tandem wasn't running at the scheduled time.", "The missed note is the one plain sentence")
        try require(NativeScheduler.caughtUpNote == "Caught up after Tandem wasn't running at the scheduled time.", "The caught up note is the agreed sentence")
        try require(window == 86_400, "The catch-up window is a day")

        let daily = try CatchUpFixture(start: at(19, 6))
        let morning = try daily.schedule(.daily(minuteOfDay: 7 * 60), next: at(19, 7), zone: zone)
        try daily.closed(from: at(19, 6), until: at(19, 9))
        _ = await daily.scheduler.tick()
        var runs = try daily.runs(morning.id)
        try require(daily.log.count == 1 && daily.log.fired[0].scheduledFor == at(19, 7), "A daily run missed while closed starts once for its time")
        try require(runs.count == 1 && runs[0].scheduledFor == at(19, 7) && runs[0].outcome == .running && runs[0].startedAt == at(19, 9)
                    && runs[0].detail == NativeScheduler.caughtUpNote && runs[0].taskReferenceID == "reference-1",
                    "The caught up run is recorded running with the caught up note: \(runs.map(\.detail))")
        try require(try daily.store.get(morning.id)?.nextRunAt == at(20, 7), "The schedule moves on to tomorrow at 7:00")
        try require(daily.log.origins.count == 1 && daily.log.origins[0]?.scheduleID == morning.id && daily.log.origins[0]?.unattended == true,
                    "A caught up run starts work that carries its schedule, so it is read-only")

        daily.clock.advance(60)
        _ = await daily.scheduler.tick()
        try require(daily.log.count == 1 && (try daily.runs(morning.id)).count == 1, "The next tick starts nothing for the same miss")
        let relaunch = NativeSchedulerFireLog()
        let relaunched = NativeScheduler(store: daily.store, now: { daily.clock.now }, grace: 300, downtime: 60,
                                         lookup: { run in relaunch.link(run) },
                                         fire: { schedule, run, _ in relaunch.record(schedule, run) })
        _ = await relaunched.tick()
        daily.clock.advance(3600)
        _ = await relaunched.tick()
        runs = try daily.runs(morning.id)
        try require(relaunch.count == 0 && runs.count == 1 && runs[0].detail == NativeScheduler.caughtUpNote,
                    "A relaunched scheduler on the same history starts nothing new for the same misses")

        let hourly = try CatchUpFixture(start: at(19, 3, 30))
        let hours = try hourly.schedule(.everyHours(1), next: at(19, 4), zone: zone)
        try hourly.closed(from: at(19, 3, 30), until: at(19, 8, 30))
        _ = await hourly.scheduler.tick()
        runs = try hourly.runs(hours.id)
        try require(hourly.log.count == 1 && hourly.log.fired[0].scheduledFor == at(19, 8), "Five missed hours start one run for the latest")
        try require(runs.count == 5 && runs.prefix(4).map(\.scheduledFor) == [at(19, 4), at(19, 5), at(19, 6), at(19, 7)]
                    && runs.prefix(4).allSatisfy { $0.outcome == .missed && $0.detail == NativeScheduler.missedNote },
                    "The four earlier hours are recorded missed with the missed note: \(runs.map(\.detail))")
        try require(runs[4].scheduledFor == at(19, 8) && runs[4].outcome == .running && runs[4].detail == NativeScheduler.caughtUpNote,
                    "The latest hour carries the caught up note")
        try require(try hourly.store.get(hours.id)?.nextRunAt == at(19, 9), "The hourly schedule moves on to 9:00")
        _ = await hourly.scheduler.tick()
        try require(hourly.log.count == 1 && (try hourly.runs(hours.id)).count == 5, "A second tick straight after starts nothing")

        let long = try CatchUpFixture(start: at(19, 6))
        let longDaily = try long.schedule(.daily(minuteOfDay: 7 * 60), next: at(19, 7), zone: zone)
        try long.closed(from: at(19, 6), until: at(20, 12))
        _ = await long.scheduler.tick()
        runs = try long.runs(longDaily.id)
        try require(long.log.count == 1 && long.log.fired[0].scheduledFor == at(20, 7), "Thirty hours closed runs the time missed inside the day")
        try require(runs.count == 2 && runs[0].scheduledFor == at(19, 7) && runs[0].outcome == .missed && runs[0].detail == NativeScheduler.missedNote
                    && runs[1].scheduledFor == at(20, 7) && runs[1].detail == NativeScheduler.caughtUpNote,
                    "The earlier time is missed and the later one caught up")
        try require(try long.store.get(longDaily.id)?.nextRunAt == at(21, 7), "The schedule moves on to the next morning")

        let weekly = try CatchUpFixture(start: at(19, 8))
        let week = try weekly.schedule(.weekly(weekday: 2, minuteOfDay: 9 * 60), next: at(19, 9), zone: zone)
        try weekly.closed(from: at(19, 8), until: at(21, 9))
        _ = await weekly.scheduler.tick()
        runs = try weekly.runs(week.id)
        try require(weekly.log.count == 0 && runs.count == 1 && runs[0].scheduledFor == at(19, 9) && runs[0].outcome == .missed
                    && runs[0].detail == NativeScheduler.missedNote, "A weekly miss two days old is recorded missed and nothing starts")
        try require(try weekly.store.get(week.id)?.nextRunAt == at(26, 9), "The weekly schedule moves on to next Monday")

        for (offset, catches) in [(window, true), (window + 1, false)] {
            let edge = try CatchUpFixture(start: at(19, 8))
            let edgeWeek = try edge.schedule(.weekly(weekday: 2, minuteOfDay: 9 * 60), next: at(19, 9), zone: zone)
            try edge.closed(from: at(19, 8), until: at(19, 9).addingTimeInterval(offset))
            _ = await edge.scheduler.tick()
            let edgeRuns = try edge.runs(edgeWeek.id)
            try require(edge.log.count == (catches ? 1 : 0) && edgeRuns.count == 1
                        && edgeRuns[0].outcome == (catches ? .running : .missed)
                        && edgeRuns[0].detail == (catches ? NativeScheduler.caughtUpNote : NativeScheduler.missedNote),
                        "A miss \(Int(offset)) seconds old \(catches ? "catches up" : "is only recorded missed"): \(edgeRuns.map(\.detail))")
        }
        let narrow = try CatchUpFixture(start: at(19, 6), window: 3600)
        let narrowDaily = try narrow.schedule(.daily(minuteOfDay: 7 * 60), next: at(19, 7), zone: zone)
        try narrow.closed(from: at(19, 6), until: at(19, 9))
        _ = await narrow.scheduler.tick()
        try require(narrow.log.count == 0 && (try narrow.runs(narrowDaily.id)).first?.outcome == .missed, "The window comes from the initialiser")

        let asleep = try CatchUpFixture(start: at(19, 6, 58))
        let asleepDaily = try asleep.schedule(.daily(minuteOfDay: 7 * 60), next: at(19, 7), zone: zone)
        _ = await asleep.scheduler.tick()
        try require(try asleep.store.heartbeat() == at(19, 6, 58), "The open app keeps its heartbeat")
        asleep.clock.set(at(19, 7, 2))
        _ = await asleep.scheduler.tick()
        runs = try asleep.runs(asleepDaily.id)
        try require(asleep.log.count == 1 && runs.count == 1 && runs[0].outcome == .running && runs[0].detail == NativeScheduler.caughtUpNote,
                    "A time that passed while the Mac slept with the app open catches up, even inside the grace window")
        let slept = try CatchUpFixture(start: at(19, 6))
        let sleptDaily = try slept.schedule(.daily(minuteOfDay: 7 * 60), next: at(19, 7), zone: zone)
        _ = await slept.scheduler.tick()
        slept.clock.set(at(19, 9))
        _ = await slept.scheduler.tick()
        runs = try slept.runs(sleptDaily.id)
        try require(slept.log.count == 1 && runs.count == 1 && runs[0].detail == NativeScheduler.caughtUpNote,
                    "A long sleep with the app open is treated like the app being closed")

        for (late, note) in [(TimeInterval(30), ""), (TimeInterval(120), "Started 2 minutes after the scheduled time.")] {
            let running = try CatchUpFixture(start: at(19, 7))
            let onTime = try running.schedule(.daily(minuteOfDay: 7 * 60), next: at(19, 7), zone: zone)
            try running.store.recordHeartbeat(at(19, 7).addingTimeInterval(late - 30))
            running.clock.set(at(19, 7).addingTimeInterval(late))
            _ = await running.scheduler.tick()
            let lateRuns = try running.runs(onTime.id)
            try require(running.log.count == 1 && lateRuns.count == 1 && lateRuns[0].outcome == .running && lateRuns[0].detail == note,
                        "A run \(Int(late)) seconds late with the app running is a normal run: \(lateRuns.map(\.detail))")
        }
        let stale = try CatchUpFixture(start: at(19, 7))
        let staleDaily = try stale.schedule(.daily(minuteOfDay: 7 * 60), next: at(19, 7), zone: zone)
        try stale.store.recordHeartbeat(at(19, 7, 9, 30))
        stale.clock.set(at(19, 7, 10))
        _ = await stale.scheduler.tick()
        runs = try stale.runs(staleDaily.id)
        try require(stale.log.count == 1 && runs.count == 1 && runs[0].outcome == .running
                        && runs[0].detail == "Started 10 minutes after the scheduled time.",
                    "A run later than the grace window while Tandem was running still runs, and says how late it started, not that Tandem wasn't running: \(runs.map(\.detail))")

        let fresh = try CatchUpFixture(start: at(19, 9))
        let freshDaily = try fresh.schedule(.daily(minuteOfDay: 7 * 60), next: at(19, 7), zone: zone)
        try require(try fresh.store.heartbeat() == nil, "The first-launch fixture has no record of when Tandem last ran")
        _ = await fresh.scheduler.tick()
        runs = try fresh.runs(freshDaily.id)
        try require(fresh.log.count == 1 && runs.count == 1 && runs[0].outcome == .running && runs[0].detail == NativeScheduler.caughtUpNote,
                    "With no record of when Tandem last ran, a run two hours late catches up with the caught up note: \(runs.map(\.detail))")
        let freshOnTime = try CatchUpFixture(start: at(19, 7, 2))
        let freshPrompt = try freshOnTime.schedule(.daily(minuteOfDay: 7 * 60), next: at(19, 7), zone: zone)
        _ = await freshOnTime.scheduler.tick()
        runs = try freshOnTime.runs(freshPrompt.id)
        try require(freshOnTime.log.count == 1 && runs.count == 1 && runs[0].detail == "Started 2 minutes after the scheduled time.",
                    "With no record and a run inside the grace window, it is a normal run: \(runs.map(\.detail))")

        let asking = try CatchUpFixture(start: at(19, 3, 30))
        let askingHours = try asking.schedule(.everyHours(1), next: at(19, 4), zone: zone)
        try asking.store.saveRun(NativeScheduleRun(scheduleID: askingHours.id, scheduledFor: at(19, 3), startedAt: at(19, 3), outcome: .waiting,
                                                   detail: "Retry this step?", taskReferenceID: "reference-asking"))
        asking.log.status = .waiting("Retry this step?")
        try asking.closed(from: at(19, 3, 30), until: at(19, 6, 30))
        _ = await asking.scheduler.tick()
        runs = try asking.runs(askingHours.id).filter { $0.scheduledFor >= at(19, 4) }
        try require(asking.log.count == 1 && runs.count == 3 && runs[0].outcome == .missed && runs[1].outcome == .missed
                        && runs[2].scheduledFor == at(19, 6) && runs[2].outcome == .running && runs[2].detail == NativeScheduler.caughtUpNote,
                    "An earlier run waiting on a question does not stop the next occurrence, on time or caught up: \(runs.map(\.detail))")

        for (label, ended, expected) in [("its own end time", at(19, 9, 4), at(19, 9, 4)),
                                         ("no end time", Date?.none, at(20, 10)),
                                         ("an end time after now", at(21, 0), at(20, 10)),
                                         ("an end time before it started", at(19, 8), at(20, 10))] as [(String, Date?, Date)] {
            let ending = try CatchUpFixture(start: at(19, 9))
            let endingDaily = try ending.schedule(.weekly(weekday: 2, minuteOfDay: 7 * 60), next: at(26, 7), zone: zone)
            try ending.store.saveRun(NativeScheduleRun(scheduleID: endingDaily.id, scheduledFor: at(19, 7), startedAt: at(19, 9), outcome: .running,
                                                       detail: NativeScheduler.caughtUpNote, taskReferenceID: "reference-ending"))
            ending.log.status = .completed
            ending.log.endedAt = ended
            try ending.closed(from: at(19, 9, 1), until: at(20, 10))
            _ = await ending.scheduler.tick()
            let settled = try ending.runs(endingDaily.id).first { $0.scheduledFor == at(19, 7) }
            try require(settled?.outcome == .completed && settled?.finishedAt == expected && settled?.happenedAt == expected,
                        "A run noticed as finished after a relaunch is given \(label): \(String(describing: settled?.finishedAt))")
        }

        let retired = NativeScheduler.missedNote + " " + oldSentence + "."
        try require(NativeScheduler.retiredMissedNote == retired && NativeScheduler.shownNote(retired) == NativeScheduler.missedNote,
                    "A missed row saved before this change shows the current missed note")
        for other in [NativeScheduler.missedNote, NativeScheduler.caughtUpNote, "The model said: " + retired, retired + " ", ""] {
            try require(NativeScheduler.shownNote(other) == other, "Any other saved note is shown as saved: \(other)")
        }

        let busy = try CatchUpFixture(start: at(19, 3, 30))
        let busyHours = try busy.schedule(.everyHours(1), next: at(19, 4), zone: zone)
        try busy.store.saveRun(NativeScheduleRun(scheduleID: busyHours.id, scheduledFor: at(19, 3), startedAt: at(19, 3), outcome: .running,
                                                 taskReferenceID: "reference-busy"))
        try busy.closed(from: at(19, 3, 30), until: at(19, 6, 30))
        _ = await busy.scheduler.tick()
        runs = try busy.runs(busyHours.id).filter { $0.scheduledFor >= at(19, 4) }
        try require(busy.log.count == 0, "No catch-up starts while the schedule's run is still going")
        try require(runs.count == 3 && runs[0].outcome == .missed && runs[1].outcome == .missed
                    && runs[0].detail == NativeScheduler.missedNote && runs[1].detail == NativeScheduler.missedNote
                    && runs[2].scheduledFor == at(19, 6) && runs[2].outcome == .skipped && runs[2].detail == "The previous run was still going.",
                    "The latest time is skipped as still going and the earlier ones missed: \(runs.map(\.detail))")
        try require(try busy.store.get(busyHours.id)?.nextRunAt == at(19, 7), "The busy schedule moves on")

        for (closedFor, catches) in [(TimeInterval(2 * 3600), true), (TimeInterval(25 * 3600), false)] {
            let single = try CatchUpFixture(start: at(19, 8))
            let once = try single.schedule(.once(at(19, 9)), next: at(19, 9), zone: zone, workerType: "document")
            try single.closed(from: at(19, 8), until: at(19, 9).addingTimeInterval(closedFor))
            _ = await single.scheduler.tick()
            let onceRuns = try single.runs(once.id)
            let finished = try single.store.get(once.id)
            try require(single.log.count == (catches ? 1 : 0) && onceRuns.count == 1
                        && onceRuns[0].detail == (catches ? NativeScheduler.caughtUpNote : NativeScheduler.missedNote),
                        "A one-time schedule missed by \(Int(closedFor / 3600)) hours \(catches ? "runs once" : "is recorded missed")")
            try require(finished?.enabled == false && finished?.nextRunAt == nil, "The one-time schedule is finished either way")
        }

        try await catchUpPausedCompanion(require, zone: zone, at: at)
        try await catchUpManySchedules(require, zone: zone, at: at)
        try catchUpEngineClaim(require)
        try catchUpStrings(require, oldSentence: oldSentence)
        let due = at(19, 7)
        let ran = at(19, 9, 40)
        let late = NativeScheduleRun(scheduleID: "happened", scheduledFor: due, startedAt: ran, finishedAt: ran.addingTimeInterval(240),
                                     outcome: .completed, detail: NativeScheduler.caughtUpNote)
        var going = late
        going.outcome = .running
        going.finishedAt = nil
        try require(late.happenedAt == ran.addingTimeInterval(240) && going.happenedAt == ran,
                    "A run that happened shows when it finished, or when it started while it is still going, not its scheduled time")
        for outcome in [NativeScheduleOutcome.missed, .skipped, .couldNotStart] {
            let never = NativeScheduleRun(scheduleID: "happened", scheduledFor: due, finishedAt: ran, outcome: outcome)
            try require(never.happenedAt == due, "A run that never ran shows the time it was due: \(outcome.rawValue)")
        }
        let bare = NativeScheduleRun(scheduleID: "happened", scheduledFor: due, outcome: .completed)
        try require(bare.happenedAt == due, "An older row with no recorded times falls back to its scheduled time")
        print("  native scheduler catch-up OK (one run per missed schedule inside a day, earlier times missed, boundary, sleep, late while running, still going, relaunch, once, paused companion, five schedules through the engine, read-only, strings)")
    }

    private static func catchUpPausedCompanion(_ require: (Bool, String) throws -> Void, zone: TimeZone, at: (Int, Int, Int, Int) -> Date) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catch-up-paused-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try LocalChatRepository(url: folder.appendingPathComponent("vera.sqlite"))
        let live = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                             artifactPersistenceEnabled: false)
        await live.connect()
        live.nativeSchedulerLoop?.cancel()
        await live.nativeSchedulerLoop?.value
        live.nativeSchedulerLoop = nil
        live.skipDotSetup()
        guard let store = live.nativeScheduleStore else { throw NativeTaskFixture.Failure.assertion("The live store has a schedule store") }
        let schedule = try NativeSchedule(owner: .dot, workerType: "research", title: "Paused check", instruction: "Check the beds.",
                                          cadence: .daily(minuteOfDay: 7 * 60), timeZone: zone, nextRunAt: at(19, 7, 0, 0))
        try store.save(schedule)
        live.setDotState(.paused)
        let clock = NativeSchedulerClock(at(19, 9, 0, 0))
        try store.recordHeartbeat(at(19, 6, 0, 0))
        let scheduler = NativeScheduler(store: store, now: { clock.now }, lookup: { _ in nil },
                                        fire: { [weak live] schedule, run, bind in
                                            guard let live else { return .failed("Tandem is closing.") }
                                            return await live.fireSchedule(schedule, run: run, bind: bind)
                                        })
        _ = await scheduler.tick()
        let runs = try store.runs(scheduleID: schedule.id)
        try require(runs.count == 1 && runs[0].scheduledFor == at(19, 7, 0, 0) && runs[0].outcome == .skipped
                    && runs[0].detail == CompanionSavedText.marker + " is paused.",
                    "A missed companion run inside the window does not run while paused and keeps the paused note: \(runs.map(\.detail))")
        try require(!runs.contains { $0.detail == NativeScheduler.caughtUpNote }, "Nothing says a paused run was caught up")
        try require(try store.get(schedule.id)?.nextRunAt == at(20, 7, 0, 0), "The paused schedule moves on")
        live.stopNativeTaskRecovery()
    }

    private static func catchUpManySchedules(_ require: (Bool, String) throws -> Void, zone: TimeZone, at: (Int, Int, Int, Int) -> Date) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("chat.sqlite"))
        let config = NativeChatConfig(baseURL: URL(string: "https://fixture.invalid/v1")!, apiKey: nil, model: "fixture", chatTemplateKwargs: nil)
        let live = ChatStore(nativeConfig: config, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                             nativeSearchAvailable: { true }, artifactPersistenceEnabled: false)
        await live.connect()
        live.nativeSchedulerLoop?.cancel()
        await live.nativeSchedulerLoop?.value
        live.nativeSchedulerLoop = nil
        defer { live.stopNativeTaskRecovery() }
        guard let engine = live.nativeTaskLocalEngine, let store = live.nativeScheduleStore else {
            throw NativeTaskFixture.Failure.assertion("The store runs the local engine and keeps schedules")
        }
        var schedules: [NativeSchedule] = []
        for index in 0..<5 {
            let schedule = try NativeSchedule(owner: .conversation, workerType: "document", title: "Digest \(index + 1)",
                                              instruction: "Write a short note about the fictional moon Luma",
                                              cadence: .daily(minuteOfDay: 7 * 60 + index * 10), timeZone: zone,
                                              nextRunAt: at(19, 7, index * 10, 0))
            try store.save(schedule)
            schedules.append(schedule)
        }
        let clock = NativeSchedulerClock(at(19, 11, 0, 0))
        try store.recordHeartbeat(at(19, 6, 0, 0))
        let sampled = CatchUpPeak()
        let database = repository.database
        @Sendable func sample() async {
            let running = (try? await database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_engine_tasks WHERE state = 'running'") ?? 0
            }) ?? 0
            sampled.note(running)
        }
        func scheduler() -> NativeScheduler {
            NativeScheduler(store: store, now: { clock.now }, lookup: { _ in nil },
                            fire: { [weak live] schedule, run, bind in
                                guard let live else { return .failed("Tandem is closing.") }
                                await sample()
                                let result = await live.fireSchedule(schedule, run: run, bind: bind)
                                await sample()
                                return result
                            })
        }
        let first = scheduler()
        _ = await first.tick()
        var taskIDs: [String: String] = [:]
        for schedule in schedules {
            let runs = try store.runs(scheduleID: schedule.id)
            try require(runs.count == 1 && runs[0].scheduledFor == schedule.nextRunAt && runs[0].detail == NativeScheduler.caughtUpNote
                        && runs[0].taskReferenceID != nil,
                        "\(schedule.title) gets exactly one caught up run that reached the engine: \(runs.map { "\($0.outcome) \($0.detail)" })")
            guard let id = runs[0].taskReferenceID, let uuid = UUID(uuidString: id), let reference = try repository.taskReference(id: uuid),
                  let taskID = reference.remoteTaskID else { throw NativeTaskFixture.Failure.assertion("\(schedule.title) has an engine task") }
            taskIDs[schedule.id] = taskID
            let origin = NativeRunOrigin(payload: try engine.store.get(taskID).payload)
            try require(origin.scheduleID == schedule.id && origin.unattended, "\(schedule.title)'s caught up task carries its schedule, so it is read-only")
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            await sample()
            let queued = try await repository.database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_engine_tasks WHERE state IN ('queued', 'running')") ?? 0
            }
            if queued == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(sampled.peak <= 1 && sampled.samples >= 10,
                    "The engine never holds more than one running task while the caught up runs proceed: peak \(sampled.peak) over \(sampled.samples) samples")

        let second = scheduler()
        _ = await second.tick()
        for schedule in schedules {
            try require(try store.runs(scheduleID: schedule.id).count == 1, "\(schedule.title) gets no second catch-up after a relaunch")
        }

        let target = schedules[0]
        guard let advanced = try store.get(target.id), let onTime = advanced.nextRunAt else {
            throw NativeTaskFixture.Failure.assertion("The first schedule has a next time")
        }
        try store.recordHeartbeat(onTime.addingTimeInterval(-20))
        clock.set(onTime.addingTimeInterval(20))
        let normal = scheduler()
        _ = await normal.tick()
        let normalRun = try store.runs(scheduleID: target.id).first { $0.scheduledFor == onTime }
        guard let normalID = normalRun?.taskReferenceID, let uuid = UUID(uuidString: normalID), let reference = try repository.taskReference(id: uuid),
              let normalTask = reference.remoteTaskID, let caughtUpTask = taskIDs[target.id] else {
            throw NativeTaskFixture.Failure.assertion("The on-time run reached the engine: \(String(describing: normalRun))")
        }
        try require(normalRun?.detail == "", "The on-time run carries no catch-up note")
        let caughtUpPayload = try engine.store.get(caughtUpTask).payload
        let normalPayload = try engine.store.get(normalTask).payload
        try require(NativeRunOrigin(payload: caughtUpPayload) == NativeRunOrigin(payload: normalPayload)
                    && NativeRunOrigin(payload: caughtUpPayload).unattended,
                    "A caught up run and an on-time run of the same schedule start work held to read-only the same way")
        try require(caughtUpPayload == normalPayload, "The caught up task's request is the same request an on-time run submits")
    }

    private static func catchUpEngineClaim(_ require: (Bool, String) throws -> Void) throws {
        let repository = try LocalChatRepository(inMemory: true)
        let tasks = NativeTaskStore(database: repository.database)
        let payload = try NativeTaskStore.canonical(["query": "Luma"])
        for index in 0..<5 {
            _ = try tasks.create(workerType: "document", payload: payload, idempotencyKey: "catch-up-\(index)")
        }
        guard let first = try tasks.claim(workerTypes: ["document"]) else { throw NativeTaskFixture.Failure.assertion("The first queued task is claimed") }
        try require(try tasks.claim(workerTypes: ["document"]) == nil, "A second claim waits while one task is running")
        _ = try tasks.commitStep(first.id, generation: first.generation,
                                 step: NativeTaskStepResult(state: .completed, result: try NativeTaskStore.canonical(["done": true]), event: "completed"))
        let next = try tasks.claim(workerTypes: ["document"])
        try require(next != nil && next?.id != first.id, "The next task is claimed once the first finishes")
        try require(try tasks.claim(workerTypes: ["document"]) == nil, "Still only one at a time")
    }

    private static func catchUpStrings(_ require: (Bool, String) throws -> Void, oldSentence: String) throws {
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil)
        for caughtUp in [false, true] {
            NativeScheduleShotFixture.populate(store, caughtUp: caughtUp)
            let details = store.scheduleRuns.values.flatMap { $0 }.map(\.detail)
            try require(!details.contains { $0.contains(oldSentence) }, "No fixture run says the old missed sentence")
            try require(!caughtUp || (details.contains(NativeScheduler.caughtUpNote) && details.contains(NativeScheduler.missedNote)),
                        "The caught up fixture shows a caught up run and a missed run")
        }
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let view = try String(contentsOf: sources.appendingPathComponent("ScheduledView.swift"), encoding: .utf8)
        try require(view.contains("CompanionNamedText(template: \"Work {name} runs on a schedule while Tandem is open or in the menu bar.\")"),
                    "The Scheduled header text is unchanged")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let allowed = file.lastPathComponent == "NativeScheduler.swift" ? 1 : 0
            try require(text.components(separatedBy: oldSentence).count - 1 == allowed,
                        "\(file.lastPathComponent) carries the old missed sentence only where saved rows from before are recognised")
        }
        let setup = sources.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/SETUP.md")
        let docs = try String(contentsOf: setup, encoding: .utf8)
        try require(!docs.contains(oldSentence) && !docs.contains("is never caught up"), "The setup guide no longer says missed runs are never caught up")
    }
}
