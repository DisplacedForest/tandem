import Foundation

@MainActor
extension SelfTest {
    static func runNativeScheduleTools() async throws {
        let require = NativeTaskFixture.require
        let zone = TimeZone(identifier: "America/Chicago")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 6, minute: 30))!
        try require(calendar.component(.weekday, from: now) == 2, "The fixture anchor is a Monday")

        func arguments(_ extra: [String: NativeJSONValue], workerType: String = "research") -> [String: NativeJSONValue] {
            var base: [String: NativeJSONValue] = [
                "title": .string("Morning policy check"),
                "worker_type": .string(workerType),
                "instruction": .string("Summarize overnight developments with sources."),
            ]
            base.merge(extra) { _, new in new }
            return base
        }
        func draft(_ values: [String: NativeJSONValue]) throws -> NativeScheduleDraft {
            try NativeScheduleTools.draft(from: values, now: now, timeZone: zone)
        }
        func rejects(_ values: [String: NativeJSONValue]) -> Bool {
            (try? draft(values)) == nil
        }

        let daily = try draft(arguments(["repeat": .string("daily"), "time": .string("07:00")]))
        try require(daily.cadence == .daily(minuteOfDay: 420), "Daily at 07:00 projects to minute 420")
        try require(daily.owner == .conversation, "Results go to the schedule's own chat by default")
        try require(daily.title == "Morning policy check", "The title carries through")
        try require(daily.instruction == "Summarize overnight developments with sources.", "The instruction carries through")
        try require(daily.workerType == "research", "The worker type carries through")
        let weekdaysArguments = arguments(["repeat": .string("weekdays"), "time": .string("08:30")])
        try require(try draft(weekdaysArguments).cadence == .weekdays(minuteOfDay: 510), "Weekdays at 08:30 projects to minute 510")
        try require(try draft(arguments(["repeat": .string("weekly"), "weekday": .string("friday"), "time": .string("15:30")])).cadence
            == .weekly(weekday: 6, minuteOfDay: 930), "Weekly on Friday projects to weekday 6")
        try require(try draft(arguments(["repeat": .string("every_hours"), "hours": .number(6)])).cadence == .everyHours(6), "Every 6 hours projects")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        try require(try draft(arguments(["repeat": .string("once"), "at": .string(formatter.string(from: tomorrow))])).cadence == .once(tomorrow),
                    "A one-time schedule reads local time in the zone")
        try require(try draft(arguments(["repeat": .string("daily"), "time": .string("07:00"), "results_to": .string("assistant")])).owner == .dot,
                    "results_to assistant goes to the assistant thread")
        try require(try draft(arguments(["repeat": .string("daily"), "time": .string("07:00"), "results_to": .string("own_chat")])).owner == .conversation,
                    "results_to own_chat goes to its own chat")

        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let rejected: [(String, [String: NativeJSONValue])] = [
            ("an hour past 23", arguments(["repeat": .string("daily"), "time": .string("25:00")])),
            ("a non 24-hour time", arguments(["repeat": .string("daily"), "time": .string("7am")])),
            ("zero hours", arguments(["repeat": .string("every_hours"), "hours": .number(0)])),
            ("fractional hours", arguments(["repeat": .string("every_hours"), "hours": .number(2.5)])),
            ("a past one-time date", arguments(["repeat": .string("once"), "at": .string(formatter.string(from: yesterday))])),
            ("an unknown repeat", arguments(["repeat": .string("monthly"), "time": .string("07:00")])),
            ("an unknown worker type", arguments(["repeat": .string("daily"), "time": .string("07:00")], workerType: "voice")),
            ("an unknown field", arguments(["repeat": .string("daily"), "time": .string("07:00"), "priority": .string("high")])),
            ("daily without a time", arguments(["repeat": .string("daily")])),
            ("weekly without a weekday", arguments(["repeat": .string("weekly"), "time": .string("07:00")])),
            ("an unknown destination", arguments(["repeat": .string("daily"), "time": .string("07:00"), "results_to": .string("pulse")])),
        ]
        for (label, values) in rejected {
            try require(rejects(values), "The projection rejects \(label)")
        }

        let fixture = "{\"title\":\"Morning policy check\",\"worker_type\":\"research\",\"instruction\":\"Summarize overnight developments in semiconductor export policy with sources.\",\"results_to\":\"own_chat\",\"repeat\":\"weekdays\",\"time\":\"07:00\"}"
        guard let parsed = NativeScheduleTools.draft(inRequest: fixture, now: now, timeZone: zone) else {
            throw NativeTaskFixture.Failure.assertion("The confirmation request parses")
        }
        let prompt = NativeScheduleTools.prompt(for: parsed, timeZone: zone)
        try require(prompt.contains("Morning policy check") && prompt.contains("weekdays at") && prompt.hasSuffix("?"),
                    "The confirmation prompt names the schedule and its cadence")
        let detail = NativeScheduleTools.detail(for: parsed, assistantName: "Sol")
        try require(detail.contains("Results go to its own chat") && detail.contains("Nothing is saved until you approve"),
                    "The confirmation detail names the destination and that nothing is saved yet")
        var threaded = parsed
        threaded.owner = .dot
        try require(NativeScheduleTools.detail(for: threaded, assistantName: "Sol").contains("the Sol thread"),
                    "The confirmation detail names the assistant thread")
        try require(NativeScheduleTools.draft(inRequest: "{\"title\":\"x\"}", now: now, timeZone: zone) == nil, "An incomplete request does not parse")

        let research = NativeWebTools.researchToolID
        let asksSchedule = NativeTurnToolAuthority("Every weekday at 7 research semiconductor export policy")
        let asksResearch = NativeTurnToolAuthority("Research NASA")
        let asksNeither = NativeTurnToolAuthority("Tell me about tea")
        func composed(_ consented: Set<String>, _ authority: NativeTurnToolAuthority, mentions: Set<String> = [], hasStore: Bool = true) -> Set<String> {
            let turnConsent = consented.union(mentions)
            let snapshot = authority.filter(turnConsent)
            var allowed = NativeScheduleTools.turnEnabledIDs(snapshot: snapshot, consented: turnConsent, authority: authority,
                                                             hasEngine: true, hasRepository: true, hasStore: hasStore)
            allowed.remove(research)
            return allowed
        }
        try require(composed([research], asksSchedule) == [NativeScheduleTools.toolID], "The ticket's own example offers the schedule tool and nothing else")
        try require(composed([research], asksResearch) == [NativeTaskTools.toolID], "A plain research request offers background work, never the schedule tool")
        try require(composed([research], NativeTurnToolAuthority("Research daily trading volume")) == [NativeTaskTools.toolID],
                    "A cadence word inside the subject offers background work only")
        try require(composed([research], NativeTurnToolAuthority("Research news about NASA every weekday at 7")).isSuperset(of: [NativeScheduleTools.toolID]),
                    "A recurring request with a subject word before the cadence still offers the schedule tool")
        try require(composed([research], asksNeither).isEmpty, "An ordinary message offers neither")
        for text in ["Please set up a printer", "Write a guide to set up a home server", "Set up the project folder", "Help me set up a standing desk", "Set up a regular expression for emails", "Schedule a meeting with the plumber", "What is on my schedule today", "Set up a Dailymotion account", "Please set up a Dailymotion account", "Dailymotion is a video site", "Research the Weeklys brand", "Check hourlyrate.example for me"] {
            try require(!composed([research], NativeTurnToolAuthority(text)).contains(NativeScheduleTools.toolID),
                        "A generic set up request does not offer the schedule tool: \(text)")
        }
        try require(composed([research], NativeTurnToolAuthority("Set up a weekly digest of my saved articles")) == [NativeScheduleTools.toolID],
                    "Set up with a cadence offers the schedule tool")
        try require(composed([], asksSchedule).isEmpty, "Nothing enables the tool without background work")
        try require(composed([research], asksSchedule, hasStore: false).isEmpty, "No store, no tool")
        try require(composed(["apple-reminders"], asksSchedule) == ["apple-reminders"], "Other tools do not enable it")
        try require(composed([research], NativeTurnToolAuthority("Do not use tools. Every day research NASA")).isEmpty, "No tools means no schedule tool")
        let mentionAuthority = NativeTurnToolAuthority("make it recurring", mentions: [NativeScheduleTools.toolID])
        try require(composed([research], mentionAuthority, mentions: [NativeScheduleTools.toolID]) == [NativeScheduleTools.toolID],
                    "A mention enables the tool when background work is consented")
        try require(NativeScheduleTools.turnEnabledIDs(snapshot: asksSchedule.filter([research]), consented: [], authority: asksSchedule,
                                                       hasEngine: true, hasRepository: true, hasStore: true).isEmpty,
                    "Consent revoked after the send drops the tool")

        let allowed = ["Every weekday at 7 research semiconductor export policy", "Schedule a daily summary of my saved articles",
                       "Each morning write me a short memo on overnight news", "Once a week check lumber prices",
                       "Tomorrow at 9 research the weather outlook", "Can you research NASA every 6 hours",
                       "Research news about NASA every weekday at 7", "Please set up a daily digest of my saved articles",
                       "Check lumber prices every 6 hours and send me a summary", "Research the Mars mission every Monday at 9am, please",
                       "every weekday at 7, research overnight chip export news"]
        for text in allowed {
            try require(NativeTurnToolAuthority(text).allowsSchedule, "Scheduling is allowed for: \(text)")
        }
        let refused = ["Research NASA", "Tell me about tea", "What did I ask?", "Do not schedule anything. Research NASA.",
                       "Do not use tools. Every day research NASA", "What is a schedule?", "Research why people drink coffee every morning.",
                       "Why do markets move every Monday?", "Explain how weekly sprints work", "Is the market open on Mondays?",
                       "Write a memo about what happens every day at the plant", "Tell me how recurring billing works",
                       "Research daily trading volume", "Summarize the weekly report I attached", "My schedule is full this week",
                       "Research what people do every morning", "Please set up a printer", "Write a guide to set up a home server", "Help me set up a standing desk"]
        for text in refused {
            try require(!NativeTurnToolAuthority(text).allowsSchedule, "Scheduling is refused for: \(text)")
        }
        try require(NativeTurnToolAuthority("make it recurring", mentions: [NativeScheduleTools.toolID]).allowsSchedule, "A mention allows scheduling")
        try require(NativeTurnToolAuthority("Tell me about tea").filter([NativeScheduleTools.toolID, "apple-reminders"]) == ["apple-reminders"],
                    "The filter drops the tool without scheduling intent")
        try require(NativeTurnToolAuthority("Every day research tea").filter([NativeScheduleTools.toolID, "apple-reminders"]).contains(NativeScheduleTools.toolID),
                    "The filter keeps the tool with scheduling intent")

        let save: @Sendable (NativeScheduleDraft) async throws -> NativeSchedule = { draft in
            try NativeSchedule(owner: draft.owner, workerType: draft.workerType, title: draft.title,
                               instruction: draft.instruction, cadence: draft.cadence, timeZone: zone)
        }
        let definition = NativeScheduleTools.definition(assistantName: { "Sol" }, searchAvailable: { true },
                                                        now: { now }, timeZone: { zone }, save: save)
        try require(definition.confirmation == .required, "Scheduling always asks first")
        try require(definition.name == "schedule_task", "The tool is named schedule_task")
        let saved = try await definition.execute(weekdaysArguments)
        guard case .object(let result) = saved, case .string(let message)? = result["message"] else {
            throw NativeTaskFixture.Failure.assertion("The tool returns a message")
        }
        try require(result["saved"] == .bool(true), "The result says the schedule was saved")
        try require(message.contains("Weekdays at \(NativeScheduleCadence.clock(510))") && NativeScheduleCadence.clock(510).hasPrefix("8:30") && message.contains("its own chat"), "The result names the cadence and destination")
        let toThread = try await definition.execute(arguments(["repeat": .string("daily"), "time": .string("07:00"), "results_to": .string("assistant")]))
        guard case .object(let threadResult) = toThread, case .string(let threadMessage)? = threadResult["message"] else {
            throw NativeTaskFixture.Failure.assertion("The tool returns a message for the assistant thread")
        }
        try require(threadMessage.contains("the Sol thread"), "The result names the assistant thread")

        let offline = NativeScheduleTools.definition(assistantName: { "Sol" }, searchAvailable: { false },
                                                     now: { now }, timeZone: { zone }, save: save)
        do {
            _ = try await offline.execute(weekdaysArguments)
            throw NativeTaskFixture.Failure.assertion("Research without search should be refused")
        } catch let error as NativeToolError {
            try require(error == .failed(NativeTaskTools.searchUnavailable), "Research without search is refused with the usual explanation")
        }
        let document = try await offline.execute(arguments(["repeat": .string("weekdays"), "time": .string("08:30")], workerType: "document"))
        guard case .object(let documentResult) = document else { throw NativeTaskFixture.Failure.assertion("A document schedule returns an object") }
        try require(documentResult["saved"] == .bool(true), "A document schedule saves without search")

        let refusing = NativeScheduleTools.definition(assistantName: { "Sol" }, searchAvailable: { true }, now: { now }, timeZone: { zone },
                                                      save: { _ in throw NativeScheduleError.invalid("Pick a time that is still ahead.") })
        do {
            _ = try await refusing.execute(weekdaysArguments)
            throw NativeTaskFixture.Failure.assertion("A failed save should surface")
        } catch let error as NativeToolError {
            try require(error == .failed("Pick a time that is still ahead."), "A failed save surfaces its reason")
        }

        let hourlyWire = "{\"title\":\"Hourly check\",\"worker_type\":\"document\",\"instruction\":\"Note anything new.\",\"repeat\":\"every_hours\",\"hours\":1}"
        let hourlyArguments = try definition.validatedArguments(hourlyWire)
        try require(hourlyArguments["hours"] == .number(1), "A JSON 1 stays a number on the wire")
        try require(try draft(hourlyArguments).cadence == .everyHours(1), "Hourly projects through the real JSON path")
        try require(NativeScheduleTools.prompt(for: NativeScheduleTools.draft(inRequest: hourlyWire, now: now, timeZone: zone)!, timeZone: zone).contains("every hour"),
                    "The confirmation card renders an hourly schedule")
        let hourlySaved = try await definition.execute(hourlyArguments)
        guard case .object(let hourlyResult) = hourlySaved else { throw NativeTaskFixture.Failure.assertion("An hourly schedule returns an object") }
        try require(hourlyResult["saved"] == .bool(true), "An hourly schedule saves")
        let flagWire = "{\"title\":\"Hourly check\",\"worker_type\":\"document\",\"instruction\":\"Note anything new.\",\"repeat\":\"every_hours\",\"hours\":true}"
        try require((try? draft(try definition.validatedArguments(flagWire))) == nil, "A JSON true is not an hour count")

        let missingRepeat = "{\"title\":\"Morning policy check\",\"worker_type\":\"research\",\"instruction\":\"Summarize.\",\"time\":\"07:00\"}"
        try require((try? definition.validatedArguments(missingRepeat)) == nil, "The generic validator requires repeat")

        print("  native schedule tool: PASS (projection, rejections, confirmation copy, enablement, turn authority, save, search gate, save failure, schema)")
    }
}
