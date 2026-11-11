import Foundation

private final class CardSentenceShownLiterals: @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [String?] = []

    func add(_ literal: String?) {
        lock.lock(); defer { lock.unlock() }
        shown.append(literal)
    }

    var all: [String?] {
        lock.lock(); defer { lock.unlock() }
        return shown
    }
}

extension SelfTest {
    @MainActor
    static func runCardSentenceLiteral() async throws {
        let require = NativeTaskFixture.require
        let placeholder = CompanionSentence.placeholder
        let hostile = ["{name}", "{Name}", "{ name }", "\u{E000}companion\u{E001}"]
        let joined = hostile.joined(separator: " ")
        let names: [String?] = ["Ada", nil]

        func bytes(_ haystack: String, _ needle: String) -> Bool {
            Data(haystack.utf8).range(of: Data(needle.utf8)) != nil
        }
        func occurrences(_ needle: String, in haystack: String) -> Int {
            haystack.components(separatedBy: needle).count - 1
        }
        func nameParts(_ line: CompanionLine) -> Int {
            line.parts.filter { (part: CompanionLinePart) -> Bool in part == .name }.count
        }
        func texts(_ line: CompanionLine) -> [String] {
            line.parts.compactMap { (part: CompanionLinePart) -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
        }
        func insideText(_ line: CompanionLine, _ needle: String) -> Bool {
            texts(line).contains { (text: String) -> Bool in bytes(text, needle) }
        }
        func subject(_ name: String?) -> String {
            name ?? "Your companion"
        }
        func json(_ object: [String: String]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        func request(id: String, toolID: String, name: String, title: String, arguments: [String: String],
                     subject: NativeCardSubject?) throws -> NativeToolConfirmationRequest {
            var built = NativeToolConfirmationRequest(activity: NativeToolActivity(
                id: id, toolID: toolID, name: name, title: title, round: 1, request: try json(arguments),
                result: nil, state: .pending, confirmationRequired: true))
            if let subject {
                built.subject = subject
                built.choices = NativeCardChoices.offered(subject, place: .chat(conversationID: "c1"))
                built.covers = NativeCardChoices.covers(subject)
            }
            return built
        }

        let folderTargets = hostile.compactMap { (folder: String) -> NativeRuleTarget? in
            NativeRuleTarget.make(.folder, "/Volumes/Notes/\(folder)/note.txt")
        }
        try require(folderTargets.count == hostile.count, "Every hostile folder name makes a folder target")
        let folderPath = "/Volumes/Notes/\(joined)/note.txt"
        let folder = try request(id: "f1", toolID: NativeFolderTools.toolID, name: NativeFolderTools.writeName, title: "Write a file",
                                 arguments: ["path": folderPath, "content": "x"],
                                 subject: NativeCardSubject(action: .fileEdits, toolID: NativeFolderTools.toolID, toolTitle: "Write a file",
                                                            targets: folderTargets, phrase: "edit files"))
        let sendTargets = hostile.compactMap { (recipient: String) -> NativeRuleTarget? in NativeRuleTarget.make(.recipient, recipient) }
        try require(sendTargets.count == hostile.count, "Every hostile send target makes a recipient target")
        let send = try request(id: "s1", toolID: "mail.send", name: "send_message", title: "Send a message",
                               arguments: ["to": joined, "body": "Hello \(joined)"],
                               subject: NativeCardSubject(action: .networkSends, toolID: "mail.send", toolTitle: "Send a message",
                                                          targets: sendTargets, phrase: "send a message"))
        let command = "echo \(joined)"
        let commandRequest = try request(id: "r1", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName, title: "Run a command",
                                         arguments: ["command": command],
                                         subject: NativeCardSubject(action: .commands, toolID: NativeCommandTools.toolID,
                                                                    toolTitle: "Run a command", command: command))
        let fallback = try request(id: "t1", toolID: "outside.tool", name: "outside_tool", title: "Run \(joined)",
                                   arguments: ["value": joined], subject: nil)
        let phrased = try request(id: "p1", toolID: "outside.tool", name: "outside_tool", title: "Outside tool",
                                  arguments: ["value": joined],
                                  subject: NativeCardSubject(action: .otherChanges, toolID: "outside.tool", toolTitle: "Outside tool",
                                                             phrase: "change \(joined)"))
        let sendShown = sendTargets.map(\.value)
        let cases: [(String, NativeToolConfirmationRequest, [String])] = [
            ("folder", folder, hostile),
            ("send", send, sendShown),
            ("command", commandRequest, []),
            ("fallback title", fallback, hostile),
            ("tool phrase", phrased, hostile),
        ]
        try require(NativeToolConfirmationBar.sentence(for: commandRequest, actor: "") == " wants to run a command."
                    && !hostile.contains { (text: String) -> Bool in NativeToolConfirmationBar.sentence(for: commandRequest, actor: "").contains(text) },
                    "A command card's sentence never carries the command")

        for (label, card, shown) in cases {
            let rest = NativeToolConfirmationBar.sentence(for: card, actor: "")
            for text in shown {
                try require(bytes(rest, text), "The \(label) sentence carries the tool text \(text)")
            }
            let companion = NativeToolConfirmationBar.sentenceLine(for: card, prompt: nil, actor: placeholder)
            try require(companion.parts.first == .name && nameParts(companion) == 1 && companion.parts == [.name, .text(rest)],
                        "The \(label) companion card has exactly one name part, the actor, first, and the rest is one verbatim text part")
            for text in shown {
                try require(insideText(companion, text), "The \(label) companion card keeps \(text) inside a text part")
            }
            for name in names {
                let plain = companion.plain(name: name)
                try require(plain == subject(name) + rest && plain.hasPrefix(subject(name) + " wants to "),
                            "The \(label) companion card reads as the companion followed by the verbatim rest for \(name ?? "no name")")
                for text in shown {
                    try require(bytes(plain, text), "The \(label) companion card shows \(text) unchanged for \(name ?? "no name")")
                }
            }
            try require(occurrences("Ada", in: companion.plain(name: "Ada")) == 1
                        && occurrences("our companion", in: companion.plain(name: nil)) == 1,
                        "The \(label) companion card names the companion exactly once")
            if !shown.isEmpty, shown.contains(placeholder) {
                try require(CompanionSentence.plain(NativeToolConfirmationBar.sentence(for: card, actor: placeholder), name: "Ada") != companion.plain(name: "Ada"),
                            "The \(label) fixture is one the whole-sentence filler would have rewritten")
            }

            let ordinary = NativeToolConfirmationBar.sentenceLine(for: card, prompt: nil, actor: "Tandem")
            try require(nameParts(ordinary) == 0 && ordinary == .literal("Tandem" + rest)
                        && NativeToolConfirmationBar.sentence(for: card, actor: "Tandem") == "Tandem" + rest,
                        "The \(label) ordinary chat card has no name part and is the existing sentence verbatim")
            for text in shown {
                try require(insideText(ordinary, text), "The \(label) ordinary chat card keeps \(text) inside a text part")
            }
            for name in names {
                let plain = ordinary.plain(name: name)
                try require(plain == "Tandem" + rest && plain.hasPrefix("Tandem wants to ")
                            && !plain.contains("Ada") && !plain.lowercased().contains("your companion"),
                            "The \(label) ordinary chat card never names the companion for \(name ?? "no name")")
                for text in shown {
                    try require(bytes(plain, text), "The \(label) ordinary chat card shows \(text) unchanged for \(name ?? "no name")")
                }
            }
        }

        try require(NativeToolConfirmationBar.literal(for: commandRequest) == command, "The command block is the exact command")
        let commandIn = try request(id: "r2", toolID: NativeCommandTools.toolID, name: NativeCommandTools.runName, title: "Run a command",
                                    arguments: ["command": command, "directory": "/Volumes/Notes/\(joined)"], subject: nil)
        try require(NativeToolConfirmationBar.literal(for: commandIn) == command + "\nin /Volumes/Notes/" + joined,
                    "The command block keeps the command and its folder exactly")
        try require(NativeToolConfirmationBar.literal(for: folder) == folderPath, "The folder block is the exact path")
        let sendLiteral = NativeToolConfirmationBar.literal(for: send) ?? ""
        try require(sendLiteral.components(separatedBy: "\n").contains("To: " + joined)
                    && sendLiteral.components(separatedBy: "\n").contains("Body: Hello " + joined),
                    "The message block keeps the exact recipient and body")
        for text in hostile {
            try require(bytes(sendLiteral, text), "The message block keeps \(text) unchanged")
        }

        let profile = try request(id: "pr1", toolID: NativeCompanionProfileTools.toolID, name: NativeCompanionProfileTools.name,
                                  title: "Update companion profile", arguments: ["action": "connect", "value": joined], subject: nil)
        let profilePrompt = NativeToolConfirmationBar.prompt(for: profile)
        try require(profilePrompt == "Allow this companion to use \(joined)?", "A profile tool card asks about the exact value")
        let profileLine = NativeToolConfirmationBar.sentenceLine(for: profile, prompt: profilePrompt, actor: placeholder)
        try require(nameParts(profileLine) == 0 && profileLine == .literal("Allow this companion to use \(joined)?"),
                    "A profile tool card is all literal")
        for name in names {
            try require(profileLine.plain(name: name) == profilePrompt, "A profile tool card reads unchanged for \(name ?? "no name")")
        }
        let twoLines = NativeToolConfirmationBar.sentenceLine(for: profile, prompt: "First \(placeholder)\nSecond", actor: placeholder)
        try require(twoLines == .literal("First \(placeholder)") && nameParts(twoLines) == 0, "Only the first prompt line shows, verbatim")

        let savedCommand = "\(placeholder) wants to do this: Run a command: echo \(placeholder) {Name}."
        let savedLine = CompanionSavedText.question(savedCommand)
        try require(savedLine.parts == [.name, .text(" wants to do this: Run a command: echo \(placeholder) {Name}.")],
                    "A saved question has one leading name part and a verbatim tail")
        try require(savedLine.plain(name: "Ada") == "Ada wants to do this: Run a command: echo \(placeholder) {Name}."
                    && savedLine.plain(name: nil) == "Your companion wants to do this: Run a command: echo \(placeholder) {Name}.",
                    "The second token in a saved question survives")
        for text in hostile {
            let tail = " wants to open \(text)."
            let line = CompanionSavedText.question(placeholder + tail)
            try require(line.parts == [.name, .text(tail)] && insideText(line, text), "A saved question keeps \(text) in its tail")
            for name in names {
                try require(line.plain(name: name) == subject(name) + tail, "A saved question reads \(text) unchanged for \(name ?? "no name")")
            }
        }
        let finished = "Ada has used this run's working time and saved its progress. Keep going, or finish with what it has?"
        let literalSaved = [
            finished,
            "The model said \(placeholder) could not find the file.",
            "Error: \(joined) is not a folder.",
            "\(placeholder) is paused.",
            "\(placeholder)wants to run this.",
            "\(placeholder) wants  to run this.",
            " \(placeholder) wants to run this.",
            "{Name} wants to run this.",
            "{ name } wants to run this.",
            "\u{E000}companion\u{E001} wants to run this.",
        ]
        for text in literalSaved {
            let line = CompanionSavedText.question(text)
            try require(line == .literal(text) && nameParts(line) == 0 && line.parts == [.text(text)],
                        "Saved text that is not a question stays literal: \(text)")
            for name in names {
                try require(line.plain(name: name) == text, "Saved text reads unchanged for \(name ?? "no name"): \(text)")
            }
        }
        let oldRow = "\(placeholder) wants to create a folder in b."
        let oldLine = CompanionSavedText.question(oldRow)
        try require(oldLine.plain(name: "Ada") == "Ada wants to create a folder in b."
                    && oldLine.plain(name: nil) == "Your companion wants to create a folder in b."
                    && oldLine.plain(name: "Ada") == CompanionSentence.plain(oldRow, name: "Ada")
                    && oldLine.plain(name: nil) == CompanionSentence.plain(oldRow, name: nil),
                    "An old saved question reads exactly as before")

        let hostileQuestion = "\(placeholder) wants to send a message to \(joined)."
        let hostileTail = " wants to send a message to \(joined)."
        let asking = NativeTaskCardPresentation(id: "t", title: "Work", status: .needsInput, milestone: hostileQuestion, workerType: "companion")
        try require(asking.milestoneLine.parts == [.name, .text(hostileTail)] && insideText(asking.milestoneLine, placeholder),
                    "A task card that needs an answer shows the saved question with its tail verbatim")
        for name in names {
            try require(asking.milestoneLine.plain(name: name) == subject(name) + hostileTail, "The task question tail reads unchanged for \(name ?? "no name")")
        }
        let others: [NativeTaskCardPresentation.Status] = [.preparing, .queued, .working, .stopping, .stopped, .completed, .failed]
        for status in others {
            var card = asking
            card.status = status
            try require(card.milestoneLine == .literal(hostileQuestion) && nameParts(card.milestoneLine) == 0,
                        "A task card milestone outside a question is all literal: \(status.rawValue)")
            for name in names {
                try require(card.milestoneLine.plain(name: name) == hostileQuestion, "A literal milestone reads unchanged: \(status.rawValue)")
            }
        }

        for name in names {
            let read = CompanionSavedText.question(hostileQuestion).plain(name: name)
            try require(read == subject(name) + hostileTail, "The saved-question reader keeps the hostile tail for \(name ?? "no name")")
        }

        let overview = ChatStore()
        let overviewConversation = Conversation(id: "card-literal-overview", title: "Card literal", messages: [], updatedAt: Date())
        overview.conversations.insert(overviewConversation, at: 0)
        overview.selectedID = overviewConversation.id
        let decisionReference = try OngoingWorkFixture.reference(conversationID: overviewConversation.id, title: "Hostile question",
                                                                 state: "needs_decision",
                                                                 decision: ["id": "hostile", "prompt": hostileQuestion, "choices": ["retry"]])
        overview.nativeTaskReferences = [decisionReference]
        let decisionCard = try NativeTaskProjection.display(reference: decisionReference, snapshot: decisionReference.snapshot).card
        try require(decisionCard.status == .needsInput && decisionCard.milestone == hostileQuestion, "The fixture task asks the hostile question")
        let taskItem = CompanionOverviewModel.taskItem(card: decisionCard, reference: decisionReference, decision: nil, hasArtifact: false, date: Date())
        overview.schedules = CompanionOverviewFixture.schedules()
        let questionRun = NativeScheduleRun(id: "card-literal-question", scheduleID: "overview-morning", scheduledFor: Date(),
                                            outcome: .waiting, detail: hostileQuestion)
        let literalRun = NativeScheduleRun(id: "card-literal-error", scheduleID: "overview-morning", scheduledFor: Date(),
                                           outcome: .failed, detail: "The model said \(joined) failed.")
        overview.scheduleRuns = ["overview-morning": [questionRun, literalRun]]
        let questionItem = CompanionOverviewModel.runItem(questionRun, schedule: overview.schedules[0])
        let literalItem = CompanionOverviewModel.runItem(literalRun, schedule: overview.schedules[0])
        for name in names {
            overview.adoptAssistantName(name)
            try require(overview.companionActivityDetail(taskItem).outcome == subject(name) + hostileTail,
                        "Companion activity detail for a task question keeps the hostile tail for \(name ?? "no name")")
            try require(overview.companionActivityDetail(questionItem).outcome == subject(name) + hostileTail,
                        "Companion activity detail for a scheduled question keeps the hostile tail for \(name ?? "no name")")
            try require(overview.companionActivityDetail(literalItem).outcome == "The model said \(joined) failed.",
                        "Companion activity detail for other saved text is unchanged for \(name ?? "no name")")
        }

        for name in names {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = try LocalChatRepository(url: directory.appendingPathComponent("chat.sqlite"))
            let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!)
            let origin = try NativeTaskFixture.origin(repository)
            let taskRequest = try NativeResearchTaskRequest(objective: "Hostile check-in", deliverables: ["A short summary"])
            let reference = try repository.prepareTaskReference(origin: origin, engine: engine, request: taskRequest, profile: nil)
            let waiting = try NativeTaskDisplayFixture.snapshot(reference, id: UUID().uuidString, state: "needs_decision",
                                                                decision: ["id": "hostile", "prompt": hostileQuestion, "choices": ["retry"]])
            _ = try repository.acknowledgeTaskReference(id: reference.id, snapshot: waiting)
            _ = try repository.projectTask(id: reference.id, snapshot: waiting)
            let scheduleStore = NativeScheduleStore(database: repository.database)
            var schedule = try NativeSchedule(owner: .conversation, workerType: "research", title: "Hostile check",
                                              instruction: "Check the hostile folder.", cadence: .everyHours(6),
                                              timeZone: TimeZone(identifier: "UTC")!)
            schedule.advance(after: Date(), from: nil)
            try scheduleStore.save(schedule)
            let run = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), startedAt: Date(), outcome: .waiting,
                                        detail: hostileQuestion, conversationID: origin.conversationID,
                                        messageID: origin.assistantMessageID.uuidString, taskReferenceID: reference.id.uuidString)
            try scheduleStore.saveRun(run)
            let before = try repository.messages(conversationID: origin.conversationID).count
            let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: name,
                                  artifactPersistenceEnabled: false)
            store.nativeScheduleStore = scheduleStore
            store.reloadSchedules()
            store.postScheduleCheckIns()
            let messages = try repository.messages(conversationID: origin.conversationID)
            try require(messages.count == before + 1, "One scheduled check-in is posted for \(name ?? "no name")")
            let expected = "The scheduled research \"Hostile check\" stopped to ask: " + subject(name) + hostileTail
            try require(messages.last?.text == expected,
                        "The scheduled check-in quotes the question with its hostile tail unchanged for \(name ?? "no name"): \(messages.last?.text ?? "")")
        }

        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("card-literal-\(UUID().uuidString)", isDirectory: true)
        let inside = base.appendingPathComponent("granted", isDirectory: true)
        let folderName = "\(placeholder) {Name}"
        try manager.createDirectory(at: inside.appendingPathComponent(folderName, isDirectory: true), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let grant = try FolderGrant.make(url: inside)
        let runDirectory = grant.path + "/" + folderName
        let runCommand = "printf '%s' '\(joined)'"
        let recorder = NativeCommandRunRecorder()
        let shownLiterals = CardSentenceShownLiterals()
        try require(NativeCommandClassifier.classify(runCommand, grants: [grant], directory: runDirectory) == .riskyCommands,
                    "A command with braces cannot be fully checked, so it follows the risky commands rule")
        let registry = NativeToolRegistry(definitions: NativeCommandTools.definitions(
            grants: { [grant] }, decision: .ask, reason: { _ in .userApproved }, record: { recorder.add($0) },
            live: { (_: String, action: NativeActionClass) -> NativeRuleDecision? in action == .riskyCommands ? .ask : nil }))
        let arguments = try json(["command": runCommand, "directory": runDirectory])
        let transport = ScriptedNativeToolTransport(rounds: [
            [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: "hostile-run", name: NativeCommandTools.runName, arguments: arguments)],
                                      finishReason: "tool_calls")],
            [NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")],
        ])
        let loop = NativeToolLoop(transport: transport, registry: registry, confirm: { (activity: NativeToolActivity) async -> Bool in
            let shown = await MainActor.run { () -> String? in
                NativeToolConfirmationBar.literal(for: NativeToolConfirmationRequest(activity: activity))
            }
            shownLiterals.add(shown)
            return true
        })
        var final: NativeToolTurnSnapshot?
        for try await snapshot in loop.stream(messages: [NativeChatMessage(role: "user", content: "run it")], model: "local-model",
                                              enabledToolIDs: [NativeCommandTools.toolID]) {
            final = snapshot
        }
        let shownBlock = shownLiterals.all
        try require(shownBlock.count == 1 && shownBlock[0] == runCommand + "\nin " + runDirectory,
                    "The card showed the exact command and folder: \(shownBlock) \(final?.activities.first?.result ?? "no result")")
        let shownLines = (shownBlock.first ?? nil)?.components(separatedBy: "\nin ") ?? []
        try require(final?.activities.first?.state == .succeeded && recorder.recorded.count == 1,
                    "The approved hostile command ran once: \(final?.activities.first?.result ?? "no result")")
        let ran = recorder.recorded[0]
        try require(shownLines.count == 2 && ran.command == shownLines[0] && Data(ran.command.utf8) == Data(runCommand.utf8),
                    "The command handed to the runner is the card's command line byte for byte: \(ran.command)")
        try require(ran.directory == shownLines[1] && ran.stdout == joined && ran.exitCode == 0,
                    "The command ran in the folder the card showed and printed the hostile text unchanged: \(ran.directory) \(ran.stdout)")

        print("  card sentence literal OK (companion and ordinary chat cards, folder, send, command, tool title and phrase, literal blocks, profile prompt, saved questions, old rows, task milestones, activity detail, scheduled check-in, what runs is what was shown)")
    }
}
