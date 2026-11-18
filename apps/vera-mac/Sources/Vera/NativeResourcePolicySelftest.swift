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
        try NativeTaskFixture.require(roomy == 0 && tight > 1,
                                      "The default context takes the request whole, and a small context condenses it in steps first: \(tight) against \(roomy)")
        try await documentRelaunchDuringCondense()
        try await documentRevisionRecorded()
        try await researchBatchedNotes()
        try await documentPlanTooLarge()
        try await documentQuotedMaterial()
        try await documentBulletsCondensed()
        try await documentRetryAfterStuck()
        try await researchLongQuestion()
        try encodedSplitting()
        try await contextLookupBounded()
    }

    private static func contextLookupBounded() async throws {
        let base = URL(string: "https://slow-models.test/v1")!
        let held = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        defer { held.cancel() }
        NativeModelContext.shared.watch(base: base, lookup: held)
        let started = ContinuousClock.now
        await NativeModelContext.shared.settle(base: base, within: .milliseconds(300))
        let waited = ContinuousClock.now - started
        try NativeTaskFixture.require(waited < .seconds(5), "A model list still loading past the bound doesn't hold up starting work: \(waited)")
    }

    private static func encodedSplitting() throws {
        let require = NativeTaskFixture.require
        typealias Policy = NativeResourcePolicy
        try require(Policy.wireCost("a") == 1 && Policy.wireCost("\"") == 4 && Policy.wireCost("\n") == 3 && Policy.wireCost("\u{00E9}") == 2,
                    "A character's size as sent counts its escaping")
        let quotes = String(repeating: "\"", count: 1_000)
        let pieces = Policy.parts([quotes], budget: 400)
        try require(pieces.count > 1, "A long run of quotes is split into several parts")
        try require(pieces.allSatisfy { Policy.wireCost($0) <= 400 } && pieces.joined().count == quotes.count,
                    "Text full of quotes is split by its size as sent and nothing is lost")
        let mixed = String(repeating: " aaaa\u{1F600}\"/\u{2028}\n", count: 300)
        for budget in [64, 65, 77, 128, 199] {
            let cut = Policy.parts([mixed, "aa", "bb"], budget: budget, prefix: { $0 == 0 ? "[1] A source (https://s.test/x)\n" : "" })
            try require(cut.allSatisfy { Policy.wireCost($0) <= budget }, "Every part, joined or prefixed, stays within \(budget) bytes as sent")
        }
        try require(Policy.parts(["aa", "bb"], budget: 64) == ["aa\n\nbb"] && Policy.parts(["x"], budget: 1) == ["x"],
                    "Small parts are joined with a blank line, and a part is never smaller than the minimum")
        let hugeLabel = Policy.parts([String(repeating: "c", count: 300)], budget: 64, prefix: { _ in String(repeating: "L", count: 500) })
        try require(hugeLabel.allSatisfy { Policy.wireCost($0) <= 64 && $0.contains("c") }, "A label larger than a part is shortened so content still fits")
        let piled = "a" + String(repeating: "\u{0301}", count: 500)
        let scalars = Policy.parts([piled], budget: 100)
        try require(scalars.allSatisfy { Policy.wireCost($0) <= 100 } && scalars.joined().unicodeScalars.count == piled.unicodeScalars.count,
                    "A single character heavier than a part is split by its scalars")
        let headed = Policy.parts([String(repeating: "x", count: 900)], budget: 200, prefix: { _ in "[3] Title (https://a.test)\n" })
        try require(headed.count > 1 && headed.allSatisfy { $0.hasPrefix("[3] Title (https://a.test)\n") },
                    "Every fragment of a split source keeps its number and address")
        let payload = NativeResearchTaskPayload(request: try NativeResearchTaskRequest(objective: "Write a guide.",
            deliverables: (1...24).map { "Item \($0) " + String(repeating: "z", count: 10_000) }, workerType: "document"))
        let messages = NativeDocumentWorker.messages(payload: payload, checkpoint: NativeDocumentCheckpoint(), identity: NativeWorkerIdentity(assistantName: nil, ownerName: nil))
        try require(messages.last?.content.contains("Item 24 ") == true && messages.last?.content.contains("Write a guide.") == true,
                    "A prompt larger than the old serialization cap keeps every input instead of falling back to the brief")
    }

    private static func documentQuotedMaterial() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter) { job in ResourcePolicyFixture.document(job) }
        try await harness.start()
        let reference = try await harness.submitDocument(title: "Quotes", brief: "Write about the quotes.",
                                                         inputs: ["Input 1: " + String(repeating: "\"", count: 60_000)])
        try require(try await harness.wait(seconds: 40) { try harness.state(reference) == .completed },
                    "Material full of quotes is condensed by its size as sent and completes: \(String(describing: try harness.state(reference)))")
        try require(await counter.count(prefix: "generate:condense") > 1, "It was split into several parts")
        await harness.stop()
    }

    private static func documentBulletsCondensed() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let bullets = (1...10).map { "- Point \($0)" }.joined(separator: "\n")
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter, profileContextTokens: 6_000) { job in
            if job.phase.hasPrefix("condense") { return ResourcePolicyFixture.document(job) }
            return ResourcePolicyFixture.text(bullets)
        }
        try await harness.start()
        let reference = try await harness.submitDocument(title: "Ten points", brief: "Write exactly ten bullets about the beds.", inputs: ResourcePolicyFixture.inputs)
        try require(try await harness.wait(seconds: 40) { try harness.state(reference) == .completed },
                    "A brief asking for exact bullets with long inputs is condensed first and completes: \(String(describing: try harness.state(reference)))")
        try require(await counter.count(prefix: "generate:condense") > 0, "The inputs were condensed before the list was written")
        await harness.stop()
    }

    private static func documentRetryAfterStuck() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let release = NativeTaskEngineCounter()
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter, profileContextTokens: 6_000) { job in
            if job.phase.hasPrefix("condense"), await release.count("retry") == 0 {
                let allowance = NativeResourcePolicy(contextTokens: 6_000, outputTokens: nil, reasoning: false).replyCharacters
                return ResourcePolicyFixture.text(String(repeating: "\"", count: allowance))
            }
            return ResourcePolicyFixture.document(job)
        }
        try await harness.start()
        let reference = try await harness.submitDocument(title: "Raised beds", brief: "Write a guide to the raised beds.",
                                                         inputs: Array(ResourcePolicyFixture.inputs.prefix(10)))
        try require(try await harness.wait(seconds: 40) { try harness.state(reference) == .needsDecision }, "Condensing that doesn't shrink pauses")
        let paused = try repository.taskProjection(id: reference.id)!.snapshot!
        try require(paused.decision?.prompt == NativeDocumentWorker.condenseStuckMessage, "The pause says what happened and what Retry does")
        let before = await counter.count(prefix: "generate:condense")
        await release.bump("retry")
        await harness.tracker.retry(reference.id)
        try require(try await harness.wait(seconds: 40) { try harness.state(reference) == .completed }, "Retry condenses in smaller parts and finishes")
        try require(await counter.count(prefix: "generate:condense") > before, "Retry made new condensing requests")
        await harness.stop()
    }

    private static func researchLongQuestion() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let recorder = NativeTaskJobRecorder()
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter) { job in
            await recorder.record(job)
            let text = job.messages.map(\.content).joined(separator: "\n")
            let numbers = Set(ResourcePolicyFixture.found("\\[[0-9]+\\]", in: text)).sorted()
            if job.phase.hasPrefix("condense") { return .text("Which reading rooms are quiet?") }
            if job.phase == "plan" { return .text("{\"subquestions\":[\"Which rooms\"]}") }
            if job.phase == "review" { return .text("{}") }
            return .text("Summary. " + numbers.map { "A finding \($0)." }.joined(separator: " "))
        }
        try await harness.start()
        let reference = try await harness.submit("Compare quiet reading rooms. " + String(repeating: "Consider every branch and its hours. ", count: 5_000))
        try require(try await harness.wait(seconds: 40) { try harness.state(reference) == .completed },
                    "A research question longer than the prompt room is condensed first and completes: \(String(describing: try harness.state(reference)))")
        let plan = await recorder.all().first { $0.phase == "plan" }
        let planned = plan?.messages.last?.content ?? ""
        try require(planned.hasPrefix("Which reading rooms are quiet?") && planned.count < 1_000, "Planning uses the condensed question, not the whole one")
        await harness.stop()
    }

    private static func documentPlanTooLarge() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let recorder = NativeTaskJobRecorder()
        let many = NativeResourcePolicy.sectionsThatFit + 4
        let sections = (1...many).map { ["heading": "Part \($0)", "instructions": "Cover part \($0)"] }
        let plan = String(decoding: try JSONSerialization.data(withJSONObject: ["sections": sections]), as: UTF8.self)
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter) { job in
            await recorder.record(job)
            return job.phase == "outline" ? .text(plan) : ResourcePolicyFixture.text("Written.")
        }
        try await harness.start()
        let reference = try await harness.submitDocument(title: "Everything", brief: "Write about everything.", inputs: [])
        try require(try await harness.wait(seconds: 20) { try harness.state(reference) == .failed }, "A plan larger than one document can hold stops at the plan")
        let outlinePrompt = await recorder.all().first { $0.phase == "outline" }?.messages.first?.content ?? ""
        try require(outlinePrompt.contains("at most \(NativeResourcePolicy.sectionsThatFit)"), "The plan is asked to fit what one document can hold")
        try require(await counter.count(prefix: "generate:draft") == 0, "No section is written for a plan that can't be saved")
        let snapshot = try repository.taskProjection(id: reference.id)!.snapshot!
        let card = try NativeTaskProjection.display(reference: try repository.taskReference(id: reference.id)!, snapshot: snapshot).card
        let expected = NativeResourcePolicy.planTooLarge(needed: many * NativeResourcePolicy.sectionShare,
                                                         room: NativeResourcePolicy.documentCharacters)
        try require(card.status == .failed && card.milestone == expected && expected.hasSuffix("Ask for it as two documents."),
                    "The card says how much the plan needs, what one document holds and what to do: \(card.milestone)")
        await harness.stop()
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
            "maximumPlanAttempts", "maximumRequestedBullets", "wireEncodingMultiple", "jobBytes", "jobFrameBytes", "sectionFrameCharacters", "roundingStep", "batchJoinBytes", "minimumPartBytes", "contextLookupSeconds",
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
        try require(Policy.tooLarge(300_001, limit: Policy.documentCharacters, document: true)
                    == "The finished document is 300,001 characters, and Tandem can save up to about 240,000 in one document. Ask for it as two documents."
                    && Policy.tooLarge(300_001, limit: 251_234, document: false)
                    == "The finished report is 300,001 characters, and Tandem can save up to about 250,000 in one report. Ask for a narrower report.",
                    "A result too large to save says both numbers and what to do next")
        try require(Policy.documentCharacters == 240_000 && Policy.planTooLarge(needed: 288_720, room: Policy.documentCharacters)
                    == "This document would need about 290,000 characters, and Tandem can save up to about 240,000 in one document. Ask for it as two documents.",
                    "A plan too large for one document says both numbers before anything is written")
        try require(NativeTaskProjection.unrevisedLine(1) == "One section wasn't revised."
                    && NativeTaskProjection.unrevisedLine(3) == "3 sections weren't revised."
                    && NativeTaskProjection.condensingLine == "Condensing the material so it fits."
                    && NativeDocumentWorker.condenseStuckMessage == "The material for this document is still too long to work with after condensing it. Try this step again to condense it in smaller parts?"
                    && NativeResearchWorker.condenseStuckMessage == "The material for this research is still too long to work with after condensing it. Try this step again to condense it in smaller parts?"
                    && NativeDocumentWorker.progressTooLargeMessage == "This document grew larger than Tandem can hold while writing it. Ask for it as two documents.",
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
        let long = String(repeating: "\"", count: 2_950)
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
