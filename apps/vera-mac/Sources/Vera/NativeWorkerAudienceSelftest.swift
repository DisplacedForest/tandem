import Foundation

private actor NativeWorkerAudienceRecorder {
    private(set) var messages: [String: [NativeTaskGenerationMessage]] = [:]
    private(set) var queries: [String] = []
    func record(_ phase: String, _ sent: [NativeTaskGenerationMessage]) { messages[phase, default: []] += sent }
    func record(query: String) { queries.append(query) }
}

@MainActor
extension SelfTest {
    static func workerAudienceContract() async throws {
        let owner = "Jordan"
        let named = NativeWorkerIdentity(assistantName: "Nova", ownerName: owner)
        let anonymous = NativeWorkerIdentity(assistantName: "Nova", ownerName: nil)
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NativeTaskFixture.Failure.assertion(message) }
        }
        try require(named.planningAudience == anonymous.planningAudience, "Planning audience must not depend on the owner")
        try require(anonymous.audience == anonymous.planningAudience, "An unnamed owner must read as the neutral audience")
        try require(!NativeResearchWorker.planPrompt(identity: named).contains(owner), "Research planning must not name the owner")
        try require(NativeResearchWorker.synthesisPrompt(identity: named).contains(owner), "Research synthesis must name the owner")

        let request = try NativeResearchTaskRequest(objective: "Summarize the week", deliverables: ["A short brief"], workerType: "document")
        let payload = NativeResearchTaskPayload(request: request)
        var outline = NativeDocumentCheckpoint()
        outline.phase = "outline"
        let outlineMessages = NativeDocumentWorker.messages(payload: payload, checkpoint: outline, identity: named)
        try require(!outlineMessages.contains { $0.content.contains(owner) }, "The document outline must not name the owner")
        var body = NativeDocumentCheckpoint()
        body.outline = [NativeDocumentSection(heading: "Overview", instructions: "Cover the week")]
        for phase in ["draft", "revise"] {
            body.phase = phase
            let messages = NativeDocumentWorker.messages(payload: payload, checkpoint: body, identity: named)
            try require(messages.first { $0.role == "system" }?.content.contains(owner) == true, "The document \(phase) step must name the owner")
        }
        let recorder = NativeWorkerAudienceRecorder()
        let repository = try LocalChatRepository(inMemory: true)
        let search = NativeResearchSearch { query, _ in
            await recorder.record(query: query)
            return [NativeResearchSource(n: 0, title: "Local time guide", url: "https://time.test/\(query.count)",
                                         content: "Local time depends on the time zone. Asked: \(query)")]
        }
        let harness = try NativeTaskEngineHarness.make(repository: repository, counter: NativeTaskEngineCounter(), search: search) { job in
            await recorder.record(job.phase, job.messages)
            return job.phase == "plan" ? "{\"subquestions\": [\"What time zone applies here?\", \"What is the current local time?\"]}"
                : "It is evening locally [1].\n\nSources\n[1] Local time guide"
        }
        try await harness.start()
        let reference = try await harness.submit("What is the current local time where I live?")
        let finished = try await harness.wait { try harness.state(reference) == .completed }
        await harness.stop()
        try require(finished, "The research task completes end to end")
        let sent = await recorder.messages
        let queries = await recorder.queries
        let planned = sent["plan"] ?? []
        try require(planned.contains { $0.role == "system" } && planned.contains { $0.role == "user" }, "The planner sends system and user messages")
        try require(!planned.contains { $0.content.contains(owner) }, "No planner message names the owner")
        let record = try harness.engine.store.get(try reference.remoteTaskID ?? { throw NativeTaskFixture.Failure.assertion("The task has an engine id") }())
        let saved = try JSONDecoder().decode(NativeResearchCheckpoint.self, from: record.checkpoint).subquestions
        try require(saved.count == 2 && !saved.contains { $0.contains(owner) }, "Saved sub-questions never name the owner")
        try require(queries.count == 2 && !queries.contains { $0.contains(owner) }, "No search query names the owner: \(queries)")
        try require(sent["synthesize"]?.first { $0.role == "system" }?.content.contains(owner) == true, "The synthesis request names the owner")
        print("  worker audience OK (research plan, sub-questions, search queries and document outline stay neutral, synthesis and body name the owner)")
    }
}
