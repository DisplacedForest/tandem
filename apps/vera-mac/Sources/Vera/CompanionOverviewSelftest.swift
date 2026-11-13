import Foundation

@MainActor
enum CompanionOverviewFixture {
    static let zone = TimeZone(identifier: "America/Chicago")!

    static func task(_ id: UUID, _ title: String, status: NativeTaskCardPresentation.Status, document: Bool = false,
                     hasArtifact: Bool = false, decision: NativeTaskDecision? = nil, minutesAgo: Double) -> CompanionActivityItem {
        let state = status == .completed && hasArtifact ? "Ready to open" : status.title(document: document)
        return CompanionActivityItem(id: id.uuidString, title: title, state: state, status: status, isDocument: document,
                                     hasArtifact: hasArtifact, decision: decision, date: Date().addingTimeInterval(-minutesAgo * 60),
                                     source: .task(id), canOpen: true, canStop: status != .completed && status != .failed && status != .stopped)
    }

    static func schedules() -> [NativeSchedule] {
        [
            try? NativeSchedule(id: "overview-morning", owner: .dot, workerType: "research", title: "Morning check-in",
                                instruction: "Summarize what changed overnight.", cadence: .daily(minuteOfDay: 8 * 60), timeZone: zone),
            try? NativeSchedule(id: "overview-other", owner: .conversation, workerType: "document", title: "Weekly digest",
                                instruction: "Write the weekly digest.", cadence: .weekly(weekday: 2, minuteOfDay: 9 * 60), timeZone: zone),
        ].compactMap { $0 }
    }

    static let reviewID = UUID()
    static let visitID = UUID()
    static let layoutID = UUID()

    static func runs() -> [NativeScheduleRun] {
        let now = Date()
        return [
            NativeScheduleRun(id: "run-missed", scheduleID: "overview-morning", scheduledFor: now.addingTimeInterval(-26 * 3600),
                              outcome: .missed, detail: "Tandem was closed."),
            NativeScheduleRun(id: "run-linked", scheduleID: "overview-morning", scheduledFor: now.addingTimeInterval(-2 * 3600),
                              startedAt: now.addingTimeInterval(-2 * 3600), outcome: .running, taskReferenceID: visitID.uuidString),
            NativeScheduleRun(id: "run-foreign", scheduleID: "overview-other", scheduledFor: now.addingTimeInterval(-3600), outcome: .completed),
            NativeScheduleRun(id: "run-orphan", scheduleID: "overview-morning", scheduledFor: now.addingTimeInterval(-50 * 3600),
                              startedAt: now.addingTimeInterval(-50 * 3600), outcome: .running, conversationID: "thread"),
        ]
    }

    static func tasks() -> [CompanionActivityItem] {
        [
            task(reviewID, "Send the studio schedule", status: .needsInput,
                 decision: NativeTaskDecision(id: "d1", prompt: "The draft is ready for your review.", choices: ["retry", "cancel"]), minutesAgo: 5),
            task(visitID, "Prepare the studio visit", status: .working, minutesAgo: 30),
            task(layoutID, "Room layout", status: .completed, document: true, hasArtifact: true, minutesAgo: 600),
        ]
    }

    static func profileSchedules() -> [NativeSchedule] {
        [
            try? NativeSchedule(id: "profile-morning", owner: .dot, workerType: "research", title: "Morning check-in",
                                instruction: "Summarize what changed overnight.", cadence: .daily(minuteOfDay: 8 * 60), timeZone: zone,
                                nextRunAt: Date().addingTimeInterval(14 * 3600)),
            try? NativeSchedule(id: "profile-friday", owner: .dot, workerType: "document", title: "Friday greenhouse note",
                                instruction: "Write the weekly greenhouse note.", cadence: .weekly(weekday: 6, minuteOfDay: 16 * 60),
                                timeZone: zone, enabled: false),
            try? NativeSchedule(id: "profile-other", owner: .conversation, workerType: "document", title: "Weekly digest",
                                instruction: "Write the weekly digest.", cadence: .weekly(weekday: 2, minuteOfDay: 9 * 60), timeZone: zone),
        ].compactMap { $0 }
    }

    static let newSinceMinutes: Double = 15

    static func profileModel(name: String = "Ada", extraTasks: [CompanionActivityItem] = []) -> CompanionOverviewModel {
        let now = Date()
        let extra = [
            task(UUID(), "Compare frost cloth options", status: .completed, minutesAgo: 1500),
            task(UUID(), "Seed order for spring", status: .completed, document: true, hasArtifact: true, minutesAgo: 2900),
        ]
        let morning = profileSchedules()[0]
        let run = NativeScheduleRun(id: "profile-run", scheduleID: morning.id, scheduledFor: now.addingTimeInterval(-7 * 3600),
                                    startedAt: now.addingTimeInterval(-7 * 3600), finishedAt: now.addingTimeInterval(-7 * 3600 + 300),
                                    outcome: .completed, conversationID: "thread")
        return CompanionOverviewModel.build(
            name: name,
            profile: NativeDotProfile(state: .active, setupCompleted: true),
            services: "Can reach Web search, Documents and 1 more.",
            rules: "",
            activity: CompanionOverviewModel.activity(tasks: extraTasks + tasks() + extra, runs: [run], schedules: profileSchedules()),
            results: [
                CompanionOverviewResult(id: "art-4", title: "Seed order for spring", kind: .document, updatedAt: now.addingTimeInterval(-170_000)),
                CompanionOverviewResult(id: "art-3", title: "Frost cloth comparison", kind: .document, updatedAt: now.addingTimeInterval(-90_000)),
                CompanionOverviewResult(id: "art-2", title: "Weekly meal plan", kind: .document, updatedAt: now.addingTimeInterval(-7200)),
                CompanionOverviewResult(id: "art-1", title: "Room layout", kind: .document, updatedAt: now.addingTimeInterval(-3600)),
            ],
            schedules: profileSchedules(),
            lastMessage: now.addingTimeInterval(-4 * 60))
    }

    static func model(name: String = "Ada", paused: Bool = false) -> CompanionOverviewModel {
        let now = Date()
        return CompanionOverviewModel.build(
            name: name,
            profile: NativeDotProfile(state: paused ? .paused : .active, setupCompleted: true),
            services: "Can reach Web search, Documents and 1 more.",
            rules: "Asks first for commands and Trash. Hands off sending.",
            activity: CompanionOverviewModel.activity(tasks: tasks(), runs: runs(), schedules: schedules()),
            results: [
                CompanionOverviewResult(id: "art-2", title: "Weekly meal plan", kind: .document, updatedAt: now.addingTimeInterval(-7200)),
                CompanionOverviewResult(id: "art-1", title: "Room layout", kind: .document, updatedAt: now.addingTimeInterval(-3600)),
            ])
    }
}

@MainActor
extension SelfTest {
    private static func missedRunActions(_ model: CompanionOverviewModel) -> Bool {
        guard let missed = model.selected("run:run-missed") else { return false }
        return !missed.canOpen && !missed.canStop && !missed.canRetry
    }

    static func runCompanionOverview() throws {
        let require = NativeTaskFixture.require
        let model = CompanionOverviewFixture.model()
        let ids = model.activity.map(\.id)
        try require(ids == [CompanionOverviewFixture.reviewID.uuidString, CompanionOverviewFixture.visitID.uuidString,
                            CompanionOverviewFixture.layoutID.uuidString, "run:run-missed", "run:run-orphan"],
                    "Activity lists the companion's tasks and its own scheduled runs newest first")
        try require(missedRunActions(model), "A missed run with no chat offers neither Open nor Stop")
        let orphan = model.selected("run:run-orphan")
        try require(orphan?.canOpen == true && orphan?.canStop == false && orphan?.canRetry == false,
                    "A running run without a task reference can be opened but not stopped or retried")
        try require(model.selected(CompanionOverviewFixture.visitID.uuidString)?.canStop == true
                    && model.selected(CompanionOverviewFixture.layoutID.uuidString)?.canStop == false,
                    "Stop is offered for a running task and not for a finished one")
        try require(!ids.contains("run:run-linked"), "A run that produced a task is shown once, as the task")
        try require(!ids.contains("run:run-foreign"), "Runs of schedules the companion does not own stay out")
        let missed = model.selected("run:run-missed")
        try require(missed?.state == "Missed" && missed?.status == .stopped && missed?.isOpen == false, "A missed run reads in plain words")
        try require(model.needsYouCount == 1 && model.activity[0].canRetry, "Work waiting on a decision is counted and can be retried")
        try require(model.outputs.map(\.id) == ["art-1", "art-2"], "Outputs sort newest first")

        try require(model.rulesTitle(selected: CompanionOverviewFixture.visitID.uuidString) == "Prepare the studio visit",
                    "The rules column names the selected task")
        try require(model.rulesTitle(selected: "run:run-missed") == "Morning check-in", "A scheduled run can be selected too")
        try require(model.rulesTitle(selected: "missing") == nil && model.rulesTitle(selected: nil) == nil,
                    "Absent work gives the rules column nothing to name")

        let paused = CompanionOverviewFixture.model(paused: true)
        try require(paused.paused, "A paused companion reads as paused")
        try require(CompanionOverviewModel.pauseTitle(name: "Ada", paused: false) == "Pause Ada"
                    && CompanionOverviewModel.pauseTitle(name: "Ada", paused: true) == "Resume Ada"
                    && CompanionOverviewModel.stopTitle == "Stop this task", "Global pause and per-task stop name different targets")

        let options = [
            NativeDotServiceOption(id: "a", name: "Web search", detail: "", toolIDs: ["a"]),
            NativeDotServiceOption(id: "b", name: "Documents", detail: "", toolIDs: ["b"]),
            NativeDotServiceOption(id: "c", name: "Images", detail: "", toolIDs: ["c"]),
            NativeDotServiceOption(id: "d", name: "Calendar", detail: "", toolIDs: ["d"]),
        ]
        try require(CompanionOverviewModel.servicesLine(options: options, selected: ["a", "b", "c", "d"]) == "Can reach every service that is turned on."
                    && CompanionOverviewModel.servicesLine(options: options, selected: ["a", "b"]) == "Can reach Web search, Documents."
                    && CompanionOverviewModel.servicesLine(options: options, selected: ["a", "b", "c", "d"].dropLast().reduce(into: Set<String>()) { $0.insert($1) }) == "Can reach Web search, Documents, Images."
                    && CompanionOverviewModel.servicesLine(options: options, selected: []) == "No services connected."
                    && CompanionOverviewModel.servicesLine(options: [], selected: []) == "No services turned on yet.",
                    "The services line says what the companion can reach in plain words")

        let emptyModel = CompanionOverviewModel.build(name: "Ada", profile: NativeDotProfile(), services: "No services turned on yet.",
                                                      rules: "", activity: [], results: [])
        try require(emptyModel.activity.isEmpty && emptyModel.outputs.isEmpty && !emptyModel.paused,
                    "An unset companion has empty sections")

        let store = CompanionShotFixture.store()
        store.adoptAssistantName("Ada")
        store.dotProfile = NativeDotProfile(state: .active, setupCompleted: true)
        let live = store.companionOverviewModel()
        try require(live.name == "Ada" && !live.paused && live.activity.isEmpty && live.outputs.isEmpty,
                    "A store with no work builds an honest empty overview")
        store.openCompanionOutputs()
        try require(store.section == .artifacts && store.pendingLibraryConversationID == store.veraThreadID,
                    "Show more hands the companion's thread to the Library filter")
        let navigation = OngoingWorkFixture.store()
        let originID = navigation.selectedID
        let reference = navigation.nativeTaskReferences.last!
        let item = CompanionOverviewModel.taskItem(card: try NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot).card,
                                                  reference: reference, decision: nil, hasArtifact: true, date: Date())
        let answered = NativeTaskCardPresentation(id: reference.id.uuidString, title: "Weather tomorrow", status: .completed,
                                                  milestone: "", workerType: "companion", answer: "Sunny and mild.")
        let answeredItem = CompanionOverviewModel.taskItem(card: answered, reference: reference, decision: nil, hasArtifact: false, date: Date())
        var researched = answered
        researched.workerType = "research"
        let researchedItem = CompanionOverviewModel.taskItem(card: researched, reference: reference, decision: nil, hasArtifact: false, date: Date())
        let documentItem = CompanionOverviewModel.taskItem(card: answered, reference: reference, decision: nil, hasArtifact: true, date: Date())
        try require(answeredItem.state == "Work done" && researchedItem.state == "Research complete" && documentItem.state == "Ready to open",
                    "Finished companion work without a document reads as work done")
        navigation.newConversation()
        let unrelatedID = navigation.selectedID
        let fresh = navigation.companionActivityDetail(item)
        try require(fresh.request == reference.request.objective && fresh.outcome?.contains("The plan is ready") != true,
                    "Activity details use the saved request and never repeat a result that arrives as a message")
        navigation.nativeTaskResultDeliveries[reference.id] = .some(nil)
        let detail = navigation.companionActivityDetail(item)
        try require(detail.request == reference.request.objective && detail.outcome?.contains("The plan is ready") == true,
                    "Activity details for work finished before results arrived as messages still use the validated result")
        try require(navigation.selectedID == unrelatedID && navigation.pendingTaskReveal == nil,
                    "Reading details leaves the current conversation in place")
        navigation.openCompanionActivity(item)
        try require(navigation.selectedID == originID && navigation.pendingTaskReveal == reference.id.uuidString,
                    "Go to chat opens the actual origin and reveals the task card")
        let savedOrigin = navigation.conversations.first { $0.id == originID }!
        try navigation.repository?.saveConversation(savedOrigin)
        navigation.newConversation()
        navigation.conversations.removeAll { $0.id == originID }
        try require(navigation.companionActivityDetail(item).canOpen && navigation.openCompanionActivity(item)
                    && navigation.selectedID == originID && navigation.pendingTaskReveal == reference.id.uuidString,
                    "Stored task origins can reopen even when they are not loaded in the conversation list")
        let missingItem = CompanionOverviewFixture.tasks()[0]
        try require(!navigation.companionActivityDetail(missingItem).canOpen,
                    "A missing task cannot offer a misleading chat action")
        navigation.schedules = CompanionOverviewFixture.schedules()
        navigation.scheduleRuns = ["overview-morning": CompanionOverviewFixture.runs()]
        let scheduledDetail = navigation.companionActivityDetail(model.selected("run:run-missed")!)
        try require(scheduledDetail.request == nil && scheduledDetail.outcome == "Tandem was closed.",
                    "A run without a saved task does not substitute today's schedule instruction for its original request")
        let deletedRun = NativeScheduleRun(id: "deleted-chat", scheduleID: "overview-morning", scheduledFor: Date(),
                                           outcome: .completed, conversationID: "deleted")
        navigation.scheduleRuns["overview-morning", default: []].append(deletedRun)
        let deletedItem = CompanionOverviewModel.runItem(deletedRun, schedule: navigation.schedules[0])
        let beforeMissingOpen = navigation.selectedID
        try require(!navigation.companionActivityDetail(deletedItem).canOpen && !navigation.openCompanionActivity(deletedItem)
                    && navigation.selectedID == beforeMissingOpen,
                    "Deleted scheduled chats offer no navigation and preserve the current conversation")
        let blankDetail = CompanionActivityDetail(request: "  ", outcome: "", canOpen: false)
        try require(blankDetail.request == nil && blankDetail.outcome == nil, "Missing detail fields are omitted")

        let focused = CompanionShotFixture.store()
        focused.newConversation()
        try require(!focused.isVeraThread(focused.selectedID) && focused.section == .chat
                    && !CompanionProfileState.available(section: focused.section, companionThread: focused.isVeraThread(focused.selectedID)),
                    "A focused chat never gets the companion profile")
        focused.openVeraThread()
        try require(CompanionProfileState.available(section: focused.section, companionThread: focused.isVeraThread(focused.selectedID))
                    && !CompanionProfileState.available(section: .chat, companionThread: true),
                    "Only the companion conversation offers the profile")
        try runCompanionProfile()
        print("  companion overview OK (activity, runs, selection, rules title, pause and stop labels, services line, empty states, routing, profile)")
    }

    static func runCompanionProfile() throws {
        let require = NativeTaskFixture.require
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        var state = CompanionProfileState(launchedAt: launch)
        try require(!state.isOpen && state.lastClosed == launch, "The profile starts closed and counts from launch")
        state.close(now: launch.addingTimeInterval(30))
        try require(!state.isOpen && state.lastClosed == launch, "Closing a closed profile does not move the last close")
        state.toggle(now: launch.addingTimeInterval(60))
        try require(state.isOpen && state.lastClosed == launch, "The toggle opens the profile")
        state.toggle(now: launch.addingTimeInterval(120))
        try require(!state.isOpen && state.lastClosed == launch.addingTimeInterval(120), "The toggle closes it and remembers when")
        state.open()
        state.open()
        try require(state.isOpen && state.lastClosed == launch.addingTimeInterval(120), "Opening from the working line opens it and leaves it open when asked twice")
        state.close(now: launch.addingTimeInterval(180))

        try require(CompanionProfileMetrics.panelWidth(available: 879) == CompanionProfileMetrics.width
                    && CompanionProfileMetrics.panelWidth(available: 2000) == CompanionProfileMetrics.width,
                    "A roomy window gives the profile its full width")
        try require(CompanionProfileMetrics.panelWidth(available: 701) == 340
                    && CompanionProfileMetrics.panelWidth(available: 671) == 310,
                    "A tighter window narrows the profile so the conversation keeps its minimum")
        try require(CompanionProfileMetrics.panelWidth(available: 619) == CompanionProfileMetrics.minimumWidth
                    && CompanionProfileMetrics.panelWidth(available: 0) == CompanionProfileMetrics.minimumWidth,
                    "The profile never goes below its floor")

        try require(CompanionProfileCopy.toggleTitle(name: "Ada", open: false) == "Open Ada's profile"
                    && CompanionProfileCopy.toggleTitle(name: "Ada", open: true) == "Close Ada's profile",
                    "The profile toggle names the companion")
        let unnamed = CompanionOverviewModel.build(name: CompanionSubject(nil).leading, profile: NativeDotProfile(), services: "",
                                                   rules: "", activity: [], results: [])
        try require(CompanionProfileCopy.toggleTitle(name: unnamed.mention, open: false) == "Open your companion's profile"
                    && CompanionProfileCopy.toggleTitle(name: unnamed.mention, open: true) == "Close your companion's profile",
                    "An unnamed companion reads as your companion")
        try require(CompanionProfileCopy.panelLabel(name: "Ada") == "Ada's profile"
                    && CompanionProfileCopy.panelLabel(name: CompanionSubject(nil).leading) == "Your companion's profile"
                    && CompanionProfileCopy.runLabel("Morning check-in") == "Run Morning check-in",
                    "The panel and its switches have plain labels")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US_POSIX")
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15))!
        func active(_ seconds: TimeInterval) -> String? {
            CompanionProfileCopy.activeLine(since: now.addingTimeInterval(-seconds), now: now, calendar: calendar, locale: locale)
        }
        try require(active(0) == "Active just now" && active(59) == "Active just now", "Under a minute reads as just now")
        try require(active(60) == "Active 1 minute ago" && active(45 * 60) == "Active 45 minutes ago", "Minutes read as minutes")
        try require(active(3600) == "Active 1 hour ago" && active(5 * 3600) == "Active 5 hours ago"
                    && active(23 * 3600 + 3540) == "Active 23 hours ago", "Hours read as hours")
        try require(active(26 * 3600) == "Active yesterday", "The day before reads as yesterday")
        try require(active(3 * 86400) == "Active on Nov 9", "Older activity reads as a short date: \(active(3 * 86400) ?? "nil")")
        try require(active(370 * 86400) == "Active on Nov 7, 2025", "Last year's activity names the year: \(active(370 * 86400) ?? "nil")")
        try require(CompanionProfileCopy.activeLine(since: nil, now: now) == nil, "Nothing to report leaves the line out")
        try require(active(-120) == "Active just now", "A clock that ran ahead still reads as just now")

        let item = CompanionOverviewFixture.task(UUID(), "Water the beds", status: .working, minutesAgo: 30)
        try require(CompanionOverviewModel.lastActive(lastMessage: item.date.addingTimeInterval(60), activity: [item]) == item.date.addingTimeInterval(60)
                    && CompanionOverviewModel.lastActive(lastMessage: item.date.addingTimeInterval(-60), activity: [item]) == item.date
                    && CompanionOverviewModel.lastActive(lastMessage: nil, activity: []) == nil,
                    "Active time is the newest of the last message and the newest activity")
        try require(CompanionOverviewModel.isNew(item, since: item.date.addingTimeInterval(-1))
                    && !CompanionOverviewModel.isNew(item, since: item.date)
                    && !CompanionOverviewModel.isNew(item, since: item.date.addingTimeInterval(1)),
                    "A row is new only when it is later than the last close")

        let profile = CompanionOverviewFixture.profileModel()
        let since = Date().addingTimeInterval(-CompanionOverviewFixture.newSinceMinutes * 60)
        try require(profile.activity.filter { CompanionOverviewModel.isNew($0, since: since) }.count == 1,
                    "The profile fixture has exactly one new row")
        try require(profile.activity.count == 6
                    && CompanionOverviewModel.preview(profile.activity, limit: CompanionOverviewModel.activityPreview, expanded: false).count == 5
                    && CompanionOverviewModel.preview(profile.activity, limit: CompanionOverviewModel.activityPreview, expanded: true).count == 6
                    && CompanionOverviewModel.hasMore(profile.activity.count, limit: CompanionOverviewModel.activityPreview),
                    "Recent activity shows five rows, then Show more expands the rest")
        try require(CompanionOverviewModel.outputPreview == 3 && profile.outputs.count == 4
                    && CompanionOverviewModel.preview(profile.outputs, limit: CompanionOverviewModel.outputPreview, expanded: false).map(\.id) == ["art-1", "art-2", "art-3"]
                    && CompanionOverviewModel.hasMore(profile.outputs.count, limit: CompanionOverviewModel.outputPreview)
                    && !CompanionOverviewModel.hasMore(3, limit: CompanionOverviewModel.outputPreview),
                    "Outputs show the three newest, then Show more")
        let runRow = profile.selected("run:profile-run")
        try require(runRow?.line == CompanionOverviewFixture.profileSchedules()[0].cadenceSummary && runRow?.state == NativeScheduleOutcome.completed.title,
                    "A scheduled row says how often it runs and keeps its state for the details: \(String(describing: runRow?.line)) \(String(describing: runRow?.state))")
        try require(profile.selected(CompanionOverviewFixture.visitID.uuidString)?.line == "Researching",
                    "Other rows keep their state line")
        try require(profile.upcoming.map(\.id) == ["profile-morning", "profile-friday"]
                    && profile.upcoming.map(\.enabled) == [true, false]
                    && profile.upcoming[0].when == CompanionOverviewFixture.profileSchedules()[0].cadenceSummary,
                    "Upcoming lists only the companion's schedules in the Scheduled screen's words")
        try require(!profile.isEmpty && unnamed.isEmpty && unnamed.upcoming.isEmpty && unnamed.lastActive == nil,
                    "An empty profile is recognised as empty")

        let store = CompanionShotFixture.store()
        if store.nativeScheduleStore == nil, let local = store.repository as? LocalChatRepository {
            store.nativeScheduleStore = NativeScheduleStore(database: local.database)
        }
        guard let schedules = store.nativeScheduleStore else { throw NativeTaskFixture.Failure.assertion("The store has a schedule store") }
        for var schedule in CompanionOverviewFixture.profileSchedules() {
            if schedule.enabled { schedule.advance(after: Date(), from: nil) }
            try schedules.save(schedule)
        }
        store.reloadSchedules()
        try require(store.companionOverviewModel().upcoming.map(\.id) == ["profile-morning", "profile-friday"],
                    "The live profile lists the companion's schedules")
        let rows = store.companionOverviewModel().upcoming
        guard let morning = rows.first(where: { $0.title == "Morning check-in" }),
              let friday = rows.first(where: { $0.title == "Friday greenhouse note" }) else {
            throw NativeTaskFixture.Failure.assertion("The live profile has both rows")
        }
        let off = store.switchCompanionSchedule(morning.id, on: false)
        let on = store.switchCompanionSchedule(friday.id, on: true)
        let switched = store.companionOverviewModel().upcoming
        try require(off == nil && on == nil
                    && switched.first { $0.id == "profile-morning" }?.enabled == false
                    && switched.first { $0.id == "profile-friday" }?.enabled == true
                    && (try schedules.get("profile-morning"))?.enabled == false
                    && (try schedules.get("profile-friday"))?.enabled == true
                    && (try schedules.get("profile-other"))?.enabled == true,
                    "The profile switch changes the row's own schedule and nothing else")
        try require(store.switchCompanionSchedule("profile-other", on: false) == nil
                    && (try schedules.get("profile-other"))?.enabled == true,
                    "The profile switch can't change a schedule that isn't the companion's")
        try schedules.save(NativeSchedule(id: "profile-passed", owner: .dot, workerType: "research", title: "One-time check",
                                          instruction: "Check once.", cadence: .once(Date().addingTimeInterval(-3600)),
                                          timeZone: CompanionOverviewFixture.zone, enabled: false))
        store.reloadSchedules()
        let passed = store.switchCompanionSchedule("profile-passed", on: true)
        try require(passed?.isEmpty == false && (try schedules.get("profile-passed"))?.enabled == false
                    && store.companionOverviewModel().upcoming.first { $0.id == "profile-passed" }?.enabled == false,
                    "Turning on a one-time schedule whose time has passed says why and leaves it off")
        store.openCompanionSchedules()
        try require(store.section == .scheduled, "The message under a schedule that can't turn on leads to Scheduled")
        let lastMessage = store.conversations.first { $0.id == store.veraThreadID }?.messages.last?.createdAt
        try require(lastMessage != nil && store.companionOverviewModel().lastActive == lastMessage,
                    "The live profile is active as of the last message")
        print("  companion profile OK (closed by default, toggle labels, active line, new dot, previews, upcoming switch)")
    }
}
