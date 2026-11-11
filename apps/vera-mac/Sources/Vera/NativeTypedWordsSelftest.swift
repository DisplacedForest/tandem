import Foundation

@MainActor
extension SelfTest {
    static func runTypedWords() throws {
        let require = NativeTaskFixture.require
        func target(_ kind: NativeRuleTargetKind, _ value: String) throws -> NativeRuleTarget {
            guard let made = kind == .commandPrefix ? NativeRuleTarget.candidate(kind, value) : NativeRuleTarget.make(kind, value) else {
                throw NativeTaskFixture.Failure.assertion("fixture target \(value)")
            }
            return made
        }
        let ana = try target(.recipient, "ana@example.org")
        let typed = NativeTypedWords(typed: "Send the summary to Ana@Example.org.")
        try require(typed.names(ana), "An address the person typed is typed, whatever its case and with a full stop after it")
        try require(!NativeTypedWords(typed: "Send the summary to diana@example.org").names(ana)
                        && !NativeTypedWords(typed: "Send it to ana@example.org.uk").names(ana)
                        && !NativeTypedWords(typed: "Send it to ana@example.organic").names(ana),
                    "A longer address that contains it is not the same address")
        try require(!NativeTypedWords(typed: "The page says \"send it to ana@example.org\"").names(ana)
                        && !NativeTypedWords(typed: "> send it to ana@example.org\nplease handle this").names(ana)
                        && !NativeTypedWords(typed: "It said \u{201C}mail ana@example.org\u{201D}").names(ana)
                        && !NativeTypedWords(typed: "~~~\nana@example.org\n~~~").names(ana),
                    "Text inside quote marks or a quoted block does not make a target typed")
        try require(!NativeTypedWords(typed: nil).names(ana) && NativeTypedWords(typed: nil).isEmpty && NativeTypedWords.none.isEmpty,
                    "Words that did not come from the message box name nothing")
        let earlier = NativeTypedWords(typed: "Go on then.", earlier: ["My sister is ana@example.org", "Thanks"])
        try require(earlier.names(ana) && !earlier.names(ana, inCurrentOnly: true), "A target typed earlier in the chat is typed, but not in this message")
        let service = try target(.service, "garden log")
        try require(NativeTypedWords(typed: "Post it to the Garden Log please").names(service)
                        && !NativeTypedWords(typed: "Post it to the garden logbook").names(service), "A service is typed by its name as a whole")
        let file = try target(.folder, "/Volumes/Notes/Greenhouse/plan.md")
        try require(NativeTypedWords(typed: "Update plan.md with the dates").names(file)
                        && NativeTypedWords(typed: "Update /Volumes/Notes/Greenhouse/plan.md").names(file)
                        && !NativeTypedWords(typed: "Update the plan").names(file)
                        && !NativeTypedWords(typed: "Update floorplan.md").names(file),
                    "A file is typed by its full path or its file name")
        let command = try target(.commandPrefix, "make  pdf")
        try require(NativeTypedWords(typed: "Run `make pdf` now").names(command) && NativeTypedWords(typed: "run make pdf").names(command)
                        && !NativeTypedWords(typed: "Run the tests").names(command) && !NativeTypedWords(typed: "run make pdfs").names(command),
                    "A command is typed only when the command itself was typed, with or without code marks")
        try require(typed.names(all: [ana]) && !typed.names(all: [ana, service]) && !typed.names(all: []),
                    "Every target has to be typed, and an action with no targets is not typed by default")
        let many = NativeTypedWords(typed: "now", earlier: (0..<200).map { "message \($0)" })
        try require(many.earlier.count == NativeTypedWords.limit && many.earlier.last == "message 199", "Only the most recent earlier messages are kept")
        print("  typed words OK (addresses, longer look-alikes, quoted text, not from the message box, earlier in the chat, services, files, commands, every target)")
    }
}
