import Foundation

@MainActor
extension SelfTest {
    static func runRuleRows() async throws {
        let require = NativeTaskFixture.require
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15))!
        let day: TimeInterval = 86_400
        let command = NativeCommandTools.toolID
        let thread = "rows-thread"
        var places = RulePlaces()
        places.chats = ["rows-greenhouse": "Greenhouse notes", "rows-braces": "Notes about {name}"]
        places.companionThreadID = thread
        places.projects = ["rows-garden": "Garden"]
        places.schedules = ["rows-frost": "Frost check"]
        places.work = ["rows-book": "Book the workshop inspection", "rows-blank": " "]

        func record(_ scope: NativeRuleScope = .everywhere, action: NativeActionClass? = nil, tool: String? = nil, target: NativeRuleTarget? = nil,
                    effect: NativeRuleEffect = .allow, statement: String = "Saved from a card", origin: NativeRuleOrigin = .confirmCard,
                    from conversation: String? = nil, created: Date? = nil, status: NativeRuleStatus = .active,
                    uses: Int? = nil, expires: Date? = nil) -> NativeRuleRecord {
            NativeRuleRecord(scope: scope, action: action, toolID: tool, target: target, effect: effect, statement: statement, origin: origin,
                             originConversationID: conversation, remainingUses: uses, expiresAt: expires, status: status,
                             createdAt: created ?? now)
        }
        func row(_ record: NativeRuleRecord) -> RuleRow { RuleRows.row(record, places: places, now: now, calendar: calendar) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rule-rows-\(UUID().uuidString)", isDirectory: true)
        let seedlingsPath = root.appendingPathComponent("Seedlings").path
        let cuttingsPath = root.appendingPathComponent("Cuttings").path
        try FileManager.default.createDirectory(atPath: seedlingsPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cuttingsPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let pdf = NativeRuleTarget.make(.commandPrefix, "make pdf"), let seedlings = NativeRuleTarget.folder(seedlingsPath),
              let cuttings = NativeRuleTarget.folder(cuttingsPath), let workshop = NativeRuleTarget.make(.recipient, "workshop@example.com"),
              let garden = NativeRuleTarget.make(.service, "garden.example") else {
            throw NativeTaskFixture.Failure.assertion("The rule row fixtures build their targets")
        }

        let prefixed = record(.conversation("rows-greenhouse"), action: .commands, tool: command, target: pdf,
                              statement: "In this chat, allow commands that start with something else")
        try require(RuleRows.sentence(prefixed) == "Always allow commands that start with make pdf",
                    "A command prefix row reads from the target, not the stored sentence: \(RuleRows.sentence(prefixed))")
        let neverEdit = record(action: .fileEdits, target: seedlings, effect: .forbid, statement: "Never allow file edits in somewhere")
        try require(RuleRows.sentence(neverEdit) == "Never allow file edits in Seedlings", "A folder never names its folder: \(RuleRows.sentence(neverEdit))")
        let combined = "Always allow file edits in A and B"
        let first = record(action: .fileEdits, target: seedlings, statement: combined)
        let second = record(action: .fileEdits, target: cuttings, statement: combined)
        try require(RuleRows.sentence(first) == "Always allow file edits in Seedlings" && RuleRows.sentence(second) == "Always allow file edits in Cuttings",
                    "Two folders saved from one card each name only their own folder")
        let trash = record(action: .trash, target: seedlings, effect: .forbid, statement: "Never move things anywhere")
        try require(RuleRows.sentence(trash) == "Never allow moving things in Seedlings to the Trash", "A trash row names its folder: \(RuleRows.sentence(trash))")
        let sendAllow = record(action: .networkSends, tool: "mail", target: workshop, statement: "In this chat, allow sending")
        let sendNever = record(action: .networkSends, tool: "mail", target: workshop, effect: .forbid, statement: "Never send")
        let serviceAllow = record(action: .networkSends, target: garden, statement: "Allow the service")
        let serviceNever = record(action: .networkSends, target: garden, effect: .forbid, statement: "Never the service")
        let twins = RuleRows.toolNames([(id: "a", title: "Mail", hints: ["mail.example", "mail send"]),
                                        (id: "b", title: "Mail", hints: ["post.example", "mail post"]),
                                        (id: "c", title: "Garden log", hints: ["garden.example"])])
        try require(twins["a"] == "Mail (mail.example)" && twins["b"] == "Mail (post.example)" && twins["c"] == "Garden log",
                    "Two tools with the same title are told apart by where they send, and a unique title stays plain")
        let sameHost = RuleRows.toolNames([(id: "a", title: "Mail", hints: ["mail.example", "send mail"]),
                                           (id: "b", title: "mail", hints: ["mail.example", "archive mail"])])
        try require(sameHost["a"] != sameHost["b"] && sameHost["a"] == "Mail (mail.example, send mail)",
                    "Two tools with the same title on the same server are told apart by their own names")
        let bare = RuleRows.toolNames([(id: "a", title: "Mail", hints: []), (id: "b", title: "Mail", hints: ["mail.example"]),
                                       (id: "c", title: "Mail", hints: ["mail.example"])])
        try require(Set(bare.values).count == 3 && bare["a"] == "Mail (1)" && RuleRows.toolNames([]).isEmpty,
                    "Tools that can't be told apart by anything they declare are numbered, and nothing crashes on an empty list")
        let twinA = record(action: .networkSends, tool: "a", target: workshop, statement: "x")
        let twinB = record(action: .networkSends, tool: "b", target: workshop, statement: "x")
        try require(RuleRows.sentence(twinA, tools: twins) != RuleRows.sentence(twinB, tools: twins),
                    "Rules for two same-titled tools sending to one person never read the same")
        let named = ["mail": "Mail", "post": "Garden log"]
        let otherTool = record(action: .networkSends, tool: "post", target: workshop, statement: "In this chat, allow sending")
        try require(RuleRows.sentence(sendAllow, tools: named) != RuleRows.sentence(otherTool, tools: named)
                    && RuleRows.sentence(otherTool, tools: named) == "Always allow sending to workshop@example.com through Garden log"
                    && RuleRows.sentence(otherTool) == "Always allow sending to workshop@example.com through a tool that's no longer here"
                    && !RuleRows.sentence(otherTool).contains("post"),
                    "Two tools allowed to send to the same person read differently, and an unknown tool never shows its identifier")
        try require(RuleRows.sentence(sendAllow, tools: named) == "Always allow sending to workshop@example.com through Mail"
                    && RuleRows.sentence(sendNever, tools: named) == "Never allow sending to workshop@example.com through Mail"
                    && RuleRows.sentence(serviceAllow) == "Always allow sending to garden.example"
                    && RuleRows.sentence(serviceNever) == "Never allow sending to garden.example",
                    "Recipient and service rows name who they send to")
        let neverRun = record(.conversation("rows-greenhouse"), tool: command, effect: .forbid, statement: "Never run commands in this chat")
        try require(RuleRows.sentence(neverRun) == "Never run commands", "A whole command never reads plainly: \(RuleRows.sentence(neverRun))")
        let gardenLog = record(action: .networkSends, tool: "garden-log", statement: "In this chat, allow: Post to the garden log")
        try require(RuleRows.sentence(gardenLog) == "Always allow: Post to the garden log", "A whole tool row names the tool: \(RuleRows.sentence(gardenLog))")
        let unnamedTool = record(action: .networkSends, tool: "garden-log", statement: "Allowed the garden log")
        try require(RuleRows.sentence(unnamedTool) == "Always allow: this action", "A tool with no name in its sentence falls back: \(RuleRows.sentence(unnamedTool))")
        let askTool = record(action: .networkSends, tool: "garden-log", effect: .ask, statement: "Ask: Post to the garden log")
        let handTool = record(action: .networkSends, tool: "garden-log", effect: .handOff, statement: "Leave: Post to the garden log")
        try require(RuleRows.sentence(askTool).hasPrefix("Always ask before") && RuleRows.sentence(handTool).hasPrefix("Always leave to you"),
                    "Ask and hand off rows lead with what happens: \(RuleRows.sentence(askTool)) / \(RuleRows.sentence(handTool))")

        try require(RuleRows.place(.everywhere, places: places) == "everywhere", "Everywhere reads as everywhere")
        try require(RuleRows.place(.conversation("rows-greenhouse"), places: places) == "in Greenhouse notes", "A chat place names the chat")
        try require(RuleRows.place(.conversation(thread), places: places) == "in {name}'s thread", "The companion thread uses the name template")
        let threadRow = row(record(.conversation(thread), action: .networkSends, tool: "garden-log", statement: "In this chat, allow: Post to the garden log"))
        try require(CompanionSentence.plain(threadRow.line, name: "Ada").contains("in Ada's thread")
                    && CompanionSentence.plain(threadRow.line, name: nil).contains("in your companion's thread"),
                    "The companion thread place follows the saved name: \(threadRow.line)")
        try require(RuleRows.place(.project("rows-garden"), places: places) == "in the Garden project", "A project place names the project")
        try require(RuleRows.place(.schedule("rows-frost"), places: places) == "for the schedule Frost check", "A schedule place names the schedule")
        try require(RuleRows.place(.task("rows-book"), places: places) == "for Book the workshop inspection", "A task place names the work")
        try require(RuleRows.place(.task("rows-blank"), places: places) == "for background work", "A task with no title reads as background work")
        let braces = row(record(.conversation("rows-braces"), action: .networkSends, tool: "garden-log", statement: "Allow: Post"))
        try require(!braces.line.contains(CompanionSentence.placeholder) && !CompanionSentence.plain(braces.line, name: "Ada").contains("Ada"),
                    "A chat title with the name placeholder is never filled with the companion's name: \(braces.line)")

        let clock = try NSRegularExpression(pattern: ":[0-9]{2}")
        func timeless(_ text: String?, _ id: String) throws {
            guard let text else { return }
            let range = NSRange(text.startIndex..., in: text)
            try require(clock.firstMatch(in: text, range: range) == nil && !text.contains(id), "No clock time or record id in \(text)")
        }
        let today = record(origin: .confirmCard, from: "rows-greenhouse")
        let yesterday = record(origin: .confirmCard, from: "rows-greenhouse", created: now.addingTimeInterval(-day))
        let november = record(origin: .confirmCard, from: "rows-greenhouse", created: calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!)
        let lastYear = record(origin: .confirmCard, from: "rows-greenhouse", created: calendar.date(from: DateComponents(year: 2025, month: 12, day: 24, hour: 9))!)
        let noChat = record(origin: .confirmCard)
        let goneChat = record(origin: .confirmCard, from: "rows-missing")
        let fromThread = record(origin: .confirmCard, from: thread)
        let carried = record(origin: .migration, from: "rows-greenhouse")
        let fromSettings = record(origin: .settings)
        func source(_ record: NativeRuleRecord) -> String? { RuleRows.source(record, places: places, now: now, calendar: calendar) }
        try require(source(today) == "From a card in Greenhouse notes, today", "Same day source: \(source(today) ?? "nil")")
        try require(source(yesterday) == "From a card in Greenhouse notes, yesterday", "Yesterday source: \(source(yesterday) ?? "nil")")
        try require(source(november) == "From a card in Greenhouse notes, November 3", "Same year source: \(source(november) ?? "nil")")
        try require(source(lastYear) == "From a card in Greenhouse notes, December 24, 2025", "Earlier year source: \(source(lastYear) ?? "nil")")
        try require(source(noChat) == "From a card, today" && source(goneChat) == "From a card, today", "A card with no known chat still says when")
        try require(source(fromThread) == "From a card in {name}'s thread, today", "A card from the companion thread uses the template")
        try require(source(carried) == "Carried over from an earlier version", "A migrated rule says it was carried over")
        try require(source(fromSettings) == nil, "A rule set in Settings has no source line")
        for item in [today, yesterday, november, lastYear, noChat, goneChat, fromThread, carried, fromSettings] { try timeless(source(item), item.id) }

        func limit(_ record: NativeRuleRecord) -> String? { RuleRows.limit(record, now: now, calendar: calendar) }
        let once = record(action: .networkSends, tool: "mail", uses: 1)
        let twice = record(action: .networkSends, tool: "mail", uses: 2)
        let tonight = record(action: .networkSends, tool: "mail", expires: now.addingTimeInterval(2 * 3600))
        let tomorrow = record(action: .networkSends, tool: "mail", expires: now.addingTimeInterval(day))
        let friday = record(action: .networkSends, tool: "mail", expires: now.addingTimeInterval(3 * day))
        let later = record(action: .networkSends, tool: "mail", expires: now.addingTimeInterval(20 * day))
        try require(limit(once) == "1 use left" && limit(twice) == "2 uses left", "Use counts read plainly")
        try require(limit(tonight) == "expires today", "Later today: \(limit(tonight) ?? "nil")")
        try require(limit(tomorrow) == "until tomorrow", "Tomorrow: \(limit(tomorrow) ?? "nil")")
        try require(limit(friday) == "until Friday", "Within the week names the weekday: \(limit(friday) ?? "nil")")
        try require(limit(later) == "until November 30", "Further out names the date: \(limit(later) ?? "nil")")
        for item in [once, twice, tonight, tomorrow, friday, later] { try timeless(limit(item), item.id); try timeless(row(item).note, item.id) }
        let switchedOff = row(record(action: .networkSends, tool: "mail", status: .disabled, uses: 1))
        try require(switchedOff.off && switchedOff.note?.hasPrefix("Switched off") == true, "A switched off rule says so first: \(switchedOff.note ?? "nil")")

        let chatAllow = record(.conversation("rows-greenhouse"), action: .networkSends, tool: "mail", target: workshop)
        let projectNever = record(.project("rows-garden"), action: .networkSends, tool: "mail", target: workshop, effect: .forbid)
        let chatAsk = record(.conversation("rows-greenhouse"), action: .networkSends, tool: "garden-log", effect: .ask, statement: "Ask: Post")
        let projectHand = record(.project("rows-garden"), action: .networkSends, tool: "garden-log", effect: .handOff, statement: "Leave: Post")
        let everywhereAllow = record(action: .networkSends, tool: "mail", target: workshop)
        let taskAllow = record(.task("rows-book"), action: .networkSends, tool: "mail", target: workshop)
        let scheduleNever = record(.schedule("rows-frost"), action: .networkSends, tool: "mail", target: workshop, effect: .forbid)
        try require(RuleRows.widens(chatAllow) && RuleRows.widens(projectNever) && RuleRows.widens(neverRun),
                    "Allow and never rules in a chat or project can apply everywhere")
        try require(![everywhereAllow, taskAllow, scheduleNever, chatAsk, projectHand].contains(where: RuleRows.widens),
                    "Everywhere, task, schedule, ask and hand off rules never offer to apply everywhere")
        try require(RuleRows.widenQuestion(chatAllow) == nil && RuleRows.widenQuestion(scheduleNever) == nil && RuleRows.widenQuestion(chatAsk) == nil,
                    "Only a never that widens asks first")
        try require(RuleRows.widenQuestion(neverRun) == "Never run commands, in every chat and in background work?",
                    "The widen question for a chat's never: \(RuleRows.widenQuestion(neverRun) ?? "nil")")
        let offEverywhere = record(action: .networkSends, tool: "mail", target: workshop, status: .disabled)
        try require(row(everywhereAllow).menuTitles == ["Switch off"] && row(offEverywhere).menuTitles == ["Switch on"]
                    && row(chatAllow).menuTitles == ["Switch off", "Apply everywhere"],
                    "Saved rows offer switch and apply everywhere only where they fit")
        let chatRuleRow = RuleRows.chatRow(conversationID: "rows-greenhouse", action: .fileEdits, choice: .ask, places: places)
        try require(chatRuleRow.menuTitles.isEmpty && chatRuleRow.toggleTitle == nil, "A stricter chat row has only Remove")
        try require([everywhereAllow, offEverywhere, chatAllow].allSatisfy { row($0).toggleTitle != nil },
                    "A saved row has a menu next to Remove")

        let older = record(action: .networkSends, tool: "mail", target: workshop, created: now.addingTimeInterval(-day))
        let newer = record(action: .networkSends, tool: "mail", target: garden, created: now)
        let revoked = record(action: .networkSends, tool: "mail", status: .revoked)
        let unknown = record(.conversation("rows-elsewhere"), action: .networkSends, tool: "mail")
        let inChat = record(.conversation("rows-greenhouse"), action: .networkSends, tool: "mail")
        let inProject = record(.project("rows-garden"), action: .networkSends, tool: "mail")
        let inSchedule = record(.schedule("rows-frost"), action: .networkSends, tool: "mail")
        let inTask = record(.task("rows-book"), action: .networkSends, tool: "mail")
        let chatRules: [(id: String, rules: NativeConversationRules)] = [(id: "rows-greenhouse", rules: NativeConversationRules(choices: [.fileEdits: .ask]))]
        let listed = RuleRows.rows(records: [inTask, inSchedule, inChat, revoked, older, unknown, inProject, newer], chatRules: chatRules,
                                   places: places, now: now, calendar: calendar)
        try require(listed.prefix(6).map(\.id) == [newer.id, older.id, inProject.id, inChat.id, inSchedule.id, inTask.id],
                    "Rows run everywhere, project, chat, schedule, task, newest first: \(listed.map(\.sentence))")
        try require(!listed.contains { $0.id == revoked.id || $0.id == unknown.id }, "Removed rules and rules for unknown places never show")
        try require(RuleRows.chatSentence(.commands, .handOff) == "Always leave commands to me"
                    && RuleRows.chatSentence(.networkSends, .actIfPreapproved) == "Always wait for my go-ahead before sending"
                    && RuleRows.chatSentence(.trash, .ask) == "Always ask before moving files to the Trash"
                    && NativeActionClass.configurable.allSatisfy { action in
                        NativeRuleChoice.allCases.allSatisfy { choice in
                            let sentence = RuleRows.chatSentence(action, choice)
                            return !sentence.contains(":") && !sentence.lowercased().split(separator: " ").contains { $0 == "you" || $0 == "your" }
                        }
                    }, "A stricter chat reads as a sentence like every other row")
        try require(listed.count == 7 && listed[6].sentence == "Always ask before file edits" && listed[6].place == "in Greenhouse notes",
                    "A stricter chat adds its own row: \(listed.last?.line ?? "none")")
        let again = RuleRows.rows(records: [inChat], chatRules: chatRules, places: places, now: now, calendar: calendar)
        try require(again.last?.id == listed[6].id, "A stricter chat row keeps its id")

        let kept = record(.conversation("rows-kept"), action: .networkSends, tool: "mail")
        let gone = record(.conversation("rows-gone"), action: .networkSends, tool: "mail")
        let unsure = record(.conversation("rows-unsure"), action: .networkSends, tool: "mail")
        let wide = record(action: .networkSends, tool: "mail")
        let alreadyGone = record(.conversation("rows-gone"), action: .networkSends, tool: "mail", status: .revoked)
        let behind = RuleRows.leftBehind([kept, gone, unsure, wide, alreadyGone]) { scope -> Bool? in
            switch scope {
            case .conversation("rows-kept"): return true
            case .conversation("rows-unsure"): return nil
            case .everywhere: return true
            default: return false
            }
        }
        try require(behind == [gone.id], "Only a rule whose place is surely gone is left behind: \(behind)")
        try require(RuleRows.leftBehind([wide, alreadyGone]) { _ in false }.isEmpty, "Everywhere rules and removed rules are never left behind")

        let every = [prefixed, neverEdit, first, second, trash, sendAllow, sendNever, serviceAllow, serviceNever, neverRun, gardenLog, unnamedTool,
                     askTool, handTool, today, yesterday, november, lastYear, noChat, goneChat, fromThread, carried, fromSettings, once, tonight,
                     friday, later, chatAllow, projectNever, chatAsk, projectHand, taskAllow, scheduleNever, offEverywhere,
                     record(.conversation(thread), action: .networkSends, tool: "garden-log", statement: "Allow: Post to the garden log", from: thread),
                     record(.task("rows-blank"), action: .networkSends, tool: "mail"), record(.conversation("rows-braces"), action: .networkSends, tool: "mail")]
        let everyRow = RuleRows.rows(records: every, chatRules: chatRules, places: places, now: now, calendar: calendar)
        try require(everyRow.count == every.count + 1, "Every fixture shape shows a row")
        let internalWords: Set<String> = ["grant", "kind", "class", "record", "origin", "scope", "prefix", "effect", "revoke"]
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        }
        for name in ["Ada", nil] as [String?] {
            for text in RuleRows.screenStrings(everyRow, name: name) {
                let hits = words(text).intersection(internalWords)
                try require(hits.isEmpty, "Saved rule copy uses no internal words: \(hits) in \(text)")
                try require(!text.contains("Ver" + "a") && !text.contains(CompanionSentence.placeholder), "Saved rule copy names no default and fills the name: \(text)")
            }
            for text in RulesCopy.screenStrings(name: name) {
                let hits = words(text).intersection(internalWords)
                try require(hits.isEmpty, "Rules screen copy uses no internal words: \(hits) in \(text)")
                try require(!text.contains("Ver" + "a") && !text.contains(CompanionSentence.placeholder), "Rules screen copy names no default: \(text)")
            }
        }
        try require(RulesCopy.info(for: .fileEdits, choice: .act).hasSuffix(RulesCopy.imagesNote), "Editing files explains it covers saved images")
        try require(!RulesCopy.info(for: .commands, choice: .ask).contains(RulesCopy.imagesNote), "Other kinds never mention images")
        print("  rule rows OK (sentences from targets, places, sources, limits, menus, order, chat rows, left behind, copy)")
    }

    static func runRuleRowsStore() async throws {
        let require = NativeTaskFixture.require
        let store = ChatStore()
        store.prepareRuleRecords()
        guard let local = store.repository as? LocalChatRepository else {
            throw NativeTaskFixture.Failure.assertion("The rule rows store opens a local database")
        }
        let database = local.database
        let command = NativeCommandTools.toolID
        func chat(_ id: String, _ title: String) {
            store.conversations.insert(Conversation(id: id, title: title, messages: [], updatedAt: Date()), at: 0)
        }
        func decision(_ conversation: String, _ text: String) -> NativeRuleDecision {
            store.nativeRuleSource.resolver(for: conversation, requestText: "").tool(command, targets: []).decision(forCommand: text)
        }
        func row(_ id: String) -> RuleRow? { store.ruleRows().first { $0.id == id } }
        func stored(_ id: String) -> NativeRuleRecord? { store.ruleRecords.first { $0.id == id } }
        func save(_ record: NativeRuleRecord) throws -> NativeRuleRecord {
            guard let saved = store.addRuleRecord(record) else { throw NativeTaskFixture.Failure.assertion("The store saves \(record.statement)") }
            return saved
        }
        func allow(_ scope: NativeRuleScope, from conversation: String? = nil) -> NativeRuleRecord {
            NativeRuleRecord(scope: scope, action: .networkSends, toolID: "garden-log", effect: .allow, statement: "Allow: Post to the garden log",
                             origin: .confirmCard, originConversationID: conversation)
        }
        guard let pdf = NativeRuleTarget.make(.commandPrefix, "make pdf") else { throw NativeTaskFixture.Failure.assertion("The prefix target builds") }
        chat("rows-a", "Greenhouse notes")
        chat("rows-b", "Seed orders")

        func prefix() -> NativeRuleRecord {
            NativeRuleRecord(scope: .conversation("rows-a"), action: .commands, toolID: command, target: pdf, effect: .allow,
                             statement: "Always allow commands that start with make pdf", origin: .confirmCard, originConversationID: "rows-a")
        }
        let removable = try save(prefix())
        try require(decision("rows-a", "make pdf") == .act(.grant), "A saved prefix lets the command run in its chat")
        guard let removableRow = row(removable.id) else { throw NativeTaskFixture.Failure.assertion("The saved prefix is listed") }
        store.removeRule(removableRow)
        try require(row(removable.id) == nil && stored(removable.id)?.status == .revoked && decision("rows-a", "make pdf") == .ask,
                    "Remove takes the rule back and the next matching command asks again")

        let toggled = try save(prefix())
        guard let onRow = row(toggled.id) else { throw NativeTaskFixture.Failure.assertion("The second prefix is listed") }
        store.toggleRule(onRow)
        guard let offRow = row(toggled.id) else { throw NativeTaskFixture.Failure.assertion("A switched off rule stays listed") }
        try require(offRow.off && decision("rows-a", "make pdf") == .ask, "Switch off stops the rule and keeps the row")
        store.toggleRule(offRow)
        try require(row(toggled.id)?.off == false && decision("rows-a", "make pdf") == .act(.grant), "Switch on brings the rule back")
        store.revokeRuleRecord(id: toggled.id)

        let never = try save(NativeRuleRecord(scope: .conversation("rows-a"), action: nil, toolID: command, effect: .forbid,
                                              statement: "Never run commands in this chat", origin: .confirmCard, originConversationID: "rows-a"))
        try require(decision("rows-a", "ls") == .handOff && decision("rows-b", "ls") == .ask, "A chat's never stays in its chat")
        guard let neverRow = row(never.id) else { throw NativeTaskFixture.Failure.assertion("The never is listed") }
        try require(store.widenRule(neverRow) && stored(never.id)?.scope == .everywhere && decision("rows-b", "ls") == .handOff,
                    "Apply everywhere makes the never refuse commands in another chat")
        guard let widenedRow = row(never.id) else { throw NativeTaskFixture.Failure.assertion("The widened never is listed") }
        try require(!store.widenRule(widenedRow) && stored(never.id)?.scope == .everywhere, "An everywhere rule cannot widen again")
        store.revokeRuleRecord(id: never.id)
        let taskBound = try save(allow(.task("rows-task-missing")))
        let taskRow = RuleRows.row(taskBound, places: RulePlaces(), now: Date(), calendar: .current)
        let forged = RuleRow(id: taskRow.id, source: taskRow.source, sentence: taskRow.sentence, place: taskRow.place, note: nil, off: false,
                             widens: true, widenQuestion: nil)
        try require(!store.widenRule(taskRow) && !store.widenRule(forged) && stored(taskBound.id)?.scope == .task("rows-task-missing"),
                    "A task rule never widens, even from a row that claims it can")
        store.tightenConversationRule(.handOff, for: .trash, conversationID: "rows-b")
        let chatRowID = "chat|rows-b|\(NativeActionClass.trash.rawValue)"
        guard let tighterRow = row(chatRowID) else { throw NativeTaskFixture.Failure.assertion("A stricter chat is listed") }
        try require(!store.widenRule(tighterRow) && store.conversations.first { $0.id == "rows-b" }?.rules.choices[.trash] == .handOff,
                    "A stricter chat row never widens")
        store.removeRule(tighterRow)

        chat("rows-c", "Plant list")
        store.tightenConversationRule(.ask, for: .fileEdits, conversationID: "rows-c")
        let editRowID = "chat|rows-c|\(NativeActionClass.fileEdits.rawValue)"
        guard let editRow = row(editRowID) else { throw NativeTaskFixture.Failure.assertion("A chat that asks more is listed") }
        try require(editRow.sentence == "Always ask before file edits" && editRow.place == "in Plant list", "The stricter chat row reads plainly")
        var leftToMe = NativeRules.defaults
        leftToMe.set(.handOff, for: .fileEdits)
        let chatRules = store.conversations.filter { !$0.rules.isEmpty }.map { (id: $0.id, rules: $0.rules) }
        let underStricterDefault = RuleRows.rows(records: [], chatRules: chatRules, places: store.rulePlaces(for: []), defaults: leftToMe)
        try require(!underStricterDefault.contains { $0.id == editRowID } && store.ruleRows().contains { $0.id == editRowID },
                    "A chat row is hidden while the default is already as strict, and shown when it is stricter than the default")
        let unloaded = RuleRows.place(.conversation("rows-unloaded"), places: RulePlaces(chats: ["rows-unloaded": ""]))
        try require(unloaded == RuleRows.lostChat && RuleRows.place(.project("p"), places: RulePlaces(projects: ["p": ""])) == RuleRows.lostProject
                    && RuleRows.place(.schedule("s"), places: RulePlaces(schedules: ["s": ""])) == RuleRows.lostSchedule,
                    "A place that exists but could not be read still gets a row that can be removed")
        store.removeRule(editRow)
        try require(store.conversations.first { $0.id == "rows-c" }?.rules.isEmpty == true && row(editRowID) == nil,
                    "Remove puts the chat back on the defaults")

        let heard = NativeChatRulesCounter()
        let observer = NotificationCenter.default.addObserver(forName: .ruleRecordsChanged, object: nil, queue: nil) { _ in heard.hit() }
        defer { NotificationCenter.default.removeObserver(observer) }
        func announces(_ label: String, _ change: () throws -> Void) throws {
            heard.reset()
            try change()
            try require(heard.count >= 1, "\(label) tells the Rules screen")
        }
        func quiet(_ label: String, _ change: () throws -> Void) throws {
            heard.reset()
            try change()
            try require(heard.count == 0, "\(label) stays quiet when nothing changed")
        }
        var announced: NativeRuleRecord?
        try announces("Adding a rule") { announced = try save(allow(.conversation("rows-a"))) }
        guard let announcedID = announced?.id else { throw NativeTaskFixture.Failure.assertion("The announced rule saves") }
        try announces("Switching a rule off") { try require(store.disableRuleRecord(id: announcedID), "The rule switches off") }
        try announces("Switching a rule on") { try require(store.enableRuleRecord(id: announcedID), "The rule switches on") }
        try announces("Removing a rule") { try require(store.revokeRuleRecord(id: announcedID), "The rule is removed") }
        try announces("Making a chat stricter") { store.tightenConversationRule(.ask, for: .fileEdits, conversationID: "rows-c") }
        try announces("Clearing a stricter chat") { store.clearConversationRule(for: .fileEdits, conversationID: "rows-c") }
        _ = try save(allow(.conversation("rows-gone-chat")))
        try announces("Removing a place's rules") { store.removeRules(for: .conversation("rows-gone-chat")) }
        try quiet("Removing a place's rules again") { store.removeRules(for: .conversation("rows-gone-chat")) }
        let swept = try save(allow(.conversation("rows-never-existed")))
        try announces("The launch pass") { try require(store.sweepRuleRecords() >= 1, "The launch pass removes the rule") }
        try require(stored(swept.id)?.status == .revoked, "The swept rule is removed")
        try quiet("The launch pass again") { try require(store.sweepRuleRecords() == 0, "A second pass finds nothing") }

        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
        let posted = NativeChatRulesCounter()
        let send = NativeToolDefinition(id: "capability-garden_log", name: "garden_log", title: "Post to the garden log",
                                        description: "Post a line to the garden log",
                                        parameters: .object(["type": .string("object"), "properties": .object(["line": .object(["type": .string("string")])]),
                                                             "required": .array([.string("line")])]),
                                        confirmation: .none, action: .networkSends, isAvailable: { true },
                                        execute: { _ in posted.hit(); return .object(["posted": .bool(true)]) })
        let rounds = [[NativeChatStreamSnapshot(content: "", toolCalls: [
            NativeChatToolCall(id: "send-call", name: "garden_log", arguments: "{\"line\":\"Watered the beans\"}"),
        ], finishReason: "tool_calls")], [NativeChatStreamSnapshot(content: "Posted.", toolCalls: [], finishReason: "stop")]]
        let carding = ChatStore(nativeConfig: config, nativeTransport: ScriptedNativeToolTransport(rounds: rounds),
                                repository: try LocalChatRepository(inMemory: true), nativeEnabledToolIDs: [send.id], nativeRules: .defaults,
                                nativeToolRegistry: NativeToolRegistry(definitions: [send]), artifactPersistenceEnabled: false)
        await carding.connect()
        carding.newConversation()
        carding.sendText("Post the note to the garden log")
        var waited = 0
        while carding.turnConfirmations.isEmpty && waited < 500 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        guard let (messageID, card) = carding.turnConfirmations.first.map({ ($0.key, $0.value) }) else {
            throw NativeTaskFixture.Failure.assertion("The card fixture shows a card")
        }
        heard.reset()
        carding.resolveTurnConfirmation(messageID, decision: .allowHere, requestID: card.id, token: carding.turnConfirmationTokens[messageID])
        waited = 0
        while carding.generating && waited < 500 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        try require(heard.count >= 1 && carding.ruleRecords.contains { $0.toolID == send.id }, "Saving from a card tells the Rules screen")

        chat("rows-delete", "Old chat")
        let chatBound = try save(allow(.conversation("rows-delete"), from: "rows-delete"))
        let wideFromChat = try save(NativeRuleRecord(scope: .everywhere, action: .networkSends, toolID: "mail", effect: .allow,
                                                     statement: "Allow: Send mail", origin: .confirmCard, originConversationID: "rows-delete"))
        store.deleteConversation("rows-delete", confirmed: true)
        try require(stored(chatBound.id)?.status == .revoked && stored(wideFromChat.id)?.status == .active,
                    "Deleting a chat removes its rules and keeps an everywhere rule saved there")
        store.sweepRuleRecords()
        try require(stored(wideFromChat.id)?.status == .active && row(wideFromChat.id) != nil,
                    "The launch pass keeps an everywhere rule whose chat is gone")

        guard let project = store.createProject(name: "Garden") else { throw NativeTaskFixture.Failure.assertion("The project fixture saves") }
        let projectBound = try save(allow(.project(project.id)))
        try require(row(projectBound.id)?.place == "in the Garden project", "A project rule names its project")
        store.deleteProject(project.id)
        try require(stored(projectBound.id)?.status == .revoked, "Deleting a project removes its rules")

        store.nativeScheduleStore = NativeScheduleStore(database: database)
        store.reloadSchedules()
        var draft = NativeScheduleDraft()
        draft.title = "Frost check"
        draft.instruction = "Check the forecast for frost"
        guard let schedule = store.createSchedule(draft) else { throw NativeTaskFixture.Failure.assertion("The schedule fixture saves") }
        let scheduleBound = try save(allow(.schedule(schedule.id)))
        try require(row(scheduleBound.id)?.place == "for the schedule Frost check", "A schedule rule names its schedule")
        store.deleteSchedule(schedule.id)
        try require(stored(scheduleBound.id)?.status == .revoked, "Deleting a schedule removes its rules")

        let years = Date().addingTimeInterval(-3 * 365 * 86_400)
        let oldClock = NativeRuleRecordStore(database: database, now: { years })
        let ancient = try oldClock.add(allow(.conversation("rows-a")))
        let orphan = try oldClock.add(allow(.conversation("rows-no-such-chat")))
        try local.saveConversation(Conversation(id: "rows-stored", title: "Stored only", messages: [], updatedAt: Date()))
        let storedOnly = try oldClock.add(allow(.conversation("rows-stored")))
        let tasks = NativeTaskStore(database: database)
        let payload = try JSONSerialization.data(withJSONObject: ["title": "Book the workshop inspection"])
        let running = try tasks.create(workerType: "rules-fixture", payload: payload, idempotencyKey: "rule-rows-running")
        let finished = try tasks.create(workerType: "rules-fixture", payload: payload, idempotencyKey: "rule-rows-finished")
        _ = try tasks.cancel(finished.id)
        let liveWork = try save(allow(.task(running.id)))
        let doneWork = try save(allow(.task(finished.id)))
        store.reloadRuleRecords()
        try require(ancient.createdAt < Date().addingTimeInterval(-2 * 365 * 86_400), "The old rule really is old")
        try require(row(liveWork.id)?.place == "for Book the workshop inspection", "Running work is named by its title")
        store.sweepRuleRecords()
        try require(stored(ancient.id)?.status == .active, "The launch pass keeps a very old rule whose chat still exists")
        try require(stored(storedOnly.id)?.status == .active, "The launch pass keeps a rule whose chat is only on disk")
        try require(row(storedOnly.id)?.place == "in Stored only", "A rule whose chat is only on disk is still listed, named from the saved chat")
        try require(stored(orphan.id)?.status == .revoked, "The launch pass removes a rule whose chat is gone")
        try require(stored(taskBound.id)?.status == .revoked, "The launch pass removes a rule for work that does not exist")
        try require(stored(liveWork.id)?.status == .active && stored(doneWork.id)?.status == .revoked,
                    "The launch pass keeps rules for running work and removes them for finished work")

        let attachments = FileManager.default.temporaryDirectory.appendingPathComponent("rule-rows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: attachments) }
        let blind = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil, attachmentStore: NativeAttachmentStore(directory: attachments))
        try require(blind.ruleScopeExists(.conversation("rows-x")) == nil && blind.ruleScopeExists(.project("rows-x")) == nil
                    && blind.ruleScopeExists(.schedule("rows-x")) == nil && blind.ruleScopeExists(.task("rows-x")) == nil
                    && blind.ruleScopeExists(.everywhere) == true, "A store that cannot check keeps every rule")
        try require(blind.sweepRuleRecords() == 0, "The launch pass with no database removes nothing")
        print("  rule rows store OK (remove, switch off and on, apply everywhere, stricter chat, change notices, card save, delete chat project schedule, launch pass)")
    }
}
