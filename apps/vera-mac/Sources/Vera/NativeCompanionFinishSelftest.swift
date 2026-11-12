import Foundation
import GRDB

final class NativeCompanionFinishModel: @unchecked Sendable {
    struct Seen: Equatable {
        let attempt: String
        let choice: String
        let tools: Bool
    }

    private let lock = NSLock()
    private var seen: [Seen] = []
    private var failures: [Error] = []
    let script: @Sendable ([NativeTaskGenerationMessage]) -> NativeTaskGenerationCompletion
    let closing: NativeTaskGenerationCompletion

    init(closing: NativeTaskGenerationCompletion = .text("The central reading room has forty seats."),
         _ script: @escaping @Sendable ([NativeTaskGenerationMessage]) -> NativeTaskGenerationCompletion) {
        self.closing = closing
        self.script = script
    }

    static func looping(callsPerRound: Int = 1) -> NativeCompanionFinishModel {
        NativeCompanionFinishModel { messages in
            let calls = (0..<callsPerRound).map {
                NativeTaskGenerationToolCall(id: "call-\(messages.count)-\($0)", name: NativeCompanionFinishRig.lookupName, arguments: "{}")
            }
            return NativeTaskGenerationCompletion(content: "", toolCalls: calls, finishReason: "tool_calls")
        }
    }

    var calls: [Seen] { lock.withLock { seen } }

    func failClosing(_ error: Error) { lock.withLock { failures.append(error) } }

    func complete(_ attempt: String, _ messages: [NativeTaskGenerationMessage], _ tools: [NativeTaskGenerationTool]?,
                  _ choice: String) throws -> NativeTaskGenerationCompletion {
        if messages.first?.content == NativeCompanionShape.classifierPrompt { return .text("{\"keep\": false}") }
        let closing = attempt.hasSuffix("-finish")
        let failure: Error? = lock.withLock {
            seen.append(Seen(attempt: attempt, choice: choice, tools: tools != nil))
            guard closing, !failures.isEmpty else { return nil }
            return failures.removeFirst()
        }
        if let failure { throw failure }
        if closing { return self.closing }
        return script(messages)
    }
}

struct NativeCompanionFinishRig {
    static let tightRoom = 16384 + 8192

    let repository: LocalChatRepository
    let store: NativeTaskStore
    let ledger: NativeEffectLedgerStore
    let model: NativeCompanionFinishModel
    let tools: [NativeToolDefinition]
    var environment: NativeCompanionWorkerEnvironment

    init(url: URL? = nil, room: Int = NativeCompanionWorkerBudget.standard.transcriptBytes, tools custom: [NativeToolDefinition]? = nil,
         model: NativeCompanionFinishModel) throws {
        repository = try url.map { try LocalChatRepository(url: $0) } ?? LocalChatRepository(inMemory: true)
        store = NativeTaskStore(database: repository.database)
        let clock = NativeEffectTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        ledger = NativeEffectLedgerStore(database: repository.database, now: { clock.now })
        self.model = model
        let rules = NativeRuleSource()
        rules.setGlobal(NativeRules(choices: [:]))
        let grants = NativeFolderGrantSource()
        let tools = custom ?? Self.libraryTools()
        self.tools = tools
        environment = NativeCompanionWorkerEnvironment(
            context: { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: "companion-thread-1", tools: tools) },
            authority: { conversation, request in
                NativeCompanionWorkerAuthority(resolver: rules.resolver(for: conversation, requestText: request), grantsRevision: grants.revision)
            },
            ledger: ledger, tasks: store, now: { clock.now }, pause: { _ in }, defaultToolSeconds: 2)
        environment.budget = NativeCompanionWorkerBudget(transcriptBytes: room)
    }

    func create(_ assignment: String = "Check the reading room hours at the central library", mode: String = "manual",
                scheduleID: String? = nil) throws -> String {
        let dot = try NativeCompanionTaskPayload(assignment: assignment, mode: mode, scheduleID: scheduleID)
        let payload = NativeResearchTaskPayload(request: try NativeResearchTaskRequest(dot: dot))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try store.create(workerType: "companion", payload: try NativeTaskStore.canonical(try encoder.encode(payload)),
                                idempotencyKey: UUID().uuidString).id
    }

    func run(_ claimed: NativeTaskRecord) async throws -> NativeTaskStepResult {
        let model = self.model
        return try await NativeCompanionWorker.step(claimed, environment: environment) { _, attempt, _, messages, tools, choice in
            try model.complete(attempt, messages, tools, choice)
        }
    }

    @discardableResult
    func step() async throws -> NativeTaskRecord {
        guard let claimed = try store.claim(workerTypes: ["companion"]) else { throw NativeTaskFixture.Failure.assertion("A companion task is queued") }
        return try store.commitStep(claimed.id, generation: claimed.generation, step: try await run(claimed))
    }

    func settle(_ limit: Int = 400) async throws -> (record: NativeTaskRecord, states: [NativeTaskState]) {
        var states: [NativeTaskState] = []
        for _ in 0..<limit {
            let record = try await step()
            states.append(record.state)
            if record.state != .queued { return (record, states) }
        }
        throw NativeTaskFixture.Failure.assertion("The companion work settles")
    }

    func seed(_ id: String, checkpoint: Data, decision: [String: Any]? = nil) throws -> NativeTaskRecord {
        guard let claimed = try store.claim(workerTypes: ["companion"]) else { throw NativeTaskFixture.Failure.assertion("Claimed") }
        return try store.commitStep(id, generation: claimed.generation, step: NativeTaskStepResult(
            state: decision == nil ? .queued : .needsDecision, checkpoint: checkpoint, event: "progress",
            decision: try decision.map { try NativeTaskStore.canonical($0) }))
    }

    @discardableResult
    func reply(_ record: NativeTaskRecord, _ action: String, key: String = UUID().uuidString) throws -> NativeTaskRecord {
        guard let id = record.decisionID() else { throw NativeTaskFixture.Failure.assertion("The question has an id") }
        return try store.respond(record.id, decisionID: id, replyKey: key, reply: try NativeTaskStore.canonical(["action": action]))
    }

    func checkpoint(_ record: NativeTaskRecord) throws -> NativeCompanionCheckpoint {
        try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: record.checkpoint)
    }

    func report(_ record: NativeTaskRecord) throws -> [String: Any] {
        guard let raw = record.result else { throw NativeTaskFixture.Failure.assertion("The companion work has a result") }
        return try NativeTaskStore.object(raw)
    }

    func asked(_ id: String) throws -> Int {
        try repository.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_engine_task_events WHERE task_id = ? AND state = 'needs_decision'", arguments: [id]) ?? 0
        }
    }

    func display(_ record: NativeTaskRecord, assignment: String) throws -> (card: NativeTaskCardPresentation, artifact: NativeResearchArtifact?) {
        let request = try NativeResearchTaskRequest(dot: NativeCompanionTaskPayload(assignment: assignment, mode: "manual"))
        var reference = try repository.prepareTaskReference(origin: NativeTaskFixture.origin(repository),
            engine: NativeTaskEngineIdentity(URL(string: "https://engine.example.org")!), request: request, profile: nil)
        reference.remoteTaskID = record.id
        let snapshot = try NativeTaskSnapshot(id: record.id, workerType: record.workerType,
            payload: JSONDecoder().decode(NativeResearchTaskPayload.self, from: record.payload), state: record.state,
            checkpoint: JSONDecoder().decode(NativeTaskCheckpoint.self, from: record.checkpoint),
            result: try record.result.map { try JSONDecoder().decode(NativeResearchTaskResult.self, from: $0) },
            decision: try record.decision.map { try JSONDecoder().decode(NativeTaskDecision.self, from: $0) },
            cancelRequested: false, generation: record.generation, updatedAt: record.updatedAt)
        return try NativeTaskProjection.display(reference: reference, snapshot: snapshot)
    }

    static func answeredOnce(_ checkpoint: NativeCompanionCheckpoint) -> Bool {
        let issued = checkpoint.transcript.flatMap { $0.toolCalls ?? [] }.map(\.id)
        let answers = checkpoint.transcript.compactMap(\.toolCallID)
        return Set(issued).count == issued.count && answers.sorted() == issued.sorted()
    }
}

@MainActor
extension SelfTest {
    static func runNativeCompanionFinish() async throws {
        try await companionLongWork()
        try await companionFinishInterrupted()
        try await companionFinishAutomaticRetry()
        try await companionFinishOutstanding()
        try await companionFinishTerminal()
        try await companionFinishScalarLimit()
        try await companionFinishRelaunch()
        try await companionFinishStopped()
        try await companionFinishOldCheckpoint()
        try await companionSourcesRead()
        try await companionFinishSavedPages()
        try await companionFinishFallbackKeepsPages()
        try await companionLongWorkThroughEngine()
        try await companionOldQuestionCarriesOn()
        try await companionManyCallsInOneReply()
        try await companionEndingSavedFirst()
        try await companionResultFitsItsLimit()
        try await companionOldQuestionSaveFails()
        try companionAppendKeepsSuffix()
        try await companionNoticesKeptTogether()
        try companionNoticesSurviveShrinking()
        try companionStopDetailsFit()
        try companionUnlistedPagesCounted()
        print("  companion finish OK (long work never asks or ends early, running out of room survives a missing model, automatic and explicit retries, a relaunch and a stop, closing write-up only, unanswered calls answered once, terminal failure keeps saved sources, older saved work carries on, pages read or only found, a redirect saves the page that was read, unfinished write-ups cite only listed pages, the closing write-up is used when it fits, a write-up that can't run or comes back unusable keeps the pages, over a hundred steps through the engine, a saved old question carries on by itself, more than 64 calls in one reply, the ending is saved before the closing request, the saved result fits its limit, a failed answer save is tried again, an appended line survives a long paragraph, both notices survive a long answer and a shrinking result, stop details fit, unlisted pages are counted)")
    }

    private static func companionClosingOnly(_ rig: NativeCompanionFinishRig, after mark: Int) -> Bool {
        let later = rig.model.calls.dropFirst(mark)
        return !later.isEmpty && later.allSatisfy { $0.choice == "none" && $0.attempt.hasSuffix("-finish") }
    }

    private static func companionClosingOnlyAfterFirst(_ rig: NativeCompanionFinishRig) -> Bool {
        guard let first = rig.model.calls.firstIndex(where: { $0.attempt.hasSuffix("-finish") }) else { return false }
        return companionClosingOnly(rig, after: first)
    }

    private static func companionLongWork() async throws {
        let require = NativeTaskFixture.require
        for (mode, schedule) in [("manual", nil), ("scheduled", "garden-schedule")] as [(String, String?)] {
            let model = NativeCompanionFinishModel { messages in
                let rounds = messages.filter { $0.role == "assistant" && $0.toolCalls != nil }.count
                if rounds >= 100 { return .text("All the hour checks are done.") }
                let calls = (0..<3).map { NativeTaskGenerationToolCall(id: "call-\(rounds)-\($0)", name: NativeCompanionFinishRig.lookupName, arguments: "{}") }
                return NativeTaskGenerationCompletion(content: "", toolCalls: calls, finishReason: "tool_calls")
            }
            let rig = try NativeCompanionFinishRig(model: model)
            let id = try rig.create(mode: mode, scheduleID: schedule)
            let settled = try await rig.settle()
            let saved = try rig.checkpoint(settled.record)
            let report = try rig.report(settled.record)["report"] as? String ?? ""
            try require(settled.record.state == .completed && !settled.states.contains(.needsDecision) && settled.record.decision == nil
                        && (try rig.asked(id)) == 0,
                        "The \(mode) work runs to its answer without a question: \(settled.states.count) steps")
            try require(saved.rounds == 101 && saved.calls == 300 && saved.finishing == nil,
                        "The \(mode) work runs far past the old limits: rounds \(saved.rounds) calls \(saved.calls)")
            try require(report == "All the hour checks are done." && !rig.model.calls.contains { $0.attempt.hasSuffix("-finish") },
                        "The \(mode) work ends with its own answer, never a forced write-up: \(report)")
            try require(NativeCompanionFinishRig.answeredOnce(saved), "Every call in the \(mode) work is answered once")
        }
    }

    private static func companionFinishInterrupted() async throws {
        let require = NativeTaskFixture.require
        let rig = try NativeCompanionFinishRig(room: NativeCompanionFinishRig.tightRoom, model: .looping())
        let id = try rig.create()
        rig.model.failClosing(NativeTaskExecutorUnavailable())
        let blocked = try await rig.settle()
        let saved = try rig.checkpoint(blocked.record)
        try require(blocked.record.state == .blocked && saved.finishing == true && saved.rounds > 1 && !blocked.states.contains(.needsDecision),
                    "Running out of room starts the closing write-up, which waits for the model: \(blocked.record.state) rounds \(saved.rounds)")
        let mark = rig.model.calls.count
        _ = try rig.store.resume(id)
        let settled = try await rig.settle()
        try require(settled.record.state == .completed && !settled.states.contains(.needsDecision), "The resumed work completes: \(settled.states)")
        try require(companionClosingOnly(rig, after: mark), "After resuming only the closing write-up runs: \(rig.model.calls.dropFirst(mark))")
        let report = try rig.report(settled.record)["report"] as? String ?? ""
        try require(report == NativeCompanionWorker.outOfRoomLead + "\n\nThe central reading room has forty seats.",
                    "The closing write-up says the work ran out of room: \(report)")
        try require(NativeCompanionFinishRig.answeredOnce(try rig.checkpoint(settled.record)), "Every call is answered exactly once")
        try require(try rig.asked(id) == 0, "Running out of room never asks a question")
    }

    private static func companionFinishAutomaticRetry() async throws {
        let require = NativeTaskFixture.require
        let rig = try NativeCompanionFinishRig(room: NativeCompanionFinishRig.tightRoom, model: .looping())
        _ = try rig.create()
        rig.model.failClosing(NativeTaskGenerationFailure(code: "request_timeout"))
        let settled = try await rig.settle()
        try require(!settled.states.contains(.needsDecision) && settled.record.state == .completed,
                    "A closing write-up that retries on its own still finishes without asking: \(settled.states)")
        try require(companionClosingOnlyAfterFirst(rig) && rig.model.calls.filter { $0.attempt.hasSuffix("-finish") }.count == 2,
                    "The automatic retry asks only for the closing write-up")

        let unsafe = try NativeCompanionFinishRig(room: NativeCompanionFinishRig.tightRoom, model: .looping())
        _ = try unsafe.create()
        unsafe.model.failClosing(NativeTaskGenerationFailure(code: "provider_auth"))
        let retry = try await unsafe.settle()
        try require(retry.record.state == .needsDecision && (try unsafe.decision(retry.record)) == ["retry"]
                    && (try unsafe.checkpoint(retry.record)).finishing == true,
                    "A closing write-up that is unsafe to repeat asks only to retry")
        let mark = unsafe.model.calls.count
        try unsafe.reply(retry.record, "retry")
        let done = try await unsafe.settle()
        try require(done.record.state == .completed && !done.states.contains(.needsDecision),
                    "After Retry the work goes back to finishing: \(done.states)")
        try require(companionClosingOnly(unsafe, after: mark), "Retrying asks only for the closing write-up: \(unsafe.model.calls.dropFirst(mark))")
    }

    private static func companionFinishOutstanding() async throws {
        let require = NativeTaskFixture.require
        let rig = try NativeCompanionFinishRig(model: .looping())
        let id = try rig.create()
        var checkpoint = NativeCompanionCheckpoint()
        checkpoint.threadID = "companion-thread-1"
        checkpoint.rounds = 5
        checkpoint.calls = 13
        checkpoint.finishing = true
        let calls = (0..<3).map { NativeTaskGenerationToolCall(id: "left-\($0)", name: NativeCompanionFinishRig.lookupName, arguments: "{}") }
        checkpoint.transcript = [NativeTaskGenerationMessage(role: "assistant", content: "", toolCalls: calls),
                                 NativeTaskGenerationMessage(role: "tool", content: "{\"seats\":40}", toolCallID: "left-0")]
        _ = try rig.seed(id, checkpoint: try checkpoint.encoded())
        let settled = try await rig.settle()
        try require(settled.record.state == .completed && rig.model.calls.allSatisfy { $0.attempt.hasSuffix("-finish") },
                    "Finishing work only asks for the closing write-up")
        let final = try rig.checkpoint(settled.record)
        let notRun = final.transcript.filter { $0.role == "tool" && $0.content.contains("this work is finishing with what it has") }
        try require(NativeCompanionFinishRig.answeredOnce(final) && notRun.count == 2, "Unanswered calls are answered once as not run")
    }
}

@MainActor
extension SelfTest {
    private static func companionFinishTerminal() async throws {
        let require = NativeTaskFixture.require
        let web = companionWebTools().1
        let searching = NativeCompanionFinishModel { messages in
            NativeCompanionScriptedModel.call("web_search", "{\"query\":\"reading rooms\"}", id: "search-\(messages.count)")
        }
        let rig = try NativeCompanionFinishRig(room: NativeCompanionFinishRig.tightRoom, tools: web, model: searching)
        let id = try rig.create("Find the reading room hours at the public libraries")
        rig.model.failClosing(NativeTaskGenerationFailure(code: "request_limit"))
        let ended = try await rig.settle()
        let result = try rig.report(ended.record)
        let report = result["report"] as? String ?? ""
        let sources = result["sources"] as? [[String: Any]] ?? []
        try require(ended.record.state == .completed && !ended.states.contains(.needsDecision) && (try rig.asked(id)) == 0,
                    "A closing write-up that cannot run ends the work without asking: \(ended.states)")
        try require(report.hasPrefix("I couldn't finish the write-up. Here's what I'd saved.") && report.contains("Rain totals [1]"),
                    "The result says the write-up could not be finished and lists what was saved: \(report)")
        try require(report.contains("Found in a search, not read:") && !report.contains("Pages read:") && !report.contains("Pages found:"),
                    "Pages that only turned up in a search are never listed as read: \(report)")
        try require(sources.compactMap { ($0["n"] as? NSNumber)?.intValue } == [1, 2, 3]
                    && sources.compactMap { $0["url"] as? String } == ["https://weather.example/rain", "https://gauge.example/levels", "https://third.example/"],
                    "Every saved source is kept: \(sources)")
        try require(!report.contains(CompanionSavedText.marker) && !report.contains("\u{2014}"), "The statement is plain")

        let empty = try NativeCompanionFinishRig(room: NativeCompanionFinishRig.tightRoom, model: .looping())
        _ = try empty.create()
        empty.model.failClosing(NativeTaskGenerationFailure(code: "input_limit"))
        let nothing = try await empty.settle()
        let nothingReport = try empty.report(nothing.record)["report"] as? String ?? ""
        try require(nothing.record.state == .completed
                    && nothingReport == "I couldn't finish the write-up. I hadn't read any pages yet.",
                    "With only other tool results the result says no pages were read: \(nothingReport)")
        try require(!nothingReport.lowercased().contains("nothing"), "The result never claims nothing was found")
    }

    private static func companionFinishScalarLimit() async throws {
        let require = NativeTaskFixture.require
        let lead = "I couldn't finish the write-up. Here's what I'd saved."
        let title = "a" + String(repeating: "\u{0301}", count: 12000)
        let definition = NativeCompanionFinishRig.libraryTools()[0]
        let described = NativeCompanionWorker.describe(definition, ["title": .string(title)])
        let source = NativeTaskSource(n: 12, title: "Reading room hours", url: "https://library.example.org/hours", read: true)
        for variant in ["completed", "undone", "not run", "both"] {
            let rig = try NativeCompanionFinishRig(model: .looping())
            let assignment = "Check the reading room hours at the central library"
            let id = try rig.create(assignment)
            var checkpoint = NativeCompanionCheckpoint()
            checkpoint.threadID = "companion-thread-1"
            checkpoint.finishing = true
            checkpoint.sources = [source]
            for _ in 0..<4 { checkpoint.effects.append(NativeCompanionEffectNote(title: described, outcome: "done")) }
            let longLine = "a" + String(repeating: "\u{0301}", count: variant == "both" ? 16000 : 30000)
            if variant == "undone" || variant == "both" {
                checkpoint.effects.append(NativeCompanionEffectNote(title: longLine, outcome: NativeReadOnlyRun.outcome))
            }
            if variant == "not run" || variant == "both" {
                checkpoint.effects.append(NativeCompanionEffectNote(title: longLine, outcome: "not done", reason: "The room was closed."))
            }
            try require((NativeCompanionWorker.earlierLine(checkpoint) ?? "").unicodeScalars.count <= NativeTaskStop.stepScalars / 4,
                        "The completed steps line is cut to its limit in scalars")
            _ = try rig.seed(id, checkpoint: try checkpoint.encoded())
            rig.model.failClosing(NativeTaskGenerationFailure(code: "request_limit"))
            let ended = try await rig.settle()
            let report = try rig.report(ended.record)["report"] as? String ?? ""
            try require(ended.record.state == .completed && companionClosingOnly(rig, after: 0),
                        "The \(variant) finish saves a completed result after the closing request fails")
            let display = try rig.display(ended.record, assignment: assignment)
            try require(display.card.status == .completed && (display.card.answer ?? display.artifact?.report) == report,
                        "The completed projection accepts the \(variant) saved report")
            try require(report.unicodeScalars.count <= NativeCompanionWorker.reportScalars && report.hasPrefix(lead),
                        "The \(variant) report fits in scalars and keeps the opening statement")
        }
        let oversized = NativeCompanionWorker.appendingReport(String(repeating: title, count: 4), to: lead + "\n\nReading room hours [12]")
        try require(oversized.hasPrefix(lead) && oversized.unicodeScalars.count <= NativeCompanionWorker.reportScalars,
                    "An appended line larger than the limit still keeps the opening statement")
        var checkpoint = NativeCompanionCheckpoint()
        checkpoint.sources = [source]
        for tail in ["[12]", "[12, 13]"] {
            let prefix = lead + "\n\n" + String(repeating: "a", count: NativeCompanionWorker.reportScalars - lead.unicodeScalars.count - 4)
            let step = try NativeCompanionWorker.report(checkpoint, assignment: "Check the reading room hours", text: prefix + tail)
            let result = try NativeTaskStore.object(step.result!)
            let report = result["report"] as? String ?? ""
            try require(report == prefix && (result["sources"] as? [[String: Any]])?.isEmpty == true,
                        "Truncating a citation removes its entire marker")
            let suffix = "The room was closed."
            let shorter = String(String.UnicodeScalarView(prefix.unicodeScalars.dropLast(suffix.unicodeScalars.count + 2)))
            let appended = NativeCompanionWorker.appendingReport(suffix, to: shorter + tail)
            try require(appended == shorter + "\n\n" + suffix,
                        "Reserving room for an appended line removes a cut citation marker")
        }
        let complete = try NativeCompanionWorker.report(checkpoint, assignment: "Check the reading room hours", text: lead + " [12]")
        let cited = try NativeTaskStore.object(complete.result!)["sources"] as? [[String: Any]] ?? []
        try require(cited.count == 1 && (cited.first?["n"] as? NSNumber)?.intValue == 12,
                    "An intact citation keeps its matching saved source")
    }

    private static func companionFinishRelaunch() async throws {
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func completions(_ rig: NativeCompanionFinishRig, _ id: String) throws -> Int {
            try rig.repository.database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_engine_task_events WHERE task_id = ? AND state = 'completed'", arguments: [id]) ?? 0
            }
        }
        for variant in ["blocked", "interrupted"] {
            let url = directory.appendingPathComponent("\(variant).sqlite")
            let before = try NativeCompanionFinishRig(url: url, room: NativeCompanionFinishRig.tightRoom, model: .looping())
            let id = try before.create()
            before.model.failClosing(NativeTaskExecutorUnavailable())
            let blocked = try await before.settle()
            try require(blocked.record.state == .blocked && (try before.checkpoint(blocked.record)).finishing == true,
                        "The blocked save keeps the finishing mark")
            if variant == "interrupted" {
                _ = try before.store.resume(id)
                _ = try before.store.claim(workerTypes: ["companion"])
            }
            let after = try NativeCompanionFinishRig(url: url, room: NativeCompanionFinishRig.tightRoom, model: .looping())
            try after.store.recover()
            if try after.store.get(id).state == .blocked { _ = try after.store.resume(id) }
            let settled = try await after.settle()
            try require(settled.record.state == .completed && !settled.states.contains(.needsDecision),
                        "After a relaunch the \(variant) work finishes without asking: \(settled.states)")
            try require(after.model.calls.allSatisfy { $0.choice == "none" }, "After a relaunch only the closing write-up runs")
            try require(try after.store.claim(workerTypes: ["companion"]) == nil, "Nothing is left to run")
            try require(try completions(after, id) == 1 && (try after.asked(id)) == 0, "One result and no question")
        }
    }

    private static func companionFinishStopped() async throws {
        let require = NativeTaskFixture.require
        let rig = try NativeCompanionFinishRig(room: NativeCompanionFinishRig.tightRoom, model: .looping())
        let id = try rig.create()
        rig.model.failClosing(NativeTaskExecutorUnavailable())
        let blocked = try await rig.settle()
        try require(blocked.record.state == .blocked, "Finishing waits for the model")
        let canceled = try rig.store.cancel(id)
        try require(canceled.state == .canceled && canceled.result == nil, "Stopping while finishing ends the work")
        try require(try rig.store.claim(workerTypes: ["companion"]) == nil && (try? rig.store.resume(id)) == nil,
                    "A stopped finish cannot run again")
        try require(try rig.store.get(id).result == nil, "A stopped finish publishes nothing")

        let running = try NativeCompanionFinishRig(room: NativeCompanionFinishRig.tightRoom, model: .looping())
        let runningID = try running.create()
        running.model.failClosing(NativeTaskExecutorUnavailable())
        _ = try await running.settle()
        _ = try running.store.resume(runningID)
        guard let claimed = try running.store.claim(workerTypes: ["companion"]) else { throw NativeTaskFixture.Failure.assertion("Claimed") }
        _ = try running.store.cancel(runningID)
        do {
            let step = try await running.run(claimed)
            _ = try running.store.commitStep(runningID, generation: claimed.generation, step: step)
        } catch is CancellationError {}
        try running.store.recover()
        let stopped = try running.store.get(runningID)
        try require(stopped.state == .canceled && stopped.result == nil, "A stop during the closing write-up publishes nothing: \(stopped.state)")
    }

    private static func companionFinishOldCheckpoint() async throws {
        let require = NativeTaskFixture.require
        let model = NativeCompanionFinishModel { messages in
            NativeCompanionScriptedModel.toolResults(messages).count >= 3
                ? .text("The central reading room has forty seats.")
                : NativeCompanionScriptedModel.call(NativeCompanionFinishRig.lookupName, "{}", id: "new-\(messages.count)")
        }
        let old = Data(#"{"attempt":"0ldattempt","calls":4,"effects":[],"pending":{"kind":"cap"},"rounds":4,"segment_calls":4,"segment_rounds":4,"sources":[{"n":1,"title":"Opening hours","url":"https://hours.example.org/rooms"}],"thread_id":"companion-thread-1","transcript":[{"content":"","role":"assistant","tool_calls":[{"arguments":"{}","id":"old-1","name":"room_hours"}]},{"content":"{\"seats\":40}","role":"tool","tool_call_id":"old-1"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: old)
        try require(decoded.finishing == nil && decoded.pending?.kind == "cap" && decoded.rounds == 4 && decoded.sources?.first?.read == nil,
                    "Older saved work reads with no finishing mark and its sources unread")
        let encoded = String(decoding: try decoded.encoded(), as: UTF8.self)
        try require(!encoded.contains("finishing") && !encoded.contains("segment")
                    && !String(decoding: try JSONEncoder().encode(decoded.sources ?? []), as: UTF8.self).contains("read"),
                    "Older saved work drops the old counters and encodes as before")
        for answer in ["finish", "continue"] {
            let rig = try NativeCompanionFinishRig(model: model)
            let id = try rig.create()
            let waiting = try rig.seed(id, checkpoint: old, decision: ["prompt": "Keep going, or finish with what it has?", "choices": ["continue", "finish"]])
            try rig.reply(waiting, answer)
            let done = try await rig.settle()
            let report = try rig.report(done.record)["report"] as? String ?? ""
            try require(done.record.state == .completed && !done.states.contains(.needsDecision) && (try rig.asked(id)) == 1,
                        "Older saved work waiting on the old question completes after \(answer) without asking again")
            try require(rig.model.calls.contains { $0.choice == "auto" } && !rig.model.calls.contains { $0.attempt.hasSuffix("-finish") }
                        && report == "The central reading room has forty seats.",
                        "Older saved work carries on with its tools after \(answer) and ends with its own answer: \(report)")
        }
    }

    private static func companionSourcesRead() async throws {
        let require = NativeTaskFixture.require
        let run = try await companionWebRun("The central room opens at nine [1]. The branch closes at five [2].")
        let saved = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: run.record.checkpoint)
        try require(saved.sources?.map(\.n) == [1, 2, 3] && saved.sources?.map(\.read) == [false, true, false],
                    "A page fetched after search is read and the others were only found: \(saved.sources ?? [])")
        let shown = run.result["sources"] as? [[String: Any]] ?? []
        try require(shown.allSatisfy { Set($0.keys) == ["n", "title", "url"] }, "The result's sources are unchanged")
        let tools = companionWebTools().1
        guard let fetcher = tools.first(where: { $0.id == NativeWebTools.fetchToolID }),
              let searcher = tools.first(where: { $0.id == NativeWebTools.searchToolID }) else {
            throw NativeTaskFixture.Failure.assertion("The fake web tools include search and a page reader")
        }
        var direct = NativeCompanionCheckpoint()
        _ = direct.numbered(.object(["url": .string("https://central.example.org/reading-room"), "title": .string("Central reading room"),
                                     "text": .string("Open nine to five.")]),
                            definition: fetcher, requested: "https://central.example.org/reading-room")
        let found: NativeJSONValue = .object(["results": .array([
            .object(["url": .string("https://central.example.org/reading-room"), "title": .string("Reading rooms")]),
            .object(["url": .string("https://hours.example.org/reading-rooms"), "title": .string("Opening hours")]),
        ])])
        _ = direct.numbered(found, definition: searcher)
        try require(direct.sources?.map(\.n) == [1, 2] && direct.sources?.map(\.read) == [true, false],
                    "A page fetched first stays read when it shows up in search, and search alone leaves a page unread")
        let reloaded = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: try direct.encoded())
        try require(reloaded.sources == direct.sources, "Whether a page was read survives a reload")
        let searchRun = try await companionWebRun("The central room opens at nine [1].", tools: [searcher])
        let searchOnly = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: searchRun.record.checkpoint)
        try require(searchOnly.sources?.isEmpty == false && searchOnly.sources?.allSatisfy { $0.read == false } == true,
                    "Search alone marks every page as found and not read")

        var moved = NativeCompanionCheckpoint()
        _ = moved.numbered(.object(["results": .array([
            .object(["url": .string("https://hours.example.org/rooms"), "title": .string("Reading room hours")]),
        ])]), definition: searcher)
        let landed = moved.numbered(.object(["url": .string("https://www.example.org/rooms-moved"), "title": .string("Moved page"),
                                             "text": .string("Open nine to five.")]),
                                    definition: fetcher, requested: "https://hours.example.org/rooms")
        guard case .object(let page) = landed, case .number(let landedNumber)? = page["n"] else {
            throw NativeTaskFixture.Failure.assertion("The moved page keeps a number")
        }
        try require(Int(landedNumber) == 1 && moved.sources == [NativeTaskSource(n: 1, title: "Moved page", url: "https://www.example.org/rooms-moved", read: true)]
                    && moved.aliases?["https://www.example.org/rooms-moved"] == 1 && moved.aliases?["https://hours.example.org/rooms"] == 1,
                    "A page that lands somewhere else keeps its number and saves the page that was read: \(moved.sources ?? [])")
        try require(!(moved.sources ?? []).contains { $0.url == "https://hours.example.org/rooms" },
                    "No saved page claims the address that was asked for was read")
        var untitled = NativeCompanionCheckpoint()
        _ = untitled.numbered(.object(["results": .array([
            .object(["url": .string("https://hours.example.org/rooms"), "title": .string("Reading room hours")]),
        ])]), definition: searcher)
        _ = untitled.numbered(.object(["url": .string("https://www.example.org/rooms-moved"), "title": .string(""), "text": .string("Open.")]),
                              definition: fetcher, requested: "https://hours.example.org/rooms")
        try require(untitled.sources == [NativeTaskSource(n: 1, title: "Reading room hours", url: "https://www.example.org/rooms-moved", read: true)],
                    "A landed page with no title keeps the saved title: \(untitled.sources ?? [])")
        _ = moved.numbered(.object(["results": .array([
            .object(["url": .string("https://hours.example.org/rooms"), "title": .string("Reading room hours")]),
        ])]), definition: searcher)
        try require(moved.sources?.count == 1 && moved.sources?.first?.read == true,
                    "The address that was asked for still means the same page in a later search: \(moved.sources ?? [])")
        var same = NativeCompanionCheckpoint()
        _ = same.numbered(.object(["results": .array([
            .object(["url": .string("https://hours.example.org/rooms"), "title": .string("Reading room hours")]),
        ])]), definition: searcher)
        _ = same.numbered(.object(["url": .string("https://hours.example.org/rooms"), "title": .string("Hours page"),
                                   "text": .string("Open nine to five.")]),
                          definition: fetcher, requested: "https://hours.example.org/rooms")
        try require(same.sources == [NativeTaskSource(n: 1, title: "Reading room hours", url: "https://hours.example.org/rooms", read: true)],
                    "Fetching the same address marks the page found in a search as read: \(same.sources ?? [])")

        try require(NativeTaskSource(n: 1, title: "", url: "notes.txt").label == "Saved page"
                    && NativeTaskSource(n: 1, title: "Map room", url: "https://example.org/map").label == "Map room",
                    "A page with no title and no site reads as a saved page, and a real title is kept")
        let titled = NativeTaskSource(n: 1, title: "https://example.org/docs: A beginner guide", url: "https://guides.example.org/start")
        try require(titled.label == "https://example.org/docs: A beginner guide",
                    "A title that starts with an address but says more is kept: \(titled.label)")
        try require(NativeTaskSource(n: 1, title: " https://www.example.org/docs ", url: "https://guides.example.org/start").label == "guides.example.org"
                    && NativeTaskSource(n: 1, title: "https://www.example.org/docs", url: "notes.txt").label == "example.org",
                    "A title that is only an address still reads as the site name")
    }

    private static func companionFinishSavedPages() async throws {
        let require = NativeTaskFixture.require
        let long = "https://archive.example.org/" + String(repeating: "a", count: 1100)
        let sources: [[String: Any]] = [
            ["n": 1, "title": "Central reading room", "url": "https://central.example.org/reading-room", "read": true],
            ["n": 2, "title": "Archive scan", "url": long, "read": true],
            ["n": 3, "title": "https://www.example.org/hours", "url": "https://www.example.org/hours", "read": true],
            ["n": 4, "title": "Branch list", "url": "https://branches.example.org/", "read": false],
            ["n": 5, "title": "Opening hours", "url": "https://hours.example.org/reading-rooms"],
            ["n": 6, "title": "", "url": "https://seats.example.org/count"],
        ]
        let rig = try NativeCompanionFinishRig(model: .looping())
        let id = try rig.create()
        let checkpoint: [String: Any] = [
            "attempt": "savedpages", "calls": 4, "effects": [], "finishing": true, "rounds": 4, "segment_calls": 4,
            "segment_rounds": 4, "sources": sources, "thread_id": "companion-thread-1",
            "transcript": [["content": "", "role": "assistant", "tool_calls": [["arguments": "{}", "id": "saved-1", "name": NativeCompanionFinishRig.lookupName]]],
                           ["content": "{\"seats\":40}", "role": "tool", "tool_call_id": "saved-1"]],
        ]
        _ = try rig.seed(id, checkpoint: try NativeTaskStore.canonical(checkpoint))
        rig.model.failClosing(NativeTaskGenerationFailure(code: "request_limit"))
        let ended = try await rig.settle()
        let result = try rig.report(ended.record)
        let report = result["report"] as? String ?? ""
        let listed = Set((result["sources"] as? [[String: Any]] ?? []).compactMap { ($0["n"] as? NSNumber)?.intValue })
        let cited = Set(CitationResolver.scan(report, known: Set(1...6)).refs)
        try require(ended.record.state == .completed && !cited.isEmpty && cited.isSubset(of: listed) && !cited.contains(2),
                    "Every number in the unfinished write-up has a matching source: cited \(cited.sorted()) listed \(listed.sorted())\n\(report)")
        try require(report.contains("I saved 1 more page, but I can't list it here.") && !report.contains("Archive scan"),
                    "A page that can't be listed is counted, not cited: \(report)")
        try require(report.contains("Pages read:\n- Central reading room [1]\n- example.org [3]")
                    && report.contains("Found in a search, not read:\n- Branch list [4]")
                    && report.contains("Pages found:\n- Opening hours [5]\n- seats.example.org [6]"),
                    "Read, search-only and older pages each get their own list with readable names: \(report)")
        try require(!report.contains("http") && !report.lowercased().contains("nothing"), "No address is used as a name and nothing is overstated: \(report)")
        let named = (result["sources"] as? [[String: Any]] ?? []).reduce(into: [Int: String]()) { names, source in
            if let n = (source["n"] as? NSNumber)?.intValue { names[n] = source["title"] as? String }
        }
        let linked = (result["sources"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
        try require(named[3] == "example.org" && named[6] == "seats.example.org" && named[1] == "Central reading room"
                    && !named.values.contains { $0.contains("http") } && linked.contains("https://www.example.org/hours"),
                    "The saved result names each source readably and keeps where it goes: \(named)")
        let wide = "https://" + (0..<3).map { _ in String(repeating: "b", count: 63) }.joined(separator: ".") + ".example.org/hours"
        let untitled = NativeTaskSource(n: 1, title: "", url: wide, read: true)
        let shown = try NativeTaskProjection.displaySources([NativeTaskSource(n: 1, title: untitled.label, url: untitled.url)])
        try require(untitled.label.unicodeScalars.count == NativeTaskSource.labelScalars && shown.first?.title == untitled.label
                    && NativeTaskSource(n: 2, title: String(repeating: "t", count: 260), url: "https://example.org/a").label.unicodeScalars.count == NativeTaskSource.labelScalars,
                    "A very long site name is cut to what a finished result can show: \(untitled.label.unicodeScalars.count)")
    }

    private static func companionFinishFallbackKeepsPages() async throws {
        let moved = "https://moved.example/rain-totals"
        let require = NativeTaskFixture.require
        for variant in ["tight", "empty", "calls", "closing", "unusable"] {
            let (client, web) = companionWebTools()
            client.page("https://weather.example/rain", .init(body: "<html><head><title>Rain totals page</title></head><body><p>Two inches fell.</p></body></html>",
                                                              finalURL: moved))
            let closing: NativeTaskGenerationCompletion = variant == "calls"
                ? NativeCompanionScriptedModel.call(NativeCompanionFinishRig.lookupName, "{}", id: "closing-call")
                : .text(variant == "empty" ? "  " : "Two inches of rain fell [1].")
            let model = NativeCompanionFinishModel(closing: closing) { messages in
                guard NativeCompanionScriptedModel.toolResults(messages).isEmpty else { return .text("Done.") }
                let calls = [
                    NativeTaskGenerationToolCall(id: "search", name: "web_search", arguments: "{\"query\":\"rain\"}"),
                    NativeTaskGenerationToolCall(id: "read-rain", name: "fetch_page", arguments: "{\"url\":\"https://weather.example/rain\"}"),
                    NativeTaskGenerationToolCall(id: "read-gauge", name: "fetch_page", arguments: "{\"url\":\"https://gauge.example/levels\"}"),
                ] + (0..<7).map { NativeTaskGenerationToolCall(id: "hours-\($0)", name: NativeCompanionFinishRig.lookupName, arguments: "{}") }
                return NativeTaskGenerationCompletion(content: "", toolCalls: calls, finishReason: "tool_calls")
            }
            var rig = try NativeCompanionFinishRig(tools: web + NativeCompanionFinishRig.libraryTools(), model: model)
            let id = try rig.create("Find out how much rain fell")
            let first = try await rig.step()
            let saved = try rig.checkpoint(first)
            try require(first.state == .queued && saved.outstandingCalls.isEmpty
                        && saved.sources?.filter { $0.read == true }.map(\.url) == [moved, "https://gauge.example/levels"],
                        "The \(variant) run reads both pages in its first step: \(saved.sources ?? [])")
            let used = try NativeTaskGenerationJob.wireBytes(saved.transcript, tools: rig.tools.map(\.schema))
            rig.environment.budget = NativeCompanionWorkerBudget(transcriptBytes: variant == "tight" ? used : used + 16383)
            let mark = rig.model.calls.count
            if variant == "unusable" { rig.model.failClosing(NativeTaskGenerationFailure(code: "provider_response")) }
            let ended = try await rig.settle()
            let result = try rig.report(ended.record)
            let report = result["report"] as? String ?? ""
            let sources = result["sources"] as? [[String: Any]] ?? []
            try require(ended.record.state == .completed && !ended.states.contains(.needsDecision) && (try rig.asked(id)) == 0,
                        "The \(variant) work ends once without asking: \(ended.states)")
            try require(variant == "tight" ? rig.model.calls.count == mark : companionClosingOnly(rig, after: mark),
                        "The \(variant) finish \(variant == "tight" ? "never asks for" : "asks only for") the closing write-up")
            try require(variant != "unusable" || rig.model.calls.dropFirst(mark).count == 1,
                        "An unusable closing write-up is not asked for again: \(rig.model.calls.dropFirst(mark))")
            if variant == "closing" {
                try require(report == NativeCompanionWorker.outOfRoomLead + "\n\nTwo inches of rain fell [1]."
                            && sources.compactMap { $0["url"] as? String } == [moved],
                            "A closing write-up that fits is used under the ran out of room line: \(report)")
                continue
            }
            try require(report.hasPrefix(NativeCompanionWorker.outOfRoomFallback),
                        "The \(variant) finish says the work ran out of room and the write-up could not be written: \(report)")
            try require(report.contains("Pages read:\n- Rain totals page [1]\n- River levels [2]")
                        && report.contains("Found in a search, not read:\n- Forecast [3]"),
                        "The \(variant) report lists the pages that were read: \(report)")
            try require(sources.compactMap { ($0["n"] as? NSNumber)?.intValue } == [1, 2, 3]
                        && sources.compactMap { $0["url"] as? String } == [moved, "https://gauge.example/levels", "https://third.example/"],
                        "The \(variant) result keeps the fetched pages as sources: \(sources)")
            try require(!report.contains("weather.example") && !report.contains(": done") && !report.contains("http"),
                        "The \(variant) report never lists the address that redirected or a raw step list: \(report)")
        }
    }

    nonisolated static func companionEngineCompletion(_ job: NativeTaskGenerationJob, rounds limit: Int) -> NativeTaskGenerationCompletion {
        if job.messages.first?.content == NativeCompanionShape.classifierPrompt { return .text("{\"keep\": false}") }
        let rounds = job.messages.filter { $0.role == "assistant" && $0.toolCalls != nil }.count
        if job.tools == nil || job.toolChoice == "none" || rounds >= limit { return .text("The central reading room has forty seats.") }
        return NativeCompanionScriptedModel.call(NativeCompanionFinishRig.lookupName, "{}", id: "call-\(job.messages.count)")
    }

    private static func companionEngineHarness(_ repository: LocalChatRepository, recorder: NativeTaskJobRecorder, rounds: Int,
                                               first: NativeTaskStepResult? = nil) throws -> (NativeTaskEngineHarness, NativeTaskStore) {
        let tasks = NativeTaskStore(database: repository.database)
        let ledger = NativeEffectLedgerStore(database: repository.database)
        let rules = NativeRuleSource()
        rules.setGlobal(NativeRules(choices: [:]))
        let grants = NativeFolderGrantSource()
        let tools = NativeCompanionFinishRig.libraryTools()
        let environment = NativeCompanionWorkerEnvironment(
            context: { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: "companion-thread-1", tools: tools) },
            authority: { conversation, request in
                NativeCompanionWorkerAuthority(resolver: rules.resolver(for: conversation, requestText: request), grantsRevision: grants.revision)
            },
            ledger: ledger, tasks: tasks, defaultToolSeconds: 2)
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: NativeTaskEngineCounter(),
            workers: { exchange in
                let real = NativeCompanionWorker.make(exchange: exchange, environment: environment)
                guard let first else { return ["companion": real] }
                return ["companion": NativeTaskWorker(timeoutSeconds: real.timeoutSeconds) { task in
                    task.checkpoint == NativeTaskStore.emptyObject ? first : try await real.step(task)
                }]
            }) { job in
                await recorder.record(job)
                return companionEngineCompletion(job, rounds: rounds)
            }
        return (harness, tasks)
    }

    private static func companionLongWorkThroughEngine() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let recorder = NativeTaskJobRecorder()
        let (harness, tasks) = try companionEngineHarness(repository, recorder: recorder, rounds: 100)
        try await harness.start()
        let reference = try await harness.submitDot("Check the reading room hours at the central library")
        try require(try await harness.wait(seconds: 180) { try harness.state(reference)?.isTerminal == true },
                    "Long work through the engine finishes: \(String(describing: try? harness.state(reference)))")
        guard let remote = try repository.taskReference(id: reference.id)?.remoteTaskID else {
            throw NativeTaskFixture.Failure.assertion("The handoff has an engine id")
        }
        let jobs = await recorder.all()
        let saved = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: try tasks.get(remote).checkpoint)
        try require(try harness.state(reference) == .completed && saved.rounds == 101 && saved.finishing == nil,
                    "The work runs a hundred and one steps and ends with its answer: \(saved.rounds)")
        try require(jobs.contains { $0.phase == "work-100" } && jobs.contains { $0.phase == "work-64" },
                    "Steps past the old numbering are accepted end to end: \(jobs.last?.phase ?? "")")
        let (stored, asked) = try await repository.database.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_task_generations WHERE request_id = ?", arguments: [reference.id.uuidString]) ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_engine_task_events WHERE task_id = ? AND state = 'needs_decision'", arguments: [remote]) ?? 0)
        }
        try require(stored > 64 && asked == 0, "More than 64 saved model requests are accepted and nothing is asked: \(stored) \(asked)")
        try require(repository.taskProjection(id: reference.id)?.snapshot?.result?.report == "The central reading room has forty seats.",
                    "The tracker shows the work's own answer")
        await harness.stop()
    }

    private static func companionOldQuestionCarriesOn() async throws {
        let require = NativeTaskFixture.require
        let old = Data(#"{"attempt":"0ldattempt","calls":4,"effects":[],"pending":{"kind":"cap"},"rounds":4,"segment_calls":4,"segment_rounds":4,"thread_id":"companion-thread-1","transcript":[{"content":"","role":"assistant","tool_calls":[{"arguments":"{}","id":"old-1","name":"room_hours"}]},{"content":"{\"seats\":40}","role":"tool","tool_call_id":"old-1"}]}"#.utf8)
        let decision: [String: Any] = ["prompt": CompanionSavedText.marker + " has used this run's working time and saved its progress. Keep going, or finish with what it has?",
                                       "choices": ["continue", "finish"]]
        let rig = try NativeCompanionFinishRig(model: .looping())
        let assignment = "Check the reading room hours at the central library"
        let id = try rig.create(assignment)
        let waiting = try rig.seed(id, checkpoint: old, decision: decision)
        let shown = try rig.display(waiting, assignment: assignment)
        try require(shown.card.status == .working && shown.card.milestone == "Working on your goal." && shown.card.offeredChoices.isEmpty
                    && shown.card.statusTitle == "Working on it",
                    "Work saved on the old question reads as ordinary work in progress: \(shown.card.status) \(shown.card.milestone)")

        let repository = try LocalChatRepository(inMemory: true)
        let recorder = NativeTaskJobRecorder()
        let first = NativeTaskStepResult(state: .needsDecision, checkpoint: old, event: "progress",
                                         data: try NativeTaskStore.canonical(["message": "saved"]), decision: try NativeTaskStore.canonical(decision))
        let (harness, tasks) = try companionEngineHarness(repository, recorder: recorder, rounds: 3, first: first)
        try await harness.start()
        let reference = try await harness.submitDot(assignment)
        try require(try await harness.wait(seconds: 180) { try harness.state(reference)?.isTerminal == true },
                    "Work saved on the old question carries on by itself: \(String(describing: try? harness.state(reference)))")
        guard let remote = try repository.taskReference(id: reference.id)?.remoteTaskID else {
            throw NativeTaskFixture.Failure.assertion("The handoff has an engine id")
        }
        let saved = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: try tasks.get(remote).checkpoint)
        let (answers, asked) = try await repository.database.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_task_retries WHERE reference_id = ?", arguments: [reference.id.uuidString]) ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_engine_task_events WHERE task_id = ? AND state = 'needs_decision'", arguments: [remote]) ?? 0)
        }
        try require(try harness.state(reference) == .completed && saved.rounds == 7 && saved.finishing == nil,
                    "The resumed work runs to its own answer: rounds \(saved.rounds)")
        try require(answers == 1 && asked == 1, "The old question is answered once and never asked again: \(answers) \(asked)")
        let jobs = await recorder.all()
        try require(jobs.contains { $0.toolChoice == "auto" } && !jobs.contains { $0.attempt.contains("-finish") },
                    "It carries on with its tools instead of finishing early")
        await harness.stop()
    }
}

final class NativeCompanionHeldAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var held = true
    private var tries = 0

    var attempts: Int { lock.withLock { tries } }

    func check() -> Bool { lock.withLock { tries += 1; return held } }

    func release() { lock.withLock { held = false } }
}

@MainActor
extension SelfTest {
    private static func companionManyCallsInOneReply() async throws {
        let require = NativeTaskFixture.require
        let calls = (0..<65).map { NativeTaskGenerationToolCall(id: "many-\($0)", name: NativeCompanionFinishRig.lookupName, arguments: "{}") }
        let reply = NativeTaskGenerationCompletion(content: "", toolCalls: calls, finishReason: "tool_calls")
        let tools = NativeCompanionFinishRig.libraryTools().map(\.schema)
        let opening = [NativeTaskGenerationMessage(role: "system", content: "Work on the assignment."),
                       NativeTaskGenerationMessage(role: "user", content: "Assignment:\nCheck the reading room hours")]
        let job = NativeTaskGenerationJob(id: UUID().uuidString, taskID: "task-many", bindingID: "binding-many", enrollmentDigest: "digest",
            admissionBase: URL(string: "https://provider.example.org/v1")!, phase: "work-0", attempt: "many", messages: opening,
            messagesDigest: NativeTaskGenerationJob.digest(opening, tools: tools, toolChoice: "auto"), deadlineSeconds: 60,
            generation: 1, tools: tools, toolChoice: "auto")
        try require((try? reply.validated(for: job)) == reply, "A reply with 65 tool calls is accepted")
        let transcript = opening + [NativeTaskGenerationMessage(role: "assistant", content: "", toolCalls: calls)]
            + calls.map { NativeTaskGenerationMessage(role: "tool", content: "{\"seats\":40}", toolCallID: $0.id) }
        try require(NativeTaskGenerationJob.validShape(transcript, tools: tools, toolChoice: "auto", budget: .dot),
                    "A saved transcript with 65 calls in one reply is accepted")

        let model = NativeCompanionFinishModel { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeTaskGenerationCompletion(content: "", toolCalls: calls, finishReason: "tool_calls")
                : .text("The central reading room has forty seats.")
        }
        let rig = try NativeCompanionFinishRig(model: model)
        let id = try rig.create()
        let settled = try await rig.settle()
        let saved = try rig.checkpoint(settled.record)
        let answered = saved.transcript.filter { $0.role == "tool" }.compactMap(\.toolCallID)
        try require(settled.record.state == .completed && (try rig.asked(id)) == 0 && saved.calls == 65
                    && answered.sorted() == calls.map(\.id).sorted() && NativeCompanionFinishRig.answeredOnce(saved),
                    "All 65 calls in one reply run and are answered once: \(saved.calls) \(answered.count)")
        try require(saved.transcript.filter { $0.role == "tool" }.allSatisfy { $0.content.contains("seats") },
                    "Every one of the 65 calls ran its tool")
    }

    private static func companionEndingSavedFirst() async throws {
        let require = NativeTaskFixture.require
        let small = NativeCompanionFinishRig.libraryTools()
        let large = NativeCompanionFinishRig.paddedTools(8)
        var rig = try NativeCompanionFinishRig(tools: large, model: .looping())
        let id = try rig.create()
        let first = try await rig.step()
        let saved = try rig.checkpoint(first)
        try require(first.state == .queued && saved.rounds == 1 && saved.outstandingCalls.isEmpty, "The first step runs one round")
        let smallBytes = try NativeTaskGenerationJob.wireBytes(saved.transcript, tools: small.map(\.schema))
        let largeBytes = try NativeTaskGenerationJob.wireBytes(saved.transcript, tools: large.map(\.schema))
        let budget = NativeCompanionWorkerBudget(transcriptBytes: smallBytes + 16384 + (largeBytes - smallBytes) / 2)
        rig.environment.budget = budget
        let mark = rig.model.calls.count
        let ending = try await rig.step()
        let ended = try rig.checkpoint(ending)
        try require(ending.state == .queued && ended.finishing == true && rig.model.calls.count == mark,
                    "The step that runs out of room saves the ending without asking the model: \(ending.state) \(rig.model.calls.count - mark)")
        try require(ended.transcript == saved.transcript && ended.rounds == saved.rounds && ending.result == nil,
                    "Saving the ending changes nothing else")

        var control = try NativeCompanionFinishRig(tools: small, model: .looping())
        control.environment.budget = budget
        var unmarked = saved
        unmarked.finishing = nil
        _ = try control.seed(try control.create(), checkpoint: try unmarked.encoded())
        _ = try await control.step()
        try require(control.model.calls.last.map { $0.choice == "auto" && !$0.attempt.hasSuffix("-finish") } == true,
                    "With fewer tools a working request fits again")

        rig.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: "companion-thread-1", tools: small) }
        let settled = try await rig.settle()
        let final = try rig.checkpoint(settled.record)
        let report = try rig.report(settled.record)["report"] as? String ?? ""
        try require(settled.record.state == .completed && (try rig.asked(id)) == 0 && companionClosingOnly(rig, after: mark),
                    "Saved ending work goes to the closing request even when a working request would fit: \(rig.model.calls.dropFirst(mark))")
        try require(final.calls == saved.calls && final.transcript.filter { $0.role == "tool" }.count == saved.transcript.filter { $0.role == "tool" }.count,
                    "No tool runs after the ending is saved")
        try require(report == NativeCompanionWorker.outOfRoomLead + "\n\nThe central reading room has forty seats.",
                    "The result says the work ran out of room: \(report)")
    }

    private static func companionResultFitsItsLimit() async throws {
        let require = NativeTaskFixture.require
        let wide = "a" + String(repeating: "\u{0301}", count: 7000)
        var noted = NativeCompanionCheckpoint()
        noted.threadID = "companion-thread-1"
        for index in 0..<64 { noted.note(wide, index.isMultiple(of: 2) ? "done" : "not done", reason: wide) }
        try require(noted.effects.count == 64 && noted.effects.allSatisfy {
                        $0.title.unicodeScalars.count == NativeCompanionWorker.noteScalars
                            && $0.reason?.unicodeScalars.count == NativeCompanionWorker.noteScalars
                    }, "Saved step titles and reasons are cut when they are noted")
        var object = try NativeTaskStore.object(try noted.encoded())
        var effects = object["effects"] as? [[String: Any]] ?? []
        for index in 0..<16 { effects[index]["title"] = wide }
        object["effects"] = effects
        let older = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: try NativeTaskStore.canonical(object, limit: NativeTaskStore.maximumCheckpointBytes))
        try require(older.effects.prefix(16).allSatisfy { $0.title.unicodeScalars.count == 7001 },
                    "Older saved work still holds its long step titles")
        let text = String(repeating: "\u{1D538}", count: NativeCompanionWorker.reportScalars)
        let assignment = "Check the reading room hours at the central library"
        for (name, checkpoint) in [("noted", noted), ("older", older)] {
            let rig = try NativeCompanionFinishRig(model: .looping())
            let id = try rig.create(assignment)
            let step = try NativeCompanionWorker.report(checkpoint, assignment: assignment, text: text)
            let data = step.result ?? Data()
            let result = try NativeTaskStore.object(data)
            let saved = result["effects"] as? [[String: Any]] ?? []
            try require(data.count <= NativeTaskStore.maximumJSONBytes && saved.count == 64
                        && saved.allSatisfy { (($0["title"] as? String) ?? "").unicodeScalars.count <= NativeCompanionWorker.noteScalars },
                        "The \(name) result fits its size limit: \(data.count)")
            guard let claimed = try rig.store.claim(workerTypes: ["companion"]) else { throw NativeTaskFixture.Failure.assertion("Claimed") }
            let record = try rig.store.commitStep(id, generation: claimed.generation, step: step)
            let display = try rig.display(record, assignment: assignment)
            let shown = display.card.answer ?? display.artifact?.report ?? ""
            try require(record.state == .completed && display.card.status == .completed && !shown.isEmpty
                        && shown == result["report"] as? String,
                        "The completed projection accepts the \(name) result")
        }
    }

    private static func companionOldQuestionSaveFails() async throws {
        let require = NativeTaskFixture.require
        let old = Data(#"{"attempt":"0ldattempt","calls":4,"effects":[],"pending":{"kind":"cap"},"rounds":4,"segment_calls":4,"segment_rounds":4,"thread_id":"companion-thread-1","transcript":[{"content":"","role":"assistant","tool_calls":[{"arguments":"{}","id":"old-1","name":"room_hours"}]},{"content":"{\"seats\":40}","role":"tool","tool_call_id":"old-1"}]}"#.utf8)
        let decision: [String: Any] = ["prompt": CompanionSavedText.marker + " has used this run's working time and saved its progress. Keep going, or finish with what it has?",
                                       "choices": ["continue", "finish"]]
        let repository = try LocalChatRepository(inMemory: true)
        let gate = NativeCompanionHeldAnswer()
        let held = DatabaseFunction("held_answer", argumentCount: 0, pure: false) { _ in gate.check() }
        try repository.database.inDatabase { db in
            db.add(function: held)
            try db.execute(sql: "CREATE TEMP TRIGGER held_answer BEFORE INSERT ON native_task_retries WHEN held_answer() BEGIN SELECT RAISE(ABORT, 'held'); END")
        }
        let recorder = NativeTaskJobRecorder()
        let first = NativeTaskStepResult(state: .needsDecision, checkpoint: old, event: "progress",
                                         data: try NativeTaskStore.canonical(["message": "saved"]), decision: try NativeTaskStore.canonical(decision))
        let (harness, tasks) = try companionEngineHarness(repository, recorder: recorder, rounds: 3, first: first)
        try await harness.start()
        let reference = try await harness.submitDot("Check the reading room hours at the central library")
        func answers() throws -> Int {
            try repository.database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_task_retries WHERE reference_id = ?", arguments: [reference.id.uuidString]) ?? 0
            }
        }
        try require(try await harness.wait(seconds: 60) { gate.attempts >= 3 },
                    "A carried on answer that could not be saved is tried again: \(gate.attempts)")
        try require(try answers() == 0 && (try harness.state(reference))?.isTerminal != true, "Nothing is answered while saving fails")
        gate.release()
        try require(try await harness.wait(seconds: 180) { try harness.state(reference)?.isTerminal == true },
                    "Once saving works again the work carries on: \(String(describing: try? harness.state(reference)))")
        guard let remote = try repository.taskReference(id: reference.id)?.remoteTaskID else {
            throw NativeTaskFixture.Failure.assertion("The handoff has an engine id")
        }
        let saved = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: try tasks.get(remote).checkpoint)
        try require(try harness.state(reference) == .completed && (try answers()) == 1 && saved.rounds == 7,
                    "The answer is saved once and the work completes: \(saved.rounds)")
        try require(repository.taskProjection(id: reference.id)?.snapshot?.result?.report == "The central reading room has forty seats.",
                    "The tracker shows the work's own answer")
        await harness.stop()
    }

    private static func companionNoticesKeptTogether() async throws {
        let require = NativeTaskFixture.require
        let paragraph = "Garden notes " + String(repeating: "b", count: NativeCompanionWorker.reportScalars)
        for variant in ["answer", "out of room"] {
            let model = NativeCompanionFinishModel(closing: .text(paragraph)) { messages in
                NativeCompanionScriptedModel.toolResults(messages).isEmpty
                    ? NativeCompanionScriptedModel.call(NativeCompanionFinishRig.postName, "{\"text\":\"Beds are watered\"}", id: "post-1")
                    : .text(paragraph)
            }
            var rig = try NativeCompanionFinishRig(tools: NativeCompanionFinishRig.libraryTools() + [NativeCompanionFinishRig.postTool()], model: model)
            let id = try rig.create("Check the garden beds", mode: "scheduled", scheduleID: "garden-schedule")
            let first = try await rig.step()
            let saved = try rig.checkpoint(first)
            guard let undone = NativeReadOnlyRun.undone(saved.effects.filter { $0.outcome == NativeReadOnlyRun.outcome }.map(\.title)),
                  let notRun = NativeCompanionWorker.notRunLine(saved.effects) else {
                throw NativeTaskFixture.Failure.assertion("The scheduled run leaves a change undone and not run: \(saved.effects)")
            }
            if variant == "out of room" {
                let used = try NativeTaskGenerationJob.wireBytes(saved.transcript, tools: rig.tools.map(\.schema))
                rig.environment.budget = NativeCompanionWorkerBudget(transcriptBytes: used + 16383)
            }
            let settled = try await rig.settle()
            let report = try rig.report(settled.record)["report"] as? String ?? ""
            try require(settled.record.state == .completed && (try rig.asked(id)) == 0, "The \(variant) scheduled run completes")
            try require(report.contains(undone) && report.contains(notRun) && report.hasSuffix(undone + "\n\n" + notRun),
                        "The \(variant) report keeps both notices in full: \(report.unicodeScalars.suffix(400))")
            try require(report.unicodeScalars.count <= NativeCompanionWorker.reportScalars,
                        "The \(variant) report fits: \(report.unicodeScalars.count)")
            try require(variant == "answer" ? report.hasPrefix("Garden notes") : report.hasPrefix(NativeCompanionWorker.outOfRoomLead + "\n\nGarden notes"),
                        "The \(variant) report keeps its opening")
        }
    }

    private static func companionNoticesSurviveShrinking() throws {
        let require = NativeTaskFixture.require
        let wide = String(repeating: "\u{1D538}", count: 400)
        var checkpoint = NativeCompanionCheckpoint()
        for _ in 0..<64 { checkpoint.note(wide, "done") }
        let notices = ["Left undone, because scheduled and self-started runs can only read: Post a garden note.",
                       "Not run: Post a garden note. This needs your approval first."]
        let stop = NativeTaskStop(reason: NativeTaskStop.left, step: String(repeating: "\u{1D538}", count: NativeTaskStop.stepScalars),
                                  earlier: NativeCompanionWorker.earlierLine(done: Array(repeating: wide, count: 64), unsure: []))
        let text = String(repeating: "\u{1D538}", count: NativeCompanionWorker.reportScalars)
        let step = try NativeCompanionWorker.report(checkpoint, assignment: "Check the garden beds", text: text, stop: stop, notices: notices)
        let data = step.result ?? Data()
        let report = try NativeTaskStore.object(data)["report"] as? String ?? ""
        try require(data.count <= NativeTaskStore.maximumJSONBytes && report.unicodeScalars.count <= NativeCompanionWorker.reportScalars / 2,
                    "The result shrinks its body to fit: \(data.count) \(report.unicodeScalars.count)")
        try require(report.hasSuffix(notices.joined(separator: "\n\n")), "Both notices survive a shrinking result")
    }

    private static func companionStopDetailsFit() throws {
        let require = NativeTaskFixture.require
        let definition = NativeCompanionFinishRig.libraryTools()[0]
        let marks = "a" + String(repeating: "\u{0301}", count: 7500)
        let described = NativeCompanionWorker.describe(definition, ["title": .string(marks)])
        try require(described.unicodeScalars.count <= definition.title.unicodeScalars.count + 2 + 120 && described.hasSuffix("..."),
                    "A described step is cut by scalars: \(described.unicodeScalars.count)")
        var checkpoint = NativeCompanionCheckpoint()
        checkpoint.threadID = "companion-thread-1"
        for _ in 0..<64 { checkpoint.note(described, "done") }
        let earlier = NativeCompanionWorker.earlierLine(done: Array(repeating: described, count: 200), unsure: Array(repeating: described, count: 200))
        try require((earlier?.unicodeScalars.count ?? 0) == NativeTaskStop.stepScalars / 4, "The earlier steps line is cut")
        let stop = NativeTaskStop(reason: NativeTaskStop.left, step: String(repeating: "\u{1D538}", count: NativeTaskStop.stepScalars), earlier: earlier)
        let assignment = "Check the reading room hours at the central library"
        let rig = try NativeCompanionFinishRig(model: .looping())
        let id = try rig.create(assignment)
        let step = try NativeCompanionWorker.report(checkpoint, assignment: assignment, text: "I stopped before posting the hours.", stop: stop)
        let data = step.result ?? Data()
        try require(data.count <= NativeTaskStore.maximumJSONBytes, "The stopped result fits its size limit: \(data.count)")
        guard let claimed = try rig.store.claim(workerTypes: ["companion"]) else { throw NativeTaskFixture.Failure.assertion("Claimed") }
        let record = try rig.store.commitStep(id, generation: claimed.generation, step: step)
        let display = try rig.display(record, assignment: assignment)
        try require(record.state == .completed && display.card.status == .completed && display.card.stop == stop && stop.drawable,
                    "The completed projection shows the stop")
    }

    private static func companionUnlistedPagesCounted() throws {
        let require = NativeTaskFixture.require
        let long = "https://archive.example.org/" + String(repeating: "a", count: 1100)
        var checkpoint = NativeCompanionCheckpoint()
        checkpoint.sources = [NativeTaskSource(n: 1, title: "Archive scan", url: long + "1", read: true),
                              NativeTaskSource(n: 2, title: "Archive index", url: long + "2", read: true)]
        let sections = NativeCompanionWorker.savedMaterial(checkpoint)
        try require(sections == ["I saved 2 more pages, but I can't list them here."], "Several unlisted pages are counted: \(sections)")
    }

    private static func companionAppendKeepsSuffix() throws {
        let require = NativeTaskFixture.require
        let suffix = "The room was closed."
        let paragraph = "Reading room notes " + String(repeating: "b", count: NativeCompanionWorker.reportScalars)
        for body in [paragraph, NativeCompanionWorker.outOfRoomLead + "\n\n" + paragraph] {
            let appended = NativeCompanionWorker.appendingReport(suffix, to: body)
            try require(appended.hasSuffix("\n\n" + suffix) && appended.unicodeScalars.count <= NativeCompanionWorker.reportScalars,
                        "A line appended to one long paragraph is kept within the limit: \(appended.unicodeScalars.count)")
            try require(appended.hasPrefix(String(body.prefix(2000))), "The start of the long paragraph is kept")
        }
        let led = NativeCompanionWorker.appendingReport(suffix, to: NativeCompanionWorker.outOfRoomLead + "\n\n" + paragraph)
        try require(led.hasPrefix(NativeCompanionWorker.outOfRoomLead + "\n\nReading room notes"), "The ran out of room line survives")
    }
}

extension NativeCompanionFinishRig {
    static let lookupName = "room_hours"

    static let postName = "post_note"

    static func postTool() -> NativeToolDefinition {
        let object: NativeJSONValue = .object(["type": .string("object"), "properties": .object(["text": .object(["type": .string("string")])])])
        return NativeToolDefinition(id: "garden-notes", name: postName, title: "Post a garden note", description: "Post a note to the garden board",
                                    parameters: object, confirmation: .none, isAvailable: { true }, execute: { _ in .object(["posted": .bool(true)]) })
    }

    static func paddedTools(_ count: Int) -> [NativeToolDefinition] {
        let object: NativeJSONValue = .object(["type": .string("object"), "properties": .object([:])])
        return libraryTools() + (0..<count).map { index in
            var shelf = NativeToolDefinition(id: "shelf-\(index)", name: "shelf_notes_\(index)", title: "Read the shelf notes",
                                             description: String(repeating: "Shelf notes. ", count: 300), parameters: object,
                                             confirmation: .none, isAvailable: { true }, execute: { _ in .object([:]) })
            shelf.effect = .read
            return shelf
        }
    }

    static func libraryTools() -> [NativeToolDefinition] {
        let object: NativeJSONValue = .object(["type": .string("object"), "properties": .object([:])])
        var hours = NativeToolDefinition(id: "library", name: lookupName, title: "Check the reading room hours",
                                         description: "Read the reading room opening hours", parameters: object, confirmation: .none,
                                         isAvailable: { true }, execute: { _ in
            .object(["opens": .string("9:00"), "closes": .string("17:00"), "seats": .number(40)])
        })
        hours.effect = .read
        return [hours]
    }

    func decision(_ record: NativeTaskRecord) throws -> [String] {
        guard let raw = record.decision else { throw NativeTaskFixture.Failure.assertion("A question is waiting") }
        return try NativeTaskStore.object(raw)["choices"] as? [String] ?? []
    }
}
