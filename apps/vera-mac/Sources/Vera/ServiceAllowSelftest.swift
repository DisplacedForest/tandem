import Foundation
import GRDB

final class ServiceAllowTransport: NativeChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let tools: [String: String]

    init(_ tools: [String: String]) { self.tools = tools }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools offered: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        if NativeRequestAuthorizer.asksRestrictions(messages) { return NativeRequestAuthorizer.answered(NativeRequestAuthorizer.noRestrictions) }
        let snapshot: NativeChatStreamSnapshot = lock.withLock {
            calls += 1
            guard let last = messages.last, last.role == "user", let name = tools.keys.first(where: { last.content.contains("(\($0))") }), let id = tools[name] else {
                return NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")
            }
            return NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: "service-call-\(calls)", name: id, arguments: "{\"title\":\"Gate\"}")],
                                            finishReason: "tool_calls")
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }
}

@MainActor
enum ServiceAllowSelftest {
    static let require = NativeTaskFixture.require
    static let first = NativeServiceTool(tool: "post_update", service: "Synthetic tracker", detail: "Synthetic post_update")

    static func run() async throws {
        try menus()
        try confirm()
        try rows()
        try await handedOff()
        try await offers()
        print("  service allow OK (menus, confirm, rows, handed-off answers across an upgrade, one tool per offer)")
    }

    static func subject(_ service: NativeServiceTool = first, alwaysAsks: Bool = false) -> NativeCardSubject {
        NativeCardSubject(action: .serviceChanges, toolID: "mcp_one", toolTitle: "Synthetic tracker: post_update", alwaysAsks: alwaysAsks, service: service)
    }

    static func menus() throws {
        let chat = NativeCardPlace.chat(conversationID: "c")
        let work = NativeCardPlace.task(taskID: "t", conversationID: "c", scheduleID: nil)
        for place in [chat, work] {
            let offered = NativeCardChoices.offered(subject(), place: place)
            try require(offered.map(\.kind) == [.decline, .never, .allowAlways, .allowOnce], "A service change offers one standing allow: \(place)")
            try require(offered[1].title == "Never allow post_update \(place.neverWords)" && offered[2].title == "Always allow post_update everywhere", "The choices name the tool: \(offered)")
            let records = NativeCardChoices.records(.allowAlways, subject: subject(), place: place, originMessageID: nil)
            try require(records.count == 1 && records[0].scope == .everywhere && records[0].toolID == "mcp_one" && records[0].statement == "Always allow: post_update in Synthetic tracker",
                        "Always allow saves one rule for the tool: \(records)")
        }
        var request = NativeToolConfirmationRequest(activity: NativeToolActivity(id: "a", toolID: "mcp_one", name: "mcp_one", title: "x", round: 1, request: "{}", result: nil,
                                                                                 state: .pending, confirmationRequired: true))
        request.subject = subject()
        request.choices = NativeCardChoices.offered(subject(), place: chat)
        let shown = CardAnswers.chat(request)
        try require(shown.allowMenu.map(\.title) == ["Always allow post_update everywhere"] && shown.allowMenu[0].note == "Everything it can do in Synthetic tracker"
                    && shown.declineMenu.map(\.title) == ["Never allow post_update in this chat"], "The chat menus hold one item each: \(shown)")
        let wires = NativeCardChoices.offered(subject(), place: work).map { NativeCardChoices.wire($0, subject: subject()) }
        try require(wires == ["decline", "never", NativeCardChoices.serviceAlways, "approve"] && NativeCardChoices.kind(wire: NativeCardChoices.serviceAlways) == .allowAlways,
                    "Handed-off work uses an answer an earlier version can't read: \(wires)")
        let task = CardAnswers.task(choices: wires, covers: NativeCardChoices.scope(subject()), neverTitle: "Never allow post_update for this", service: first)
        try require(task.allowMenu == [CardMenuItem(id: NativeCardChoices.serviceAlways, title: "Always allow post_update everywhere", note: "Everything it can do in Synthetic tracker")],
                    "The handed-off menu holds the same item: \(task.allowMenu)")
        for text in (shown.allowMenu + task.allowMenu).map(\.spoken) {
            try require(!text.contains("in this chat") && !text.contains("for this"), "An allow never names the chat: \(text)")
        }
        try require(NativeCardChoices.offered(subject(alwaysAsks: true), place: chat).map(\.kind) == [.decline, .never, .allowOnce], "A tool that always asks offers no standing allow")
        let long = NativeServiceTool(tool: String(repeating: "a", count: 300), service: "Tracker", detail: "")
        try require(NativeCardChoices.offered(subject(long), place: chat).map(\.kind) == [.decline, .allowOnce], "A name too long to show offers nothing standing")
        let other = NativeCardSubject(action: .otherChanges, toolID: "notes", toolTitle: "Update a note")
        try require(NativeCardChoices.offered(other, place: chat).map(\.kind) == [.decline, .never, .allowAlways, .allowHere, .allowOnce], "Other actions keep their choices")
    }

    static func confirm() throws {
        let asked = ServiceAllowConfirm.tool(NativeServiceTool(tool: "HassSynthetic", service: "Den", detail: " Opens the vent.\nFor gates, this unlatches. "))
        try require(asked.question == "Allow everything HassSynthetic can do in Den without asking?" && asked.quotes.map(\.text) == ["Opens the vent.\nFor gates, this unlatches."],
                    "The confirm shows the server's own words: \(asked)")
        try require(ServiceAllowConfirm.tool(NativeServiceTool(tool: "x", service: "Den", detail: " ")).quotes.map(\.text) == ["Den doesn't describe it."], "A tool with no description says so")
        let answers = CardAnswers.task(choices: [NativeCardChoices.serviceAlways, "never"], covers: nil, neverTitle: "Never", service: first)
        try require(answers.route(NativeCardChoices.serviceAlways) == .confirm(NativeCardChoices.serviceAlways, .tool(first)) && answers.route("never") == .send("never"),
                    "Only the wide choice is confirmed")
        try require(CardAnswers.offer(first).route(RuleOfferAnswer.allowEverywhere.rawValue) == .confirm(RuleOfferAnswer.allowEverywhere.rawValue, .tool(first))
                    && CardAnswers.offer().route(RuleOfferAnswer.allowEverywhere.rawValue) == .send(RuleOfferAnswer.allowEverywhere.rawValue)
                    && CardAnswers.offer(first).route(RuleOfferAnswer.neverOffer.rawValue) == .send(RuleOfferAnswer.neverOffer.rawValue),
                    "Allow everywhere on a tool's offer is confirmed, other offers aren't")
    }

    static func rows() throws {
        func record(_ scope: NativeRuleScope, _ effect: NativeRuleEffect = .allow, tool: String? = "mcp_one") -> NativeRuleRecord {
            NativeRuleRecord(scope: scope, action: .serviceChanges, toolID: tool, effect: effect, statement: "Always allow: Synthetic tracker: post_update")
        }
        var places = RulePlaces()
        places.chats["c"] = "Evening lights"
        func row(_ record: NativeRuleRecord) -> RuleRow { RuleRows.row(record, places: places, now: Date(), calendar: .current) }
        let gone = row(record(.conversation("c")))
        try require(!gone.widens && gone.confirm == nil, "An allow whose description can't be shown isn't widened")
        try require(row(record(.conversation("c"), .forbid)).widens, "A never still widens")
        places.services["mcp_one"] = first
        places.tools["mcp_one"] = first.words
        let here = row(record(.conversation("c")))
        try require(here.line.plain(name: nil) == "Always allow post_update in Synthetic tracker, in Evening lights" && here.widens && here.confirm == .tool(first), "The row names the tool: \(here)")
        try require(row(record(.conversation("c"), .forbid)).line.plain(name: nil) == "Never allow post_update in Synthetic tracker, in Evening lights", "A never reads the same way")
        try require(row(record(.everywhere)).line.plain(name: nil) == "Always allow post_update in Synthetic tracker, everywhere", "An everywhere row says so")
        try require(!row(record(.conversation("c"), tool: nil)).widens && row(record(.conversation("c"), .forbid, tool: nil)).widens, "An allow for every service never widens")
        let repository = try LocalChatRepository(inMemory: true)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: repository)
        store.prepareRuleRecords()
        guard let saved = store.addRuleRecord(record(.conversation("c"))) else { throw NativeTaskFixture.Failure.assertion("The rule saves") }
        try require(!store.widenRule(here) && !store.widenRule(row(saved)) && !store.widenRule(row(saved), confirmed: ServiceAllowConfirm.tool(first).confirmed) && store.ruleRecords.first?.scope == .conversation("c"), "A wide allow isn't saved without its confirm")
    }

    static func handedOff() async throws {
        func harness() async throws -> (NativeCompanionHarness, NativeMCPChangesConnection, String) {
            let (manager, connection, server) = try await NativeMCPChangesSelftest.connected([NativeMCPChangesSelftest.tool("post_update")], reads: [], acts: ["post_update"])
            let id = server.toolID("post_update")
            var harness = try NativeCompanionHarness(rules: [.serviceChanges: .ask]) { messages in
                NativeCompanionScriptedModel.toolResults(messages).isEmpty
                    ? NativeCompanionScriptedModel.call(id, "{\"title\":\"Fix the gate\"}") : NativeCompanionScriptedModel.text("Finished.")
            }
            let tools = manager.authority.definitions(scope: IntegrationsText.ownWorkScope)
            let thread = harness.thread
            harness.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: thread.current, tools: tools) }
            return (harness, connection, id)
        }
        let saving = ServiceAllowSaved()
        var (asked, connection, id) = try await harness()
        asked.environment.saveRules = { drafts in saving.add(drafts); return true }
        _ = try asked.create("Post the update")
        let paused = try await asked.runUntilSettled()
        let decision = try asked.decision(paused)
        try require(decision["choices"] as? [String] == ["decline", "never", NativeCardChoices.serviceAlways, "approve"], "The handed-off card holds one standing allow: \(decision)")
        let shown = try JSONDecoder().decode(NativeServiceTool.self, from: try JSONSerialization.data(withJSONObject: decision["service"] ?? [:]))
        try require(shown.tool == "post_update" && shown.service == "Synthetic tracker" && shown.detail == "Synthetic post_update", "The card carries what the confirm shows: \(shown)")
        try asked.reply(paused, "allow_always", digest: decision["digest"] as? String)
        let again = try await asked.runUntilSettled()
        try require(again.state == .needsDecision && connection.count("post_update") == 0 && saving.all.isEmpty, "An earlier version's wide answer asks again and saves nothing")
        try asked.reply(again, NativeCardChoices.serviceAlways, digest: try asked.decision(again)["digest"] as? String)
        let bare = try await asked.runUntilSettled()
        try require(bare.state == .needsDecision && connection.count("post_update") == 0 && saving.all.isEmpty, "The wide answer without its confirm saves nothing and keeps asking")
        try asked.reply(bare, NativeCardChoices.confirmedWire(ServiceAllowConfirmed(digest: "wrong")), digest: try asked.decision(bare)["digest"] as? String)
        let wrong = try await asked.runUntilSettled()
        try require(wrong.state == .needsDecision && saving.all.isEmpty, "A confirm for something else saves nothing")
        let decisionValue = NativeTaskDecision(id: "d", prompt: "p", choices: decision["choices"] as? [String] ?? [], service: shown)
        try require(!decisionValue.accepts(NativeCardChoices.serviceAlways) && decisionValue.accepts(NativeCardChoices.confirmedWire(ServiceAllowConfirm.tool(shown).confirmed))
                    && !decisionValue.accepts(NativeCardChoices.confirmedWire(ServiceAllowConfirmed(digest: "wrong"))) && decisionValue.accepts("approve"),
                    "The wide answer is sent only with its confirm")
        try asked.reply(wrong, NativeCardChoices.confirmedWire(ServiceAllowConfirm.tool(shown).confirmed), digest: try asked.decision(wrong)["digest"] as? String)
        let done = try await asked.runUntilSettled()
        try require(done.state == .completed && connection.count("post_update") == 1 && saving.all.map(\.scope) == [.everywhere] && saving.all.map(\.toolID) == [id],
                    "The confirmed answer saves the tool and runs it: \(saving.all)")

        let earlier = ServiceAllowSaved()
        var (waiting, held, _) = try await harness()
        waiting.environment.saveRules = { drafts in earlier.add(drafts); return true }
        let workID = try waiting.create("Post the update")
        let card = try await waiting.runUntilSettled()
        try waiting.reply(card, "allow_here", digest: try waiting.decision(card)["digest"] as? String)
        let finished = try await waiting.runUntilSettled()
        try require(finished.state == .completed && held.count("post_update") == 1 && earlier.all.map(\.scope) == [.task(workID)], "A card waiting across the upgrade keeps its narrow answer")
    }

    static func offers() async throws {
        let names = ["post_update", "close_update", "move_update"]
        let (manager, _, server) = try await NativeMCPChangesSelftest.connected(names.map { NativeMCPChangesSelftest.tool($0) }, reads: [], acts: Set(names))
        let ids = Dictionary(uniqueKeysWithValues: names.map { ($0, server.toolID($0)) })
        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
        let store = ChatStore(nativeConfig: config, nativeTransport: ServiceAllowTransport(ids), repository: try LocalChatRepository(inMemory: true),
                              nativeEnabledToolIDs: Set(ids.values), nativeMCP: manager, artifactPersistenceEnabled: false)
        await store.connect()
        guard let offerStore = store.ruleOfferStore else { throw NativeTaskFixture.Failure.assertion("The offer store opens") }
        func turn(_ name: String) async throws -> Bool {
            guard let id = store.selectedID else { throw NativeTaskFixture.Failure.assertion("A chat is selected") }
            let count = store.conversations.first { $0.id == id }?.messages.count ?? 0
            guard store.sendText("Please use (\(name)) now") else { throw NativeTaskFixture.Failure.assertion("The message sends") }
            var card = false
            for _ in 0..<1000 {
                if let (messageID, request) = store.turnConfirmations.first.map({ ($0.key, $0.value) }) {
                    card = true
                    store.resolveTurnConfirmation(messageID, decision: .allowOnce, requestID: request.id, token: store.turnConfirmationTokens[messageID])
                }
                let messages = store.conversations.first { $0.id == id }?.messages ?? []
                if messages.count >= count + 2, messages.last?.state == .complete, store.turnExecutions.isEmpty, store.turnConfirmations.isEmpty { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return card
        }
        func chat() throws -> String {
            store.newConversation()
            guard let id = store.selectedID else { throw NativeTaskFixture.Failure.assertion("A chat opens") }
            return id
        }
        func shown(_ id: String) -> [(UUID, NativeRuleOffer)] {
            (store.conversations.first { $0.id == id }?.messages ?? []).flatMap { message in
                message.displayBlocks.compactMap { block -> (UUID, NativeRuleOffer)? in
                    if case .ruleOffer(let offer) = block { return (message.id, offer) }
                    return nil
                }
            }
        }
        func reach(_ name: String) async throws -> (String, UUID, NativeRuleOffer) {
            let id = try chat()
            for _ in 0..<3 { try require(try await turn(name), "Each use shows its card") }
            guard let found = shown(id).first, shown(id).count == 1 else { throw NativeTaskFixture.Failure.assertion("Three approvals of one tool leave one offer: \(shown(id))") }
            return (id, found.0, found.1)
        }

        _ = try chat()
        let mixed = store.selectedID ?? ""
        for name in names { try require(try await turn(name), "Each tool shows its card") }
        try require(shown(mixed).isEmpty, "Three different tools offer nothing")

        let (here, message, offer) = try await reach("post_update")
        guard let subject = offer.subject, subject.toolID == ids["post_update"] else { throw NativeTaskFixture.Failure.assertion("The offer covers the tool: \(offer)") }
        try require(offer.action == nil && offer.actionName == RuleOfferSubject.toolName && RuleOfferCopy.question(subject) == "Stop asking before post_update in Synthetic tracker in this chat?",
                    "The offer names the tool and an earlier version can't read it as every service")
        let round = try JSONDecoder().decode(NativeRuleOffer.self, from: JSONEncoder().encode(offer))
        try require(round == offer, "The offer survives a save")
        store.answerRuleOffer(.allow, messageID: message, blockID: offer.blockID, everywhere: { _ in false })
        let saved = store.ruleRecords
        try require(shown(here).first?.1.state == .allowedHere && saved.count == 1 && saved[0].scope == .conversation(here) && saved[0].toolID == ids["post_update"] && saved[0].action == .serviceChanges,
                    "Allow saves the tool for this chat: \(saved)")
        try require(!(try await turn("post_update")), "The tool then runs with no card here")
        try require(try await turn("close_update"), "Another tool still asks")

        let (wide, wideMessage, wideOffer) = try await reach("close_update")
        let before = store.ruleRecords.count
        store.answerRuleOffer(.allowEverywhere, messageID: wideMessage, blockID: wideOffer.blockID, everywhere: { _ in true })
        try require(shown(wide).first?.1.state == .waiting && store.ruleRecords.count == before, "Allow everywhere without its confirm saves nothing and leaves the offer")
        guard let wideService = wideOffer.service else { throw NativeTaskFixture.Failure.assertion("The offer carries the tool") }
        store.answerRuleOffer(.allowEverywhere, messageID: wideMessage, blockID: wideOffer.blockID, confirmed: ServiceAllowConfirm.tool(wideService).confirmed, everywhere: { _ in true })
        try require(shown(wide).first?.1.state == .allowedEverywhere && store.ruleRecords.contains { $0.scope == .everywhere && $0.toolID == ids["close_update"] }
                    && store.nativeRules.choice(for: .serviceChanges) == .ask, "Allow everywhere covers that tool and leaves the setting")

        let (off, offMessage, offOffer) = try await reach("move_update")
        store.answerRuleOffer(.neverOffer, messageID: offMessage, blockID: offOffer.blockID, everywhere: { _ in false })
        let key = RuleOfferSubject.toolName + ":" + (ids["move_update"] ?? "")
        try require(shown(off).first?.1.state == .closed && (try offerStore.turnedOff(key)) && !(try offerStore.turnedOff(RuleOfferSubject.toolName + ":other")), "Don't offer again stops that tool")
        try offerStore.turnOff(.serviceChanges)
        try require(try offerStore.turnedOff(RuleOfferSubject.toolName + ":other"), "An earlier don't offer again for services covers every tool")

        _ = try chat()
        try require(store.sendText("Please use (move_update) now"), "The message sends")
        for _ in 0..<1000 where store.turnConfirmations.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        guard let (cardMessage, card) = store.turnConfirmations.first.map({ ($0.key, $0.value) }), let cardService = card.subject?.service else {
            throw NativeTaskFixture.Failure.assertion("The card waits")
        }
        let kept = store.ruleRecords.count
        for given in [nil, ServiceAllowConfirmed(digest: "wrong"), ServiceAllowConfirm.tool(first).confirmed] {
            store.resolveTurnConfirmation(cardMessage, decision: .allowAlways, requestID: card.id, token: store.turnConfirmationTokens[cardMessage], confirmed: given)
            try require(store.turnConfirmations[cardMessage]?.id == card.id && store.ruleRecords.count == kept, "The wide answer without its own confirm saves nothing and the card waits")
        }
        store.resolveTurnConfirmation(cardMessage, decision: .allowAlways, requestID: card.id, token: store.turnConfirmationTokens[cardMessage],
                                      confirmed: ServiceAllowConfirm.tool(cardService).confirmed)
        for _ in 0..<1000 where !store.turnExecutions.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(store.ruleRecords.filter { $0.scope == .everywhere && $0.toolID == ids["move_update"] }.count == 1, "The confirmed answer saves the tool")

        guard let narrow = store.addRuleRecord(NativeRuleRecord(scope: .conversation(mixed), action: .serviceChanges, toolID: ids["move_update"], effect: .allow, statement: "Always allow: move_update")),
              let narrowRow = store.ruleRows().first(where: { $0.id == narrow.id }), let needed = narrowRow.confirm else { throw NativeTaskFixture.Failure.assertion("The row can be widened") }
        try require(!store.widenRule(narrowRow) && !store.widenRule(narrowRow, confirmed: ServiceAllowConfirmed(digest: "wrong"))
                    && store.ruleRecords.first { $0.id == narrow.id }?.scope == .conversation(mixed), "Apply everywhere without its confirm saves nothing")
        try require(store.widenRule(narrowRow, confirmed: needed.confirmed) && store.ruleRecords.first { $0.id == narrow.id }?.scope == .everywhere, "Apply everywhere saves once confirmed")

        let old = NativeRuleOffer(id: "old", action: .serviceChanges)
        try require(!old.open && old.subject == .action(.serviceChanges) && NativeRuleOffer(id: "kept", action: .commands).open, "A waiting offer for every service is closed")
    }
}

final class ServiceAllowSaved: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [NativeRuleRecord] = []
    var all: [NativeRuleRecord] { lock.withLock { held } }
    func add(_ records: [NativeRuleRecord]) { lock.withLock { held += records } }
}
