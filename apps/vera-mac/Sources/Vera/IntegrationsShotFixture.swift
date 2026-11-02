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

    static func store(variant: String) -> Seeded {
        let store = ChatStore()
        store.section = .integrations
        let rows: [[String: Any]] = variant == "integrations-empty" ? [] : [
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
        let manager = NativeMCPManager(servers: servers)
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
        switch variant {
        case "integrations-public":
            return Seeded(store: store, config: config, tab: .catalogue, search: "documentation", selection: "deepwiki")
        default:
            return Seeded(store: store, config: config, tab: .personal, search: "", selection: rows.isEmpty ? nil : wikiID)
        }
    }

    private static let schema: NativeJSONValue = .object([
        "type": .string("object"),
        "properties": .object(["repoName": .object(["type": .string("string"), "maxLength": .number(200)])]),
        "required": .array([.string("repoName")]),
        "additionalProperties": .bool(false),
    ])
}
