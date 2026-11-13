import AppKit
import SwiftUI

@MainActor
enum WordsShot {
    static let menuDecline = "Opens from the caret on Decline"
    static let menuAllow = "Opens from the caret on Allow"

    static func render(view: String, to path: String, appearance: String) {
        let named = view.hasSuffix("-ada")
        let variant = named ? String(view.dropLast("-ada".count))
            : view.hasSuffix("-unnamed") ? String(view.dropLast("-unnamed".count)) : view
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let name: String? = named ? NativeDotShotFixture.name : nil
        let store = ChatStore()
        store.adoptAssistantName(name ?? "")
        store.ensureVeraThread()
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        var size = CGSize(width: 1000, height: 900)
        let content: AnyView
        switch variant {
        case "words-card-menus":
            size = CGSize(width: 1000, height: 1500)
            content = AnyView(taskMenus(store))
        case "words-activity-stop":
            size = CGSize(width: CompanionProfileMetrics.width + 40, height: 520)
            content = AnyView(activityStop(store, name: name))
        case "words-rules":
            size = CGSize(width: 1240, height: 760)
            content = AnyView(rules(store))
        case "words-limit-cards":
            size = CGSize(width: 760, height: 1000)
            content = AnyView(cards(limitCards(store)))
        case "words-connection-cards":
            size = CGSize(width: 760, height: 1800)
            content = AnyView(cards(connectionCards(store)))
        case "words-scheduled":
            size = CGSize(width: 1180, height: 900)
            seedScheduled(store)
            store.section = .scheduled
            content = AnyView(ShotView(store: store, section: .scheduled, width: size.width))
        case "words-tool-errors":
            size = CGSize(width: 760, height: 1000)
            content = AnyView(toolErrors())
        case "words-tools":
            size = CGSize(width: 760, height: 1000)
            content = AnyView(ScrollView { NativeToolEditor().padding(24) }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        case "words-search":
            size = CGSize(width: 760, height: 420)
            content = AnyView(SearchTab(status: SearchTab.savedOn))
        case "words-mentions":
            size = CGSize(width: 720, height: 420)
            content = AnyView(ComposerMentionList(sections: store.mentionCatalog.sections(""), selection: 3, onHover: { _ in }, onPick: { _ in })
                .frame(width: 640).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        case "words-admission":
            size = CGSize(width: 900, height: 420)
            content = AnyView(admission())
        default:
            FileHandle.standardError.write(Data("Unknown words view\n".utf8))
            exit(1)
        }
        let hosting = NSHostingView(rootView: content
            .environment(\.renderSafe, true)
            .environment(\.companionName, name)
            .environmentObject(store)
            .environmentObject(config)
            .frame(width: size.width, height: size.height)
            .background(Theme.bg)
            .environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("Words render failed\n".utf8))
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Words render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: AppLocations.checkedOutput(path))
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Words image couldn't be saved\n".utf8))
            exit(1)
        }
    }

    static func taskSubjects() -> [NativeCardSubject] {
        [
            NativeCardSubject(action: .commands, toolID: NativeCommandTools.toolID, toolTitle: "Run a command", command: "make pdf"),
            NativeCardSubject(action: .otherChanges, toolID: "garden-log", toolTitle: "Post to the garden log"),
            NativeCardSubject(action: .networkSends, toolID: "workshop-mail", toolTitle: "Send an email",
                              targets: [NativeRuleTarget.make(.recipient, "orders@workshop.example")].compactMap { $0 }, phrase: "send an email"),
        ]
    }

    static func taskCard(_ subject: NativeCardSubject, store: ChatStore) -> (NativeTaskCardPresentation?, CardAnswers, CardAnswers) {
        let threadID = store.veraThreadID ?? "words-thread"
        let place = NativeCardPlace.task(taskID: "words-asked", conversationID: threadID, scheduleID: nil)
        let offered = NativeCardChoices.offered(subject, place: place)
        let wires = offered.map { NativeCardChoices.wire($0, subject: subject) }
        let never = offered.first(where: { $0.kind == .never })?.title ?? ""
        let covers = NativeCardChoices.scope(subject) ?? ""
        let decision: [String: Any] = [
            "id": "words-decision", "prompt": NativeCardChoices.sentence(actor: CompanionSentence.placeholder, subject: subject, title: subject.toolTitle),
            "covers": covers, "never": never, "choices": wires,
        ]
        var card: NativeTaskCardPresentation?
        if let reference = try? OngoingWorkFixture.reference(conversationID: threadID, title: subject.toolTitle, workerType: "companion",
                                                             state: "needs_decision", decision: decision),
           var display = try? NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot) {
            display.card.choices = reference.snapshot?.decision?.choices.filter { NativeTaskCardPresentation.choiceTitle($0) != nil }
            card = display.card
        }
        return (card, CardAnswers.task(choices: wires, covers: covers, neverTitle: never),
                CardAnswers.task(choices: wires, covers: covers, neverTitle: never, run: true))
    }

    static func menus(_ answers: CardAnswers) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Spacer(minLength: 0)
            CardMenuPreview(heading: menuDecline, items: answers.declineMenu)
            CardMenuPreview(heading: menuAllow, items: answers.allowMenu)
        }
    }

    static func taskMenus(_ store: ChatStore) -> some View {
        let built = taskSubjects().map { taskCard($0, store: store) }
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(built.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .trailing, spacing: 10) {
                    if let card = entry.0 {
                        NativeDisplayBlocksView(blocks: [.taskCard(card)], onCancel: { _ in }, onRetry: { _ in }, onDecide: { _, _ in })
                    }
                    menus(entry.1)
                }
            }
            if let run = built.first?.2, let whole = built.dropFirst().first?.2 {
                Text("Scheduled").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                menus(run)
                menus(whole)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func activityStop(_ store: ChatStore, name: String?) -> some View {
        let threadID = store.veraThreadID ?? "words-thread"
        let reference = try? OngoingWorkFixture.reference(conversationID: threadID, title: "Compare quiet reading spaces at three public libraries",
                                                          workerType: "companion", state: "running")
        let display = reference.flatMap { try? NativeTaskProjection.display(reference: $0, snapshot: $0.snapshot) }
        let item = reference.flatMap { reference in
            display.map { CompanionOverviewModel.taskItem(card: $0.card, reference: reference, decision: nil, hasArtifact: false, date: Date()) }
        }
        store.nativeTaskReferences = reference.map { [$0] } ?? []
        let model = CompanionOverviewModel(name: CompanionSubject(name).leading, services: "", rules: "", paused: false,
                                           activity: item.map { [$0] } ?? [], outputs: [])
        return CompanionThreadPanel(fixed: model, selectedID: item?.id)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func rules(_ store: ChatStore) -> some View {
        store.prepareRuleRecords()
        let chat = Conversation(id: "words-greenhouse", title: "Greenhouse notes", messages: [], updatedAt: Date())
        store.conversations.insert(chat, at: 0)
        var tasks: [String] = []
        if let database = (store.repository as? LocalChatRepository)?.database {
            let engine = NativeTaskStore(database: database)
            for (key, assignment) in [("words-titled", "Book the workshop inspection"), ("words-untitled", "")] {
                let payload = (try? JSONSerialization.data(withJSONObject: ["assignment": assignment])) ?? Data()
                if let record = try? engine.create(workerType: "companion", payload: payload, idempotencyKey: key) { tasks.append(record.id) }
            }
        }
        let subjects = taskSubjects()
        if tasks.count == 2 {
            let titled = NativeCardPlace.task(taskID: tasks[0], conversationID: chat.id, scheduleID: nil)
            let untitled = NativeCardPlace.task(taskID: tasks[1], conversationID: chat.id, scheduleID: nil)
            for record in NativeCardChoices.records(.allowHere, subject: subjects[0], place: titled, originMessageID: nil) { store.addRuleRecord(record) }
            for record in NativeCardChoices.records(.never, subject: subjects[1], place: untitled, originMessageID: nil) { store.addRuleRecord(record) }
        }
        for record in NativeCardChoices.records(.never, subject: subjects[0], place: .chat(conversationID: chat.id), originMessageID: nil) {
            store.addRuleRecord(record)
        }
        let opened = store.ruleRows().first(where: { $0.widenQuestion != nil })
        return HStack(alignment: .top, spacing: 16) {
            RulesSettingsTab(showing: RulesAdvancedState()).frame(width: 860)
            if let opened {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Opens from the menu on this row").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    CompanionLineText(line: opened.line).font(.system(size: 12, weight: .semibold))
                    ForEach(opened.menuTitles, id: \.self) { Text($0).font(.system(size: 13)) }
                    Divider()
                    Text("Apply everywhere asks first").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Text(opened.widenQuestion ?? "").font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(RuleRows.cancel) {}
                        Button(RuleRows.widenConfirm) {}.buttonStyle(.borderedProminent)
                    }
                }
                .padding(14)
                .frame(width: 340, alignment: .leading)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
                .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static func cards(_ cards: [NativeTaskCardPresentation]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NativeDisplayBlocksView(blocks: cards.map { .taskCard($0) }, onCancel: { _ in }, onRetry: { _ in }, onDecide: { _, _ in })
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func limitCards(_ store: ChatStore) -> [NativeTaskCardPresentation] {
        let threadID = store.veraThreadID ?? "words-thread"
        let work: [(String, String, String)] = [
            ("companion", "request_limit", "Compare quiet reading spaces at three public libraries"),
            ("companion", "input_limit", "Sort the seed packets by sowing month"),
            ("document", "request_limit", "Workshop plan"),
            ("document", "input_limit", "Greenhouse watering guide"),
            ("research", "request_limit", "Lumber prices this month"),
            ("research", "input_limit", "Insulation options for the workshop"),
        ]
        return work.compactMap { kind, reason, title in
            guard let reference = try? OngoingWorkFixture.reference(conversationID: threadID, title: title, workerType: kind, state: "failed",
                                                                    checkpoint: ["failure_reason": reason]) else { return nil }
            return (try? NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot))?.card
        }
    }

    static var connectionMessages: [String] {
        let http: [NativeTaskHTTPError] = [.unavailable, .status(401), .status(404), .status(409), .status(422), .status(503), .invalidResponse]
        let task: [NativeTaskError] = [.invalidEngine, .engineChanged]
        var messages = http.map(\.localizedDescription) + task.map(\.localizedDescription)
        do { _ = try NativeResearchTaskRequest(objective: "Lumber prices this month", deliverables: ["A short summary"], workerType: "other") }
        catch { messages.append(error.localizedDescription) }
        do { _ = try NativeTaskGenerationLimits(maximumRequests: 0) } catch { messages.append(error.localizedDescription) }
        return messages
    }

    static func connectionCards(_ store: ChatStore) -> [NativeTaskCardPresentation] {
        let threadID = store.veraThreadID ?? "words-thread"
        return connectionMessages.compactMap { message in
            guard var reference = try? OngoingWorkFixture.reference(conversationID: threadID, title: "Lumber prices this month", state: nil) else { return nil }
            reference.lastDeliveryError = message
            return (try? NativeTaskProjection.display(reference: reference, snapshot: nil))?.card
        }
    }

    static func seedScheduled(_ store: ChatStore) {
        NativeScheduleShotFixture.populate(store)
        let zone = TimeZone(identifier: "America/Chicago")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = Date()
        let today5 = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now)!
        guard let frost = try? NativeSchedule(id: "words-frost", owner: .conversation, workerType: "research", title: "Frost check",
                                              instruction: "Check the overnight frost forecast for the greenhouse.",
                                              cadence: .daily(minuteOfDay: 5 * 60), timeZone: zone,
                                              nextRunAt: calendar.date(byAdding: .day, value: 1, to: today5)!,
                                              lastRunAt: today5, lastOutcome: .couldNotStart) else { return }
        store.schedules = [frost] + store.schedules
        store.scheduleRuns[frost.id] = [NativeScheduler.neverStartedNote, NativeScheduler.closedBeforeStartNote, NativeScheduler.refusedNote]
            .enumerated().map { index, detail in
                let day = calendar.date(byAdding: .day, value: -index, to: today5)!
                return NativeScheduleRun(scheduleID: frost.id, scheduledFor: day, startedAt: day, finishedAt: day.addingTimeInterval(30),
                                         outcome: .couldNotStart, detail: detail)
            }
    }

    static func failedActivity(_ id: String, toolID: String, title: String, request: String, error: String) -> NativeToolActivity {
        let result = (try? NativeToolResultBudget.serializedError(error, maximumBytes: 20000)) ?? error
        return NativeToolActivity(id: id, toolID: toolID, name: id, title: title, round: 1, request: request, result: result,
                                  state: .failed, confirmationRequired: false)
    }

    static func toolErrors() -> some View {
        let start = failedActivity("words-start", toolID: NativeTaskTools.toolID, title: "Start work", request: "{\"objective\":\"Lumber prices this month\"}",
                                   error: NativeToolError.invalidArguments(NativeTaskTools.missingArguments).localizedDescription)
        let schedule = failedActivity("words-schedule", toolID: NativeScheduleTools.toolID, title: "Schedule work", request: "{\"title\":\"Frost check\"}",
                                      error: NativeToolError.invalidArguments(NativeScheduleTools.missingArguments).localizedDescription)
        let engine = failedActivity("words-unset", toolID: NativeTaskTools.toolID, title: "Start work",
                                    request: "{\"worker_type\":\"research\",\"objective\":\"Lumber prices this month\",\"deliverables\":[\"A short summary\"]}",
                                    error: NativeTaskError.invalidEngine.localizedDescription)
        return VStack(alignment: .leading, spacing: 14) {
            MessageRow(message: Message(role: .user, text: "Look into lumber prices this month, and check the frost forecast every morning."))
            ForEach([start, schedule, engine]) { activity in
                NativeToolActivityChip(activity: activity, startsExpanded: true)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func admission() -> some View {
        let errors: [NativeInferenceAdmission.AdmissionError] = [.unavailable, .malformed]
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                MessageRow(message: Message(role: .user, text: "What should I plant after the garlic comes out?"))
                MessageRow(message: Message(role: .assistant, text: "", state: .interrupted, failure: error.localizedDescription))
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
