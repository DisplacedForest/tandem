import Foundation

@MainActor
enum NativeScheduleShotFixture {
    static func populate(_ store: ChatStore) {
        let zone = TimeZone(identifier: "America/Chicago")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = Date()
        let today7 = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now)!
        let tomorrow7 = calendar.date(byAdding: .day, value: 1, to: today7)!
        guard let briefing = try? NativeSchedule(id: "shot-briefing", owner: .dot, workerType: "research", title: "Morning news check",
                                                 instruction: "Summarize overnight developments in semiconductor export policy with sources.",
                                                 cadence: .daily(minuteOfDay: 7 * 60), timeZone: zone, nextRunAt: tomorrow7,
                                                 lastRunAt: today7, lastOutcome: .completed),
              let digest = try? NativeSchedule(id: "shot-digest", owner: .conversation, workerType: "document", title: "Weekly reading digest",
                                               instruction: "Write a one-page digest of the week's saved articles.",
                                               cadence: .weekly(weekday: 2, minuteOfDay: 9 * 60), timeZone: zone,
                                               nextRunAt: calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime),
                                               lastRunAt: calendar.date(byAdding: .day, value: -3, to: today7), lastOutcome: .missed),
              let prices = try? NativeSchedule(id: "shot-prices", owner: .conversation, workerType: "research", title: "Lumber price watch",
                                               instruction: "Check current lumber futures and note any move over two percent.",
                                               cadence: .everyHours(6), timeZone: zone, enabled: false) else { return }
        store.schedules = [briefing, digest, prices]
        store.scheduleRuns = [
            briefing.id: [
                NativeScheduleRun(scheduleID: briefing.id, scheduledFor: today7, startedAt: today7, finishedAt: today7.addingTimeInterval(240),
                                  outcome: .completed, conversationID: "shot"),
                NativeScheduleRun(scheduleID: briefing.id, scheduledFor: calendar.date(byAdding: .day, value: -1, to: today7)!,
                                  finishedAt: now, outcome: .missed,
                                  detail: "Tandem wasn't running at the scheduled time. It will run next time as planned."),
            ],
            digest.id: [
                NativeScheduleRun(scheduleID: digest.id, scheduledFor: calendar.date(byAdding: .day, value: -3, to: today7)!,
                                  finishedAt: now, outcome: .missed,
                                  detail: "Tandem wasn't running at the scheduled time. It will run next time as planned."),
            ],
        ]
    }
}
