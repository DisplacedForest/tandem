import Foundation

extension SelfTest {
    @MainActor
    static func runOngoingWork() throws {
        let require = NativeTaskFixture.require
        let here = "ongoing-here"
        let there = "ongoing-there"
        let fixture = OngoingWorkFixture.self
        let cases: [(NativeTaskReference, OngoingWorkItem.Glyph, String)] = [
            (try fixture.reference(conversationID: here, title: "Preparing", state: nil), .running, "Starting research"),
            (try fixture.reference(conversationID: here, title: "Queued", state: "queued"), .running, "Ready to continue"),
            (try fixture.reference(conversationID: here, title: "Working", state: "running"), .running, "Researching"),
            (try fixture.reference(conversationID: here, title: "Writing", workerType: "document", state: "running"), .running, "Writing"),
            (try fixture.reference(conversationID: here, title: "Stopping", state: "running", cancelRequested: true), .running, "Stopping research"),
            (try fixture.reference(conversationID: here, title: "Stopped", state: "canceled"), .problem, "Research stopped"),
            (try fixture.reference(conversationID: here, title: "Failed", state: "failed"), .problem, "Couldn't finish"),
            (try fixture.reference(conversationID: here, title: "Decision", state: "needs_decision", decision: fixture.decision), .waiting, "Needs your input"),
            (try fixture.reference(conversationID: here, title: "Plan", workerType: "document", state: "completed",
                                   result: fixture.documentResult("Plan")), .done, "Ready to open"),
        ]
        for (reference, glyph, state) in cases {
            let item = OngoingWork.item(reference)
            try require(item.glyph == glyph && item.state == state,
                        "\(reference.request.displayTitle) maps to its glyph and state line, got \(item.state)")
            try require(item.title == reference.request.displayTitle, "The card title is the task title")
            try require((item.artifact != nil) == (state == OngoingWork.readyToOpen), "Only a finished result opens")
        }
        let unopened = OngoingWork.presentation(status: .completed, document: true, hasArtifact: false)
        try require(unopened.glyph == .done && unopened.state == "Document ready", "Completed work without a result keeps its label")

        let elsewhere = try fixture.reference(conversationID: there, title: "Elsewhere", state: "running")
        let orphan = try fixture.reference(conversationID: "ongoing-gone", title: "Orphan", state: "failed")
        let mixed = [cases[0].0, elsewhere, cases[1].0, orphan, cases[2].0]
        let scoped = OngoingWork.items(mixed, conversationID: here)
        try require(scoped.map(\.id) == [cases[2].0, cases[1].0, cases[0].0].map(\.id.uuidString),
                    "The panel keeps only this conversation's work, newest first")
        try require(OngoingWork.items(mixed, conversationID: nil).isEmpty, "No conversation shows no work")
        try require(OngoingWork.activeCount(mixed, conversationID: here) == 3, "Running work counts toward the badge")

        let conversations = [Conversation(id: here, title: "Workshop plans", messages: [], updatedAt: Date()),
                             Conversation(id: there, title: "Market watch", messages: [], updatedAt: Date())]
        let groups = OngoingWork.groups(mixed, conversations: conversations)
        try require(groups.map(\.title) == ["Workshop plans", "Market watch", "Other"], "Groups follow the newest work, unknown last")
        try require(groups.last?.conversationID == nil && groups.last?.items.map(\.id) == [orphan.id.uuidString],
                    "An unknown conversation's work goes under Other")

        let taskID = cases[2].0.id.uuidString
        let card = NativeTaskCardPresentation(id: taskID, title: "Working", status: .working, milestone: "")
        let owner = Message(role: .assistant, text: "", displayBlocks: [.taskCard(card)])
        let origin = Message(role: .assistant, text: "")
        try require(OngoingWork.owningMessageID(taskID: taskID, fallback: origin.id, in: [origin, owner]) == owner.id,
                    "The message showing the task card owns it")
        try require(OngoingWork.owningMessageID(taskID: taskID, fallback: origin.id, in: [origin]) == origin.id,
                    "The originating reply owns a task with no card yet")
        try require(OngoingWork.owningMessageID(taskID: taskID, fallback: UUID(), in: [origin]) == nil,
                    "Missing messages own nothing")

        try require(OngoingWork.revealApplies(origin: here, selectedConversationID: here, generation: 4, latestGeneration: 4),
                    "A reveal applies while its chat is selected and it is the latest selection")
        try require(!OngoingWork.revealApplies(origin: here, selectedConversationID: there, generation: 4, latestGeneration: 4),
                    "A reveal stops once another chat is selected")
        try require(!OngoingWork.revealApplies(origin: here, selectedConversationID: here, generation: 4, latestGeneration: 5),
                    "A newer selection supersedes an older reveal")
        try require(!OngoingWork.revealApplies(origin: here, selectedConversationID: here, generation: 4, latestGeneration: 4, cancelled: true),
                    "A cancelled reveal does nothing")

        let store = OngoingWorkFixture.store()
        let shotConversation = try store.selectedID ?? { throw NativeTaskFixture.Failure.assertion("The fixture selects a chat") }()
        store.conversations.append(Conversation(id: there, title: "Market watch", messages: [], updatedAt: Date()))
        let other = try fixture.reference(conversationID: there, title: "Elsewhere", state: "running")
        store.nativeTaskReferences.append(other)
        let first = try store.nativeTaskReferences.first ?? { throw NativeTaskFixture.Failure.assertion("The fixture has work") }()
        store.revealOngoingWork(first)
        let firstGeneration = store.taskRevealGeneration
        try require(store.pendingTaskReveal == first.id.uuidString && store.selectedID == shotConversation,
                    "Selecting work in the open chat queues its reveal")
        store.revealOngoingWork(other)
        try require(store.selectedID == there && store.pendingTaskReveal == other.id.uuidString,
                    "Selecting work in another chat opens that chat and queues its reveal")
        try require(!OngoingWork.revealApplies(origin: shotConversation, selectedConversationID: store.selectedID,
                                               generation: firstGeneration, latestGeneration: store.taskRevealGeneration),
                    "The first chat's delayed reveal no longer applies after switching")
        let unknownGeneration = store.taskRevealGeneration
        store.revealOngoingWork(orphan)
        try require(store.taskRevealGeneration == unknownGeneration && store.selectedID == there,
                    "Work from an unknown chat changes nothing")
    }
}
