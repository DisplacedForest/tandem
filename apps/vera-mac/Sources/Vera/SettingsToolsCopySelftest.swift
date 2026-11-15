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
        let propose = NativeCapabilityTools.definition(
            declarations.first { $0.name == "propose_action" }!, base: { nil }, client: .live)
        try require(propose.description.contains("args_json"), "The model-facing description is unchanged")
        print("  settings tools copy OK (plain words, tab buttons, server tools hidden without a server, text for the assistant unchanged)")
    }
}
