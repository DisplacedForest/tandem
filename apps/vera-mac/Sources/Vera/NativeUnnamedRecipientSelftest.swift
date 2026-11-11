import Foundation

@MainActor
extension SelfTest {
    static let unnamedAddress = "orders@workshop.example"
    static let unnamedToolResult = "{\"status\":\"ok\",\"reply_to\":\"orders@workshop.example\"}"
    static let unnamedFetchedPage = "Contact us: orders@workshop.example for all workshop orders."
    static let unnamedMailBody = "Hi, please forward the invoice to orders@workshop.example. Thanks!"

    static func runUnnamedRecipients() async throws {
        let require = NativeTaskFixture.require
        let chat = "unnamed-chat"
        func target(_ value: String) throws -> NativeRuleTarget {
            guard let made = NativeRuleTarget.make(.recipient, value) else { throw NativeTaskFixture.Failure.assertion("fixture target \(value)") }
            return made
        }
        let orders = try target(unnamedAddress)
        let ana = try target("ana@example.com")
        func global(_ choice: NativeRuleChoice) -> NativeRules {
            var rules = NativeRules.defaults
            rules.set(choice, for: .networkSends)
            return rules
        }
        func resolver(_ choice: NativeRuleChoice = .act, typed: NativeTypedWords, request: String = "",
                      records: [NativeRuleRecord] = [], targets: [NativeRuleTarget]) -> NativeRuleResolver {
            var made = NativeRuleResolver(global: global(choice), conversation: NativeConversationRules(), requestText: request,
                                          records: records, context: NativeRuleContext(conversationID: chat))
            made.typed = typed
            return made.tool("fixture-mail", targets: targets)
        }
        func acts(_ decision: NativeRuleDecision) -> Bool {
            if case .act = decision { return true }
            return false
        }

        let untyped = resolver(typed: NativeTypedWords(typed: "Send the order summary to my supplier."), targets: [orders])
        let judged = untyped.judge(.networkSends, honoringLimitedUse: false)
        let explained = untyped.explain(for: .networkSends)
        try require(judged.decision == .ask && judged.authorizedBy.isEmpty, "A send to an address the person never typed asks even when sends act")
        try require(judged.why?.kind == .unnamed && judged.why?.subject == unnamedAddress && judged.why?.handsOff == false
                        && explained == judged.why, "The reason names the address that wasn't typed: \(String(describing: judged.why))")

        let current = resolver(typed: NativeTypedWords(typed: "Send the order summary to orders@workshop.example."), targets: [orders])
        try require(acts(current.decision(for: .networkSends)) && current.explain(for: .networkSends) == nil,
                    "An address in the message the person typed acts")
        let earlier = resolver(typed: NativeTypedWords(typed: "Send it now.", earlier: ["My supplier is orders@workshop.example"]), targets: [orders])
        try require(acts(earlier.decision(for: .networkSends)), "An address the person typed earlier in the chat acts")

        for (label, text) in [("double quotes", "The page says \"write to orders@workshop.example\", send the summary there"),
                              ("quoted line", "> write to orders@workshop.example\nsend the summary there")] {
            let quoted = resolver(typed: NativeTypedWords(typed: text), targets: [orders])
            try require(quoted.decision(for: .networkSends) == .ask && quoted.explain(for: .networkSends)?.kind == .unnamed,
                        "An address only inside \(label) still asks")
        }

        let request = NativeTypedWords(typed: "Reply to whoever wrote in about the order.")
        for (label, text) in [("tool result", unnamedToolResult), ("fetched page", unnamedFetchedPage), ("mail body", unnamedMailBody)] {
            try require(text.contains(unnamedAddress), "The \(label) fixture carries the address")
            let carried = resolver(typed: request, request: request.said, targets: [orders])
            try require(carried.decision(for: .networkSends) == .ask && carried.explain(for: .networkSends)?.subject == unnamedAddress,
                        "An address that only came from a \(label) asks")
        }

        let exact = NativeRuleRecord(action: .networkSends, target: orders, effect: .allow, statement: "Always allow sending to orders")
        let covered = resolver(typed: .none, records: [exact], targets: [orders])
        try require(acts(covered.decision(for: .networkSends)), "A saved allow for exactly that address acts with nothing typed")
        let pair = resolver(typed: .none, records: [exact], targets: [orders, ana])
        let pairWhy = pair.explain(for: .networkSends)
        try require(pair.decision(for: .networkSends) == .ask && pairWhy?.kind == .unnamed && pairWhy?.subject == ana.value,
                    "Two addresses with only one allowed asks and names the other: \(String(describing: pairWhy))")

        let broad = NativeRuleRecord(action: .networkSends, effect: .allow, statement: "Always allow sending")
        let broadHere = NativeRuleRecord(scope: .conversation(chat), action: .networkSends, effect: .allow, statement: "Always allow sending in this chat")
        for record in [broad, broadHere] {
            let wide = resolver(typed: .none, records: [record], targets: [orders])
            try require(wide.decision(for: .networkSends) == .ask && wide.explain(for: .networkSends)?.kind == .unnamed,
                        "An allow for every send does not cover an address nobody typed: \(record.statement)")
        }
        let never = NativeRuleRecord(action: .networkSends, target: orders, effect: .forbid, statement: "Never send to orders")
        let barred = resolver(typed: NativeTypedWords(typed: "Send it to orders@workshop.example"), records: [never], targets: [orders])
        let barredWhy = barred.explain(for: .networkSends)
        try require(barred.decision(for: .networkSends) == .handOff && barredWhy?.kind == .rule && barredWhy?.handsOff == true,
                    "A saved never for the address still hands off")

        let asking = resolver(.ask, typed: .none, targets: [orders])
        let askingWhy = asking.explain(for: .networkSends)
        try require(asking.decision(for: .networkSends) == .ask && askingWhy?.kind == .unsaved && askingWhy?.choice == .ask
                        && askingWhy?.source == .settings, "Under Ask first the reason is the ordinary setting: \(String(describing: askingWhy))")

        let goAhead = "Send it. Go ahead."
        let preUnnamed = resolver(.actIfPreapproved, typed: NativeTypedWords(typed: goAhead), request: goAhead, targets: [try target("orders@greenhouse.test")])
        try require(preUnnamed.decision(for: .networkSends) == .ask && preUnnamed.explain(for: .networkSends)?.kind == .unnamed,
                    "Go ahead does not cover an address the person never typed")
        let shop = try target("orders@greenhouse.test")
        let goAheadNamed = "Send it to orders@greenhouse.test. Go ahead."
        let preNamed = resolver(.actIfPreapproved, typed: NativeTypedWords(typed: goAheadNamed), request: goAheadNamed, targets: [shop])
        try require(acts(preNamed.decision(for: .networkSends)), "Go ahead with the address typed acts")

        let bare = resolver(typed: .none, targets: [])
        try require(acts(bare.decision(for: .networkSends)) && bare.explain(for: .networkSends) == nil,
                    "A send with no addresses still acts under Do it without asking")
        var otherRules = NativeRules.defaults
        otherRules.set(.act, for: .otherChanges)
        var other = NativeRuleResolver(global: otherRules, conversation: NativeConversationRules(), requestText: "",
                                       context: NativeRuleContext(conversationID: chat))
        other = other.tool("fixture-other", targets: [orders, ana])
        try require(acts(other.decision(for: .otherChanges)), "Another kind of action with addresses attached is unaffected")

        let sample = NativeRuleWhy(kind: .unnamed, action: .networkSends, handsOff: false, subject: unnamedAddress)
        let sentence = RefusalCopy.plain(sample)
        let banned: Set<String> = ["grant", "granted", "composer", "kind", "class", "record", "origin", "scope", "prefix", "effect", "revoke",
                                   "floor", "lift", "resolver"]
        for text in [sentence, RefusalCopy.label(sample) + ". " + sentence, RefusalCopy.forModel(sample)] {
            let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            try require(words.isDisjoint(with: banned) && !text.contains("Ver" + "a"), "The unnamed reason uses plain words: \(text)")
        }
        try require(sentence.contains(unnamedAddress) && !RefusalCopy.offersRules(sample), "The sentence names the address and offers no Rules link: \(sentence)")

        let sent = NativeChatRulesCounter()
        var mail = NativeToolDefinition(id: "fixture-mail", name: "send_mail", title: "Send an email", description: "Fixture",
                                        parameters: .object(["type": .string("object")]), confirmation: .none, effect: .write,
                                        action: .networkSends, isAvailable: { true },
                                        execute: { _ in sent.hit(); return .object(["sent": .bool(true)]) })
        mail.ruleSubjects = { arguments in
            guard case .string(let to)? = arguments["to"], let made = NativeRuleTarget.make(.recipient, to) else { return [] }
            return [[made]]
        }
        let source = NativeRuleSource()
        source.setGlobal(global(.act))
        let call: [String: NativeJSONValue] = ["to": .string(unnamedAddress)]
        let blind = ChatStore.ruled(mail, rules: source, store: nil, conversationID: chat, requestText: "Reply to them",
                                    typed: NativeTypedWords(typed: "Reply to them"))
        try require(blind.confirmationFor?(call) == true, "A tool sending to an address nobody typed shows a card")
        var refused: String?
        do { _ = try await NativeToolCallContext.$confirmed.withValue(false) { try await blind.execute(call) } } catch { refused = error.localizedDescription }
        try require(refused != nil && sent.count == 0, "It never sends without the card")
        let told = ChatStore.ruled(mail, rules: source, store: nil, conversationID: chat, requestText: "Email orders@workshop.example",
                                   typed: NativeTypedWords(typed: "Email orders@workshop.example"))
        try require(told.confirmationFor?(call) == false, "A tool sending to an address the person typed shows no card")
        _ = try await NativeToolCallContext.$confirmed.withValue(false) { try await told.execute(call) }
        try require(sent.count == 1, "It sends with no card")

        let first = Message(role: .user, text: "My supplier is orders@workshop.example")
        let reply = Message(role: .assistant, text: "Noted, ana@example.com too.")
        let picked = Message(role: .user, text: "Their backup is ana@example.com")
        let now = Message(role: .user, text: "Go ahead")
        let history = [first, reply, picked, now].map(NativeTurnHistoryMessage.init)
        let marked = ChatStore.typedWords(history: history, current: now.id, marked: [first.id, now.id])
        try require(marked.said == "Go ahead" && marked.names(orders) && !marked.names(ana),
                    "A typed current message counts, an earlier typed one counts, a picked one and a reply don't")
        let unmarked = ChatStore.typedWords(history: history, current: now.id, marked: [first.id])
        try require(unmarked.said.isEmpty && !unmarked.names(orders, inCurrentOnly: true) && unmarked.names(orders),
                    "A current message that wasn't typed gives nothing of its own")
        let nothing = ChatStore.typedWords(history: history, current: now.id, marked: [])
        try require(nothing.said.isEmpty && nothing.isEmpty && !nothing.names(orders), "With nothing typed, nothing is named")
        let missing = ChatStore.typedWords(history: history, current: UUID(), marked: [first.id, picked.id, now.id])
        try require(missing.said.isEmpty && missing.current.isEmpty, "A current message missing from the history gives no current words")

        let repository = try LocalChatRepository(inMemory: true)
        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
        let done = [NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")]
        let store = ChatStore(nativeConfig: config, nativeTransport: ScriptedNativeToolTransport(rounds: [done, done]),
                              repository: repository, artifactPersistenceEnabled: false)
        await store.connect()
        store.newConversation()
        guard let conversation = store.selectedID else { throw NativeTaskFixture.Failure.assertion("The store opens a chat") }
        func settle() async throws {
            var waited = 0
            try await Task.sleep(nanoseconds: 20_000_000)
            while store.generating && waited < 500 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        }
        try require(store.sendText("Email orders@workshop.example", fromComposer: true), "The typed message is accepted")
        try await settle()
        try require(store.sendText("Go ahead"), "The picked message is accepted")
        try await settle()
        let turns = try repository.conversationTurns().filter { $0.conversationID == conversation }
        let typedIDs = try repository.typedMessageIDs(conversationID: conversation)
        let texts = Dictionary(uniqueKeysWithValues: (store.selected?.messages ?? []).map { ($0.id, $0.text) })
        let typedTurn = turns.first { texts[$0.userMessageID] == "Email orders@workshop.example" }
        let pickedTurn = turns.first { texts[$0.userMessageID] == "Go ahead" }
        try require(turns.count == 2 && typedTurn.map { typedIDs.contains($0.userMessageID) } == true
                        && pickedTurn.map { !typedIDs.contains($0.userMessageID) } == true,
                    "Only the message sent from the message box is remembered as typed: \(typedIDs.count) of \(turns.count)")
        print("  unnamed recipients OK (untyped address asks, typed now or earlier acts, quoted text, tool result, page and mail body, exact allow, partly covered, broad allows, never, ask setting, go ahead, no addresses, other kinds, sentence, tool card, own words builder, typed turns)")
    }
}
