import Foundation

@MainActor
enum IntegrationsShotFixture {
    struct Seeded {
        let store: ChatStore
        let config: ConfigStore
        let tab: IntegrationsTab
        let search: String
        let selection: String?
    }

    final class Disk {
        var contents: [String: Any]
        init(_ contents: [String: Any]) { self.contents = contents }
    }

    static let wikiID = "6f1c2a4e-3b7d-4c18-9a2e-5d0f81b7c3a9"
    static let codeID = "d2a9e7c1-8f34-4b6a-b0c5-1e7a3f9d2b64"

    static let codeRow: [String: Any] = [
        "id": codeID, "name": "GitHub", "url": "https://api.githubcopilot.com/mcp/",
        "read_tools": ["search_repositories", "get_file_contents", "list_notifications"], "act_tools": ["create_issue"],
        "scopes": ["focused", "assistant", "worker"], "timeout_seconds": 20.0, "authentication": "bearer",
        "publisher": "GitHub", "source_url": "https://github.com/github/github-mcp-server",
    ]

    static let reportsID = "0d4b6f2e-5a1c-4e93-b7d8-3c9e1f6a2b50"

    static var reportsRow: [String: Any] {
        ["id": reportsID, "name": "Home Assistant", "url": "https://house.example/mcp", "scopes": IntegrationsText.scopeKeys, "timeout_seconds": 20.0]
    }

    static var signedInRow: [String: Any] {
        ["id": wikiID, "name": "Reference", "url": "https://reference.example/mcp", "read_tools": ["lookup_reference"], "scopes": ["focused", "assistant"], "timeout_seconds": 20.0, "authentication": "oauth",
         "oauth": ["resource": "https://reference.example/mcp", "issuer": "https://login.reference.example",
                   "protected_resource_metadata_url": "https://reference.example/.well-known/oauth-protected-resource/mcp",
                   "authorization_server_metadata_url": "https://login.reference.example/.well-known/oauth-authorization-server",
                   "authorization_endpoint": "https://login.reference.example/authorize", "token_endpoint": "https://login.reference.example/token",
                   "client_id": "preregistered-public-client", "redirect_uri": "vera-oauth://callback", "scopes": ["reference.read"]]]
    }

    static var docsRow: [String: Any] {
        ["id": wikiID, "name": "DeepWiki", "url": "https://mcp.deepwiki.com/mcp", "read_tools": ["read_wiki_structure"], "scopes": ["focused"],
         "timeout_seconds": 20.0, "publisher": "Cognition (Devin)"]
    }

    static var longRow: [String: Any] {
        ["id": wikiID, "name": "A service somebody gave a remarkably long name that will not fit on one line", "url": "https://long.example/mcp",
         "scopes": ["focused"], "timeout_seconds": 20.0, "publisher": "Example"]
    }

    static func changeDefinition(_ store: ChatStore) -> NativeToolDefinition {
        let seeded = self.store(variant: "integrations-reports")
        return seeded.config.nativeMCP.authority.definitions(scope: "focused").first { $0.title.hasSuffix("remove_item") }!
    }

    static func store(variant: String) -> Seeded {
        let store = ChatStore()
        store.section = .integrations
        let manage = variant.hasPrefix("integrations-manage")
        let changes = variant == "integrations-changes" || manage
        let rows: [[String: Any]] = ["integrations-empty", "integrations-public"].contains(variant) ? [] : variant.hasPrefix("integrations-long") ? [longRow, codeRow] : variant == "integrations-states" ? [docsRow, codeRow, reportsRow] : variant == "integrations-reports" || variant == "integrations-manage-reports" ? [reportsRow] : variant == "integrations-signed-in" ? [signedInRow] : changes ? [codeRow] : [
            [
                "id": wikiID, "name": "DeepWiki", "url": "https://mcp.deepwiki.com/mcp",
                "read_tools": ["read_wiki_structure", "read_wiki_contents", "ask_question"],
                "scopes": ["focused", "assistant"], "timeout_seconds": 20.0,
                "publisher": "Cognition (Devin)", "source_url": "https://docs.devin.ai/work-with-devin/deepwiki-mcp",
            ],
            [
                "id": codeID, "name": "GitHub", "url": "https://api.githubcopilot.com/mcp/",
                "read_tools": ["search_repositories", "get_file_contents", "list_issues"],
                "scopes": ["focused", "assistant", "worker"], "timeout_seconds": 20.0, "authentication": "bearer",
                "publisher": "GitHub", "source_url": "https://github.com/github/github-mcp-server",
            ],
        ]
        let disk = Disk(rows.isEmpty ? [:] : ["native_mcp_servers": rows])
        let (servers, _) = NativeMCPServerConfiguration.load(disk.contents)
        let keys = NativeCredentialFixtureStore()
        if ["integrations-manage", "integrations-reconnecting", "integrations-states"].contains(variant), let code = servers.first(where: { $0.id == codeID }) {
            try? NativeMCPTokenKeeper(store: keys).save("synthetic-shot-token", server: code)
        }
        let manager = NativeMCPManager(servers: servers, tokens: keys, reconnectDelays: [])
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents },
                                 nativeMCP: manager, writeConfiguration: { disk.contents = $0 })
        if let wiki = servers.first(where: { $0.id == wikiID }),
           var state = manager.authority.access.snapshot().first(where: { $0.id == wikiID }) {
            let tools: [(String, String)] = [
                ("read_wiki_structure", "List the documentation topics for a public repository."),
                ("read_wiki_contents", "Read the generated documentation for a public repository."),
                ("ask_question", "Ask a question about a public repository and get an answer grounded in its code."),
            ]
            state.connected = true
            state.status = "Connected"
            state.tools = tools.map { name, description in
                NativeMCPToolRecord(id: wiki.toolID(name), server: wiki, generation: state.generation, remoteName: name,
                                    description: description, schema: schema, validator: try? NativeMCPJSONSchema(schema), reason: nil)
            }
            manager.authority.access.update(state)
            config.setNativeTool(wiki.toolID("read_wiki_structure"), enabled: true)
            config.setNativeTool(wiki.toolID("read_wiki_contents"), enabled: true)
            manager.refresh()
        }
        if changes, let code = servers.first(where: { $0.id == codeID }),
           var state = manager.authority.access.snapshot().first(where: { $0.id == codeID }) {
            let tools: [(String, String, NativeMCPToolHints)] = [
                ("search_repositories", "Find repositories by name, topic or owner.", NativeMCPToolHints(readOnly: true)),
                ("get_file_contents", "Read a file or folder from a repository.", NativeMCPToolHints(readOnly: true)),
                ("list_notifications", "List your notifications and mark them as read.", NativeMCPToolHints(readOnly: false)),
                ("create_issue", "Open a new issue in a repository.", NativeMCPToolHints(readOnly: false)),
                ("delete_repository", "Delete a repository for good.", NativeMCPToolHints(readOnly: false, destructive: true)),
            ]
            state.connected = true
            state.status = "Connected"
            state.tools = tools.map { name, description, hints in
                NativeMCPToolRecord(id: code.toolID(name), server: code, generation: state.generation, remoteName: name,
                                    description: description, schema: schema, validator: try? NativeMCPJSONSchema(schema),
                                    reason: name == "delete_repository" ? "This action has not been approved as a read tool." : nil, hints: hints)
            }
            manager.authority.access.update(state)
            for (name, _, _) in tools where name != "get_file_contents" && name != "delete_repository" { config.setNativeTool(code.toolID(name), enabled: true) }
            manager.refresh()
        }
        if variant == "integrations-failed", var state = manager.authority.access.snapshot().first(where: { $0.id == codeID }) {
            state.status = NativeMCPAuthority.tokenNeeded
            state.refused = true
            manager.authority.access.update(state)
            manager.refresh()
        }
        if let reports = servers.first(where: { $0.reportsTools }), var state = manager.authority.access.snapshot().first(where: { $0.id == reports.id }) {
            let tools: [(String, String, Bool)] = [("read_items", "Reads every item.", true), ("update_item", "Changes one item.", false), ("remove_item", "Removes an item.", false)]
            state.connected = variant != "integrations-states"
            state.status = state.connected ? "Connected" : "Not connected"
            state.tools = !state.connected ? [] : tools.map { name, description, readOnly in
                NativeMCPToolRecord(id: reports.toolID(name), server: reports, generation: state.generation, remoteName: name, description: description, schema: schema,
                                    validator: try? NativeMCPJSONSchema(schema), reason: nil, hints: NativeMCPToolHints(readOnly: readOnly, destructive: true))
            }
            manager.authority.access.update(state)
            manager.refresh()
        }
        if variant == "integrations-signed-in", var state = manager.authority.access.snapshot().first {
            state.connected = true
            state.status = "Signed in"
            manager.authority.access.update(state)
            manager.refresh()
        }
        switch variant {
        case "integrations-reconnecting", "integrations-failed":
            return Seeded(store: store, config: config, tab: .personal, search: "", selection: codeID)
        case "integrations-reports", "integrations-manage-reports", "integrations-signed-in":
            return Seeded(store: store, config: config, tab: .personal, search: "", selection: nil)
        case "integrations-public":
            return Seeded(store: store, config: config, tab: .catalogue, search: "", selection: "home-assistant")
        case "integrations-public-installed", "integrations-menu":
            return Seeded(store: store, config: config, tab: .catalogue, search: "", selection: codeID)
        case "integrations-no-match":
            return Seeded(store: store, config: config, tab: .catalogue, search: "nothing like this", selection: nil)
        default:
            return Seeded(store: store, config: config, tab: .personal, search: "", selection: rows.isEmpty ? nil : changes ? codeID : wikiID)
        }
    }

    static func detail(_ view: String, seed: Seeded) -> IntegrationsDetailTarget {
        if view == "integrations-detail-public", let entry = (try? IntegrationsCatalogue.loaded.get())?.entries.first { return .entry(entry) }
        return .server(seed.selection ?? seed.config.nativeMCP.servers.first?.id ?? "")
    }

    static func installDraft(_ view: String) -> NativeMCPInstallDraft? {
        if view == "integrations-install-own" { return NativeMCPInstallDraft(entry: .own) }
        let id = view == "integrations-install-github" ? "github" : "home-assistant"
        guard let entry = (try? IntegrationsCatalogue.loaded.get())?.entries.first(where: { $0.id == id }) else { return nil }
        guard view.hasPrefix("integrations-install-review") || view == "integrations-install-open" else {
            let draft = NativeMCPInstallDraft(entry: entry)
            if view == "integrations-install-filled" { draft.values = ["address": "http://homeassistant.local:8123/api/mcp", "token": "fixture"] }
            return draft
        }
        let tools: [(String, String, Bool)] = [
            ("update_item", "Changes one item.", true),
            ("update_items", "Changes several items at once.", true),
            ("create_item", "Adds an item.", true),
            ("remove_item", "Removes an item.", true),
            ("run_routine", "Runs a routine by name.", true),
            ("find_items", "Finds items by name.", false),
            ("read_item", "Reads one item.", false),
            ("read_history", "Reads how an item changed over a period of time.", false),
        ]
        return NativeMCPInstallDraft(reviewing: entry, offers: tools.map { NativeMCPInstallOffer(name: $0.0, label: $0.0, detail: $0.1, change: $0.2, usable: true) })
    }

    private static let schema: NativeJSONValue = .object([
        "type": .string("object"),
        "properties": .object(["repoName": .object(["type": .string("string"), "maxLength": .number(200)])]),
        "required": .array([.string("repoName")]),
        "additionalProperties": .bool(false),
    ])
}
