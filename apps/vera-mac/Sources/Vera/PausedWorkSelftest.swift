import Foundation

@MainActor
extension SelfTest {
    static func runPausedWork() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)

        let mixed = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 3, searchOnly: 2))
        let pause = try pausedValue(mixed.card.pausedWork, "The keep-going question carries what was read")
        try require(pause.pages.map(\.n) == [1, 3, 5] && pause.more == 0 && pause.earlier == nil && pause.heading == PausedWorkCopy.readHeading,
                    "Only read pages are listed, in saved order: \(pause.pages.map(\.n))")
        try require(pause.decisionID == PausedWorkFixture.decisionID, "The pause remembers which question it shows")
        try require(pause.pages.allSatisfy { $0.url.hasPrefix("https://library.example.org/") } && mixed.card.sources.isEmpty,
                    "Read pages keep their links and nothing else is listed as a source")
        let searched = Set(["Riverside Branch reading room", "Market Street Branch reading room"])
        try require(searched.isDisjoint(with: PausedWorkCopy.lines(pause, name: "Ada")), "Pages only found in a search are never listed")
        try require(PausedWorkCopy.lines(pause, name: "Ada").prefix(2) == [PausedWorkCopy.line.plain(name: "Ada"), PausedWorkCopy.readHeading],
                    "The question leads, then the read list heading")
        try require(mixed.card.milestone == PausedWorkCopy.savedMilestone && mixed.card.choices == ["continue", "finish"],
                    "The card asks the new question with both answers offered")
        try require(PausedWorkCopy.line.plain(name: nil)
                    == "Your companion paused with the work saved. Keep going, or finish with what's been found so far?",
                    "Unnamed work reads plainly")

        let empty = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 0, searchOnly: 4))
        let emptyPause = try pausedValue(empty.card.pausedWork, "Waiting work with nothing read still asks")
        let emptyLines = PausedWorkCopy.lines(emptyPause, name: nil)
        try require(emptyPause.pages.isEmpty && emptyLines.contains("No pages have been read yet.")
                    && !emptyLines.contains(PausedWorkCopy.readHeading) && !emptyLines.contains(PausedWorkCopy.foundHeading),
                    "Search-only work says no pages have been read yet, with no heading: \(emptyLines)")
        try require(!emptyLines.contains { $0.lowercased().contains("nothing") }, "The pause never claims nothing useful was found")

        let many = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 9, searchOnly: 0))
        let manyPause = try pausedValue(many.card.pausedWork, "Many read pages still draw")
        try require(manyPause.pages.count == 6 && manyPause.more == 3 && PausedWorkCopy.lines(manyPause, name: nil).contains("and 3 more"),
                    "Nine read pages show six and a count of the rest")

        let crowded = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 12, searchOnly: 8))
        let crowdedPause = try pausedValue(crowded.card.pausedWork, "Twenty saved sources still draw")
        try require(crowdedPause.pages.count == 6 && crowdedPause.more == 6 && crowdedPause.pages.allSatisfy { $0.n <= 20 },
                    "Twenty saved sources never fail the card")

        let earlier = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 2, searchOnly: 1, earlier: true))
        try require(earlier.card.pausedWork?.earlier == "Earlier in this work: Save a note: reading-rooms.md.",
                    "Earlier changes are mentioned with the shared line")

        var approvalCheckpoint = PausedWorkFixture.checkpoint(read: 2, searchOnly: 0)
        approvalCheckpoint["pending"] = ["kind": "approval", "call_id": "call-1", "digest": "abc"]
        let approvalPrompt = CompanionSavedText.marker + " wants to send a note to the reading room desk."
        let approval = try PausedWorkFixture.seed(repository, checkpoint: approvalCheckpoint, decision: [
            "id": "approval-1", "prompt": approvalPrompt, "choices": ["decline", "allow_always", "approve"],
            "details": "Send a note\nto: desk@library.example.org"])
        try require(approval.card.pause == nil && approval.card.milestone == approvalPrompt
                    && approval.card.details == "Send a note\nto: desk@library.example.org"
                    && approval.card.choices == ["decline", "allow_always", "approve"] && !approval.card.canRetry,
                    "An approval projects as before")
        var capApproval = PausedWorkFixture.checkpoint(read: 1, searchOnly: 0)
        capApproval["pending"] = ["kind": "cap"]
        let mismatched = try PausedWorkFixture.seed(repository, checkpoint: capApproval, decision: [
            "id": "approval-2", "prompt": approvalPrompt, "choices": ["decline", "approve"]])
        try require(mismatched.card.pause == nil && mismatched.card.milestone == approvalPrompt,
                    "Other answers are never read as the keep-going question")
        let retryPrompt = "The write-up didn't cite its sources correctly. Retry this step?"
        let retry = try PausedWorkFixture.seed(repository, checkpoint: ["sources": []], decision: [
            "id": "retry-1", "prompt": retryPrompt, "choices": ["retry"]])
        try require(retry.card.pause == nil && retry.card.milestone == retryPrompt && retry.card.canRetry && retry.card.choices == ["retry"],
                    "A retry projects as before")
        let noPending = try PausedWorkFixture.seed(repository, checkpoint: ["sources": []], decision: PausedWorkFixture.decision)
        try require(noPending.card.pause == nil && noPending.card.milestone == PausedWorkFixture.oldPrompt,
                    "The question is recognized by what was saved, not by its wording")

        let oldCheckpoint: [String: Any] = ["pending": ["kind": "cap"], "rounds": 4, "calls": 4,
                                            "sources": [["n": 1, "title": "Opening hours", "url": "https://hours.example.org/reading-rooms"]]]
        let old = try PausedWorkFixture.seed(repository, checkpoint: oldCheckpoint, decision: [
            "id": "cap-old", "prompt": "Keep going, or finish with what it has?", "choices": ["continue", "finish"]])
        let oldPause = try pausedValue(old.card.pausedWork, "Older waiting work shows the new question")
        try require(PausedWorkCopy.lines(oldPause, name: "Ada") == [PausedWorkCopy.line.plain(name: "Ada"), "Found so far", "Opening hours"],
                    "Older waiting work whose pages have no read mark lists them as found: \(PausedWorkCopy.lines(oldPause, name: "Ada"))")

        let unknown = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 0, searchOnly: 2, unknown: 8))
        let unknownPause = try pausedValue(unknown.card.pausedWork, "Older saved pages still draw")
        try require(unknownPause.heading == PausedWorkCopy.foundHeading && unknownPause.pages.map(\.n) == [3, 4, 5, 6, 7, 8]
                    && unknownPause.more == 2 && PausedWorkCopy.lines(unknownPause, name: nil).contains("and 2 more"),
                    "Older saved pages show under Found so far with the same cap, and search-only pages stay out: \(unknownPause.pages.map(\.n))")
        var both = PausedWorkFixture.checkpoint(read: 2, searchOnly: 1)
        both["sources"] = (both["sources"] as? [[String: Any]] ?? []) + [PausedWorkFixture.source(9, read: nil)]
        let bothPause = try pausedValue(try PausedWorkFixture.seed(repository, checkpoint: both).card.pausedWork, "Mixed marks draw")
        try require(bothPause.heading == PausedWorkCopy.readHeading && bothPause.pages.map(\.n) == [1, 3],
                    "When some pages were read, only those are listed under Read so far: \(bothPause.pages.map(\.n))")

        let addressed: [String: Any] = ["pending": ["kind": "cap"], "sources": [
            ["n": 1, "title": "https://www.example.org/reading-rooms", "url": "https://www.example.org/reading-rooms", "read": true],
            ["n": 2, "title": "", "url": "https://branch.example.org/hours", "read": true],
            ["n": 3, "title": "http://old.example.org/", "url": "https://hours.example.org/rooms", "read": true]]]
        let addressedPause = try pausedValue(try PausedWorkFixture.seed(repository, checkpoint: addressed).card.pausedWork, "Address-titled pages draw")
        try require(addressedPause.pages.map(\.title) == ["example.org", "branch.example.org", "hours.example.org"],
                    "Pages titled with an address show the site name: \(addressedPause.pages.map(\.title))")
        try require(PausedWorkCopy.lines(addressedPause, name: nil).allSatisfy { !$0.contains("http") }, "No address is shown as a label")
        try require(NativeTaskSource(n: 1, title: "", url: "notes.txt").label == "Saved page"
                    && NativeTaskSource(n: 1, title: "Map room", url: "https://example.org/map").label == "Map room",
                    "A page with no title and no site reads as a saved page, and a real title is kept")

        for (choice, line) in [("finish", PausedWorkCopy.finishing), ("continue", PausedWorkCopy.keepingGoing)] {
            let answered = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 2, searchOnly: 1), answer: choice)
            try require(answered.card.pausedWork?.answer == choice && answered.card.milestone == line && answered.card.offeredChoices.isEmpty
                        && answered.card.choices == [] && PausedWorkCopy.lines(answered.card.pausedWork!, name: nil) == [line],
                        "An accepted \(choice) shows its line and no answers")
            try require(answered.card.statusTitle == "Working on it", "Answered work no longer asks for an answer")
        }

        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                              artifactPersistenceEnabled: false)
        for seeded in [mixed, many, empty, earlier, unknown] {
            store.nativeTaskReferences = [seeded.reference]
            let item = CompanionOverviewModel.taskItem(card: seeded.card, reference: seeded.reference,
                                                       decision: seeded.reference.snapshot?.decision, hasArtifact: false, date: Date())
            let detail = store.companionActivityDetail(item)
            try require(detail.pause == seeded.card.pausedWork && detail.outcome == nil && !detail.showsRequest(title: item.title)
                        && !item.canRetry, "The details show what the card shows, once")
        }
        let finishing = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 3, searchOnly: 0), answer: "finish")
        store.nativeTaskReferences = [finishing.reference]
        let finishingItem = CompanionOverviewModel.taskItem(card: finishing.card, reference: finishing.reference,
                                                            decision: finishing.reference.snapshot?.decision, hasArtifact: false, date: Date())
        let finishingDetail = store.companionActivityDetail(finishingItem)
        try require(finishingDetail.pause == finishing.card.pausedWork && finishingDetail.pause?.answer == "finish"
                    && finishingItem.state == "Working on it", "The details agree once Finish is accepted")
        let plain = CompanionActivityDetail(request: "Check the reading room hours", outcome: nil, canOpen: true)
        try require(!plain.showsRequest(title: " Check the reading room hours ") && plain.showsRequest(title: "Reading rooms"),
                    "Identical title and request show once")
        let fuller = PausedWorkFixture.longAssignment
        let asking = CompanionActivityDetail(request: fuller, outcome: nil, canOpen: true, pause: pause)
        let waiting = CompanionActivityDetail(request: fuller, outcome: nil, canOpen: true,
                                              pause: try pausedValue(finishing.card.pausedWork, "Finishing pause"))
        try require(asking.showsRequest(title: "Reading rooms") && waiting.showsRequest(title: "Reading rooms"),
                    "A short title with a fuller request still shows the request during a pause and while an answer waits")
        try require(!CompanionActivityDetail(request: "Reading rooms", outcome: nil, canOpen: true, pause: pause).showsRequest(title: "Reading rooms"),
                    "A pause whose request matches the title shows it once")

        let running = try PausedWorkFixture.snapshot(finishing.reference, remote: finishing.reference.remoteTaskID ?? "",
                                                     state: "running", checkpoint: ["finishing": true], decision: nil)
        let runningCard = try NativeTaskProjection.display(reference: finishing.reference, snapshot: running).card
        try require(runningCard.milestone == PausedWorkCopy.finishing, "Running work that is finishing says so")
        let blocked = try PausedWorkFixture.snapshot(finishing.reference, remote: finishing.reference.remoteTaskID ?? "",
                                                     state: "blocked", checkpoint: ["finishing": true, "native_unavailable": "profile"], decision: nil)
        let blockedCard = try NativeTaskProjection.display(reference: finishing.reference, snapshot: blocked).card
        try require(blockedCard.milestone.hasPrefix(PausedWorkCopy.finishing) && blockedCard.milestone.contains("Keep Tandem open"),
                    "Blocked work that is finishing keeps the instruction: \(blockedCard.milestone)")
        let plainRunning = try PausedWorkFixture.snapshot(finishing.reference, remote: finishing.reference.remoteTaskID ?? "",
                                                          state: "running", checkpoint: [:], decision: nil)
        try require(try NativeTaskProjection.display(reference: finishing.reference, snapshot: plainRunning).card.milestone == "Working on your goal.",
                    "Ordinary running work reads as before")

        try await pausedStaleAnswer()
        try pausedOverviewAnswer()

        let banned: Set<String> = ["grant", "grants", "kind", "kinds", "class", "classes", "record", "records", "resolver", "artifact",
                                   "artifacts", "worker", "workers", "task", "tasks", "checkpoint", "checkpoints", "budget", "budgets",
                                   "limit", "limits", "rounds", "round", "vera", "she", "her", "he", "his", "him", "hers"]
        let shown = [nil, "Ada"].flatMap { name in
            PausedWorkCopy.strings(name: name) + [pause, emptyPause, manyPause, oldPause, unknownPause].flatMap { PausedWorkCopy.lines($0, name: name) }
        }
        for text in shown {
            let words = text.lowercased().split { !$0.isLetter }.map(String.init)
            try require(words.allSatisfy { !banned.contains($0) }, "No internal or gendered word: \(text)")
            for (first, second) in [("hand", "off"), ("actions", "used")] {
                try require(!zip(words, words.dropFirst()).contains { $0 == first && $1 == second }, "No \(first) \(second): \(text)")
            }
            try require(!text.contains("\u{2014}") && !text.contains(CompanionSavedText.marker), "No dash or marker: \(text)")
        }
    }

    private static func pausedStaleAnswer() async throws {
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("chat.sqlite"))
        let engine = URL(string: "https://engine.test/api")!
        let seeded = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 2, searchOnly: 1), engine: engine)
        let id = seeded.reference.id
        let remote = seeded.reference.remoteTaskID ?? ""
        let questionA = try PausedWorkFixture.snapshot(seeded.reference, remote: remote,
                                                       checkpoint: PausedWorkFixture.checkpoint(read: 2, searchOnly: 1),
                                                       decision: PausedWorkFixture.decision)
        let resumed = try PausedWorkFixture.snapshot(seeded.reference, remote: remote, state: "queued",
                                                     checkpoint: PausedWorkFixture.checkpoint(read: 2, searchOnly: 1), decision: nil)
        let bodies = NativeTaskDisplayFixtureBodies()
        let client = NativeTaskClient { method, url, body, _ in
            if method == "POST", let body { await bodies.record(body) }
            return (try nativeTaskEncoded(url.lastPathComponent == "decision" ? resumed : questionA), 200)
        }
        let service = NativeTaskHandoffService(repository: repository, client: client, configuredBase: { engine })
        let tracker = NativeTaskTracker(repository: repository, client: client, service: service, configuredBase: { engine })
        await tracker.decide(id, choice: "continue", expecting: PausedWorkFixture.decisionID)
        let first = await bodies.values
        let firstBody = first.first.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        try require(first.count == 1 && (firstBody?["reply"] as? [String: Any])?["action"] as? String == "continue"
                    && firstBody?["decision_id"] as? String == PausedWorkFixture.decisionID,
                    "An answer for the question on screen is delivered")

        let questionB = try PausedWorkFixture.snapshot(seeded.reference, remote: remote,
                                                       checkpoint: PausedWorkFixture.checkpoint(read: 3, searchOnly: 1),
                                                       decision: ["id": "cap-2", "prompt": PausedWorkFixture.oldPrompt, "choices": ["continue", "finish"]])
        _ = try repository.projectTask(id: id, snapshot: questionB)
        await tracker.decide(id, choice: "finish", expecting: PausedWorkFixture.decisionID)
        try require(await bodies.values.count == 1, "A late answer for an earlier question sends nothing")
        try require(try repository.pendingTaskRetries().allSatisfy { $0.referenceID != id },
                    "A late answer for an earlier question prepares nothing for the new one")
        let card = PausedWorkFixture.card(try repository.projectTask(id: id, snapshot: nil))
        try require(card?.pausedWork?.decisionID == "cap-2" && card?.pausedWork?.answer == nil && card?.choices == ["continue", "finish"],
                    "The new question is still waiting for an answer")
        await tracker.stop()
    }

    private static func pausedOverviewAnswer() throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                              artifactPersistenceEnabled: false)
        store.dotProfile = NativeDotProfile(goal: "Keep track of the reading rooms", state: .active, setupCompleted: true)
        store.ensureVeraThread()
        guard let thread = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion conversation opens") }
        for choice in ["finish", "continue"] {
            let seeded = try PausedWorkFixture.seed(repository, conversationID: thread, assignment: PausedWorkFixture.longAssignment,
                                                    checkpoint: PausedWorkFixture.checkpoint(read: 2, searchOnly: 1))
            store.nativeTaskReferences = [seeded.reference]
            let asking = try pausedValue(store.companionOverviewModel().activity.first { $0.taskID == seeded.reference.id },
                                         "The waiting work is in the overview")
            try require(asking.state == "Needs your answer", "Before an answer the overview asks: \(asking.state)")
            _ = try repository.prepareTaskDecision(id: seeded.reference.id, decisionID: PausedWorkFixture.decisionID, choice: choice)
            let item = try pausedValue(store.companionOverviewModel().activity.first { $0.taskID == seeded.reference.id },
                                       "The answered work is in the overview")
            let detail = store.companionActivityDetail(item)
            let line = choice == "finish" ? PausedWorkCopy.finishing : PausedWorkCopy.keepingGoing
            try require(item.state == "Working on it" && detail.pause?.answer == choice
                        && detail.pause.map { PausedWorkCopy.lines($0, name: "Ada") } == [line],
                        "Once \(choice) is saved the overview and the details agree: \(item.state)")
            try require(detail.showsRequest(title: item.title) == (item.title != PausedWorkFixture.longAssignment),
                        "The request shows only when it says more than the title")
        }
    }

    private static func pausedValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NativeTaskFixture.Failure.assertion(message) }
        return value
    }
}
