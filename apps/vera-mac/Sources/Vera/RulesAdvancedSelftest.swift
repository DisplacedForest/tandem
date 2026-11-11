import AppKit
import Foundation
import SwiftUI

@MainActor
extension SelfTest {
    static func runRulesAdvanced() async throws {
        let require = NativeTaskFixture.require

        var state = RulesAdvancedState()
        try require(!state.isOpen && state.question == nil, "Advanced starts closed with no question")
        state.ask(.payments)
        try require(state.question == nil, "Nothing can be offered while Advanced is closed")
        state.askToOpen()
        try require(state.question == .open, "Opening Advanced asks first")
        state.cancel()
        try require(!state.isOpen && state.question == nil, "Cancelling the open question leaves Advanced closed")
        state.askToOpen()
        try require(state.confirm() == nil && state.isOpen && state.question == nil, "Confirming the open question opens Advanced")
        state.askToOpen()
        try require(state.question == nil, "Opening an open Advanced does nothing")
        state.ask(.ruleChanges)
        try require(state.question == nil, "Loosening a rule because a message said to is never offered")
        state.ask(.payments)
        state.cancel()
        try require(state.question == nil, "Cancelling a question leaves none")
        state.ask(.payments)
        try require(state.confirm() == .allow(.payments) && state.question == nil, "Confirming returns the item and clears the question")
        state.ask(.payments)
        state.leave()
        try require(!state.isOpen && state.question == nil, "Leaving closes Advanced and clears a pending question")
        state.ask(.payments)
        try require(state.confirm() == nil, "Nothing is confirmed after leaving")

        let defaults = NativeRules.defaults
        let liftable: [NativeFloorItem] = [.credentialEntry, .payments, .permanentDeletion]
        try require(RulesAdvancedCopy.allowed(defaults).isEmpty, "Nothing is allowed by default")
        try require(RulesAdvancedCopy.offered(defaults) == liftable, "The three liftable items are offered in order")
        try require(RulesAdvancedCopy.leftToYou(defaults) == NativeFloorItem.allCases, "Everything is left to you by default")
        var rules = defaults
        rules.lift(.payments)
        try require(RulesAdvancedCopy.allowed(rules) == [.payments], "A lifted item is listed as allowed")
        try require(!RulesAdvancedCopy.offered(rules).contains(.payments), "A lifted item is no longer offered")
        try require(!RulesAdvancedCopy.leftToYou(rules).contains(.payments) && RulesAdvancedCopy.leftToYou(rules).contains(.ruleChanges),
                    "A lifted item leaves the left-to-you list but rule changes stay")
        try require(RulesAdvancedCopy.follows(.payments, rules: rules) == "Ask first", "A default lift asks first")
        var everything = defaults
        for item in liftable { everything.lift(item) }
        try require(RulesAdvancedCopy.leftToYou(everything) == [.ruleChanges], "Only rule changes stay with you when everything is lifted")
        rules.lift(.payments, choice: .act)
        try require(RulesAdvancedCopy.follows(.payments, rules: rules) == "Do it without asking", "A stored wider choice is shown truthfully")

        let disk = CompanionAppearanceFixtureDisk()
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents },
                                 nativeMCP: NativeMCPManager(servers: []),
                                 writeConfiguration: { disk.contents = $0; disk.writes += 1 })
        let store = ChatStore()
        let start = store.rulesRevision
        config.letThrough(.payments, store: store)
        try require(config.nativeSettings.rules.isLifted(.payments) && config.nativeSettings.rules.choice(for: .payments) == .ask,
                    "Letting a payment through lifts it to ask first")
        try require(store.nativeRules == config.nativeSettings.rules, "The chat store sees the change at once")
        let afterLift = store.rulesRevision
        try require(afterLift != start, "The rule source revision changes after a lift")
        let reopened = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents },
                                   nativeMCP: NativeMCPManager(servers: []), writeConfiguration: { _ in })
        try require(reopened.nativeSettings.rules.isLifted(.payments), "A lifted item survives a relaunch")
        let before = config.nativeSettings.rules
        config.letThrough(.ruleChanges, store: store)
        try require(config.nativeSettings.rules == before && store.rulesRevision == afterLift, "Rule changes can never be let through")
        config.applyRule(.act, for: .payments, store: store)
        config.letThrough(.payments, store: store)
        try require(config.nativeSettings.rules.choice(for: .payments) == .act, "Letting through again does not reset a wider choice")
        let beforeLeave = store.rulesRevision
        config.leaveToMe(.payments, store: store)
        try require(config.nativeSettings.rules.holds(.payments) && store.nativeRules.holds(.payments), "Leaving it to you holds payments again everywhere")
        try require(store.rulesRevision != beforeLeave, "The rule source revision changes after leaving it to you")
        let relocked = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents },
                                   nativeMCP: NativeMCPManager(servers: []), writeConfiguration: { _ in })
        try require(relocked.nativeSettings.rules.holds(.payments), "Leaving it to you survives a relaunch")
        struct Unwritable: Error {}
        let failing = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] },
                                  nativeMCP: NativeMCPManager(servers: []), writeConfiguration: { _ in throw Unwritable() })
        let other = ChatStore()
        failing.letThrough(.credentialEntry, store: other)
        try require(other.nativeRules.isLifted(.credentialEntry) && other.rulesNotice != nil, "A change that can't be saved still applies now and says so")
        failing.leaveToMe(.credentialEntry, store: other)
        try require(other.nativeRules.holds(.credentialEntry) && other.rulesNotice != nil, "Putting it back applies now even when it can't be saved")

        let banned = ["floor", "lift", "lifted", "unlock", "grant", "kind", "class", "record", "scope", "effect", "revoke"]
        for name in [Optional("Ada"), nil] {
            for text in RulesAdvancedCopy.screenStrings(name: name) {
                for fragment in ["Ver" + "a", "Tandem", "{name}", " her ", " she "] {
                    try require(!text.contains(fragment), "Advanced copy never contains \(fragment): \(text)")
                }
                let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
                for word in banned {
                    try require(!words.contains(word), "Advanced copy never says \(word): \(text)")
                }
            }
        }
        try require(CompanionSentence.plain(RulesAdvancedCopy.allowTemplate, name: nil) == "Let your companion do this", "The unnamed allow button")
        try require(CompanionSentence.plain(RulesAdvancedCopy.allowTemplate, name: "Ada") == "Let Ada do this", "The named allow button")
        try require(RulesAdvancedCopy.question(.allow(.payments), name: "Ada") == "Let Ada pay or transfer money?", "The payments question")
        try require(RulesAdvancedCopy.detail(.allow(.payments), name: "Ada") == "Money that has left can't be called back.", "The payments detail")

        print("  rules advanced OK (state, lists, store, copy)")
    }

    static func runRulesAdvancedChoices() async throws {
        let require = NativeTaskFixture.require
        let liftable: [NativeFloorItem] = [.credentialEntry, .payments, .permanentDeletion]

        var closed = RulesAdvancedState()
        try require(!closed.choose(.ask, for: .payments) && closed.question == nil, "Choosing while Advanced is closed does nothing")
        try require(!closed.choose(.act, for: .payments) && closed.question == nil, "Choosing without asking while closed sets no question")
        var state = RulesAdvancedState()
        state.askToOpen()
        _ = state.confirm()
        try require(state.isOpen, "Advanced is open for the choice checks")
        for choice in [NativeRuleChoice.ask, .actIfPreapproved, .handOff] {
            try require(state.choose(choice, for: .payments) && state.question == nil, "Choosing \(choice.rawValue) applies at once with no question")
        }
        try require(!state.choose(.act, for: .payments) && state.question == .withoutAsking(.payments), "Choosing to do it without asking asks once more")
        state.cancel()
        try require(state.question == nil && state.isOpen, "Cancelling the second question leaves none and Advanced open")
        _ = state.choose(.act, for: .payments)
        try require(state.confirm() == .withoutAsking(.payments) && state.question == nil, "Confirming returns the choice to do it without asking")
        try require(!state.choose(.act, for: .ruleChanges) && state.question == nil, "Rule changes can never be set to act")
        _ = state.choose(.act, for: .payments)
        state.leave()
        try require(state.confirm() == nil && !state.isOpen, "Nothing is confirmed after leaving")

        for name in [Optional("Ada"), nil] {
            let prefix = name.map { "Let \($0) " } ?? "Let your companion "
            try require(RulesAdvancedCopy.question(.withoutAsking(.payments), name: name).hasPrefix(prefix), "The second question starts with the companion")
            try require(RulesAdvancedCopy.confirm(.withoutAsking(.payments), name: name) == "Do it without asking", "The second confirm title")
            for item in liftable {
                try require(RulesAdvancedCopy.detail(.withoutAsking(item), name: name) == item.reason, "The second question's detail is the item's reason")
            }
        }
        try require(RulesAdvancedCopy.question(.withoutAsking(.payments), name: "Ada") == "Let Ada pay or transfer money without asking?", "The second payments question")
        try require(RulesAdvancedCopy.screenStrings(name: "Ada").contains("Do it without asking"), "The copy audit covers the second question")

        func configured() -> (ConfigStore, ChatStore, CompanionAppearanceFixtureDisk) {
            let disk = CompanionAppearanceFixtureDisk()
            let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents },
                                     nativeMCP: NativeMCPManager(servers: []),
                                     writeConfiguration: { disk.contents = $0; disk.writes += 1 })
            return (config, ChatStore(), disk)
        }
        func reopened(_ disk: CompanionAppearanceFixtureDisk) -> ConfigStore {
            ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents },
                        nativeMCP: NativeMCPManager(servers: []), writeConfiguration: { _ in })
        }

        let (config, store, disk) = configured()
        let untouched = config.nativeSettings.rules
        let startRevision = store.rulesRevision
        config.setChoice(.act, for: .payments, store: store)
        try require(config.nativeSettings.rules == untouched && store.rulesRevision == startRevision, "Choosing for an item that is not on changes nothing")
        config.letThrough(.payments, store: store)
        let lifted = store.rulesRevision
        config.setChoice(.act, for: .payments, store: store)
        try require(config.nativeSettings.rules.choice(for: .payments) == .act && store.nativeRules.choice(for: .payments) == .act, "Choosing to act applies in settings and chat at once")
        try require(store.rulesRevision != lifted, "Changing the choice moves the revision")
        try require(reopened(disk).nativeSettings.rules.choice(for: .payments) == .act && reopened(disk).nativeSettings.rules.isLifted(.payments), "The choice survives a relaunch")
        let acted = store.rulesRevision
        config.setChoice(.act, for: .payments, store: store)
        try require(store.rulesRevision == acted, "Choosing the same thing again does not move the revision")
        config.setChoice(.actIfPreapproved, for: .payments, store: store)
        try require(config.nativeSettings.rules.choice(for: .payments) == .actIfPreapproved && store.rulesRevision != acted, "Choosing to act if approved works")
        let beforeBack = store.rulesRevision
        config.setChoice(.handOff, for: .payments, store: store)
        try require(config.nativeSettings.rules.holds(.payments) && !config.nativeSettings.rules.isLifted(.payments) && store.nativeRules.holds(.payments)
                    && store.rulesRevision != beforeBack, "Choosing to leave it to you puts the item back")
        try require(reopened(disk).nativeSettings.rules.holds(.payments), "Putting it back survives a relaunch")
        config.letThrough(.payments, store: store)
        try require(config.nativeSettings.rules.choice(for: .payments) == .ask, "Turning it on again starts at ask first")
        let beforeRule = config.nativeSettings.rules
        let ruleRevision = store.rulesRevision
        config.setChoice(.act, for: .ruleChanges, store: store)
        try require(config.nativeSettings.rules == beforeRule && store.rulesRevision == ruleRevision, "Rule changes can never be set to act")

        let chat = "advanced-choices"
        let calls = NativeChatRulesCounter()
        func payment(_ item: NativeFloorItem, confirmation: NativeToolConfirmation = .none) -> NativeToolDefinition {
            NativeToolDefinition(id: "fixture-" + item.rawValue, name: "fixture_" + item.rawValue, title: item.title, description: "Fixture",
                                 parameters: .object(["type": .string("object")]), confirmation: confirmation, effect: .write,
                                 action: item.actionClass, isAvailable: { true },
                                 execute: { _ in calls.hit(); return .object(["ok": .bool(true)]) })
        }
        func run(_ definition: NativeToolDefinition, confirmed: Bool) async -> String? {
            do {
                _ = try await NativeToolCallContext.$confirmed.withValue(confirmed) { try await definition.execute([:]) }
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        for item in liftable {
            guard let action = item.actionClass else { throw NativeTaskFixture.Failure.assertion("\(item.rawValue) has a class") }
            let (cfg, chatStore, _) = configured()
            func admission() -> NativeRuleDecision {
                chatStore.nativeRuleSource.resolver(for: chat, requestText: "").decision(for: action)
            }
            let live = ChatStore.ruled(payment(item), rules: chatStore.nativeRuleSource, store: nil, conversationID: chat, requestText: "")
            let offBefore = chatStore.nativeRuleSource.resolver(for: chat, requestText: "")
            try require(admission() == .handOff && live.confirmationFor?([:]) == false, "\(item.rawValue) hands off when it is not on")
            let before = calls.count
            let held = RefusalCopy.forModel(NativeRuleWhy(kind: .held, action: action, handsOff: true, item: item))
            try require(await run(live, confirmed: true) == held && calls.count == before, "\(item.rawValue) does not run when it is not on")

            cfg.letThrough(item, store: chatStore)
            try require(admission() == .ask && live.confirmationFor?([:]) == true, "\(item.rawValue) asks when on with ask first")
            let onAsk = chatStore.nativeRuleSource.resolver(for: chat, requestText: "")
            try require(onAsk.revision != offBefore.revision, "Turning \(item.rawValue) on changes the rules revision")
            try require(await run(live, confirmed: false) == NativeRuleResolver.changedMessage && calls.count == before, "\(item.rawValue) does not run unconfirmed when it asks")

            cfg.setChoice(.act, for: item, store: chatStore)
            try require(admission() == .act(.rule) && live.confirmationFor?([:]) == false, "\(item.rawValue) acts at admission when set to act")
            let onAct = chatStore.nativeRuleSource.resolver(for: chat, requestText: "")
            try require(onAct.revision != onAsk.revision && onAsk.decision(for: action) == .ask && onAct.decision(for: action) == .act(.rule),
                        "A resolver taken before the choice changed keeps its own revision and decision for \(item.rawValue)")
            try require(await run(live, confirmed: false) == nil && calls.count == before + 1, "\(item.rawValue) runs at execution when set to act")

            cfg.leaveToMe(item, store: chatStore)
            try require(admission() == .handOff && chatStore.nativeRuleSource.resolver(for: chat, requestText: "").revision != onAct.revision,
                        "\(item.rawValue) hands off again after it is put back")
            try require(onAct.decision(for: action) == .act(.rule), "A resolver taken while it acted still says act, so work admitted then is stale by revision")
            try require(await run(live, confirmed: true) == held && calls.count == before + 1,
                        "A tool set up while \(item.rawValue) acted refuses at execution after it is put back")

            cfg.letThrough(item, store: chatStore)
            cfg.setChoice(.act, for: item, store: chatStore)
            let demanding = ChatStore.ruled(payment(item, confirmation: .required), rules: chatStore.nativeRuleSource, store: nil, conversationID: chat, requestText: "")
            try require(demanding.alwaysAsks && demanding.confirmationFor?([:]) == true, "A chat tool that always asks still asks for \(item.rawValue) when set to act")
            let background = NativeToolDefinition(id: "fixture-bg-" + item.rawValue, name: "fixture_bg", title: item.title, description: "Fixture",
                                                  parameters: .object(["type": .string("object")]), confirmation: .required, effect: .write,
                                                  action: action, isAvailable: { true }, execute: { _ in .null })
            let resolver = chatStore.nativeRuleSource.resolver(for: chat, requestText: "")
            let background1 = NativeCompanionWorker.ruleDecision(background, [:], resolver: resolver, honoringLimitedUse: true)
            try require(background.demandsConfirmation && background1.action == action && background1.decision == .ask && background1.authorizedBy.isEmpty,
                        "Background work asks for an always-confirm tool on \(item.rawValue) set to act")
            let relaxed = NativeToolDefinition(id: "fixture-bg-" + item.rawValue, name: "fixture_bg", title: item.title, description: "Fixture",
                                               parameters: .object(["type": .string("object")]), confirmation: .none, effect: .write,
                                               action: action, isAvailable: { true }, execute: { _ in .null })
            let relaxedDecision = NativeCompanionWorker.ruleDecision(relaxed, [:], resolver: resolver, honoringLimitedUse: true)
            try require(relaxedDecision.decision == .act(.rule), "The same background tool without the demand acts for \(item.rawValue)")
            cfg.leaveToMe(item, store: chatStore)
            let fresh = chatStore.nativeRuleSource.resolver(for: chat, requestText: "")
            try require(NativeCompanionWorker.ruleDecision(relaxed, [:], resolver: fresh, honoringLimitedUse: true).decision == .handOff,
                        "A fresh background decision hands off \(item.rawValue) after it is put back")
        }

        func destructive(_ rules: NativeRules) -> (NativeActionClass, NativeRuleDecision) {
            let resolver = NativeRuleResolver(global: rules, conversation: NativeConversationRules(), requestText: "")
            let (action, decision, _) = NativeCommandTools.evaluate(command: "rm -rf /Volumes/Other/x", directory: "/Volumes/Granted", grants: [], fallback: .handOff,
                                                                    live: { command, action in action == .commands ? resolver.decision(forCommand: command) : resolver.decision(for: action) },
                                                                    liveTargets: nil)
            return (action, decision)
        }
        var deletion = NativeRules.defaults
        try require(destructive(deletion) == (.permanentDeletion, .handOff), "A destructive command outside a granted folder hands off while permanent deletion is not on")
        deletion.lift(.permanentDeletion)
        try require(destructive(deletion) == (.permanentDeletion, .ask), "It asks once permanent deletion is on")
        deletion.set(.act, for: .permanentDeletion)
        try require(destructive(deletion) == (.permanentDeletion, .act(.rule)), "It acts when permanent deletion is set to act")
        deletion.restore(.permanentDeletion)
        try require(destructive(deletion) == (.permanentDeletion, .handOff), "It hands off again after it is put back")

        final class Answers { var cancelled = 0; var confirmed = 0 }
        let answers = Answers()
        let sheet = NSHostingView(rootView: RulesAdvancedQuestionView(question: .withoutAsking(.payments),
                                                                    onCancel: { answers.cancelled += 1 }, onConfirm: { answers.confirmed += 1 })
            .environment(\.companionName, "Ada"))
        sheet.frame = NSRect(x: 0, y: 0, width: 360, height: 160)
        let window = NSWindow(contentRect: sheet.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = sheet
        sheet.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        func press(_ characters: String, code: UInt16) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return false }
            return window.performKeyEquivalent(with: event)
        }
        _ = press("\u{1b}", code: 53)
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(answers.cancelled == 1 && answers.confirmed == 0, "Escape answers the question with Cancel: \(answers.cancelled) \(answers.confirmed)")
        _ = press("\r", code: 36)
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(answers.cancelled == 1 && answers.confirmed == 1, "Return gives the filled answer: \(answers.cancelled) \(answers.confirmed)")
        let (keptConfig, keptStore, _) = configured()
        keptConfig.letThrough(.payments, store: keptStore)
        var asking = RulesAdvancedState()
        asking.askToOpen()
        _ = asking.confirm()
        let keptRevision = keptStore.rulesRevision
        if asking.choose(.act, for: .payments) { keptConfig.setChoice(.act, for: .payments, store: keptStore) }
        asking.cancel()
        try require(keptConfig.nativeSettings.rules.choice(for: .payments) == .ask && keptStore.rulesRevision == keptRevision && asking.confirm() == nil,
                    "Cancel leaves the stored choice untouched")

        print("  rules advanced choices OK (state, copy, store, engine, always-confirm, sheet keys)")
    }
}
