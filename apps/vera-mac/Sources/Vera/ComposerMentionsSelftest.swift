import Foundation

@MainActor
extension SelfTest {
    static func runComposerMentions() throws {
        let require = NativeTaskFixture.require
        let catalog = ComposerMentionCatalog(items: [ComposerMentionCatalog.filesItem]
            + ComposerMentionCatalog.builtIns(webAvailable: true, imageAvailable: false)
            + [ComposerMentionCatalog.plugin(name: "Home Assistant", serverID: "a", connected: true, toolIDs: ["mcp-1", "mcp-2"]),
               ComposerMentionCatalog.plugin(name: "Slack", serverID: "b", connected: false, toolIDs: [])])

        try require(ComposerMentions.query(in: "@") == ComposerMentionQuery(range: "@".startIndex..<"@".endIndex, text: ""), "A bare @ opens the picker")
        try require(ComposerMentions.query(in: "find @sea")?.text == "sea", "Text after @ is the filter")
        try require(ComposerMentions.query(in: "mail me@example.com") == nil, "An @ inside a word is not a mention")
        try require(ComposerMentions.query(in: "@Search the web\nmore") == nil, "A mention query does not span lines")

        let web = catalog.items.first { $0.id == NativeWebTools.searchToolID }!
        let draft = "please @sea"
        let query = ComposerMentions.query(in: draft)!
        try require(ComposerMentions.insert(web, into: draft, replacing: query) == "please @Search the web ", "Picking replaces the query with the mention")
        try require(ComposerMentions.insert(ComposerMentionCatalog.filesItem, into: "hello @", replacing: ComposerMentions.query(in: "hello @")!) == "hello ", "Picking files removes the @")

        try require(catalog.matching("web").map(\.id) == [NativeWebTools.searchToolID], "Filtering matches names")
        try require(catalog.matching("background").map(\.id) == [NativeWebTools.researchToolID], "Filtering matches details")
        try require(catalog.sections("").map(\.0) == [.add, .tools, .plugins], "Sections appear in order")
        try require(catalog.items.first { $0.id == "plugin-b" }?.available == false, "A disconnected plugin is dimmed")
        try require(catalog.items.first { $0.id == NativeImageTools.toolID }?.available == false, "An unconfigured tool is dimmed")

        try require(ComposerMentions.resolve("@Search the web what is new", catalog: catalog) == [NativeWebTools.searchToolID], "A mention resolves to its tool")
        try require(ComposerMentions.resolve("@search THE Web please", catalog: catalog) == [NativeWebTools.searchToolID], "Mentions are case-insensitive")
        try require(ComposerMentions.resolve("use @Home Assistant to dim the lights", catalog: catalog) == ["mcp-1", "mcp-2"], "A plugin mention includes every tool of that server")
        try require(ComposerMentions.resolve("@Deep research the history of tea", catalog: catalog) == [NativeWebTools.researchToolID, NativeTaskTools.toolID], "Deep research includes the handoff tool")
        try require(ComposerMentions.resolve("@Nobody knows", catalog: catalog).isEmpty, "Unknown names resolve to nothing")
        try require(ComposerMentions.resolve("`@Search the web` is literal", catalog: catalog).isEmpty, "Code spans are ignored")
        try require(ComposerMentions.resolve("email@Search the web", catalog: catalog).isEmpty, "An @ glued to a word is not a mention")
        try require(ComposerMentions.resolve("@Search the webs", catalog: catalog).isEmpty, "A longer word does not match a shorter name")
        try require(ComposerMentions.resolve("@Search the web, now", catalog: catalog) == [NativeWebTools.searchToolID], "Punctuation after a mention is fine")

        let plain = NativeTurnToolAuthority("tell me about tea")
        try require(!plain.allowsResearch, "Plain text does not authorize research")
        let mentioned = NativeTurnToolAuthority("@Deep research tea", mentions: [NativeWebTools.researchToolID])
        try require(mentioned.allowsResearch, "A research mention authorizes research")
        try require(mentioned.filter([NativeWebTools.researchToolID, NativeTaskTools.toolID]) == [NativeWebTools.researchToolID, NativeTaskTools.toolID], "Research tools pass the filter when mentioned")
        let refused = NativeTurnToolAuthority("do not use tools @Deep research tea", mentions: [NativeWebTools.researchToolID])
        try require(refused.filter([NativeWebTools.researchToolID]).isEmpty, "An explicit no-tools instruction still wins")
    }
}
