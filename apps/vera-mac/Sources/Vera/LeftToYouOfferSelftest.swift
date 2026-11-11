import Foundation
import GRDB

@MainActor
extension SelfTest {
    static func runLeftToYouOffer() async throws {
        try await leftToYouWorker()
        try leftToYouPredicate()
        try await leftToYouAnswers()
        try leftToYouOldResults()
        try leftToYouCopy()
        print("  left to you OK (offer on a stop from a Leave it to me setting, settings and chat wording, no offer for saved rules, protected actions, unread rules or the closed fallback, keep, ask first in settings and in the chat, failed save, changed setting, second answer, unknown report, relaunch, old results, copy)")
    }

    nonisolated private static func sendThenReport(_ messages: [NativeTaskGenerationMessage]) -> NativeTaskGenerationCompletion {
        NativeCompanionScriptedModel.toolResults(messages).isEmpty
            ? NativeCompanionScriptedModel.call("water_bed", "{\"bed\":\"north\"}") : .text("Finished.")
    }

    private static func handedOff(_ harness: NativeCompanionHarness) async throws -> (NativeTaskRecord, NativeResearchTaskResult) {
        let id = try harness.create()
        let done = try await harness.runUntilSettled()
        try NativeTaskFixture.require(done.state == .completed && harness.service.count("water_bed") == 0 && (try harness.effects(id)).isEmpty,
                                      "The work stops at the step with nothing run")
        return (done, try JSONDecoder().decode(NativeResearchTaskResult.self, from: done.result ?? Data()))
    }

    private static func leftToYouWorker() async throws {
        let require = NativeTaskFixture.require
        let settings = try NativeCompanionHarness(rules: [.networkSends: .handOff], script: sendThenReport)
        let (done, result) = try await handedOff(settings)
        try require(result.offer == NativeLeftToYouOffer(action: "network_sends", source: "settings", step: "Bed: north"),
                    "A stop from the sending setting offers to ask first, with the step as it would have run: \(String(describing: result.offer))")
        let title = "Water a bed"
        try require(result.summary == NativeCompanionWorker.handOffLead(title: title) + " Nothing was changed."
                    && result.why.map { result.report.hasPrefix(NativeCompanionWorker.handOffLead(title: title)) && result.report.contains(RefusalCopy.plain($0)) } == true
                    && !result.report.contains("Bed: north"),
                    "The report reads the same as before: \(result.report)")
        try require((try settings.result(done))["offer"] != nil && done.state == .completed, "The stopped work stays finished")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("left-to-you-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = try FolderGrant.make(url: directory)
        let command = "sudo systemsetup -setremotelogin on"
        var risky = try NativeCompanionHarness(rules: [.commands: .act, .riskyCommands: .handOff]) { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call(NativeCommandTools.runName,
                                                    "{\"command\":\"\(command)\",\"directory\":\"\(grant.path)\"}")
                : .text("Finished.")
        }
        let tools = ChatStore.companionCommandDefinitions(grants: { [grant] })
        let thread = risky.thread
        risky.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: thread.current, tools: tools) }
        let riskyID = try risky.create("Turn on remote login")
        let riskyDone = try await risky.runUntilSettled()
        let riskyResult = try JSONDecoder().decode(NativeResearchTaskResult.self, from: riskyDone.result ?? Data())
        try require(riskyDone.state == .completed && (try risky.effects(riskyID)).isEmpty
                    && riskyResult.offer == NativeLeftToYouOffer(action: "risky_commands", source: "settings", step: command + "\nin " + grant.path),
                    "A risky command stopped by its setting offers to ask first and shows the command and folder: \(String(describing: riskyResult.offer))")

        let chat = try NativeCompanionHarness(rules: [.networkSends: .ask], script: sendThenReport)
        chat.rules.set(NativeConversationRules(choices: [.networkSends: .handOff]), for: chat.thread.current)
        let (_, chatResult) = try await handedOff(chat)
        try require(chatResult.offer?.source == "chat" && chatResult.offer?.action == "network_sends",
                    "A stop from this chat's own choice offers to ask first in this chat")

        for effect in [NativeRuleEffect.forbid, .handOff] {
            let saved = try NativeCompanionHarness(rules: [.networkSends: .ask], script: sendThenReport)
            saved.rules.setRecords([NativeRuleRecord(action: .networkSends, toolID: "garden", effect: effect, statement: "Never water the beds")])
            let (_, savedResult) = try await handedOff(saved)
            try require(savedResult.offer == nil && savedResult.why?.kind == .rule, "A saved rule that stops the step offers nothing")
        }

        let unread = try NativeCompanionHarness(rules: [.networkSends: .handOff], script: sendThenReport)
        unread.rules.fail()
        let (_, unreadResult) = try await handedOff(unread)
        try require(unreadResult.offer == nil, "Rules that couldn't be read offer nothing")

        var closed = try NativeCompanionHarness(rules: [.networkSends: .handOff], script: sendThenReport)
        closed.environment.authority = { _, request in
            let all = NativeRules(choices: Dictionary(uniqueKeysWithValues: NativeActionClass.allCases.map { ($0, NativeRuleChoice.handOff) }))
            return NativeCompanionWorkerAuthority(resolver: NativeRuleResolver(global: all, conversation: NativeConversationRules(),
                                                                               requestText: request, revision: -1), grantsRevision: -1)
        }
        let (_, closedResult) = try await handedOff(closed)
        try require(closedResult.offer == nil, "The closed fallback with no rules offers nothing")
    }

    private static func leftToYouPredicate() throws {
        let require = NativeTaskFixture.require
        let read = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "", revision: 3)
        var failed = read
        failed.failed = true
        let fallback = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "", revision: -1)
        let offered = NativeRuleWhy(kind: .unsaved, action: .networkSends, handsOff: true, choice: .handOff, source: .settings)
        try require(NativeCompanionWorker.offersAskFirst(offered, rules: read), "A Leave it to me setting offers")
        try require(NativeCompanionWorker.offersAskFirst(NativeRuleWhy(kind: .unsaved, action: .trash, handsOff: true, choice: .handOff, source: .chat), rules: read),
                    "A chat's own Leave it to me offers")
        try require(!NativeCompanionWorker.offersAskFirst(offered, rules: failed), "Unread rules offer nothing")
        try require(!NativeCompanionWorker.offersAskFirst(offered, rules: fallback), "The closed fallback offers nothing")
        for action in [NativeActionClass.credentialEntry, .payments, .permanentDeletion] {
            try require(!NativeCompanionWorker.offersAskFirst(NativeRuleWhy(kind: .unsaved, action: action, handsOff: true, choice: .handOff, source: .settings), rules: read),
                        "\(action.title) is never offered")
            try require(!NativeCompanionWorker.offersAskFirst(NativeRuleWhy(kind: .held, action: action, handsOff: true, item: action.floorItem), rules: read),
                        "A protected step is never offered")
        }
        let record = NativeRuleWhy.Rule(NativeRuleRecord(action: .networkSends, effect: .handOff, statement: "Leave sends to me"))
        let others = [
            NativeRuleWhy(kind: .rule, action: .networkSends, handsOff: true, choice: .handOff, source: .settings, rule: record),
            NativeRuleWhy.folder(.fileEdits, path: "/Volumes/Garden/notes"),
            NativeRuleWhy(kind: .outside, action: .networkSends, handsOff: true, choice: .handOff, source: .settings, rule: record),
            NativeRuleWhy(kind: .unsaved, action: .networkSends, handsOff: true),
            NativeRuleWhy(kind: .unsaved, action: .networkSends, handsOff: true, choice: .ask, source: .settings),
            NativeRuleWhy(kind: .unsaved, action: .networkSends, handsOff: false, choice: .handOff, source: .settings),
            NativeRuleWhy(kind: .unsaved, action: .networkSends, handsOff: true, choice: .handOff),
        ]
        for why in others {
            try require(!NativeCompanionWorker.offersAskFirst(why, rules: read), "Only a stop from a Leave it to me setting offers: \(why.kind)")
        }
    }

    private static func leftToYouReference(_ store: ChatStore, result: NativeResearchTaskResult, state: String = "completed",
                                           workerType: String = "companion") throws -> NativeTaskReference {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any] ?? [:]
        let reference = try OngoingWorkFixture.reference(conversationID: store.veraThreadID ?? "", title: result.query, workerType: workerType,
                                                         state: state, result: object)
        store.nativeTaskReferences.append(reference)
        return reference
    }

    private static func leftToYouAnswers() async throws {
        let require = NativeTaskFixture.require
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("left-to-you-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("chat.sqlite")
        func open(_ rules: NativeRules) throws -> ChatStore {
            let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: try LocalChatRepository(url: url), nativeRules: rules)
            if store.conversations.isEmpty { store.conversations = (try? store.repository?.listConversations()) ?? [] }
            store.ensureVeraThread()
            return store
        }
        func config(fails: Bool = false) -> ConfigStore {
            ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in
                if fails { throw NSError(domain: "SelfTest", code: 1) }
            })
        }
        func ledgerRows(_ store: ChatStore) throws -> Int {
            guard let repository = store.repository as? LocalChatRepository else { return -1 }
            return try repository.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM native_effect_ledger") ?? 0 }
        }
        let harness = try NativeCompanionHarness(rules: [.networkSends: .handOff], script: sendThenReport)
        let (_, handed) = try await handedOff(harness)
        var sends = NativeRules.defaults
        sends.set(.handOff, for: .networkSends)

        let store = try open(sends)
        let kept = try leftToYouReference(store, result: handed)
        let keptID = kept.id.uuidString
        let records = store.ruleRecords.count
        guard let offer = store.leftToYouOffer(cardID: keptID) else { throw NativeTaskFixture.Failure.assertion("A finished report with an offer is found") }
        try require(store.leftToYouStillApplies(offer), "The offer applies while the setting is Leave it to me")
        store.answerLeftToYouOffer(cardID: keptID, answer: .kept, config: config())
        try require(store.leftToYouAnswers[keptID] == .kept && store.nativeRules.choice(for: .networkSends) == .handOff
                    && store.ruleRecords.count == records && (try ledgerRows(store)) == 0,
                    "Keep it this way changes nothing and is remembered")
        try require((try store.ruleOfferStore?.rows(conversationID: store.veraThreadID ?? "")) == 0
                    && (try store.ruleOfferStore?.turnedOff(.networkSends)) == false,
                    "The remembered answer doesn't touch the chat offers")
        store.answerLeftToYouOffer(cardID: keptID, answer: .askFirst, config: config())
        try require(store.leftToYouAnswers[keptID] == .kept && store.nativeRules.choice(for: .networkSends) == .handOff,
                    "A second answer does nothing")
        let relaunched = try open(sends)
        try require(relaunched.leftToYouAnswers[keptID] == .kept, "The answer is still there after a relaunch")

        let asked = try leftToYouReference(store, result: handed)
        let askedID = asked.id.uuidString
        store.answerLeftToYouOffer(cardID: askedID, answer: .askFirst, config: config(fails: true))
        try require(store.leftToYouFailed.contains(askedID) && store.leftToYouAnswers[askedID] == nil
                    && (try store.ruleOfferStore?.leftAnswer(reportID: askedID, action: .networkSends)) == 0
                    && store.leftToYouState(try NativeTaskProjection.display(reference: asked, snapshot: asked.snapshot).card)?.shown == true,
                    "A failed save says so, remembers nothing and keeps the buttons")
        store.answerLeftToYouOffer(cardID: askedID, answer: .askFirst, config: config())
        try require(store.leftToYouAnswers[askedID] == .askFirst && !store.leftToYouFailed.contains(askedID)
                    && store.nativeRules.choice(for: .networkSends) == .ask && (try ledgerRows(store)) == 0,
                    "Ask me first next time changes the setting to Ask first")
        try require(try open(store.nativeRules).leftToYouAnswers[askedID] == .askFirst, "Ask first is remembered after a relaunch")
        let next = try NativeCompanionHarness(rules: [.networkSends: store.nativeRules.choice(for: .networkSends)], script: sendThenReport)
        _ = try next.create()
        let paused = try await next.runUntilSettled()
        let choices = (try? next.decision(paused))?["choices"] as? [String] ?? []
        try require(paused.state == .needsDecision && choices.contains("approve") && choices.contains("decline") && next.service.count("water_bed") == 0,
                    "The next time, the same step asks first")

        let changed = try leftToYouReference(store, result: handed)
        let changedID = changed.id.uuidString
        guard let changedOffer = store.leftToYouOffer(cardID: changedID) else { throw NativeTaskFixture.Failure.assertion("The second report is found") }
        try require(!store.leftToYouStillApplies(changedOffer), "Once the setting changed elsewhere the offer no longer applies")
        store.answerLeftToYouOffer(cardID: changedID, answer: .kept, config: config())
        try require(store.leftToYouAnswers[changedID] == nil && (try store.ruleOfferStore?.leftAnswer(reportID: changedID, action: .networkSends)) == 0,
                    "Answering an offer that no longer applies does nothing")

        let research = try leftToYouReference(store, result: handed, workerType: "research")
        let waiting = try leftToYouReference(store, result: handed, state: "running")
        for id in [UUID().uuidString, research.id.uuidString, waiting.id.uuidString] {
            store.answerLeftToYouOffer(cardID: id, answer: .askFirst, config: config())
            try require(store.leftToYouOffer(cardID: id) == nil && store.leftToYouAnswers[id] == nil,
                        "An offer with no finished companion report behind it does nothing")
        }

        var acting = NativeRules.defaults
        acting.set(.act, for: .networkSends)
        let chatStore = try open(acting)
        guard let threadID = chatStore.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion thread opens") }
        chatStore.tightenConversationRule(.handOff, for: .networkSends, conversationID: threadID)
        let chatHarness = try NativeCompanionHarness(rules: [.networkSends: .act], script: sendThenReport)
        chatHarness.rules.set(NativeConversationRules(choices: [.networkSends: .handOff]), for: chatHarness.thread.current)
        let (_, chatHanded) = try await handedOff(chatHarness)
        let chatReference = try leftToYouReference(chatStore, result: chatHanded)
        chatStore.answerLeftToYouOffer(cardID: chatReference.id.uuidString, answer: .askFirst, config: config(fails: true))
        try require(chatStore.leftToYouAnswers[chatReference.id.uuidString] == .askFirst
                    && chatStore.conversationRules(for: threadID).choices[.networkSends] == .ask
                    && chatStore.nativeRules.choice(for: .networkSends) == .act,
                    "Ask first from a chat choice changes only this chat")
        var cleared = NativeConversationRules(choices: [.networkSends: .handOff])
        cleared.tighten(.ask, for: .networkSends, global: NativeRules(choices: [.networkSends: .ask]))
        try require(cleared.choices[.networkSends] == nil, "When the setting already asks, the chat goes back to the setting")
    }

    private static func leftToYouOldResults() throws {
        let require = NativeTaskFixture.require
        let old: [String: Any] = ["kind": "companion_report", "query": "Water the north bed", "title": "Water the north bed",
                                  "report": "Stopped before this step: Water a bed: north.", "summary": "Stopped before this step.", "sources": [],
                                  "why": ["kind": "unsaved", "action": "network_sends", "handsOff": true, "choice": "hand_off", "source": "settings"]]
        let decoded = try JSONDecoder().decode(NativeResearchTaskResult.self, from: JSONSerialization.data(withJSONObject: old))
        try require(decoded.offer == nil && decoded.why != nil, "An earlier report without an offer still reads")
        let reference = try OngoingWorkFixture.reference(conversationID: "thread", title: "Water the north bed", workerType: "companion",
                                                         state: "completed", result: old)
        let card = try NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot).card
        try require(card.offer == nil && card.needsYou, "An earlier report shows as before with no offer")
        let saved = try JSONEncoder().encode(card)
        var object = try JSONSerialization.jsonObject(with: saved) as? [String: Any] ?? [:]
        object["offer"] = nil
        let reread = try JSONDecoder().decode(NativeTaskCardPresentation.self, from: JSONSerialization.data(withJSONObject: object))
        try require(reread.offer == nil, "A saved card from before still reads")
    }

    private static func leftToYouCopy() throws {
        let require = NativeTaskFixture.require
        let banned = ["grant", "kind", "class", "record", "scope", "origin", "effect", "resolver", "task", "worker", "allow", "vera",
                      "she", "her", "he", "his", "him"]
        for action in NativeActionClass.configurable {
            for line in LeftToYouCopy.strings(action) {
                let words = Set(line.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
                try require(words.isDisjoint(with: banned) && !line.contains("\u{2014}"), "The offer copy reads plainly: \(line)")
            }
            for chat in [false, true] {
                try require(LeftToYouCopy.sentence(action, chat: chat).plain(name: nil).hasPrefix("Your companion "),
                            "With no name the sentence starts with Your companion")
            }
        }
        try require(LeftToYouCopy.asked.plain(name: nil) == "Your companion will ask first next time.", "The answered line names the companion")
        try require(LeftToYouCopy.answers.allowMenu.isEmpty && LeftToYouCopy.answers.declineMenu.isEmpty, "The offer has two buttons and no menus")
    }
}
