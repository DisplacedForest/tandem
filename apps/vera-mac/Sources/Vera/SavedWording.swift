import Foundation

enum SavedWording {
    static let earlier: [(String, String)] = [
        ("Tandem closed before this run reached the task engine.", NativeScheduler.closedBeforeStartNote),
        ("The run never reached the task engine.", NativeScheduler.neverStartedNote),
        ("The task engine refused the run.", NativeScheduler.refusedNote),
        ("The task engine couldn't be reached.", "This couldn't be reached."),
        ("The task engine didn't authorize this request.", "This request wasn't allowed."),
        ("The task engine couldn't find this task.", "This couldn't be found."),
        ("The task engine found a conflicting request.", "This conflicts with an earlier request."),
        ("The task engine couldn't accept this request.", "This request couldn't be accepted."),
        ("The task engine is unavailable right now.", "This couldn't start right now."),
        ("The task engine returned an unreadable response.", "The reply couldn't be read."),
        ("Configure a valid task engine address first.", "This can't start until Tandem is set up for it."),
        ("This research request belongs to a different engine.", "This research request was started somewhere else and can't continue here."),
        ("Background work must be research or a document.", "This must be research or a document."),
        ("Background generation limits must be finite and bounded.", "Those generation settings are out of range."),
        ("Provide a title, a worker type, an instruction and a repeat.", NativeScheduleTools.missingArguments),
        ("Provide a worker type, an objective and deliverables.", NativeTaskTools.missingArguments),
        ("Tandem can't coordinate the model request right now. Check the engine connection and try again.",
         "Tandem can't line up the model request right now. Try again in a moment."),
        ("The engine returned an invalid model reservation.", "The model reservation came back unreadable. Try again."),
        ("The assignment and its notes are too large for this task.", "The assignment and its notes are too large."),
        ("The brief, inputs or outline are too large for this task.", "The brief, inputs or outline are too large."),
        ("The research input is too large for this task.", "The research input is too large."),
    ]

    static let argumentsLead = "The tool arguments are invalid: "

    static func current(_ saved: String) -> String {
        if let pair = earlier.first(where: { $0.0 == saved }) { return pair.1 }
        guard saved.hasPrefix(argumentsLead) else { return saved }
        let detail = String(saved.dropFirst(argumentsLead.count))
        guard let pair = earlier.first(where: { $0.0 == detail }) else { return saved }
        return argumentsLead + pair.1
    }
}
