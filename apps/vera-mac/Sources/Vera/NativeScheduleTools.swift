import Foundation

enum NativeScheduleTools {
    static let toolID = "scheduled-work"
    static let toolName = "schedule_task"
    static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let repeatKinds = ["daily", "weekdays", "weekly", "every_hours", "once"]
    static let argumentNames: Set<String> = ["title", "worker_type", "instruction", "results_to", "repeat", "time", "weekday", "hours", "at"]

    static func turnEnabledIDs(snapshot: Set<String>, consented: Set<String>, authority: NativeTurnToolAuthority,
                               hasEngine: Bool, hasRepository: Bool, hasStore: Bool) -> Set<String> {
        let current = snapshot.intersection(consented)
        var allowed = NativeTaskTools.enabledIDs(authority.filter(current), hasEngine: hasEngine, hasRepository: hasRepository)
        if !authority.allowsBackground { allowed.remove(NativeTaskTools.toolID) }
        return enabledIDs(allowed, consented: current, authority: authority, hasStore: hasStore)
    }

    static func enabledIDs(_ existing: Set<String>, consented: Set<String>, authority: NativeTurnToolAuthority, hasStore: Bool) -> Set<String> {
        let base = existing.subtracting([toolID])
        guard consented.contains(NativeWebTools.researchToolID), authority.allowsSchedule, hasStore else { return base }
        return base.union([toolID])
    }

    static func definition(searchAvailable: @escaping @Sendable () -> Bool = { NativeWebSearch.resolvedBase() != nil },
                           now: @escaping @Sendable () -> Date = { Date() },
                           timeZone: @escaping @Sendable () -> TimeZone = { .current },
                           save: @escaping @Sendable (NativeScheduleDraft) async throws -> NativeSchedule) -> NativeToolDefinition {
        NativeToolDefinition(id: toolID, name: toolName, title: "Schedule work",
            description: "Propose a schedule only when the current user message explicitly asks for research or a written document to happen on a repeating basis or at a later time (every day, on weekdays, weekly, every few hours, or once at a set time). Nothing runs now and nothing is saved by this call alone: the user confirms the cadence and the work in the app first. Use worker_type research for a question answered from web sources, document for a written deliverable. Give a short title and the full instruction. Give time as 24-hour HH:MM in the user's local time. Use results_to assistant when the user wants results in the ongoing assistant thread, otherwise own_chat. Then acknowledge in one sentence. Do not claim the schedule exists until the tool result says it was saved, and do not expose internal identifiers.",
            parameters: .object([
                "type": .string("object"), "additionalProperties": .bool(false),
                "required": .array([.string("title"), .string("worker_type"), .string("instruction"), .string("repeat")]),
                "properties": .object([
                    "title": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(120),
                                      "description": .string("One-line name for the schedule")]),
                    "worker_type": .object(["type": .string("string"), "enum": .array([.string("research"), .string("document")])]),
                    "instruction": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(5000),
                                            "description": .string("What to research, or the brief for the document")]),
                    "results_to": .object(["type": .string("string"), "enum": .array([.string("assistant"), .string("own_chat")])]),
                    "repeat": .object(["type": .string("string"), "enum": .array(repeatKinds.map { .string($0) })]),
                    "time": .object(["type": .string("string"), "description": .string("HH:MM, 24-hour local time, for daily, weekdays and weekly")]),
                    "weekday": .object(["type": .string("string"), "enum": .array(weekdayNames.map { .string($0) }),
                                        "description": .string("For weekly")]),
                    "hours": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(Double(NativeScheduleCadence.maximumHours)),
                                      "description": .string("For every_hours")]),
                    "at": .object(["type": .string("string"), "description": .string("YYYY-MM-DDTHH:MM local time, for once")]),
                ]),
            ]), confirmation: .required, timeout: .seconds(10), action: .otherChanges, isAvailable: { true }, execute: { arguments in
                let draft = try draft(from: arguments, now: now(), timeZone: timeZone())
                if draft.workerType == "research", !searchAvailable() {
                    throw NativeToolError.failed(NativeTaskTools.searchUnavailable)
                }
                let schedule: NativeSchedule
                do { schedule = try await save(draft) } catch { throw NativeToolError.failed(error.localizedDescription) }
                let destination = schedule.owner == .dot ? "the companion's conversation" : "its own chat"
                return .object([
                    "message": .string("Saved. \(schedule.cadenceSummary). It appears in Scheduled, and results go to \(destination)."),
                    "saved": .bool(true),
                ])
            }, wants: wants)
    }

    static func draft(from arguments: [String: NativeJSONValue], now: Date, timeZone: TimeZone) throws -> NativeScheduleDraft {
        guard Set(arguments.keys).isSubset(of: argumentNames) else {
            throw NativeToolError.invalidArguments("Unexpected field")
        }
        guard case .string(let title)? = arguments["title"],
              case .string(let workerType)? = arguments["worker_type"],
              case .string(let instruction)? = arguments["instruction"],
              case .string(let repeatKind)? = arguments["repeat"] else {
            throw NativeToolError.invalidArguments("Provide a title, a worker type, an instruction and a repeat.")
        }
        guard NativeResearchTaskRequest.chatWorkerTypes.contains(workerType) else {
            throw NativeToolError.invalidArguments("Scheduled work must be research or a document.")
        }
        var draft = NativeScheduleDraft()
        draft.title = title
        draft.instruction = instruction
        draft.workerType = workerType
        switch arguments["results_to"] {
        case nil, .string("own_chat")?: draft.owner = .conversation
        case .string("assistant")?: draft.owner = .dot
        default: throw NativeToolError.invalidArguments("results_to must be assistant or own_chat.")
        }
        switch repeatKind {
        case "daily": draft.cadence = .daily(minuteOfDay: try minute(arguments["time"]))
        case "weekdays": draft.cadence = .weekdays(minuteOfDay: try minute(arguments["time"]))
        case "weekly":
            guard case .string(let name)? = arguments["weekday"],
                  let index = weekdayNames.firstIndex(of: name.lowercased()) else {
                throw NativeToolError.invalidArguments("A weekly schedule needs a weekday.")
            }
            draft.cadence = .weekly(weekday: index + 1, minuteOfDay: try minute(arguments["time"]))
        case "every_hours":
            guard case .number(let raw)? = arguments["hours"], raw == raw.rounded(), raw >= 1, raw <= Double(NativeScheduleCadence.maximumHours) else {
                throw NativeToolError.invalidArguments("Repeat every 1 to \(NativeScheduleCadence.maximumHours) hours.")
            }
            draft.cadence = .everyHours(Int(raw))
        case "once":
            guard case .string(let text)? = arguments["at"], let date = localDate(text, timeZone: timeZone) else {
                throw NativeToolError.invalidArguments("A one-time schedule needs a date and time as YYYY-MM-DDTHH:MM.")
            }
            guard date > now else { throw NativeToolError.invalidArguments("Pick a time that is still ahead.") }
            draft.cadence = .once(date)
        default:
            throw NativeToolError.invalidArguments("repeat must be daily, weekdays, weekly, every_hours or once.")
        }
        _ = try NativeSchedule(owner: draft.owner, workerType: draft.workerType, title: draft.title,
                               instruction: draft.instruction, cadence: draft.cadence, timeZone: timeZone)
        return draft
    }

    static func draft(inRequest request: String, now: Date = Date(), timeZone: TimeZone = .current) -> NativeScheduleDraft? {
        guard let data = request.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = try? object.mapValues({ try NativeJSONValue(any: $0) }) else { return nil }
        return try? draft(from: values, now: now, timeZone: timeZone)
    }

    static let wants = "schedule this"

    static func literal(for draft: NativeScheduleDraft, timeZone: TimeZone = .current) -> String {
        let cadence = draft.cadence.summary(timeZone: timeZone)
        var instruction = draft.instruction.replacingOccurrences(of: "\n", with: " ")
        if instruction.count > 180 { instruction = String(instruction.prefix(177)).trimmingCharacters(in: .whitespaces) + "..." }
        return [draft.title + ", " + cadence.prefix(1).lowercased() + cadence.dropFirst(), instruction].joined(separator: "\n")
    }

    static func destination(for draft: NativeScheduleDraft) -> String {
        draft.owner == .dot ? "Results go to \(CompanionSentence.placeholder)'s thread." : "Results go to its own chat."
    }

    private static func minute(_ value: NativeJSONValue?) throws -> Int {
        guard case .string(let text)? = value else { throw NativeToolError.invalidArguments("Give the time as HH:MM.") }
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw NativeToolError.invalidArguments("Give the time as HH:MM in 24-hour form.")
        }
        return hour * 60 + minute
    }

    private static func localDate(_ text: String, timeZone: TimeZone) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}
