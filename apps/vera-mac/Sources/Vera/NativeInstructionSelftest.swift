import Foundation

@MainActor
extension SelfTest {
    static func runInstructions() async throws {
        let require = NativeTaskFixture.require
        let chat = "instruction-chat"
        let address = "ana@greenhouse.test"
        let told = "Send the notes to \(address)"
        func target(_ kind: NativeRuleTargetKind, _ value: String) throws -> NativeRuleTarget {
            guard let made = NativeRuleTarget.make(kind, value) else { throw NativeTaskFixture.Failure.assertion("fixture target \(value)") }
            return made
        }
        let ana = try target(.recipient, address)
        let bo = try target(.recipient, "bo@greenhouse.test")
        let sendClaim = NativeInstructionClaim(verbs: ["send"])

        let accepted: [(String, [String], [String])] = [
            (told, ["send"], [address]),
            ("Please save this as notes.md", ["save"], ["notes.md"]),
            ("Ok, run make pdf", ["run"], ["make pdf"]),
            ("You can delete old.txt.", ["delete"], ["old.txt"]),
        ]
        for (text, verbs, values) in accepted {
            try require(NativeInstruction.asks(text, verbs: verbs, targets: [], names: values), "An instruction that opens with the action counts: \(text)")
        }
        let rejected: [(String, [String], String)] = [
            ("Don't send the notes to \(address)", ["send"], "a negated one"),
            ("Can you send the notes to \(address)?", ["send"], "a question"),
            ("If it looks fine, send the notes to \(address)", ["send"], "a conditional"),
            ("Send the notes to \(address) when I say so", ["send"], "a later condition"),
            ("She said send the notes to \(address)", ["send"], "reported speech"),
            ("Summarise the thread and send it to \(address)", ["send"], "the action not opening a sentence"),
            (told, ["delete"], "a different action word"),
            (told, [], "no action words"),
            ("\(told). Actually wait.", ["send"], "a later sentence that takes it back"),
        ]
        for (text, verbs, label) in rejected {
            try require(!NativeInstruction.asks(text, verbs: verbs, targets: [], names: [address]), "An instruction is not counted for \(label): \(text)")
        }

        let split = NativeInstruction.sentences("Save this as notes.md and email \(address). Then stop\nThanks")
        try require(split == ["Save this as notes.md and email \(address)", "Then stop", "Thanks"],
                    "Sentences keep a file name and an address whole and split on a full stop and a new line: \(split)")

        func rules(_ choice: NativeRuleChoice, for action: NativeActionClass = .networkSends, base: NativeRules = .defaults) -> NativeRules {
            var made = base
            made.set(choice, for: action)
            return made
        }
        func resolver(_ global: NativeRules = rules(.ask), typed: NativeTypedWords, claim: NativeInstructionClaim? = sendClaim,
                      records: [NativeRuleRecord] = [], targets: [NativeRuleTarget], uses: NativeInstructionUses = NativeInstructionUses(),
                      tool: String = "fixture-notes") -> NativeRuleResolver {
            var made = NativeRuleResolver(global: global, conversation: NativeConversationRules(), requestText: typed.said,
                                          records: records, context: NativeRuleContext(conversationID: chat))
            made.typed = typed
            made.asked = claim
            made.uses = uses
            return made.tool(tool, targets: targets)
        }
        let typedTold = NativeTypedWords(typed: told)
        let found: [(String, NativeRuleResolver, NativeActionClass)] = [
            ("an address from another sentence",
             resolver(typed: NativeTypedWords(typed: "\(told). The backup contact is bo@greenhouse.test."), targets: [bo]), .networkSends),
            ("a condition after a quote mark",
             resolver(typed: NativeTypedWords(typed: "Send the notes to \(address) with subject \"Draft\" only if I approve."), targets: [ana]), .networkSends),
            ("a question mark after a quote mark",
             resolver(typed: NativeTypedWords(typed: "Send the notes to \(address) titled \"Draft\"?"), targets: [ana]), .networkSends),
            ("an alias that is also part of a later word",
             resolver(typed: NativeTypedWords(typed: "Send the update to a after lunch."), targets: [try target(.recipient, "a")]), .networkSends),
        ]
        for (label, made, action) in found {
            try require(made.decision(for: action) == .ask, "An instruction does not count for \(label)")
        }
        let saveClaim = NativeInstructionClaim(verbs: NativeFolderTools.verbs[.fileEdits] ?? [])
        let trashClaim = NativeInstructionClaim(verbs: NativeFolderTools.verbs[.trash] ?? [])
        let draft = try target(.folder, "/shared/drafts/notes.txt")
        let finalCopy = try target(.folder, "/shared/final/notes.txt")
        let deleteDraft = NativeTypedWords(typed: "Delete /shared/drafts/notes.txt")
        try require(resolver(rules(.ask, for: .trash), typed: deleteDraft, claim: trashClaim, targets: [draft]).decision(for: .trash) == .act(.instruction)
                        && resolver(rules(.ask, for: .trash), typed: deleteDraft, claim: trashClaim, targets: [finalCopy]).decision(for: .trash) == .ask,
                    "A typed path allows that file and not another file with the same name")
        let copyNotes = NativeTypedWords(typed: "Copy notes.md to backup.md")
        try require(resolver(rules(.ask, for: .fileEdits), typed: copyNotes, claim: saveClaim, targets: [try target(.folder, "/shared/notes.md")])
                        .decision(for: .fileEdits) == .ask,
                    "Asking for a copy does not allow writing over the file being copied")
        let runClaim = NativeInstructionClaim(verbs: NativeCommandTools.verbs)
        let spacedRun = NativeTypedWords(typed: "Run `make pdf`")
        let runUses = NativeInstructionUses()
        let tight = resolver(rules(.ask, for: .commands), typed: spacedRun, claim: runClaim, targets: [], uses: runUses, tool: NativeCommandTools.toolID)
        let tightQuery = tight.query(for: .commands, command: "make pdf")
        let wideQuery = tight.query(for: .commands, command: "make  pdf")
        guard let tightSignature = tight.instructed(tightQuery, honoringLimitedUse: false) else {
            throw NativeTaskFixture.Failure.assertion("A typed plain command is instructed")
        }
        try require(tight.instructed(wideQuery, honoringLimitedUse: false) == tightSignature, "Extra spaces in a command do not make it a different use")
        runUses.take(tightSignature)
        try require(tight.instructed(wideQuery, honoringLimitedUse: false) == nil, "The same command with extra spaces is spent with the first run")
        func command(_ typed: String, runs command: String) -> Bool {
            let made = resolver(rules(.ask, for: .commands), typed: NativeTypedWords(typed: typed), claim: runClaim, targets: [], tool: NativeCommandTools.toolID)
            return made.instructed(made.query(for: .commands, command: command), honoringLimitedUse: false) != nil
        }
        try require(command("Run make pdf", runs: "make pdf") && command("Please run `make pdf`.", runs: "make pdf"),
                    "A typed command allows exactly that command")
        for (typed, ran) in [("Run make -n", "make"), ("Run echo make", "make"), ("Run make", "make -n"), ("Run make pdf", "make PDF"),
                             ("Run make pdf now", "make pdf"), ("Run make pdf and send it", "make pdf"), ("Run `make clean. all`", "make clean"),
                             ("Run make clean. Then stop", "make clean"), ("Run make clean\nall", "make clean"), ("Run make pdf.", "make pdf.x"), ("Run `make pdf`.", "make pdf ."), ("Run make pdf.", "make pdf."), ("Run `make pdf` .", "make pdf ."), ("Run `make` pdf", "make pdf"),
                             ("Run ``make pdf``", "make pdf"), ("Run `make pdf", "make pdf"), ("Run make `pdf`", "make pdf"), ("Run ` make pdf `", "make pdf")] {
            try require(!command(typed, runs: ran), "Typing \(typed) does not allow running \(ran)")
        }
        let drafts = try target(.folder, "/shared/drafts")
        try require(resolver(rules(.ask, for: .trash), typed: deleteDraft, claim: trashClaim, targets: [drafts]).decision(for: .trash) == .ask,
                    "Naming a file does not allow moving its folder to the Trash")
        for typed in ["Delete /shared/drafts._backup/notes.txt", "Delete /shared/drafts./notes.txt", "Delete /shared/drafts-old", "Delete /shared/drafts.bak"] {
            try require(resolver(rules(.ask, for: .trash), typed: NativeTypedWords(typed: typed), claim: trashClaim, targets: [drafts]).decision(for: .trash) == .ask,
                        "A longer typed path does not name a shorter one: \(typed)")
        }
        try require(resolver(rules(.ask, for: .trash), typed: NativeTypedWords(typed: "Delete /shared/drafts."), claim: trashClaim, targets: [drafts])
                        .decision(for: .trash) == .act(.instruction)
                        && command("Run make pdf.", runs: "make pdf") && command("Run `make pdf`.", runs: "make pdf"),
                    "A full stop that ends the message is not part of the path or command")
        let loose = try target(.folder, "/shared/notes.txt")
        for typed in ["Delete /shared/prefix:notes.txt", "Delete x,notes.txt", "Delete my-notes.txt", "Delete ~notes.txt", "Delete other/notes.txt",
                      "Delete /shared/archive(notes.txt)", "Delete /shared/archive(/shared/notes.txt)", "Delete `` /shared/notes.txt` ``",
                      "Delete (notes.txt)", "Delete `notes.txt`x", "Delete `/shared/notes.txt,`", "Delete `, notes.txt`", "Delete `old notes.txt`", "Delete `x/notes.txt`", "Delete notes.txt and `other.txt`", "Delete `notes.txt.`", "Delete `notes.txt;` now", "Delete x`notes.txt`", "Delete ``notes.txt``", "Delete `notes.txt` and `other.txt`"] {
            try require(resolver(rules(.ask, for: .trash), typed: NativeTypedWords(typed: typed), claim: trashClaim, targets: [loose]).decision(for: .trash) == .ask,
                        "A file name that is only the end of something longer is not that file: \(typed)")
        }
        try require(resolver(rules(.ask, for: .trash), typed: NativeTypedWords(typed: "Delete notes.txt"), claim: trashClaim, targets: [loose])
                        .decision(for: .trash) == .act(.instruction)
                        && resolver(rules(.ask, for: .trash), typed: NativeTypedWords(typed: "Delete `notes.txt`."), claim: trashClaim, targets: [loose])
                            .decision(for: .trash) == .act(.instruction),
                    "A file name typed on its own, with or without code marks, is that file")
        try require(command("Run `make pdf` .", runs: "make pdf") && command("  Run   make   pdf  ", runs: "make pdf"),
                    "The command in code marks is the command, whatever closing punctuation follows")
        let upper = try target(.folder, "/shared/drafts/Notes.txt")
        try require(resolver(rules(.ask, for: .trash), typed: deleteDraft, claim: trashClaim, targets: [upper]).decision(for: .trash) == .ask
                        && resolver(rules(.ask, for: .trash), typed: NativeTypedWords(typed: "Delete notes.txt"), claim: trashClaim, targets: [upper])
                            .decision(for: .trash) == .ask,
                    "A file name in different letter case is a different file")
        let renamed = try target(.folder, "/shared/old notes.txt")
        let moving = resolver(rules(.ask, for: .fileEdits), typed: NativeTypedWords(typed: "Create `old notes.txt` from draft.txt"), claim: saveClaim, targets: [])
            .tool("fixture-notes", subjects: [[loose], [renamed]])
        try require(moving.decision(for: .fileEdits) == .ask
                        && resolver(rules(.ask, for: .fileEdits), typed: NativeTypedWords(typed: "Save notes.md and hello.md"), claim: saveClaim, targets: [])
                            .tool("fixture-notes", subjects: [[try target(.folder, "/shared/notes.md")], [try target(.folder, "/shared/hello.md")]])
                            .decision(for: .fileEdits) == .ask
                        && resolver(rules(.ask, for: .fileEdits), typed: NativeTypedWords(typed: "Create `old notes.txt`"), claim: saveClaim, targets: [renamed])
                            .decision(for: .fileEdits) == .act(.instruction),
                    "An instruction covers a call aimed at one file, never one that touches two")
        let alias = try target(.recipient, "ana")
        let longer = try target(.recipient, "ana!archive@greenhouse.test")
        for typed in ["Send the notes to `ana!archive@greenhouse.test`", "Send the notes to ana!archive@greenhouse.test", "Send the notes to ana#x and ana$y"] {
            let made = resolver(typed: NativeTypedWords(typed: typed), targets: []).tool("fixture-notes", subjects: [[longer], [alias]])
            try require(made.decision(for: .networkSends) == .ask, "A shorter name inside a longer address is not a second recipient: \(typed)")
            try require(!NativeTypedWords(typed: typed).names(alias), "And it is not typed for the unnamed-recipient check either: \(typed)")
        }
        try require(resolver(typed: NativeTypedWords(typed: "Send the notes to ana and bo@greenhouse.test!"), targets: [])
                        .tool("fixture-notes", subjects: [[alias], [bo]]).decision(for: .networkSends) == .act(.instruction),
                    "Two recipients each named on their own both count, with closing punctuation after the last")
        let service = try target(.service, "https://api.greenhouse.test")
        for typed in ["Send the notes to https://api.greenhouse.test:8443", "Send the notes to https://api.greenhouse.test/other",
                      "Send the notes to https://api.greenhouse.test.evil.test", "Send the notes to x:https://api.greenhouse.test",
                      "Send the notes to =https://api.greenhouse.test", "Send the notes to https://relay.greenhouse.test/(https://api.greenhouse.test)",
                      "Send the notes to https://api.greenhouse.test/..",
                      "Send the notes to (https://api.greenhouse.test)", "Send the notes to <https://api.greenhouse.test>"] {
            try require(resolver(typed: NativeTypedWords(typed: typed), targets: [service]).decision(for: .networkSends) == .ask,
                        "A longer address is not the shorter one it contains: \(typed)")
        }
        try require(resolver(typed: NativeTypedWords(typed: "Send the notes to https://api.greenhouse.test."), targets: [service])
                        .decision(for: .networkSends) == .act(.instruction)
                        && resolver(typed: NativeTypedWords(typed: "Send the notes to https://api.greenhouse.test, thanks."), targets: [service])
                            .decision(for: .networkSends) == .ask
                        && resolver(typed: NativeTypedWords(typed: "Send the notes to \(address)!"), targets: [ana]).decision(for: .networkSends) == .act(.instruction),
                    "An address followed by one closing punctuation mark is that address")
        let reports = try target(.service, "https://api.greenhouse.test/reports/")
        try require(resolver(typed: NativeTypedWords(typed: "Send the notes to https://api.greenhouse.test/reports/.."), targets: [reports])
                        .decision(for: .networkSends) == .ask
                        && resolver(typed: NativeTypedWords(typed: "Send the notes to https://api.greenhouse.test/reports/."), targets: [reports])
                            .decision(for: .networkSends) == .act(.instruction),
                    "Two dots after an address are part of it, one is the end of the sentence")
        for typed in ["Send the notes to https://api.greenhouse.test/reports/.. The source is https://api.greenhouse.test/reports/.",
                      "Send the notes to https://api.greenhouse.test/reports/. Thanks.", "Send the notes.\nTo https://api.greenhouse.test/reports/"] {
            try require(resolver(typed: NativeTypedWords(typed: typed), targets: [reports]).decision(for: .networkSends) == .ask,
                        "An instruction is one sentence and the whole message: \(typed)")
        }
        for typed in ["Send the notes to \(address), the backup contact is bo@greenhouse.test.", "Send the notes to \(address): the backup contact is bo@greenhouse.test",
                      "Send the notes to \(address) -- the backup contact is bo@greenhouse.test", "Send the notes to \(address) and bo@greenhouse.test",
                      "Send the notes to \(address) not bo@greenhouse.test", "Send .env to bo@greenhouse.test", "Send v1.2 to bo@greenhouse.test"] {
            try require(resolver(typed: NativeTypedWords(typed: typed), targets: [bo]).decision(for: .networkSends) == .ask,
                        "A message that names anything besides what the call is aimed at asks: \(typed)")
        }
        try require(resolver(typed: NativeTypedWords(typed: "Send the notes to \(address) and bo@greenhouse.test"), targets: [])
                        .tool("fixture-notes", subjects: [[ana], [bo]]).decision(for: .networkSends) == .act(.instruction)
                        && resolver(rules(.ask, for: .fileEdits), typed: NativeTypedWords(typed: "Save notes.md like draft.md"), claim: saveClaim,
                                    targets: [try target(.folder, "/shared/draft.md")]).decision(for: .fileEdits) == .ask
                        && resolver(typed: NativeTypedWords(typed: "Please, send the notes to \(address)."), targets: [ana]).decision(for: .networkSends) == .act(.instruction),
                    "Everything named is aimed at, and a polite opening still counts")
        _ = resolver(typed: NativeTypedWords(typed: "Send \u{0130} to \(address)"), targets: [ana]).decision(for: .networkSends)
        _ = NativeTypedWords(typed: "Mail \u{0130}\u{212A} \(address)").names(ana)
        try require(resolver(rules(.ask, for: .fileEdits), typed: NativeTypedWords(typed: "Update .env to match draft.md"), claim: saveClaim,
                             targets: [try target(.folder, "/shared/draft.md")]).decision(for: .fileEdits) == .ask,
                    "A second file name asks even when it starts with a dot")
        for typed in ["Delete notes.txt and backup-2026.", "Delete notes.txt and backup_old", "Delete notes.txt and backup2", "Delete notes.txt and *",
                      "Delete notes.txt and $HOME", "Delete notes.txt (and others)", "Delete notes.txt & more", "Delete notes.txt\tand more"] {
            try require(resolver(rules(.ask, for: .trash), typed: NativeTypedWords(typed: typed), claim: trashClaim, targets: [loose]).decision(for: .trash) == .ask,
                        "Anything besides plain words next to the named file asks: \(typed)")
        }
        for typed in ["Delete notes.txt and the parent directory ..", "Delete notes.txt and .", "Delete notes.txt!!", "Delete notes.txt and more..."] {
            try require(resolver(rules(.ask, for: .trash), typed: NativeTypedWords(typed: typed), claim: trashClaim, targets: [loose]).decision(for: .trash) == .ask,
                        "More than one closing mark at the end is not sentence punctuation: \(typed)")
        }
        try require(resolver(rules(.ask, for: .trash), typed: NativeTypedWords(typed: "Delete notes.txt now."), claim: trashClaim, targets: [loose])
                        .decision(for: .trash) == .act(.instruction),
                    "One closing full stop is sentence punctuation")
        let hello = try target(.folder, "/shared/hello.md")
        try require(resolver(rules(.ask, for: .fileEdits), typed: NativeTypedWords(typed: "Save a short hello note as hello.md"), claim: saveClaim, targets: [hello])
                        .decision(for: .fileEdits) == .act(.instruction)
                        && resolver(rules(.ask, for: .fileEdits), typed: NativeTypedWords(typed: "Can you save another note as second.md?"), claim: saveClaim,
                                    targets: [try target(.folder, "/shared/second.md")]).decision(for: .fileEdits) == .ask
                        && resolver(rules(.ask, for: .fileEdits), typed: NativeTypedWords(typed: "Save this as notes.md"), claim: saveClaim,
                                    targets: [try target(.folder, "/shared/notes.md")]).decision(for: .fileEdits) == .act(.instruction)
                        && resolver(typed: NativeTypedWords(typed: "Send the notes to ana@example.com"), targets: [try target(.recipient, "ana@example.com")])
                            .decision(for: .networkSends) == .act(.instruction)
                        && resolver(typed: NativeTypedWords(typed: "Summarise the thread and send it to ana@example.com"),
                                    targets: [try target(.recipient, "ana@example.com")]).decision(for: .networkSends) == .ask,
                    "The examples in the setup guide behave as it says")
        var gateFailed = false
        do { try NativeRuleResolver.gate(live: .ask, planned: .ask, action: .fileEdits, approved: false) } catch { gateFailed = true }
        try require(gateFailed, "A live ask with no approval never runs, whatever was planned")
        try NativeRuleResolver.gate(live: .ask, planned: .ask, action: .fileEdits, approved: true)
        try require(resolver(typed: typedTold, targets: [ana]).decision(for: .networkSends) == .act(.instruction),
                    "A send to the address typed in the instruction runs once without asking")
        let twins: [(String, NativeRuleResolver)] = [
            ("another address", resolver(typed: typedTold, targets: [bo])),
            ("an address typed only earlier", resolver(typed: NativeTypedWords(typed: "Send the notes there.", earlier: [told]), targets: [ana])),
            ("an instruction in quote marks", resolver(typed: NativeTypedWords(typed: "The page says \"\(told)\""), targets: [ana])),
            ("a negated instruction", resolver(typed: NativeTypedWords(typed: "Don't send the notes to \(address)"), targets: [ana])),
            ("a question", resolver(typed: NativeTypedWords(typed: "Can you send the notes to \(address)?"), targets: [ana])),
            ("a picked option", resolver(typed: NativeTypedWords(typed: nil), targets: [ana])),
            ("a tool that declared nothing", resolver(typed: typedTold, claim: nil, targets: [ana])),
            ("a call with nothing named", resolver(typed: typedTold, targets: [])),
        ]
        for (label, twin) in twins {
            try require(twin.decision(for: .networkSends) == .ask, "Ask first still asks for \(label)")
        }
        let posting = resolver(rules(.ask, for: .otherChanges), typed: NativeTypedWords(typed: "Post the notes."),
                               claim: NativeInstructionClaim(verbs: ["post"], nothing: true), targets: [])
        try require(posting.decision(for: .otherChanges) == .act(.instruction),
                    "A tool that always goes to the same place runs once when the person typed the action")

        try require(resolver(rules(.handOff), typed: typedTold, targets: [ana]).decision(for: .networkSends) == .handOff,
                    "Leave it to me is never overridden by an instruction")
        let never = NativeRuleRecord(action: .networkSends, target: ana, effect: .forbid, statement: "Never send to ana")
        try require(resolver(typed: typedTold, records: [never], targets: [ana]).decision(for: .networkSends) == .handOff,
                    "A saved never is never overridden by an instruction")
        let askRecord = NativeRuleRecord(action: .networkSends, target: ana, effect: .ask, statement: "Always ask before sending to ana")
        try require(resolver(rules(.act), typed: typedTold, records: [askRecord], targets: [ana]).decision(for: .networkSends) == .ask,
                    "A saved always ask is never overridden by an instruction")
        guard let payments = NativeFloorItem.payments.actionClass else { throw NativeTaskFixture.Failure.assertion("payments has an action") }
        let payTyped = NativeTypedWords(typed: "Pay the invoice.")
        let payClaim = NativeInstructionClaim(verbs: ["pay"], nothing: true)
        try require(resolver(.defaults, typed: payTyped, claim: payClaim, targets: []).decision(for: payments) == .handOff,
                    "Payments that aren't turned on stay with the person")
        var opened = NativeRules.defaults
        opened.lift(.payments, choice: .ask)
        try require(resolver(opened, typed: payTyped, claim: payClaim, targets: []).decision(for: payments) == .act(.instruction),
                    "Once payments are turned on and set to ask, the typed instruction runs once")
        var broken = resolver(typed: typedTold, targets: [ana])
        broken.failed = true
        try require(broken.decision(for: .networkSends) == .ask, "Rules that failed to load never act on an instruction")

        let both = NativeTypedWords(typed: "Send the notes to \(address) and bo@greenhouse.test")
        let shared = NativeInstructionUses()
        let first = resolver(typed: typedTold, targets: [ana], uses: shared)
        guard let signature = first.instructed(first.query(for: .networkSends), honoringLimitedUse: false) else {
            throw NativeTaskFixture.Failure.assertion("The instruction gives a signature")
        }
        try require(shared.take(signature) && !shared.take(signature), "A signature is spent once")
        try require(first.decision(for: .networkSends) == .ask, "The same send asks after it ran once")
        try require(resolver(typed: both, targets: [bo], uses: shared).decision(for: .networkSends) == .ask
                        && resolver(typed: both, targets: [], uses: shared).tool("fixture-notes", subjects: [[ana], [bo]])
                            .decision(for: .networkSends) == .act(.instruction),
                    "A message naming two addresses covers one send to both, not a send to one of them")
        try require(resolver(typed: NativeTypedWords(typed: "Thanks, that's all."), targets: [ana]).decision(for: .networkSends) == .ask,
                    "The next message without the instruction asks")

        func source(_ global: NativeRules, records: [NativeRuleRecord] = []) -> NativeRuleSource {
            let made = NativeRuleSource()
            made.setGlobal(global)
            made.setRecords(records)
            return made
        }
        let goAhead = "Run the tests. Go ahead."
        let preapproved = ChatStore.commandDecision(source(rules(.actIfPreapproved, for: .commands)), conversationID: chat, requestText: goAhead,
                                                    typed: NativeTypedWords(typed: goAhead), uses: NativeInstructionUses(),
                                                    command: "make test", action: .commands, subjects: [])
        try require(preapproved.decision == .act(.requestPreapproval), "Go ahead still works as before: \(preapproved.decision)")

        let sent = NativeChatRulesCounter()
        func sender(_ confirmation: NativeToolConfirmation) -> NativeToolDefinition {
            var made = NativeToolDefinition(id: "fixture-notes", name: "send_notes", title: "Send the notes", description: "Fixture",
                                            parameters: .object(["type": .string("object")]), confirmation: confirmation, effect: .write,
                                            action: .networkSends, isAvailable: { true },
                                            execute: { _ in sent.hit(); return .object(["sent": .bool(true)]) })
            made.ruleSubjects = { arguments in
                guard case .string(let to)? = arguments["to"], let target = NativeRuleTarget.make(.recipient, to) else { return [] }
                return [[target]]
            }
            made.verbs = ["send"]
            return made
        }
        let mail = sender(.none)
        let asking = source(rules(.ask))
        let call: [String: NativeJSONValue] = ["to": .string(address)]
        let turnUses = NativeInstructionUses()
        let wrapped = ChatStore.ruled(mail, rules: asking, store: nil, conversationID: chat, requestText: told, typed: typedTold, uses: turnUses)
        try require(wrapped.confirmationFor?(call) == false, "The instructed send shows no card")
        let sink = NativeToolReasonSink()
        _ = try await NativeToolCallContext.$confirmed.withValue(false) {
            try await NativeToolCallContext.$reason.withValue(sink) { try await wrapped.execute(call) }
        }
        try require(sent.count == 1 && sink.value == .instruction, "It runs once without a card and reports why")
        try require(wrapped.confirmationFor?(call) == true, "The same send now needs the card")
        var again: String?
        do { _ = try await NativeToolCallContext.$confirmed.withValue(false) { try await wrapped.execute(call) } } catch { again = error.localizedDescription }
        try require(again != nil && sent.count == 1, "The same send never runs twice on one instruction")
        try require(wrapped.confirmationFor?(["to": .string("bo@greenhouse.test")]) == true, "A send to another address needs the card")
        let strictWrapped = ChatStore.ruled(sender(.required), rules: asking, store: nil, conversationID: chat, requestText: told, typed: typedTold,
                                            uses: NativeInstructionUses())
        try require(strictWrapped.confirmationFor?(call) == true, "A tool that always asks still asks")

        sent.reset()
        let loopTool = ChatStore.ruled(mail, rules: asking, store: nil, conversationID: chat, requestText: told, typed: typedTold,
                                       uses: NativeInstructionUses())
        let arguments = "{\"to\":\"\(address)\"}"
        let transport = ScriptedNativeToolTransport(rounds: [
            [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: "first", name: "send_notes", arguments: arguments)],
                                      finishReason: "tool_calls")],
            [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: "second", name: "send_notes", arguments: arguments)],
                                      finishReason: "tool_calls")],
            [NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")],
        ])
        let loop = NativeToolLoop(transport: transport, registry: NativeToolRegistry(definitions: [loopTool]),
                                  confirm: { (_: NativeToolActivity) async -> Bool in false })
        var final: NativeToolTurnSnapshot?
        for try await snapshot in loop.stream(messages: [NativeChatMessage(role: "user", content: told)], model: "local-model",
                                              enabledToolIDs: ["fixture-notes"]) {
            final = snapshot
        }
        let steps = final?.activities ?? []
        try require(steps.count == 2 && steps[0].state == .succeeded && steps[0].ranBecause == .instruction
                        && steps[1].state == .failed && steps[1].ranBecause == nil && steps[1].confirmationRequired && sent.count == 1,
                    "In a reply the first send runs and says why, the repeat asks: \(steps.map { ($0.state, $0.ranBecause as Any) })")

        let commands = source(rules(.ask, for: .commands))
        func command(_ typed: String, _ line: String, uses: NativeInstructionUses = NativeInstructionUses()) -> NativeRuleVerdict {
            ChatStore.commandDecision(commands, conversationID: chat, requestText: typed, typed: NativeTypedWords(typed: typed), uses: uses,
                                      command: line, action: .commands, subjects: NativeCommandTools.ruleSubjects(command: line))
        }
        let commandUses = NativeInstructionUses()
        let pdf = command("Run `make pdf`", "make pdf", uses: commandUses)
        try require(pdf.decision == .act(.instruction), "A typed command in code marks runs once: \(pdf.decision)")
        try require(pdf.confirm?() == true && command("Run `make pdf`", "make pdf", uses: commandUses).decision == .ask,
                    "Running it spends the instruction")
        try require(command("Run the tests", "make test").decision == .ask, "A command the person didn't type asks")
        try require(command("Run `make pdf && rm x`", "make pdf && rm x").decision == .ask, "A command with more than one step asks even typed in full")

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("instructed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let grant = try FolderGrant.make(url: base)
        let recorder = NativeCommandRunRecorder()
        let typedRun = "Run `echo hi`"
        let live = ChatStore.commandLive(commands, store: nil, conversationID: chat, requestText: typedRun, typed: NativeTypedWords(typed: typedRun),
                                         uses: NativeInstructionUses())
        let runner = NativeCommandTools.definitions(grants: { [grant] }, decision: .ask, reason: { _ in nil }, record: { recorder.add($0) },
                                                    live: live.live, liveTargets: live.liveTargets)
        let runTransport = ScriptedNativeToolTransport(rounds: [
            [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: "run", name: NativeCommandTools.runName,
                                                                                  arguments: "{\"command\":\"echo hi\"}")], finishReason: "tool_calls")],
            [NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")],
        ])
        let runLoop = NativeToolLoop(transport: runTransport, registry: NativeToolRegistry(definitions: runner),
                                     confirm: { (_: NativeToolActivity) async -> Bool in false })
        for try await _ in runLoop.stream(messages: [NativeChatMessage(role: "user", content: typedRun)], model: "local-model",
                                          enabledToolIDs: [NativeCommandTools.toolID]) {}
        let ran = recorder.recorded
        try require(ran.count == 1 && ran[0].outcome == .ran && ran[0].reason == .instruction
                        && ran[0].decisionLine == "Ran because you asked for this",
                    "A typed command runs without a card and its card says why: \(ran.map { ($0.outcome, $0.reason as Any) })")

        let folder = source(rules(.ask, for: .fileEdits, base: rules(.ask, for: .trash)))
        let notes = try target(.folder, base.path + "/notes.md")
        let old = try target(.folder, base.path + "/old.txt")
        func folderDecision(_ typed: String, _ action: NativeActionClass, _ file: NativeRuleTarget) -> NativeRuleDecision {
            ChatStore.folderDecision(folder, conversationID: chat, requestText: typed, typed: NativeTypedWords(typed: typed),
                                     uses: NativeInstructionUses(), action: action, subjects: [[file]]).decision
        }
        try require(folderDecision("Save this as notes.md", .fileEdits, notes) == .act(.instruction), "A typed save runs once")
        try require(folderDecision("Delete old.txt", .trash, old) == .act(.instruction), "A typed delete runs once")
        try require(folderDecision("Save this as notes.md", .trash, notes) == .ask, "A save never stands in for a delete")

        let plain = NativeToolActivity(id: "a1", toolID: "fixture-notes", name: "send_notes", title: "Send the notes", round: 0, request: "{}",
                                       result: "{}", state: .succeeded, confirmationRequired: false)
        let plainData = try JSONEncoder().encode(plain)
        try require(!String(decoding: plainData, as: UTF8.self).contains("ranBecause"), "An old saved step has no reason field")
        let decoded = try JSONDecoder().decode(NativeToolActivity.self, from: plainData)
        var marked = plain
        marked.ranBecause = .instruction
        let markedBack = try JSONDecoder().decode(NativeToolActivity.self, from: try JSONEncoder().encode(marked))
        try require(decoded == plain && decoded.ranBecause == nil && markedBack.ranBecause == .instruction,
                    "Old saved steps still load and the reason survives saving")
        try require(NativeRuleReason.instruction.title == "Ran because you asked for this", "The reason reads plainly")

        print("  instructions OK (matcher table, sentences, resolver twins, nothing named, never overrides, single use, go ahead, tool card, reply steps, commands, command card reason, folder saves and deletes, old steps)")
    }
}
