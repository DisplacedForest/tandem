import Foundation

struct NativeTaskEvent: Decodable, Equatable, Sendable {
    let id: Int64
    let taskID: String

    private enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
    }
}

enum NativeTaskEventError: Error, Equatable {
    case oversizedFrame, invalidEncoding, invalidEvent, wrongTask
}

struct NativeTaskEventDecoder: Sendable {
    static let maximumFrameBytes = 65536
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?
    private var eventID: String?
    private var frameBytes = 0
    private var previousWasCR = false

    mutating func consume(_ data: Data) throws -> [NativeTaskEvent] {
        var events: [NativeTaskEvent] = []
        for byte in data {
            if let event = try consume(byte: byte) { events.append(event) }
        }
        return events
    }

    mutating func consume(byte: UInt8) throws -> NativeTaskEvent? {
        if byte == 10 && previousWasCR {
            previousWasCR = false
            return nil
        }
        previousWasCR = byte == 13
        frameBytes += 1
        guard frameBytes <= Self.maximumFrameBytes else { throw NativeTaskEventError.oversizedFrame }
        if byte == 10 || byte == 13 { return try endLine() }
        line.append(byte)
        return nil
    }

    private mutating func endLine() throws -> NativeTaskEvent? {
        guard let text = String(bytes: line, encoding: .utf8) else { throw NativeTaskEventError.invalidEncoding }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            defer {
                dataLines.removeAll(keepingCapacity: true)
                eventName = nil
                eventID = nil
                frameBytes = 0
            }
            guard !dataLines.isEmpty, eventName == "task" else { return nil }
            guard let rawID = eventID, let id = Int64(rawID), id > 0,
                  let bytes = dataLines.joined(separator: "\n").data(using: .utf8),
                  let event = try? JSONDecoder().decode(NativeTaskEvent.self, from: bytes),
                  event.id == id, !event.taskID.isEmpty, event.taskID.utf8.count <= 200 else {
                throw NativeTaskEventError.invalidEvent
            }
            return event
        }
        if text.hasPrefix(":") { return nil }
        let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(pieces[0])
        var value = pieces.count > 1 ? String(pieces[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": eventName = value
        case "id": eventID = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }
}

struct NativeTaskSnapshotTicket: Equatable, Sendable {
    let epoch: UInt64
    let cursor: Int64
}

struct NativeTaskReconciliation: Sendable {
    let taskID: String
    private(set) var appliedCursor: Int64
    private(set) var terminal: Bool
    private(set) var needsRefresh = true
    private var pendingCursor: Int64
    private var epoch: UInt64 = 0
    private var active: NativeTaskSnapshotTicket?

    init(taskID: String, cursor: Int64 = 0, terminal: Bool = false) {
        self.taskID = taskID
        appliedCursor = max(0, cursor)
        pendingCursor = max(0, cursor)
        self.terminal = terminal
    }

    mutating func receive(_ event: NativeTaskEvent) throws {
        guard event.taskID == taskID else { throw NativeTaskEventError.wrongTask }
        guard event.id > appliedCursor else { return }
        pendingCursor = max(pendingCursor, event.id)
        needsRefresh = true
    }

    mutating func beginFetch() -> NativeTaskSnapshotTicket? {
        guard active == nil, needsRefresh else { return nil }
        epoch &+= 1
        let ticket = NativeTaskSnapshotTicket(epoch: epoch, cursor: pendingCursor)
        active = ticket
        return ticket
    }

    func canApply(_ ticket: NativeTaskSnapshotTicket, terminal incomingTerminal: Bool) -> Bool {
        active == ticket && (!terminal || incomingTerminal)
    }

    @discardableResult
    mutating func committed(_ ticket: NativeTaskSnapshotTicket, terminal incomingTerminal: Bool) -> Bool {
        guard canApply(ticket, terminal: incomingTerminal) else { return false }
        appliedCursor = max(appliedCursor, ticket.cursor)
        terminal = incomingTerminal
        active = nil
        needsRefresh = pendingCursor > appliedCursor
        return true
    }

    mutating func failed(_ ticket: NativeTaskSnapshotTicket) {
        guard active == ticket else { return }
        active = nil
        needsRefresh = true
    }

    mutating func invalidate() {
        epoch &+= 1
        active = nil
        needsRefresh = true
    }

    mutating func resetCursor() {
        invalidate()
        appliedCursor = 0
        pendingCursor = 0
    }
}
