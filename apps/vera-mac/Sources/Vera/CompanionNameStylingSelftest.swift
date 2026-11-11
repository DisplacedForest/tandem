import Foundation

extension SelfTest {
    @MainActor
    static func runCompanionNameStyling() throws {
        let require = NativeTaskFixture.require
        let placeholder = CompanionSentence.placeholder
        let dot = try NativeSchedule(owner: .dot, workerType: "research", title: "Morning check", instruction: "Check",
                                     cadence: .daily(minuteOfDay: 420), timeZone: TimeZone(identifier: "UTC")!)
        let pausedNote = NativeScheduleControls.pausedNote(dot, assistantPaused: true) ?? ""
        let cases: [(String, String, String)] = [
            (CompanionWorkCopy.describe, "Describe what Ada should work on.", "Describe what your companion should work on."),
            (CompanionWorkCopy.paused, "Ada is paused. Resume to give it work.", "Your companion is paused. Resume to give it work."),
            (CompanionWorkCopy.conversation, "Ada's conversation couldn't be opened.", "Your companion's conversation couldn't be opened."),
            (CompanionWorkCopy.couldNotStart, "Ada couldn't start this work.", "Your companion couldn't start this work."),
            (pausedNote, "Paused with Ada", "Paused with your companion"),
            (NativeScheduleControls.title(.resumeAssistant), "Resume Ada", "Resume your companion"),
            (DotProfileCopy.startOver, "Removes the conversation, what Ada remembered from it and its schedules. Artifacts stay in Artifacts.",
             "Removes the conversation, what your companion remembered from it and its schedules. Artifacts stay in Artifacts."),
            (DotProfileCopy.subtitle, "Give Ada a standing goal, choose what it can reach and set what asks first. You can change all of this later from the header.",
             "Give your companion a standing goal, choose what it can reach and set what asks first. You can change all of this later from the header."),
            (ArtifactLibrarySelection.companionFilterTitle, "From Ada", "From your companion"),
            ("Give {name} work", "Give Ada work", "Give your companion work"),
            ("{name} is paused.", "Ada is paused.", "Your companion is paused."),
            ("Ask anything. It goes to {name}'s thread.", "Ask anything. It goes to Ada's thread.", "Ask anything. It goes to your companion's thread."),
            (CompanionErrorCopy.saveLead + "disk full", "Ada's settings couldn't be saved: disk full", "Your companion's settings couldn't be saved: disk full"),
            (CompanionErrorCopy.clearLead + "disk full", "Ada's settings couldn't be cleared: disk full", "Your companion's settings couldn't be cleared: disk full"),
            (CompanionErrorCopy.threadLead + "disk full", "Ada's thread couldn't be created: disk full", "Your companion's thread couldn't be created: disk full"),
            (CompanionErrorCopy.loadLead + "disk full" + CompanionErrorCopy.loadTail,
             "Ada's goal and settings couldn't load: disk full Scheduled work is paused and no services are connected until the settings are saved again.",
             "Your companion's goal and settings couldn't load: disk full Scheduled work is paused and no services are connected until the settings are saved again."),
        ]
        for (template, named, unnamed) in cases {
            try require(template.contains(placeholder), "The template names the companion: \(template)")
            try require(CompanionSentence.plain(template, name: "Ada") == named, "Named rendering: \(template)")
            try require(CompanionSentence.plain(template, name: nil) == unnamed, "Unnamed rendering: \(template)")
            try require(CompanionSentence.plain(template, name: "  ") == unnamed, "A blank name reads as unnamed: \(template)")
            for name in ["Ada", nil] as [String?] {
                try require(!CompanionSentence.plain(template, name: name).contains(placeholder), "No placeholder survives: \(template)")
            }
        }
        try require(CompanionSentence.plain("Message {name}…", name: nil) == "Message your companion…", "Mid-sentence unnamed stays lowercase")
        try require(CompanionSentence.plain("Work {name} runs on a schedule while Tandem is open or in the menu bar.", name: nil)
                    == "Work your companion runs on a schedule while Tandem is open or in the menu bar.", "The schedule header reads unnamed")
        try require(CompanionSentence.plain("{name} follows these everywhere. You can also just say one in chat.", name: nil)
                    == "Your companion follows these everywhere. You can also just say one in chat.", "The preferences line starts a sentence")
        try require(CompanionSentence.plain("{name} isn't connected. Set up the connection", name: "Ada") == "Ada isn't connected. Set up the connection",
                    "The connection call to action names the companion")

        let toCompanion = NativeScheduleControls.resultsLine("Daily at 7:00 AM. ", toCompanion: true)
        try require(toCompanion.plain(name: "Ada") == "Daily at 7:00 AM. Results go to Ada", "Results go to the named companion")
        try require(toCompanion.plain(name: nil) == "Daily at 7:00 AM. Results go to your companion", "Results go to the unnamed companion")
        let detail = NativeScheduleControls.resultsLine("Research. Daily at 7:00 AM. ", toCompanion: true, end: ".")
        try require(detail.plain(name: "Ada") == "Research. Daily at 7:00 AM. Results go to Ada.", "The detail line ends with a period")
        let ownChat = NativeScheduleControls.resultsLine("Daily at 7:00 AM. ", toCompanion: false)
        try require(ownChat == .literal("Daily at 7:00 AM. Results go to its own chat"), "A chat's own schedule names no companion")
        try require(CompanionLine.literal("Keep {name}").plain(name: "Ada") == "Keep {name}", "Literal text is never filled in")
        try require(CompanionSentence.plain(NativeScheduleControls.title(.runNow), name: "Ada") == "Run now", "Other controls stay as they were")

        for name in ["Ada", nil] as [String?] {
            let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil)
            store.adoptAssistantName(name)
            let subject = name ?? "Your companion"
            store.reportCompanionConfigurationError(CompanionErrorCopy.saveLead, description: "disk full")
            try require(store.chatConfigurationError == "\(subject)'s settings couldn't be saved: disk full", "The plain error is finished text")
            try require(store.chatConfigurationErrorTemplate == CompanionErrorCopy.saveLead + "disk full", "The template is kept beside it")
            try require(store.chatConfigurationErrorLine == .named(CompanionErrorCopy.saveLead + "disk full"), "Real text draws the styled template")
            try require(store.companionOpeningErrorLine == .named(CompanionErrorCopy.saveLead + "disk full"), "The opening view draws the styled template")
            store.chatConfigurationError = "Messages couldn't load: offline"
            try require(store.chatConfigurationErrorTemplate == nil, "An unrelated error clears the template")
            try require(store.chatConfigurationErrorLine == .literal("Messages couldn't load: offline"), "An unrelated error draws as plain text")
            store.reportCompanionConfigurationError(CompanionErrorCopy.threadLead, description: "disk full")
            store.chatConfigurationError = nil
            try require(store.chatConfigurationErrorTemplate == nil && store.chatConfigurationErrorLine == nil, "Clearing the error clears the template")
            store.reportCompanionConfigurationError(CompanionErrorCopy.loadLead, description: "bad {name} value", tail: CompanionErrorCopy.loadTail)
            try require(store.chatConfigurationErrorTemplate == nil, "A description holding the placeholder sets no template")
            try require(store.chatConfigurationError == "\(subject)'s goal and settings couldn't load: bad {name} value" + CompanionErrorCopy.loadTail,
                        "A description holding the placeholder is kept word for word")
            try require(store.chatConfigurationErrorLine == .literal(store.chatConfigurationError ?? ""), "That error draws as plain text")
        }
    }
}
