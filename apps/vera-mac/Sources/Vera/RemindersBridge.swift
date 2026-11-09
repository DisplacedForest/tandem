import EventKit
import Foundation

private final class ReminderFetchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var reminders: [EKReminder] = []

    func store(_ reminders: [EKReminder]) {
        lock.lock()
        self.reminders = reminders
        lock.unlock()
    }

    func load() -> [EKReminder] {
        lock.lock()
        defer { lock.unlock() }
        return reminders
    }
}

final class RemindersBridge: @unchecked Sendable {
    static let shared = RemindersBridge()

    private let store = EKEventStore()

    // MARK: access

    @discardableResult
    func requestAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    // MARK: EventKit

    private func calendars() -> [EKCalendar] { store.calendars(for: .reminder) }

    private func calendar(named name: String) -> EKCalendar? {
        let want = name.trimmingCharacters(in: .whitespaces).lowercased()
        return calendars().first { $0.title.trimmingCharacters(in: .whitespaces).lowercased() == want }
    }

    private func fetch(_ cals: [EKCalendar]) throws -> [EKReminder] {
        let pred = store.predicateForReminders(in: cals.isEmpty ? nil : cals)
        let sem = DispatchSemaphore(value: 0)
        let result = ReminderFetchResult()
        store.fetchReminders(matching: pred) { items in
            result.store(items ?? [])
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 15) == .success else {
            throw NativeToolError.failed("Apple Reminders did not respond in time")
        }
        return result.load()
    }

    private func iso(_ c: DateComponents?) -> String? {
        guard let c, let y = c.year, let m = c.month, let d = c.day else { return nil }
        if let hh = c.hour {
            return String(format: "%04d-%02d-%02dT%02d:%02d", y, m, d, hh, c.minute ?? 0)
        }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private func components(_ s: String) -> DateComponents? {
        let f = ISO8601DateFormatter()
        f.formatOptions = s.count > 10 ? [.withInternetDateTime] : [.withFullDate]
        let cal = Calendar.current
        if s.count > 10, let dt = f.date(from: s) {
            return cal.dateComponents([.year, .month, .day, .hour, .minute], from: dt)
        }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    private func sentenceCased(_ t: String) -> String {
        let s = t.trimmingCharacters(in: .whitespaces)
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

extension RemindersBridge: NativeRemindersService {
    var nativeAuthorization: NativeRemindersAuthorization {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func nativeRequestAccess() async -> Bool {
        await requestAccess()
    }

    func nativeLists() async throws -> [NativeReminderList] {
        try requireNativeAccess()
        return calendars().map { NativeReminderList(id: $0.calendarIdentifier, name: $0.title) }
    }

    func nativeReminders(list: String?, completed: Bool) async throws -> [NativeReminder] {
        try requireNativeAccess()
        let selected: [EKCalendar]
        if let list {
            guard let calendar = calendar(named: list) else {
                throw NativeToolError.failed("No reminders list named '\(list)'")
            }
            selected = [calendar]
        } else {
            selected = calendars()
        }
        return try fetch(selected).filter { $0.isCompleted == completed }.map(nativeReminder)
    }

    func nativeCreateReminder(
        list: String, title: String, notes: String?, due: String?
    ) async throws -> NativeReminder {
        try requireNativeAccess()
        guard let calendar = calendar(named: list) else {
            throw NativeToolError.failed("No reminders list named '\(list)'")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = sentenceCased(title)
        reminder.notes = notes
        if let due {
            guard let value = components(due) else {
                throw NativeToolError.invalidArguments("Due must be an ISO 8601 date or date-time")
            }
            reminder.dueDateComponents = value
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw NativeToolError.failed(error.localizedDescription)
        }
        return nativeReminder(reminder)
    }

    func nativeCompleteReminder(id: String) async throws -> NativeReminder {
        try requireNativeAccess()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw NativeToolError.failed("No reminder with identifier '\(id)'")
        }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw NativeToolError.failed(error.localizedDescription)
        }
        return nativeReminder(reminder)
    }

    private func requireNativeAccess() throws {
        guard nativeAuthorization == .authorized else { throw NativeToolError.unavailable }
    }

    private func nativeReminder(_ reminder: EKReminder) -> NativeReminder {
        NativeReminder(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            due: iso(reminder.dueDateComponents),
            completed: reminder.isCompleted,
            list: reminder.calendar?.title)
    }
}
