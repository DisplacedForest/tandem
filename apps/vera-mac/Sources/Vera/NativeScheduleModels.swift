import Foundation

enum NativeScheduleOwner: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case dot, conversation

    var title: String {
        switch self {
        case .dot: return "Vera thread"
        case .conversation: return "Its own chat"
        }
    }
}

enum NativeScheduleCadence: Codable, Equatable, Hashable, Sendable {
    case daily(minuteOfDay: Int)
    case weekdays(minuteOfDay: Int)
    case weekly(weekday: Int, minuteOfDay: Int)
    case everyHours(Int)
    case once(Date)

    static let maximumHours = 168

    private enum CodingKeys: String, CodingKey { case kind, minute, weekday, hours, at }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "daily": self = .daily(minuteOfDay: try container.decode(Int.self, forKey: .minute))
        case "weekdays": self = .weekdays(minuteOfDay: try container.decode(Int.self, forKey: .minute))
        case "weekly":
            self = .weekly(weekday: try container.decode(Int.self, forKey: .weekday),
                           minuteOfDay: try container.decode(Int.self, forKey: .minute))
        case "every_hours": self = .everyHours(try container.decode(Int.self, forKey: .hours))
        case "once": self = .once(Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .at)))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown cadence")
        }
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .daily(let minute):
            try container.encode("daily", forKey: .kind)
            try container.encode(minute, forKey: .minute)
        case .weekdays(let minute):
            try container.encode("weekdays", forKey: .kind)
            try container.encode(minute, forKey: .minute)
        case .weekly(let weekday, let minute):
            try container.encode("weekly", forKey: .kind)
            try container.encode(weekday, forKey: .weekday)
            try container.encode(minute, forKey: .minute)
        case .everyHours(let hours):
            try container.encode("every_hours", forKey: .kind)
            try container.encode(hours, forKey: .hours)
        case .once(let date):
            try container.encode("once", forKey: .kind)
            try container.encode(date.timeIntervalSince1970, forKey: .at)
        }
    }

    func validate() throws {
        switch self {
        case .daily(let minute), .weekdays(let minute):
            guard (0..<1440).contains(minute) else { throw NativeScheduleError.invalid("Pick a time of day.") }
        case .weekly(let weekday, let minute):
            guard (1...7).contains(weekday), (0..<1440).contains(minute) else { throw NativeScheduleError.invalid("Pick a day and a time.") }
        case .everyHours(let hours):
            guard (1...Self.maximumHours).contains(hours) else { throw NativeScheduleError.invalid("Repeat every 1 to \(Self.maximumHours) hours.") }
        case .once:
            break
        }
    }

    var repeats: Bool {
        if case .once = self { return false }
        return true
    }

    func nextRun(after now: Date, previous: Date?, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch self {
        case .daily(let minute):
            return calendar.nextDate(after: now, matching: Self.components(minute), matchingPolicy: .nextTime)
        case .weekdays(let minute):
            var cursor = now
            for _ in 0..<8 {
                guard let candidate = calendar.nextDate(after: cursor, matching: Self.components(minute), matchingPolicy: .nextTime) else { return nil }
                if (2...6).contains(calendar.component(.weekday, from: candidate)) { return candidate }
                cursor = candidate
            }
            return nil
        case .weekly(let weekday, let minute):
            var components = Self.components(minute)
            components.weekday = weekday
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
        case .everyHours(let hours):
            let step = TimeInterval(hours * 3600)
            var next = (previous ?? now).addingTimeInterval(step)
            while next <= now { next = next.addingTimeInterval(step) }
            return next
        case .once(let date):
            return date > now ? date : nil
        }
    }

    private static func components(_ minute: Int) -> DateComponents {
        DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
    }

    func summary(timeZone: TimeZone) -> String {
        switch self {
        case .daily(let minute): return "Every day at \(Self.clock(minute))"
        case .weekdays(let minute): return "Weekdays at \(Self.clock(minute))"
        case .weekly(let weekday, let minute): return "Every \(Self.weekdayName(weekday)) at \(Self.clock(minute))"
        case .everyHours(let hours): return hours == 1 ? "Every hour" : "Every \(hours) hours"
        case .once(let date): return "Once on \(NativeScheduleClock.dayAndTime(date, timeZone: timeZone))"
        }
    }

    static func clock(_ minute: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: minute / 60, minute: minute % 60))!
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    static func weekdayName(_ weekday: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale.autoupdatingCurrent
        let names = DateFormatter().weekdaySymbols ?? calendar.weekdaySymbols
        guard (1...7).contains(weekday) else { return "day" }
        return names[weekday - 1]
    }
}

enum NativeScheduleClock {
    static func dayAndTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d 'at' h:mm a"
        return formatter.string(from: date)
    }

    static func relative(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = DateFormatter()
        time.timeZone = timeZone
        time.timeStyle = .short
        time.dateStyle = .none
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time.string(from: date))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time.string(from: date))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time.string(from: date))"
        }
        return dayAndTime(date, timeZone: timeZone)
    }
}

enum NativeScheduleOutcome: String, Codable, Equatable, Hashable, Sendable {
    case running, completed, failed, stopped, missed, skipped
    case couldNotStart = "could_not_start"

    var title: String {
        switch self {
        case .running: return "Running"
        case .completed: return "Finished"
        case .failed: return "Couldn't finish"
        case .stopped: return "Stopped"
        case .missed: return "Missed"
        case .skipped: return "Skipped"
        case .couldNotStart: return "Couldn't start"
        }
    }

    var symbol: String {
        switch self {
        case .running: return "clock"
        case .completed: return "checkmark.circle"
        case .failed, .couldNotStart: return "exclamationmark.circle"
        case .stopped: return "stop.circle"
        case .missed: return "moon.zzz"
        case .skipped: return "forward.end"
        }
    }

    var isSettled: Bool { self != .running }
}

enum NativeScheduleError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .notFound: return "That schedule no longer exists."
        }
    }
}

struct NativeSchedule: Identifiable, Equatable, Hashable, Sendable {
    static let workerTypes: [String] = ["research", "document"]

    let id: String
    var owner: NativeScheduleOwner
    var conversationID: String?
    var workerType: String
    var title: String
    var instruction: String
    var cadence: NativeScheduleCadence
    var timeZoneID: String
    var enabled: Bool
    var nextRunAt: Date?
    var lastRunAt: Date?
    var lastOutcome: NativeScheduleOutcome?
    var createdAt: Date

    init(id: String = UUID().uuidString.lowercased(), owner: NativeScheduleOwner, conversationID: String? = nil,
         workerType: String, title: String, instruction: String, cadence: NativeScheduleCadence,
         timeZone: TimeZone, enabled: Bool = true, nextRunAt: Date? = nil, lastRunAt: Date? = nil,
         lastOutcome: NativeScheduleOutcome? = nil, createdAt: Date = Date()) throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.unicodeScalars.count <= 120,
              !cleanTitle.contains("\n"), !cleanTitle.contains("\r") else {
            throw NativeScheduleError.invalid("Give the schedule a one-line name of up to 120 characters.")
        }
        let cleanInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstruction.isEmpty, cleanInstruction.unicodeScalars.count <= 5000 else {
            throw NativeScheduleError.invalid("Describe the work in up to 5,000 characters.")
        }
        guard Self.workerTypes.contains(workerType) else {
            throw NativeScheduleError.invalid("Scheduled work must be research or a document.")
        }
        try cadence.validate()
        self.id = id
        self.owner = owner
        self.conversationID = conversationID
        self.workerType = workerType
        self.title = cleanTitle
        self.instruction = cleanInstruction
        self.cadence = cadence
        self.timeZoneID = timeZone.identifier
        self.enabled = enabled
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastOutcome = lastOutcome
        self.createdAt = createdAt
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    var cadenceSummary: String { cadence.summary(timeZone: timeZone) }
    var isDocument: Bool { workerType == "document" }
    var workTitle: String { isDocument ? "Document" : "Research" }

    func deliverables() -> [String] {
        isDocument ? ["Write the document the brief asks for"] : ["A cited summary of what was found"]
    }

    mutating func advance(after now: Date, from scheduled: Date?) {
        nextRunAt = cadence.nextRun(after: now, previous: scheduled, timeZone: timeZone)
        if nextRunAt == nil { enabled = false }
    }

    func taskRequest() throws -> NativeResearchTaskRequest {
        try NativeResearchTaskRequest(objective: instruction, deliverables: deliverables(), workerType: workerType, title: title)
    }
}

struct NativeScheduleRun: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let scheduleID: String
    let scheduledFor: Date
    var startedAt: Date?
    var finishedAt: Date?
    var outcome: NativeScheduleOutcome
    var detail: String
    var conversationID: String?
    var messageID: String?
    var taskReferenceID: String?

    init(id: String = UUID().uuidString.lowercased(), scheduleID: String, scheduledFor: Date, startedAt: Date? = nil,
         finishedAt: Date? = nil, outcome: NativeScheduleOutcome, detail: String = "", conversationID: String? = nil,
         messageID: String? = nil, taskReferenceID: String? = nil) {
        self.id = id
        self.scheduleID = scheduleID
        self.scheduledFor = scheduledFor
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.detail = String(detail.prefix(300))
        self.conversationID = conversationID
        self.messageID = messageID
        self.taskReferenceID = taskReferenceID
    }
}
