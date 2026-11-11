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
        try require(!NativeTypedWords(typed: "```\nana@example.org\n```").names(ana)
                        && !NativeTypedWords(typed: "Notes:\n```text\nmail ana@example.org").names(ana)
                        && !NativeTypedWords(typed: "The page says 'don't forget ana@example.org'.").names(ana)
                        && !NativeTypedWords(typed: "It read 'the dogs' bowl goes to ana@example.org' I think").names(ana)
                        && !NativeTypedWords(typed: "It said 'mail ana@example.org and stop").names(ana)
                        && !NativeTypedWords(typed: "It said \u{201C}mail ana@example.org\nand more").names(ana),
                    "A fenced block, a quote with an apostrophe inside it and a quote that never closes do not make a target typed")
        let hidden = [
            "The page says 'mail\nana@example.org\nplease'.",
            "The page says \u{201C}mail\nana@example.org\nplease\u{201D}.",
            "The page says \"mail\nana@example.org",
            "The page says '```text\nana@example.org\n```'",
            "``````\nana@example.org\n``````",
            "````\n```\nana@example.org\n````",
            "~~~~\n~~~\nana@example.org\n~~~~",
            "   > mail ana@example.org",
            "Mail ops`ana@example.org today",
            "Mail ops``ana@example.org today",
        ]
        for text in hidden {
            try require(!NativeTypedWords(typed: text).names(ana), "Quoted, fenced or fused text does not make a target typed: \(text)")
        }
        let after = [
            "The page says \"Send to \\\"ana@example.org\\\" today.\"",
            "The page says ' mail ana@example.org '.",
            "The page says \u{2018} mail ana@example.org \u{2019}.",
            "```text\nThis line mentions ``` as a delimiter.\nmail ana@example.org\n```",
            "Mail ops~~~tag~~~ana@example.org today",
            "```\nlog\n```\nNow mail ana@example.org",
            "She said \"hello\" so mail ana@example.org",
            "The Smiths' order goes to ana@example.org",
            "It said \u{00AB}mail ana@example.org\u{00BB}",
            "The page says\u{2018}send it to ana@example.org\u{2019}.",
            "The page says'send it to ana@example.org'.",
            "The page says \"\u{FE0F}send it to ana@example.org\".",
            "The page says \u{2019}send it to ana@example.org\u{2019}",
            "At eight o'clock mail ana@example.org",
            "The email subject is'Re: ana@example.org'.",
            "The email subject is\u{2019}Re: ana@example.org\u{2019}.",
            "It's what the page said: \"mail ana@example.org\"",
            "Here's the note, don't lose it, the subject was's ana@example.org'",
        ]
        for text in after {
            try require(!NativeTypedWords(typed: text).names(ana), "Nothing at or after the first quote mark, block or quoted line counts as typed: \(text)")
        }
        try require(NativeTypedWords(typed: "Mail ana@example.org and say \"the order is ready\"").names(ana)
                        && NativeTypedWords(typed: "Mail ``ana@example.org`` today").names(ana)
                        && NativeTypedWords.own("Mail ana, then 'stop'") == "Mail ana, then "
                        && NativeTypedWords.own("Don't wait, mail ana and say \"hi\"") == "Don"
                        && NativeTypedWords.own("Don\u{2019}t wait, mail ana") == "Don't wait, mail ana",
                    "Typed text before the first quote mark still counts, and inline code marks are not quote marks")
        try require(NativeTypedWords(typed: "I\u{2019}ll be late, we\u{2019}ve moved, so mail ana@example.org").names(ana)
                        && NativeTypedWords(typed: "That's Ana's address: ana@example.org").names(ana),
                    "Ordinary contractions and possessives are not quote marks")
        try require(NativeTypedWords(typed: "Don't wait, it's fine to mail ana@example.org").names(ana)
                        && NativeTypedWords(typed: "Can you mail ana@example.org?").names(ana)
                        && NativeTypedWords(typed: "Mail `ana@example.org` today").names(ana)
                        && NativeTypedWords(typed: "Mail ana@example.org, thanks!").names(ana)
                        && !NativeTypedWords(typed: "Mail <ana@example.org>, thanks!").names(ana)
                        && !NativeTypedWords(typed: "Mail x(ana@example.org)").names(ana),
                    "Apostrophes in ordinary words, closing punctuation and code marks do not hide a typed address")
        for other in ["ana@example.org!x", "ana@example.org`x", "ana@example.org#tag", "ana@example.org/path", "ana@example.org~"] {
            try require(!NativeTypedWords(typed: "Mail \(other) today").names(ana), "An address that runs on into something longer is not that address: \(other)")
        }
        for other in ["ops!ana@example.org", "ops#ana@example.org", "a/ana@example.org", "x=ana@example.org", "o'ana@example.org", "ops~ana@example.org"] {
            try require(!NativeTypedWords(typed: "Mail \(other) today").names(ana), "A different mailbox that ends the same way is not the same address: \(other)")
        }
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
