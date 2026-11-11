import Foundation
import GRDB

final class RuleOfferTransport: NativeChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var captured: [[NativeChatMessage]] = []

    var histories: [[NativeChatMessage]] { locked { captured } }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        let snapshot: NativeChatStreamSnapshot = locked {
            captured.append(messages)
            calls += 1
            guard messages.last?.role == "user", messages.last?.content.contains("Run printf") == true else {
                return NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")
            }
            return NativeChatStreamSnapshot(content: "", toolCalls: [
                NativeChatToolCall(id: "offer-call-\(calls)", name: NativeCommandTools.runName,
                                   arguments: messages.last?.content.contains("twice") == true
                                       ? "{\"command\":\"printf hello && printf again\"}"
                                       : messages.last?.content.contains("timed") == true ? "{\"command\":\"echo hello time\"}" : "{\"command\":\"printf hello\"}"),
            ], finishReason: "tool_calls")
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@MainActor
extension SelfTest {
    static func runRuleOfferModel() throws {
        let require = NativeTaskFixture.require
        func why(_ kind: NativeRuleWhy.Kind = .unsaved, _ action: NativeActionClass = .commands, choice: NativeRuleChoice? = .ask,
                 source: NativeRuleWhy.Source? = .settings, handsOff: Bool = false) -> NativeRuleWhy {
            NativeRuleWhy(kind: kind, action: action, handsOff: handsOff, choice: choice, source: source)
        }
        func run(_ events: [RuleOfferEvent], from start: RuleOfferState = RuleOfferState(), off: Bool = false) -> (RuleOfferState, [Bool]) {
            var state = start
            var offers: [Bool] = []
            for event in events {
                let next = RuleOffer.apply(event, to: state, turnedOff: off)
                state = next.state
                offers.append(next.offer)
            }
            return (state, offers)
        }
        let approve = RuleOfferEvent.approved(why())
        try require(RuleOffer.approvalsBeforeOffer == 3, "Three approvals raise the offer")
        try require(run([approve, approve, approve]).1 == [false, false, true], "The third approval in a row offers and the first two don't")
        try require(run([approve, approve]).0.approvals == 2 && !run([approve, approve]).1.contains(true), "Two approvals don't offer")
        try require(run([approve, approve, .declined(why()), approve]).1 == [false, false, false, false]
                    && run([approve, approve, .declined(why()), approve]).0.approvals == 1, "A decline in between starts the count over")
        try require(run([approve, approve, .declined(why(choice: .actIfPreapproved)), approve, approve, approve]).1.last == true,
                    "After a decline, three more approvals offer again")
        try require(run([approve, .standing, approve, .standing, approve]).1.last == true && run([.standing]).0 == RuleOfferState(),
                    "Standing approvals from the menu neither add nor reset")
        for kind in NativeRuleWhy.Kind.allCases where kind != .unsaved {
            try require(!RuleOffer.counts(why(kind)), "A card shown for \(kind.rawValue) doesn't count")
            try require(run([approve, approve, .approved(why(kind)), approve]).1.last == true
                        && run([approve, approve, .declined(why(kind)), approve]).1.last == true,
                        "A \(kind.rawValue) card neither adds nor resets")
        }
        for odd in [why(source: .chat), why(choice: nil), why(source: nil), why(choice: .act), why(choice: .handOff), why(handsOff: true)] {
            try require(!RuleOffer.counts(odd) && run([approve, approve, .approved(odd), approve]).1.last == true
                        && run([approve, approve, .declined(odd), approve]).1.last == true,
                        "A card not shown because of the setting neither adds nor resets: \(odd)")
        }
        try require(!RuleOffer.counts(nil) && run([.approved(nil), .approved(nil), .approved(nil)]).0.approvals == 0, "A card with no reason never counts")
        try require(RuleOffer.counts(why(choice: .actIfPreapproved)), "A card shown because the setting waits for a go ahead counts")
        let answered = run([approve, approve, .answered, approve, approve, approve])
        try require(answered.0.answered && !answered.1.contains(true), "An answered offer is not raised again in the same chat")
        try require(!run([approve, approve, approve], off: true).1.contains(true), "Offers turned off everywhere never appear")
        for floor in NativeActionClass.allCases where floor.floorItem != nil {
            try require(!RuleOffer.offerable(floor) && !RuleOffer.counts(why(.unsaved, floor)), "Floor kinds are never offered: \(floor.rawValue)")
            var lifted = NativeRules.defaults
            if let item = floor.floorItem { lifted.lift(item, choice: .ask) }
            try require(!RuleOffer.stillAsks(floor, global: lifted, chat: NativeConversationRules()), "A lifted floor kind is still never offered: \(floor.rawValue)")
        }
        try require(NativeActionClass.configurable.allSatisfy(RuleOffer.offerable), "Every configurable kind can be offered")
        try require(RuleOffer.event(.allowOnce, why: why()) == .approved(why()) && RuleOffer.event(.never, why: why()) == .declined(why())
                    && RuleOffer.event(.decline, why: why()) == .declined(why())
                    && [NativeCardChoiceKind.allowHere, .allowAlways, .allowSchedule].allSatisfy { RuleOffer.event($0, why: why()) == .standing },
                    "Card answers map to approvals, declines and standing choices")
        var asks = NativeRules.defaults
        asks.set(.ask, for: .fileEdits)
        asks.set(.actIfPreapproved, for: .reminders)
        try require(RuleOffer.stillAsks(.fileEdits, global: asks, chat: NativeConversationRules())
                    && RuleOffer.stillAsks(.reminders, global: asks, chat: NativeConversationRules())
                    && !RuleOffer.stillAsks(.fileEdits, global: .defaults, chat: NativeConversationRules())
                    && !RuleOffer.stillAsks(.riskyCommands, global: .defaults, chat: NativeConversationRules()),
                    "Only a setting of ask first or go ahead still asks")
        try require(!RuleOffer.stillAsks(.reminders, global: asks, chat: NativeConversationRules(choices: [.reminders: .ask]))
                    && !RuleOffer.stillAsks(.fileEdits, global: asks, chat: NativeConversationRules(choices: [.fileEdits: .handOff]))
                    && RuleOffer.stillAsks(.fileEdits, global: asks, chat: NativeConversationRules(choices: [.fileEdits: .ask])),
                    "A chat with its own stricter choice is not offered")

        let repository = try LocalChatRepository(inMemory: true)
        let store = RuleOfferStore(database: repository.database)
        for _ in 0..<2 { try store.record(approve, conversationID: "a", action: .commands) }
        try require(try store.record(.approved(why(.unsaved, .fileEdits)), conversationID: "a", action: .fileEdits) == false
                    && (try store.record(approve, conversationID: "b", action: .commands)) == false,
                    "Counts are kept per kind and per chat")
        try require(try store.record(approve, conversationID: "a", action: .commands), "The stored count reaches the offer")
        try store.record(.answered, conversationID: "a", action: .commands)
        try require(try store.state(conversationID: "a", action: .commands) == RuleOfferState(approvals: 0, answered: true)
                    && store.state(conversationID: "a", action: .fileEdits).approvals == 1, "Answering one kind leaves the others")
        try store.turnOff(.commands)
        try store.record(approve, conversationID: "b", action: .commands)
        try require(try store.turnedOff(.commands) && !(try store.record(approve, conversationID: "b", action: .commands))
                    && store.state(conversationID: "b", action: .commands).approvals == 3, "Turned off everywhere stops every chat's offer")
        try require(try store.record(approve, conversationID: "", action: .commands) == false && store.turnedOff(.commands),
                    "Events never land on the every chat row")
        try store.remove(conversationID: "a")
        try require(try store.rows(conversationID: "a") == 0 && store.rows(conversationID: "b") == 1 && store.turnedOff(.commands),
                    "Removing a chat's rows keeps the rest")
        print("  rule offer model OK (count, reset, kinds, chats, floor, still asks, store)")
    }

    static func runRuleOfferCopy() throws {
        let require = NativeTaskFixture.require
        let banned = ["grant", "kind", "class", "record", "scope", "streak", "origin", "prefix", "effect", "revoke", "vera", "she", "her", "he", "his"]
        let expected: [NativeActionClass: String] = [
            .fileEdits: "file edits", .commands: "running commands", .trash: "moving files to the Trash", .networkSends: "sending on your behalf",
            .riskyCommands: "running risky commands", .reminders: "changing reminders",
            .serviceChanges: "making changes through connected services", .otherChanges: "making other changes",
        ]
        try require(Set(expected.keys) == Set(NativeActionClass.configurable), "Every configurable kind has offer words")
        for action in NativeActionClass.configurable {
            let words = expected[action] ?? ""
            try require(RuleOfferCopy.words(action) == words && RuleOfferCopy.question(action) == "Stop asking before \(words) in this chat?",
                        "The offer reads plainly for \(action.rawValue)")
            for text in RuleOfferCopy.strings(action) {
                let tokens = text.lowercased().split { !$0.isLetter }.map(String.init)
                try require(!tokens.contains { banned.contains($0) } && !text.contains("\u{2014}"), "Offer copy avoids banned words: \(text)")
            }
            for effect in [NativeRuleEffect.allow, .forbid, .ask, .handOff] {
                let record = NativeRuleRecord(scope: .conversation("c"), action: action, effect: effect, statement: "x")
                try require(RuleRows.sentence(record) == "\(RuleRows.lead(effect)) \(words)", "A whole kind row reads \(RuleRows.sentence(record))")
            }
        }
        try require(RuleRows.sentence(NativeRuleRecord(action: .fileEdits, effect: .allow, statement: "x")) == "Always allow file edits"
                    && RuleRows.sentence(NativeRuleRecord(action: .commands, effect: .allow, statement: "x")) == "Always allow running commands"
                    && RuleRows.sentence(NativeRuleRecord(action: .networkSends, effect: .allow, statement: "x")) == "Always allow sending on your behalf"
                    && RuleRows.sentence(NativeRuleRecord(action: .fileEdits, effect: .forbid, statement: "x")) == "Never allow file edits",
                    "Whole kind rows read as the card did")
        let answers = CardAnswers.offer()
        try require(answers.allowTitle == "Allow" && answers.declineTitle == "Decline"
                    && answers.allowMenu.map(\.title) == ["Allow everywhere"] && answers.declineMenu.map(\.title) == ["Don't offer this again"],
                    "The offer card has two answers with one item behind each caret")
        let spoken = RuleOfferCard.spoken(RuleOfferCopy.question(.fileEdits), answers: answers)
        try require(spoken.count == 6 && spoken.allSatisfy { $0.hasSuffix("Stop asking before file edits in this chat?") },
                    "Every control names the question for assistive tech")
        let record = RuleOffer.record(.fileEdits, conversationID: "c")
        try require(record.scope == .conversation("c") && record.action == .fileEdits && record.toolID == nil && record.target == nil
                    && record.effect == .allow && record.origin == .confirmCard && record.originConversationID == "c"
                    && record.statement == "Always allow file edits" && record.reason == "You chose this on a confirmation card.",
                    "Allow saves one plain rule for this chat")
        let encoded = try JSONEncoder().encode([NativeDisplayBlock.ruleOffer(NativeRuleOffer(id: "o", action: .trash, state: .allowedHere))])
        let decoded = try JSONDecoder().decode([NativeDisplayBlock].self, from: encoded)
        try require(decoded == [.ruleOffer(NativeRuleOffer(id: "o", action: .trash, state: .allowedHere))] && decoded[0].id == "offer:o",
                    "An offer block survives a save")
        let odd = Data("[{\"type\":\"rule_offer\",\"rule_offer\":{\"id\":\"o\",\"action\":\"teleport\",\"state\":\"maybe\"}}]".utf8)
        guard case .ruleOffer(let tolerant)? = try JSONDecoder().decode([NativeDisplayBlock].self, from: odd).first else {
            throw NativeTaskFixture.Failure.assertion("An offer block with unknown values still decodes")
        }
        try require(tolerant.action == nil && tolerant.state == .closed && RuleOfferCard.line(tolerant) == nil,
                    "An offer block with unknown values decodes closed and shows nothing")
        let folderTarget = NativeRuleTarget.make(.folder, "/tmp/offer/notes.md")
        let recipient = NativeRuleTarget.make(.recipient, "workshop@example.com")
        func card(_ action: NativeActionClass, tool: String = "offer-tool", targets: [NativeRuleTarget?] = [], command: String? = nil,
                  governed: Bool = true, fixed: Bool = false, alwaysAsks: Bool = false) -> Bool {
            ChatStore.ruleOfferCard(NativeCardSubject(action: action, toolID: tool, toolTitle: "Tool", targets: targets.compactMap { $0 }, command: command,
                                                      governed: governed, fixed: fixed, alwaysAsks: alwaysAsks))
        }
        try require(!ChatStore.ruleOfferCard(nil) && !card(.otherChanges, alwaysAsks: true) && !card(.otherChanges, governed: false)
                    && card(.otherChanges), "A card from a tool that always asks never counts")
        try require(!card(.networkSends) && card(.networkSends, fixed: true) && card(.networkSends, targets: [recipient]),
                    "A send with no declared recipient never counts")
        try require(card(.commands, tool: NativeCommandTools.toolID, command: "printf hello")
                    && !card(.commands, tool: NativeCommandTools.toolID, command: "printf hello && printf again")
                    && card(.riskyCommands, tool: NativeCommandTools.toolID, command: "rm -rf build")
                    && !card(.networkSends, tool: NativeCommandTools.toolID, command: "git push origin main")
                    && !card(.trash, tool: NativeCommandTools.toolID, command: "trash notes.md"),
                    "A command that isn't plain never counts, a risky one does, and a send or Trash move through a command doesn't")
        try require(card(.fileEdits, tool: NativeFolderTools.toolID, targets: [folderTarget]) && !card(.fileEdits, tool: NativeFolderTools.toolID),
                    "A file edit counts when its folder is known")
        print("  rule offer copy OK (words, banned words, rule rows, answers, blocks)")
    }

    static func runRuleOfferStore() async throws {
        let require = NativeTaskFixture.require
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vera-offer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
        func makeStore(_ repository: LocalChatRepository, transport: RuleOfferTransport) async -> ChatStore {
            let store = ChatStore(nativeConfig: config, nativeTransport: transport, repository: repository, nativeEnabledToolIDs: [NativeCommandTools.toolID])
            await store.connect()
            return store
        }
        func chat(_ store: ChatStore) throws -> String {
            store.newConversation()
            store.grantFolder(folder)
            guard let id = store.selectedID, store.grants(for: id).count == 1 else { throw NativeTaskFixture.Failure.assertion("The offer fixture shares a folder") }
            return id
        }
        func turn(_ store: ChatStore, _ text: String = "Run printf hello in the folder", answer: NativeCardChoiceKind = .allowOnce) async throws -> Bool {
            guard let id = store.selectedID else { throw NativeTaskFixture.Failure.assertion("A chat is selected") }
            let count = store.conversations.first { $0.id == id }?.messages.count ?? 0
            guard store.sendText(text) else { throw NativeTaskFixture.Failure.assertion("The message sends") }
            var card = false
            for _ in 0..<1000 {
                if let (messageID, request) = store.turnConfirmations.first.map({ ($0.key, $0.value) }) {
                    card = true
                    store.resolveTurnConfirmation(messageID, decision: answer, requestID: request.id, token: store.turnConfirmationTokens[messageID])
                }
                let messages = store.conversations.first { $0.id == id }?.messages ?? []
                if messages.count >= count + 2, messages.last?.state == .complete, store.turnExecutions.isEmpty, store.turnConfirmations.isEmpty { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return card
        }
        func offers(_ store: ChatStore, _ id: String) -> [(UUID, NativeRuleOffer)] {
            (store.conversations.first { $0.id == id }?.messages ?? []).flatMap { message in
                message.displayBlocks.compactMap { block -> (UUID, NativeRuleOffer)? in
                    if case .ruleOffer(let offer) = block { return (message.id, offer) }
                    return nil
                }
            }
        }
        func reachOffer(_ store: ChatStore, _ id: String) async throws -> (UUID, NativeRuleOffer) {
            for index in 0..<3 {
                try require(try await turn(store), "Approval \(index + 1) shows a card")
                if index < 2 { try require(offers(store, id).isEmpty, "No offer before the third approval") }
            }
            let found = offers(store, id)
            guard found.count == 1, let last = store.conversations.first(where: { $0.id == id })?.messages.last,
                  found[0].0 == last.id, found[0].1.state == .waiting, found[0].1.action == .commands else {
                throw NativeTaskFixture.Failure.assertion("Three approvals leave one waiting offer under the last reply: \(found)")
            }
            return found[0]
        }
        func commands(_ store: ChatStore, _ id: String) -> NativeRuleDecision {
            store.ruleResolver(for: id, requestText: "").tool(NativeCommandTools.toolID, targets: []).decide(forCommand: "printf hello").decision
        }
        func sent(_ transport: RuleOfferTransport, from start: Int) -> String {
            transport.histories.dropFirst(start).flatMap { $0 }.map(\.content).joined(separator: "\n").lowercased()
        }
        func clean(_ text: String) -> Bool {
            !text.contains("stop asking") && !text.contains("stopped asking") && !text.contains("don't offer") && !text.contains("allow everywhere")
        }

        let transport = RuleOfferTransport()
        let store = await makeStore(try LocalChatRepository(inMemory: true), transport: transport)
        guard let offerStore = store.ruleOfferStore else { throw NativeTaskFixture.Failure.assertion("The offer store opens") }
        func exec(_ sql: String) throws { try offerStore.database.write { db in try db.execute(sql: sql) } }
        let here = try chat(store)
        let (hereMessage, hereOffer) = try await reachOffer(store, here)
        let shownAt = transport.histories.count
        try require(try await turn(store), "A fourth approval still shows its card")
        try require(offers(store, here).count == 1, "A second offer doesn't appear while one waits")
        try require(clean(sent(transport, from: shownAt)), "The model never sees the waiting offer")
        let records = store.ruleRecords.count
        store.answerRuleOffer(.allow, messageID: hereMessage, blockID: hereOffer.blockID, everywhere: { _ in false })
        let saved = store.ruleRecords.filter { $0.scope == .conversation(here) }
        try require(offers(store, here).first?.1.state == .allowedHere && saved.count == 1 && store.ruleRecords.count == records + 1
                    && saved[0].action == .commands && saved[0].toolID == nil && saved[0].target == nil && saved[0].effect == .allow
                    && saved[0].origin == .confirmCard, "Allow saves one rule for this chat and shows the quiet line")
        let answeredAt = transport.histories.count
        try require(!(try await turn(store)), "After Allow the next command here runs with no card")
        try require(store.conversations.first { $0.id == here }?.messages.last?.toolActivities.first?.state == .succeeded,
                    "The command after Allow ran")
        try require(clean(sent(transport, from: answeredAt)), "The model never sees the answered offer")
        try require(commands(store, here) == .act(.grant), "Commands act here after Allow")
        let always = NativeToolDefinition(id: "offer-always", name: "offer_always", title: "Always", description: "Always",
                                          parameters: .object(["type": .string("object")]), confirmation: .required, effect: .write, action: .commands,
                                          isAvailable: { true }, execute: { _ in .null })
        let relaxed = NativeToolDefinition(id: "offer-relaxed", name: "offer_relaxed", title: "Relaxed", description: "Relaxed",
                                           parameters: .object(["type": .string("object")]), confirmation: .none, effect: .write, action: .commands,
                                           isAvailable: { true }, execute: { _ in .null })
        let ruledAlways = ChatStore.ruled(always, rules: store.nativeRuleSource, store: nil, conversationID: here, requestText: "")
        let ruledRelaxed = ChatStore.ruled(relaxed, rules: store.nativeRuleSource, store: nil, conversationID: here, requestText: "")
        try require(ruledAlways.confirmationFor?([:]) == true && ruledRelaxed.confirmationFor?([:]) == false,
                    "An always ask tool still asks here while the rest of that kind runs")
        store.answerRuleOffer(.allow, messageID: hereMessage, blockID: hereOffer.blockID, everywhere: { _ in false })
        try require(store.ruleRecords.count == records + 1, "An answered offer can't be answered twice")

        store.tightenConversationRule(.handOff, for: .commands, conversationID: here)
        try require(commands(store, here) == .handOff, "After Allow, leaving commands to you in this chat hands them back")
        store.clearConversationRule(for: .commands, conversationID: here)
        try require(commands(store, here) == .act(.grant), "Back on the default, the saved rule decides again")

        let elsewhere = try chat(store)
        try require(commands(store, elsewhere) == .ask, "Allow in one chat leaves other chats asking")
        let (declineMessage, declineOffer) = try await reachOffer(store, elsewhere)
        for typed in ["allow", "stop asking", "Allow everywhere"] {
            try require(!(try await turn(store, typed)), "A typed reply runs no card: \(typed)")
        }
        try require(offers(store, elsewhere).count == 1 && offers(store, elsewhere).first?.1.state == .waiting
                    && store.ruleRecords.count == records + 1 && store.nativeRules == .defaults,
                    "Typing allow or stop asking changes nothing while the offer waits")
        store.answerRuleOffer(.decline, messageID: declineMessage, blockID: declineOffer.blockID, everywhere: { _ in false })
        try require(offers(store, elsewhere).first?.1.state == .closed && RuleOfferCard.line(offers(store, elsewhere)[0].1) == nil
                    && commands(store, elsewhere) == .ask && store.ruleRecords.count == records + 1, "Decline closes the card and saves nothing")
        for _ in 0..<3 { _ = try await turn(store) }
        try require(offers(store, elsewhere).count == 1, "A declined offer isn't raised again in that chat")

        let third = try chat(store)
        let (neverMessage, neverOffer) = try await reachOffer(store, third)
        store.answerRuleOffer(.neverOffer, messageID: neverMessage, blockID: neverOffer.blockID, everywhere: { _ in false })
        try require(offers(store, third).first?.1.state == .closed && commands(store, third) == .ask && (try offerStore.turnedOff(.commands)),
                    "Don't offer this again closes the card and turns the offer off")
        let fourth = try chat(store)
        for _ in 0..<3 { _ = try await turn(store) }
        try require(offers(store, fourth).isEmpty, "Once turned off, no chat offers that kind")
        try exec("DELETE FROM native_rule_offers WHERE conversation_id = ''")

        let failing = try chat(store)
        let (failMessage, failOffer) = try await reachOffer(store, failing)
        try exec("CREATE TRIGGER offer_block BEFORE INSERT ON native_rule_records BEGIN SELECT RAISE(ABORT, 'blocked'); END;")
        store.answerRuleOffer(.allow, messageID: failMessage, blockID: failOffer.blockID, everywhere: { _ in false })
        try require(offers(store, failing).first?.1.state == .waiting && offers(store, failing).first?.1.failed == true
                    && store.ruleRecords.count == records + 1 && commands(store, failing) == .ask, "A failed save keeps the card and says so")
        try exec("DROP TRIGGER offer_block")
        store.answerRuleOffer(.allow, messageID: failMessage, blockID: failOffer.blockID, everywhere: { _ in false })
        try require(offers(store, failing).first?.1.state == .allowedHere && offers(store, failing).first?.1.failed == false
                    && commands(store, failing) == .act(.grant), "Trying again after a failed save works")

        let stale = try chat(store)
        let (staleMessage, staleOffer) = try await reachOffer(store, stale)
        store.tightenConversationRule(.handOff, for: .commands, conversationID: stale)
        store.answerRuleOffer(.allow, messageID: staleMessage, blockID: staleOffer.blockID, everywhere: { _ in true })
        try require(offers(store, stale).first?.1.state == .closed && store.ruleRecords.count == records + 2
                    && (try offerStore.state(conversationID: stale, action: .commands)).answered, "A stale card closes and saves nothing")

        let wide = try chat(store)
        let (wideMessage, wideOffer) = try await reachOffer(store, wide)
        var writes = 0
        let broken = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in
            throw NSError(domain: "SelfTest", code: 1)
        })
        store.answerRuleOffer(.allowEverywhere, messageID: wideMessage, blockID: wideOffer.blockID, config: broken)
        try require(offers(store, wide).first?.1.state == .waiting && offers(store, wide).first?.1.failed == true,
                    "A failed settings save keeps the card and says so")
        let working = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in writes += 1 })
        let before = store.ruleRecords.count
        store.answerRuleOffer(.allowEverywhere, messageID: wideMessage, blockID: wideOffer.blockID, config: working)
        try require(offers(store, wide).first?.1.state == .allowedEverywhere && writes == 1 && store.nativeRules.choice(for: .commands) == .act
                    && store.ruleRecords.count == before && commands(store, elsewhere) == .act(.rule),
                    "Allow everywhere changes the setting for every chat and saves no rule")
        let staleNext = try chat(store)
        for _ in 0..<3 { try require(!(try await turn(store)), "Commands run without asking once allowed everywhere") }
        try require(offers(store, staleNext).isEmpty, "Nothing is offered once the setting no longer asks")
        store.updateNativeRules(.defaults)

        let compound = try chat(store)
        for _ in 0..<3 { try require(try await turn(store, "Run printf twice in the folder"), "A command that isn't plain shows a card") }
        try require(offers(store, compound).isEmpty, "Approving commands that aren't plain never leads to an offer")

        let timed = try chat(store)
        for _ in 0..<3 { try require(try await turn(store, "Run printf timed in the folder"), "A command with a part that can't be read plainly shows a card") }
        try require(offers(store, timed).isEmpty, "A command the app can't read as plain never leads to an offer, even with a simple start")

        let partial = try chat(store)
        let (partialMessage, partialOffer) = try await reachOffer(store, partial)
        try exec("CREATE TRIGGER offer_block BEFORE INSERT ON native_rule_offers WHEN NEW.conversation_id = '' BEGIN SELECT RAISE(ABORT, 'blocked'); END;")
        store.answerRuleOffer(.neverOffer, messageID: partialMessage, blockID: partialOffer.blockID, everywhere: { _ in false })
        try require(offers(store, partial).first?.1.state == .waiting && offers(store, partial).first?.1.failed == true
                    && !(try offerStore.state(conversationID: partial, action: .commands)).answered && !(try offerStore.turnedOff(.commands)),
                    "A failed don't offer again saves nothing and keeps the card")
        try exec("DROP TRIGGER offer_block")
        store.answerRuleOffer(.neverOffer, messageID: partialMessage, blockID: partialOffer.blockID, everywhere: { _ in false })
        try require(offers(store, partial).first?.1.state == .closed && (try offerStore.turnedOff(.commands)), "Trying don't offer again a second time finishes it")
        try exec("DELETE FROM native_rule_offers WHERE conversation_id = ''")

        let torn = try chat(store)
        let (tornMessage, tornOffer) = try await reachOffer(store, torn)
        let tornCount = store.ruleRecords.count
        try exec("CREATE TRIGGER offer_block BEFORE UPDATE OF display_blocks_json ON messages BEGIN SELECT RAISE(ABORT, 'blocked'); END;")
        store.answerRuleOffer(.allow, messageID: tornMessage, blockID: tornOffer.blockID, everywhere: { _ in false })
        try exec("DROP TRIGGER offer_block")
        try require(store.ruleRecords.count == tornCount + 1 && (try offerStore.state(conversationID: torn, action: .commands)).answered,
                    "Allow saves the rule and the answer even when the card can't be rewritten")
        store.updateRuleOffer(tornOffer, messageID: tornMessage)
        try require(offers(store, torn).first?.1.state == .waiting, "The fixture puts the card back to waiting as a relaunch would")
        store.answerRuleOffer(.allow, messageID: tornMessage, blockID: tornOffer.blockID, everywhere: { _ in false })
        try require(store.ruleRecords.count == tornCount + 1 && offers(store, torn).first?.1.state == .closed,
                    "A card left waiting after it was answered closes and saves nothing more")

        let half = try chat(store)
        let (halfMessage, halfOffer) = try await reachOffer(store, half)
        let halfCount = store.ruleRecords.count
        try exec("CREATE TRIGGER offer_block BEFORE UPDATE ON native_rule_offers BEGIN SELECT RAISE(ABORT, 'blocked'); END;")
        store.answerRuleOffer(.allow, messageID: halfMessage, blockID: halfOffer.blockID, everywhere: { _ in false })
        try require(offers(store, half).first?.1.state == .waiting && offers(store, half).first?.1.failed == true
                    && store.ruleRecords.count == halfCount + 1, "A failed answer write keeps the card and says so")
        store.answerRuleOffer(.decline, messageID: halfMessage, blockID: halfOffer.blockID, everywhere: { _ in false })
        try require(offers(store, half).first?.1.state == .waiting, "A failed decline write keeps the card")
        try exec("DROP TRIGGER offer_block")
        store.answerRuleOffer(.allow, messageID: halfMessage, blockID: halfOffer.blockID, everywhere: { _ in false })
        try require(offers(store, half).first?.1.state == .allowedHere && store.ruleRecords.count == halfCount + 1,
                    "Trying again after a failed answer write doesn't save the rule twice")

        try exec("CREATE TRIGGER offer_block BEFORE DELETE ON native_rule_offers BEGIN SELECT RAISE(ABORT, 'blocked'); END;")
        store.deleteConversation(half, confirmed: true)
        try exec("DROP TRIGGER offer_block")
        func chats(_ id: String) throws -> Int {
            try offerStore.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations WHERE id = ?", arguments: [id]) ?? 0 }
        }
        let kept = try chats(half)
        try require((kept == 0) == (try offerStore.rows(conversationID: half) == 0), "A chat is never deleted while its offer rows stay behind")

        store.deleteConversation(here, confirmed: true)
        try require(try offerStore.rows(conversationID: here) == 0 && offerStore.rows(conversationID: elsewhere) == 1,
                    "Deleting a chat removes its offer rows")
        store.ensureVeraThread()
        guard let thread = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion conversation exists") }
        try offerStore.record(.approved(NativeRuleWhy(kind: .unsaved, action: .commands, handsOff: false, choice: .ask, source: .settings)),
                              conversationID: thread, action: .commands)
        try require(try offerStore.rows(conversationID: thread) == 1, "The companion conversation keeps a count")
        store.resetDot()
        try require(try offerStore.rows(conversationID: thread) == 0, "Start over removes the companion conversation's offer rows")
        print("  rule offer store OK (offer, waiting, typed, model, allow, decline, never, failed, stale, everywhere, delete, start over)")
    }

    static func runRuleOfferRelaunch() async throws {
        let require = NativeTaskFixture.require
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vera-offer-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("offer.sqlite")
        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
        func open() async throws -> ChatStore {
            let store = ChatStore(nativeConfig: config, nativeTransport: RuleOfferTransport(), repository: try LocalChatRepository(url: url),
                                  nativeEnabledToolIDs: [NativeCommandTools.toolID])
            await store.connect()
            return store
        }
        func approve(_ store: ChatStore, _ id: String) async throws {
            store.select(id)
            let count = store.conversations.first { $0.id == id }?.messages.count ?? 0
            guard store.sendText("Run printf hello in the folder", conversationID: id) else { throw NativeTaskFixture.Failure.assertion("The message sends") }
            var card = false
            for _ in 0..<1000 {
                if let (messageID, request) = store.turnConfirmations.first.map({ ($0.key, $0.value) }) {
                    card = true
                    store.resolveTurnConfirmation(messageID, decision: .allowOnce, requestID: request.id, token: store.turnConfirmationTokens[messageID])
                }
                let messages = store.conversations.first { $0.id == id }?.messages ?? []
                if card, messages.count >= count + 2, messages.last?.state == .complete, store.turnExecutions.isEmpty, store.turnConfirmations.isEmpty { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(card, "Each approval shows a card")
        }
        func waiting(_ store: ChatStore, _ id: String) -> (UUID, NativeRuleOffer)? {
            for message in store.conversations.first(where: { $0.id == id })?.messages ?? [] {
                for block in message.displayBlocks { if case .ruleOffer(let offer) = block, offer.state == .waiting { return (message.id, offer) } }
            }
            return nil
        }
        let opened = try await open()
        opened.newConversation()
        opened.grantFolder(folder)
        guard let id = opened.selectedID else { throw NativeTaskFixture.Failure.assertion("A chat is selected") }
        try await approve(opened, id)
        try await approve(opened, id)
        opened.conversationTurnLoop?.cancel()
        let second = try await open()
        if second.conversations.first(where: { $0.id == id })?.messages.isEmpty != false {
            second.conversations = (try? second.repository?.listConversations()) ?? second.conversations
            if let index = second.conversations.firstIndex(where: { $0.id == id }) {
                second.conversations[index].messages = (try second.repository?.messages(conversationID: id)) ?? []
            }
        }
        try require(second.grants(for: id).count == 1 && waiting(second, id) == nil, "The chat reopens with its folder and no offer yet")
        try await approve(second, id)
        guard waiting(second, id) != nil else { throw NativeTaskFixture.Failure.assertion("The third approval after a relaunch offers") }
        second.conversationTurnLoop?.cancel()
        let third = try await open()
        if let index = third.conversations.firstIndex(where: { $0.id == id }), third.conversations[index].messages.isEmpty {
            third.conversations[index].messages = (try third.repository?.messages(conversationID: id)) ?? []
        }
        guard let (messageID, offer) = waiting(third, id) else { throw NativeTaskFixture.Failure.assertion("The waiting offer survives a relaunch") }
        third.answerRuleOffer(.allow, messageID: messageID, blockID: offer.blockID, everywhere: { _ in false })
        let stored = try third.repository?.messages(conversationID: id).flatMap(\.displayBlocks) ?? []
        try require(stored.contains(.ruleOffer(NativeRuleOffer(id: offer.id, action: .commands, state: .allowedHere)))
                    && third.ruleRecords.contains { $0.scope == .conversation(id) && $0.action == .commands && $0.effect == .allow },
                    "An offer opened after a relaunch is answered and saved")
        third.conversationTurnLoop?.cancel()
        print("  rule offer relaunch OK (count survives, card answers after relaunch)")
    }
}
