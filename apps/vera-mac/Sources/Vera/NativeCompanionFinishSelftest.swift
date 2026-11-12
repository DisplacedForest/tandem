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

    init(_ script: @escaping @Sendable ([NativeTaskGenerationMessage]) -> NativeTaskGenerationCompletion) {
        self.script = script
    }

    static func looping(callsPerRound: Int = 1) -> NativeCompanionFinishModel {
        NativeCompanionFinishModel { messages in
            let calls = (0..<callsPerRound).map {
                NativeTaskGenerationToolCall(id: "call-\(messages.count)-\($0)", name: "garden_status", arguments: "{}")
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
        if closing { return .text("The garden has three beds.") }
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
        let tools = custom ?? NativeCompanionHarness.tools(NativeCompanionFakeService(), reconcile: false)
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

    func create(_ assignment: String = "Check the garden", mode: String = "manual") throws -> String {
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
        try await companionFinishRelaunch()
        try await companionFinishStopped()
        try await companionFinishAnsweredOnce()
        try await companionFinishOldCheckpoint()
        try await companionSourcesRead()
        try await companionFinishThroughEngine()
        print("  companion finish OK (finish survives a missing model, automatic and explicit retries, a relaunch and a stop, closing write-up only, unanswered calls answered once, terminal failure keeps saved sources, one answer per question, older saved work, pages read or only found, tracker and engine end to end)")
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
        let searching = NativeCompanionFinishModel { _ in NativeCompanionScriptedModel.call("web_search", "{\"query\":\"rain\"}") }
        let rig = try NativeCompanionFinishRig(rounds: 1, tools: web, model: searching)
        _ = try rig.create("Find out how much rain fell")
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
        try require(report.contains("Found in a search, not read:") && !report.contains("Pages read:"),
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
        try require(nothing.record.state == .completed
                    && (try empty.report(nothing.record)["report"] as? String) == "The write-up could not be finished, and nothing was found before it stopped.",
                    "With nothing saved the result says so honestly")
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
        let old = Data(#"{"attempt":"0ldattempt","calls":4,"effects":[],"pending":{"kind":"cap"},"rounds":4,"segment_calls":4,"segment_rounds":4,"sources":[{"n":1,"title":"Rain totals","url":"https://weather.example/rain"}],"thread_id":"companion-thread-1","transcript":[{"content":"","role":"assistant","tool_calls":[{"arguments":"{}","id":"old-1","name":"garden_status"}]},{"content":"{\"beds\":3}","role":"tool","tool_call_id":"old-1"}]}"#.utf8)
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
        let run = try await companionWebRun("Two inches fell [1]. The river rose two feet [2].")
        let saved = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: run.record.checkpoint)
        try require(saved.sources?.map(\.n) == [1, 2, 3] && saved.sources?.map(\.read) == [nil, true, nil],
                    "A page fetched after search is read and the others were only found: \(saved.sources ?? [])")
        let shown = run.result["sources"] as? [[String: Any]] ?? []
        try require(shown.allSatisfy { Set($0.keys) == ["n", "title", "url"] }, "The result's sources are unchanged")
        let tools = companionWebTools().1
        guard let fetcher = tools.first(where: { $0.id == NativeWebTools.fetchToolID }),
              let searcher = tools.first(where: { $0.id == NativeWebTools.searchToolID }) else {
            throw NativeTaskFixture.Failure.assertion("The fake web tools include search and a page reader")
        }
        var direct = NativeCompanionCheckpoint()
        _ = direct.numbered(.object(["url": .string("https://gauge.example/levels"), "title": .string("Gauge page"), "text": .string("Rose.")]),
                            definition: fetcher, requested: "https://gauge.example/levels")
        let found: NativeJSONValue = .object(["results": .array([
            .object(["url": .string("https://gauge.example/levels"), "title": .string("River levels")]),
            .object(["url": .string("https://weather.example/rain"), "title": .string("Rain totals")]),
        ])])
        _ = direct.numbered(found, definition: searcher)
        try require(direct.sources?.map(\.n) == [1, 2] && direct.sources?.map(\.read) == [true, nil],
                    "A page fetched first stays read when it shows up in search, and search alone leaves a page unread")
        let reloaded = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: try direct.encoded())
        try require(reloaded.sources == direct.sources, "Whether a page was read survives a reload")
        let searchRun = try await companionWebRun("Two inches fell [1].", tools: [searcher])
        let searchOnly = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: searchRun.record.checkpoint)
        try require(searchOnly.sources?.allSatisfy { $0.read == nil } == true, "Search alone marks nothing read")
    }

    nonisolated static func companionEngineCompletion(_ job: NativeTaskGenerationJob) -> NativeTaskGenerationCompletion {
        if job.messages.first?.content == NativeCompanionShape.classifierPrompt { return .text("{\"keep\": false}") }
        if job.tools == nil || job.toolChoice == "none" { return .text("The garden has three beds.") }
        return NativeCompanionScriptedModel.call("garden_status", "{}", id: "call-\(job.messages.count)")
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
        let tools = NativeCompanionHarness.tools(NativeCompanionFakeService(), reconcile: false)
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
        let reference = try await harness.submitDot("Check the garden")
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
    func decision(_ record: NativeTaskRecord) throws -> [String] {
        guard let raw = record.decision else { throw NativeTaskFixture.Failure.assertion("A question is waiting") }
        return try NativeTaskStore.object(raw)["choices"] as? [String] ?? []
    }
}
