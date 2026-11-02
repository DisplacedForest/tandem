import Foundation

@MainActor
extension SelfTest {
    static func workerAudienceContract() throws {
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
        print("  worker audience OK (research plan and document outline stay neutral, synthesis and body name the owner)")
    }
}
