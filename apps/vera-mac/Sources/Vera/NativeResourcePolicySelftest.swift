import Foundation

enum ResourcePolicyFixture {
    static func found(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    static func markers(_ job: NativeTaskGenerationJob) -> [String] {
        let text = job.messages.map(\.content).joined(separator: "\n")
        var seen: [String] = []
        for marker in found("Input [0-9]+\\b", in: text) where !seen.contains(marker) { seen.append(marker) }
        return seen
    }

    static func text(_ value: String) -> NativeTaskGenerationCompletion {
        let data = (try? JSONSerialization.data(withJSONObject: ["text": value])) ?? Data()
        return .text(String(decoding: data, as: UTF8.self))
    }

    static let outline = NativeTaskGenerationCompletion.text("{\"sections\":[{\"heading\":\"Beds\",\"instructions\":\"Cover the beds\"},{\"heading\":\"Water\",\"instructions\":\"Cover watering\"},{\"heading\":\"Tools\",\"instructions\":\"Cover the tools\"}]}")

    static func document(_ job: NativeTaskGenerationJob) -> NativeTaskGenerationCompletion {
        if job.phase.hasPrefix("condense") { return text("Notes: " + markers(job).joined(separator: ", ")) }
        if job.phase == "outline" { return outline }
        if job.phase.hasPrefix("draft") { return text("Draft for \(job.phase) using " + markers(job).joined(separator: ", ") + ".") }
        return text("Revised \(job.phase) using " + markers(job).joined(separator: ", ") + ".")
    }

    static let inputs: [String] = (1...30).map { "Input \($0): " + String(repeating: "Raised beds need deep soil and steady water. ", count: 45) }
}

@MainActor
extension SelfTest {
    static func resourcePolicy() async throws {
        try policyRules()
        let roomy = try await longDocumentCondensed(context: nil)
        let tight = try await longDocumentCondensed(context: 6_000)
        try NativeTaskFixture.require(tight > roomy, "A small context condenses the same request in more steps: \(tight) against \(roomy)")
        try await documentRelaunchDuringCondense()
        try await documentRevisionRecorded()
        try await researchBatchedNotes()
    }

    private static func policyRules() throws {
        let require = NativeTaskFixture.require
        typealias Policy = NativeResourcePolicy
        let named: Set<String> = [
            "defaultContextTokens", "charactersPerToken", "replyShareDivisor", "reasoningShareDivisor", "wrapperReserveTokens",
            "messageOverheadBytes", "shortestSectionCharacters", "maximumShrinks", "fullSectionCharacters", "headingCharacters",
            "instructionCharacters", "titleCharacters", "condenseShrinkPercent", "materialShareDivisor", "condenseInputMultiple",
            "legacyMaximumSections", "legacyMaximumSources", "searchResultsPerQuestion", "pageCharacters", "reviewCharacters", "urlBytes",
            "noteLineCharacters", "keptNoteLines", "progressSources", "noteQuestionCharacters", "shortestPlanCharacters",
            "maximumPlanAttempts", "maximumRequestedBullets", "wireEncodingMultiple", "jobBytes", "jobFrameBytes",
            "legacyPromptBytes", "legacyOutputTokens", "legacyReportCharacters", "legacyResearchReportCharacters", "legacySourceCharacters",
            "companionReportScalars", "companionNoteScalars", "companionStepScalars", "summaryCharacters",
            "companionCheckpointReserveBytes", "companionUnknownMessageBytes", "companionSeparatorBytes", "companionMarkerBytes",
            "companionEffects", "companionDecisionScalars", "companionLabelScalars", "companionArgumentCharacters",
            "companionCallOverheadBytes", "companionToolReserveBytes", "companionShortestResultBytes", "companionShortestReportScalars",
            "companionClosingReserveBytes", "companionReplyReserveBytes", "companionAnswerBytes",
            "savedResultBytes", "requestBytes", "savedSnapshotBytes",
        ]
        try require(Set(Policy.reasons.keys) == named && Policy.reasons.values.allSatisfy { $0.count > 20 && !$0.contains("\u{2014}") },
                    "Every limit in the policy has a stated reason: \(Set(Policy.reasons.keys).symmetricDifference(named))")
        try require(Policy.defaultContextTokens == 32_000, "The one documented default context size is 32,000 tokens")
        let unknown = Policy(contextTokens: Policy.defaultContextTokens, outputTokens: nil, reasoning: false)
        let small = Policy(contextTokens: 4_000, outputTokens: nil, reasoning: false)
        let huge = Policy(contextTokens: 2_000_000, outputTokens: nil, reasoning: false)
        try require(!unknown.legacy && unknown.promptBytes == 72_000 && unknown.sectionCharacters == Policy.fullSectionCharacters,
                    "With the default context, prompts get three quarters of it and sections ask for full size")
        try require(small.promptBytes == 9_000 && small.promptBytes < unknown.promptBytes, "A small reported context gives a smaller prompt room")
        try require(huge.promptBytes == Policy.jobBytes / Policy.wireEncodingMultiple - Policy.jobFrameBytes,
                    "A very large context is still kept inside one request's size")
        let legacy = Policy(nil)
        try require(legacy.legacy && legacy.promptBytes == Policy.legacyPromptBytes && legacy.sectionCharacters == Policy.fullSectionCharacters
                    && legacy.reportCharacters == Policy.legacyReportCharacters && legacy.sourceCharacters == Policy.legacySourceCharacters,
                    "Work saved before the policy keeps the sizes it started with")
        try require(NativeTaskGenerationBudget.forWorker("document").maximumBytes == NativeTaskGenerationBudget.standard.maximumBytes
                    && NativeTaskGenerationBudget.forWorker("document", binding: NativeTaskAdmissionBinding(id: "b", admissionBase: URL(string: "https://a.test")!,
                        enrollmentDigest: "d", contextTokens: 200_000)).maximumBytes > NativeTaskGenerationBudget.standard.maximumBytes,
                    "The size of one request follows the saved context size, and stays as it was for older work")
        let list = Data(#"{"data":[{"id":"big/model","context_length":200000},{"id":"routed/model","top_provider":{"context_length":131072}},{"id":"plain"},{"id":"odd","context_length":true}]}"#.utf8)
        try require(NativeChatClient.modelContexts(from: list) == ["big/model": 200_000, "routed/model": 131_072],
                    "The model list's context sizes are read, and anything that isn't a positive whole number is ignored")
        let line = Policy.tooLarge(300_001, limit: 262_000, what: "finished document")
        try require(line == "The finished document is 300,001 characters, and Tandem can save one of up to about 262,000. The finished parts are kept.",
                    "A result too large to save says both numbers")
        try require(NativeTaskProjection.unrevisedLine(1) == "The document is ready. One section wasn't given a revision pass."
                    && NativeTaskProjection.unrevisedLine(3) == "The document is ready. 3 sections weren't given a revision pass."
                    && NativeTaskProjection.condensingLine == "Condensing the material so it fits."
                    && NativeDocumentWorker.condenseStuckMessage == "The material for this document couldn't be condensed enough to fit the model. The parts already condensed are kept. Try this step again?",
                    "The new card lines read exactly as written")
        try require(NativeResearchTaskRequest.shortTitle("Write a full guide to the raised beds in the back garden, covering soil, water, tools and the planting calendar for every season of the year")
                    == "Write a full guide to the raised beds in the back garden, covering soil, water, tools and the planting calendar for",
                    "A long objective gives a short derived title")
        let untitled = try NativeResearchTaskRequest(objective: "Compare quiet reading spaces.\nUse each library's own page.", deliverables: [], workerType: "document")
        try require(untitled.displayTitle == "Compare quiet reading spaces", "With no title given, the shown title is derived from the first line")
    }

    private static func longDocumentCondensed(context: Int?) async throws -> Int {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter,
                                                            profileContextTokens: context) { job in ResourcePolicyFixture.document(job) }
        try await harness.start()
        let inputs = ResourcePolicyFixture.inputs
        try require(inputs.count == 30 && inputs.reduce(0) { $0 + $1.count } >= 60_000, "The fixture is 30 inputs and at least 60,000 characters")
        let reference = try await harness.submitDocument(title: "Raised beds", brief: "Write a guide to the raised beds.", inputs: inputs)
        try require(try await harness.wait(seconds: 40) { try harness.state(reference) == .completed },
                    "A document with 30 long inputs completes: \(String(describing: try harness.state(reference)))")
        let report = try repository.taskProjection(id: reference.id)?.snapshot?.result?.report ?? ""
        let missing = (1...30).filter { !report.contains("Input \($0)") }
        try require(missing.isEmpty, "Every input is reflected in the finished document, missing \(missing)")
        let condensed = await counter.count(prefix: "generate:condense")
        try require(condensed > 0, "The material was condensed in steps before planning")
        let references = try repository.taskReferences(conversationID: nil)
        try require(references.count == 1 && references[0].snapshot?.state == .completed, "The document is saved once")
        await harness.stop()
        return condensed
    }

    private static func documentRelaunchDuringCondense() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let first = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter, profileContextTokens: 6_000) { job in
            ResourcePolicyFixture.document(job)
        }
        try await first.start()
        let reference = try await first.submitDocument(title: "Raised beds", brief: "Write a guide to the raised beds.", inputs: ResourcePolicyFixture.inputs)
        var started = false
        for _ in 0..<800 where !started {
            started = await counter.count(prefix: "generate:condense") >= 3
            if !started { try await Task.sleep(for: .milliseconds(25)) }
        }
        try require(started, "Condensing has started")
        await first.crash()
        let second = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter, profileContextTokens: 6_000) { job in
            ResourcePolicyFixture.document(job)
        }
        try await second.start()
        try require(try await second.wait(seconds: 40) { try second.state(reference) == .completed }, "After a relaunch the document finishes")
        try require(await counter.count("generate:condense-0") == 1, "A part condensed before the relaunch is not condensed again")
        let references = try repository.taskReferences(conversationID: nil)
        try require(references.count == 1, "The relaunch saves no second document")
        await second.stop()
    }

    private static func documentRevisionRecorded() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let long = String(repeating: "w", count: 2_950)
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: NativeTaskEngineCounter(),
                                                            profileContextTokens: 1_800) { job in
            if job.phase == "outline" { return .text("{\"sections\":[{\"heading\":\"Beds\",\"instructions\":\"Cover the beds\"}]}") }
            if job.phase.hasPrefix("draft") { return ResourcePolicyFixture.text(long) }
            return ResourcePolicyFixture.text("Revised.")
        }
        try await harness.start()
        let reference = try await harness.submitDocument(title: "Beds", brief: "Write about the beds.", inputs: ["Soil"])
        try require(try await harness.wait(seconds: 20) { try harness.state(reference) == .completed }, "The document finishes")
        let snapshot = try repository.taskProjection(id: reference.id)!.snapshot!
        try require(snapshot.checkpoint.unrevised == [0], "A revision that couldn't run is recorded")
        let card = try NativeTaskProjection.display(reference: try repository.taskReference(id: reference.id)!, snapshot: snapshot).card
        try require(card.milestone == NativeTaskProjection.unrevisedLine(1), "The card says the section wasn't revised: \(card.milestone)")
        try require(snapshot.result?.report.contains(long) == true, "The draft is kept as written")
        await harness.stop()
    }

    private static func researchBatchedNotes() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let search = NativeResearchSearch { query, _ in
            (0..<4).map { index in
                NativeResearchSource(n: 0, title: "Source \(query.count)-\(index)", url: "https://sources.test/\(query.count)/\(index)",
                                     content: "Finding \(query.count)-\(index). " + String(repeating: "Detail about quiet reading rooms. ", count: 60))
            }
        }
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter, search: search,
                                                            profileContextTokens: 3_000) { job in
            let text = job.messages.map(\.content).joined(separator: "\n")
            let numbers = Set(ResourcePolicyFixture.found("\\[[0-9]+\\]", in: text)).sorted()
            if job.phase == "plan" { return .text("{\"subquestions\":[\"Which rooms\",\"Which opening hours\",\"Which house rules apply\",\"Which seats are best\"]}") }
            if job.phase == "review" { return .text("{}") }
            if job.phase.hasPrefix("notes") { return .text("Notes " + numbers.joined(separator: " ")) }
            return .text("Summary of the rooms. " + numbers.map { "A finding \($0)." }.joined(separator: " ") + "\n\nSources: listed.")
        }
        try await harness.start()
        let reference = try await harness.submit("Compare quiet reading rooms")
        try require(try await harness.wait(seconds: 40) { try harness.state(reference) == .completed },
                    "Research with more gathered text than one prompt holds completes: \(String(describing: try harness.state(reference)))")
        let result = try repository.taskProjection(id: reference.id)!.snapshot!.result!
        let cited = NativeResearchWorker.citations(in: result.report).numbers
        let all = Set(result.sources.map(\.n))
        try require(all.count > 14 && cited == all, "Every gathered source, past the old 14, is cited from the batched notes")
        try require(await counter.count(prefix: "generate:notes") > 1, "The sources were read in more than one batch")
        await harness.stop()
    }
}
