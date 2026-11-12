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
    let repository: LocalChatRepository
    let store: NativeTaskStore
    let ledger: NativeEffectLedgerStore
    let model: NativeCompanionFinishModel
    var environment: NativeCompanionWorkerEnvironment

    init(url: URL? = nil, rounds: Int = 4, tools custom: [NativeToolDefinition]? = nil, model: NativeCompanionFinishModel) throws {
        repository = try url.map { try LocalChatRepository(url: $0) } ?? LocalChatRepository(inMemory: true)
        store = NativeTaskStore(database: repository.database)
        let clock = NativeEffectTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        ledger = NativeEffectLedgerStore(database: repository.database, now: { clock.now })
        self.model = model
        let rules = NativeRuleSource()
        rules.setGlobal(NativeRules(choices: [:]))
        let grants = NativeFolderGrantSource()
        let tools = custom ?? Self.libraryTools()
        environment = NativeCompanionWorkerEnvironment(
            context: { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: "companion-thread-1", tools: tools) },
            authority: { conversation, request in
                NativeCompanionWorkerAuthority(resolver: rules.resolver(for: conversation, requestText: request), grantsRevision: grants.revision)
            },
            ledger: ledger, tasks: store, now: { clock.now }, pause: { _ in }, defaultToolSeconds: 2)
        let standard = NativeCompanionWorkerBudget.standard
        environment.budget = NativeCompanionWorkerBudget(rounds: rounds, calls: standard.calls, transcriptMessages: standard.transcriptMessages,
                                                         transcriptBytes: standard.transcriptBytes, taskRounds: standard.taskRounds,
                                                         taskCalls: standard.taskCalls)
    }

    func create(_ assignment: String = "Check the reading room hours at the central library", mode: String = "manual") throws -> String {
        let dot = try NativeCompanionTaskPayload(assignment: assignment, mode: mode)
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

    func settle(_ limit: Int = 16) async throws -> (record: NativeTaskRecord, states: [NativeTaskState]) {
        var states: [NativeTaskState] = []
        for _ in 0..<limit {
            let record = try await step()
            states.append(record.state)
            if record.state != .queued { return (record, states) }
        }
        throw NativeTaskFixture.Failure.assertion("The companion work settles")
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

    static func answeredOnce(_ checkpoint: NativeCompanionCheckpoint) -> Bool {
        let issued = checkpoint.transcript.flatMap { $0.toolCalls ?? [] }.map(\.id)
        let answers = checkpoint.transcript.compactMap(\.toolCallID)
        return Set(issued).count == issued.count && answers.sorted() == issued.sorted()
    }
}

@MainActor
extension SelfTest {
    static func runNativeCompanionFinish() async throws {
        try await companionFinishAfterContinueUnavailable()
        try await companionFinishAutomaticRetry()
        try await companionFinishAtFirstCap()
        try await companionFinishTerminal()
        try await companionFinishScalarLimit()
        try await companionFinishRelaunch()
        try await companionFinishStopped()
        try await companionFinishAnsweredOnce()
        try await companionFinishOldCheckpoint()
        try await companionSourcesRead()
        try await companionFinishSavedPages()
        try await companionFinishFallbackKeepsPages()
        try await companionFinishThroughEngine()
        print("  companion finish OK (finish survives a missing model, automatic and explicit retries, a relaunch and a stop, closing write-up only, unanswered calls answered once, terminal failure keeps saved sources, one answer per question, older saved work, pages read or only found, a redirect saves the page that was read, unfinished write-ups cite only listed pages, a write-up that can't run keeps the pages, tracker and engine end to end)")
    }

    private static func companionCappedTwice(_ rig: NativeCompanionFinishRig) async throws -> NativeTaskRecord {
        let require = NativeTaskFixture.require
        _ = try rig.create()
        let first = try await rig.settle()
        try require(first.record.state == .needsDecision && (try rig.checkpoint(first.record)).pending?.kind == "cap",
                    "The first cap asks to keep going or finish")
        try rig.reply(first.record, "continue")
        let second = try await rig.settle()
        try require(second.record.state == .needsDecision && (try rig.checkpoint(second.record)).rounds == 8,
                    "The second cap asks again after another four rounds")
        return second.record
    }

    private static func companionClosingOnly(_ rig: NativeCompanionFinishRig, after mark: Int) -> Bool {
        let later = rig.model.calls.dropFirst(mark)
        return !later.isEmpty && later.allSatisfy { $0.choice == "none" && $0.attempt.hasSuffix("-finish") }
    }

    private static func companionFinishAfterContinueUnavailable() async throws {
        let require = NativeTaskFixture.require
        let rig = try NativeCompanionFinishRig(model: .looping())
        let waiting = try await companionCappedTwice(rig)
        rig.model.failClosing(NativeTaskExecutorUnavailable())
        let mark = rig.model.calls.count
        try rig.reply(waiting, "finish")
        let blocked = try await rig.step()
        try require(blocked.state == .blocked, "A closing write-up without a model blocks the work: \(blocked.state)")
        _ = try rig.store.resume(blocked.id)
        let settled = try await rig.settle()
        try require(!settled.states.contains(.needsDecision),
                    "After Finish the question never comes back: \(settled.states) pending \(String(describing: (try? rig.checkpoint(settled.record))?.pending))")
        try require(settled.record.state == .completed && (try rig.report(settled.record)["report"] as? String)?.isEmpty == false,
                    "The resumed work completes with a report")
        try require(companionClosingOnly(rig, after: mark), "After Finish the model is only asked for the closing write-up: \(rig.model.calls.dropFirst(mark))")
        try require(NativeCompanionFinishRig.answeredOnce(try rig.checkpoint(settled.record)), "Every call is answered exactly once")
    }

    private static func companionFinishAutomaticRetry() async throws {
        let require = NativeTaskFixture.require
        let rig = try NativeCompanionFinishRig(model: .looping())
        let waiting = try await companionCappedTwice(rig)
        rig.model.failClosing(NativeTaskGenerationFailure(code: "request_timeout"))
        let mark = rig.model.calls.count
        try rig.reply(waiting, "finish")
        let settled = try await rig.settle()
        try require(!settled.states.contains(.needsDecision) && settled.record.state == .completed,
                    "A closing write-up that retries on its own still finishes without asking again: \(settled.states)")
        try require(companionClosingOnly(rig, after: mark), "The automatic retry asks only for the closing write-up: \(rig.model.calls.dropFirst(mark))")

        let unsafe = try NativeCompanionFinishRig(model: .looping())
        let asked = try await companionCappedTwice(unsafe)
        unsafe.model.failClosing(NativeTaskGenerationFailure(code: "provider_auth"))
        let unsafeMark = unsafe.model.calls.count
        try unsafe.reply(asked, "finish")
        let retry = try await unsafe.settle()
        try require(retry.record.state == .needsDecision && (try unsafe.decision(retry.record)) == ["retry"],
                    "A closing write-up that is unsafe to repeat asks only to retry")
        try unsafe.reply(retry.record, "retry")
        let done = try await unsafe.settle()
        try require(done.record.state == .completed && !done.states.contains(.needsDecision),
                    "After Retry the work goes back to finishing: \(done.states)")
        try require(companionClosingOnly(unsafe, after: unsafeMark), "Retrying asks only for the closing write-up: \(unsafe.model.calls.dropFirst(unsafeMark))")
    }

    private static func companionFinishAtFirstCap() async throws {
        let require = NativeTaskFixture.require
        let rig = try NativeCompanionFinishRig(model: .looping(callsPerRound: 3))
        _ = try rig.create()
        let capped = try await rig.settle()
        let saved = try rig.checkpoint(capped.record)
        try require(capped.record.state == .needsDecision && saved.pending?.kind == "cap" && !saved.outstandingCalls.isEmpty,
                    "The action cap asks with calls still unanswered")
        rig.model.failClosing(NativeTaskExecutorUnavailable())
        let mark = rig.model.calls.count
        try rig.reply(capped.record, "finish")
        let blocked = try await rig.step()
        try require(blocked.state == .blocked && (try rig.checkpoint(blocked)).outstandingCalls.isEmpty,
                    "The blocked save keeps the not-run answers")
        _ = try rig.store.resume(blocked.id)
        let settled = try await rig.settle()
        try require(settled.record.state == .completed && !settled.states.contains(.needsDecision),
                    "Finishing at the first cap completes after the model returns: \(settled.states)")
        try require(companionClosingOnly(rig, after: mark), "Only the closing write-up runs: \(rig.model.calls.dropFirst(mark))")
        let final = try rig.checkpoint(settled.record)
        let notRun = final.transcript.filter { $0.role == "tool" && $0.content.contains("the person asked to finish") }
        try require(NativeCompanionFinishRig.answeredOnce(final) && notRun.count == saved.outstandingCalls.count,
                    "Unanswered calls are answered once as not run")
    }
}

@MainActor
extension SelfTest {
    private static func companionFinishTerminal() async throws {
        let require = NativeTaskFixture.require
        let web = companionWebTools().1
        let searching = NativeCompanionFinishModel { _ in NativeCompanionScriptedModel.call("web_search", "{\"query\":\"reading rooms\"}") }
        let rig = try NativeCompanionFinishRig(rounds: 1, tools: web, model: searching)
        _ = try rig.create("Find the reading room hours at the public libraries")
        let capped = try await rig.settle()
        try require(capped.record.state == .needsDecision && (try rig.checkpoint(capped.record)).sources?.count == 3,
                    "The search results are saved before the question")
        rig.model.failClosing(NativeTaskGenerationFailure(code: "request_limit"))
        try rig.reply(capped.record, "finish")
        let ended = try await rig.settle()
        let result = try rig.report(ended.record)
        let report = result["report"] as? String ?? ""
        let sources = result["sources"] as? [[String: Any]] ?? []
        try require(ended.record.state == .completed && !ended.states.contains(.needsDecision),
                    "A closing write-up that cannot run ends the work without asking again: \(ended.states)")
        try require(report.hasPrefix("The write-up could not be finished.") && report.contains("Rain totals [1]"),
                    "The result says the write-up could not be finished and lists what was saved: \(report)")
        try require(report.contains("Found in a search, not read:") && !report.contains("Pages read:") && !report.contains("Pages found:"),
                    "Pages that only turned up in a search are never listed as read: \(report)")
        try require(sources.compactMap { ($0["n"] as? NSNumber)?.intValue } == [1, 2, 3]
                    && sources.compactMap { $0["url"] as? String } == ["https://weather.example/rain", "https://gauge.example/levels", "https://third.example/"],
                    "Every saved source is kept: \(sources)")
        try require(!report.contains(CompanionSavedText.marker) && !report.contains("\u{2014}"), "The statement is plain")

        let empty = try NativeCompanionFinishRig(rounds: 1, model: .looping())
        _ = try empty.create()
        let asked = try await empty.settle()
        empty.model.failClosing(NativeTaskGenerationFailure(code: "input_limit"))
        try empty.reply(asked.record, "finish")
        let nothing = try await empty.settle()
        let nothingReport = try empty.report(nothing.record)["report"] as? String ?? ""
        try require(nothing.record.state == .completed
                    && nothingReport == "The write-up could not be finished. No pages were read before it stopped.",
                    "With only other tool results the result says no pages were read: \(nothingReport)")
        try require(!nothingReport.lowercased().contains("nothing"), "The result never claims nothing was found")
    }

    private static func companionFinishScalarLimit() async throws {
        let require = NativeTaskFixture.require
        let lead = "The write-up could not be finished. This is what was saved before it stopped."
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
            checkpoint.pending = NativeCompanionPending(kind: "cap")
            checkpoint.sources = [source]
            for _ in 0..<4 { checkpoint.note(described, "done") }
            let longLine = "a" + String(repeating: "\u{0301}", count: variant == "both" ? 16000 : 30000)
            if variant == "undone" || variant == "both" { checkpoint.note(longLine, NativeReadOnlyRun.outcome) }
            if variant == "not run" || variant == "both" { checkpoint.note(longLine, "not done", reason: "The room was closed.") }
            try require((NativeCompanionWorker.earlierLine(checkpoint) ?? "").unicodeScalars.count > NativeCompanionWorker.reportScalars,
                        "The completed steps exceed the report limit in scalars")
            guard let claimed = try rig.store.claim(workerTypes: ["companion"]) else { throw NativeTaskFixture.Failure.assertion("Claimed") }
            let waiting = try rig.store.commitStep(id, generation: claimed.generation, step: NativeTaskStepResult(
                state: .needsDecision, checkpoint: try checkpoint.encoded(), event: "progress",
                decision: try NativeTaskStore.canonical(["prompt": "Keep going, or finish with what it has?", "choices": ["continue", "finish"]])))
            rig.model.failClosing(NativeTaskGenerationFailure(code: "request_limit"))
            let mark = rig.model.calls.count
            try rig.reply(waiting, "finish")
            let ended = try await rig.settle()
            let report = try rig.report(ended.record)["report"] as? String ?? ""
            try require(ended.record.state == .completed && companionClosingOnly(rig, after: mark),
                        "The \(variant) finish saves a completed result after the closing request fails")
            let request = try NativeResearchTaskRequest(dot: NativeCompanionTaskPayload(assignment: assignment, mode: "manual"))
            var reference = try rig.repository.prepareTaskReference(origin: NativeTaskFixture.origin(rig.repository),
                engine: NativeTaskEngineIdentity(URL(string: "https://engine.example.org")!), request: request, profile: nil)
            reference.remoteTaskID = id
            let snapshot = try NativeTaskSnapshot(id: id, workerType: ended.record.workerType,
                payload: JSONDecoder().decode(NativeResearchTaskPayload.self, from: ended.record.payload), state: ended.record.state,
                checkpoint: JSONDecoder().decode(NativeTaskCheckpoint.self, from: ended.record.checkpoint),
                result: JSONDecoder().decode(NativeResearchTaskResult.self, from: ended.record.result!), decision: nil,
                cancelRequested: false, generation: ended.record.generation, updatedAt: ended.record.updatedAt)
            let display = try NativeTaskProjection.display(reference: reference, snapshot: snapshot)
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
        func completions(_ rig: NativeCompanionFinishRig, _ id: String) throws -> (completed: Int, asked: Int) {
            try rig.repository.database.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_engine_task_events WHERE task_id = ? AND state = 'completed'", arguments: [id]) ?? 0,
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_engine_task_events WHERE task_id = ? AND state = 'needs_decision'", arguments: [id]) ?? 0)
            }
        }
        for variant in ["answered", "blocked", "interrupted"] {
            let url = directory.appendingPathComponent("\(variant).sqlite")
            let before = try NativeCompanionFinishRig(url: url, rounds: 1, model: .looping())
            let id = try before.create()
            let capped = try await before.settle()
            try before.reply(capped.record, "finish")
            switch variant {
            case "blocked":
                before.model.failClosing(NativeTaskExecutorUnavailable())
                let blocked = try await before.step()
                try require(blocked.state == .blocked && (try before.checkpoint(blocked)).finishing == true, "The blocked save keeps the finishing mark")
            case "interrupted":
                _ = try before.store.claim(workerTypes: ["companion"])
            default:
                break
            }
            let after = try NativeCompanionFinishRig(url: url, rounds: 1, model: .looping())
            try after.store.recover()
            if try after.store.get(id).state == .blocked { _ = try after.store.resume(id) }
            let settled = try await after.settle()
            try require(settled.record.state == .completed && !settled.states.contains(.needsDecision),
                        "After a relaunch the \(variant) work finishes without asking again: \(settled.states)")
            try require(after.model.calls.allSatisfy { $0.choice == "none" }, "After a relaunch only the closing write-up runs")
            try require(try after.store.claim(workerTypes: ["companion"]) == nil, "Nothing is left to run")
            let counts = try completions(after, id)
            try require(counts.completed == 1 && counts.asked == 1, "One result and one question: \(counts)")
        }
    }

    private static func companionFinishStopped() async throws {
        let require = NativeTaskFixture.require
        let rig = try NativeCompanionFinishRig(rounds: 1, model: .looping())
        let id = try rig.create()
        let capped = try await rig.settle()
        rig.model.failClosing(NativeTaskExecutorUnavailable())
        try rig.reply(capped.record, "finish")
        let blocked = try await rig.step()
        try require(blocked.state == .blocked, "Finishing waits for the model")
        let canceled = try rig.store.cancel(id)
        try require(canceled.state == .canceled && canceled.result == nil, "Stopping while finishing ends the work")
        try require(try rig.store.claim(workerTypes: ["companion"]) == nil && (try? rig.store.resume(id)) == nil,
                    "A stopped finish cannot run again")
        try require(try rig.store.get(id).result == nil, "A stopped finish publishes nothing")

        let running = try NativeCompanionFinishRig(rounds: 1, model: .looping())
        let runningID = try running.create()
        let waiting = try await running.settle()
        running.model.failClosing(NativeTaskExecutorUnavailable())
        try running.reply(waiting.record, "finish")
        _ = try await running.step()
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

    private static func companionFinishAnsweredOnce() async throws {
        let require = NativeTaskFixture.require
        let rig = try NativeCompanionFinishRig(rounds: 1, model: .looping())
        let id = try rig.create()
        let capped = try await rig.settle()
        let key = UUID().uuidString
        try rig.reply(capped.record, "finish", key: key)
        let again = try rig.reply(capped.record, "finish", key: key)
        try require(again.state == .queued, "The same answer sent twice is the same answer")
        do {
            try rig.reply(capped.record, "continue")
            throw NativeTaskFixture.Failure.assertion("A second answer to the same question must be refused")
        } catch NativeTaskStoreError.conflict {}
        let done = try await rig.settle()
        try require(done.record.state == .completed, "The first answer finishes the work")
        do {
            try rig.reply(capped.record, "finish")
            throw NativeTaskFixture.Failure.assertion("An answer after the work ended must be refused")
        } catch NativeTaskStoreError.conflict {}
        try require(try rig.store.claim(workerTypes: ["companion"]) == nil && (try rig.store.get(id)).result == done.record.result,
                    "A late answer cannot produce a second result")
    }

    private static func companionFinishOldCheckpoint() async throws {
        let require = NativeTaskFixture.require
        let rig = try NativeCompanionFinishRig(model: .looping())
        let id = try rig.create()
        let old = Data(#"{"attempt":"0ldattempt","calls":4,"effects":[],"pending":{"kind":"cap"},"rounds":4,"segment_calls":4,"segment_rounds":4,"sources":[{"n":1,"title":"Opening hours","url":"https://hours.example.org/rooms"}],"thread_id":"companion-thread-1","transcript":[{"content":"","role":"assistant","tool_calls":[{"arguments":"{}","id":"old-1","name":"room_hours"}]},{"content":"{\"seats\":40}","role":"tool","tool_call_id":"old-1"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: old)
        try require(decoded.finishing == nil && decoded.pending?.kind == "cap" && decoded.sources?.first?.read == nil,
                    "Older saved work reads with no finishing mark and its sources unread")
        try require(!String(decoding: try decoded.encoded(), as: UTF8.self).contains("finishing")
                    && !String(decoding: try JSONEncoder().encode(decoded.sources ?? []), as: UTF8.self).contains("read"),
                    "Older saved work encodes as before")
        guard let claimed = try rig.store.claim(workerTypes: ["companion"]) else { throw NativeTaskFixture.Failure.assertion("Claimed") }
        let waiting = try rig.store.commitStep(id, generation: claimed.generation, step: NativeTaskStepResult(
            state: .needsDecision, checkpoint: old, event: "progress",
            decision: try NativeTaskStore.canonical(["prompt": "Keep going, or finish with what it has?", "choices": ["continue", "finish"]])))
        try rig.reply(waiting, "finish")
        let done = try await rig.settle()
        try require(done.record.state == .completed && !done.states.contains(.needsDecision) && rig.model.calls.allSatisfy { $0.choice == "none" },
                    "Finish completes older saved work that was waiting on the question")
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
        let movedPause = PausedWorkCopy.pause(try JSONDecoder().decode(NativeTaskCheckpoint.self, from: try moved.encoded()), answer: nil)
        try require(movedPause.heading == PausedWorkCopy.readHeading && movedPause.pages.map(\.url) == ["https://www.example.org/rooms-moved"]
                    && movedPause.pages.map(\.title) == ["Moved page"],
                    "The pause lists the page that was read under Read so far: \(movedPause.pages)")
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
            "attempt": "savedpages", "calls": 4, "effects": [], "pending": ["kind": "cap"], "rounds": 4, "segment_calls": 4,
            "segment_rounds": 4, "sources": sources, "thread_id": "companion-thread-1",
            "transcript": [["content": "", "role": "assistant", "tool_calls": [["arguments": "{}", "id": "saved-1", "name": NativeCompanionFinishRig.lookupName]]],
                           ["content": "{\"seats\":40}", "role": "tool", "tool_call_id": "saved-1"]],
        ]
        guard let claimed = try rig.store.claim(workerTypes: ["companion"]) else { throw NativeTaskFixture.Failure.assertion("Claimed") }
        let waiting = try rig.store.commitStep(id, generation: claimed.generation, step: NativeTaskStepResult(
            state: .needsDecision, checkpoint: try NativeTaskStore.canonical(checkpoint), event: "progress",
            decision: try NativeTaskStore.canonical(["prompt": "Keep going, or finish with what it has?", "choices": ["continue", "finish"]])))
        rig.model.failClosing(NativeTaskGenerationFailure(code: "request_limit"))
        try rig.reply(waiting, "finish")
        let ended = try await rig.settle()
        let result = try rig.report(ended.record)
        let report = result["report"] as? String ?? ""
        let listed = Set((result["sources"] as? [[String: Any]] ?? []).compactMap { ($0["n"] as? NSNumber)?.intValue })
        let cited = Set(CitationResolver.scan(report, known: Set(1...6)).refs)
        try require(ended.record.state == .completed && !cited.isEmpty && cited.isSubset(of: listed) && !cited.contains(2),
                    "Every number in the unfinished write-up has a matching source: cited \(cited.sorted()) listed \(listed.sorted())\n\(report)")
        try require(report.contains("1 more page was saved but can't be listed.") && !report.contains("Archive scan"),
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
        let require = NativeTaskFixture.require
        let lead = "Reached the limit for this assignment before writing a full report."
        let moved = "https://moved.example/rain-totals"
        for variant in ["tight", "empty", "calls"] {
            let (client, web) = companionWebTools()
            client.page("https://weather.example/rain", .init(body: "<html><head><title>Rain totals page</title></head><body><p>Two inches fell.</p></body></html>",
                                                              finalURL: moved))
            let closing: NativeTaskGenerationCompletion = variant == "calls"
                ? NativeCompanionScriptedModel.call(NativeCompanionFinishRig.lookupName, "{}", id: "closing-call")
                : .text(variant == "empty" ? "  " : "The rain report is ready.")
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
            _ = try rig.create("Find out how much rain fell")
            let capped = try await rig.settle()
            let saved = try rig.checkpoint(capped.record)
            try require(capped.record.state == .needsDecision && saved.pending?.kind == "cap" && !saved.outstandingCalls.isEmpty
                        && saved.sources?.filter { $0.read == true }.map(\.url) == [moved, "https://gauge.example/levels"],
                        "The \(variant) run pauses at the call cap with both pages read: \(saved.sources ?? [])")
            if variant == "tight" {
                let standard = NativeCompanionWorkerBudget.standard
                rig.environment.budget = NativeCompanionWorkerBudget(rounds: 4, calls: standard.calls, transcriptMessages: 2,
                                                                     transcriptBytes: standard.transcriptBytes, taskRounds: standard.taskRounds,
                                                                     taskCalls: standard.taskCalls)
            }
            let mark = rig.model.calls.count
            try rig.reply(capped.record, "finish")
            let ended = try await rig.settle()
            let result = try rig.report(ended.record)
            let report = result["report"] as? String ?? ""
            let sources = result["sources"] as? [[String: Any]] ?? []
            try require(ended.record.state == .completed && !ended.states.contains(.needsDecision) && report.hasPrefix(lead),
                        "The \(variant) finish ends with the limit report: \(report)")
            try require(variant == "tight" ? rig.model.calls.count == mark : rig.model.calls.dropFirst(mark).contains { $0.attempt.hasSuffix("-finish") },
                        "The \(variant) finish \(variant == "tight" ? "never asks for" : "asks for") the closing write-up")
            try require(report.contains("Pages read:\n- Rain totals page [1]\n- River levels [2]")
                        && report.contains("Found in a search, not read:\n- Forecast [3]"),
                        "The \(variant) limit report lists the pages that were read: \(report)")
            try require(sources.compactMap { ($0["n"] as? NSNumber)?.intValue } == [1, 2, 3]
                        && sources.compactMap { $0["url"] as? String } == [moved, "https://gauge.example/levels", "https://third.example/"],
                        "The \(variant) result keeps the fetched pages as sources: \(sources)")
            try require(!report.contains("weather.example") && !report.contains(": done") && !report.contains("http"),
                        "The \(variant) report never lists the address that redirected or a raw step list: \(report)")
        }
    }

    nonisolated static func companionEngineCompletion(_ job: NativeTaskGenerationJob) -> NativeTaskGenerationCompletion {
        if job.messages.first?.content == NativeCompanionShape.classifierPrompt { return .text("{\"keep\": false}") }
        if job.tools == nil || job.toolChoice == "none" { return .text("The central reading room has forty seats.") }
        return NativeCompanionScriptedModel.call(NativeCompanionFinishRig.lookupName, "{}", id: "call-\(job.messages.count)")
    }

    private static func companionFinishThroughEngine() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let recorder = NativeTaskJobRecorder()
        let tasks = NativeTaskStore(database: repository.database)
        let ledger = NativeEffectLedgerStore(database: repository.database)
        let rules = NativeRuleSource()
        rules.setGlobal(NativeRules(choices: [:]))
        let grants = NativeFolderGrantSource()
        let tools = NativeCompanionFinishRig.libraryTools()
        var environment = NativeCompanionWorkerEnvironment(
            context: { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: "companion-thread-1", tools: tools) },
            authority: { conversation, request in
                NativeCompanionWorkerAuthority(resolver: rules.resolver(for: conversation, requestText: request), grantsRevision: grants.revision)
            },
            ledger: ledger, tasks: tasks, defaultToolSeconds: 2)
        let standard = NativeCompanionWorkerBudget.standard
        environment.budget = NativeCompanionWorkerBudget(rounds: 2, calls: standard.calls, transcriptMessages: standard.transcriptMessages,
                                                         transcriptBytes: standard.transcriptBytes, taskRounds: standard.taskRounds,
                                                         taskCalls: standard.taskCalls)
        let worker = environment
        let gate = NativeTaskEngineCounter()
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter,
            workers: { ["companion": NativeCompanionWorker.make(exchange: $0, environment: worker)] },
            available: { await gate.count("hold") == gate.count("release") }) { job in
                await recorder.record(job)
                return companionEngineCompletion(job)
            }
        try await harness.start()
        let reference = try await harness.submitDot("Check the reading room hours at the central library")
        func decision() throws -> NativeTaskDecision? {
            guard let snapshot = try repository.taskProjection(id: reference.id)?.snapshot, snapshot.state == .needsDecision else { return nil }
            return snapshot.decision
        }
        try require(try await harness.wait(seconds: 20) { try decision() != nil }, "The first cap reaches the tracker")
        let first = try decision()
        try require(first?.choices == ["continue", "finish"], "The cap offers Continue and Finish")
        await harness.tracker.decide(reference.id, choice: "continue")
        try require(try await harness.wait(seconds: 20) { try decision().map { $0.id != first?.id } ?? false }, "The second cap reaches the tracker")
        guard let remote = try repository.taskReference(id: reference.id)?.remoteTaskID,
              let binding = NativeTaskGenerationExchange.binding(of: try tasks.get(remote)) else {
            throw NativeTaskFixture.Failure.assertion("The handoff has an engine id and a model binding")
        }
        await gate.bump("hold")
        try require(try await harness.waitAsync(seconds: 10) { await !harness.engine.exchange.hasPresence(remote, binding: binding) },
                    "The app stops answering for the model while the question waits")
        let mark = await recorder.all().count
        await harness.tracker.decide(reference.id, choice: "finish")
        try require(try await harness.wait(seconds: 15) { try tasks.get(remote).state == .blocked }, "Finish reaches the engine and blocks without a model")
        try require(try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: try tasks.get(remote).checkpoint).finishing == true,
                    "The blocked work remembers it is finishing")
        await gate.bump("release")
        try require(try await harness.wait(seconds: 30) { try harness.state(reference) == .completed },
                    "Finish through the tracker completes: \(String(describing: try? harness.state(reference)))")
        let later = await recorder.all().dropFirst(mark)
        try require(!later.isEmpty && later.allSatisfy { $0.toolChoice == "none" || $0.tools == nil },
                    "After Finish the provider is asked only for the closing write-up: \(later.map { $0.toolChoice ?? "nil" })")
        let counts = try await repository.database.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_engine_task_events WHERE task_id = ? AND state = 'completed'", arguments: [remote]) ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_engine_task_events WHERE task_id = ? AND state = 'needs_decision'", arguments: [remote]) ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM native_engine_task_events WHERE task_id = ? AND state = 'blocked'", arguments: [remote]) ?? 0)
        }
        try require(counts.0 == 1 && counts.1 == 2 && counts.2 >= 1, "Exactly one result and two questions after a blocked finish: \(counts)")
        let saved = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: try tasks.get(remote).checkpoint)
        try require(NativeCompanionFinishRig.answeredOnce(saved), "Every call is answered once through the engine")
        let result = try repository.taskProjection(id: reference.id)?.snapshot?.result
        try require(result?.report.isEmpty == false, "The tracker shows the report")
        await harness.stop()
    }
}

extension NativeCompanionFinishRig {
    static let lookupName = "room_hours"

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
