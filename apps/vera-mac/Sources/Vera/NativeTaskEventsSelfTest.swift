import Foundation

enum NativeTaskEventsSelfTest {
    static func run() throws {
        let frame = "id: 12\r\nevent: task\r\ndata: {\"id\":12,\"task_id\":\"task-one\",\"data\":{\"title\":\"Café\"}}\r\n\r\n"
        var decoder = NativeTaskEventDecoder()
        var decoded: [NativeTaskEvent] = []
        for byte in frame.utf8 { decoded += try decoder.consume(Data([byte])) }
        try expect(decoded == [NativeTaskEvent(id: 12, taskID: "task-one")], "Byte-split SSE must preserve UTF-8 and CRLF")
        try expect(try decoder.consume(Data(": keepalive\n\n".utf8)).isEmpty, "Keepalives must not advance task cursors")
        let multiple = "id: 13\nevent: task\ndata: {\"id\":13,\ndata: \"task_id\":\"task-one\"}\n\n"
        try expect(try decoder.consume(Data(multiple.utf8)) == [NativeTaskEvent(id: 13, taskID: "task-one")],
                   "Multiline SSE data must parse as one event")
        let escapedUnicode = String(repeating: "\\ud83c\\udf33", count: 4000)
        let expanded = "id: 14\nevent: task\ndata: {\"id\":14,\"task_id\":\"task-one\",\"data\":\"\(escapedUnicode)\"}\n\n"
        try expect(try decoder.consume(Data(expanded.utf8)) == [NativeTaskEvent(id: 14, taskID: "task-one")],
                   "JSON escaping of a bounded Unicode event must fit the frame budget")
        for invalid in [
            "id: 14\nevent: task\ndata: {\"id\":15,\"task_id\":\"task-one\"}\n\n",
            "id: -1\nevent: task\ndata: {\"id\":-1,\"task_id\":\"task-one\"}\n\n",
            "id: 14\nevent: task\ndata: {\"id\":14,\"task_id\":\"\"}\n\n",
        ] {
            var invalidDecoder = NativeTaskEventDecoder()
            try expect((try? invalidDecoder.consume(Data(invalid.utf8))) == nil,
                       "Invalid events must not move replay cursors")
        }
        var oversized = NativeTaskEventDecoder()
        try expect((try? oversized.consume(Data(repeating: 120, count: NativeTaskEventDecoder.maximumFrameBytes + 1))) == nil,
                   "An unterminated frame must have a memory bound")
        var state = NativeTaskReconciliation(taskID: "task-one", cursor: 10)
        try state.receive(NativeTaskEvent(id: 12, taskID: "task-one"))
        guard let first = state.beginFetch() else { throw failure("First snapshot fetch missing") }
        try expect(state.beginFetch() == nil, "Snapshot fetches must serialize per task")
        try state.receive(NativeTaskEvent(id: 13, taskID: "task-one"))
        try expect(state.appliedCursor == 10, "Received events alone must not advance persisted progress")
        try expect(state.committed(first, terminal: false), "A current snapshot should apply")
        try expect(state.appliedCursor == 12 && state.needsRefresh, "An event received during GET needs another snapshot")
        guard let second = state.beginFetch() else { throw failure("Follow-up snapshot fetch missing") }
        state.invalidate()
        try expect(!state.canApply(second, terminal: false), "A late GET must not restore an old user decision")
        guard let current = state.beginFetch() else { throw failure("Authoritative refresh missing") }
        try expect(state.committed(current, terminal: true), "Completion should apply once persisted")
        try state.receive(NativeTaskEvent(id: 11, taskID: "task-one"))
        try expect(!state.needsRefresh, "Replayed older events must be ignored")
        state.invalidate()
        guard let stale = state.beginFetch() else { throw failure("Terminal refresh missing") }
        try expect(!state.canApply(stale, terminal: false), "A terminal snapshot must not regress")
        state.failed(stale)
        state.resetCursor()
        try expect(state.appliedCursor == 0 && state.needsRefresh && state.terminal,
                   "Cursor reset must preserve cached terminal evidence")
        try expect((try? state.receive(NativeTaskEvent(id: 99, taskID: "other-task"))) == nil,
                   "A different task's event must not advance this subscription")
        var failedWrite = NativeTaskReconciliation(taskID: "task-one", cursor: 10)
        try failedWrite.receive(NativeTaskEvent(id: 15, taskID: "task-one"))
        guard let unpersisted = failedWrite.beginFetch() else { throw failure("Persistence fixture fetch missing") }
        failedWrite.failed(unpersisted)
        try expect(failedWrite.appliedCursor == 10, "A failed projection write must retain the old replay cursor")
        guard let retry = failedWrite.beginFetch() else { throw failure("Persistence retry missing") }
        try expect(retry.cursor == 15 && !failedWrite.canApply(unpersisted, terminal: false),
                   "Retry must preserve pending progress while rejecting the abandoned response")
        try streamBatches()
    }

    private static func streamBatches() throws {
        var stream = NativeTaskStreamProgress(cursor: 10)
        let connection = stream.replaceConnection()
        for id in 11...18 {
            stream.receive(NativeTaskEvent(id: Int64(id), taskID: "task-\(id)"), enrolled: true, connection: connection)
        }
        stream.receive(NativeTaskEvent(id: 19, taskID: "other-task"), enrolled: false, connection: connection)
        guard let batch = stream.beginBatch() else { throw failure("Global stream batch missing") }
        try expect(batch.cursor == 19 && batch.tasks.count == 8,
                   "One stream must coalesce more than six enrolled tasks and skip unrelated tasks")
        try expect(stream.beginBatch() == nil && !stream.canCommit(batch),
                   "The global cursor must wait for every projection in its batch")
        for id in 11...17 { stream.acknowledge(taskID: "task-\(id)", in: batch) }
        stream.receive(NativeTaskEvent(id: 20, taskID: "task-11"), enrolled: true, connection: connection)
        try expect(!stream.committed(batch) && stream.appliedCursor == 10,
                   "A failed projection must prevent acknowledgement of later stream events")
        try expect(stream.remaining(in: batch) == ["task-18": 18],
                   "Only unpersisted projections should need another snapshot")
        stream.acknowledge(taskID: "task-18", in: batch)
        try expect(stream.committed(batch) && stream.appliedCursor == 19,
                   "Persisted projections may advance the global cursor to the captured watermark")
        guard let next = stream.beginBatch() else { throw failure("Next global batch missing") }
        try expect(next.cursor == 20 && next.tasks == ["task-11": 20],
                   "Events arriving during a batch must remain pending for the next snapshot")
        var restarted = NativeTaskStreamProgress(cursor: 10)
        let restartedConnection = restarted.replaceConnection()
        restarted.receive(NativeTaskEvent(id: 11, taskID: "task-11"), enrolled: true, connection: restartedConnection)
        try expect(restarted.beginBatch()?.tasks == ["task-11": 11],
                   "Restart before cursor persistence must replay already written projections safely")
        stream.resetCursor()
        stream.acknowledge(taskID: "task-11", in: next)
        try expect(!stream.committed(next) && stream.appliedCursor == 0,
                   "An old batch must not restore a cursor after a server reset")
        stream.receive(NativeTaskEvent(id: 100, taskID: "task-11"), enrolled: true, connection: connection)
        try expect(stream.receivedCursor == 0, "A replaced connection must not inject late events")
        let replacement = stream.replaceConnection()
        stream.receive(NativeTaskEvent(id: 1, taskID: "task-11"), enrolled: true, connection: replacement)
        guard let replacementBatch = stream.beginBatch() else { throw failure("Replacement connection batch missing") }
        _ = stream.replaceConnection()
        stream.acknowledge(taskID: "task-11", in: replacementBatch)
        try expect(!stream.committed(replacementBatch) && stream.appliedCursor == 0,
                   "A canceled connection's snapshot callback must not advance the durable cursor")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "NativeTaskEventsSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
