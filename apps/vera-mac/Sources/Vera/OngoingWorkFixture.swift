import Foundation

@MainActor
enum OngoingWorkFixture {
    static func reference(conversationID: String, title: String, workerType: String = "research",
                          state: String?, result: [String: Any]? = nil, decision: [String: Any]? = nil,
                          cancelRequested: Bool = false, updatedAt: Double = 1.0,
                          request custom: NativeResearchTaskRequest? = nil) throws -> NativeTaskReference {
        let request = try custom ?? NativeResearchTaskRequest(objective: title, deliverables: ["A short summary"],
                                                              workerType: workerType, title: title)
        let create = NativeTaskCreateRequest(request: request, idempotencyKey: UUID())
        let body = try create.encoded()
        let remote = UUID().uuidString
        let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!)
        var reference = NativeTaskReference(
            id: UUID(),
            origin: NativeTaskOrigin(conversationID: conversationID, userMessageID: UUID(), assistantMessageID: UUID()),
            engine: engine, request: request, createRequest: create, body: body, profile: nil,
            remoteTaskID: remote, deliveryState: .accepted, cancelRequested: cancelRequested,
            cancelDelivered: false, lastDeliveryError: nil, snapshot: nil)
        guard let state else { return reference }
        let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        var object: [String: Any] = [
            "id": remote, "worker_type": workerType, "payload": envelope["payload"] ?? [:],
            "state": state, "checkpoint": [:], "cancel_requested": false,
            "generation": 1, "updated_at": updatedAt,
        ]
        object["result"] = result
        object["decision"] = decision
        reference.snapshot = try JSONDecoder().decode(NativeTaskSnapshot.self, from: NativeTaskClient.canonical(object))
        return reference
    }

    static func documentResult(_ title: String) -> [String: Any] {
        ["kind": "document_report", "query": title, "report": "# \(title)\n\nThe plan is ready to read.", "sources": []]
    }

    static let decision: [String: Any] = [
        "id": "choice", "prompt": "The report didn't cite its sources correctly. Retry this step?", "choices": ["retry"],
    ]

    static func store() -> ChatStore {
        let store = ChatStore()
        let conversation = Conversation(id: "ongoing-work-shot", title: "Workshop plans", messages: [], updatedAt: Date())
        store.conversations.insert(conversation, at: 0)
        store.selectedID = conversation.id
        let references = [
            try? reference(conversationID: conversation.id, title: "Compare insulation options",
                           state: "needs_decision", decision: decision),
            try? reference(conversationID: conversation.id, title: "Lumber prices this month", state: "running"),
            try? reference(conversationID: conversation.id, title: "Workshop plan", workerType: "document",
                           state: "completed", result: documentResult("Workshop plan")),
        ]
        store.nativeTaskReferences = references.compactMap { $0 }
        return store
    }

    static let changedAssignment = "Compare quiet reading spaces at two public libraries using their official websites."
    static let changedBefore = "Compare quiet reading spaces at three public libraries using their official websites."

    static func asideStore() -> ChatStore {
        let store = ChatStore()
        let conversation = Conversation(id: "aside-work-shot", title: "Companion", messages: [], updatedAt: Date())
        store.conversations.insert(conversation, at: 0)
        store.selectedID = conversation.id
        let changed = try? ChatStore.companionRequest(changedAssignment, connectedToolIDs: nil,
                                                      carried: NativeCompanionCarried(request: changedBefore))
        let references = [
            try? reference(conversationID: conversation.id, title: "Quiet reading spaces", workerType: "companion", state: "running"),
            try? reference(conversationID: conversation.id, title: "New Indy restaurants", workerType: "companion", state: "paused"),
            try? reference(conversationID: conversation.id, title: "Library hours", workerType: "companion", state: "running",
                           request: changed),
            try? reference(conversationID: conversation.id, title: "Garden notes", workerType: "companion", state: "archived_later"),
        ]
        store.nativeTaskReferences = references.compactMap { $0 }
        return store
    }

    static func asideItems(_ store: ChatStore) -> [CompanionActivityItem] {
        store.nativeTaskReferences.enumerated().compactMap { index, reference in
            guard let display = try? NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot) else { return nil }
            return CompanionOverviewModel.taskItem(card: display.card, reference: reference, decision: nil, hasArtifact: false,
                                                   date: Date().addingTimeInterval(-Double(index + 1) * 120))
        }
    }
}
