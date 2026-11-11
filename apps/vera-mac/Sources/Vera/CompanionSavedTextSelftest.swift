import Foundation

@MainActor
enum CompanionSavedTextFixture {
    static let marker = CompanionSavedText.marker
    static let tokens = ["{name}", "{Name}", "{ name }"]
    static let hostile = tokens + [CompanionSavedText.marker]
    static var hostileJoined: String { hostile.joined(separator: " ") }
    static var tokensJoined: String { tokens.joined(separator: " ") }
    static let assignment = "Water the north bed"
    static let capQuestion = CompanionSavedText.marker + " has used this run's actions and saved its progress. Keep going, or finish with what it has?"
    static let pausedNote = CompanionSavedText.marker + " is paused."
    static let missedNote = "Missed while " + CompanionSavedText.marker + " was paused."
    static let approvalQuestion = CompanionSavedText.marker + " wants to create a folder in Seeds."

    static func result(_ report: String, shape: String?) -> [String: Any] {
        let summary = report.components(separatedBy: "\n\n").first ?? report
        var result: [String: Any] = ["kind": "companion_report", "query": assignment, "title": assignment, "report": report,
                                     "summary": summary, "sources": [], "effects": []]
        if let shape { result["shape"] = shape }
        return result
    }

    static func handOffResult() -> [String: Any] {
        result(NativeCompanionWorker.handOffText(title: "Send the seed order to Ana", action: nil), shape: nil)
    }

    static func declinedResult() -> [String: Any] {
        result("Stopped because you declined: Send the seed order to Ana.", shape: NativeCompanionShape.answer)
    }

    static func reference(state: String, conversationID: String = "saved-text-thread", result: [String: Any]? = nil,
                          decision: [String: Any]? = nil) throws -> NativeTaskReference {
        try OngoingWorkFixture.reference(conversationID: conversationID, title: assignment, workerType: "companion", state: state,
                                         result: result, decision: decision)
    }

    static func approvalDecision() -> [String: Any] {
        ["id": "saved-approval", "prompt": approvalQuestion, "choices": ["decline", "allow_always", "approve"],
         "details": "Create a folder\npath: ~/Documents/Garden/Seeds/2027"]
    }

    static func cards() -> [NativeTaskCardPresentation] {
        var cards: [NativeTaskCardPresentation] = []
        for (state, result, decision) in [("completed", handOffResult(), nil), ("completed", declinedResult(), nil),
                                          ("needs_decision", nil, approvalDecision())] as [(String, [String: Any]?, [String: Any]?)] {
            if let reference = try? reference(state: state, result: result, decision: decision),
               var card = try? NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot).card {
                card.choices = reference.snapshot?.decision?.choices.filter { (choice: String) -> Bool in NativeTaskCardPresentation.choiceTitle(choice) != nil }
                cards.append(card)
            }
        }
        return cards
    }

    static func scheduleRuns(_ store: ChatStore) {
        guard let schedule = store.schedules.first(where: { $0.owner == .dot }) else { return }
        let now = Date()
        let paused = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: now.addingTimeInterval(-3600), finishedAt: now,
                                       outcome: .skipped, detail: pausedNote)
        let missed = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: now.addingTimeInterval(-7200), finishedAt: now,
                                       outcome: .skipped, detail: missedNote)
        store.scheduleRuns[schedule.id] = [paused, missed] + (store.scheduleRuns[schedule.id] ?? [])
    }

    static func libraryItems(_ store: ChatStore) -> String? {
        guard let thread = store.veraThreadID else { return nil }
        store.recordTaskArtifacts([NativeDisplayBlock.artifact(NativeResearchArtifact(id: "saved-text-before", title: "Frost checklist",
                                                                      report: "# Frost checklist\n\nCover the beds.", sources: []))],
                                  conversationID: thread, messageID: UUID().uuidString)
        _ = try? store.artifactRepository?.resolveArtifacts(conversationID: thread, choice: .keep)
        store.recordTaskArtifacts([NativeDisplayBlock.artifact(NativeResearchArtifact(id: "saved-text-linked", title: "Weekly greenhouse note",
                                                                      report: "# Weekly note\n\nVents checked.", sources: []))],
                                  conversationID: thread, messageID: UUID().uuidString)
        store.reloadArtifacts()
        return store.artifactRecords.first { $0.title == "Frost checklist" }?.id
    }
}

@MainActor
extension SelfTest {
    static func runCompanionSavedText() async throws {
        try savedTextReader()
        try savedTextRoundTrip()
        let reports = try await savedTextWriters()
        try savedTextRename()
        try await savedTextRunNotes()
        try await savedTextModelInput(reports)
        try await savedTextLeakScan(reports)
        try savedTextLibrary()
        print("  companion saved text OK (marker reader, legacy rows, outside text, round trip through the store and the database, worker questions for a folder, a send, a command, the limit and a check, name-free reports, rename, run notes by outcome and by the run's own task, fire path notes, check-in, tool result, observation, memory note, leak scan, Library origin)")
    }

    private static var marker: String { CompanionSavedText.marker }

    nonisolated private static func savedTextJSON(_ object: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static func hasMarkerScalar(_ text: String) -> Bool {
        text.unicodeScalars.contains { (scalar: Unicode.Scalar) -> Bool in scalar == "\u{E000}" || scalar == "\u{E001}" }
    }

    private static func nameParts(_ line: CompanionLine) -> Int {
        line.parts.filter { (part: CompanionLinePart) -> Bool in part == .name }.count
    }

    private static func savedTextReader() throws {
        let require = NativeTaskFixture.require
        let start = marker + " is paused."
        try require(CompanionSavedText.line(start, appWritten: true) == .parts([.name, .text(" is paused.")]),
                    "A marker at the start is one name part and the verbatim rest")
        try require(CompanionSavedText.plain(start, name: "Ada", appWritten: true) == "Ada is paused."
                    && CompanionSavedText.plain(start, name: nil, appWritten: true) == "Your companion is paused.",
                    "A leading marker reads as the name, or Your companion")
        let middle = "Missed while " + marker + " was paused."
        try require(CompanionSavedText.line(middle, appWritten: true) == .parts([.text("Missed while "), .name, .text(" was paused.")])
                    && CompanionSavedText.plain(middle, name: "Ada", appWritten: true) == "Missed while Ada was paused."
                    && CompanionSavedText.plain(middle, name: nil, appWritten: true) == "Missed while your companion was paused.",
                    "A marker in the middle reads lowercase when unnamed")
        let twice = marker + " asked. " + marker + " waited, then " + marker + " stopped."
        try require(nameParts(CompanionSavedText.line(twice, appWritten: true)) == 3
                    && CompanionSavedText.plain(twice, name: "Ada", appWritten: true) == "Ada asked. Ada waited, then Ada stopped."
                    && CompanionSavedText.plain(twice, name: nil, appWritten: true) == "Your companion asked. Your companion waited, then your companion stopped.",
                    "Every marker is a name part, capitalised only at a sentence start")
        for name in ["Ada", "Moss", nil] as [String?] {
            let legacy = "{name} wants to create a folder in b."
            try require(CompanionSavedText.plain(legacy, name: name, appWritten: true) == CompanionSentence.plain(legacy, name: name),
                        "A legacy question reads as before for \(name ?? "no name")")
        }
        let legacyCommand = "{name} wants to do this: Run a command: echo {name} " + marker + "."
        try require(CompanionSavedText.line(legacyCommand, appWritten: true)
                        == .parts([.name, .text(" wants to do this: Run a command: echo {name} " + marker + ".")]),
                    "A legacy question keeps every later token and any marker scalars in its verbatim tail")
        for text in [start, middle, twice, legacyCommand, "{name} is paused.", marker, "Plain text."] {
            try require(CompanionSavedText.line(text, appWritten: false) == .literal(text)
                        && CompanionSavedText.plain(text, name: "Ada", appWritten: false) == text,
                        "Text that is not app-written stays literal: \(text)")
        }
        for text in ["{name} is paused.", "{Name} wants to go.", " {name} wants to go.", "Plain text."] {
            try require(CompanionSavedText.line(text, appWritten: true) == .literal(text), "App-written text without a marker stays literal: \(text)")
        }
        let mixed = "a\u{E000}b\u{E001}c{name}\u{E002}e\u{0301}" + marker
        try require(Array(CompanionSavedText.sanitized(mixed).unicodeScalars) == Array("abc{name}\u{E002}e\u{0301}companion".unicodeScalars),
                    "Sanitizing removes only the two marker scalars")
        try require(CompanionSavedText.sanitized(CompanionSavedTextFixture.tokensJoined) == CompanionSavedTextFixture.tokensJoined,
                    "Sanitizing leaves template tokens alone")
    }

    private static func savedTextRoundTrip() throws {
        let require = NativeTaskFixture.require
        let prompt = marker + " wants to create a folder in " + CompanionSavedText.sanitized(CompanionSavedTextFixture.hostileJoined) + "."
        let decision: [String: Any] = ["id": "round-trip", "prompt": prompt, "choices": ["approve", "decline"]]
        let canonical = try NativeTaskStore.canonical(decision)
        let decoded = try JSONDecoder().decode(NativeTaskDecision.self, from: canonical)
        let again = try JSONDecoder().decode(NativeTaskDecision.self, from: JSONEncoder().encode(decoded))
        try require(Data(decoded.prompt.utf8) == Data(prompt.utf8) && Data(again.prompt.utf8) == Data(prompt.utf8),
                    "A marker question survives canonical JSON and Codable byte for byte")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saved-text-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chat.sqlite")
        let referenceID: UUID
        let runID: String
        let waitingID: String
        do {
            let repository = try LocalChatRepository(url: url)
            let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!)
            let origin = try NativeTaskFixture.origin(repository)
            let request = try NativeResearchTaskRequest(objective: "Saved text check", deliverables: [], workerType: "companion")
            let reference = try repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: nil)
            var object = (try JSONSerialization.jsonObject(with: NativeTaskFixture.snapshot(reference, id: UUID().uuidString,
                                                                                            state: "needs_decision"))) as? [String: Any] ?? [:]
            object["worker_type"] = "companion"
            object["decision"] = decision
            let waiting = try JSONDecoder().decode(NativeTaskSnapshot.self, from: NativeTaskClient.canonical(object))
            _ = try repository.acknowledgeTaskReference(id: reference.id, snapshot: waiting)
            _ = try repository.projectTask(id: reference.id, snapshot: waiting)
            let schedules = NativeScheduleStore(database: repository.database)
            var schedule = try NativeSchedule(owner: .dot, workerType: "companion", title: "Saved check", instruction: "Check the beds.",
                                              cadence: .everyHours(6), timeZone: TimeZone(identifier: "UTC")!)
            schedule.advance(after: Date(), from: nil)
            try schedules.save(schedule)
            let paused = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), outcome: .skipped,
                                           detail: CompanionSavedTextFixture.missedNote)
            let asking = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), outcome: .waiting, detail: prompt,
                                           taskReferenceID: reference.id.uuidString)
            try schedules.saveRun(paused)
            try schedules.saveRun(asking)
            referenceID = reference.id
            runID = paused.id
            waitingID = asking.id
        }
        let reopened = try LocalChatRepository(url: url)
        let saved = try reopened.taskProjection(id: referenceID)?.snapshot?.decision?.prompt ?? ""
        let referenced = try reopened.taskReference(id: referenceID)?.snapshot?.decision?.prompt ?? ""
        let runs = NativeScheduleStore(database: reopened.database)
        try require(Data(saved.utf8) == Data(prompt.utf8) && Data(referenced.utf8) == Data(prompt.utf8),
                    "The saved task projection and reference hold the marker question byte for byte after reopening")
        try require(Data((try runs.run(runID)?.detail ?? "").utf8) == Data(CompanionSavedTextFixture.missedNote.utf8)
                    && Data((try runs.run(waitingID)?.detail ?? "").utf8) == Data(prompt.utf8),
                    "Saved run notes hold the marker byte for byte after reopening")
    }

    private static func requireQuestion(_ prompt: String, _ label: String, lead: String, shown: [String]) throws {
        let require = NativeTaskFixture.require
        let rest = String(prompt.dropFirst(marker.count))
        try require(prompt.hasPrefix(marker) && occurrences(marker, in: prompt) == 1 && !hasMarkerScalar(rest),
                    "The \(label) question has the marker once, as its subject: \(prompt)")
        try require(!prompt.contains("Ada") && !prompt.lowercased().contains("your companion"), "The \(label) question saves no finished name")
        let line = CompanionSavedText.line(prompt, appWritten: true)
        try require(nameParts(line) == 1 && line.parts == [.name, .text(rest)], "The \(label) question has exactly one name part")
        try require(line.plain(name: "Ada") == "Ada" + rest && line.plain(name: "Ada").hasPrefix("Ada " + lead)
                    && line.plain(name: nil).hasPrefix("Your companion " + lead), "The \(label) question reads with the name: \(line.plain(name: "Ada"))")
        for text in shown {
            try require(rest.contains(text), "The \(label) question keeps the outside text \(text)")
        }
    }

    private static func savedTextWriters() async throws -> [String: [String: Any]] {
        let require = NativeTaskFixture.require
        let hostileJoined = CompanionSavedTextFixture.hostileJoined
        let shownHostile = CompanionSavedTextFixture.tokens + ["companion"]
        var reports: [String: [String: Any]] = [:]

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saved-text-folder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(hostileJoined), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let grant = try FolderGrant.make(url: folder)
        let made = grant.path + "/" + hostileJoined + "/c"
        let mkdirArguments = savedTextJSON(["path": made])
        var folderHarness = try NativeCompanionHarness(rules: [.fileEdits: .ask]) { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call(NativeFolderTools.mkdirName, mkdirArguments) : .text("Made it.")
        }
        let folderRules = folderHarness.rules
        let folderThread = folderHarness.thread
        let folderTools = NativeFolderTools.definitions(grants: { [grant] }, ledger: NativeFileChangeLedger(), edits: .ask, trash: .ask, live: { action in
            folderRules.resolver(for: folderThread.current, requestText: "").decision(for: action)
        })
        folderHarness.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: folderThread.current, tools: folderTools) }
        _ = try folderHarness.create("Make the folder")
        let folderAsk = try await folderHarness.runUntilSettled()
        let folderPrompt = try folderHarness.decision(folderAsk)["prompt"] as? String ?? ""
        try require(folderAsk.state == .needsDecision, "The folder edit asks first")
        try requireQuestion(folderPrompt, "folder", lead: "wants to create a folder in ", shown: shownHostile)
        try require(folderPrompt == marker + " wants to create a folder in " + CompanionSavedText.sanitized(hostileJoined) + ".",
                    "The folder question is the marker and the sanitized folder name: \(folderPrompt)")
        try require(((try folderHarness.decision(folderAsk)["details"] as? String) ?? "").contains(made),
                    "The folder details keep the exact path, marker scalars included")

        let recipients = CompanionSavedTextFixture.hostile
        var sendHarness = try NativeCompanionHarness(rules: [.networkSends: .ask]) { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call("send_note", savedTextJSON(["to": hostileJoined, "text": "Hello"])) : .text("Sent.")
        }
        let object: NativeJSONValue = .object(["type": .string("object"), "properties": .object(["to": .object(["type": .string("string")])])])
        var send = NativeToolDefinition(id: "mail", name: "send_note", title: "Send a note", description: "Send a note",
                                        parameters: object, confirmation: .none, isAvailable: { true }, execute: { _ in .object(["sent": .bool(true)]) })
        send.effect = .write
        send.action = .networkSends
        send.executeWithKey = { _, _ in .object(["sent": .bool(true)]) }
        send.ruleSubjects = { _ in [recipients.compactMap { (value: String) -> NativeRuleTarget? in NativeRuleTarget.make(.recipient, value) }] }
        let sendThread = sendHarness.thread
        let sendTool = send
        sendHarness.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: sendThread.current, tools: [sendTool]) }
        _ = try sendHarness.create("Send the note")
        let sendAsk = try await sendHarness.runUntilSettled()
        let sendPrompt = try sendHarness.decision(sendAsk)["prompt"] as? String ?? ""
        try require(sendAsk.state == .needsDecision, "The send asks first")
        try requireQuestion(sendPrompt, "send", lead: "wants to ", shown: ["{name}", "{ name }", "companion"])
        try require(sendPrompt.contains(" to "), "The send question names its recipients: \(sendPrompt)")

        let commandDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("saved-text-commands-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: commandDirectory) }
        let commandGrant = try FolderGrant.make(url: commandDirectory)
        let command = "echo " + hostileJoined
        let commandArguments = savedTextJSON(["command": command])
        var commandHarness = try NativeCompanionHarness(rules: [.commands: .ask, .riskyCommands: .ask]) { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call(NativeCommandTools.runName, commandArguments) : .text("Ran it.")
        }
        let commandTools = ChatStore.companionCommandDefinitions(grants: { [commandGrant] })
        let commandThread = commandHarness.thread
        commandHarness.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: commandThread.current, tools: commandTools) }
        _ = try commandHarness.create("Run the check")
        let commandAsk = try await commandHarness.runUntilSettled()
        let commandPrompt = try commandHarness.decision(commandAsk)["prompt"] as? String ?? ""
        try require(commandAsk.state == .needsDecision, "The command asks first")
        try requireQuestion(commandPrompt, "command", lead: "wants to ", shown: [])
        try require(((try commandHarness.decision(commandAsk)["details"] as? String) ?? "").contains(command),
                    "The command details keep the exact command, marker scalars included")

        let permissive = Dictionary(uniqueKeysWithValues: NativeActionClass.allCases.map { ($0, NativeRuleChoice.act) })
        let capped = try NativeCompanionHarness(rules: permissive) { messages in
            NativeCompanionScriptedModel.call("garden_status", "{}", id: "call-\(NativeCompanionScriptedModel.toolResults(messages).count)")
        }
        _ = try capped.create()
        let atCap = try await capped.runUntilSettled(40)
        let capPrompt = try capped.decision(atCap)["prompt"] as? String ?? ""
        try require(atCap.state == .needsDecision && (try capped.decision(atCap)["choices"] as? [String]) == ["continue", "finish"],
                    "The limit fixture asks to keep going")
        try requireQuestion(capPrompt, "limit", lead: "has used this run's ", shown: [])
        try capped.reply(atCap, "finish")
        let limited = try await capped.runUntilSettled(40)
        let limitReport = try capped.result(limited)
        try require(limited.state == .completed && (limitReport["report"] as? String ?? "").hasPrefix("Reached the limit for this assignment before writing a full report."),
                    "Finishing at the limit writes the name-free limit report: \(limitReport["report"] as? String ?? "")")
        reports["limit"] = limitReport

        let blindScript: @Sendable ([NativeTaskGenerationMessage]) -> NativeTaskGenerationCompletion = { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call("water_bed", savedTextJSON(["bed": "north", "text": hostileJoined])) : .text("Done.")
        }
        let blind = try NativeCompanionHarness(rules: [.networkSends: .act], toolSeconds: 0.2, script: blindScript)
        blind.service.applyThenStall = true
        _ = try blind.create()
        let unsure = try await blind.runUntilSettled()
        let checkPrompt = try blind.decision(unsure)["prompt"] as? String ?? ""
        try require(unsure.state == .needsDecision && (try blind.decision(unsure)["choices"] as? [String]) == ["it_happened", "it_did_not", "stop"],
                    "An unconfirmed write asks the person to check")
        try requireQuestion(checkPrompt, "check", lead: "can't tell whether this happened: ", shown: shownHostile)
        try require(checkPrompt == marker + " can't tell whether this happened: Water a bed: " + CompanionSavedText.sanitized(hostileJoined)
                        + ". Please check, then say what you found.", "The check question sanitizes the outside title: \(checkPrompt)")
        try blind.reply(unsure, "stop")
        let stopped = try await blind.runUntilSettled()
        let stopReport = try blind.result(stopped)
        let stopTitle = "Water a bed: " + hostileJoined
        try require(stopped.state == .completed
                    && (stopReport["report"] as? String ?? "").hasPrefix("Stopped at your request. It could not be confirmed whether this happened: " + CompanionSavedText.sanitized(stopTitle) + ".")
                    && stopTitle != CompanionSavedText.sanitized(stopTitle) && !hasMarkerScalar(stopReport["report"] as? String ?? "\u{E000}"),
                    "Stopping writes the name-free report and keeps the outside title, minus the marker characters: \(stopReport["report"] as? String ?? "")")
        reports["stop"] = stopReport.merging(["outside": stopTitle]) { old, _ in old }

        let declineText = CompanionSavedTextFixture.tokensJoined
        let declineScript: @Sendable ([NativeTaskGenerationMessage]) -> NativeTaskGenerationCompletion = { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call("water_bed", savedTextJSON(["bed": "north", "text": declineText])) : .text("Done.")
        }
        let declining = try NativeCompanionHarness(rules: [.networkSends: .ask], script: declineScript)
        _ = try declining.create()
        let asked = try await declining.runUntilSettled()
        try requireQuestion(try declining.decision(asked)["prompt"] as? String ?? "", "water", lead: "wants to ", shown: [])
        try declining.reply(asked, "decline")
        let declined = try await declining.runUntilSettled()
        let declineTitle = "Water a bed: " + CompanionSavedTextFixture.tokensJoined
        let declineReport = try declining.result(declined)
        try require(declined.state == .completed && (declineReport["report"] as? String ?? "").hasPrefix("Stopped because you declined: " + declineTitle + "."),
                    "Declining writes the name-free report: \(declineReport["report"] as? String ?? "")")
        reports["declined"] = declineReport.merging(["outside": declineTitle]) { old, _ in old }

        let handing = try NativeCompanionHarness(rules: [.networkSends: .handOff]) { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call("water_bed", "{\"bed\":\"north\"}") : .text("Done.")
        }
        _ = try handing.create()
        let handed = try await handing.runUntilSettled()
        let handReport = try handing.result(handed)
        try require(handed.state == .completed && (handReport["report"] as? String ?? "").hasPrefix("Stopped before this step because your rules hand it to you: Water a bed."),
                    "A hand off writes the name-free report: \(handReport["report"] as? String ?? "")")
        reports["handoff"] = handReport
        try require(NativeCompanionWorker.handOffText(title: "Pay it", action: .payments).hasPrefix("Stopped before this step and handed it to you: Pay it. It counts as"),
                    "The floor hand off needs no name either")

        for (label, report) in reports {
            let outside = report["outside"] as? String ?? ""
            for key in ["report", "summary"] {
                let whole = report[key] as? String ?? ""
                let text = whole.replacingOccurrences(of: outside.isEmpty ? "\u{0}" : CompanionSavedText.sanitized(outside), with: "")
                try require(!hasMarkerScalar(whole), "The \(label) \(key) holds no marker character, even from an outside title: \(whole)")
                try require(!text.contains("Ada") && !text.lowercased().contains("your companion") && !text.contains("{name}") && !hasMarkerScalar(text),
                            "The \(label) \(key) carries no name, token or marker of its own: \(text)")
            }
        }
        return reports
    }

    private static func savedTextRename() throws {
        let require = NativeTaskFixture.require
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: try LocalChatRepository(inMemory: true),
                              nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
        let reference = try CompanionSavedTextFixture.reference(state: "needs_decision", decision: [
            "id": "cap", "prompt": CompanionSavedTextFixture.capQuestion, "choices": ["continue", "finish"]])
        store.nativeTaskReferences = [reference]
        let card = try NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot).card
        try require(card.milestone == CompanionSavedTextFixture.capQuestion, "The card keeps the saved marker question")
        let schedule = try NativeSchedule(id: "saved-text-rename", owner: .dot, workerType: "companion", title: "Bed check",
                                          instruction: "Check the beds.", cadence: .everyHours(6), timeZone: TimeZone(identifier: "UTC")!)
        let paused = NativeScheduleRun(id: "rename-paused", scheduleID: schedule.id, scheduledFor: Date(), outcome: .skipped,
                                       detail: CompanionSavedTextFixture.pausedNote)
        let missed = NativeScheduleRun(id: "rename-missed", scheduleID: schedule.id, scheduledFor: Date(), outcome: .skipped,
                                       detail: CompanionSavedTextFixture.missedNote)
        store.schedules = [schedule]
        store.scheduleRuns = [schedule.id: [paused, missed]]
        let taskItem = CompanionOverviewModel.taskItem(card: card, reference: reference, decision: nil, hasArtifact: false, date: Date())
        let expected: [(String?, String, String, String)] = [
            ("Ada", "Ada has used this run's actions", "Ada is paused.", "Missed while Ada was paused."),
            ("Moss", "Moss has used this run's actions", "Moss is paused.", "Missed while Moss was paused."),
            (nil, "Your companion has used this run's actions", "Your companion is paused.", "Missed while your companion was paused."),
        ]
        for (index, (name, question, pausedText, missedText)) in expected.enumerated() {
            if index > 0 { store.adoptAssistantName(name) }
            let label = name ?? "no name"
            try require(store.companionName == name, "The live store uses \(label)")
            try require(card.milestoneLine.plain(name: store.companionName).hasPrefix(question)
                        && (store.companionActivityDetail(taskItem).outcome ?? "").hasPrefix(question),
                        "The saved card question reads with \(label)")
            try require(store.scheduleRunNote(paused).plain(name: store.companionName) == pausedText
                        && store.companionActivityDetail(CompanionOverviewModel.runItem(paused, schedule: schedule)).outcome == pausedText,
                        "The paused note reads with \(label)")
            try require(store.scheduleRunNote(missed).plain(name: store.companionName) == missedText
                        && store.companionActivityDetail(CompanionOverviewModel.runItem(missed, schedule: schedule)).outcome == missedText,
                        "The missed-while-paused note reads with \(label)")
        }
    }

    private static func savedTextRunNotes() async throws {
        let require = NativeTaskFixture.require
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: try LocalChatRepository(inMemory: true),
                              nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
        let zone = TimeZone(identifier: "UTC")!
        var owned = try NativeSchedule(id: "notes-owned", owner: .dot, workerType: "companion", title: "Bed check",
                                       instruction: "Check the beds.", cadence: .everyHours(6), timeZone: zone)
        let paused = NativeScheduleRun(id: "notes-paused", scheduleID: owned.id, scheduledFor: Date(), outcome: .skipped,
                                       detail: CompanionSavedTextFixture.pausedNote)
        let missedOutcome = NativeScheduleRun(id: "notes-missed", scheduleID: owned.id, scheduledFor: Date(), outcome: .missed,
                                              detail: CompanionSavedTextFixture.missedNote)
        store.schedules = [owned]
        try require(store.scheduleRunNote(paused).plain(name: "Ada") == "Ada is paused."
                    && store.scheduleRunNote(missedOutcome).plain(name: "Ada") == "Missed while Ada was paused.",
                    "Skipped and missed notes on the companion's schedule fill the marker")
        owned.owner = .conversation
        store.schedules = [owned]
        try require(store.scheduleRunNote(paused).plain(name: "Ada") == "Ada is paused." && !hasMarkerScalar(store.scheduleRunNote(paused).plain(name: nil)),
                    "A paused note written while the schedule was the companion's still reads with the name after it moves to its own chat")
        for outcome in [NativeScheduleOutcome.couldNotStart, .failed, .blocked, .running, .completed, .stopped] {
            let run = NativeScheduleRun(id: "notes-other-\(outcome.rawValue)", scheduleID: owned.id, scheduledFor: Date(), outcome: outcome,
                                        detail: CompanionSavedTextFixture.pausedNote)
            try require(store.scheduleRunNote(run).plain(name: "Ada") == "Ada is paused."
                            && !hasMarkerScalar(store.scheduleRunNote(run).plain(name: nil)),
                        "A note the app wrote with the marker reads with the name under outcome \(outcome.rawValue) and never shows the marker")
            let finishedQuestion = NativeScheduleRun(id: "notes-finished-\(outcome.rawValue)", scheduleID: owned.id, scheduledFor: Date(), outcome: outcome,
                                                     detail: CompanionSavedTextFixture.approvalQuestion)
            try require(finishedQuestion.checkInKey == nil && !hasMarkerScalar(store.scheduleRunNote(finishedQuestion).plain(name: nil))
                            && !hasMarkerScalar(store.scheduleRunNote(finishedQuestion).plain(name: "Ada")),
                        "A run that asked and then ended as \(outcome.rawValue) without a check-in never shows the marker")
            let outside = NativeScheduleRun(id: "notes-outside-\(outcome.rawValue)", scheduleID: owned.id, scheduledFor: Date(), outcome: outcome,
                                            detail: "The service said {name} wants to stop: permission denied.")
            try require(store.scheduleRunNote(outside) == .literal("The service said {name} wants to stop: permission denied."),
                        "Outside text without the marker stays literal under outcome \(outcome.rawValue)")
        }
        let hostileReason = "The model said " + CompanionSavedText.marker + " is paused and \u{E000} more."
        try require(CompanionSavedText.sanitized(hostileReason) == "The model said companion is paused and  more."
                        && !CompanionSavedText.sanitized(hostileReason).contains(CompanionSavedText.marker),
                    "Outside text loses the two marker characters before it is saved to a run note")

        let companionReference = try CompanionSavedTextFixture.reference(state: "needs_decision", decision: [
            "id": "q", "prompt": CompanionSavedTextFixture.approvalQuestion, "choices": ["approve", "decline"]])
        let legacyQuestion = "{name} wants to send a message to {Name}."
        let researchReference = try OngoingWorkFixture.reference(conversationID: "notes-research", title: "Research question", workerType: "research",
                                                                 state: "needs_decision", decision: ["id": "r", "prompt": legacyQuestion, "choices": ["retry"]])
        store.nativeTaskReferences = [companionReference, researchReference]
        var changed = try NativeSchedule(id: "notes-changed", owner: .dot, workerType: "research", title: "Changed",
                                         instruction: "Check the beds.", cadence: .everyHours(6), timeZone: zone)
        let waiting = NativeScheduleRun(id: "notes-waiting", scheduleID: changed.id, scheduledFor: Date(), outcome: .waiting,
                                        detail: CompanionSavedTextFixture.approvalQuestion, taskReferenceID: companionReference.id.uuidString)
        let researchWaiting = NativeScheduleRun(id: "notes-research-waiting", scheduleID: "notes-switched", scheduledFor: Date(), outcome: .waiting,
                                                detail: legacyQuestion, taskReferenceID: researchReference.id.uuidString)
        let switched = try NativeSchedule(id: "notes-switched", owner: .dot, workerType: "companion", title: "Switched",
                                          instruction: "Check the beds.", cadence: .everyHours(6), timeZone: zone)
        store.schedules = [changed, switched]
        try require(store.scheduleRunNote(waiting).plain(name: "Ada") == "Ada wants to create a folder in Seeds.",
                    "A waiting marker question reads with the name after the schedule's work type changed")
        try require(store.scheduleRunNote(researchWaiting) == .literal(legacyQuestion),
                    "A research task's question stays literal on a schedule later switched to companion work")
        changed.workerType = "companion"
        store.schedules = [changed, switched]
        let unlinked = NativeScheduleRun(id: "notes-unlinked", scheduleID: changed.id, scheduledFor: Date(), outcome: .waiting,
                                         detail: CompanionSavedTextFixture.approvalQuestion)
        try require(store.scheduleRunNote(unlinked).plain(name: nil) == "Your companion wants to create a folder in Seeds.",
                    "Without a task the schedule decides, and companion work fills the marker")
        let asked = NativeScheduleRun(id: "notes-asked", scheduleID: changed.id, scheduledFor: Date(), outcome: .completed,
                                      detail: CompanionSavedTextFixture.approvalQuestion, taskReferenceID: companionReference.id.uuidString,
                                      checkInKey: "asked")
        try require(store.scheduleRunNote(asked).plain(name: "Ada") == "Ada wants to create a folder in Seeds.",
                    "A finished run that asked keeps reading its question")
        let orphanSchedule = try NativeSchedule(id: "notes-orphan", owner: .conversation, workerType: "research", title: "Orphan",
                                                instruction: "Check the beds.", cadence: .everyHours(6), timeZone: zone)
        store.schedules = [orphanSchedule]
        store.nativeTaskReferences = []
        for key in [String?.none, "asked"] {
            let orphan = NativeScheduleRun(id: "notes-orphan-\(key ?? "none")", scheduleID: orphanSchedule.id, scheduledFor: Date(), outcome: .completed,
                                           detail: CompanionSavedTextFixture.approvalQuestion, taskReferenceID: UUID().uuidString, checkInKey: key)
            try require(!store.scheduleRunIsCompanionWork(orphan), "The orphan fixture has no task and a research schedule")
            try require(store.scheduleRunNote(orphan).plain(name: "Ada") == "Ada wants to create a folder in Seeds."
                            && !hasMarkerScalar(store.scheduleRunNote(orphan).plain(name: nil)),
                        "A saved question still reads with the name after its task is gone and its schedule was changed")
        }
        let orphanOutside = NativeScheduleRun(id: "notes-orphan-outside", scheduleID: orphanSchedule.id, scheduledFor: Date(), outcome: .completed,
                                              detail: "The service said " + CompanionSavedText.marker + " is paused.")
        try require(store.scheduleRunNote(orphanOutside) == .literal("The service said " + CompanionSavedText.marker + " is paused."),
                    "Text that does not start with the marker is never filled on that path")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saved-text-fire-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try LocalChatRepository(url: folder.appendingPathComponent("vera.sqlite"))
        let live = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                             artifactPersistenceEnabled: false)
        await live.connect()
        live.nativeSchedulerLoop?.cancel()
        await live.nativeSchedulerLoop?.value
        live.nativeSchedulerLoop = nil
        live.skipDotSetup()
        guard let scheduleStore = live.nativeScheduleStore else { throw NativeTaskFixture.Failure.assertion("The live store has a schedule store") }
        let fixed: Set<String> = [ChatStore.removedScheduleReason, CompanionSavedTextFixture.pausedNote, CompanionSavedTextFixture.missedNote,
                                  CompanionSavedText.marker + " started over before this ran.", "The previous run was still going.",
                                  NativeScheduler.missedNote]
        func isFixed(_ note: String) -> Bool {
            fixed.contains(note) || note.range(of: #"^\d+ earlier (run was|runs were) also missed while Tandem wasn't running\.$"#, options: .regularExpression) != nil
        }
        let dotSchedule = try NativeSchedule(owner: .dot, workerType: "research", title: "Fire check", instruction: "Check the beds.",
                                             cadence: .everyHours(6), timeZone: zone, nextRunAt: Date().addingTimeInterval(3600))
        try scheduleStore.save(dotSchedule)
        live.setDotState(.paused)
        let probe = NativeScheduleRun(scheduleID: dotSchedule.id, scheduledFor: Date(), outcome: .running)
        let pausedFire = await live.fireSchedule(dotSchedule, run: probe, bind: { _, _ in })
        live.setDotState(.active)
        let duringPause = NativeScheduleRun(scheduleID: dotSchedule.id, scheduledFor: (live.dotProfile.resumedAt ?? Date()).addingTimeInterval(-60), outcome: .running)
        let missedFire = await live.fireSchedule(dotSchedule, run: duringPause, bind: { _, _ in })
        try scheduleStore.delete(dotSchedule.id)
        let removedFire = await live.fireSchedule(dotSchedule, run: probe, bind: { _, _ in })
        var fired: [String] = []
        for result in [pausedFire, missedFire, removedFire] {
            guard case .skipped(let note) = result else { throw NativeTaskFixture.Failure.assertion("The fire path skipped: \(result)") }
            fired.append(note)
        }
        try require(fired == [CompanionSavedTextFixture.pausedNote, CompanionSavedTextFixture.missedNote, ChatStore.removedScheduleReason],
                    "The fire path's skipped notes are the fixed app texts: \(fired)")

        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let schedulerStore = NativeScheduleStore(database: try LocalChatRepository(inMemory: true).database)
        let late = try NativeSchedule(owner: .dot, workerType: "research", title: "Late", instruction: "Check the beds.",
                                      cadence: .everyHours(1), timeZone: zone, nextRunAt: moment.addingTimeInterval(-30 * 3600))
        let busy = try NativeSchedule(owner: .dot, workerType: "research", title: "Busy", instruction: "Check the beds.",
                                      cadence: .everyHours(6), timeZone: zone, nextRunAt: moment.addingTimeInterval(-5))
        let failing = try NativeSchedule(owner: .dot, workerType: "research", title: "Failing", instruction: "Check the beds.",
                                         cadence: .everyHours(6), timeZone: zone, nextRunAt: moment.addingTimeInterval(-5))
        for schedule in [late, busy, failing] { try schedulerStore.save(schedule) }
        try schedulerStore.saveRun(NativeScheduleRun(scheduleID: busy.id, scheduledFor: moment.addingTimeInterval(-600),
                                                     startedAt: moment.addingTimeInterval(-600), outcome: .running))
        let outsideError = "The model said " + CompanionSavedTextFixture.hostileJoined + " failed."
        let failingID = failing.id
        let skippedNote = CompanionSavedTextFixture.pausedNote
        let busyID = busy.id
        let scheduler = NativeScheduler(store: schedulerStore, now: { moment }, lookup: { (run: NativeScheduleRun) -> NativeScheduleTaskLink? in
            run.scheduleID == busyID ? NativeScheduleTaskLink(referenceID: "busy-task", status: .active) : nil
        }, fire: { schedule, _, _ in
            schedule.id == failingID ? .failed(outsideError) : .skipped(skippedNote)
        })
        _ = await scheduler.tick()
        var recorded: [NativeScheduleRun] = []
        for schedule in [late, busy, failing] { recorded += try schedulerStore.runs(scheduleID: schedule.id, limit: 100) }
        let skippedOrMissed = recorded.filter { (run: NativeScheduleRun) -> Bool in run.outcome == .skipped || run.outcome == .missed }
        try require(skippedOrMissed.contains { $0.outcome == .missed } && skippedOrMissed.contains { $0.detail == "The previous run was still going." },
                    "The scheduler fixture records missed and still-going notes: \(skippedOrMissed.map(\.detail))")
        try require(skippedOrMissed.allSatisfy { isFixed($0.detail) },
                    "Every skipped or missed note the scheduler writes is fixed app text: \(skippedOrMissed.map(\.detail))")
        let failedRuns = try schedulerStore.runs(scheduleID: failing.id)
        try require(failedRuns.count == 1 && failedRuns[0].outcome == .couldNotStart && failedRuns[0].detail == CompanionSavedText.sanitized(outsideError)
                        && outsideError != CompanionSavedText.sanitized(outsideError) && !hasMarkerScalar(failedRuns[0].detail),
                    "Outside error text is stored as could not start, never as skipped or missed, with the marker characters removed")
        store.schedules = [failing]
        try require(store.scheduleRunNote(failedRuns[0]) == .literal(CompanionSavedText.sanitized(outsideError)), "An outside error note stays literal")
    }

    private static func waitingCheckIn(name: String?, rename: String?? = nil) throws -> String? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("chat.sqlite"))
        let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!)
        let origin = try NativeTaskFixture.origin(repository)
        let request = try NativeResearchTaskRequest(objective: "Saved check-in", deliverables: [], workerType: "companion")
        let reference = try repository.prepareTaskReference(origin: origin, engine: engine, request: request, profile: nil)
        var object = (try JSONSerialization.jsonObject(with: NativeTaskFixture.snapshot(reference, id: UUID().uuidString,
                                                                                        state: "needs_decision"))) as? [String: Any] ?? [:]
        object["worker_type"] = "companion"
        object["decision"] = ["id": "check-in", "prompt": CompanionSavedTextFixture.capQuestion, "choices": ["continue", "finish"]]
        let waiting = try JSONDecoder().decode(NativeTaskSnapshot.self, from: NativeTaskClient.canonical(object))
        _ = try repository.acknowledgeTaskReference(id: reference.id, snapshot: waiting)
        _ = try repository.projectTask(id: reference.id, snapshot: waiting)
        let scheduleStore = NativeScheduleStore(database: repository.database)
        var schedule = try NativeSchedule(owner: .dot, workerType: "companion", title: "Saved check", instruction: "Check the beds.",
                                          cadence: .everyHours(6), timeZone: TimeZone(identifier: "UTC")!)
        schedule.advance(after: Date(), from: nil)
        try scheduleStore.save(schedule)
        try scheduleStore.saveRun(NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), startedAt: Date(), outcome: .waiting,
                                                    detail: CompanionSavedTextFixture.capQuestion, conversationID: origin.conversationID,
                                                    messageID: origin.assistantMessageID.uuidString, taskReferenceID: reference.id.uuidString))
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: name,
                              artifactPersistenceEnabled: false)
        if let rename { store.adoptAssistantName(rename) }
        store.nativeScheduleStore = scheduleStore
        store.reloadSchedules()
        store.postScheduleCheckIns()
        return try repository.messages(conversationID: origin.conversationID).last?.text
    }

    private static func savedTextModelInput(_ reports: [String: [String: Any]]) async throws {
        let require = NativeTaskFixture.require
        var refused = NativeCompanionCheckpoint()
        let hostileTitle = "Water a bed: " + CompanionSavedText.marker
        refused.note(hostileTitle, NativeReadOnlyRun.outcome)
        guard let appendix = NativeReadOnlyRun.undone(refused.effects.filter { $0.outcome == NativeReadOnlyRun.outcome }.map(\.title)) else {
            throw NativeTaskFixture.Failure.assertion("A refused write is listed as left undone")
        }
        try require(hasMarkerScalar(appendix), "The fixture's left undone line carries the hostile title as written")
        for text in ["Nothing changed.\n\n" + appendix, "The model wrote " + CompanionSavedText.marker + " itself.\n\n" + appendix] {
            let step = try NativeCompanionWorker.report(refused, assignment: CompanionSavedTextFixture.assignment, text: text, keep: true)
            guard let data = step.result, let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeTaskFixture.Failure.assertion("The report is saved")
            }
            let report = saved["report"] as? String ?? "\u{E000}"
            let summary = saved["summary"] as? String ?? "\u{E000}"
            try require(!hasMarkerScalar(report) && !hasMarkerScalar(summary) && report.contains("Left undone") && report.contains("Water a bed: companion"),
                        "Every saved companion report loses the marker characters, including the left undone line the app appends: \(report)")
            let reference = try CompanionSavedTextFixture.reference(state: "completed", result: saved)
            try require(!hasMarkerScalar(ChatStore.refinementObservation(reference.snapshot) ?? "\u{E000}"),
                        "The follow-up built from that report carries no marker character")
        }
        for (label, report) in reports {
            let outside = report["outside"] as? String ?? ""
            var result = report
            result.removeValue(forKey: "outside")
            let reference = try CompanionSavedTextFixture.reference(state: "completed", result: result.merging(["query": CompanionSavedTextFixture.assignment]) { _, new in new })
            let observation = ChatStore.refinementObservation(reference.snapshot) ?? ""
            let own = outside.isEmpty ? observation : observation.replacingOccurrences(of: CompanionSavedText.sanitized(outside), with: "")
            try require(!observation.isEmpty && !hasMarkerScalar(observation) && !own.contains("{name}") && !own.contains("Ada"),
                        "The refinement observation from the \(label) report carries no marker or name: \(observation)")
        }
        let expected: [(String?, String??, String)] = [("Ada", nil, "Ada"), ("Ada", .some("Moss"), "Moss"), (nil, nil, "Your companion")]
        for (name, rename, shown) in expected {
            let text = try waitingCheckIn(name: name, rename: rename) ?? ""
            try require(text == "The scheduled research \"Saved check\" stopped to ask: " + shown
                            + " has used this run's actions and saved its progress. Keep going, or finish with what it has?"
                        && !hasMarkerScalar(text) && !text.contains("{name}"),
                        "The posted check-in fills the current name and carries no marker: \(text)")
        }
        let definition = NativeScheduleTools.definition(searchAvailable: { true }, save: { draft in
            try NativeSchedule(owner: draft.owner, workerType: draft.workerType, title: draft.title, instruction: draft.instruction,
                               cadence: draft.cadence, timeZone: .current)
        })
        let saved = try await definition.execute(["title": .string("Bed check"), "worker_type": .string("document"),
                                                   "instruction": .string("Write the bed note."), "results_to": .string("assistant"),
                                                   "repeat": .string("every_hours"), "hours": .number(6)])
        guard case .object(let fields) = saved, case .string(let message)? = fields["message"] else {
            throw NativeTaskFixture.Failure.assertion("The schedule tool returns a message")
        }
        try require(message.hasSuffix("results go to the companion's conversation.") && !hasMarkerScalar(message) && !message.contains("{name}")
                    && !message.contains("Ada"), "The schedule tool result names no companion and carries no marker: \(message)")
    }

    private static func savedTextLeakScan(_ reports: [String: [String: Any]]) async throws {
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saved-text-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: directory)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository,
                              nativeAssistantName: "Ada", attachmentStore: NativeAttachmentStore(directory: directory),
                              artifactPersistenceEnabled: false)
        store.ensureVeraThread()
        guard let thread = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion thread exists") }
        let waiting = try CompanionSavedTextFixture.reference(state: "needs_decision", conversationID: thread, decision: CompanionSavedTextFixture.approvalDecision())
        var finished: [NativeTaskReference] = []
        for key in ["handoff", "declined", "limit", "stop"] {
            guard var result = reports[key] else { continue }
            result.removeValue(forKey: "outside")
            finished.append(try CompanionSavedTextFixture.reference(state: "completed", conversationID: thread, result: result))
        }
        store.nativeTaskReferences = [waiting] + finished
        let schedule = try NativeSchedule(id: "scan-owned", owner: .dot, workerType: "companion", title: "Bed check",
                                          instruction: "Check the beds.", cadence: .everyHours(6), timeZone: TimeZone(identifier: "UTC")!)
        let paused = NativeScheduleRun(id: "scan-paused", scheduleID: schedule.id, scheduledFor: Date(), outcome: .skipped,
                                       detail: CompanionSavedTextFixture.pausedNote)
        let asked = NativeScheduleRun(id: "scan-asked", scheduleID: schedule.id, scheduledFor: Date(), outcome: .completed,
                                      detail: CompanionSavedTextFixture.approvalQuestion, taskReferenceID: waiting.id.uuidString, checkInKey: "asked")
        store.schedules = [schedule]
        store.scheduleRuns = [schedule.id: [paused, asked]]
        store.recordTaskArtifacts([NativeDisplayBlock.artifact(NativeResearchArtifact(id: "scan-artifact", title: "Bed note", report: "# Bed note", sources: []))],
                                  conversationID: thread, messageID: UUID().uuidString)
        guard let artifact = store.artifactRecords.first(where: { $0.title == "Bed note" }) else {
            throw NativeTaskFixture.Failure.assertion("The companion artifact was saved")
        }
        try require(waiting.snapshot?.decision?.prompt.contains(marker) == true && paused.detail.contains(marker) && asked.detail.contains(marker)
                    && artifact.originTitle == marker, "The raw saved rows hold the marker, so the scan is not vacuous")
        for name in ["Ada", nil] as [String?] {
            store.adoptAssistantName(name)
            var shown: [String] = []
            for reference in [waiting] + finished {
                let display = try NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot)
                shown.append(display.card.milestoneLine.plain(name: store.companionName))
                shown.append(display.card.answer ?? "")
                shown.append(display.artifact?.report ?? "")
                shown.append(display.card.details ?? "")
                let item = CompanionOverviewModel.taskItem(card: display.card, reference: reference, decision: reference.snapshot?.decision,
                                                           hasArtifact: display.artifact != nil, date: Date())
                shown.append(store.companionActivityDetail(item).outcome ?? "")
            }
            for run in [paused, asked] {
                shown.append(store.scheduleRunNote(run).plain(name: store.companionName))
                shown.append(store.companionActivityDetail(CompanionOverviewModel.runItem(run, schedule: schedule)).outcome ?? "")
            }
            let origin = store.artifactOriginLabel(artifact)
            shown.append(origin)
            shown.append("\(artifact.kind.label) · \(origin) · \(ArtifactDateLabel.text(artifact.updatedAt))")
            shown.append(ArtifactDateLabel.origin(artifact, companionName: store.companionName))
            shown.append(ArtifactLibrarySelection.searchableOrigin(artifact, companionName: store.companionName) ?? "")
            shown.append(try waitingCheckIn(name: name) ?? "")
            shown.append(ChatStore.refinementObservation(finished.first?.snapshot) ?? "")
            let leaked = shown.filter(hasMarkerScalar)
            try require(leaked.isEmpty, "No reader output carries a marker scalar for \(name ?? "no name"): \(leaked)")
            try require(shown.contains { $0.hasPrefix((name ?? "Your companion") + " wants to create a folder in Seeds.") } && origin == (name ?? "Your companion"),
                        "The scan read the marker rows with \(name ?? "no name")")
        }
    }

    private static func savedTextLibrary() throws {
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saved-text-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: directory)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository,
                              nativeAssistantName: "Ada", attachmentStore: NativeAttachmentStore(directory: directory),
                              artifactPersistenceEnabled: false)
        store.ensureVeraThread()
        guard let thread = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion thread exists") }
        let ordinary = Conversation(id: "saved-text-ordinary", title: "Greenhouse plan", messages: [], updatedAt: Date())
        try repository.saveConversation(ordinary)
        store.conversations.append(ordinary)
        let first = Message(role: .user, text: "Note the vents.")
        try repository.saveMessage(first, conversationID: thread, ordinal: 0)
        let now = Date()
        try repository.saveMemory(NativeMemoryRecord(id: "saved-text-memory", title: "Vents", summary: "Vents stick", details: ["Vents stick"],
                                                     group: .areas, category: .goal, bank: "home", durability: .durable, expiry: nil,
                                                     status: .approved, embedding: nil, sourceConversationID: thread,
                                                     sourceMessageID: first.id.uuidString, createdAt: now, updatedAt: now),
                                  decision: .accepted, note: "Fixture")
        store.recordTaskArtifacts([NativeDisplayBlock.artifact(NativeResearchArtifact(id: "lib-companion", title: "Frost checklist", report: "# Frost", sources: []))],
                                  conversationID: thread, messageID: UUID().uuidString)
        store.recordTaskArtifacts([NativeDisplayBlock.artifact(NativeResearchArtifact(id: "lib-ordinary", title: "Heating options", report: "# Heat", sources: []))],
                                  conversationID: ordinary.id, messageID: UUID().uuidString)
        _ = try repository.recordArtifact(ArtifactDraft(kind: .document, title: "Old note", conversationID: nil, originTitle: "Ada", messageID: nil,
                                                        sourceKey: "saved-text-old", data: Data("# Old".utf8), mime: "text/markdown", fileExtension: "md"),
                                          revising: nil)
        let impostor = Conversation(id: "saved-text-impostor", title: CompanionSavedText.marker, messages: [], updatedAt: Date())
        let mixed = Conversation(id: "saved-text-mixed", title: "Plan " + CompanionSavedText.marker, messages: [], updatedAt: Date())
        for conversation in [impostor, mixed] {
            try repository.saveConversation(conversation)
            store.conversations.append(conversation)
        }
        store.recordTaskArtifacts([NativeDisplayBlock.artifact(NativeResearchArtifact(id: "lib-impostor", title: "Impostor note", report: "# I", sources: []))],
                                  conversationID: impostor.id, messageID: UUID().uuidString)
        store.recordTaskArtifacts([NativeDisplayBlock.artifact(NativeResearchArtifact(id: "lib-mixed", title: "Mixed note", report: "# M", sources: []))],
                                  conversationID: mixed.id, messageID: UUID().uuidString)
        store.reloadArtifacts()
        for (title, expected) in [("Impostor note", "companion"), ("Mixed note", "Plan companion")] {
            guard let item = store.artifactRecords.first(where: { $0.title == title }) else { throw NativeTaskFixture.Failure.assertion("The \(title) item exists") }
            try require(item.originTitle == expected && store.artifactOriginLabel(item) == expected
                            && store.artifactOriginLine(item) == .literal(expected),
                        "A chat titled with the marker cannot pass as the companion or show the marker: \(item.originTitle ?? "nil")")
        }
        store.syncArtifactOrigin(conversationID: impostor.id, title: "Garden")
        try require(store.artifactRecords.first(where: { $0.title == "Impostor note" })?.originTitle == "Garden",
                    "Renaming that chat still updates its item's origin")
        store.syncArtifactOrigin(conversationID: mixed.id, title: CompanionSavedText.marker)
        try require(store.artifactRecords.first(where: { $0.title == "Mixed note" })?.originTitle == "companion",
                    "Renaming an ordinary chat to the marker cannot make its item the companion's")
        func record(_ title: String) throws -> ArtifactRecord {
            guard let found = store.artifactRecords.first(where: { $0.title == title }) else {
                throw NativeTaskFixture.Failure.assertion("The \(title) item exists")
            }
            return found
        }
        func found(_ query: String) -> Bool {
            ArtifactLibrarySelection(search: query).visible(store.artifactRecords, companionName: store.companionName)
                .contains { $0.title == "Frost checklist" }
        }
        try require(try record("Frost checklist").originTitle == marker, "A companion item stores the marker as its origin")
        try require(try record("Heating options").originTitle == "Greenhouse plan", "An ordinary chat item stores its title")
        try require(store.artifactOriginLabel(try record("Frost checklist")) == "Ada" && found("ada"), "A companion item reads Ada and is found by Ada")
        store.adoptAssistantName("Moss")
        try require(store.artifactOriginLabel(try record("Frost checklist")) == "Moss" && found("moss") && !found("ada"),
                    "After the rename it reads Moss, is found by moss and no longer by ada")
        try require(store.artifactOriginLabel(try record("Old note")) == "Ada", "An item saved before keeps the name it stored")
        store.renameConversation(ordinary.id, title: "Greenhouse plan, revised")
        try require(try record("Heating options").originTitle == "Greenhouse plan, revised" && store.artifactOriginLabel(try record("Heating options")) == "Greenhouse plan, revised",
                    "Renaming an ordinary chat renames its items' origin")
        store.syncArtifactOrigin(conversationID: thread, title: "Hijack")
        try repository.updateArtifactOrigin(conversationID: thread, title: "Hijack")
        store.reloadArtifacts()
        try require(try record("Frost checklist").originTitle == marker, "Neither a chat rename nor a direct origin update overwrites a companion item")
        store.adoptAssistantName(nil)
        try require(store.artifactOriginLabel(try record("Frost checklist")) == "Your companion" && found("your companion"), "Unnamed it reads Your companion")
        store.adoptAssistantName("Moss")
        store.resetDot()
        let kept = try record("Frost checklist")
        try require(kept.conversationID == nil && kept.originTitle == marker && store.artifactOriginLabel(kept) == "Moss" && found("moss"),
                    "After start over the unlinked companion item still reads the current name")
        store.adoptAssistantName("Ada")
        try require(store.artifactOriginLabel(kept) == "Ada", "A later rename reaches the unlinked companion item")
        let notes = try repository.memoryChanges(limit: 20).map(\.note)
        try require(notes.contains("Removed when the companion started over")
                    && !notes.contains { $0.contains("Moss") || $0.contains("Ada") || hasMarkerScalar($0) || $0.contains("{name}") },
                    "The start-over memory note names no companion: \(notes)")
        let typed = ArtifactRecord(id: "typed", kind: .document, title: "Typed", conversationID: nil, originTitle: "Plan " + marker,
                                   createdAt: Date(), updatedAt: Date(), versionCount: 1)
        try require(store.artifactOriginLabel(typed) == "Plan " + marker, "A typed title that merely contains the marker shows as typed")
    }
}
