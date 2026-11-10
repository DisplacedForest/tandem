import Foundation

final class NativeChatRulesCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func hit() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        value = 0
    }
}

@MainActor
extension SelfTest {
    static func runNativeChatRules() async throws {
        let require = NativeTaskFixture.require
        let chat = "chat-rules"
        let other = "chat-rules-other"
        let request = "Post the note"

        func tool(_ id: String, effect: NativeToolEffect = .write, action: NativeActionClass? = nil,
                  confirmation: NativeToolConfirmation = .none, counter: NativeChatRulesCounter) -> NativeToolDefinition {
            NativeToolDefinition(id: id, name: id.replacingOccurrences(of: "-", with: "_"), title: "Post to the garden log",
                                 description: "Fixture", parameters: .object(["type": .string("object")]),
                                 confirmation: confirmation, effect: effect, action: action, isAvailable: { true },
                                 execute: { _ in counter.hit(); return .object(["ok": .bool(true)]) })
        }
        func source(_ rules: NativeRules = .defaults, records: [NativeRuleRecord] = []) -> NativeRuleSource {
            let source = NativeRuleSource()
            source.setGlobal(rules)
            source.setRecords(records)
            return source
        }
        func rules(_ choice: NativeRuleChoice, for action: NativeActionClass) -> NativeRules {
            var rules = NativeRules.defaults
            rules.set(choice, for: action)
            return rules
        }
        func ruled(_ definition: NativeToolDefinition, _ rules: NativeRuleSource, conversation: String = chat,
                   store: NativeRuleRecordStore? = nil) -> NativeToolDefinition {
            ChatStore.ruled(definition, rules: rules, store: store, conversationID: conversation, requestText: request)
        }
        func run(_ definition: NativeToolDefinition, _ arguments: [String: NativeJSONValue] = [:], confirmed: Bool) async -> String? {
            do {
                _ = try await NativeToolCallContext.$confirmed.withValue(confirmed) { try await definition.execute(arguments) }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        func asks(_ definition: NativeToolDefinition, _ arguments: [String: NativeJSONValue] = [:]) -> Bool? {
            definition.confirmationFor?(arguments)
        }

        let readCount = NativeChatRulesCounter()
        let read = tool("fixture-read", effect: .read, counter: readCount)
        let readRuled = ruled(read, source(rules(.handOff, for: .otherChanges)))
        try require(!readRuled.governed && readRuled.confirmationFor == nil && !ChatStore.followsRules(read),
                    "A read is returned unchanged")
        try require(await run(readRuled, confirmed: false) == nil && readCount.count == 1, "A read runs with no card")

        let sendCount = NativeChatRulesCounter()
        let send = tool("fixture-send", action: .networkSends, counter: sendCount)
        try require(ChatStore.followsRules(send), "A declared write follows the rules")
        let acting = ruled(send, source(rules(.act, for: .networkSends)))
        try require(acting.governed && asks(acting) == false, "A write under a kind set to act shows no card")
        try require(await run(acting, confirmed: false) == nil && sendCount.count == 1, "A write under act runs without a card")

        let asking = ruled(send, source())
        try require(asking.governed && asks(asking) == true, "A write under ask shows a card")
        try require(await run(asking, confirmed: false) == NativeRuleResolver.changedMessage && sendCount.count == 1,
                    "A write under ask never runs without an approved card")
        try require(await run(asking, confirmed: true) == nil && sendCount.count == 2, "A write under ask runs once after the card")

        let handOffMessage = NativeRuleResolver.handOffMessage(.networkSends)
        let handing = ruled(send, source(rules(.handOff, for: .networkSends)))
        try require(asks(handing) == false, "A write under hand off shows no card")
        for confirmed in [false, true] {
            try require(await run(handing, confirmed: confirmed) == handOffMessage && sendCount.count == 2,
                        "A write under hand off is refused and never runs: confirmed \(confirmed)")
        }
        try require(handOffMessage.contains(NativeActionClass.networkSends.title.lowercased()), "The hand off message names the kind")

        let plainCount = NativeChatRulesCounter()
        let plain = tool("fixture-plain", counter: plainCount)
        let plainDefault = ruled(plain, source())
        try require(plainDefault.governed && asks(plainDefault) == true, "A write with no declared kind asks under the defaults")
        try require(await run(plainDefault, confirmed: false) == NativeRuleResolver.changedMessage && plainCount.count == 0,
                    "An undeclared write never runs without its card")
        let plainActs = ruled(plain, source(rules(.act, for: .otherChanges)))
        try require(asks(plainActs) == false, "An undeclared write follows other changes")
        try require(await run(plainActs, confirmed: false) == nil && plainCount.count == 1, "An undeclared write runs when other changes act")
        try require(await run(ruled(plain, source(rules(.handOff, for: .otherChanges))), confirmed: true)
                    == NativeRuleResolver.handOffMessage(.otherChanges) && plainCount.count == 1,
                    "An undeclared write is handed off under other changes")

        let strictCount = NativeChatRulesCounter()
        let strict = tool("fixture-strict", action: .networkSends, confirmation: .required, counter: strictCount)
        let strictActs = ruled(strict, source(rules(.act, for: .networkSends)))
        try require(asks(strictActs) == true, "A tool that always confirms still asks when its kind acts")
        try require(await run(strictActs, confirmed: true) == nil && strictCount.count == 1, "An always-confirm tool runs after its card")
        let strictHanded = ruled(strict, source(rules(.handOff, for: .networkSends)))
        try require(asks(strictHanded) == false, "An always-confirm tool shows no card when its kind hands off")
        try require(await run(strictHanded, confirmed: true) == handOffMessage && strictCount.count == 1,
                    "An always-confirm tool is refused when its kind hands off")
        var custom = strict
        custom.confirmationFor = { _ in false }
        try require(asks(ruled(custom, source(rules(.act, for: .networkSends)))) == false
                    && asks(ruled(custom, source())) == true, "A tool's own per-call answer is kept and the rules can only add a card")

        let forbidCount = NativeChatRulesCounter()
        let forbidden = tool("fixture-forbidden", action: .networkSends, counter: forbidCount)
        let withKind = NativeRuleRecord(scope: .conversation(chat), action: .networkSends, toolID: forbidden.id, effect: .forbid,
                                        statement: "Never post to the garden log here")
        let toolWide = NativeRuleRecord(scope: .conversation(chat), action: nil, toolID: forbidden.id, effect: .forbid,
                                        statement: "Never use the garden log here")
        for record in [withKind, toolWide] {
            let barred = source(rules(.act, for: .networkSends), records: [record])
            let here = ruled(forbidden, barred)
            try require(asks(here) == false, "A saved never shows no card: \(record.statement)")
            try require(await run(here, confirmed: true) != nil && forbidCount.count == 0, "A saved never refuses the tool: \(record.statement)")
            let elsewhere = ruled(forbidden, barred, conversation: other)
            try require(asks(elsewhere) == false, "A chat-scoped never leaves another chat on its rule: \(record.statement)")
            try require(await run(elsewhere, confirmed: false) == nil && forbidCount.count == 1,
                        "A chat-scoped never leaves another chat alone: \(record.statement)")
            forbidCount.reset()
        }

        let allowCount = NativeChatRulesCounter()
        let allowed = tool("fixture-allowed", action: .networkSends, counter: allowCount)
        let allowRecord = NativeRuleRecord(scope: .conversation(chat), action: .networkSends, toolID: allowed.id, effect: .allow,
                                           statement: "Always post to the garden log here")
        let allowing = ruled(allowed, source(records: [allowRecord]))
        try require(asks(allowing) == false, "A saved allow removes the card for an ask kind")
        try require(await run(allowing, confirmed: false) == nil && allowCount.count == 1, "A saved allow runs with no card")
        try require(asks(ruled(allowed, source(records: [allowRecord]), conversation: other)) == true, "A chat-scoped allow stays in its chat")

        let repository = try LocalChatRepository(inMemory: true)
        let records = NativeRuleRecordStore(database: repository.database)
        let durable = NativeRuleSource()
        ChatStore.prepareRules(durable, from: records)
        _ = try records.add(NativeRuleRecord(scope: .conversation(chat), action: .networkSends, toolID: allowed.id, effect: .allow,
                                             statement: "Allow posting to the garden log once", remainingUses: 1))
        ChatStore.reloadRules(durable, from: records)
        let once = ruled(allowed, durable, store: records)
        try require(asks(once) == false, "A one-use allow removes the card")
        try require(await run(once, confirmed: false) == nil && allowCount.count == 2, "A one-use allow runs once")
        try require(asks(ruled(allowed, durable, store: records)) == true, "A used one-use allow asks again")
        try require(await run(once, confirmed: false) == NativeRuleResolver.changedMessage && allowCount.count == 2,
                    "A spent one-use allow never runs a second time")

        let flipCount = NativeChatRulesCounter()
        let flipping = tool("fixture-flip", action: .networkSends, counter: flipCount)
        let live = source()
        let flipped = ruled(flipping, live)
        try require(asks(flipped) == true, "The card is shown under ask")
        live.setGlobal(rules(.handOff, for: .networkSends))
        try require(await run(flipped, confirmed: true) == handOffMessage && flipCount.count == 0,
                    "A kind handed off after the card is refused at run time")
        live.setGlobal(.defaults)
        try require(asks(flipped) == true, "The card is shown again under ask")
        live.setGlobal(rules(.act, for: .networkSends))
        try require(await run(flipped, confirmed: true) == nil && flipCount.count == 1, "A kind set to act after the card runs")

        let bundled = NativeCapabilityTools.bundled
        let shipped = bundled.map { NativeCapabilityTools.definition($0, base: { nil }) }
        let preflightCount = NativeChatRulesCounter()
        var checked = tool("fixture-preflight", action: .networkSends, counter: preflightCount)
        checked.preflight = { arguments in
            guard arguments["line"] != nil else { throw NativeToolError.invalidArguments("A line is required") }
        }
        let sparing = try records.add(NativeRuleRecord(scope: .conversation(chat), action: .networkSends, toolID: checked.id, effect: .allow,
                                                       statement: "Allow the checked post once", remainingUses: 1))
        ChatStore.reloadRules(durable, from: records)
        let spared = ruled(checked, durable, store: records)
        try require(await run(spared, confirmed: false) != nil && preflightCount.count == 0,
                    "A call that fails its own checks does not run")
        try require(try records.all().first { $0.id == sparing.id }?.remainingUses == 1 && asks(spared, ["line": .string("Beans")]) == false,
                    "A call that fails its own checks leaves a one-use allow unspent")
        try require(await run(spared, ["line": .string("Beans")], confirmed: false) == nil && preflightCount.count == 1,
                    "The next valid call uses the one-use allow")

        let watch = try { () throws -> NativeToolDefinition in
            guard let found = bundled.first(where: { $0.name == "recurring_watch" }) else { throw NativeTaskFixture.Failure.assertion("The watch tool ships") }
            return NativeCapabilityTools.definition(found, base: { URL(string: "https://api.example") })
        }()
        let draft: [String: NativeJSONValue] = ["mode": .string("draft")]
        let save: [String: NativeJSONValue] = ["mode": .string("save")]
        try require(!watch.proposes && ChatStore.followsRules(watch) && watch.proposesFor?(draft) == true && watch.proposesFor?(save) == false
                        && watch.proposesFor?([:]) == false,
                    "The watch tool proposes only while drafting")
        let watchAsk = ruled(watch, source())
        try require(asks(watchAsk, draft) == false && asks(watchAsk, save) == true, "Drafting a watch shows no card and saving one asks under the default sends rule")
        let watchOff = ruled(watch, source(rules(.handOff, for: .networkSends)))
        try require(await run(watchOff, save, confirmed: true) == NativeRuleResolver.handOffMessage(.networkSends),
                    "Saving a watch is refused when sends are handed off")
        try require(await run(watchAsk, save, confirmed: false) == NativeRuleResolver.changedMessage, "Saving a watch never runs without an answer")
        _ = try records.add(NativeRuleRecord(scope: .conversation(other), action: nil, toolID: watch.id, effect: .forbid,
                                             statement: "Never allow this in this chat"))
        ChatStore.reloadRules(durable, from: records)
        let watchNever = ruled(watch, durable, conversation: other, store: records)
        try require(await run(watchNever, save, confirmed: true) != nil, "A saved never refuses saving a watch")
        try require(asks(watchNever, draft) == false, "A saved never still lets a watch be drafted")

        let lookup = try NativeCapabilityTools.parse(data: try JSONSerialization.data(withJSONObject: [
            "name": "garden_lookup", "title": "Look up the garden log", "description": "Read the garden log",
            "parameters": ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
            "endpoint": "https://garden.example/log", "method": "GET", "confirmation": "required",
        ] as [String: Any]), source: "garden_lookup.json")
        let guarded = NativeCapabilityTools.definition(lookup, base: { nil })
        try require(!lookup.reads && guarded.effect == .write && guarded.action == .otherChanges && ChatStore.followsRules(guarded),
                    "A lookup file that demands confirmation counts as another change")
        let guardedRuled = ruled(guarded, source(rules(.act, for: .otherChanges)))
        try require(guardedRuled.alwaysAsks && asks(guardedRuled) == true, "It always asks, whatever the rule says")
        try require(shipped.filter { $0.effect == .read }.allSatisfy { $0.confirmation == .none && $0.confirmationFor == nil },
                    "No shipped lookup can show a card")

        try require(shipped.allSatisfy { $0.proposes == NativeCapabilityTools.proposing.contains($0.name) },
                    "A shipped tool carries the proposing mark exactly when its name is in the proposing set")
        try require(shipped.contains { $0.proposes } && shipped.first { $0.name == "propose_action" }?.proposes == true,
                    "At least one shipped tool carries the proposing mark")
        try require(shipped.filter(\.proposes).allSatisfy { !ChatStore.followsRules($0) }, "The shipped proposing tools keep their own flow")
        try require(shipped.filter { $0.effect == .write && !$0.proposes }.allSatisfy(ChatStore.followsRules),
                    "Every other shipped posting tool follows the rules")

        func file(_ name: String, extra: [String: Any] = [:]) throws -> Data {
            var object: [String: Any] = [
                "name": name, "title": "Post to the garden log", "description": "Post a line to the garden log",
                "parameters": ["type": "object", "properties": ["line": ["type": "string"]], "required": ["line"], "additionalProperties": false],
                "endpoint": "https://garden.example/log", "method": "POST", "confirmation": "none",
            ]
            object.merge(extra) { _, new in new }
            return try JSONSerialization.data(withJSONObject: object)
        }
        for (label, data) in [("garden.json", try file("garden_log")),
                              ("sneaky.json", try file("garden_log", extra: ["proposes": true, "source": "bundled"])),
                              ("propose_action.json", try file("propose_action"))] {
            let declaration = try NativeCapabilityTools.parse(data: data, source: label)
            try require(declaration.source == label, "A file keeps its own source: \(label)")
            let definition = NativeCapabilityTools.definition(declaration, base: { nil })
            try require(!definition.proposes && ChatStore.followsRules(definition) && definition.action == .networkSends,
                        "A posting file never carries the proposing mark: \(label)")
            let wrapped = ruled(definition, source())
            try require(wrapped.governed && asks(wrapped, ["line": .string("Watered the beans")]) == true,
                        "A posting file asks first under the default sends rule: \(label)")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-chat-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try file("propose_action").write(to: folder.appendingPathComponent("propose_action.json"))
        let catalog = NativeCapabilityTools.catalog(directory: folder)
        try require(catalog.failures.count == 1 && catalog.failures[0].reason.contains("already loaded"),
                    "A file cannot take a shipped tool's name")
        try require(catalog.declarations.filter { $0.name == "propose_action" }.count == 1
                        && catalog.declarations.first { $0.name == "propose_action" }?.source == NativeCapabilityTools.bundledSource,
                    "The proposing name stays with the shipped declaration")

        let profileCount = NativeChatRulesCounter()
        let profile = tool(NativeCompanionProfileTools.toolID, counter: profileCount)
        let profileRuled = ruled(profile, source(rules(.handOff, for: .otherChanges)))
        try require(!ChatStore.followsRules(profile) && !profileRuled.governed && profileRuled.confirmationFor == nil,
                    "The companion profile tool is never wrapped")
        try require(await run(profileRuled, confirmed: false) == nil && profileCount.count == 1, "The companion profile tool keeps its own flow")

        let keptCount = NativeChatRulesCounter()
        var kept = tool("fixture-kept", action: .networkSends, counter: keptCount)
        kept.timeout = .seconds(7)
        kept.resultByteBudget = 1234
        kept.wants = "post a line"
        kept.argumentValidator = { arguments in
            if arguments["line"] == nil { throw NativeToolError.invalidArguments("A line is required") }
        }
        kept.classify = { arguments in arguments["line"] == nil ? .otherChanges : .networkSends }
        kept.ruleSubjects = { _ in [[NativeRuleTarget.make(.recipient, "ana@example.com")!]] }
        let keptRuled = ruled(kept, source())
        let line: [String: NativeJSONValue] = ["line": .string("Watered the beans")]
        try require(keptRuled.id == kept.id && keptRuled.name == kept.name && keptRuled.title == kept.title
                    && keptRuled.description == kept.description && keptRuled.parameters == kept.parameters
                    && keptRuled.confirmation == kept.confirmation && keptRuled.timeout == kept.timeout
                    && keptRuled.resultByteBudget == kept.resultByteBudget && keptRuled.effect == kept.effect
                    && keptRuled.action == kept.action && keptRuled.wants == kept.wants && keptRuled.proposes == kept.proposes
                    && keptRuled.wantsPhrase == kept.wantsPhrase, "Wrapping keeps every stored value")
        try require(keptRuled.isAvailable() && keptRuled.ruleSubjects?(line) == kept.ruleSubjects?(line)
                    && keptRuled.actionClass(for: line) == .networkSends && keptRuled.actionClass(for: [:]) == .otherChanges
                    && (try? keptRuled.argumentValidator?(line)) != nil && (try? keptRuled.argumentValidator?([:])) == nil
                    && keptRuled.executeWithKey == nil && keptRuled.reconcile == nil && keptRuled.ruleDecision == nil,
                    "Wrapping keeps every closure behaving the same")
        let unavailable = NativeToolDefinition(id: kept.id, name: kept.name, title: kept.title, description: kept.description,
                                           parameters: kept.parameters, confirmation: .none, action: .networkSends,
                                           isAvailable: { false }, execute: { _ in .null })
        try require(!ruled(unavailable, source()).isAvailable(), "Wrapping keeps a tool unavailable")

        let reminders = SelfTestRemindersService()
        let reminderTools = Dictionary(NativeRemindersTools.definitions(service: reminders).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let create = reminderTools["apple_reminders_create"]!
        let complete = reminderTools["apple_reminders_complete"]!
        let createArguments: [String: NativeJSONValue] = ["list": .string("Errands"), "title": .string("Buy seed potatoes")]
        let completeArguments: [String: NativeJSONValue] = ["id": .string("open")]
        for name in ["apple_reminders_get_lists", "apple_reminders_list"] {
            let wrapped = ruled(reminderTools[name]!, source(rules(.handOff, for: .reminders)))
            try require(!wrapped.governed && wrapped.confirmationFor == nil, "\(name) stays an untouched read")
        }
        let defaults = source()
        let createDefault = ruled(create, defaults)
        let completeDefault = ruled(complete, defaults)
        try require(createDefault.governed && completeDefault.governed, "Reminder writes follow the rules")
        try require(asks(createDefault, createArguments) == false && asks(completeDefault, completeArguments) == false,
                    "Adding or completing a reminder shows no card under the defaults")
        let createdPlainly = await run(createDefault, createArguments, confirmed: false)
        let completedPlainly = await run(completeDefault, completeArguments, confirmed: false)
        try require(createdPlainly == nil && completedPlainly == nil
                    && reminders.createCalls == 1 && reminders.completeCalls == 1, "Reminder writes run with no card under the defaults")
        let reminderAsk = source(rules(.ask, for: .reminders))
        try require(asks(ruled(create, reminderAsk), createArguments) == true && asks(ruled(complete, reminderAsk), completeArguments) == true,
                    "Reminder writes ask when reminders are set to ask")
        try require(await run(ruled(create, reminderAsk), createArguments, confirmed: false) == NativeRuleResolver.changedMessage
                    && reminders.createCalls == 1, "A reminder never saves without its card when reminders ask")
        let reminderHandOff = source(rules(.handOff, for: .reminders))
        try require(asks(ruled(create, reminderHandOff), createArguments) == false, "A handed off reminder shows no card")
        let createHanded = await run(ruled(create, reminderHandOff), createArguments, confirmed: true)
        let completeHanded = await run(ruled(complete, reminderHandOff), completeArguments, confirmed: true)
        try require(createHanded == NativeRuleResolver.handOffMessage(.reminders) && completeHanded == NativeRuleResolver.handOffMessage(.reminders)
                    && reminders.createCalls == 1 && reminders.completeCalls == 1, "Handed off reminders are refused and nothing is written")
        try require(NativeCompanionWorker.excludedToolIDs.contains(NativeRemindersTools.toolID), "Background work never gets the reminder tools")
        let always = NativeToolDefinition(id: "fixture-always", name: "always_ask", title: "Publish the newsletter", description: "",
                                          parameters: .object(["type": .string("object")]), confirmation: .required, effect: .write,
                                          action: .networkSends, isAvailable: { true }, execute: { _ in .null })
        let alwaysRuled = ruled(always, source(rules(.act, for: .networkSends)))
        let alwaysActivity = NativeToolActivity(id: "a1", toolID: always.id, name: always.name, title: always.title, round: 1, request: "{}",
                                                result: nil, state: .pending, confirmationRequired: true)
        let alwaysSubject = ChatStore.cardSubject(for: alwaysActivity, definitions: [alwaysRuled], typedText: "")
        var alwaysRequest = NativeToolConfirmationRequest(activity: alwaysActivity)
        alwaysRequest.subject = alwaysSubject
        alwaysRequest.choices = alwaysSubject.map { NativeCardChoices.offered($0, place: .chat(conversationID: "c1")) } ?? []
        try require(alwaysRuled.alwaysAsks && alwaysSubject?.alwaysAsks == true
                    && alwaysRequest.choices.map(\.kind) == [.decline, .never, .allowOnce]
                    && CardAnswers.chat(alwaysRequest).allowMenu.isEmpty && CardAnswers.chat(alwaysRequest).declineMenu.count == 1
                    && NativeCardChoices.records(.allowAlways, subject: alwaysSubject!, place: .chat(conversationID: "c1"), originMessageID: nil).isEmpty,
                    "A tool that always asks never offers an allow that sticks, because it could not take effect")
        let sometimes = ruled(send, source())
        try require(!sometimes.alwaysAsks, "A tool that asks only because of the rules can be allowed for good")
        let createActivity = NativeToolActivity(id: "r1", toolID: create.id, name: create.name, title: create.title, round: 1,
                                                request: "{\"list\":\"Errands\",\"title\":\"Buy seed potatoes\"}", result: nil, state: .pending,
                                                confirmationRequired: true)
        let createSubject = ChatStore.cardSubject(for: createActivity, definitions: [ruled(create, source(rules(.ask, for: .reminders)))], typedText: "")
        var createRequest = NativeToolConfirmationRequest(activity: createActivity)
        createRequest.subject = createSubject
        let completeActivity = NativeToolActivity(id: "r2", toolID: complete.id, name: complete.name, title: complete.title, round: 1,
                                                  request: "{\"id\":\"open\"}", result: nil, state: .pending, confirmationRequired: true)
        var completeRequest = NativeToolConfirmationRequest(activity: completeActivity)
        completeRequest.subject = ChatStore.cardSubject(for: completeActivity, definitions: [ruled(complete, source(rules(.ask, for: .reminders)))], typedText: "")
        try require(NativeToolConfirmationBar.sentence(for: createRequest, actor: "Tandem") == "Tandem wants to add a reminder."
                    && NativeToolConfirmationBar.sentence(for: completeRequest, actor: "Tandem") == "Tandem wants to mark a reminder as done.",
                    "A reminder card says what it wants to do in plain words")
        print("  native chat rules OK (reads, act, ask, hand off, other changes, always confirm, saved never and allow, one-use allow, rule change, proposing tools, tool files, profile tool, kept values, reminders)")
    }

    static func runNativeChatRulesStore() async throws {
        let require = NativeTaskFixture.require
        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
        let callRound = [NativeChatStreamSnapshot(content: "", toolCalls: [
            NativeChatToolCall(id: "send-call", name: "garden_log", arguments: "{\"line\":\"Watered the beans\"}"),
        ], finishReason: "tool_calls")]
        let doneRound = [NativeChatStreamSnapshot(content: "Posted.", toolCalls: [], finishReason: "stop")]
        func store(_ rules: NativeRules, counter: NativeChatRulesCounter, rounds: [[NativeChatStreamSnapshot]]) async -> ChatStore {
            let send = NativeToolDefinition(id: "capability-garden_log", name: "garden_log", title: "Post to the garden log",
                description: "Post a line to the garden log",
                parameters: .object(["type": .string("object"), "properties": .object(["line": .object(["type": .string("string")])]),
                                     "required": .array([.string("line")])]),
                confirmation: .none, action: .networkSends, isAvailable: { true },
                execute: { _ in counter.hit(); return .object(["posted": .bool(true)]) })
            let store = ChatStore(nativeConfig: config, nativeTransport: ScriptedNativeToolTransport(rounds: rounds),
                                  repository: try! LocalChatRepository(inMemory: true), nativeEnabledToolIDs: [send.id], nativeRules: rules,
                                  nativeToolRegistry: NativeToolRegistry(definitions: [send]), artifactPersistenceEnabled: false)
            await store.connect()
            store.newConversation()
            return store
        }
        func settle(_ store: ChatStore) async throws -> Bool {
            var sawCard = false
            var waited = 0
            try await Task.sleep(nanoseconds: 20_000_000)
            while store.generating && waited < 500 {
                if !store.turnConfirmations.isEmpty { sawCard = true }
                try await Task.sleep(nanoseconds: 10_000_000); waited += 1
            }
            return sawCard || !store.turnConfirmations.isEmpty
        }

        let ran = NativeChatRulesCounter()
        let asking = await store(.defaults, counter: ran, rounds: [callRound, doneRound, callRound, doneRound])
        guard let chat = asking.selectedID else { throw NativeTaskFixture.Failure.assertion("The chat rules store opens a chat") }
        asking.sendText("Post the note to the garden log")
        var waited = 0
        while asking.turnConfirmations.isEmpty && waited < 500 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        guard let (messageID, card) = asking.turnConfirmations.first.map({ ($0.key, $0.value) }) else {
            throw NativeTaskFixture.Failure.assertion("A posting tool shows a card under the default sends rule")
        }
        let kinds = card.choices.map(\.kind)
        try require(card.subject?.governed == true && card.subject?.action == .networkSends
                    && [.decline, .never, .allowAlways, .allowHere, .allowOnce].allSatisfy(kinds.contains),
                    "The card for a posting tool offers the standing choices: \(kinds)")
        try require(ran.count == 0, "The posting tool waits for the card")
        asking.resolveTurnConfirmation(messageID, decision: .allowHere, requestID: card.id, token: asking.turnConfirmationTokens[messageID])
        _ = try await settle(asking)
        let saved = asking.ruleRecords.filter { $0.scope == .conversation(chat) && $0.toolID == "capability-garden_log" }
        try require(saved.count == 1 && saved[0].effect == .allow && saved[0].action == .networkSends && saved[0].target == nil,
                    "Allow in this chat saves a chat-scoped allow for the tool")
        try require(ran.count == 1 && asking.selected?.messages.last?.toolActivities.first?.state == .succeeded, "Allow in this chat runs the tool once")
        asking.sendText("Post the note to the garden log again")
        let carded = try await settle(asking)
        try require(!carded && ran.count == 2 && asking.selected?.messages.last?.toolActivities.first?.state == .succeeded,
                    "The saved allow runs the same call with no card")

        let refused = NativeChatRulesCounter()
        var handOff = NativeRules.defaults
        handOff.set(.handOff, for: .networkSends)
        let handing = await store(handOff, counter: refused, rounds: [callRound, doneRound])
        handing.sendText("Post the note to the garden log")
        let handedCard = try await settle(handing)
        try require(!handedCard && refused.count == 0, "A handed off posting tool shows no card and never runs")
        try require(handing.selected?.messages.last?.toolActivities.first?.state == .failed && !handing.generating,
                    "A handed off posting tool fails and the turn completes")
        print("  native chat rules store OK (default send card with standing choices, allow in this chat, saved allow, hand off)")
    }
}
