import Foundation

enum NativeScheduleControl: Hashable, Sendable {
    case runNow, pause, resume, resumeAssistant, edit
}

enum NativeScheduleControls {
    static func waitsOnPausedAssistant(_ schedule: NativeSchedule, assistantPaused: Bool) -> Bool {
        assistantPaused && schedule.owner == .dot && schedule.enabled
    }

    static func pausedNote(_ schedule: NativeSchedule, assistantPaused: Bool) -> String? {
        waitsOnPausedAssistant(schedule, assistantPaused: assistantPaused) ? "Paused with {name}" : nil
    }

    static func resultsLine(_ lead: String, toCompanion: Bool, end: String = "") -> CompanionLine {
        toCompanion ? .named("\(lead)Results go to {name}\(end)") : .literal("\(lead)Results go to its own chat\(end)")
    }

    static func controls(for schedule: NativeSchedule, assistantPaused: Bool) -> [NativeScheduleControl] {
        if waitsOnPausedAssistant(schedule, assistantPaused: assistantPaused) { return [.resumeAssistant, .edit] }
        return [.runNow, schedule.enabled ? .pause : .resume, .edit]
    }

    static func title(_ control: NativeScheduleControl) -> String {
        switch control {
        case .runNow: return "Run now"
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .resumeAssistant: return "Resume {name}"
        case .edit: return "Edit"
        }
    }
}
