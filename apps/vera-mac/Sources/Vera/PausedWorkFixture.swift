import Foundation

enum PausedWorkFixture {
    static let assignment = "Compare the reading rooms at the public libraries downtown"
    static let longAssignment = "Compare the quiet reading rooms at every public library branch downtown, including weekday evening hours, how many seats each one has, whether laptops and phone calls are allowed, and which ones need a library card at the door"
    static let decisionID = "cap-1"
    static let oldPrompt = CompanionSavedText.marker + " has used this run's working time and saved its progress. Keep going, or finish with what it has?"

    static let branches = ["Central Library", "Riverside Branch", "Hillcrest Branch", "Market Street Branch", "Harbor Branch",
                           "Northgate Branch", "Elm Park Branch", "Westfield Branch", "Old Town Branch", "Lakeside Branch",
                           "Southpoint Branch", "Maple Grove Branch", "Union Square Branch", "Cedar Hill Branch", "Brookside Branch",
                           "Station Road Branch", "Linden Row Branch", "Mill Lane Branch", "Ferry Point Branch", "Orchard Branch"]

    static func source(_ n: Int, read: Bool?) -> [String: Any] {
        let name = branches[(n - 1) % branches.count]
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        var entry: [String: Any] = ["n": n, "title": "\(name) reading room", "url": "https://library.example.org/\(slug)/reading-room"]
        if let read { entry["read"] = read }
        return entry
    }

    static func checkpoint(read: Int, searchOnly: Int, unknown: Int = 0, earlier: Bool = false, interleave: Bool = true) -> [String: Any] {
        var sources: [[String: Any]] = []
        var next = 1
        var readLeft = read
        var searchLeft = searchOnly
        while readLeft > 0 || searchLeft > 0 {
            if readLeft > 0 { sources.append(source(next, read: true)); next += 1; readLeft -= 1 }
            if searchLeft > 0, interleave || readLeft == 0 { sources.append(source(next, read: false)); next += 1; searchLeft -= 1 }
        }
        for _ in 0..<unknown {
            sources.append(source(next, read: nil))
            next += 1
        }
        var object: [String: Any] = ["pending": ["kind": "cap"], "sources": sources, "rounds": 8, "calls": 8]
        if earlier { object["effects"] = [["title": "Save a note: reading-rooms.md", "outcome": "done"]] }
        return object
    }

    static func origin(_ repository: LocalChatRepository, conversationID: String, assignment: String) throws -> NativeTaskOrigin {
        if try repository.listConversations().first(where: { $0.id == conversationID }) == nil {
            try repository.saveConversation(Conversation(id: conversationID, title: "Companion", messages: [], updatedAt: Date()))
        }
        let user = Message(role: .user, text: assignment)
        let assistant = Message(role: .assistant, text: "I'll look into that in the background.")
        let ordinal = try repository.messages(conversationID: conversationID).count
        try repository.saveMessage(user, conversationID: conversationID, ordinal: ordinal)
        try repository.saveMessage(assistant, conversationID: conversationID, ordinal: ordinal + 1)
        return NativeTaskOrigin(conversationID: conversationID, userMessageID: user.id, assistantMessageID: assistant.id)
    }

    static func snapshot(_ reference: NativeTaskReference, remote: String, state: String = "needs_decision",
                         checkpoint: [String: Any], decision: [String: Any]?) throws -> NativeTaskSnapshot {
        let body = try JSONSerialization.jsonObject(with: reference.body) as? [String: Any] ?? [:]
        var object: [String: Any] = [
            "id": remote, "worker_type": "companion", "payload": body["payload"] ?? [:], "state": state,
            "checkpoint": checkpoint, "cancel_requested": false, "generation": 1, "updated_at": 1.0,
        ]
        object["decision"] = decision
        return try JSONDecoder().decode(NativeTaskSnapshot.self, from: NativeTaskClient.canonical(object))
    }

    static var decision: [String: Any] { ["id": decisionID, "prompt": oldPrompt, "choices": ["continue", "finish"]] }

    static func card(_ update: NativeTaskMessageUpdate?) -> NativeTaskCardPresentation? {
        for block in update?.blocks ?? [] {
            if case .taskCard(let card) = block { return card }
        }
        return nil
    }

    static func seed(_ repository: LocalChatRepository, conversationID: String = UUID().uuidString, assignment: String = assignment,
                     checkpoint: [String: Any], decision: [String: Any]? = decision, answer: String? = nil,
                     engine: URL = URL(string: "https://engine.test/api")!) throws -> (reference: NativeTaskReference, card: NativeTaskCardPresentation) {
        let origin = try origin(repository, conversationID: conversationID, assignment: assignment)
        let request = try NativeResearchTaskRequest(dot: NativeCompanionTaskPayload(assignment: assignment, mode: "manual"))
        let prepared = try repository.prepareTaskReference(origin: origin, engine: try NativeTaskEngineIdentity(engine), request: request, profile: nil)
        let waiting = try snapshot(prepared, remote: UUID().uuidString, checkpoint: checkpoint, decision: decision)
        let reference = try repository.acknowledgeTaskReference(id: prepared.id, snapshot: waiting)
        var update = try repository.projectTask(id: reference.id, snapshot: waiting)
        if let answer, let id = waiting.decision?.id {
            _ = try repository.prepareTaskDecision(id: reference.id, decisionID: id, choice: answer)
            update = try repository.projectTask(id: reference.id, snapshot: waiting)
        }
        guard let card = card(update) else { throw NativeTaskFixture.Failure.assertion("The waiting work projects a card") }
        return (reference, card)
    }
}
