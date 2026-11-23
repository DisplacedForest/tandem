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
        try check(catalog.entries.map(\.id) == ["home-assistant", "github"], "the list should hold exactly two entries, found \(catalog.entries.map(\.id))")
        try check(catalog.skipped.isEmpty, "bundled list skipped \(catalog.skipped)")
        try check(catalog.categories == ["Code hosting", "Home"], "categories should come from the entries")
        try check(catalog.entries.allSatisfy { $0.sourceURL?.scheme == "https" && !$0.url.hasPrefix("http:") }, "every bundled address should be https")
        for entry in catalog.entries {
            let icon = (entry.icon ?? "") as NSString
            try check(VeraResources.url(icon.deletingPathExtension, ext: icon.pathExtension) != nil, "\(entry.name) should have a bundled icon")
        }
        guard let file = VeraResources.url(NativeMCPStarterCatalog.resourceName, ext: "json"),
              let rows = (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["entries"] as? [[String: Any]] else { throw Failure(description: "the list could not be read") }
        try check(rows.allSatisfy { !$0.keys.contains { $0.contains("tool") } }, "an entry should say nothing about tools")
        try check(catalog.matching(query: "", category: nil).count == 2, "empty query should match everything")
        try check(catalog.matching(query: "CONTROL IT", category: nil).map(\.id) == ["home-assistant"], "description search should be case insensitive")
        try check(catalog.matching(query: "github", category: "Code hosting").map(\.id) == ["github"], "query and category should combine")
        try check(catalog.matching(query: "nothing like this", category: nil).isEmpty, "unmatched query should return nothing")

        let mixed = """
        {"entries": [
          {"id": "good", "name": "Good", "publisher": "Example", "description": "Fine.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "none", "source_url": "https://example.com/docs"},
          {"id": "plain", "name": "Plain", "publisher": "Example", "description": "Insecure.", "category": "Documentation", "url": "http://mcp.example.com/mcp", "authentication": "none", "source_url": "https://example.com/docs"},
          {"id": "good", "name": "Twin", "publisher": "Example", "description": "Duplicate.", "category": "Documentation", "url": "https://twin.example.com/mcp", "authentication": "none", "source_url": "https://example.com/docs"},
          {"id": "query", "name": "Query", "publisher": "Example", "description": "Query string.", "category": "Documentation", "url": "https://mcp.example.com/mcp?key=1", "authentication": "none", "source_url": "https://example.com/docs"},
          {"id": "auth", "name": "Auth", "publisher": "Example", "description": "Unknown sign-in.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "password", "source_url": "https://example.com/docs"},
          {"id": "nowhere", "name": "Nowhere", "publisher": "Example", "description": "No gap.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "none", "fields": [{"id": "address", "label": "Address", "secret": false, "target": "address"}], "source_url": "https://example.com/docs"},
          {"id": "unused", "name": "Unused", "publisher": "Example", "description": "No sign-in.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "none", "fields": [{"id": "token", "label": "Token", "secret": true, "target": "credential"}], "source_url": "https://example.com/docs"},
          {"id": "open", "name": "Open", "publisher": "Example", "description": "Visible token.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "bearer", "fields": [{"id": "token", "label": "Token", "secret": false, "target": "credential"}], "source_url": "https://example.com/docs"},
          {"id": "tokenless", "name": "Tokenless", "publisher": "Example", "description": "Asks for no token.", "category": "Documentation", "url": "{address}", "authentication": "bearer", "fields": [{"id": "address", "label": "Address", "secret": false, "target": "address"}], "source_url": "https://example.com/docs"},
          {"id": "tokenless2", "name": "Tokenless", "publisher": "Example", "description": "Asks for nothing.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "bearer", "source_url": "https://example.com/docs"},
          {"id": "optional", "name": "Optional", "publisher": "Example", "description": "Address may be empty.", "category": "Documentation", "url": "{address}", "authentication": "none", "fields": [{"id": "address", "label": "Address", "secret": false, "optional": true, "target": "address"}], "source_url": "https://example.com/docs"},
          {"id": "gap", "name": "Gap", "publisher": "Example", "description": "Unfilled gap.", "category": "Documentation", "url": "https://{site}.example.com/mcp", "authentication": "none", "source_url": "https://example.com/docs"},
          {"id": "target", "name": "Target", "publisher": "Example", "description": "Unknown place.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "none", "fields": [{"id": "x", "label": "X", "secret": false, "target": "header"}], "source_url": "https://example.com/docs"},
          {"id": "new", "name": "New", "publisher": "Example", "description": "Fine.", "category": "Weather and tides", "url": "https://tides.example.com/mcp", "authentication": "none", "source_url": "https://example.com/docs"},
          {"id": "nameless", "name": " ", "publisher": "Example", "description": "No name.", "category": "Documentation", "url": "https://mcp.example.com/mcp", "authentication": "none", "source_url": "https://example.com/docs"}
        ]}
        """
        let partial = try NativeMCPStarterCatalog.load(Data(mixed.utf8))
        try check(partial.entries.map(\.id) == ["good", "new"], "only the valid entries should load, found \(partial.entries.map(\.id))")
        try check(partial.skipped.map(\.id) == ["plain", "good", "query", "auth", "nowhere", "unused", "open", "tokenless", "tokenless2", "optional", "gap", "target", "nameless"], "every invalid entry should be skipped, found \(partial.skipped.map(\.id))")
        try check(partial.skipped.allSatisfy { !$0.reason.isEmpty }, "every skip should carry a reason")
        try check(partial.categories == ["Documentation", "Weather and tides"], "a category the code has never named should still be listed")
        try check(partial.matching(query: "", category: "Weather and tides").map(\.id) == ["new"], "an entry should appear under its own category")
        do {
            _ = try NativeMCPStarterCatalog.load(Data("[]".utf8))
            throw Failure(description: "a file without entries should fail")
        } catch is NativeToolError {}

        guard let github = catalog.entries.first(where: { $0.id == "github" }), let address = URL(string: github.url) else { throw Failure(description: "GitHub is missing") }
        let row = catalog.configurationRow(for: github, endpoint: address, authentication: .bearer, scopes: ["focused", "worker"])
        let open = catalog.configurationRow(for: github, endpoint: address, authentication: .none, scopes: ["focused"])
        try check(Set(row.keys) == ["id", "name", "url", "scopes", "timeout_seconds", "publisher", "source_url", "authentication"], "a row should hold no tool list")
        try check(open["authentication"] == nil, "authentication should be omitted for open services")
        try check((row["id"] as? String) != (open["id"] as? String), "each row should get a fresh id")
        let (servers, failure) = NativeMCPServerConfiguration.load(["native_mcp_servers": [row, open]])
        try check(failure == nil && servers.count == 2, "configuration rows should pass the loader, failure \(failure ?? "none")")
        let server = servers[0]
        try check(server.id == row["id"] as? String && server.name == "GitHub" && server.endpoint == address, "id, name and address should be preserved")
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
