import Foundation

@MainActor
extension SelfTest {
    static func runNativeCardChoices() throws {
        let require = NativeTaskFixture.require
        let chat = NativeCardPlace.chat(conversationID: "c1")
        let task = NativeCardPlace.task(taskID: "t1", conversationID: "c1", scheduleID: nil)
        let command = NativeCardSubject(action: .commands, toolID: NativeCommandTools.toolID, toolTitle: "Run a command", command: "git status --short")
        func kinds(_ subject: NativeCardSubject, _ place: NativeCardPlace) -> [NativeCardChoiceKind] {
            NativeCardChoices.offered(subject, place: place).map(\.kind)
        }
        func title(_ subject: NativeCardSubject, _ place: NativeCardPlace, _ kind: NativeCardChoiceKind) -> String? {
            NativeCardChoices.offered(subject, place: place).first { $0.kind == kind }?.title
        }
        func valid(_ record: NativeRuleRecord) -> Bool {
            (try? NativeRuleRecord.validated(record, creating: true)) != nil
        }

        for (place, here, never, words) in [(chat, NativeRuleScope.conversation("c1"), "Never run commands in this chat", "Always allow in this chat"),
                                           (task, NativeRuleScope.task("t1"), "Never run commands for this work", "Always allow for this work")] {
            try require(kinds(command, place) == [.decline, .never, .allowAlways, .allowHere, .allowOnce], "A simple command card offers every choice: \(place)")
            try require(title(command, place, .never) == never && title(command, place, .allowHere) == words, "The command card names its place: \(place)")
            try require(NativeCardChoices.covers(command) == "commands that start with git status", "A command card covers its two-word prefix")
            let always = NativeCardChoices.records(.allowAlways, subject: command, place: place, originMessageID: nil)
            try require(always.count == 1 && always[0].scope == .everywhere && always[0].action == .commands && always[0].toolID == NativeCommandTools.toolID
                        && always[0].target == NativeRuleTarget.make(.commandPrefix, "git status") && always[0].effect == .allow
                        && always[0].origin == .confirmCard && always[0].statement == "Always allow commands that start with git status" && valid(always[0]),
                        "Always allow saves one everywhere prefix allow: \(place)")
            let hereRecords = NativeCardChoices.records(.allowHere, subject: command, place: place, originMessageID: nil)
            try require(hereRecords.count == 1 && hereRecords[0].scope == here && valid(hereRecords[0]), "Allow here is scoped to the chat or the task: \(place)")
            let nevers = NativeCardChoices.records(.never, subject: command, place: place, originMessageID: nil)
            try require(!nevers.isEmpty && nevers.allSatisfy { $0.effect == .forbid && $0.target == nil && $0.scope == here && $0.scope != .everywhere
                            && $0.toolID == NativeCommandTools.toolID && valid($0) },
                        "Never on a command card saves forbids naming the command tool in that place only: \(place)")
            for odd in [NativeCardSubject(action: .commands, toolID: NativeCommandTools.toolID, toolTitle: "Run a command", command: "git status | cat"),
                        NativeCardSubject(action: .riskyCommands, toolID: NativeCommandTools.toolID, toolTitle: "Run a command", command: "sudo git status"),
                        NativeCardSubject(action: .networkSends, toolID: NativeCommandTools.toolID, toolTitle: "Run a command", command: "git push origin main")] {
                let offered = kinds(odd, place)
                try require(!offered.contains(.allowHere) && !offered.contains(.allowAlways) && offered.contains(.never) && offered.contains(.allowOnce)
                            && offered.contains(.decline), "A command that is not a plain command only offers never, once and decline: \(odd.command ?? "")")
                try require(NativeCardChoices.records(.allowAlways, subject: odd, place: place, originMessageID: nil).isEmpty
                            && NativeCardChoices.records(.never, subject: odd, place: place, originMessageID: nil).allSatisfy { $0.target == nil && valid($0) },
                            "A command that is not a plain command saves no allow and a never without a target")
            }
            for kind in NativeCardChoiceKind.allCases {
                try require(NativeCardChoices.records(kind, subject: command, place: place, originMessageID: nil).allSatisfy { $0.target?.kind != .folder },
                            "No command card record has a folder target: \(kind.rawValue)")
            }
        }

        let notes = "/Volumes/Notes/Greenhouse/notes"
        let edit = NativeCardSubject(action: .fileEdits, toolID: NativeFolderTools.toolID, toolTitle: "Edit a file",
                                     targets: [NativeRuleTarget.make(.folder, notes + "/a.txt")!])
        try require(kinds(edit, chat) == [.decline, .never, .allowAlways, .allowHere, .allowOnce], "A file edit card offers the standing choices")
        let editAlways = NativeCardChoices.records(.allowAlways, subject: edit, place: chat, originMessageID: nil)
        try require(editAlways.count == 1 && editAlways[0].target == NativeRuleTarget.make(.folder, notes) && editAlways[0].action == .fileEdits
                    && editAlways[0].effect == .allow && valid(editAlways[0]), "Always allow on an edit covers the file's folder")
        let editNever = NativeCardChoices.records(.never, subject: edit, place: chat, originMessageID: nil)
        try require(editNever.count == 1 && editNever[0].effect == .forbid && editNever[0].target == NativeRuleTarget.make(.folder, notes)
                    && editNever[0].scope == .conversation("c1") && valid(editNever[0]), "Never on an edit forbids the same folder in this chat")
        let move = NativeCardSubject(action: .fileEdits, toolID: NativeFolderTools.toolID, toolTitle: "Move a file",
                                     targets: [NativeRuleTarget.make(.folder, notes + "/a.txt")!, NativeRuleTarget.make(.folder, "/Volumes/Notes/Archive/a.txt")!])
        let moveRecords = NativeCardChoices.records(.allowHere, subject: move, place: chat, originMessageID: nil)
        try require(moveRecords.count == 2 && Set(moveRecords.compactMap(\.target?.value)) == [notes, "/Volumes/Notes/Archive"],
                    "A move across two folders saves one record per folder")
        var trash = edit
        trash.action = .trash
        let trashRecords = NativeCardChoices.records(.allowAlways, subject: trash, place: chat, originMessageID: nil)
        try require(trashRecords.count == 1 && trashRecords[0].action == .trash && valid(trashRecords[0]), "A Trash card saves a Trash record")

        let ana = NativeRuleTarget.make(.recipient, "ana@example.com")!
        let send = NativeCardSubject(action: .networkSends, toolID: "mail", toolTitle: "Send an email", targets: [ana])
        try require(kinds(send, chat) == [.decline, .never, .allowAlways, .allowHere, .allowOnce], "A send to a named recipient offers the standing choices for that recipient")
        let sendAlways = NativeCardChoices.records(.allowAlways, subject: send, place: chat, originMessageID: nil)
        try require(sendAlways.count == 1 && sendAlways[0].target == ana && sendAlways[0].effect == .allow && valid(sendAlways[0]),
                    "Always allow on a send targets that recipient and nothing wider")
        let unknown = NativeCardSubject(action: .networkSends, toolID: "post", toolTitle: "Post a note")
        try require(kinds(unknown, chat) == [.decline, .never, .allowOnce], "A sending tool that never said where it sends offers no standing allow")
        try require(NativeCardChoices.records(.allowAlways, subject: unknown, place: chat, originMessageID: nil).isEmpty
                        && NativeCardChoices.records(.allowHere, subject: unknown, place: chat, originMessageID: nil).isEmpty,
                    "No allow is saved for a sending tool that never said where it sends")
        var fixed = unknown
        fixed.fixed = true
        try require(kinds(fixed, chat) == [.decline, .never, .allowAlways, .allowHere, .allowOnce], "A sending tool that always sends to the same place keeps the standing choices")
        let fixedAlways = NativeCardChoices.records(.allowAlways, subject: fixed, place: chat, originMessageID: nil)
        try require(fixedAlways.count == 1 && fixedAlways[0].target == nil && fixedAlways[0].toolID == "post" && valid(fixedAlways[0]),
                    "Always allow on a fixed sending tool covers that tool")
        try require(NativeCardChoices.signature(fixed) != NativeCardChoices.signature(unknown), "A fixed and an unknown sending tool are different cards")
        let untyped = send
        let sendNever = NativeCardChoices.records(.never, subject: untyped, place: chat, originMessageID: nil)
        try require(sendNever.count == 1 && sendNever[0].target == ana && sendNever[0].effect == .forbid && valid(sendNever[0]),
                    "Never on a send forbids that recipient")

        let other = NativeCardSubject(action: .otherChanges, toolID: "notes-tool", toolTitle: "Update a note")
        try require(kinds(other, chat) == [.decline, .never, .allowAlways, .allowHere, .allowOnce], "A tool with no targets offers the standing choices")
        let wholeTool = NativeCardChoices.records(.allowAlways, subject: other, place: chat, originMessageID: nil)
        try require(wholeTool.count == 1 && wholeTool[0].toolID == "notes-tool" && wholeTool[0].target == nil && wholeTool[0].action == .otherChanges
                    && valid(wholeTool[0]) && NativeCardChoices.covers(other) == "this action every time", "A tool with no targets saves a whole-tool record")
        let context = NativeRuleContext(conversationID: "c1")
        try require(NativeRuleMatcher.resolve(wholeTool, query: NativeRuleQuery(action: .otherChanges, toolID: "notes-tool"), context: context, at: Date(),
                                              honoringLimitedUse: false) != nil
                    && NativeRuleMatcher.resolve(wholeTool, query: NativeRuleQuery(action: .otherChanges, toolID: "calendar-tool"), context: context, at: Date(),
                                                 honoringLimitedUse: false) == nil, "A whole-tool record never matches another tool")
        try require(NativeRuleMatcher.resolve(sendAlways, query: NativeRuleQuery(action: .networkSends, toolID: "chat-tool", targets: [ana]), context: context,
                                              at: Date(), honoringLimitedUse: false) == nil, "A recipient allow for one tool never matches another tool")

        var ungoverned = other
        ungoverned.governed = false
        try require(kinds(ungoverned, chat) == [.decline, .allowOnce], "A card outside the rules offers only once and decline")
        for action in [NativeActionClass.fileEdits, .trash] {
            let unresolved = NativeCardSubject(action: action, toolID: NativeFolderTools.toolID, toolTitle: "Write a file")
            try require(kinds(unresolved, chat) == [.decline, .allowOnce] && kinds(unresolved, task) == [.decline, .allowOnce]
                        && NativeCardChoices.records(.allowAlways, subject: unresolved, place: chat, originMessageID: nil).isEmpty
                        && NativeCardChoices.records(.never, subject: unresolved, place: chat, originMessageID: nil).isEmpty
                        && NativeCardChoices.covers(unresolved) == nil,
                        "A file card whose path could not be placed in a folder offers no saved choice")
        }
        let rooted = NativeCardSubject(action: .fileEdits, toolID: NativeFolderTools.toolID, toolTitle: "Write a file",
                                       targets: [NativeRuleTarget.make(.folder, "/notes.txt")].compactMap { $0 })
        try require(kinds(rooted, chat) == [.decline, .allowOnce], "A file at the top of the disk never yields a rule for the whole disk")
        let one = NativeCardSubject(action: .fileEdits, toolID: NativeFolderTools.toolID, toolTitle: "Create a folder",
                                    targets: [NativeRuleTarget.make(.folder, "/Volumes/Notes/Greenhouse/a/b/c")].compactMap { $0 })
        var two = one
        two.targets += [NativeRuleTarget.make(.folder, "/Volumes/Notes/Greenhouse/a/b")].compactMap { $0 }
        try require(NativeCardChoices.signature(one) == NativeCardChoices.signature(one) && NativeCardChoices.signature(one) != NativeCardChoices.signature(two)
                    && NativeCardChoices.signature(one) != NativeCardChoices.signature(other),
                    "What a saved choice would cover has a stable fingerprint that changes when the folders change")
        let split = NativeCardSubject(action: .fileEdits, toolID: NativeFolderTools.toolID, toolTitle: "Move",
                                      targets: [NativeRuleTarget.make(.folder, "/a/x"), NativeRuleTarget.make(.folder, "/b/x")].compactMap { $0 })
        let joined = NativeCardSubject(action: .fileEdits, toolID: NativeFolderTools.toolID, toolTitle: "Move",
                                       targets: [NativeRuleTarget.make(.folder, "/a\nfolder=/b/x")].compactMap { $0 })
        try require(NativeCardChoices.signature(split) != NativeCardChoices.signature(joined)
                    && NativeCardChoices.records(.allowAlways, subject: split, place: chat, originMessageID: nil).count
                        != NativeCardChoices.records(.allowAlways, subject: joined, place: chat, originMessageID: nil).count,
                    "Two folders and one folder with a line break in its name never share a fingerprint")

        let scheduled = NativeCardPlace.task(taskID: "t1", conversationID: "c1", scheduleID: "s1")
        var instructed = command
        instructed.scheduleInstructed = true
        try require(!kinds(command, scheduled).contains(.allowSchedule) && !kinds(instructed, task).contains(.allowSchedule)
                    && kinds(instructed, scheduled).contains(.allowSchedule), "Allow for this schedule needs a schedule and its instruction")
        let scheduleRecords = NativeCardChoices.records(.allowSchedule, subject: instructed, place: scheduled, originMessageID: nil)
        try require(scheduleRecords.count == 1 && scheduleRecords[0].scope == .schedule("s1") && valid(scheduleRecords[0]), "A schedule allow is scoped to that schedule")
        try require(NativeCardChoices.records(.allowSchedule, subject: command, place: task, originMessageID: nil).isEmpty
                    && NativeCardChoices.records(.allowSchedule, subject: command, place: scheduled, originMessageID: nil).isEmpty,
                    "No schedule record is saved when the choice was not offered")
        try require(NativeCardChoices.records(.allowOnce, subject: command, place: chat, originMessageID: nil).isEmpty
                    && NativeCardChoices.records(.decline, subject: command, place: chat, originMessageID: nil).isEmpty, "Once and decline save nothing")

        func commands(_ records: [NativeRuleRecord], chat: String, rules: NativeRules = .defaults) -> NativeRuleResolver {
            NativeRuleResolver(global: rules, conversation: NativeConversationRules(), requestText: "", records: records,
                               context: NativeRuleContext(conversationID: chat)).tool(NativeCommandTools.toolID, targets: [])
        }
        let alwaysRecords = NativeCardChoices.records(.allowAlways, subject: command, place: chat, originMessageID: nil)
        try require(commands(alwaysRecords, chat: "c2").decide(forCommand: "git status -s").decision == .act(.grant)
                    && commands(alwaysRecords, chat: "c2").decide(forCommand: "git push").decision == .ask,
                    "Always allow runs the prefix in another chat and still asks for a different command")
        let neverRecords = NativeCardChoices.records(.never, subject: command, place: chat, originMessageID: nil)
        var riskyAsks = NativeRules.defaults
        riskyAsks.set(.ask, for: .riskyCommands)
        let barred = commands(neverRecords, chat: "c1", rules: riskyAsks)
        try require(barred.decide(forCommand: "git status").decision == .handOff && barred.decide(forCommand: "make test").decision == .handOff
                    && barred.decide(for: .riskyCommands).decision == .handOff && barred.decide(for: .networkSends).decision == .handOff,
                    "Never in this chat hands off every command there, risky ones included")
        let taskNever = NativeCardChoices.records(.never, subject: command, place: task, originMessageID: nil)
        let taskResolver = NativeRuleResolver(global: riskyAsks, conversation: NativeConversationRules(), requestText: "", records: taskNever,
                                              context: NativeRuleContext(conversationID: "c1", taskID: "t1")).tool(NativeCommandTools.toolID, targets: [])
        let otherTask = NativeRuleResolver(global: riskyAsks, conversation: NativeConversationRules(), requestText: "", records: taskNever,
                                           context: NativeRuleContext(conversationID: "c1", taskID: "t2")).tool(NativeCommandTools.toolID, targets: [])
        try require(taskResolver.decide(forCommand: "git status").decision == .handOff && taskResolver.decide(for: .riskyCommands).decision == .handOff
                    && otherTask.decide(forCommand: "git status").decision == .ask, "Never in a task hands off every command in that task only")
        let elsewhere = commands(neverRecords, chat: "c2", rules: riskyAsks)
        try require(elsewhere.decide(forCommand: "git status").decision == .ask && elsewhere.decide(for: .riskyCommands).decision == .ask,
                    "Never in one chat leaves another chat alone")

        func folders(_ records: [NativeRuleRecord], _ action: NativeActionClass, _ paths: [String]) -> NativeRuleDecision {
            NativeRuleResolver(global: NativeRules(choices: [.fileEdits: .act, .trash: .act]), conversation: NativeConversationRules(), requestText: "",
                               records: records, context: context)
                .tool(NativeFolderTools.toolID, subjects: paths.compactMap { NativeRuleTarget.make(.folder, $0) }.map { [$0] })
                .decide(for: action).decision
        }
        try require(folders(editNever, .fileEdits, [notes + "/b.txt"]) == .handOff && folders(editNever, .fileEdits, ["/Volumes/Notes/Other/b.txt"]) == .act(.rule),
                    "Never on an edit hands off edits under that folder and nowhere else")
        try require(folders(editNever, .fileEdits, ["/Volumes/Notes/Greenhouse", "/Volumes/Notes/Moved"]) == .handOff,
                    "Never on an edit also hands off moving a parent of that folder")
        let trashNever = NativeCardChoices.records(.never, subject: trash, place: chat, originMessageID: nil)
        try require(folders(trashNever, .trash, ["/Volumes/Notes/Greenhouse"]) == .handOff && folders(trashNever, .trash, ["/Volumes/Notes/Other"]) == .act(.rule),
                    "Never on a Trash card hands off trashing a parent of that folder")
        print("  native card choices OK (commands, folders, sends, whole tool, ungoverned, schedule, resolver)")
    }

    static func runNativeCardChoiceStore() async throws {
        let require = NativeTaskFixture.require
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vera-card-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func answered(_ choice: NativeCardChoiceKind) async throws -> (ChatStore, String, Message?) {
            let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
            let transport = ScriptedNativeToolTransport(rounds: [
                [NativeChatStreamSnapshot(content: "", toolCalls: [
                    NativeChatToolCall(id: "card-call", name: NativeCommandTools.runName, arguments: "{\"command\":\"printf hello\"}"),
                ], finishReason: "tool_calls")],
                [NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")],
            ])
            let store = ChatStore(nativeConfig: config, nativeTransport: transport, repository: try LocalChatRepository(inMemory: true),
                                  nativeEnabledToolIDs: [NativeCommandTools.toolID])
            await store.connect()
            store.newConversation()
            store.grantFolder(folder)
            guard let id = store.selectedID, store.grants(for: id).count == 1 else {
                throw NativeTaskFixture.Failure.assertion("The card store fixture grants a folder")
            }
            store.sendText("Print hello in the folder")
            var waited = 0
            while store.turnConfirmations.isEmpty && waited < 500 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
            guard let (messageID, request) = store.turnConfirmations.first.map({ ($0.key, $0.value) }) else {
                throw NativeTaskFixture.Failure.assertion("The command card appears for \(choice.rawValue)")
            }
            try require(request.choices.contains { $0.kind == choice } && request.covers == "commands that start with printf hello",
                        "The live command card offers \(choice.rawValue)")
            store.resolveTurnConfirmation(messageID, decision: choice, requestID: request.id, token: store.turnConfirmationTokens[messageID])
            waited = 0
            while store.generating && waited < 500 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
            return (store, id, store.selected?.messages.last)
        }
        func outcome(_ reply: Message?) -> NativeCommandRun.Outcome? {
            for block in reply?.displayBlocks ?? [] { if case .commandRun(let run) = block { return run.outcome } }
            return nil
        }
        let (allowed, allowedChat, allowedReply) = try await answered(.allowHere)
        let saved = allowed.ruleRecords.filter { $0.scope == .conversation(allowedChat) }
        try require(saved.count == 1 && saved[0].effect == .allow && saved[0].target == NativeRuleTarget.make(.commandPrefix, "printf hello")
                    && allowed.approvedCommandRecords(for: allowedChat).count == 1, "Allow in this chat saves a chat-scoped prefix allow")
        try require(outcome(allowedReply) == .ran && allowedReply?.toolActivities.first?.state == .succeeded, "Allow in this chat runs the command")
        let (barred, barredChat, barredReply) = try await answered(.never)
        let forbids = barred.ruleRecords.filter { $0.scope == .conversation(barredChat) }
        try require(!forbids.isEmpty && forbids.allSatisfy { $0.effect == .forbid && $0.target == nil && $0.toolID == NativeCommandTools.toolID },
                    "Never saves forbid records naming the command tool for this chat")
        try require(outcome(barredReply) == .declined && barredReply?.toolActivities.first?.state != .succeeded, "Never does not run the command")
        print("  native card choice store OK (allow in this chat, never)")
    }
}
