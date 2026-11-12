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
        let detail = navigation.companionActivityDetail(item)
        try require(detail.request == reference.request.objective && detail.outcome?.contains("The plan is ready") == true,
                    "Activity details use the saved request and validated result")
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

        for width in [CGFloat(700), 1119, 1120, 1600] {
            for canvas in [false, true] {
                try require(CompanionPanelPlacement.decide(isCompanionThread: false, windowWidth: width, canvasShowing: canvas) == .none,
                            "A focused chat never gets the companion panel or its Details button at \(Int(width)) points")
            }
        }
        try require(CompanionPanelPlacement.decide(isCompanionThread: true, windowWidth: 1600, canvasShowing: false) == .beside
                    && CompanionPanelPlacement.decide(isCompanionThread: true, windowWidth: 1119, canvasShowing: false) == .header
                    && CompanionPanelPlacement.decide(isCompanionThread: true, windowWidth: 1600, canvasShowing: true) == .header,
                    "The companion thread shows the panel beside it when wide and folds it into the header when narrow or the canvas is open")
        let focused = CompanionShotFixture.store()
        focused.newConversation()
        try require(!focused.isVeraThread(focused.selectedID) && focused.section == .chat
                    && CompanionPanelPlacement.decide(isCompanionThread: focused.section == .vera && focused.isVeraThread(focused.selectedID),
                                                      windowWidth: 1600, canvasShowing: false) == .none,
                    "A new focused chat in the store resolves to no companion panel")
        focused.openVeraThread()
        try require(CompanionPanelPlacement.decide(isCompanionThread: focused.section == .vera && focused.isVeraThread(focused.selectedID),
                                                   windowWidth: 1600, canvasShowing: false) == .beside,
                    "Opening the companion thread resolves to the panel")
        print("  companion overview OK (activity, runs, selection, rules title, pause and stop labels, services line, empty states, routing, placement)")
    }
}
