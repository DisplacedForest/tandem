import Combine
import Foundation

@MainActor
extension SelfTest {
    static func runScheduleAnythingElse() async throws {
        let require = NativeTaskFixture.require
        try await scheduleAnythingElseStore(require)
        try scheduleAnythingElseTool(require)
        try await scheduleAnythingElseAdvertised(require)
        try await scheduleAnythingElseLoop(require)
        try scheduleAnythingElseCard(require)
        try scheduleAnythingElseWords(require)
        print("  schedule anything else OK (store create, reload, edit, run without search, paused, tool unchanged in ordinary chats, companion kind, advertised per conversation, ordinary chat refuses the extra kind without a card, ordinary research still asks, companion asks and Allow saves, Decline saves nothing, unreadable request refused without a card in both, card, check-in, detail line, empty state, words)")
    }

    private static func scheduleAnythingElseStore(_ require: (Bool, String) throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("chat.sqlite"))
        let config = NativeChatConfig(baseURL: URL(string: "https://fixture.invalid/v1")!, apiKey: nil, model: "fixture", chatTemplateKwargs: nil)
        let store = ChatStore(nativeConfig: config, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                              nativeSearchAvailable: { false }, artifactPersistenceEnabled: false)
        await store.connect()
        defer { store.stopNativeTaskRecovery() }
        var draft = NativeScheduleDraft()
        draft.title = NativeScheduleShotFixture.anythingElseTitle
        draft.instruction = NativeScheduleShotFixture.anythingElseInstruction
        draft.workerType = NativeSchedule.companionWorkerType
        draft.owner = .conversation
        draft.cadence = .weekdays(minuteOfDay: 7 * 60)
        guard let created = store.createSchedule(draft), let scheduleStore = store.nativeScheduleStore else {
            throw NativeTaskFixture.Failure.assertion("A schedule for anything else saves: \(store.scheduleError ?? "")")
        }
        try require(created.owner == .dot && created.isCompanionWork, "A schedule for anything else always reports to the companion")
        let reloaded = try scheduleStore.get(created.id)
        try require(reloaded?.workerType == NativeSchedule.companionWorkerType && reloaded?.owner == .dot,
                    "It reloads from the store as anything else, reporting to the companion")
        var edited = draft
        edited.title = "Morning summary, short"
        edited.owner = .conversation
        store.updateSchedule(created.id, with: edited)
        let afterEdit = try scheduleStore.get(created.id)
        try require(afterEdit?.title == "Morning summary, short" && afterEdit?.owner == .dot && afterEdit?.isCompanionWork == true,
                    "Editing keeps it reporting to the companion")
        guard let live = afterEdit else { throw NativeTaskFixture.Failure.assertion("The edited schedule exists") }
        let probe = NativeScheduleRun(scheduleID: live.id, scheduledFor: Date(), outcome: .running)
        let fired = await store.fireSchedule(live, run: probe, bind: { _, _ in })
        if case .failed(let reason) = fired, reason.contains("Search") {
            throw NativeTaskFixture.Failure.assertion("Anything else runs without search: \(reason)")
        }
        guard case .started = fired else { throw NativeTaskFixture.Failure.assertion("Anything else starts without search: \(fired)") }
        var research = NativeScheduleDraft()
        research.title = "Frost check"
        research.instruction = "Check the frost forecast."
        guard let researchSchedule = store.createSchedule(research) else { throw NativeTaskFixture.Failure.assertion("A research schedule saves") }
        let researchFired = await store.fireSchedule(researchSchedule, run: NativeScheduleRun(scheduleID: researchSchedule.id, scheduledFor: Date(), outcome: .running),
                                                     bind: { _, _ in })
        try require(researchFired == .failed("Search isn't set up. Add a search URL in Settings."), "Research still needs search: \(researchFired)")
        store.setDotState(.paused)
        let paused = await store.fireSchedule(live, run: probe, bind: { _, _ in })
        try require(paused == .skipped(CompanionSavedText.marker + " is paused."), "A paused companion skips anything else: \(paused)")
        store.setDotState(.active)
    }

    private static func scheduleAnythingElseTool(_ require: (Bool, String) throws -> Void) throws {
        let zone = TimeZone(identifier: "America/Chicago")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let save: @Sendable (NativeScheduleDraft) async throws -> NativeSchedule = { _ in throw NativeToolError.unavailable }
        let ordinary = NativeScheduleTools.definition(now: { now }, timeZone: { zone }, save: save)
        let companion = NativeScheduleTools.definition(general: true, now: { now }, timeZone: { zone }, save: save)
        let original = "Propose a schedule only when the current user message explicitly asks for research or a written document to happen on a repeating basis or at a later time (every day, on weekdays, weekly, every few hours, or once at a set time). Nothing runs now and nothing is saved by this call alone: the user confirms the cadence and the work in the app first. Use worker_type research for a question answered from web sources, document for a written deliverable. Give a short title and the full instruction. Give time as 24-hour HH:MM in the user's local time. Use results_to assistant when the user wants results in the ongoing assistant thread, otherwise own_chat. Then acknowledge in one sentence. Do not claim the schedule exists until the tool result says it was saved, and do not expose internal identifiers."
        try require(ordinary.name == "schedule_task" && ordinary.title == "Schedule work" && ordinary.description == original,
                    "An ordinary chat's schedule tool keeps its name and description exactly")
        try require(CompanionAskedWorkFixture.kinds(ordinary.schema) == ["research", "document"], "An ordinary chat's kinds are research and document")
        try require(CompanionAskedWorkFixture.kinds(companion.schema) == ["research", "document", NativeTaskTools.generalWorkerType],
                    "The companion's conversation adds one more kind")
        try require(companion.name == ordinary.name && companion.description.hasPrefix(NativeScheduleTools.descriptionLead)
                    && companion.description.hasSuffix(NativeScheduleTools.descriptionTail) && companion.description.contains("worker_type general"),
                    "The companion's description adds one note and keeps the rest")
        guard case .object(var root) = companion.parameters, case .object(var properties)? = root["properties"],
              case .object(var kind)? = properties["worker_type"] else {
            throw NativeTaskFixture.Failure.assertion("The companion's parameters have a kind")
        }
        kind["enum"] = .array([.string("research"), .string("document")])
        properties["worker_type"] = .object(kind)
        root["properties"] = .object(properties)
        try require(NativeJSONValue.object(root) == ordinary.parameters, "The parameters differ only in the extra kind")

        func arguments(_ kind: String, resultsTo: String? = nil) -> [String: NativeJSONValue] {
            var values: [String: NativeJSONValue] = ["title": .string("Morning summary"), "worker_type": .string(kind),
                                                     "instruction": .string("Check my calendar."), "repeat": .string("weekdays"), "time": .string("07:00")]
            if let resultsTo { values["results_to"] = .string(resultsTo) }
            return values
        }
        do {
            _ = try NativeScheduleTools.draft(from: arguments(NativeTaskTools.generalWorkerType), now: now, timeZone: zone)
            throw NativeTaskFixture.Failure.assertion("An ordinary chat refuses the extra kind")
        } catch let error as NativeToolError {
            try require(error == .invalidArguments("Scheduled work must be research or a document."), "The refusal is unchanged: \(error)")
        }
        try require((try? NativeScheduleTools.draft(from: arguments(NativeSchedule.companionWorkerType), now: now, timeZone: zone, general: true)) == nil,
                    "The stored kind name is never accepted from the model")
        for resultsTo in [nil, "own_chat", "assistant"] {
            let mapped = try NativeScheduleTools.draft(from: arguments(NativeTaskTools.generalWorkerType, resultsTo: resultsTo), now: now, timeZone: zone, general: true)
            try require(mapped.workerType == NativeSchedule.companionWorkerType && mapped.owner == .dot,
                        "The extra kind becomes anything else for the companion with results_to \(resultsTo ?? "unset")")
        }
        let research = try NativeScheduleTools.draft(from: arguments("research", resultsTo: "own_chat"), now: now, timeZone: zone, general: true)
        try require(research.workerType == "research" && research.owner == .conversation, "Research in the companion's conversation is unchanged")
    }

    private static func scheduleAnythingElseAdvertised(_ require: (Bool, String) throws -> Void) async throws {
        let ask = "Every weekday at 7 research lunar ice news."
        let harness = try CompanionAskedWorkFixture.harness { _, _, _ in CompanionAskedWorkTransport.say("Done.") }
        defer { harness.store.conversationTurnLoop?.cancel() }
        harness.store.nativeScheduleStore = NativeScheduleStore(database: harness.repository.database)
        func offered() -> NativeToolSchema? {
            harness.transport.records.last { $0.user == ask }?.tools.first { $0.name == NativeScheduleTools.toolName }
        }
        _ = try await CompanionAskedWorkFixture.send(harness, ask)
        let inThread = offered()
        try require(CompanionAskedWorkFixture.kinds(inThread) == ["research", "document", NativeTaskTools.generalWorkerType]
                    && inThread?.description == NativeScheduleTools.description(general: true),
                    "The companion's conversation is offered anything else: \(CompanionAskedWorkFixture.kinds(inThread))")
        harness.store.newConversation()
        guard let focused = harness.store.selectedID, focused != harness.threadID else { throw NativeTaskFixture.Failure.assertion("A focused chat opens") }
        _ = try await CompanionAskedWorkFixture.send(harness, ask, conversationID: focused)
        let inChat = offered()
        try require(CompanionAskedWorkFixture.kinds(inChat) == ["research", "document"] && inChat?.description == NativeScheduleTools.description(general: false),
                    "An ordinary chat is offered the unchanged tool: \(CompanionAskedWorkFixture.kinds(inChat))")
    }

    private static func scheduleAnythingElseCard(_ require: (Bool, String) throws -> Void) throws {
        let request = "{\"title\":\"Morning summary\",\"worker_type\":\"general\",\"instruction\":\"Check my calendar and the weather.\",\"results_to\":\"own_chat\",\"repeat\":\"weekdays\",\"time\":\"07:00\"}"
        let card = NativeToolConfirmationRequest(activity: NativeToolActivity(id: "anything", toolID: NativeScheduleTools.toolID, name: NativeScheduleTools.toolName,
            title: "Schedule work", round: 1, request: request, result: nil, state: .pending, confirmationRequired: true))
        let placeholder = CompanionSentence.placeholder
        let block = NativeToolConfirmationBar.literal(for: card, companionThread: true) ?? ""
        try require(block.hasPrefix("Morning summary, weekdays at") && block.hasSuffix("Check my calendar and the weather."),
                    "The companion's card shows the name, cadence and what it will do: \(block)")
        let closing = NativeToolConfirmationBar.closingLine(for: card, actor: placeholder, companionThread: true)
        try require(closing?.plain(name: "Ada") == "Results go to Ada." && closing?.plain(name: nil) == "Results go to your companion.",
                    "The companion's card says results go to the companion")
        try require(NativeToolConfirmationBar.literal(for: card) == nil && NativeToolConfirmationBar.closingLine(for: card, actor: "Tandem") == nil,
                    "An ordinary chat shows no schedule details for anything else")

        let zone = TimeZone(identifier: "UTC")!
        let summary = try NativeSchedule(owner: .conversation, workerType: NativeSchedule.companionWorkerType, title: "Morning summary",
                                         instruction: "Check my calendar.", cadence: .weekdays(minuteOfDay: 7 * 60), timeZone: zone)
        let research = try NativeSchedule(owner: .conversation, workerType: "research", title: "Frost check",
                                          instruction: "Check the frost.", cadence: .weekdays(minuteOfDay: 7 * 60), timeZone: zone)
        let document = try NativeSchedule(owner: .dot, workerType: "document", title: "Weekly digest",
                                          instruction: "Write it.", cadence: .weekdays(minuteOfDay: 7 * 60), timeZone: zone)
        try require(summary.owner == .dot && research.owner == .conversation, "Only anything else is forced to the companion")
        try require(summary.checkInSentence("Which calendar?") == "The scheduled \"Morning summary\" stopped to ask: Which calendar?"
                    && research.checkInSentence("Which bed?") == "The scheduled research \"Frost check\" stopped to ask: Which bed?"
                    && document.checkInSentence("Which week?") == "The scheduled document \"Weekly digest\" stopped to ask: Which week?",
                    "The check-in names the kind for research and documents only")
        let summaryLine = NativeScheduleControls.resultsLine(summary.detailLead, toCompanion: summary.owner == .dot, end: ".")
        try require(summaryLine.plain(name: "Ada") == "\(summary.cadenceSummary). Results go to Ada."
                    && summaryLine.plain(name: nil) == "\(summary.cadenceSummary). Results go to your companion.",
                    "The detail line for anything else has no kind word: \(summaryLine.plain(name: "Ada"))")
        try require(NativeScheduleControls.resultsLine(research.detailLead, toCompanion: false, end: ".").plain(name: "Ada")
                        == "Research. \(research.cadenceSummary). Results go to its own chat."
                    && NativeScheduleControls.resultsLine(document.detailLead, toCompanion: true, end: ".").plain(name: "Ada")
                        == "Document. \(document.cadenceSummary). Results go to Ada.",
                    "The detail line for research and documents is unchanged")
        try require(summary.workTitle == "Research" && research.workTitle == "Research" && document.workTitle == "Document",
                    "The kind title keeps its old results")
        try require(ScheduledView.emptyMessage == "Set up research, a document or anything else to run every day, on weekdays, weekly, every few hours, or once.",
                    "The empty state names all three kinds")
        try require(ScheduleEditor.instructionLabel("document") == "What to write" && ScheduleEditor.instructionLabel("research") == "What to look into"
                    && ScheduleEditor.instructionLabel(NativeSchedule.companionWorkerType) == "What to do",
                    "The editor asks what to do for anything else")
        try require(ScheduleEditor.workKinds.map(\.title) == ["Research", "Document", "Anything else"]
                    && ScheduleEditor.workKinds.map(\.tag) == ["research", "document", NativeSchedule.companionWorkerType],
                    "The editor offers anything else, and an existing one opens with it selected")
        try require(CompanionLine.named(ScheduleEditor.companionResults).plain(name: nil) == "Results go to your companion."
                    && CompanionLine.named(ScheduleEditor.companionResults).plain(name: "Ada") == "Results go to Ada.",
                    "The editor says results go to the companion")
    }

    private static func scheduleAnythingElseWords(_ require: (Bool, String) throws -> Void) throws {
        let summary = try NativeSchedule(owner: .dot, workerType: NativeSchedule.companionWorkerType, title: "Morning summary",
                                         instruction: "Check my calendar.", cadence: .weekdays(minuteOfDay: 7 * 60), timeZone: TimeZone(identifier: "UTC")!)
        let shown = [
            ScheduledView.emptyMessage, ScheduleEditor.instructionLabel(NativeSchedule.companionWorkerType),
            CompanionLine.named(ScheduleEditor.companionResults).plain(name: nil),
            NativeScheduleControls.resultsLine(summary.detailLead, toCompanion: true, end: ".").plain(name: nil),
            summary.checkInSentence("Which calendar?"),
        ] + ScheduleEditor.workKinds.map(\.title)
        let banned = Set(CompanionTalkControlFixture.banned + CompanionTalkControlFixture.pronouns)
        for text in shown {
            let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            try require(!words.contains { banned.contains($0) } && !text.contains("\u{2014}"), "New wording stays plain: \(text)")
        }
    }

    private static func scheduleAnythingElseLoop(_ require: (Bool, String) throws -> Void) async throws {
        let ask = "Every weekday at 7 research lunar ice news."
        let calls = ScheduleAnythingElseCalls()
        let harness = try CompanionAskedWorkFixture.harness { _, messages, _ in
            if CompanionAskedWorkTransport.answered(messages) { return CompanionAskedWorkTransport.say("Done.") }
            return CompanionAskedWorkTransport.hand([CompanionAskedWorkTransport.call(NativeScheduleTools.toolName, calls.next())])
        }
        defer { harness.store.conversationTurnLoop?.cancel() }
        let scheduleStore = NativeScheduleStore(database: harness.repository.database)
        harness.store.nativeScheduleStore = scheduleStore
        let raised = ScheduleAnythingElseCards()
        let watch = harness.store.$pendingToolConfirmation.sink { if $0 != nil { raised.add() } }
        defer { watch.cancel() }
        harness.store.newConversation()
        guard let focused = harness.store.selectedID, focused != harness.threadID else { throw NativeTaskFixture.Failure.assertion("A focused chat opens") }

        func arguments(_ kind: String, repeatKind: String = "weekdays") -> [String: NativeJSONValue] {
            ["title": .string("Morning summary"), "worker_type": .string(kind), "instruction": .string("Check my calendar and the weather."),
             "repeat": .string(repeatKind), "time": .string("07:00")]
        }
        func toolReply(_ text: String) -> String {
            let records = harness.transport.records.filter { $0.user == text }
            return records.last?.messages.last { $0.role == "tool" }?.content ?? ""
        }
        func turn(_ label: String, in conversationID: String, _ values: [String: NativeJSONValue], decide: Bool?) async throws -> Message {
            calls.set(values)
            let text = ask + " " + label
            let before = raised.count
            try require(harness.store.sendText(text, conversationID: conversationID, fromComposer: true), "The message is accepted: \(label)")
            if let decide {
                try await NativeSessionFixture.eventually("A card is raised: \(label)") { harness.store.pendingToolConfirmation != nil }
                try require(harness.store.pendingToolConfirmation?.toolID == NativeScheduleTools.toolID, "The card is for the schedule: \(label)")
                harness.store.resolveToolConfirmation(decide)
            }
            var answer: Message?
            try await NativeSessionFixture.eventually("The reply completes: \(label)") {
                let saved = (try? harness.repository.messages(conversationID: conversationID)) ?? []
                guard let index = saved.lastIndex(where: { $0.role == .user && $0.text == text }), saved.indices.contains(index + 1),
                      saved[index + 1].state == .complete,
                      !harness.store.conversationTurns.contains(where: { $0.conversationID == conversationID && ($0.state == .pending || $0.state == .running) })
                else { return false }
                answer = saved[index + 1]
                return true
            }
            try require(raised.count == before + (decide == nil ? 0 : 1), "\(decide == nil ? "No card" : "One card") is raised: \(label)")
            guard let answer else { throw NativeTaskFixture.Failure.assertion("The reply exists: \(label)") }
            return answer
        }

        let refused = "Scheduled work must be research or a document."
        _ = try await turn("ordinary general", in: focused, arguments(NativeTaskTools.generalWorkerType), decide: nil)
        try require(toolReply(ask + " ordinary general").contains(refused) && (try scheduleStore.all()).isEmpty,
                    "An ordinary chat refuses the extra kind before asking, saves nothing and tells the model why: \(toolReply(ask + " ordinary general"))")

        _ = try await turn("ordinary research", in: focused, arguments("research"), decide: false)
        try require((try scheduleStore.all()).isEmpty, "Declining ordinary research saves nothing")

        _ = try await turn("companion decline", in: harness.threadID, arguments(NativeTaskTools.generalWorkerType), decide: false)
        try require((try scheduleStore.all()).isEmpty, "Declining in the companion's conversation saves nothing")

        _ = try await turn("companion allow", in: harness.threadID, arguments(NativeTaskTools.generalWorkerType), decide: true)
        let saved = try scheduleStore.all()
        try require(saved.count == 1 && saved[0].workerType == NativeSchedule.companionWorkerType && saved[0].owner == .dot,
                    "Allow in the companion's conversation saves anything else for the companion: \(saved.map(\.workerType))")

        let weekday = "A weekly schedule needs a weekday."
        for (label, conversationID) in [("ordinary weekly", focused), ("companion weekly", harness.threadID)] {
            _ = try await turn(label, in: conversationID, arguments("research", repeatKind: "weekly"), decide: nil)
            try require(toolReply(ask + " " + label).contains(weekday) && (try scheduleStore.all()).count == 1,
                        "An unreadable request is refused before asking with its own reason: \(label) \(toolReply(ask + " " + label))")
        }
    }
}

final class ScheduleAnythingElseCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: NativeJSONValue] = [:]

    func set(_ next: [String: NativeJSONValue]) { lock.withLock { values = next } }
    func next() -> [String: NativeJSONValue] { lock.withLock { values } }
}

@MainActor
final class ScheduleAnythingElseCards {
    private(set) var count = 0
    func add() { count += 1 }
}
