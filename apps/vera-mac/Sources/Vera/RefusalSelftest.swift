import Foundation

@MainActor
extension SelfTest {
    static func runRefusalReasons() async throws {
        let require = NativeTaskFixture.require
        let chat = "refusal-chat"
        func resolver(_ rules: NativeRules = .defaults, chatRules: NativeConversationRules = NativeConversationRules(),
                      records: [NativeRuleRecord] = []) -> NativeRuleResolver {
            let source = NativeRuleSource()
            source.setGlobal(rules)
            source.set(chatRules, for: chat)
            source.setRecords(records)
            return source.resolver(for: chat, requestText: "")
        }

        let settings = resolver().explain(for: .riskyCommands)
        let tightened = resolver(chatRules: NativeConversationRules(choices: [.fileEdits: .handOff])).explain(for: .fileEdits)
        try require(settings?.kind == .unsaved && settings?.source == .settings && settings?.choice == .handOff && settings?.handsOff == true,
                    "A kind left to you in Settings explains itself as an unsaved choice from Settings: \(String(describing: settings))")
        try require(tightened?.kind == .unsaved && tightened?.source == .chat && tightened?.handsOff == true,
                    "A chat's stricter choice explains itself as coming from this chat: \(String(describing: tightened))")
        guard let settings, let tightened else { throw NativeTaskFixture.Failure.assertion("Both unsaved reasons exist") }
        try require(!RefusalCopy.plain(settings).contains("in this chat") && RefusalCopy.plain(tightened).contains("in this chat")
                    && RefusalCopy.plain(settings) != RefusalCopy.plain(tightened), "The two sentences say where the choice was made")

        guard let start = NativeRuleTarget.make(.commandPrefix, "make pdf") else { throw NativeTaskFixture.Failure.assertion("A command start target exists") }
        let allow = NativeRuleRecord(scope: .conversation(chat), action: .commands, toolID: NativeCommandTools.toolID, target: start, effect: .allow,
                                     statement: "Allow commands that start with make pdf")
        let allowing = resolver(records: [allow]).tool(NativeCommandTools.toolID, targets: [])
        let outside = allowing.explain(forCommand: "make clean")
        try require(allowing.decision(forCommand: "make clean") == .ask && allowing.decision(forCommand: "make pdf report") == .act(.grant),
                    "The saved start allows its own commands and the other one asks")
        try require(outside?.kind == .outside && outside?.rule == NativeRuleWhy.Rule(allow) && outside?.subject?.contains("make clean") == true
                    && outside?.handsOff == false,
                    "A command outside a saved start names that rule and the command: \(String(describing: outside))")
        try require(outside.map { RefusalCopy.plain($0).contains("make pdf") && RefusalCopy.plain($0).contains("make clean") } == true,
                    "The outside sentence names the allowed start and the command")

        let never = NativeRuleRecord(scope: .conversation(chat), action: nil, toolID: NativeCommandTools.toolID, effect: .forbid,
                                     statement: "Never run commands in this chat")
        let barred = resolver(NativeRules(choices: [.commands: .act]), records: [never]).tool(NativeCommandTools.toolID, targets: [])
        let ruled = barred.explain(forCommand: "ls")
        try require(barred.decision(forCommand: "ls") == .handOff && ruled?.kind == .rule && ruled?.rule?.id == never.id,
                    "A saved never on every command explains itself as that rule: \(String(describing: ruled))")
        guard let ruled else { throw NativeTaskFixture.Failure.assertion("The never reason exists") }
        let neverSentence = RefusalCopy.plain(ruled)
        try require(RefusalCopy.label(ruled) == RefusalCopy.notRun && neverSentence.contains("Never") && !neverSentence.contains("start with"),
                    "A never reads as not run and names the rule without a command start: \(neverSentence)")

        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("refusal-" + UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let shared = base.appendingPathComponent("shared", isDirectory: true)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        let inner = shared.appendingPathComponent("inner", isDirectory: true)
        for folder in [inner, elsewhere] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "x".write(to: elsewhere.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        guard let innerTarget = NativeRuleTarget.folder(inner.path), let parentTarget = NativeRuleTarget.folder(shared.path) else {
            throw NativeTaskFixture.Failure.assertion("Folder targets exist")
        }
        let protected = NativeRuleRecord(scope: .everywhere, action: .fileEdits, toolID: nil, target: innerTarget, effect: .forbid,
                                         statement: "Never edit files in inner")
        let parent = resolver(records: [protected]).tool(NativeFolderTools.toolID, targets: [parentTarget])
        let through = parent.explain(for: .fileEdits)
        try require(parent.decision(for: .fileEdits) == .handOff && through?.kind == .rule && through?.rule?.target == innerTarget,
                    "A never on an inner folder explains a change to its parent with the inner folder: \(String(describing: through))")

        var held: [String] = []
        for item in NativeFloorItem.allCases {
            guard let action = item.actionClass else { continue }
            let atDefaults = resolver().explain(for: action)
            try require(atDefaults?.kind == .held && atDefaults?.floorItem == item && atDefaults?.handsOff == true,
                        "\(item.rawValue) explains itself as always left to you: \(String(describing: atDefaults))")
            var on = NativeRules.defaults
            on.lift(item)
            let lifted = resolver(on).explain(for: action)
            try require(lifted?.kind != .held, "\(item.rawValue) no longer explains itself as held once it is turned on: \(String(describing: lifted))")
            held.append(item.rawValue)
        }
        try require(held.count == 3, "Each of the three items that can be turned on is covered: \(held)")

        let asksAlways = NativeRuleWhy.tool(.networkSends)
        try require(RefusalCopy.plain(asksAlways) == "This always asks you first, whatever your rules say." && !RefusalCopy.offersRules(asksAlways),
                    "A tool that always asks says so and offers no Rules link")

        let grant = FolderGrant(path: shared.path)
        let outsidePath = elsewhere.appendingPathComponent("notes.txt").path
        let defaults = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "")
        let live: @Sendable (String, NativeActionClass) -> NativeRuleDecision? = { command, action in
            action == .commands ? defaults.decision(forCommand: command) : defaults.decision(for: action)
        }
        let reaching = NativeCommandTools.assess(command: "rm -rf " + outsidePath, directory: shared.path, grants: [grant], fallback: .handOff,
                                                 live: live, liveTargets: nil)
        try require(reaching.decision == .handOff && reaching.why == NativeRuleWhy.folder(reaching.action, path: outsidePath),
                    "A command whose only problem is a path outside the shared folder names that path: \(String(describing: reaching.why))")
        let inside = NativeCommandTools.assess(command: "rm -rf inner", directory: shared.path, grants: [grant], fallback: .handOff,
                                               live: live, liveTargets: nil)
        try require(inside.decision != .handOff, "The same command inside the shared folder is not stopped: \(inside.decision)")
        let privileged = NativeCommandTools.assess(command: "sudo rm -rf " + outsidePath, directory: shared.path, grants: [grant], fallback: .handOff,
                                                   live: live, liveTargets: nil)
        try require(privileged.decision == .handOff && privileged.why?.kind != .folder && privileged.why?.trigger == NativeRuleWhy.Trigger(.program, "sudo"),
                    "A command stopped for another reason keeps that reason: \(String(describing: privileged.why))")
        let evaluated = NativeCommandTools.evaluate(command: "rm -rf " + outsidePath, directory: shared.path, grants: [grant], fallback: .handOff,
                                                    live: live, liveTargets: nil)
        try require(evaluated.0 == reaching.action && evaluated.1 == reaching.decision, "The reason never changes the decision")

        let tools = NativeFolderTools.definitions(grants: { [grant] }, ledger: NativeFileChangeLedger())
        let reader = tools.first { $0.name == NativeFolderTools.readName }!
        var fileWhy: NativeRuleWhy?
        do { _ = try await reader.execute(["path": .string(outsidePath)]) } catch let refusal as NativeRuleRefusal { fileWhy = refusal.why }
        try require(fileWhy?.kind == .folder && fileWhy?.subject == outsidePath && fileWhy.map { RefusalCopy.plain($0).contains(RefusalCopy.shortened(outsidePath)) } == true,
                    "A file tool outside every shared folder names the path: \(String(describing: fileWhy))")

        let program = NativeCommandClassifier.trigger("sudo ls", grants: [grant], directory: shared.path)
        let path = NativeCommandClassifier.trigger("cat ~/.ssh/id_rsa", grants: [grant], directory: shared.path)
        let wildcard = NativeCommandClassifier.trigger("rm *.txt", grants: [grant], directory: shared.path)
        let backticks = NativeCommandClassifier.trigger("echo `date`", grants: [grant], directory: shared.path)
        try require(program == NativeRuleWhy.Trigger(.program, "sudo"), "A privileged program is the trigger: \(String(describing: program))")
        try require(path == NativeRuleWhy.Trigger(.path, "~/.ssh/id_rsa"), "A sensitive location is the trigger as written: \(String(describing: path))")
        try require(wildcard == NativeRuleWhy.Trigger(.feature, NativeCommandClassifier.Feature.wildcard)
                    && backticks == NativeRuleWhy.Trigger(.feature, NativeCommandClassifier.Feature.backticks),
                    "Shell features are the trigger: \(String(describing: wildcard)) \(String(describing: backticks))")
        try require(NativeCommandClassifier.unplain("ls | wc -l", grants: [grant], directory: shared.path)?.kind == .feature
                    && NativeCommandClassifier.unplain("ls", grants: [grant], directory: shared.path) == nil, "A plain command has no trigger")
        try require(NativeCommandClassifier.Feature.all.allSatisfy { phrase in
            !phrase.isEmpty && phrase == phrase.lowercased() && phrase.allSatisfy { $0.isLetter || $0 == " " || $0 == "." }
        }, "Every shell feature phrase is plain words")

        let samples = RefusalCopy.samples()
        try require(Set(samples.map(\.kind)) == Set(NativeRuleWhy.Kind.allCases) && samples.count == NativeRuleWhy.Kind.allCases.count,
                    "Every reason has exactly one sample")
        for sample in samples {
            let sentence = RefusalCopy.plain(sample)
            let unquoted = sentence.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
                .replacingOccurrences(of: sample.subject ?? "\u{0}", with: "")
            try require(!sentence.isEmpty && sentence.hasSuffix(".") && !unquoted.dropLast().contains(". "),
                        "\(sample.kind.rawValue) reads as one sentence: \(sentence)")
            try require([RefusalCopy.leftToYou, RefusalCopy.notRun].contains(RefusalCopy.label(sample)), "\(sample.kind.rawValue) has one of the two labels")
        }

        let banned: Set<String> = ["grant", "kind", "class", "record", "scope", "prefix", "effect", "revoke", "floor", "lift", "lifted", "resolver"]
        let shown = samples.flatMap { [RefusalCopy.label($0) + ". " + RefusalCopy.plain($0), RefusalCopy.forModel($0)] }
            + NativeCommandClassifier.Feature.all + [RefusalCopy.changeInRules]
        for text in shown {
            let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            try require(!text.contains("Ver" + "a") && !text.contains("Tandem") && !text.contains("{name}") && words.isDisjoint(with: banned),
                        "Refusal copy uses plain words: \(text)")
        }

        let sendCount = NativeChatRulesCounter()
        let send = NativeToolDefinition(id: "refusal-send", name: "refusal_send", title: "Post to the garden log", description: "Fixture",
                                        parameters: .object(["type": .string("object")]), confirmation: .none, effect: .write, action: .networkSends,
                                        isAvailable: { true }, execute: { _ in sendCount.hit(); return .object(["ok": .bool(true)]) })
        var handOff = NativeRules.defaults
        handOff.set(.handOff, for: .networkSends)
        let source = NativeRuleSource()
        source.setGlobal(handOff)
        let handed = ChatStore.ruled(send, rules: source, store: nil, conversationID: chat, requestText: "")
        var chatWhy: NativeRuleWhy?
        do {
            _ = try await NativeToolCallContext.$confirmed.withValue(true) { try await handed.execute([:]) }
        } catch let refusal as NativeRuleRefusal {
            chatWhy = refusal.why
        }
        let expected = NativeRuleWhy(kind: .unsaved, action: .networkSends, handsOff: true, choice: .handOff, source: .settings)
        try require(chatWhy == expected && sendCount.count == 0, "A handed off chat tool throws its reason and never runs: \(String(describing: chatWhy))")

        let registry = NativeToolRegistry(definitions: [handed])
        let rounds: [[NativeChatStreamSnapshot]] = [NativeWebToolsSelftest.call("r1", handed.name, "{}"), NativeWebToolsSelftest.reply("Okay.")]
        let (final, _) = try await NativeWebToolsSelftest.loop(registry, rounds: rounds, enabled: [handed.id])
        guard let activity = final?.activities.first else { throw NativeTaskFixture.Failure.assertion("The loop recorded the call") }
        let modelError = (try? JSONSerialization.jsonObject(with: Data((activity.result ?? "").utf8)) as? [String: Any])?["error"] as? String
        try require(activity.state == .failed && activity.why == expected && modelError == RefusalCopy.forModel(expected) && sendCount.count == 0,
                    "The chat loop stores the reason and tells the model the same reason: \(String(describing: activity.result))")
        let decoded = try JSONDecoder().decode(NativeToolActivity.self, from: JSONEncoder().encode(activity))
        try require(decoded == activity && decoded.why == expected, "A stored activity keeps its reason")
        var bare = try JSONSerialization.jsonObject(with: JSONEncoder().encode(activity)) as? [String: Any] ?? [:]
        bare["why"] = nil
        let old = try JSONDecoder().decode(NativeToolActivity.self, from: JSONSerialization.data(withJSONObject: bare))
        try require(old.why == nil && old.id == activity.id, "An activity saved before reasons existed still opens")

        let run = NativeCommandRun(id: "c1", command: "rm -rf " + outsidePath, directory: shared.path, outcome: .refused, why: reaching.why)
        let reopened = try JSONDecoder().decode(NativeCommandRun.self, from: JSONEncoder().encode(run))
        try require(reopened == run && reopened.why == reaching.why, "A refused command card keeps its reason")
        var plainRun = try JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any] ?? [:]
        plainRun["why"] = nil
        let older = try JSONDecoder().decode(NativeCommandRun.self, from: JSONSerialization.data(withJSONObject: plainRun))
        try require(older.why == nil && older.outcome == .refused, "A command card saved before reasons existed still opens")

        var recorded: [NativeCommandRun] = []
        let box = NativeRefusalRunBox()
        let commands = NativeCommandTools.definitions(grants: { [grant] }, decision: .act(.rule), reason: { _ in nil }, record: { box.add($0) },
                                                      live: live)[0]
        do {
            _ = try await commands.execute(["command": .string("rm -rf " + outsidePath)])
            throw NativeTaskFixture.Failure.assertion("The outside command is not run")
        } catch let refusal as NativeRuleRefusal {
            recorded = box.runs
            try require(refusal.why.kind == .folder && recorded.count == 1 && recorded[0].outcome == .refused && recorded[0].why == refusal.why,
                        "A refused command leaves a card with its reason: \(recorded)")
        }
        try require(FileManager.default.fileExists(atPath: outsidePath), "Nothing outside the shared folder was touched")

        print("  refusal reasons OK (unsaved from Settings and this chat, outside a saved start, never rules, held items, tool and folder reasons, triggers, closed list, plain copy, chat round trip, command card)")
    }
}

@MainActor
extension SelfTest {
    static func runRefusalWork() async throws {
        let require = NativeTaskFixture.require
        let object: NativeJSONValue = .object(["type": .string("object"), "properties": .object(["bed": .object(["type": .string("string")])])])
        let water: @Sendable ([NativeTaskGenerationMessage]) -> NativeTaskGenerationCompletion = { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call("water_bed", "{\"bed\":\"north\"}") : NativeCompanionScriptedModel.text("Finished the assignment.")
        }
        func command(_ text: String, in folder: String) -> @Sendable ([NativeTaskGenerationMessage]) -> NativeTaskGenerationCompletion {
            let arguments = String(decoding: (try? JSONSerialization.data(withJSONObject: ["command": text, "directory": folder])) ?? Data(), as: UTF8.self)
            return { messages in
                NativeCompanionScriptedModel.toolResults(messages).isEmpty
                    ? NativeCompanionScriptedModel.call(NativeCommandTools.runName, arguments) : NativeCompanionScriptedModel.text("Finished the assignment.")
            }
        }
        func use(_ harness: inout NativeCompanionHarness, _ tools: [NativeToolDefinition]) {
            let thread = harness.thread
            harness.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: thread.current, tools: tools) }
        }
        func stored(_ record: NativeTaskRecord) throws -> NativeResearchTaskResult {
            try JSONDecoder().decode(NativeResearchTaskResult.self, from: record.result ?? Data())
        }
        let lead = NativeCompanionWorker.handOffLead(title: "Water a bed")

        let settings = try NativeCompanionHarness(rules: [.networkSends: .handOff], script: water)
        let settingsID = try settings.create()
        let settingsDone = try await settings.runUntilSettled()
        let settingsResult = try stored(settingsDone)
        let settingsWhy = NativeRuleWhy(kind: .unsaved, action: .networkSends, handsOff: true, choice: .handOff, source: .settings)
        try require(settingsDone.state == .completed && settingsResult.why == settingsWhy && settings.service.count("water_bed") == 0
                        && (try settings.effects(settingsID)).isEmpty,
                    "A Settings choice that hands off stops the work with that reason and runs nothing: \(String(describing: settingsResult.why))")
        try require(settingsResult.report.hasPrefix(lead + " " + RefusalCopy.plain(settingsWhy))
                        && !settingsResult.report.contains("your rules hand it to you") && !settingsResult.report.contains("It counts as"),
                    "The hand off names the step, then gives the same sentence chat gives: \(settingsResult.report)")
        try require(settingsResult.summary == lead + " Nothing was changed." && settingsResult.summary?.contains(RefusalCopy.plain(settingsWhy)) == false,
                    "The card summary keeps the step and leaves the reason to its own line: \(settingsResult.summary ?? "")")
        let checkpoint = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: settingsDone.checkpoint)
        try require(checkpoint.transcript.last?.role == "tool"
                        && checkpoint.transcript.last?.content == NativeCompanionWorker.message(RefusalCopy.forModel(settingsWhy)),
                    "The step's answer to the model is the same reason chat gives the model")

        let chatty = try NativeCompanionHarness(rules: [.networkSends: .ask], script: water)
        chatty.rules.set(NativeConversationRules(choices: [.networkSends: .handOff]), for: chatty.thread.current)
        _ = try chatty.create()
        let chatResult = try stored(try await chatty.runUntilSettled())
        let chatWhy = NativeRuleWhy(kind: .unsaved, action: .networkSends, handsOff: true, choice: .handOff, source: .chat)
        try require(chatResult.why == chatWhy && chatResult.report.contains(RefusalCopy.plain(chatWhy)) && RefusalCopy.plain(chatWhy).contains("in this chat"),
                    "A stricter choice in the thread hands off with the chat's own reason: \(String(describing: chatResult.why))")

        let never = NativeRuleRecord(action: .networkSends, effect: .forbid, statement: "Never send")
        let barred = try NativeCompanionHarness(rules: [.networkSends: .act], script: water)
        try barred.setRecords([never])
        _ = try barred.create()
        let barredResult = try stored(try await barred.runUntilSettled())
        try require(barredResult.why?.kind == .rule && barredResult.why?.rule?.id == never.id && barred.service.count("water_bed") == 0
                        && barredResult.why.map { barredResult.report.contains(RefusalCopy.plain($0)) } == true,
                    "A saved never stops the work and names that rule: \(String(describing: barredResult.why))")

        var paying = try NativeCompanionHarness(rules: [:], script: water)
        var payTools = NativeCompanionHarness.tools(paying.service, reconcile: false)
        payTools[1].action = .payments
        use(&paying, payTools)
        _ = try paying.create()
        let paidResult = try stored(try await paying.runUntilSettled())
        let heldWhy = NativeRuleWhy(kind: .held, action: .payments, handsOff: true, item: .payments)
        try require(paidResult.why == heldWhy && paidResult.report.contains(RefusalCopy.plain(heldWhy)) && paying.service.count("water_bed") == 0
                        && paidResult.report.contains(NativeFloorItem.payments.title) && paidResult.report.contains("Advanced"),
                    "One of the three things always left to you names itself and where to turn it on: \(paidResult.report)")

        let confirmCount = NativeChatRulesCounter()
        let confirming = NativeToolDefinition(id: "garden", name: "water_bed", title: "Water a bed", description: "Water one bed",
                                              parameters: object, confirmation: .required, effect: .write, action: .networkSends,
                                              isAvailable: { true }, execute: { _ in confirmCount.hit(); return .object(["watered": .bool(true)]) })
        var unasked = try NativeCompanionHarness(rules: [.networkSends: .act], script: water)
        use(&unasked, [confirming])
        let unaskedID = try unasked.create(mode: "proactive")
        let unaskedDone = try await unasked.runUntilSettled()
        let unaskedResult = try stored(unaskedDone)
        let toolWhy = NativeRuleWhy.tool(.networkSends)
        try require(unaskedDone.state == .completed && confirmCount.count == 0 && (try unasked.effects(unaskedID)).isEmpty
                        && unaskedResult.why == nil
                        && unaskedResult.report.contains("Not run: Water a bed. " + RefusalCopy.plain(toolWhy)),
                    "A tool that always asks, in work that cannot ask, says so and still does not run: \(unaskedResult.report)")

        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("refusal-work-" + UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let shared = base.appendingPathComponent("shared", isDirectory: true)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        for folder in [shared, elsewhere] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let outsidePath = elsewhere.appendingPathComponent("notes.txt").path
        try "x".write(toFile: outsidePath, atomically: true, encoding: .utf8)
        let grant = FolderGrant(path: shared.path)
        let runs = NativeRefusalRunBox()
        let commandTool = NativeCommandTools.definitions(grants: { [grant] }, decision: .act(.rule), reason: { _ in nil }, record: { runs.add($0) })[0]

        var reaching = try NativeCompanionHarness(rules: [:], script: command("rm -rf " + outsidePath, in: shared.path))
        reaching.rules.setGlobal(.defaults)
        use(&reaching, [commandTool])
        _ = try reaching.create()
        let reachingResult = try stored(try await reaching.runUntilSettled())
        try require(reachingResult.why?.kind == .folder && reachingResult.why?.subject == outsidePath
                        && reachingResult.why.map { reachingResult.report.contains(RefusalCopy.plain($0)) } == true
                        && FileManager.default.fileExists(atPath: outsidePath) && runs.runs.isEmpty,
                    "A command reaching outside the shared folder stops with that path and touches nothing: \(String(describing: reachingResult.why))")

        guard let start = NativeRuleTarget.make(.commandPrefix, "make pdf") else { throw NativeTaskFixture.Failure.assertion("A command start target exists") }
        let allow = NativeRuleRecord(action: .commands, toolID: NativeCommandTools.toolID, target: start, effect: .allow,
                                     statement: "Allow commands that start with make pdf")
        var uncovered = try NativeCompanionHarness(rules: [:], script: command("make clean", in: shared.path))
        uncovered.rules.setGlobal(.defaults)
        try uncovered.saveRecords([allow])
        use(&uncovered, [commandTool])
        _ = try uncovered.create(mode: "proactive")
        let uncoveredDone = try await uncovered.runUntilSettled()
        let uncoveredResult = try stored(uncoveredDone)
        let expectedSource = NativeRuleSource()
        expectedSource.setGlobal(.defaults)
        expectedSource.setRecords([allow])
        guard let outsideWhy = expectedSource.resolver(for: uncovered.thread.current, requestText: "").tool(NativeCommandTools.toolID, targets: [])
            .explain(forCommand: "make clean") else { throw NativeTaskFixture.Failure.assertion("The uncovered command has a reason") }
        try require(outsideWhy.kind == .outside && uncoveredDone.state == .completed && runs.runs.isEmpty
                        && uncoveredResult.report.contains("Not run: Run a command: make clean. " + RefusalCopy.plain(outsideWhy)),
                    "A command a saved allow does not cover, in work that cannot ask, names the rule and the command: \(uncoveredResult.report)")

        let encoded = try JSONEncoder().encode(settingsResult)
        let reopened = try JSONDecoder().decode(NativeResearchTaskResult.self, from: encoded)
        try require(reopened == settingsResult && reopened.why == settingsWhy, "A handed off result keeps its reason through its saved form")
        var bare = try settings.result(settingsDone)
        try require(bare["kind"] as? String == "companion_report" && bare["why"] != nil, "The hand off keeps the usual result kind and adds the reason")
        bare["why"] = nil
        let old = try JSONDecoder().decode(NativeResearchTaskResult.self, from: JSONSerialization.data(withJSONObject: bare))
        try require(old.why == nil && old.report == settingsResult.report && old.kind == settingsResult.kind, "A result saved before reasons existed still opens")

        let repository = try LocalChatRepository(inMemory: true)
        let engine = try NativeTaskEngineIdentity(URL(string: "https://engine.test/api")!)
        let request = try NativeResearchTaskRequest(dot: NativeCompanionTaskPayload(assignment: "Water the north bed", mode: "manual"))
        func presented(_ record: NativeTaskRecord, settled harness: NativeCompanionHarness) throws -> (reference: NativeTaskReference, card: NativeTaskCardPresentation, artifact: Bool) {
            let prepared = try repository.prepareTaskReference(origin: try NativeTaskFixture.origin(repository), engine: engine, request: request, profile: nil)
            let payload = (try JSONSerialization.jsonObject(with: prepared.body) as! [String: Any])["payload"]!
            var result = try harness.result(record)
            result["query"] = prepared.request.objective
            let snapshot = try JSONDecoder().decode(NativeTaskSnapshot.self, from: NativeTaskClient.canonical([
                "id": UUID().uuidString, "worker_type": "companion", "payload": payload, "state": record.state.rawValue,
                "checkpoint": [:], "cancel_requested": false, "generation": 1, "updated_at": 1.0, "result": result]))
            let reference = try repository.acknowledgeTaskReference(id: prepared.id, snapshot: snapshot)
            let display = try NativeTaskProjection.display(reference: reference, snapshot: snapshot)
            return (reference, display.card, display.artifact != nil)
        }
        let handed = try presented(settingsDone, settled: settings)
        try require(handed.card.statusTitle == RefusalCopy.needsYou && handed.card.why == settingsWhy && handed.card.needsYou
                        && handed.card.status == .completed,
                    "A handed off task's card reads Needs you and carries its reason: \(handed.card.statusTitle)")
        try require(handed.card.milestone.contains("Water a bed") && !handed.card.milestone.contains(RefusalCopy.plain(settingsWhy)),
                    "The card shows the step once and leaves the reason to the reason line: \(handed.card.milestone)")
        let card = try JSONDecoder().decode(NativeTaskCardPresentation.self, from: JSONEncoder().encode(handed.card))
        var plainCard = try JSONSerialization.jsonObject(with: JSONEncoder().encode(handed.card)) as? [String: Any] ?? [:]
        plainCard["why"] = nil
        let olderCard = try JSONDecoder().decode(NativeTaskCardPresentation.self, from: JSONSerialization.data(withJSONObject: plainCard))
        try require(card == handed.card && olderCard.why == nil && olderCard.statusTitle == "Work done",
                    "A saved card keeps its reason, and a card saved before reasons existed still reads as before")

        let panel = CompanionOverviewModel.taskItem(card: handed.card, reference: handed.reference, decision: nil, hasArtifact: handed.artifact, date: Date())
        let ongoing = OngoingWork.item(handed.reference)
        let run = NativeScheduleRun(scheduleID: "refusal-schedule", scheduledFor: Date(), outcome: .completed)
        let scheduled = ChatStore.scheduleRunTitle(run, card: handed.card)
        try require(panel.state == handed.card.statusTitle && ongoing.state == handed.card.statusTitle && scheduled == handed.card.statusTitle,
                    "The card, the companion panel, the work list and the Scheduled row all read the same title: \(panel.state) \(ongoing.state) \(scheduled)")

        let finishing = try NativeCompanionHarness(rules: [.networkSends: .act], script: water)
        _ = try finishing.create()
        let finishedDone = try await finishing.runUntilSettled()
        let finished = try presented(finishedDone, settled: finishing)
        let finishedResult = try stored(finishedDone)
        try require(finishedDone.state == settingsDone.state && finishedResult.why == nil && finished.card.why == nil
                        && finished.card.statusTitle == "Work done" && ChatStore.scheduleRunTitle(run, card: finished.card) == run.outcome.title
                        && CompanionOverviewModel.taskItem(card: finished.card, reference: finished.reference, decision: nil, hasArtifact: false, date: Date()).state == "Work done",
                    "Work that finishes normally keeps its old titles")
        try require(settingsDone.state == .completed && settingsDone.state.rawValue == NativeTaskState.completed.rawValue,
                    "A hand off leaves the task in the same completed state as before")

        print("  refusal work OK (six reasons in background work, hand off and not run text, model answer, saved result round trip, old results, Needs you title on card, panel, work list and Scheduled row, normal work unchanged, task state unchanged)")
    }
}

final class NativeRefusalRunBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NativeCommandRun] = []

    var runs: [NativeCommandRun] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func add(_ run: NativeCommandRun) {
        lock.lock(); defer { lock.unlock() }
        stored.append(run)
    }
}
