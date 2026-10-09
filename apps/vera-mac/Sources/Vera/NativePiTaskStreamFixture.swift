import Foundation
import VeraAssistantUI

actor PiTaskStreamHTTPProbe {
    private var snapshots = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.httpMethod == nil || request.httpMethod == "GET", request.url?.path == "/tasks" { snapshots += 1 }
        return try await PiOwnedHTTP.send(request)
    }
    func snapshotCount() -> Int { snapshots }
}

final class PiTaskStreamCursorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func open(_ request: URLRequest) -> PiOwnedTaskEventConnection {
        lock.withLock { values.append(request.value(forHTTPHeaderField: "Last-Event-ID") ?? "missing") }
        return PiOwnedTaskEventTransport.live.open(request)
    }
    func cursors() -> [String] { lock.withLock { values } }
}

@MainActor
enum NativePiTaskStreamFixture {
    static var stage = "startup"
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PiBrokerError.unavailable
    }

    static func task(_ session: AssistantSession, state: String, excluding: Set<String> = []) async throws -> AssistantSessionTask {
        try await wait { session.tasks.contains { $0.state == state && !excluding.contains($0.id) } }
        guard let task = session.tasks.first(where: { $0.state == state && !excluding.contains($0.id) }) else { throw PiBrokerError.invalid }
        return task
    }

    static func submit(_ session: AssistantSession, text: String) async throws -> AssistantSessionTask {
        let previous = Set(session.tasks.map(\.id))
        session.setDraft(text)
        try piCheck(session.canSend)
        await session.send()
        try piCheck(session.pendingID == nil)
        return try await task(session, state: "needs_decision", excluding: previous)
    }

    static func projection(_ presentation: NativePiPresentation) throws -> [String] {
        guard let session = presentation.session, let conversation = presentation.conversation else { throw PiBrokerError.invalid }
        var projected: [String] = []
        for task in session.tasks {
            let anchors = session.messages.filter { !$0.isUser && !$0.id.hasPrefix("task:") && $0.taskIDs.contains(task.id) }
            try piCheck(anchors.count == 1 && task.originatingMessageID != nil)
            let anchor = NativePiPresentation.messageID(conversation: session.id, source: anchors[0].id)
            try piCheck(presentation.tasks(for: anchor).filter { $0.id == task.id }.count == 1)
            let attached = conversation.messages.filter { presentation.tasks(for: $0.id).contains { $0.id == task.id } }
            try piCheck(attached.count == 1 && attached[0].id == anchor)
            let cards = attached[0].displayBlocks.filter { if case .taskCard(let value) = $0 { return value.id == task.id }; return false }
            try piCheck(cards.count == 1)
            projected.append(anchor.uuidString.lowercased() + ":" + task.id)
        }
        let cards = conversation.messages.flatMap(\.displayBlocks).filter { if case .taskCard = $0 { return true }; return false }
        let artifacts = conversation.messages.flatMap(\.displayBlocks).filter { if case .artifact = $0 { return true }; return false }
        try piCheck(cards.count == session.tasks.count && artifacts.count == 1)
        return projected.sorted()
    }

    static func replay(_ owner: NativePiAppOwner, after: Int64, through: Int64) async throws -> [AssistantTaskEvent] {
        try await NativeInferenceDeadline.run(seconds: 5) {
            let stream = try await owner.events(after: after)
            var result: [AssistantTaskEvent] = []
            for try await event in stream {
                result.append(event)
                try piCheck(result.count <= 200 && event.id > after)
                if event.id == through { return result }
            }
            throw PiBrokerError.unavailable
        }
    }

    static func quiet(_ probe: PiTaskStreamHTTPProbe) async throws {
        try await Task.sleep(for: .milliseconds(300))
        let before = await probe.snapshotCount()
        try await Task.sleep(for: .milliseconds(2200))
        try piCheck(await probe.snapshotCount() == before)
    }

    static func initial(_ candidate: NativePiCandidate, _ presentation: NativePiPresentation, _ probe: PiTaskStreamHTTPProbe, _ cursors: PiTaskStreamCursorProbe) async throws -> [String: Any] {
        guard let session = presentation.session else { throw PiBrokerError.invalid }
        try piCheck(session.tasks.isEmpty && session.messages.isEmpty)
        stage = "task acceptance"
        let first = try await submit(session, text: "/task Verify addition in this disposable workspace")
        guard let decision = first.decisionID else { throw PiBrokerError.invalid }
        await session.reply(taskID: first.id, decisionID: UUID().uuidString, approved: true)
        try piCheck(session.tasks.first { $0.id == first.id }?.state == "needs_decision")
        stage = "event completion"
        await session.reply(taskID: first.id, decisionID: decision, approved: true)
        _ = try await task(session, state: "running")
        session.setDraft("What are you working on?")
        await session.send()
        try piCheck(session.tasks.first { $0.id == first.id }?.state == "running")
        let completed = try await task(session, state: "completed")
        try piCheck(completed.id == first.id)
        guard let artifact = session.output(taskID: first.id, index: 0) else { throw PiBrokerError.invalid }
        try piCheck(FileManager.default.fileExists(atPath: artifact.path))
        stage = "task controls"
        let canceled = try await submit(session, text: "/task Cancel this separate disposable example")
        await session.stop(taskID: canceled.id)
        try await wait { session.tasks.first { $0.id == canceled.id }?.state == "canceled" }
        let waiting = try await submit(session, text: "/task Keep this separate example waiting for approval")
        try await wait { session.savedEventCursor > 0 }
        stage = "idle event tracking"
        try await quiet(probe)
        try piCheck(cursors.cursors().first == "0")
        stage = "transcript association"
        let cards = try projection(presentation)
        let messages = presentation.conversation!.messages.map { $0.id.uuidString.lowercased() }
        let cursor = session.savedEventCursor
        stage = "HTTP event replay"
        let events = try await replay(candidate.owner, after: 0, through: cursor)
        let ids = events.map(\.id)
        try piCheck(ids == ids.sorted() && Set(ids).count == ids.count && ids.count > 3)
        let repeated = try await replay(candidate.owner, after: ids[0], through: cursor)
        try piCheck(repeated.map(\.id) == Array(ids.dropFirst()))
        do {
            let stream = try await candidate.owner.events(after: Int64.max)
            for try await _ in stream { throw PiBrokerError.invalid }
            throw PiBrokerError.invalid
        } catch AssistantTaskEventError.cursorReset {}
        stage = "cursor reconnect"
        await session.stopEventTracking()
        let connections = cursors.cursors().count
        session.startEventTracking()
        try await quiet(probe)
        try piCheck(cursors.cursors().dropFirst(connections).first == String(cursor))
        try piCheck(session.savedEventCursor == cursor && projection(presentation) == cards)
        try piCheck(presentation.conversation!.messages.map { $0.id.uuidString.lowercased() } == messages)
        let resultID = NativePiPresentation.messageID(conversation: session.id, source: "task:" + first.id)
        try piCheck(presentation.conversation!.messages.filter { $0.id == resultID }.count == 1)
        try piCheck(presentation.tasks(for: resultID).isEmpty)
        return ["assistant_id": candidate.workspace.assistantID.uuidString.lowercased(),
            "conversation_id": session.id.uuidString.lowercased(), "completed_task_id": first.id,
            "canceled_task_id": canceled.id, "waiting_task_id": waiting.id,
            "task_ids": session.tasks.map(\.id).sorted(), "projected_ids": messages, "card_anchors": cards,
            "event_ids": ids, "saved_cursor": cursor, "artifact_path": artifact.path,
            "event_only_completion": true, "idle_snapshot_polling": false,
            "duplicate_cards": 0, "result_deliveries": 1, "cursor_reconnect": true,
            "real_provider_calls": 0, "real_keychain_reads": 0, "visible_launch": false]
    }

    static func reopened(_ candidate: NativePiCandidate, _ presentation: NativePiPresentation, _ probe: PiTaskStreamHTTPProbe, _ cursors: PiTaskStreamCursorProbe, report: [String: Any]) async throws -> [String: Any] {
        guard let session = presentation.session, let ids = report["task_ids"] as? [String],
              let cursor = report["saved_cursor"] as? Int64, let foreign = report["foreign_task_id"] as? String else { throw PiBrokerError.invalid }
        stage = "reopened identity"
        try await wait { session.tasks.map(\.id).sorted() == ids }
        try piCheck(candidate.workspace.assistantID.uuidString.lowercased() == report["assistant_id"] as? String)
        try piCheck(session.id.uuidString.lowercased() == report["conversation_id"] as? String)
        try piCheck(session.savedEventCursor >= cursor && projection(presentation) == report["card_anchors"] as? [String])
        try piCheck(presentation.conversation!.messages.map { $0.id.uuidString.lowercased() } == report["projected_ids"] as? [String])
        for (key, state) in [("completed_task_id", "completed"), ("canceled_task_id", "canceled"), ("waiting_task_id", "needs_decision")] {
            try piCheck(session.tasks.first { $0.id == report[key] as? String }?.state == state)
        }
        stage = "foreign task authority"
        let endpoint = try await candidate.owner.endpoint()
        for action in ["cancel", "decision"] {
            var request = URLRequest(url: endpoint.appendingPathComponent("tasks/\(foreign)/\(action)"))
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["decision_id": UUID().uuidString, "idempotency_key": UUID().uuidString, "reply": ["approved": true]])
            do { _ = try await candidate.owner.http(request); throw PiBrokerError.invalid }
            catch PiBrokerError.unauthorized {}
        }
        stage = "reopened cursor"
        try await quiet(probe)
        try piCheck(cursors.cursors().first == String(cursor))
        try piCheck(await candidate.provider.calls() == 0)
        var result = report
        result["reopened"] = true
        result["saved_cursor"] = session.savedEventCursor
        result["foreign_authority_refused"] = true
        result["fresh_model_calls"] = 0
        result["reopened_request_cursor"] = cursor
        return result
    }

    static func run(_ arguments: [String]) async {
        var arguments = arguments
        let mode = arguments.first == "--hold" || arguments.first == "--reopen" ? arguments.removeFirst() : ""
        var current: NativePiPresentation?
        do {
            let probe = PiTaskStreamHTTPProbe()
            let cursors = PiTaskStreamCursorProbe()
            let candidate = try await NativePiCandidate.create(arguments, httpTransport: { try await probe.send($0) },
                eventTransport: PiOwnedTaskEventTransport(open: { cursors.open($0) }))
            let presentation = NativePiPresentation(factory: {
                NativePiConnection(workspace: candidate.workspace, stop: { await candidate.stop() })
            })
            current = presentation
            let file = candidate.root.url.appendingPathComponent("task-stream-fixture.json")
            var saved: [String: Any]?
            if mode == "--reopen" {
                saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
                try piCheck(candidate.workspace.session.savedEventCursor == saved?["saved_cursor"] as? Int64)
            }
            await presentation.connect()
            guard presentation.session != nil else { throw PiBrokerError.unavailable }
            let report: [String: Any]
            if mode == "--reopen" {
                guard let saved else { throw PiBrokerError.invalid }
                report = try await reopened(candidate, presentation, probe, cursors, report: saved)
            } else {
                report = try await initial(candidate, presentation, probe, cursors)
                try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: file, options: .atomic)
            }
            try NativePiCandidate.verifyNoCredentialFiles(candidate.root.url)
            if mode != "--hold" { await presentation.stop() }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]))
            if mode == "--hold" {
                try await Task.sleep(for: .seconds(30))
                await presentation.stop()
                throw PiBrokerError.unavailable
            }
        } catch {
            if let current { await current.stop() }
            FileHandle.standardError.write(Data("Native task stream fixture failed during \(stage): \(type(of: error))\n".utf8))
            exit(1)
        }
    }
}
