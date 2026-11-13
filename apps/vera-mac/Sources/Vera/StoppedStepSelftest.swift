import Foundation

@MainActor
extension SelfTest {
    static func runStoppedStep() async throws {
        let require = NativeTaskFixture.require
        let water: @Sendable ([NativeTaskGenerationMessage]) -> NativeTaskGenerationCompletion = { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call("water_bed", "{\"bed\":\"north\"}") : .text("Finished the assignment.\n\nDetails follow.")
        }
        func shown(_ result: [String: Any], title: String = "Water the north bed") throws
            -> (reference: NativeTaskReference, card: NativeTaskCardPresentation, artifact: NativeResearchArtifact?) {
            var result = result
            result["query"] = title
            let reference = try OngoingWorkFixture.reference(conversationID: "stopped-step", title: title, workerType: "companion",
                                                             state: "completed", result: result)
            let display = try NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot)
            return (reference, display.card, display.artifact)
        }
        func fields(_ card: NativeTaskCardPresentation) -> [String] {
            [card.milestone, card.answer ?? "", card.stop?.step ?? "", card.stop?.earlier ?? ""]
        }
        let run = NativeScheduleRun(scheduleID: "stopped-step-schedule", scheduledFor: Date(), outcome: .completed)

        let asking = try NativeCompanionHarness(rules: [.networkSends: .ask], script: water)
        _ = try asking.create()
        let card = try asking.decision(try await asking.runUntilSettled())["details"] as? String ?? ""
        try require(card == "Bed: north", "The approval card shows the step as its own literal: \(card)")

        let leaving = try NativeCompanionHarness(rules: [.networkSends: .handOff], script: water)
        _ = try leaving.create()
        let left = try await leaving.runUntilSettled()
        let leftResult = try leaving.result(left)
        let leftSaved = try JSONDecoder().decode(NativeResearchTaskResult.self, from: left.result ?? Data())
        try require(left.state == .completed && leftSaved.stop == NativeTaskStop(reason: NativeTaskStop.left, step: "Water a bed\n" + card, earlier: nil)
                        && leftResult["stop"] != nil && leaving.service.count("water_bed") == 0,
                    "A step left to you saves why it stopped and the step, named, with the same lines the card would show: \(String(describing: leftSaved.stop))")
        guard let leftWhy = leftSaved.why else { throw NativeTaskFixture.Failure.assertion("The step left to you keeps its reason") }
        try require(leftSaved.report == NativeCompanionWorker.handOffText(title: "Water a bed", why: leftWhy) + " Nothing was changed."
                        && leftSaved.summary == NativeCompanionWorker.handOffLead(title: "Water a bed") + " Nothing was changed."
                        && leftSaved.shape == nil,
                    "The saved report and summary read as before: \(leftSaved.report)")
        let leftShown = try shown(leftResult)
        try require(leftShown.card.stop == leftSaved.stop && leftShown.card.why == leftWhy && leftShown.card.milestone.isEmpty
                        && leftShown.card.answer == nil && leftShown.artifact == nil,
                    "The card for a step left to you carries the step and the reason, with no summary, answer or document")
        try require(leftShown.card.statusTitle == RefusalCopy.needsYou && leftShown.card.needsYou && leftShown.card.statusIcon == .needsYou,
                    "A step left to you reads Needs you: \(leftShown.card.statusTitle)")
        let leftPanel = CompanionOverviewModel.taskItem(card: leftShown.card, reference: leftShown.reference, decision: nil, hasArtifact: false, date: Date())
        try require(leftPanel.state == RefusalCopy.needsYou && OngoingWork.item(leftShown.reference).state == RefusalCopy.needsYou
                        && ChatStore.scheduleRunTitle(run, card: leftShown.card) == RefusalCopy.needsYou,
                    "The panel, the work list and the Scheduled row read Needs you too")

        let commandTool = NativeCommandTools.definitions(grants: { [] }, decision: .act(.rule), reason: { _ in nil }, record: { _ in })[0]
        let commandID = commandTool.id
        try require(NativeCompanionWorker.stepLiteral(toolID: commandID, toolTitle: commandTool.title,
                                                      argumentsJSON: "{\"command\":\"make pdf\",\"directory\":\"/Volumes/Notes\"}", title: "Run a command")
                        == "make pdf\nin /Volumes/Notes"
                    && NativeCompanionWorker.stepLiteral(toolID: nil, toolTitle: nil, argumentsJSON: nil, title: "Water a bed") == "Water a bed"
                    && NativeCompanionWorker.stepLiteral(toolID: commandID, toolTitle: nil,
                                                         argumentsJSON: "{\"command\":\"" + String(repeating: "x", count: 30000) + "\"}", title: "t")
                        .unicodeScalars.count == NativeTaskStop.stepScalars,
                    "A command step shows the command and its folder, a missing step falls back to its short title, and a long step is cut to fit")
        let longCommand = "rsync -a " + String(repeating: "notes/", count: 40) + " /Volumes/Backup"
        try require(NativeCompanionWorker.stepLiteral(toolID: commandID, toolTitle: nil,
                                                      argumentsJSON: NativeEffectProposal.canonicalArguments(.object(["command": .string(longCommand),
                                                                                                                      "directory": .string("/Volumes/Notes")])),
                                                      title: "Run a command: rsync -a notes/...") == longCommand + "\nin /Volumes/Notes",
                    "A step whose tool is no longer offered still shows the whole saved command and its folder")
        try require(NativeCompanionWorker.stepLiteral(toolID: "garden", toolTitle: nil, argumentsJSON: "{\"bed\":\"north\"}", title: "Water a bed")
                        == "Water a bed\nBed: north"
                    && NativeCompanionWorker.stepLiteral(toolID: "garden", toolTitle: nil, argumentsJSON: "{\"text\":\"hello\"}", title: "Send a note: hello")
                        == "Send a note\nText: hello",
                    "Without the tool, the action's name comes from the saved short title")
        try require(NativeCompanionWorker.earlierLine(done: [], unsure: []) == nil
                    && NativeCompanionWorker.earlierLine(done: ["Edit a file: plan.md"], unsure: []) == "Earlier in this work: Edit a file: plan.md."
                    && NativeCompanionWorker.earlierLine(done: ["A"], unsure: ["B", "C"])
                        == "Earlier in this work: A. These may have changed something: B; C.",
                    "The earlier line appears only when something ran or may have changed something")
        let shownStop = NativeTaskStop(reason: NativeTaskStop.declined, step: "Send a message\nTo: growers@example.com", earlier: "Earlier in this work: A.")
        try require(StoppedStepCopy.plain(shownStop, why: nil, places: RulePlaces(), name: nil)
                        == "You declined this step. It was not run.\n\nSend a message\nTo: growers@example.com\n\nEarlier in this work: A.",
                    "The companion panel's detail says whether the step ran, shows the step and the earlier line")

        let mixed = try NativeCompanionHarness(rules: [.networkSends: .act, .trash: .handOff]) { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call("water_bed", "{\"bed\":\"north\"}")
                : NativeCompanionScriptedModel.call("pull_weeds", "{\"bed\":\"north\"}", id: "call-2")
        }
        _ = try mixed.create()
        let after = try shown(try mixed.result(try await mixed.runUntilSettled()))
        try require(after.card.stop?.reason == NativeTaskStop.left && after.card.stop?.earlier?.hasPrefix("Earlier in this work:") == true
                        && after.card.stop?.earlier?.contains("Water a bed") == true,
                    "A step left to you after an earlier step ran says what ran: \(after.card.stop?.earlier ?? "nil")")
        try require(!fields(after.card).contains { $0.contains("Nothing was changed") } && after.artifact == nil,
                    "Nothing on that card says nothing changed")

        let declining = try NativeCompanionHarness(rules: [.networkSends: .ask], script: water)
        declining.model.classifier { .text("{\"keep\": true}") }
        _ = try declining.create()
        try declining.reply(try await declining.runUntilSettled(), "decline")
        let declinedResult = try declining.result(try await declining.runUntilSettled())
        let declined = try shown(declinedResult)
        try require(declinedResult["shape"] as? String == NativeCompanionShape.document
                        && (declinedResult["report"] as? String ?? "").hasPrefix("Stopped because you declined: Water a bed."),
                    "The declined run still ends as before and the classifier said keep")
        try require(declined.card.stop == NativeTaskStop(reason: NativeTaskStop.declined, step: "Water a bed\n" + card, earlier: nil) && declined.artifact == nil
                        && declined.card.answer == nil && declined.card.milestone.isEmpty,
                    "A declined step shows the step with no document, even when the classifier would keep one")
        try require(declined.card.statusTitle == NativeTaskCardPresentation.workStopped && !declined.card.needsYou
                        && declined.card.statusIcon == NativeTaskCardPresentation.Status.stopped.icon,
                    "A declined step reads Work stopped: \(declined.card.statusTitle)")
        let declinedPanel = CompanionOverviewModel.taskItem(card: declined.card, reference: declined.reference, decision: nil, hasArtifact: false, date: Date())
        try require(declinedPanel.state == NativeTaskCardPresentation.workStopped
                        && OngoingWork.item(declined.reference).state == NativeTaskCardPresentation.workStopped
                        && ChatStore.scheduleRunTitle(run, card: declined.card) == NativeTaskCardPresentation.workStopped,
                    "The panel, the work list and the Scheduled row read Work stopped for a declined step")

        let unsure = try NativeCompanionHarness(rules: [.networkSends: .act], script: water)
        unsure.service.transportFailWrites = true
        _ = try unsure.create()
        let asked = try await unsure.runUntilSettled()
        try require(asked.state == .needsDecision, "The person is asked whether the step happened")
        try unsure.reply(asked, "stop")
        let stoppedResult = try unsure.result(try await unsure.runUntilSettled())
        let stopped = try shown(stoppedResult)
        try require(stopped.card.stop == NativeTaskStop(reason: NativeTaskStop.unconfirmed, step: "Water a bed\n" + card, earlier: nil)
                        && (stoppedResult["report"] as? String ?? "").hasPrefix("Stopped at your request. It could not be confirmed whether this happened: Water a bed.")
                        && stopped.artifact == nil && stopped.card.statusTitle == NativeTaskCardPresentation.workStopped,
                    "Stopping when it is unclear whether a step happened saves that step: \(String(describing: stopped.card.stop))")
        try require(!StoppedStepCopy.line(NativeTaskStop.unconfirmed).plain(name: "Ada").contains("not run"),
                    "The unclear stop never claims the step did not run")

        let seeded = try CompanionLibraryKeepFixture.store(name: "Ada")
        defer { try? FileManager.default.removeItem(at: seeded.directory) }
        guard let thread = seeded.store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion thread exists") }
        func record(_ shown: (reference: NativeTaskReference, card: NativeTaskCardPresentation, artifact: NativeResearchArtifact?)) {
            seeded.store.recordTaskArtifacts([.taskCard(shown.card)] + (shown.artifact.map { [NativeDisplayBlock.artifact($0)] } ?? []),
                                             conversationID: thread, messageID: UUID().uuidString)
            seeded.store.reloadArtifacts()
        }
        for each in [leftShown, after, declined, stopped] { record(each) }
        try require(seeded.store.artifactRecords.isEmpty, "No stop reaches the Library: \(seeded.store.artifactRecords.map(\.title))")
        let keeping = try NativeCompanionHarness(rules: [.networkSends: .act], script: water)
        keeping.model.classifier { .text("{\"keep\": true}") }
        _ = try keeping.create()
        let kept = try shown(try keeping.result(try await keeping.runUntilSettled()), title: "Water the north bed")
        try require(kept.artifact != nil && kept.card.stop == nil, "A finished document still has its document")
        record(kept)
        try require(seeded.store.artifactRecords.count == 1, "A finished document still reaches the Library")

        var oldLeft = leftResult
        oldLeft["stop"] = nil
        let oldShown = try shown(oldLeft)
        try require(oldShown.card.stop == nil && oldShown.card.milestone == leftSaved.summary && oldShown.artifact != nil
                        && oldShown.card.statusTitle == RefusalCopy.needsYou && oldShown.card.why == leftWhy,
                    "An old step left to you draws as before, with its summary and document: \(oldShown.card.milestone)")
        var oldDeclined = declinedResult
        oldDeclined["stop"] = nil
        oldDeclined["shape"] = NativeCompanionShape.answer
        let oldDeclinedShown = try shown(oldDeclined)
        try require(oldDeclinedShown.card.stop == nil && oldDeclinedShown.card.answer?.hasPrefix("Stopped because you declined") == true
                        && oldDeclinedShown.card.statusTitle == "Work done" && oldDeclinedShown.artifact == nil,
                    "An old declined result draws its answer and reads Work done")
        var savedCard = try JSONSerialization.jsonObject(with: JSONEncoder().encode(leftShown.card)) as? [String: Any] ?? [:]
        try require(savedCard["stop"] != nil, "A card with a stop saves it")
        savedCard["stop"] = nil
        let olderCard = try JSONDecoder().decode(NativeTaskCardPresentation.self, from: JSONSerialization.data(withJSONObject: savedCard))
        try require(olderCard.stop == nil && olderCard.stoppedStep == nil && olderCard.statusTitle == RefusalCopy.needsYou,
                    "A card saved without a stop still opens")
        let reopened = try JSONDecoder().decode(NativeTaskCardPresentation.self, from: JSONEncoder().encode(declined.card))
        try require(reopened == declined.card, "A card with a stop keeps it through its saved form")

        var unknown = leftResult
        unknown["stop"] = ["reason": "later", "step": "Bed: north"]
        let unknownShown = try shown(unknown)
        try require(unknownShown.card.stop == nil && unknownShown.card.milestone == oldShown.card.milestone && unknownShown.artifact != nil
                        && unknownShown.card.statusTitle == oldShown.card.statusTitle,
                    "A stop reason this version does not know draws as before")
        var empty = leftResult
        empty["stop"] = ["reason": NativeTaskStop.left, "step": ""]
        try require(try shown(empty).card.stop == nil, "A stop with no step draws as before")

        let banned: Set<String> = ["grant", "kind", "class", "record", "scope", "origin", "effect", "resolver", "task", "worker", "handed",
                                   "vera", "she", "her", "he", "his", "him"]
        for name in [nil, "Ada"] as [String?] {
            for line in StoppedStepCopy.strings(name: name) {
                let words = Set(line.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
                try require(words.isDisjoint(with: banned) && !line.contains("\u{2014}"), "Plain words only: \(line)")
            }
        }
        let unnamed = StoppedStepCopy.line(NativeTaskStop.left).plain(name: nil)
        try require(unnamed == "Your companion did not run this step. It's left to you."
                        && StoppedStepCopy.line(NativeTaskStop.left).plain(name: "Ada") == "Ada did not run this step. It's left to you.",
                    "The left sentence names the companion: \(unnamed)")
        for reason in [NativeTaskStop.left, NativeTaskStop.declined] {
            let text = StoppedStepCopy.line(reason).plain(name: nil)
            try require(text.contains("not run"), "The sentence says the step was not run: \(text)")
        }
        print("  stopped step OK (left to you, after an earlier step, declined with keep, unclear stop, nothing in the Library, old results and cards, unknown reasons, plain words named and unnamed)")
    }
}
