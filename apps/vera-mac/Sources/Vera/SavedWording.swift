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
        ("Provide a title, the kind of work, an instruction and a repeat.", NativeScheduleTools.missingArguments),
        ("Scheduled work must be research or a document.", NativeSchedule.unreadableKind),
        ("Provide a worker type, an objective and deliverables.", NativeTaskTools.missingArguments),
        ("Tandem can't coordinate the model request right now. Check the engine connection and try again.",
         "Tandem can't line up the model request right now. Try again in a moment."),
        ("The engine returned an invalid model reservation.", "The model reservation came back unreadable. Try again."),
        ("The assignment and its notes are too large for this task.", "The assignment and its notes are too large."),
        ("The brief, inputs or outline are too large for this task.", "The brief, inputs or outline are too large."),
        ("The research input is too large for this task.", "The research input is too large."),
        ("The saved model credential is unavailable.", NativeTaskWorkerFailures.credentialUnreadableMessage),
        ("The saved model credential is unavailable. Retry this step?", NativeTaskWorkerFailures.credentialUnreadableMessage),
    ]

    static let argumentsLead = "The tool arguments are invalid: "

    static let lessFromSchedule = "Edit the schedule to ask for less."

    static let scheduledLines: [(String, String)] = [
        (NativeResearchWorker.explicitRetryMessage, "This needs an explicit retry to continue."),
        (NativeDocumentWorker.explicitRetryMessage, "This needs an explicit retry to continue."),
        (NativeResearchWorker.unusableReportMessage, "The model did not return a usable result."),
        (NativeResearchWorker.uncitedReportMessage, "The result did not cite the gathered sources correctly."),
        (NativeResearchWorker.condenseStuckMessage, "The material is still too long to work with after condensing it. Try this step again to condense it in smaller parts?"),
        (NativeDocumentWorker.condenseStuckMessage, "The material is still too long to work with after condensing it. Try this step again to condense it in smaller parts?"),
        (NativeDocumentWorker.invalidOutlineMessage, "The model did not return a valid plan."),
        (NativeDocumentWorker.longOutlineMessage, "The plan is too long for the model. Retrying asks for a shorter plan."),
        (NativeDocumentWorker.invalidSectionMessage, "The model did not return a valid section."),
        (NativeDocumentWorker.bulletCountMessage, "The result did not match the requested bullet count. Your saved work is preserved."),
        (NativeTaskWorkerFailures.outlineCutShortMessage, "The plan was cut off before it finished, even after asking for a shorter one. Try this step again?"),
        (NativeTaskWorkerFailures.modelChangedMessage, "The model this was using has changed in Settings. The next run uses the new one."),
        (NativeDocumentWorker.progressTooLargeMessage, "This grew larger than Tandem can hold while working on it. " + lessFromSchedule),
        ("This document would need more than Tandem can save in one document. Ask for it as two documents.",
         "This would need more than Tandem can save at once. " + lessFromSchedule),
        ("This document would need about ", "This would need about "),
        ("The finished document is ", "The result is "),
        ("The finished report is ", "The result is "),
        (" in one document. Ask for it as two documents.", " at once. " + lessFromSchedule),
        (" in one report. Ask for a narrower report.", " at once. " + lessFromSchedule),
        ("Preparing the report from ", "Preparing the result from "),
        ("The sections already written are kept.", "The finished sections are kept."),
        ("This research request was started somewhere else and can't continue here.", "This was started somewhere else and can't continue here."),
        ("This must be research or a document.", "This request couldn't be accepted."),
        ("The research input is too large.", "What the schedule asks for is too large."),
        ("The brief, inputs or outline are too large.", "What the schedule asks for is too large."),
    ]

    static func scheduled(_ shown: String) -> String {
        scheduledLines.reduce(shown) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    static func question(_ saved: String, scheduled: Bool = false) -> String {
        let shown = earlier.first(where: { $0.0 == saved })?.1 ?? saved
        return scheduled ? Self.scheduled(shown) : shown
    }

    static func current(_ saved: String) -> String {
        if let pair = earlier.first(where: { $0.0 == saved }) { return pair.1 }
        guard saved.hasPrefix(argumentsLead) else { return saved }
        let detail = String(saved.dropFirst(argumentsLead.count))
        guard let pair = earlier.first(where: { $0.0 == detail }) else { return saved }
        return argumentsLead + pair.1
    }
}
