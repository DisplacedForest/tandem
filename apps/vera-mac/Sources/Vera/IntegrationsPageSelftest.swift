import Foundation

@MainActor
enum IntegrationsPageSelftest {
    static func run() async throws {
        let require = NativeTaskFixture.require
        try sections(require)
        try rows(require)
        try await actions(require)
        try copy(require)
        print("INTEGRATIONS PAGE SELFTEST OK")
    }

    private static func sections(_ require: (Bool, String) throws -> Void) throws {
        let mixed = """
        {"entries": [
          {"id": "a", "name": "Tides", "publisher": "Harbor", "description": "When the water turns.", "category": "Weather and tides", "url": "https://a.example.com/mcp", "authentication": "none", "source_url": "https://example.com/a"},
          {"id": "b", "name": "Shelf", "publisher": "Example", "description": "Books.", "category": "Archive", "url": "https://b.example.com/mcp", "authentication": "none", "source_url": "https://example.com/b"},
          {"id": "c", "name": "Wind", "publisher": "Example", "description": "Gusts.", "category": "Weather and tides", "url": "https://c.example.com/mcp", "authentication": "none", "source_url": "https://example.com/c"}
        ]}
        """
        let catalog = try NativeMCPStarterCatalog.load(Data(mixed.utf8))
        let sections = IntegrationsPageModel.sections(catalog.entries)
        try require(sections.map(\.title) == ["Weather and tides", "Archive"], "Sections follow the order of the list, for categories the code never named")
        try require(sections.map { $0.entries.map(\.id) } == [["a", "c"], ["b"]], "Each section holds its own entries, and one entry makes a section")
        try require(IntegrationsPageModel.sections(catalog.matching(query: "HARBOR", category: nil)).flatMap { $0.entries.map(\.id) } == ["a"], "Public search reads the publisher")
        try require(IntegrationsPageModel.sections(catalog.matching(query: "no such thing", category: nil)).isEmpty, "A search with no match leaves no sections")
        let bundled = try NativeMCPStarterCatalog.bundled()
        try require(IntegrationsPageModel.sections(bundled.entries).flatMap(\.entries).count == bundled.entries.count, "Every listed plugin is in a section")
        let atMinimum = 920 - VeraSidebar.expandedWidth - 64
        try require(IntegrationsPageModel.columns(for: atMinimum) == 1, "The grid is one column at the smallest window")
        try require(IntegrationsPageModel.columns(for: IntegrationsPageModel.contentWidth) == 2, "The grid is two columns at full width")
    }

    private static func rows(_ require: (Bool, String) throws -> Void) throws {
        let seed = IntegrationsShotFixture.store(variant: "integrations-states")
        let manager = seed.config.nativeMCP
        let entries = try NativeMCPStarterCatalog.bundled().entries
        guard let code = manager.servers.first(where: { $0.id == IntegrationsShotFixture.codeID }),
              let own = manager.servers.first(where: { $0.id == IntegrationsShotFixture.wikiID }),
              let off = manager.servers.first(where: { $0.id == IntegrationsShotFixture.reportsID }) else {
            throw NativeToolError.failed("The fixture services are missing")
        }
        guard let listed = IntegrationsPageModel.entry(for: code, in: entries) else { throw NativeToolError.failed("The installed entry is missing") }
        try require(IntegrationsPageModel.trailing(listed, in: manager.servers) == .menu, "An installed entry shows three dots")
        try require(entries.filter { $0.id != listed.id }.allSatisfy { IntegrationsPageModel.trailing($0, in: manager.servers) == .install }, "An entry that isn't installed shows a plus")
        try require(IntegrationsPageModel.entry(for: own, in: entries) == nil, "A service the person added has no listing")
        try require(manager.shownState(code) == "Reconnecting" && manager.shownState(off) == "Not connected" && manager.shownState(own) == "Connected", "Each row knows its state")
        try require(IntegrationsPageModel.line(code, state: "Reconnecting", entry: listed) == "Reconnecting", "A row that isn't connected shows its state instead of its description")
        let locked = NativeMCPServerConfiguration.load(["native_mcp_servers": [IntegrationsShotFixture.codeRow.merging(["url": "https://api.githubcopilot.com", "address_saved": true]) { $1 }]]).0
        try require(locked.first.map { IntegrationsPageModel.trailing(listed, in: [NativeMCPServerState(configuration: $0)]) } == .menu, "A service whose address is locked still counts as installed")
        var connected = code
        connected.connected = true
        try require(IntegrationsPageModel.line(connected, state: "Connected", entry: listed) == listed.description, "A connected row shows its description")
        try require(IntegrationsPageModel.line(own, state: "Connected", entry: nil) == "Connected", "A connected row with no description shows its state")
        func found(_ query: String) -> [String] { IntegrationsPageModel.matching(manager.servers, entries: entries, query: query).map(\.id) }
        try require(found("").count == 3 && found("deepwiki") == [own.id] && found("COGNITION") == [own.id], "Personal search reads the name and the publisher")
        try require(found("pull requests") == [code.id] && found("no such thing").isEmpty, "Personal search reads the description")
    }

    private static func actions(_ require: (Bool, String) throws -> Void) async throws {
        typealias Connection = IntegrationsPageModel.Connection
        try require(IntegrationsPageModel.menu(Connection(authentication: .bearer)) == [.manage, .connect, .remove], "A service that isn't connected offers Connect")
        try require(IntegrationsPageModel.menu(Connection(authentication: .oauth)) == [.manage, .signIn, .remove], "An account service offers Sign in")
        try require(Connection(authentication: .none, connected: true).action == .disconnect, "A connected service offers Disconnect")
        try require(Connection(authentication: .bearer, reconnecting: true, kept: true).action == .disconnect, "A reconnecting service offers Disconnect")
        try require(Connection(authentication: .bearer, connecting: true).action == .cancel, "A first connection can be canceled")
        try require(Connection(authentication: .oauth, signingIn: true).action == .cancel, "A sign-in can be canceled")
        let seed = IntegrationsShotFixture.store(variant: "integrations-states")
        let manager = seed.config.nativeMCP
        try require(!manager.asksForToken(IntegrationsShotFixture.codeID) && !manager.asksForToken(IntegrationsShotFixture.wikiID), "A saved token or no token connects at once")
        let bare = IntegrationsShotFixture.store(variant: "integrations").config.nativeMCP
        try require(bare.asksForToken(IntegrationsShotFixture.codeID), "Without a saved token Connect asks for one first")
        manager.endConnection(IntegrationsShotFixture.wikiID)
        for _ in 0..<200 where manager.servers.first(where: { $0.id == IntegrationsShotFixture.wikiID })?.connected == true { await Task.yield() }
        try await NativeSessionFixture.eventually("Disconnect from the menu disconnects") {
            manager.refresh()
            return manager.servers.first { $0.id == IntegrationsShotFixture.wikiID }?.connected == false
        }
        try seed.config.removeNativeMCPServer(id: IntegrationsShotFixture.wikiID)
        try require(!seed.config.nativeMCPServerRows.contains { ($0["id"] as? String)?.lowercased() == IntegrationsShotFixture.wikiID }, "Remove takes the service out of the person's services")
    }

    private static func copy(_ require: (Bool, String) throws -> Void) throws {
        let named = CompanionSentence.plain(IntegrationsPageModel.subtitle, name: "Wren")
        let unnamed = CompanionSentence.plain(IntegrationsPageModel.subtitle, name: nil)
        try require(named.contains("Wren") && unnamed.contains(CompanionSentence.unnamedSubject), "The line under the title names the companion")
        let shown = [named, unnamed, IntegrationsPageModel.noMatch, IntegrationsPageModel.emptyTitle, IntegrationsPageModel.emptyDetail, IntegrationsText.removeQuestion("Example")]
            + IntegrationsPageModel.MenuAction.allCases.map(\.title) + IntegrationsTab.allCases.map(\.title)
        let banned = ["ver" + "a", "task", "background", "worker", "agent", "she", "her", "he", "him", "his", "\u{2014}"]
        for text in shown {
            let words = Set(text.lowercased().split { !$0.isLetter && $0 != "\u{2014}" }.map(String.init))
            try require(words.isDisjoint(with: banned), "The page's copy stays plain: \(text)")
        }
    }
}
