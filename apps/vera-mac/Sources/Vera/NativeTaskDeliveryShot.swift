import Foundation

@MainActor
enum NativeTaskDeliveryShot {
    static let views: Set<String> = ["result-message", "result-lines", "result-failed", "result-scheduled",
                                     "result-document", "result-chat", "result-two-at-once"]

    static let request = "Research how three public libraries provide quiet reading spaces. Use their official websites and produce a short comparison with source links, titled Quiet reading spaces. Do not contact anyone, create schedules, or save preferences."
    static let reply = "I'll compare quiet reading spaces at three public libraries using their official websites."

    static let sources: [[String: Any]] = [
        ["n": 1, "title": "Boston Public Library", "url": "https://www.bpl.org/locations/central/"],
        ["n": 2, "title": "Seattle Public Library", "url": "https://www.spl.org/hours-and-locations/central-library"],
        ["n": 3, "title": "Chicago Public Library", "url": "https://www.chipublib.org/locations/34/"],
    ]

    static let report = """
        - **Boston Public Library, Bates Hall:** A dedicated reading and quiet-study room with long tables, green lamps and a vaulted ceiling. It offers the most traditional reading-room setting of the three. [1]
        - **Seattle Central Library, Level 10 Reading Room:** A designated quiet place to read, work or study, with a high-floor view and Seattle history collections nearby. [2]
        - **Chicago's Harold Washington Library Center, Winter Garden:** A glass-roofed, naturally lit space for study and quiet discussion rather than strictly silent reading. The library notes that private events can occasionally close it. [3]

        ## Sources
        [1] Boston Public Library: https://www.bpl.org/locations/central/
        [2] Seattle Public Library: https://www.spl.org/hours-and-locations/central-library
        [3] Chicago Public Library: https://www.chipublib.org/locations/34/
        """

    static let scheduledReport = "Today's research: two credential-leak advisories for the command-line model tool are fixed in version 0.37.2 [1]. I found no affected installation in the places I checked; other machines weren't checked.\n\nThe distribution maintainers also confirmed the fixes are in the regular update archive [2], which settles yesterday's open question."

    static func researchReference(conversationID: String, title: String, report: String, sources: [[String: Any]]) -> NativeTaskReference? {
        try? OngoingWorkFixture.reference(conversationID: conversationID, title: title, state: "completed",
            result: ["kind": "research_report", "query": title, "report": report, "sources": sources])
    }

    static func delivered(_ reference: NativeTaskReference?, scheduled: Bool = false, at: Date) -> Message? {
        guard let reference, let snapshot = reference.snapshot else { return nil }
        return NativeTaskDelivery.resultMessage(reference: reference, snapshot: snapshot, scheduled: scheduled, now: at)
    }

    static func messages(view: String, conversationID: String) -> [Message] {
        let start = Date(timeIntervalSince1970: 1_762_950_000)
        let ask = Message(role: .user, text: request, createdAt: start)
        let answer = Message(role: .assistant, text: reply, createdAt: start.addingTimeInterval(4))
        let research = researchReference(conversationID: conversationID, title: "Quiet reading spaces", report: report, sources: sources)
        switch view {
        case "result-lines":
            let first = NativeTaskDelivery.lineMessage(referenceID: UUID(),
                text: "Boston's and Seattle's pages describe their reading rooms clearly. I'm still checking Chicago's.", now: start.addingTimeInterval(90))
            let second = NativeTaskDelivery.lineMessage(referenceID: UUID(),
                text: "Chicago's Winter Garden allows quiet discussion, so I'm noting that it isn't strictly silent.", now: start.addingTimeInterval(200))
            return [ask, answer, first, second] + [delivered(research, at: start.addingTimeInterval(320))].compactMap { $0 }
        case "result-failed":
            let failed = try? OngoingWorkFixture.reference(conversationID: conversationID, title: "Quiet reading spaces", state: "failed")
            let pages = sources.prefix(2).compactMap { source -> NativeTaskSource? in
                guard let n = source["n"] as? Int, let title = source["title"] as? String, let url = source["url"] as? String else { return nil }
                return NativeTaskSource(n: n, title: title, url: url)
            }
            let text = failed?.snapshot.map { snapshot -> String in
                let checkpoint = try? JSONDecoder().decode(NativeTaskCheckpoint.self,
                    from: NativeTaskClient.canonical(["sources": pages.map { ["n": $0.n, "title": $0.title, "url": $0.url] }]))
                let withPages = checkpoint.map { NativeTaskSnapshot(id: snapshot.id, workerType: snapshot.workerType, payload: snapshot.payload,
                    state: .failed, checkpoint: $0, result: nil, decision: nil, cancelRequested: false, generation: 1, updatedAt: 1) } ?? snapshot
                return NativeTaskDelivery.failureText(snapshot: withPages, workerType: "research", subject: "Quiet reading spaces")
            } ?? "I couldn't finish this."
            var message = NativeTaskDelivery.lineMessage(referenceID: UUID(), text: text, now: start.addingTimeInterval(300))
            message.contentType = .deliveredResult
            message.delivery = NativeDeliveredMessage(referenceID: UUID().uuidString, kind: NativeDeliveredMessage.result,
                                                      title: "Quiet reading spaces", finished: false)
            return [ask, answer, message]
        case "result-two-at-once":
            let hoursAsk = Message(role: .user, text: "Which of those libraries stay open late on weeknights? Check their official hours.", createdAt: start.addingTimeInterval(20))
            let hoursReply = Message(role: .assistant, text: "I'll check which of the three libraries stay open late on weeknights.", createdAt: start.addingTimeInterval(24))
            let readingLine = NativeTaskDelivery.lineMessage(referenceID: UUID(),
                text: "Boston's and Seattle's pages describe their quiet reading rooms clearly. I'm still checking Chicago's.", now: start.addingTimeInterval(90))
            let hoursLine = NativeTaskDelivery.lineMessage(referenceID: UUID(),
                text: "Seattle's weeknight hours changed this fall, so I'm reading its current hours page.", now: start.addingTimeInterval(100))
            let hoursReport = "- **Boston Public Library, Central Library:** Open until 8 p.m. Monday through Thursday. [1]\n- **Seattle Central Library:** Open until 8 p.m. Monday through Thursday. [2]\n- **Chicago's Harold Washington Library Center:** Open until 7 p.m. Monday through Thursday. [3]"
            let hours = researchReference(conversationID: conversationID, title: "Late weeknight hours", report: hoursReport, sources: sources)
            return [ask, answer, hoursAsk, hoursReply, readingLine, hoursLine]
                + [delivered(hours, at: start.addingTimeInterval(200)), delivered(research, at: start.addingTimeInterval(300))].compactMap { $0 }
        case "result-scheduled":
            let earlier = Message(role: .assistant, text: "Time for the evening check on the seedlings.", createdAt: start)
            let scheduled = researchReference(conversationID: conversationID, title: "Daily advisory check", report: scheduledReport,
                sources: [["n": 1, "title": "Advisory notice", "url": "https://example.org/advisories"],
                          ["n": 2, "title": "Archive notice", "url": "https://example.org/archive"]])
            var origin = Message(role: .user, text: "Check for new advisories every morning.", createdAt: start.addingTimeInterval(60))
            origin.contentType = .runOrigin
            var empty = Message(role: .assistant, text: "", createdAt: start.addingTimeInterval(60))
            empty.contentType = .runOrigin
            return [earlier, origin, empty] + [delivered(scheduled, scheduled: true, at: start.addingTimeInterval(120))].compactMap { $0 }
        case "result-document":
            let documentAsk = Message(role: .user, text: "Write me a one-page reading plan for the winter, something I can keep.", createdAt: start)
            let documentReply = Message(role: .assistant, text: "I'll write a one-page winter reading plan you can keep.", createdAt: start.addingTimeInterval(4))
            let reference = try? OngoingWorkFixture.reference(conversationID: conversationID, title: "Winter reading plan", workerType: "document",
                state: "completed", result: OngoingWorkFixture.documentResult("Winter reading plan"))
            return [documentAsk, documentReply] + [delivered(reference, at: start.addingTimeInterval(200))].compactMap { $0 }
        default:
            return [ask, answer] + [delivered(research, at: start.addingTimeInterval(300))].compactMap { $0 }
        }
    }

    static func seed(_ store: ChatStore, view: String) -> AppSection {
        if view == "result-chat" {
            let id = "delivery-shot-chat"
            let conversation = Conversation(id: id, title: "Quiet reading spaces", messages: messages(view: "result-message", conversationID: id),
                                            updatedAt: Date())
            store.conversations.insert(conversation, at: 0)
            store.selectedID = id
            store.section = .chat
            return .chat
        }
        NativeDotShotFixture.populate(store, paused: false, setupCompleted: true)
        if let id = store.veraThreadID, let index = store.conversations.firstIndex(where: { $0.id == id }) {
            store.conversations[index].messages = messages(view: view, conversationID: id)
        }
        store.section = .vera
        return .vera
    }
}
