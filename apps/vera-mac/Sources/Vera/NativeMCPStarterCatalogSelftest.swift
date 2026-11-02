import Foundation

enum NativeMCPStarterCatalogSelftest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func run() throws {
        let catalog = try NativeMCPStarterCatalog.bundled()
        try check(catalog.entries.count == 10, "bundled catalogue should list ten entries, found \(catalog.entries.count)")
        try check(catalog.skipped.isEmpty, "bundled catalogue skipped \(catalog.skipped)")
        try check(Set(catalog.entries.map(\.id)).count == 10, "bundled ids should be unique")
        try check(catalog.categories == catalog.categories.sorted() && Set(catalog.categories).count == catalog.categories.count, "categories should be sorted and distinct")
        try check(catalog.categories.count == 6, "bundled catalogue should span six categories")
        try check(catalog.entries.allSatisfy { $0.url.scheme == "https" && $0.sourceURL.scheme == "https" }, "every bundled address should be https")

        try check(catalog.matching(query: "", category: nil).count == 10, "empty query should match everything")
        try check(catalog.matching(query: "upstash", category: nil).map(\.id) == ["context7"], "publisher search should find Context7")
        try check(catalog.matching(query: "SPACES", category: nil).map(\.id) == ["hugging-face"], "description search should be case insensitive")
        let documentation = catalog.matching(query: "", category: "Documentation")
        try check(documentation.count == 5 && documentation.allSatisfy { $0.category == "Documentation" }, "category filter should keep only documentation entries")
        try check(catalog.matching(query: "github", category: "Code hosting").map(\.id) == ["github"], "query and category should combine")
        try check(catalog.matching(query: "nothing like this", category: nil).isEmpty, "unmatched query should return nothing")

        let mixed = """
        {"entries": [
          {"id": "good", "name": "Good", "publisher": "Example", "description": "Fine.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "none", "read_tools": ["search"], "source_url": "https://example.com/docs"},
          {"id": "plain", "name": "Plain", "publisher": "Example", "description": "Insecure.", "category": "Documentation", "url": "http://mcp.example.com/mcp", "authentication": "none", "read_tools": ["search"], "source_url": "https://example.com/docs"},
          {"id": "empty", "name": "Empty", "publisher": "Example", "description": "No tools.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "none", "read_tools": [], "source_url": "https://example.com/docs"},
          {"id": "good", "name": "Twin", "publisher": "Example", "description": "Duplicate.", "category": "Documentation", "url": "https://twin.example.com/mcp", "authentication": "none", "read_tools": ["search"], "source_url": "https://example.com/docs"},
          {"id": "query", "name": "Query", "publisher": "Example", "description": "Query string.", "category": "Documentation", "url": "https://mcp.example.com/mcp?key=1", "authentication": "none", "read_tools": ["search"], "source_url": "https://example.com/docs"},
          {"id": "auth", "name": "Auth", "publisher": "Example", "description": "Unknown sign-in.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "password", "read_tools": ["search"], "source_url": "https://example.com/docs"},
          {"id": "control", "name": "Control", "publisher": "Example", "description": "Control character.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "none", "read_tools": ["bad\\u0007"], "source_url": "https://example.com/docs"},
          {"id": "nameless", "name": " ", "publisher": "Example", "description": "No name.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "none", "read_tools": ["search"], "source_url": "https://example.com/docs"}
        ]}
        """
        let partial = try NativeMCPStarterCatalog.load(Data(mixed.utf8))
        try check(partial.entries.map(\.id) == ["good"], "only the valid entry should load, found \(partial.entries.map(\.id))")
        try check(partial.skipped.map(\.id) == ["plain", "empty", "good", "query", "auth", "control", "nameless"], "every invalid entry should be skipped, found \(partial.skipped.map(\.id))")
        try check(partial.skipped.allSatisfy { !$0.reason.isEmpty }, "every skip should carry a reason")
        do {
            _ = try NativeMCPStarterCatalog.load(Data("[]".utf8))
            throw Failure(description: "a file without entries should fail")
        } catch is NativeToolError {}

        guard let github = catalog.entries.first(where: { $0.id == "github" }),
              let deepwiki = catalog.entries.first(where: { $0.id == "deepwiki" }) else { throw Failure(description: "expected entries are missing") }
        let row = catalog.configurationRow(for: github, readTools: Array(github.readTools.prefix(3)), scopes: ["focused", "worker"])
        let open = catalog.configurationRow(for: deepwiki, readTools: deepwiki.readTools, scopes: ["focused"])
        try check(open["authentication"] == nil, "authentication should be omitted for open services")
        try check(row["authentication"] as? String == "bearer", "authentication should be kept for token services")
        try check((row["id"] as? String) != (open["id"] as? String), "each row should get a fresh id")
        let (servers, failure) = NativeMCPServerConfiguration.load(["native_mcp_servers": [row, open]])
        try check(failure == nil && servers.count == 2, "configuration rows should pass the loader, failure \(failure ?? "none")")
        let server = servers[0]
        try check(server.id == row["id"] as? String && server.id == server.id.lowercased(), "row id should be a lowercase uuid")
        try check(server.name == "GitHub" && server.endpoint == github.url, "name and address should be preserved")
        try check(server.readTools == Set(github.readTools.prefix(3)), "chosen read tools should be preserved")
        try check(server.scopes == ["focused", "worker"] && server.timeout == 20, "scopes and timeout should be preserved")
        try check(server.authentication == .bearer && servers[1].authentication == .none, "authentication should round trip")
        try check(server.publisher == "GitHub" && server.sourceURL == github.sourceURL, "publisher and source address should be preserved")

        var insecureSource = row
        insecureSource["source_url"] = "http://example.com/docs"
        try check(NativeMCPServerConfiguration.load(["native_mcp_servers": [insecureSource]]).1 != nil, "an http source address should be refused")
        var unknownKey = row
        unknownKey["homepage"] = "https://example.com"
        try check(NativeMCPServerConfiguration.load(["native_mcp_servers": [unknownKey]]).1 != nil, "unknown keys should still be refused")
    }
}
