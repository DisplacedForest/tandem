import Foundation

enum NativeScheduleTools {
    static let toolID = "scheduled-work"
    static let toolName = "schedule_task"
    static let missingArguments = "Provide a title, an instruction and a repeat."
    static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let repeatKinds = ["daily", "weekdays", "weekly", "every_hours", "once"]
    static let argumentNames: Set<String> = ["title", "instruction", "results_to", "repeat", "time", "weekday", "hours", "at"]

    static func turnEnabledIDs(snapshot: Set<String>, consented: Set<String>, authority: NativeTurnToolAuthority,
                               hasEngine: Bool, hasRepository: Bool, hasStore: Bool) -> Set<String> {
        let current = snapshot.intersection(consented)
        let allowed = NativeTaskTools.enabledIDs(current, hasEngine: hasEngine, hasRepository: hasRepository, general: authority.allowsGeneral)
        return enabledIDs(allowed, consented: current, hasStore: hasStore)
    }

    static func enabledIDs(_ existing: Set<String>, consented: Set<String>, hasStore: Bool) -> Set<String> {
        let base = existing.subtracting([toolID])
        guard consented.contains(NativeWebTools.researchToolID), hasStore else { return base }
        return base.union([toolID])
    }

    static let description = "Proposes saving a schedule that has you do something later, either once at a set time or on a repeat. When to use: the person wants something done at a later time or regularly, such as every morning, on weekdays, weekly or every few hours. When not to use: work that should start now, which create_background_task handles when it is offered; something the person wants to be reminded of themselves, which apple_reminders_create handles when it is offered; a question you can answer now. Effects: nothing runs and nothing is saved until the person confirms the schedule in the app; once confirmed it is saved and listed in Scheduled. Inputs: a short title and the full instruction of what to do; repeat decides which timing fields apply: daily and weekdays need time, weekly needs weekday and time, every_hours needs hours, and once needs at, which must still be ahead. Returns message and saved; acknowledge in one sentence using the timing in message, do not say the schedule exists until saved is true, and never show identifiers. If it is refused over a timing field, retry once with that field corrected; if the person declines, leave it."

    static func definition(companionThread: Bool = false,
                           now: @escaping @Sendable () -> Date = { Date() },
                           timeZone: @escaping @Sendable () -> TimeZone = { .current },
                           save: @escaping @Sendable (NativeScheduleDraft) async throws -> NativeSchedule) -> NativeToolDefinition {
        var built = NativeToolDefinition(id: toolID, name: toolName, title: "Schedule work",
            description: description,
            parameters: .object([
                "type": .string("object"), "additionalProperties": .bool(false),
                "required": .array([.string("title"), .string("instruction"), .string("repeat")]),
                "properties": .object([
                    "title": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(120),
                                      "description": .string("A one-line name for the schedule, up to 120 characters.")]),
                    "instruction": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(5000),
                                            "description": .string("What to do, written so it makes sense on its own each time it runs. Up to 5000 characters.")]),
                    "results_to": .object(["type": .string("string"), "minLength": .number(1), "enum": .array([.string("assistant"), .string("own_chat")]),
                                           "description": .string("Where results go: assistant for the companion's ongoing conversation, or own_chat for a chat of its own. Left out, a schedule asked for in the companion's conversation goes there and one asked for anywhere else gets its own chat.")]),
                    "repeat": .object(["type": .string("string"), "minLength": .number(1), "enum": .array(repeatKinds.map { NativeJSONValue.string($0) }),
                                       "description": .string("How often it runs: daily, weekdays, weekly, every_hours, or once.")]),
                    "time": .object(["type": .string("string"), "minLength": .number(1),
                                     "description": .string("Time of day as HH:MM on a 24-hour clock in the person's local time. Needed for daily, weekdays and weekly.")]),
                    "weekday": .object(["type": .string("string"), "minLength": .number(1), "enum": .array(weekdayNames.map { NativeJSONValue.string($0) }),
                                        "description": .string("Day of the week in lowercase. Needed for weekly.")]),
                    "hours": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(Double(NativeScheduleCadence.maximumHours)),
                                      "description": .string("Hours between runs, 1 to \(NativeScheduleCadence.maximumHours). Needed for every_hours.")]),
                    "at": .object(["type": .string("string"), "minLength": .number(1),
                                   "description": .string("Local date and time as YYYY-MM-DDTHH:MM, still ahead. Needed for once.")]),
                ]),
            ]), confirmation: .required, timeout: .seconds(10), action: .otherChanges, isAvailable: { true }, execute: { arguments in
                let draft = try draft(from: arguments, now: now(), timeZone: timeZone(), companionThread: companionThread)
                let schedule: NativeSchedule
                NativeToolCallContext.effectStarts()
                do { schedule = try await save(draft) } catch { throw NativeToolError.failed(error.localizedDescription) }
                let destination = schedule.owner == .dot ? "the companion's conversation" : "its own chat"
                return .object([
                    "message": .string("Saved. \(schedule.cadenceSummary). It appears in Scheduled, and results go to \(destination)."),
                    "saved": .bool(true),
                ])
            }, wants: wants, marksEffect: true)
        built.check = { arguments in
            do {
                _ = try draft(from: arguments, now: now(), timeZone: timeZone(), companionThread: companionThread)
                return nil
            } catch NativeToolError.invalidArguments(let detail) {
                return detail
            } catch let refusal as NativeScheduleError {
                return refusal.localizedDescription
            } catch {
                return nil
            }
        }
        return built
    }

    static func draft(from arguments: [String: NativeJSONValue], now: Date, timeZone: TimeZone, companionThread: Bool = false) throws -> NativeScheduleDraft {
        guard Set(arguments.keys).isSubset(of: argumentNames) else {
            throw NativeToolError.invalidArguments("Unexpected field")
        }
        guard case .string(let title)? = arguments["title"],
              case .string(let instruction)? = arguments["instruction"],
              case .string(let repeatKind)? = arguments["repeat"] else {
            throw NativeToolError.invalidArguments(missingArguments)
        }
        var draft = NativeScheduleDraft()
        draft.title = title
        draft.instruction = instruction
        switch arguments["results_to"] {
        case nil: draft.owner = companionThread ? .dot : .conversation
        case .string("own_chat")?: draft.owner = .conversation
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

    static func draft(inRequest request: String, now: Date = Date(), timeZone: TimeZone = .current, companionThread: Bool = false) -> NativeScheduleDraft? {
        guard let data = request.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = try? object.mapValues({ try NativeJSONValue(any: $0) }) else { return nil }
        return try? draft(from: values, now: now, timeZone: timeZone, companionThread: companionThread)
    }

    static let wants = "schedule this"

    static func literal(for draft: NativeScheduleDraft, timeZone: TimeZone = .current) -> String {
        let cadence = draft.cadence.summary(timeZone: timeZone)
        var instruction = draft.instruction.replacingOccurrences(of: "\n", with: " ")
        if instruction.count > 180 { instruction = String(instruction.prefix(177)).trimmingCharacters(in: .whitespaces) + "..." }
        return [draft.title + ", " + cadence.prefix(1).lowercased() + cadence.dropFirst(), instruction].joined(separator: "\n")
    }

    static func destination(for draft: NativeScheduleDraft) -> String {
        draft.owner == .dot ? "Results go to \(CompanionSentence.placeholder)." : "Results go to its own chat."
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
