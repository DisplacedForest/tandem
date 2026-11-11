import Foundation

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
        try require(state.confirm() == .payments && state.question == nil, "Confirming returns the item and clears the question")
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
}
