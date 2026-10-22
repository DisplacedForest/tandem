import Foundation
import GRDB

private final class NativeSchedulerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}

private final class NativeSchedulerFireLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var fired: [(schedule: String, scheduledFor: Date)] = []
    var result: NativeScheduleFireResult = .started(conversationID: "c", messageID: "m", taskReferenceID: UUID().uuidString)
    var status: NativeScheduleTaskStatus = .active

    func record(_ schedule: NativeSchedule, _ run: NativeScheduleRun) -> NativeScheduleFireResult {
        lock.lock(); defer { lock.unlock() }
        fired.append((schedule.id, run.scheduledFor))
        return result
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return fired.count
    }
}

@MainActor
extension SelfTest {
    static func runNativeScheduler() async throws {
        let require = NativeTaskFixture.require
        let zone = TimeZone(identifier: "America/Chicago")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 6, minute: 30))!
        try require(calendar.component(.weekday, from: monday) == 2, "The fixture anchor is a Monday")

        let daily = NativeScheduleCadence.daily(minuteOfDay: 7 * 60)
        let dailyNext = daily.nextRun(after: monday, previous: nil, timeZone: zone)!
        try require(calendar.dateComponents([.day, .hour, .minute], from: dailyNext) == DateComponents(day: 19, hour: 7, minute: 0), "Daily fires later the same day when the time is ahead")
        let dailyAfter = daily.nextRun(after: dailyNext, previous: dailyNext, timeZone: zone)!
        try require(calendar.component(.day, from: dailyAfter) == 20, "Daily advances to tomorrow after firing")
        let friday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 9, minute: 0))!
        let weekdays = NativeScheduleCadence.weekdays(minuteOfDay: 8 * 60)
        let weekdayNext = weekdays.nextRun(after: friday, previous: nil, timeZone: zone)!
        try require(calendar.component(.weekday, from: weekdayNext) == 2 && calendar.component(.day, from: weekdayNext) == 26, "Weekdays skip the weekend")
        let weekly = NativeScheduleCadence.weekly(weekday: 4, minuteOfDay: 15 * 60 + 30)
        let weeklyNext = weekly.nextRun(after: monday, previous: nil, timeZone: zone)!
        try require(calendar.component(.weekday, from: weeklyNext) == 4 && calendar.component(.hour, from: weeklyNext) == 15, "Weekly lands on the chosen day and time")
        let hourly = NativeScheduleCadence.everyHours(6)
        let anchor = monday.addingTimeInterval(-20 * 3600)
        let hourlyNext = hourly.nextRun(after: monday, previous: anchor, timeZone: zone)!
        try require(hourlyNext == anchor.addingTimeInterval(24 * 3600), "Every N hours keeps its phase and lands strictly ahead of now")
        try require(NativeScheduleCadence.once(monday).nextRun(after: monday, previous: nil, timeZone: zone) == nil, "A passed one-time cadence has no next run")
        let utc = TimeZone(identifier: "UTC")!
        let utcNext = daily.nextRun(after: monday, previous: nil, timeZone: utc)!
        try require(utcNext != dailyNext && Calendar(identifier: .gregorian).dateComponents(in: utc, from: utcNext).hour == 7, "The recorded time zone drives the clock time")

        let summaries = [daily.summary(timeZone: zone), weekdays.summary(timeZone: zone), weekly.summary(timeZone: zone),
                         hourly.summary(timeZone: zone), NativeScheduleCadence.everyHours(1).summary(timeZone: zone),
                         NativeScheduleCadence.once(monday).summary(timeZone: zone)]
        try require(summaries[0].hasPrefix("Every day at ") && summaries[1].hasPrefix("Weekdays at ") && summaries[2].hasPrefix("Every Wednesday at ")
                    && summaries[3] == "Every 6 hours" && summaries[4] == "Every hour" && summaries[5].hasPrefix("Once on Oct 19 at "),
                    "Cadence summaries are plain words: \(summaries)")
        try require(summaries.allSatisfy { !$0.contains("*") && !$0.contains("/") }, "No cron characters in any summary")
        let encoded = try JSONEncoder().encode(weekly)
        try require(try JSONDecoder().decode(NativeScheduleCadence.self, from: encoded) == weekly, "Cadence round-trips through JSON")
        do {
            _ = try NativeSchedule(owner: .dot, workerType: "research", title: "x", instruction: "y", cadence: .everyHours(0), timeZone: zone)
            throw NativeTaskFixture.Failure.assertion("Zero-hour cadence must be rejected")
        } catch is NativeScheduleError {}
        do {
            _ = try NativeSchedule(owner: .dot, workerType: "voice", title: "x", instruction: "y", cadence: daily, timeZone: zone)
            throw NativeTaskFixture.Failure.assertion("Unknown worker types must be rejected")
        } catch is NativeScheduleError {}

        let repository = try LocalChatRepository(inMemory: true)
        let store = NativeScheduleStore(database: repository.database)
        let clock = NativeSchedulerClock(monday)
        let log = NativeSchedulerFireLog()
        let scheduler = NativeScheduler(store: store, now: { clock.now }, grace: 300,
                                        taskStatus: { _ in log.status }, fire: { schedule, run in log.record(schedule, run) })
        var schedule = try NativeSchedule(owner: .conversation, workerType: "research", title: "Morning check",
                                          instruction: "Look into the fictional moon", cadence: daily, timeZone: zone, createdAt: monday)
        schedule.advance(after: monday, from: nil)
        try store.save(schedule)
        try require(try store.get(schedule.id)?.nextRunAt == dailyNext, "The saved schedule keeps its next run")

        try require(await scheduler.tick() == false && log.count == 0, "Nothing fires before its time")
        clock.set(dailyNext.addingTimeInterval(90))
        async let first: Bool = scheduler.tick()
        async let second: Bool = scheduler.tick()
        _ = await (first, second)
        try require(log.count == 1 && log.fired[0].scheduledFor == dailyNext, "A due schedule fires exactly once under concurrent ticks")
        var runs = try store.runs(scheduleID: schedule.id)
        try require(runs.count == 1 && runs[0].outcome == .running && runs[0].taskReferenceID != nil && runs[0].detail.contains("1 minute"),
                    "The run is recorded as running, bound to its task, and says it started a minute late")
        var saved = try store.get(schedule.id)!
        try require(saved.nextRunAt == dailyAfter && saved.lastOutcome == .running && saved.lastRunAt == dailyNext, "The schedule advanced to tomorrow and remembers the run")
        clock.advance(60)
        _ = await scheduler.tick()
        try require(try store.runs(scheduleID: schedule.id)[0].outcome == .running, "An active task keeps the run open")
        log.status = .completed
        _ = await scheduler.tick()
        runs = try store.runs(scheduleID: schedule.id)
        try require(runs[0].outcome == .completed && runs[0].finishedAt == clock.now, "A completed task settles the run as finished")
        try require(try store.get(schedule.id)?.lastOutcome == .completed, "The schedule shows the settled outcome")

        clock.set(dailyAfter.addingTimeInterval(3 * 3600))
        _ = await scheduler.tick()
        runs = try store.runs(scheduleID: schedule.id)
        try require(log.count == 1, "A run whose time passed beyond the grace window never fires")
        try require(runs.count == 2 && runs[0].outcome == .missed && runs[0].scheduledFor == dailyAfter && runs[0].detail.contains("wasn't running"),
                    "The missed run records the scheduled time and says why")
        saved = try store.get(schedule.id)!
        try require(saved.nextRunAt == daily.nextRun(after: clock.now, previous: nil, timeZone: zone) && saved.enabled, "The next run proceeds normally after a miss")

        let third = saved.nextRunAt!
        log.status = .active
        clock.set(third.addingTimeInterval(10))
        _ = await scheduler.tick()
        let againRuns = try store.runs(scheduleID: schedule.id)
        try require(log.count == 2 && againRuns[0].outcome == .running, "The schedule fires again on time")
        let fourth = try store.get(schedule.id)!.nextRunAt!
        clock.set(fourth.addingTimeInterval(10))
        _ = await scheduler.tick()
        runs = try store.runs(scheduleID: schedule.id)
        try require(log.count == 2 && runs[0].outcome == .skipped && runs[0].detail.contains("still going"), "A still-running task makes the next occurrence skip instead of overlapping")
        log.status = .stopped
        _ = await scheduler.tick()
        let settled = try store.runs(scheduleID: schedule.id)
        try require(settled.first(where: { $0.scheduledFor == third })?.outcome == .stopped, "A canceled task settles as stopped")

        var paused = try store.get(schedule.id)!
        paused.enabled = false
        paused.nextRunAt = nil
        try store.save(paused)
        clock.advance(48 * 3600)
        _ = await scheduler.tick()
        let pausedRuns = try store.runs(scheduleID: schedule.id)
        try require(log.count == 2 && pausedRuns.count == 4, "A disabled schedule never fires and keeps its history")
        try require(await scheduler.runNow(schedule.id) != nil && log.count == 3, "Run now fires a paused schedule on request")
        try require(await scheduler.runNow(schedule.id) == nil, "Run now refuses while a run is still going")

        log.result = .failed("No model is set up.")
        log.status = .completed
        _ = await scheduler.tick()
        var once = try NativeSchedule(owner: .dot, workerType: "document", title: "One report", instruction: "Write it",
                                      cadence: .once(clock.now.addingTimeInterval(600)), timeZone: zone)
        once.advance(after: clock.now, from: nil)
        try store.save(once)
        clock.advance(620)
        _ = await scheduler.tick()
        let onceRuns = try store.runs(scheduleID: once.id)
        try require(onceRuns.count == 1 && onceRuns[0].outcome == .couldNotStart && onceRuns[0].detail == "No model is set up.", "A refused start is recorded with its reason")
        let onceSaved = try store.get(once.id)!
        try require(onceSaved.enabled == false && onceSaved.nextRunAt == nil, "A one-time schedule turns itself off after its time")

        try store.delete(schedule.id)
        let gone = try store.get(schedule.id)
        let goneRuns = try store.runs(scheduleID: schedule.id)
        try require(gone == nil && goneRuns.isEmpty, "Deleting a schedule removes its history")
        print("  native scheduler OK (cadence math, time zones, plain summaries, single fire, late note, settle, missed, skip, disable, run now, refused start, once)")
    }
}
