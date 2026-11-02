import Foundation

enum NativeScheduleControl: Hashable, Sendable {
    case runNow, pause, resume, resumeAssistant, edit
}

enum NativeScheduleControls {
    static func waitsOnPausedAssistant(_ schedule: NativeSchedule, assistantPaused: Bool) -> Bool {
        assistantPaused && schedule.owner == .dot && schedule.enabled
    }

    static func pausedNote(_ schedule: NativeSchedule, assistantPaused: Bool, assistantName: String) -> String? {
        waitsOnPausedAssistant(schedule, assistantPaused: assistantPaused) ? "Paused with \(assistantName)" : nil
    }

    static func controls(for schedule: NativeSchedule, assistantPaused: Bool) -> [NativeScheduleControl] {
        if waitsOnPausedAssistant(schedule, assistantPaused: assistantPaused) { return [.resumeAssistant, .edit] }
        return [.runNow, schedule.enabled ? .pause : .resume, .edit]
    }

    static func title(_ control: NativeScheduleControl, assistantName: String) -> String {
        switch control {
        case .runNow: return "Run now"
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .resumeAssistant: return "Resume \(assistantName)"
        case .edit: return "Edit"
        }
    }
}
