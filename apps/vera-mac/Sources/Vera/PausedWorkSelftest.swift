import Foundation

@MainActor
extension SelfTest {
    static func runPausedWork() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)

        let mixed = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 3, searchOnly: 2))
        let pause = try pausedValue(mixed.card.pausedWork, "The keep-going question carries what was read")
        try require(pause.read.map(\.n) == [1, 3, 5] && pause.more == 0 && pause.earlier == nil,
                    "Only read pages are listed, in saved order: \(pause.read.map(\.n))")
        try require(pause.read.allSatisfy { $0.url.hasPrefix("https://library.example.org/") } && mixed.card.sources.isEmpty,
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
        try require(emptyPause.read.isEmpty && emptyLines.contains(PausedWorkCopy.nothingFound) && !emptyLines.contains(PausedWorkCopy.readHeading),
                    "Nothing read shows the nothing-found line and no heading")

        let many = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 9, searchOnly: 0))
        let manyPause = try pausedValue(many.card.pausedWork, "Many read pages still draw")
        try require(manyPause.read.count == 6 && manyPause.more == 3 && PausedWorkCopy.lines(manyPause, name: nil).contains("and 3 more"),
                    "Nine read pages show six and a count of the rest")

        let crowded = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 12, searchOnly: 8))
        let crowdedPause = try pausedValue(crowded.card.pausedWork, "Twenty saved sources still draw")
        try require(crowdedPause.read.count == 6 && crowdedPause.more == 6 && crowdedPause.read.allSatisfy { $0.n <= 20 },
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
                                            "sources": [["n": 1, "title": "Rain totals", "url": "https://weather.example/rain"]]]
        let old = try PausedWorkFixture.seed(repository, checkpoint: oldCheckpoint, decision: [
            "id": "cap-old", "prompt": "Keep going, or finish with what it has?", "choices": ["continue", "finish"]])
        let oldPause = try pausedValue(old.card.pausedWork, "Older waiting work shows the new question")
        try require(PausedWorkCopy.lines(oldPause, name: "Ada") == [PausedWorkCopy.line.plain(name: "Ada"), PausedWorkCopy.nothingFound],
                    "Older waiting work shows the new sentence and the nothing-found line")

        for (choice, line) in [("finish", PausedWorkCopy.finishing), ("continue", PausedWorkCopy.keepingGoing)] {
            let answered = try PausedWorkFixture.seed(repository, checkpoint: PausedWorkFixture.checkpoint(read: 2, searchOnly: 1), answer: choice)
            try require(answered.card.pausedWork?.answer == choice && answered.card.milestone == line && answered.card.offeredChoices.isEmpty
                        && answered.card.choices == [] && PausedWorkCopy.lines(answered.card.pausedWork!, name: nil) == [line],
                        "An accepted \(choice) shows its line and no answers")
            try require(answered.card.statusTitle == "Working on it", "Answered work no longer asks for an answer")
        }

        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                              artifactPersistenceEnabled: false)
        for seeded in [mixed, many, empty, earlier] {
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
        let plain = CompanionActivityDetail(request: "Water the beds", outcome: nil, canOpen: true)
        try require(!plain.showsRequest(title: "Water the beds") && plain.showsRequest(title: "Garden"),
                    "Identical title and request show once")

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

        let banned: Set<String> = ["grant", "grants", "kind", "kinds", "class", "classes", "record", "records", "resolver", "artifact",
                                   "artifacts", "worker", "workers", "task", "tasks", "checkpoint", "checkpoints", "budget", "budgets",
                                   "limit", "limits", "rounds", "round", "vera", "she", "her", "he", "his", "him", "hers"]
        let shown = [nil, "Ada"].flatMap { name in
            PausedWorkCopy.strings(name: name) + [pause, emptyPause, manyPause, oldPause].flatMap { PausedWorkCopy.lines($0, name: name) }
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

    private static func pausedValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NativeTaskFixture.Failure.assertion(message) }
        return value
    }
}
