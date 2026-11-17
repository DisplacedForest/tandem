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
            "actions_registry": "Lists the actions the connected server can propose, with the arguments each one takes. When to use: before calling propose_action, to find a real verb and its arguments, or when the person wants to know which actions the server offers. When not to use: to carry out or propose anything, since this only reads. Effects: read only; it changes nothing. Returns verbs, each with verb, summary, args showing the shape of its arguments, risk, reversible and autonomous, and the server may add further catalog fields. Use only verbs and argument names from this result. If it fails, say plainly that the list of actions could not be loaded, and never guess a verb.",
            "propose_action": "Proposes one action from the server's list for the person to approve or dismiss; nothing runs now. When to use: a specific action from that list is worth taking and the person should decide on it. When not to use: before actions_registry has given you the verb and its arguments in this conversation, so call it first; for something another tool here can do directly. Effects: the server checks the verb and arguments and, if they are valid, posts the proposal for the person's decision; the action runs only if the person approves it. Inputs: verb exactly as actions_registry lists it; args_json holding that verb's arguments as a JSON object written as a string, omitted when the verb takes none; a short title; and a body of one or two sentences on why it is worth doing. Returns ok and, on success, a preview with the risk and whether it can be reversed; when ok is false, error says what was wrong. If ok is false, fix the verb or arguments from actions_registry and retry once, otherwise tell the person it could not be proposed.",
            "author_skill": "Proposes saving a named skill, a stored set of step-by-step instructions that can be followed again later, or replacing the skill with that name. When to use: the person wants a repeatable procedure kept so it can be reused. When not to use: a one-off answer or a preference, which you handle in the conversation; a document meant for reading, which create_background_task writes when it is offered. Effects: the app asks the person first, and the server then holds the change for approval before the skill is saved; a skill with the same name is replaced. Inputs: name, the full content, and optionally a one-line description. Returns proposed and a preview of the change. If it fails, say plainly that the skill could not be saved.",
        ]
        try require(Set(declarations.map(\.name)) == Set(expected.keys), "The bundled server tools keep their names")
        let connected = NativeChatToolCatalog.tools(veraAPIConfigured: true, declarations: declarations)
        for declaration in declarations {
            let definition = NativeCapabilityTools.definition(declaration, base: { nil }, client: .live)
            try require(definition.description == expected[declaration.name] && declaration.description == expected[declaration.name],
                        "\(declaration.name) sends the assistant its pinned description")
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
