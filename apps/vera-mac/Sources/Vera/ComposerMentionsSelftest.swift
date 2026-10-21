import Foundation

@MainActor
extension SelfTest {
    static func runComposerMentions() throws {
        let require = NativeTaskFixture.require
        let catalog = ComposerMentionCatalog(items: [ComposerMentionCatalog.filesItem]
            + ComposerMentionCatalog.builtIns(webAvailable: true, imageAvailable: false)
            + [ComposerMentionCatalog.plugin(name: "Home Assistant", serverID: "a", connected: true, toolIDs: ["mcp-1", "mcp-2"], allowedIDs: ["mcp-1", "mcp-2"]),
               ComposerMentionCatalog.plugin(name: "Slack", serverID: "b", connected: false, toolIDs: [], allowedIDs: []),
               ComposerMentionCatalog.plugin(name: "Home", serverID: "c", connected: true, toolIDs: ["mcp-9"], allowedIDs: ["mcp-9"]),
               ComposerMentionCatalog.plugin(name: "Zoom", serverID: "d", connected: true, toolIDs: ["mcp-5"], allowedIDs: []),
               ComposerMentionCatalog.plugin(name: "search THE web", serverID: "e", connected: true, toolIDs: ["mcp-7"], allowedIDs: ["mcp-7"]),
               ComposerMentionCatalog.plugin(name: "Search the web archive", serverID: "f", connected: true, toolIDs: ["mcp-8"], allowedIDs: [])])

        try require(ComposerMentions.query(in: "@") == ComposerMentionQuery(range: "@".startIndex..<"@".endIndex, text: ""), "A bare @ opens the picker")
        try require(ComposerMentions.query(in: "find @sea")?.text == "sea", "Text after @ is the filter")
        try require(ComposerMentions.query(in: "mail me@example.com") == nil, "An @ inside a word is not a mention")
        try require(ComposerMentions.query(in: "@Search the web\nmore") == nil, "A mention query does not span lines")

        let web = catalog.items.first { $0.id == NativeWebTools.searchToolID }!
        let draft = "please @sea"
        let query = ComposerMentions.query(in: draft)!
        try require(ComposerMentions.insert(web, into: draft, replacing: query) == "please @Search the web ", "Picking replaces the query with the mention")
        try require(ComposerMentions.insert(ComposerMentionCatalog.filesItem, into: "hello @", replacing: ComposerMentions.query(in: "hello @")!) == "hello ", "Picking files removes the @")

        try require(catalog.matching("web").map(\.id) == [NativeWebTools.searchToolID, "plugin-f"], "Filtering matches names")
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
        try require(ComposerMentions.resolve("@Home Assistant lights", catalog: catalog) == ["mcp-1", "mcp-2"], "The longest name wins and shorter names do not also match")
        try require(ComposerMentions.resolve("@Home lights", catalog: catalog) == ["mcp-9"], "A shorter name still matches on its own")
        try require(catalog.items.contains { $0.id == "plugin-e" } == false, "A later item with a duplicate name is dropped")
        try require(catalog.items.first { $0.id == "plugin-d" }?.available == false && catalog.items.first { $0.id == "plugin-d" }?.detail == "Turned off in Settings", "A plugin with its tools off in settings is dimmed and says so")
        try require(ComposerMentions.resolve("@Zoom meeting", catalog: catalog).isEmpty, "A plugin with its tools off grants nothing")
        try require(ComposerMentions.resolve("Explain this:\n> @Deep research tea", catalog: catalog).isEmpty, "Blockquotes are ignored")
        try require(ComposerMentions.resolve("~~~\n@Deep research tea\n~~~", catalog: catalog).isEmpty, "Tilde fences are ignored")
        try require(ComposerMentions.resolve("``@Deep research`` tea", catalog: catalog).isEmpty, "Double backtick spans are ignored")
        try require(ComposerMentions.resolve("`word`@Deep research tea", catalog: catalog).isEmpty, "An @ glued to a code span is not a mention")
        try require(ComposerMentions.resolve("\"@Deep research\" tea", catalog: catalog).isEmpty, "Quoted text is ignored")
        try require(ComposerMentions.resolve("Explain: `` @Search the web ``", catalog: catalog).isEmpty, "Padded double backtick spans are ignored")
        try require(ComposerMentions.resolve("``\n@Search the web\n``", catalog: catalog).isEmpty, "Multiline double backtick spans are ignored")
        try require(ComposerMentions.resolve("``` @Search the web ```", catalog: catalog).isEmpty, "Inline triple backtick spans are ignored")
        try require(ComposerMentions.resolve("`x` @Search the web", catalog: catalog) == [NativeWebTools.searchToolID], "A mention after a closed code span counts")
        try require(ComposerMentions.resolve("@Search the web archive now", catalog: catalog).isEmpty, "A disabled longer name consumes the match instead of falling back to a shorter one")
        try require(ComposerMentions.resolve("@Add photos and files here", catalog: catalog).isEmpty, "The files item grants nothing")
        try require(ComposerMentions.resolve("`` @Deep research ``` x ``", catalog: catalog).isEmpty, "A longer backtick run inside a span does not close it")
        try require(ComposerMentions.resolve("`` some ``` ticks `` @Search the web", catalog: catalog) == [NativeWebTools.searchToolID], "A mention after a span with a longer run inside counts")
        try require(ComposerMentions.resolve("```` example ```` @Search the web", catalog: catalog) == [NativeWebTools.searchToolID], "A mention after a four backtick span counts")
        try require(ComposerMentions.resolve("``` fence\n@Search the web", catalog: catalog).isEmpty, "An unterminated fence swallows the rest")
        try require(ComposerMentions.resolve("`open span\n@Search the web", catalog: catalog) == [NativeWebTools.searchToolID], "An unterminated single backtick only masks its line")
        try require(ComposerMentions.resolve("`open span\r\n@Search the web", catalog: catalog) == [NativeWebTools.searchToolID], "A CRLF line break ends an unterminated single backtick")
        try require(ComposerMentions.resolve("``open span\r\n@Search the web", catalog: catalog) == [NativeWebTools.searchToolID], "A CRLF line break ends an unterminated double backtick")
        try require(!NativeTurnToolAuthority("`example\r\nDo not use tools.").allowsTools, "A prohibition after a CRLF line break still counts")
        try require(ComposerMentions.resolve("ok\n@Deep research tea", catalog: catalog) == [NativeWebTools.researchToolID, NativeTaskTools.toolID], "A mention on its own line counts")

        let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: ConversationTitleStubTransport(.reply("x")),
            repository: try LocalChatRepository(inMemory: true), artifactPersistenceEnabled: false)
        try require(store.turnToolIDs(for: "what is new in Swift").isEmpty, "Without consent or mentions a turn has no tools")
        try require(store.turnToolIDs(for: "@Search the web what is new in Swift") == [NativeWebTools.searchToolID], "A mention adds its tool to the turn even when it is off in settings")
        try require(store.turnToolIDs(for: "@Deep research Swift") == [NativeWebTools.researchToolID, NativeTaskTools.toolID], "A research mention authorizes research for the turn")
        try require(store.turnToolIDs(for: "no tools please @Search the web Swift").isEmpty, "A no-tools instruction still wins over a mention")

        let plain = NativeTurnToolAuthority("tell me about tea")
        try require(!plain.allowsResearch, "Plain text does not authorize research")
        let mentioned = NativeTurnToolAuthority("@Deep research tea", mentions: [NativeWebTools.researchToolID])
        try require(mentioned.allowsResearch, "A research mention authorizes research")
        try require(mentioned.filter([NativeWebTools.researchToolID, NativeTaskTools.toolID]) == [NativeWebTools.researchToolID, NativeTaskTools.toolID], "Research tools pass the filter when mentioned")
        let refused = NativeTurnToolAuthority("do not use tools @Deep research tea", mentions: [NativeWebTools.researchToolID])
        try require(refused.filter([NativeWebTools.researchToolID]).isEmpty, "An explicit no-tools instruction still wins")
    }
}
