import Foundation
import GRDB

final class TaskReplyCauseWire: URLProtocol, @unchecked Sendable {
    static let domain = "causes.test"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(domain) == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let scenario = url.host?.split(separator: ".").first.map(String.init),
              scenario != "timeout" else { return }
        let (status, body) = Self.reply(scenario)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static let partial = "Partial section that ran out of ro"

    static func choice(_ content: String, finish: String?, calls: [[String: Any]]? = nil) -> Data {
        var message: [String: Any] = ["role": "assistant", "content": content]
        if let calls { message["tool_calls"] = calls }
        var choice: [String: Any] = ["index": 0, "message": message]
        if let finish { choice["finish_reason"] = finish }
        return (try? JSONSerialization.data(withJSONObject: ["choices": [choice]])) ?? Data()
    }

    static func reply(_ scenario: String) -> (Int, Data) {
        switch scenario {
        case "stop": return (200, choice("{\"text\":\"A complete section.\"}", finish: "stop"))
        case "length": return (200, choice(partial, finish: "length"))
        case "missing": return (200, choice("A complete section.", finish: nil))
        case "filter": return (200, choice("A complete section.", finish: "content_filter"))
        case "odd": return (200, choice("A complete section.", finish: "stopped because of several reasons"))
        case "tools": return (200, choice("", finish: "tool_calls",
                                          calls: [["id": "call-1", "type": "function", "function": ["name": "lookup", "arguments": "{}"]]]))
        case "empty": return (200, choice(" \n ", finish: "stop"))
        case "unreadable": return (200, Data("not a reply".utf8))
        case "error": return (200, (try? JSONSerialization.data(withJSONObject: ["error": ["message": "Upstream failed", "code": 500]])) ?? Data())
        case "large": return (200, choice(String(repeating: "a", count: 262145), finish: "stop"))
        case "huge": return (200, Data(repeating: 32, count: 1048600))
        default: return (503, Data("{}".utf8))
        }
    }

    static func binding(_ scenario: String) throws -> NativeTaskProfileBinding {
        NativeTaskProfileBinding(id: UUID().uuidString, profileID: "causes-profile",
            provider: try NativeTaskEngineIdentity(URL(string: "https://\(scenario).\(domain)/v1")!),
            savedModel: "causes-model", executionModel: "causes-model", limits: try NativeTaskGenerationLimits())
    }

    static func complete(_ scenario: String, job: NativeTaskGenerationJob) async throws -> NativeTaskGenerationCompletion {
        let binding = try binding(scenario)
        let config = NativeChatConfig(baseURL: binding.provider.base, apiKey: "causes-key", model: binding.executionModel, chatTemplateKwargs: nil)
        let limits = scenario == "timeout" ? NativeTaskTransportLimits(connectAndSend: 0.3, readIdle: 0.3) : NativeTaskTransportLimits()
        return try await NativeTaskProvider.completion(config: config, binding: binding, job: job, limits: limits,
                                                       protocolClasses: [TaskReplyCauseWire.self], diagnostics: { _ in })
    }
}

@MainActor
extension SelfTest {
    static func taskReplyCauses() async throws {
        try replyCauseWords()
        try sectionSizing()
        try sizingFieldsSaved()
        try replyCauseCheckpointCompatibility()
        try await replyCauseOldGenerationRow()
        try await replyCauseProvider()
        try await replyCauseSaved()
        try await documentShorterSection()
        try await documentCutShortPause()
        try await documentUnusableAnswer()
        try await documentModelChanged()
    }

    private static func replyCauseWords() throws {
        let require = NativeTaskFixture.require
        typealias Words = NativeTaskWorkerFailures
        try require(Words.sectionCutShortMessage == "This section was too long to finish in one go, even after asking for a shorter one. The sections already written are kept. Try this step again?"
                    && Words.sectionEmptyMessage == "The answer for this section came back empty. The sections already written are kept. Try this step again?"
                    && Words.sectionUnusableMessage == "The answer for this section wasn't something Tandem could use. The sections already written are kept. Try this step again?"
                    && Words.stepCutShortMessage == "This step's answer was too long to finish in one go. Try this step again?"
                    && Words.stepEmptyMessage == "The answer for this step came back empty. Try this step again?"
                    && Words.stepUnusableMessage == "The answer for this step wasn't something Tandem could use. Try this step again?"
                    && Words.modelChangedMessage == "The model this document was using has changed in Settings. Start the document again to use the new one."
                    && Words.shorterSectionNote == "Asking for a shorter section.", "The new sentences read exactly as written")
        let forbidden = ["provider_", "response_", "finish_reason", "finish reason", "model request", "\u{2014}"] + CompanionTalkControlFixture.banned
        for sentence in Words.replySentences {
            let lowered = sentence.lowercased()
            try require(!sentence.contains(where: \.isNumber) && !forbidden.contains(where: { lowered.contains($0) }),
                        "A new sentence carries no code, status or internal word: \(sentence)")
        }
        for code in Words.replyCodes {
            try require(!Words.pauseMessage(code, sections: true).contains(code) && !Words.pauseMessage(code).contains(code), "No code reaches the words: \(code)")
        }
        try require(Words.pauseMessage("response_cut_short", sections: true) == Words.sectionCutShortMessage
                    && Words.pauseMessage("response_empty", sections: true) == Words.sectionEmptyMessage
                    && ["response_finish", "response_tool_calls", "response_unreadable", "provider_error", "response_too_large"].allSatisfy {
                        Words.pauseMessage($0, sections: true) == Words.sectionUnusableMessage && Words.pauseMessage($0) == Words.stepUnusableMessage
                    }
                    && Words.pauseMessage("response_cut_short") == Words.stepCutShortMessage
                    && Words.pauseMessage("response_empty") == Words.stepEmptyMessage, "Each cause has its own words")
        try require(Words.pauseMessage("provider_response") == "The model request did not complete."
                    && Words.pauseMessage("request_timeout") == "The model request took too long.", "The existing lines are unchanged")
        try require(Words.retryPrompt(Words.sectionEmptyMessage) == Words.sectionEmptyMessage
                    && Words.retryPrompt("The model request took too long.") == "The model request took too long. Retry this step?", "The question is asked once")
        try require(!Words.retriesAutomatically("response_cut_short") && Words.retriesAutomatically("response_empty")
                    && Words.retriesAutomatically("provider_error"), "Only a cut-short answer skips the one automatic retry")
        try require(Words.replyCodes.isSubset(of: NativeTaskGenerationExchange.failures)
                    && Words.replyCodes.allSatisfy({ NativeTaskTransportTiming.Outcome(rawValue: $0) != nil })
                    && NativeTaskGenerationExchange.failures.contains("provider_response"), "Every new cause is accepted where causes are checked")
    }

    private static func sectionSizing() throws {
        let require = NativeTaskFixture.require
        func binding(_ tokens: Int?, _ reasoning: Bool?) -> NativeTaskAdmissionBinding {
            NativeTaskAdmissionBinding(id: "binding-1", admissionBase: URL(string: "https://provider.test/v1")!,
                                       enrollmentDigest: String(repeating: "a", count: 64), outputTokens: tokens, reasoning: reasoning)
        }
        let first = NativeDocumentWorker.firstSectionCharacters
        try require(first(binding(1024, false)) == 2496 && first(binding(1024, true)) == 1248
                    && first(binding(8192, false)) == 3000 && first(binding(8192, true)) == 3000
                    && first(binding(1, false)) == 400 && first(binding(9000, false)) == 3000
                    && first(binding(nil, nil)) == 3000 && first(nil) == 3000,
                    "The first section asks for what the real cap holds, and 3000 when the cap was never saved")
        let request = try NativeResearchTaskRequest(objective: "Workshop notes", deliverables: ["Bench"], workerType: "document", title: "Plan")
        var checkpoint = NativeDocumentCheckpoint()
        checkpoint.phase = "draft"
        checkpoint.outline = [NativeDocumentSection(heading: "A", instructions: "B")]
        let identity = NativeWorkerIdentity(assistantName: nil, ownerName: nil)
        for (saved, size) in [(binding(1024, false), 2496), (binding(1024, true), 1248), (binding(nil, nil), 3000)] {
            let payload = NativeResearchTaskPayload(request: request, nativeBinding: saved)
            let prompt = NativeDocumentWorker.messages(payload: payload, checkpoint: checkpoint, identity: identity).first?.content ?? ""
            try require(prompt.contains("at most \(size) characters"), "The section request names \(size) characters")
        }
        let old = try JSONDecoder().decode(NativeTaskAdmissionBinding.self, from: Data(
            "{\"admission_base\":\"https://provider.test/v1\",\"enrollment_digest\":\"\(String(repeating: "a", count: 64))\",\"id\":\"binding-1\"}".utf8))
        let oldWire = String(decoding: try nativeTaskEncoded(old), as: UTF8.self)
        try require(old.outputTokens == nil && old.reasoning == nil && !oldWire.contains("output_tokens") && !oldWire.contains("reasoning"),
                    "A binding saved before the cap was carried reads and writes exactly as before")
        let normal = binding(1024, false)
        try require(NativeDocumentWorker.sectionAllowance(checkpoint, binding: normal) == 2496, "An unshrunk step asks for the first size")
        checkpoint.shrinkStep = checkpoint.stepKey
        checkpoint.shrinks = 1
        try require(NativeDocumentWorker.sectionAllowance(checkpoint, binding: normal) == 1248
                    && NativeDocumentWorker.sectionAllowance(checkpoint, binding: nil) == 1500, "One shrink halves whatever was asked first")
        checkpoint.shrinks = 2
        try require(NativeDocumentWorker.sectionAllowance(checkpoint, binding: normal) == 624
                    && NativeDocumentWorker.sectionAllowance(checkpoint, binding: binding(1024, true)) == 400, "The size never drops under its floor")
        checkpoint.drafts = ["Done"]
        try require(checkpoint.currentShrinks == 0 && NativeDocumentWorker.sectionAllowance(checkpoint, binding: normal) == 2496, "Moving on resets the shrink count")
        let shrinking = try JSONDecoder().decode(NativeTaskCheckpoint.self, from: try checkpoint.encoded())
        checkpoint.shrinkStep = "draft:0:0"
        let movedOn = try JSONDecoder().decode(NativeTaskCheckpoint.self, from: try checkpoint.encoded())
        try require(NativeTaskProjection.documentMilestone(movedOn) == "Drafting section 1 of 1."
                    && NativeTaskProjection.documentMilestone(shrinking) == "Drafting section 1 of 1.",
                    "A card only says it is asking for less while that step is the current one")
        checkpoint.drafts = []
        let current = try JSONDecoder().decode(NativeTaskCheckpoint.self, from: try checkpoint.encoded())
        try require(NativeTaskProjection.documentMilestone(current) == NativeTaskWorkerFailures.shorterSectionNote,
                    "The card says it is asking for a shorter section while it does")
        let longest = String(repeating: "a", count: NativeDocumentWorker.sectionCharacters)
        try require(NativeDocumentWorker.parseSectionText(longest) == longest
                    && NativeDocumentWorker.parseSectionText(longest + "a") == nil, "The section maximum is unchanged")
    }

    private static func sizingFieldsSaved() throws {
        let require = NativeTaskFixture.require
        func options(_ values: [String: NativeJSONValue]?) -> NativeChatRequestOptions {
            var options = NativeChatRequestOptions.none
            if let values { options.topLevel.append(.init(key: "reasoning", value: .object(values), source: .saved)) }
            return options
        }
        try require(NativeTaskConfiguration.reasoningOn(options(["enabled": .bool(true)]))
                    && !NativeTaskConfiguration.reasoningOn(options(["enabled": .bool(false), "effort": .string("high")]))
                    && NativeTaskConfiguration.reasoningOn(options(["effort": .string("high")]))
                    && !NativeTaskConfiguration.reasoningOn(options(["effort": .string("none")]))
                    && !NativeTaskConfiguration.reasoningOn(options(nil)), "Reasoning counts as on only when the saved settings turn it on")
        let repository = try LocalChatRepository(inMemory: true)
        let provider = try NativeTaskEngineIdentity(URL(string: "https://provider.test/v1")!)
        let thinking = NativeTaskProfileBinding(id: UUID().uuidString, profileID: "sizing-profile", provider: provider,
            savedModel: "sizing-model", executionModel: "sizing-model", limits: try NativeTaskGenerationLimits(maximumOutputTokens: 2048),
            reasoning: true)
        let document = try NativeResearchTaskRequest(objective: "Workshop notes", deliverables: ["Bench"], workerType: "document", title: "Plan")
        let research = try NativeResearchTaskRequest(objective: "What color is the fictional moon Luma?", deliverables: ["A cited answer"])
        let remote = try NativeTaskEngineIdentity(URL(string: "https://server.test/api")!)
        func saved(_ engine: NativeTaskEngineIdentity, _ request: NativeResearchTaskRequest) throws -> NativeTaskAdmissionBinding? {
            try repository.prepareTaskReference(origin: try NativeTaskFixture.origin(repository), engine: engine, request: request,
                                                profile: thinking).createRequest.payload.nativeBinding
        }
        let local = try saved(NativeTaskLocalEngine.identity, document)
        try require(local?.outputTokens == 2048 && local?.reasoning == true
                    && NativeDocumentWorker.firstSectionCharacters(local) == 2784, "A local document saves the real cap and reasoning")
        for other in [try saved(NativeTaskLocalEngine.identity, research), try saved(remote, document), try saved(remote, research)] {
            let wire = try other.map { String(decoding: try nativeTaskEncoded($0), as: UTF8.self) } ?? ""
            try require(other != nil && other?.outputTokens == nil && other?.reasoning == nil && !wire.contains("output_tokens") && !wire.contains("reasoning"),
                        "Requests that can reach the server carry no new fields")
        }
    }

    private static func replyCauseCheckpointCompatibility() throws {
        let require = NativeTaskFixture.require
        let old = "{\"attempt\":\"initial\",\"automatic_retry_step\":\"draft:0:0\",\"drafts\":[],\"errors\":[],\"outline\":[{\"heading\":\"A\",\"instructions\":\"B\"}],\"outline_attempts\":0,\"phase\":\"draft\",\"retry\":false,\"revisions\":[]}"
        let decoded = try JSONDecoder().decode(NativeDocumentCheckpoint.self, from: Data(old.utf8))
        try require(decoded.pauseCause == nil && decoded.shrinkStep == nil && decoded.shrinks == 0 && decoded.outline.count == 1
                    && decoded.automaticRetryStep == "draft:0:0", "A checkpoint saved before shrinking still decodes")
        var current = decoded
        current.pauseCause = "response_cut_short"
        current.shrinkStep = current.stepKey
        current.shrinks = 2
        let again = try JSONDecoder().decode(NativeDocumentCheckpoint.self, from: try current.encoded())
        try require(again == current, "The new checkpoint fields round trip")
        let detail = NativeTaskGenerationFailureDetail(phase: "draft-1", httpStatus: 200, finishReason: "length")
        try require(NativeTaskGenerationFailureDetail.restored(detail.stored()) == detail
                    && detail.stored() == "{\"finish_reason\":\"length\",\"http_status\":200,\"phase\":\"draft-1\"}"
                    && NativeTaskGenerationFailureDetail.restored(nil) == nil
                    && NativeTaskGenerationFailureDetail(phase: "draft-1", finishReason: "a reason with spaces").finishReason == nil
                    && NativeTaskGenerationFailureDetail(phase: "draft-1", finishReason: String(repeating: "a", count: 33)).finishReason == nil
                    && NativeTaskGenerationFailureDetail(phase: "draft-1", httpStatus: 9000).httpStatus == nil, "The saved detail is small and bounded")
    }

    private static func replyCauseOldGenerationRow() async throws {
        let require = NativeTaskFixture.require
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("chat.sqlite")
        let referenceID = UUID()
        do {
            let old = try DatabaseQueue(path: url.path)
            try LocalChatRepository.migrator().migrate(old, upTo: NativeTaskStore.pauseMigration)
            let columns = try await old.read { db in try db.columns(in: "native_task_generations").map(\.name) }
            try require(!columns.contains("failure_detail"), "The old schema has no detail column")
            try await old.write { db in
                try db.execute(sql: "INSERT INTO native_task_outbox(id, intent_key) VALUES (?, ?)", arguments: [referenceID.uuidString, "old-intent"])
                try db.execute(sql: """
                    INSERT INTO native_task_generations(request_id, generation_key, messages_digest, reserved_until, state, failure)
                    VALUES (?, 'old:draft-0:initial-0', 'digest', 0, 'failed', 'provider_response')
                    """, arguments: [referenceID.uuidString])
            }
        }
        let repository = try LocalChatRepository(url: url)
        let (failure, detail) = try await repository.database.read { db in
            (try String.fetchOne(db, sql: "SELECT failure FROM native_task_generations WHERE request_id = ?", arguments: [referenceID.uuidString]),
             try LocalChatRepository.taskGenerationFailureDetail(db, referenceID: referenceID, key: "old:draft-0:initial-0"))
        }
        try require(failure == "provider_response" && detail == nil, "An old generation row keeps its code and reads with no detail")
    }

    private static func replyCauseJob(_ phase: String) -> NativeTaskGenerationJob {
        let messages = [NativeTaskGenerationMessage(role: "user", content: "Write one section")]
        return NativeTaskGenerationJob(id: UUID().uuidString, taskID: UUID().uuidString, bindingID: UUID().uuidString,
            enrollmentDigest: String(repeating: "a", count: 64), admissionBase: URL(string: "https://causes.test/v1")!,
            phase: phase, attempt: "initial-0", messages: messages, messagesDigest: NativeTaskGenerationJob.digest(messages),
            deadlineSeconds: 20, generation: 1)
    }

    static let replyCauseExpectations: [(scenario: String, code: String, status: Int?, finish: String?)] = [
        ("length", "response_cut_short", 200, "length"),
        ("missing", "response_finish", 200, nil),
        ("filter", "response_finish", 200, "content_filter"),
        ("odd", "response_finish", 200, nil),
        ("tools", "response_tool_calls", 200, "tool_calls"),
        ("empty", "response_empty", 200, "stop"),
        ("unreadable", "response_unreadable", 200, nil),
        ("error", "provider_error", 200, nil),
        ("large", "response_too_large", 200, "stop"),
        ("huge", "response_too_large", 200, nil),
        ("status", "provider_unavailable", 503, nil),
        ("timeout", "request_timeout", nil, nil),
    ]

    private static func replyCauseProvider() async throws {
        let require = NativeTaskFixture.require
        let normal = try await TaskReplyCauseWire.complete("stop", job: replyCauseJob("draft-1"))
        try require(normal.content == "{\"text\":\"A complete section.\"}" && normal.finishReason == "stop", "A normal reply is accepted")
        for expected in replyCauseExpectations {
            do {
                _ = try await TaskReplyCauseWire.complete(expected.scenario, job: replyCauseJob("draft-1"))
                throw NativeTaskFixture.Failure.assertion("The \(expected.scenario) reply must fail")
            } catch let failure as NativeTaskGenerationFailure {
                try require(failure.code == expected.code
                            && failure.detail == NativeTaskGenerationFailureDetail(phase: "draft-1", httpStatus: expected.status, finishReason: expected.finish),
                            "The \(expected.scenario) reply has its own cause: \(failure.code) \(String(describing: failure.detail))")
            }
        }
        let replyKinds = Set(replyCauseExpectations.filter { $0.status == 200 }.map(\.code))
        try require(replyKinds == NativeTaskWorkerFailures.replyCodes, "Each kind of unusable reply has a distinct cause")
    }

    private static func replyCauseSaved() async throws {
        let require = NativeTaskFixture.require
        for expected in replyCauseExpectations {
            let repository = try LocalChatRepository(inMemory: true)
            let scenario = expected.scenario
            let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: NativeTaskEngineCounter()) { job in
                try await TaskReplyCauseWire.complete(scenario, job: job)
            }
            try await harness.start()
            let reference = try await harness.submitDocument(title: "Bench plan", brief: "Workshop notes for the bench", inputs: ["Bench along the wall"])
            let settled = try await harness.wait(seconds: 20) {
                let state = try harness.state(reference)
                return state == .needsDecision || state == .failed
            }
            try require(settled, "The \(scenario) document stops for a reason")
            let rows = try await repository.database.read { db in
                try Row.fetchAll(db, sql: "SELECT generation_key, failure FROM native_task_generations WHERE request_id = ? AND state = 'failed'",
                                 arguments: [reference.id.uuidString]).map { row -> (String?, NativeTaskGenerationFailureDetail?) in
                    (row["failure"], try LocalChatRepository.taskGenerationFailureDetail(db, referenceID: reference.id, key: row["generation_key"]))
                }
            }
            let detail = NativeTaskGenerationFailureDetail(phase: "outline", httpStatus: expected.status, finishReason: expected.finish)
            try require(!rows.isEmpty && rows.allSatisfy { $0.0 == expected.code && $0.1 == detail },
                        "The \(scenario) cause and its detail are saved: \(rows)")
            let snapshot = try repository.taskProjection(id: reference.id)?.snapshot
            let events = try harness.engine.store.events(taskID: reference.remoteTaskID!).map { String(decoding: $0.data, as: UTF8.self) }.joined()
            let shown = (snapshot?.decision?.prompt ?? "") + events
            try require(!shown.contains(expected.code) && !shown.contains("finish_reason") && !shown.contains("http_status"),
                        "No cause code or detail reaches what a person sees for \(scenario)")
            await harness.stop()
        }
    }

    nonisolated private static func sectionOutline() -> NativeTaskGenerationCompletion {
        .text("{\"sections\":[{\"heading\":\"Layout\",\"instructions\":\"Describe the bench layout\"},{\"heading\":\"Tools\",\"instructions\":\"List the tools\"}]}")
    }

    private static func asksFor(_ job: NativeTaskGenerationJob, _ characters: Int) -> Bool {
        job.messages.first?.content.contains("at most \(characters) characters") == true
    }

    private static func documentShorterSection() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let recorder = NativeTaskJobRecorder()
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter) { job in
            await recorder.record(job)
            if job.phase == "outline" { return sectionOutline() }
            if job.phase == "draft-0", await counter.count("generate:draft-0") == 1 {
                return try await TaskReplyCauseWire.complete("length", job: job)
            }
            if job.phase.hasPrefix("draft") { return .text("{\"text\":\"Draft for \(job.phase).\"}") }
            return .text("Revised \(job.phase).")
        }
        try await harness.start()
        let reference = try await harness.submitDocument(title: "Bench plan", brief: "Workshop notes for the bench", inputs: ["Bench along the wall"])
        try require(try await harness.wait(seconds: 20) { try harness.state(reference) == .completed }, "A section cut short once finishes after asking for less")
        let drafts = await recorder.all().filter { $0.phase == "draft-0" }
        let saved = reference.createRequest.payload.nativeBinding
        let full = NativeDocumentWorker.firstSectionCharacters(saved)
        try require(saved?.outputTokens == 1024 && saved?.reasoning == false && full == 2496, "A new document carries the real cap and asks for what it holds")
        try require(drafts.count == 2 && asksFor(drafts[0], full) && asksFor(drafts[1], full / 2) && drafts[0].attempt != drafts[1].attempt,
                    "The second request asks for a shorter section under a fresh attempt")
        let later = await recorder.all().filter { $0.phase == "draft-1" }
        try require(later.count == 1 && asksFor(later[0], full), "The next section asks for the full size again")
        let events = try harness.engine.store.events(taskID: reference.remoteTaskID!)
        let messages = events.compactMap { (try? NativeTaskStore.object($0.data))?["message"] as? String }
        try require(messages.contains(NativeTaskWorkerFailures.shorterSectionNote), "The progress line says it is asking for less: \(messages)")
        try require(!events.contains { $0.kind == "decision_received" }, "Nothing was asked of the person")
        let report = try repository.taskProjection(id: reference.id)?.snapshot?.result?.report ?? ""
        try require(report.contains("Revised revise-0.") && !report.contains(TaskReplyCauseWire.partial), "No cut-short text is kept: \(report)")
        await harness.stop()
    }

    private static func documentCutShortPause() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let recorder = NativeTaskJobRecorder()
        let release = NativeTaskEngineCounter()
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter) { job in
            await recorder.record(job)
            if job.phase == "outline" { return sectionOutline() }
            if job.phase == "draft-1", await release.count("retry") == 0 {
                return try await TaskReplyCauseWire.complete("length", job: job)
            }
            if job.phase.hasPrefix("draft") { return .text("{\"text\":\"Draft for \(job.phase).\"}") }
            return .text("Revised \(job.phase).")
        }
        try await harness.start()
        let reference = try await harness.submitDocument(title: "Bench plan", brief: "Workshop notes for the bench", inputs: ["Bench along the wall"])
        try require(try await harness.wait(seconds: 20) { try harness.state(reference) == .needsDecision }, "A section cut short three times pauses")
        let snapshot = try repository.taskProjection(id: reference.id)!.snapshot!
        try require(snapshot.decision?.prompt == NativeTaskWorkerFailures.sectionCutShortMessage && snapshot.decision?.choices == ["retry"],
                    "The pause asks the cut-short question once: \(String(describing: snapshot.decision?.prompt))")
        let card = try NativeTaskProjection.display(reference: try repository.taskReference(id: reference.id)!, snapshot: snapshot).card
        try require(card.milestone == NativeTaskWorkerFailures.sectionCutShortMessage && card.canRetry, "The card shows the cut-short line with Retry")
        let checkpoint = try JSONDecoder().decode(NativeDocumentCheckpoint.self, from: try harness.engine.store.get(reference.remoteTaskID!).checkpoint)
        try require(checkpoint.drafts == ["Draft for draft-0."] && checkpoint.pauseCause == "response_cut_short" && checkpoint.currentShrinks == 2,
                    "The earlier section is kept and the cause is saved")
        let full = NativeDocumentWorker.firstSectionCharacters(reference.createRequest.payload.nativeBinding)
        let tries = await recorder.all().filter { $0.phase == "draft-1" }
        try require(tries.count == 3 && asksFor(tries[0], full) && asksFor(tries[1], full / 2)
                    && asksFor(tries[2], max(NativeDocumentWorker.shortestSectionCharacters, full / 4)),
                    "Each try asks for less, never below the floor")
        await release.bump("retry")
        await harness.tracker.retry(reference.id)
        try require(try await harness.wait(seconds: 20) { try harness.state(reference) == .completed }, "Retry after the pause finishes the document")
        let report = try repository.taskProjection(id: reference.id)?.snapshot?.result?.report ?? ""
        let firstDrafts = await counter.count("generate:draft-0")
        try require(firstDrafts == 1 && report.contains("Revised revise-0.") && report.contains("Revised revise-1.")
                    && !report.contains(TaskReplyCauseWire.partial), "Retry reuses the failed step and keeps the earlier section")
        await harness.stop()
    }

    private static func documentUnusableAnswer() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter) { job in
            if job.phase == "outline" { return sectionOutline() }
            if job.phase == "draft-0" { return try await TaskReplyCauseWire.complete("empty", job: job) }
            return .text("{\"text\":\"Draft for \(job.phase).\"}")
        }
        try await harness.start()
        let reference = try await harness.submitDocument(title: "Bench plan", brief: "Workshop notes for the bench", inputs: ["Bench along the wall"])
        try require(try await harness.wait(seconds: 20) { try harness.state(reference) == .needsDecision }, "An empty answer pauses after one more try")
        let prompt = try repository.taskProjection(id: reference.id)?.snapshot?.decision?.prompt
        let attempts = await counter.count("generate:draft-0")
        try require(prompt == NativeTaskWorkerFailures.sectionEmptyMessage && attempts == 2, "The empty answer gets one automatic retry and its own words: \(attempts)")
        await harness.stop()
    }

    private static func documentModelChanged() async throws {
        let require = NativeTaskFixture.require
        let repository = try LocalChatRepository(inMemory: true)
        let counter = NativeTaskEngineCounter()
        let harness = try NativeTaskEngineHarness.makeTurns(repository: repository, counter: counter) { job in
            if job.phase == "outline" { return sectionOutline() }
            throw NativeTaskGenerationFailure(code: "profile_changed")
        }
        try await harness.start()
        let reference = try await harness.submitDocument(title: "Bench plan", brief: "Workshop notes for the bench", inputs: ["Bench along the wall"])
        try require(try await harness.wait(seconds: 20) { try harness.state(reference) == .failed }, "A changed model ends the document")
        let snapshot = try repository.taskProjection(id: reference.id)!.snapshot!
        let card = try NativeTaskProjection.display(reference: try repository.taskReference(id: reference.id)!, snapshot: snapshot).card
        let attempts = await counter.count("generate:draft-0")
        try require(card.milestone == NativeTaskWorkerFailures.modelChangedMessage && !card.canRetry && snapshot.decision == nil
                    && snapshot.checkpoint.failureReason == "profile_changed" && attempts == 1,
                    "The ending says the model changed and offers no retry: \(String(describing: card.milestone))")
        await harness.stop()
    }
}
