import Foundation

@MainActor
extension SelfTest {
    static func runSettingsToolsCopy() async throws {
        let require = NativeTaskFixture.require
        let banned = ["vera", "native chat", "model", "comfyui", "searxng", "tools.d", "config file", "declaration",
                      "args_json", "json", "shell", "working directory", "connection tab", "\u{2014}"]
        let declarations = NativeCapabilityTools.bundled
        try require(declarations.count == 3, "The three bundled server tools load")
        func texts(_ tools: [NativeChatToolDescriptor]) -> [String] {
            tools.flatMap { [$0.name, $0.summary, $0.setup] }
        }
        let bare = NativeChatToolCatalog.tools(veraAPIConfigured: false, declarations: declarations)
        let full = NativeChatToolCatalog.tools(veraAPIConfigured: true, imageConfigured: true, searchConfigured: true, declarations: declarations)
        for text in texts(bare) + texts(full) + SettingsToolsCopy.fixedStrings {
            let lowered = text.lowercased()
            for word in banned {
                try require(!lowered.contains(word), "Tools copy never says '\(word)': \(text)")
            }
        }
        try require(SettingsToolsCopy.tab(for: NativeWebTools.searchToolID) == .search, "Web search opens the Search tab")
        try require(SettingsToolsCopy.tab(for: NativeImageTools.toolID) == .image, "Image generation opens the Image tab")
        try require(SettingsToolsCopy.tab(for: "apple-reminders") == nil, "Other tools open no tab")
        let ids = Set(declarations.map(\.id))
        let without = SettingsToolsCopy.listed(declarations: declarations, serverConnected: false, imageConfigured: false, searchConfigured: false)
        try require(!without.contains { ids.contains($0.id) }, "Server tools are hidden when no server is connected")
        let with = SettingsToolsCopy.listed(declarations: declarations, serverConnected: true, imageConfigured: false, searchConfigured: false)
        for declaration in declarations {
            let row = with.first { $0.id == declaration.id }
            try require(row != nil, "\(declaration.name) is listed with a server")
            try require(row?.summary.isEmpty == false && row?.summary != declaration.description,
                        "\(declaration.name) shows its own plain summary")
        }
        let expected: [String: String] = [
            "actions_registry": "List the action verbs this deployment can propose, with the arguments each one takes. Call this before proposing an action so the verb and arguments are real.",
            "propose_action": "Propose an action for review. The verb must come from the action registry, and both title and body are required. Pass args_json as a JSON object string holding that verb's arguments, for example {\"key\": \"value\"}, when the verb takes any. The proposal is queued for a decision, not run.",
            "author_skill": "Write or replace a named skill document. Use this only when asked to capture a repeatable procedure.",
        ]
        try require(Set(declarations.map(\.name)) == Set(expected.keys), "The bundled server tools keep their names")
        let connected = NativeChatToolCatalog.tools(veraAPIConfigured: true, declarations: declarations)
        for declaration in declarations {
            let definition = NativeCapabilityTools.definition(declaration, base: { nil }, client: .live)
            try require(definition.description == expected[declaration.name] && declaration.description == expected[declaration.name],
                        "\(declaration.name) sends the assistant the same description as before")
            try require(definition.parameters == declaration.parameters && definition.name == declaration.name && definition.id == declaration.id,
                        "\(declaration.name) sends the assistant the same name and arguments as before")
            try require(bare.first { $0.id == declaration.id }?.available == false && connected.first { $0.id == declaration.id }?.available == true,
                        "\(declaration.name) is offered only with a server, as before")
        }
        let plain = try NativeCapabilityTools.parse(
            data: Data(#"{"name":"garden_log","title":"Garden log","description":"For the assistant only.","parameters":{"type":"object","properties":{},"required":[],"additionalProperties":false},"endpoint":"https://garden.example/log","method":"GET","confirmation":"none"}"#.utf8),
            source: "garden.json")
        try require(plain.summary == nil, "A tool file without a summary has none")
        let own = NativeChatToolCatalog.tools(veraAPIConfigured: false, declarations: [plain]).first { $0.id == plain.id }
        try require(own?.summary.isEmpty == true && own?.available == true, "Text written for the assistant is never shown as a tool's summary")
        try require(SettingsToolsCopy.listed(declarations: [plain], serverConnected: false, imageConfigured: false, searchConfigured: false)
                        .contains { $0.id == plain.id }, "A tool with its own address stays listed without a server")
        for value in ["", "   "] {
            let blank = try NativeCapabilityTools.parse(
                object: ["name": "garden_log", "title": "Garden log", "description": "For the assistant only.",
                         "parameters": ["type": "object", "properties": [String: Any](), "required": [String](), "additionalProperties": false],
                         "endpoint": "https://garden.example/log", "method": "GET", "confirmation": "none", "summary": value],
                source: "garden.json")
            try require(blank.summary == nil, "A blank summary counts as none")
        }
        let hint = SettingsToolsCopy.failureHint("broken.json").lowercased()
        try require(hint == "broken" && !banned.contains { hint.contains($0) }, "The hover for a tool file that couldn't load names the file plainly")
        print("  settings tools copy OK (plain words, tab buttons, server tools hidden without a server, text for the assistant unchanged)")
    }
}
