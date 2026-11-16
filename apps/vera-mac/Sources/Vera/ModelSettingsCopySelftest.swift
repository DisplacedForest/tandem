import Foundation

@MainActor
extension SelfTest {
    static func runModelSettingsCopy() async throws {
        let require = NativeTaskFixture.require
        let banned = ["identifier", "probed", "runtime", "routed", "/v1 model endpoint", "model id", "discover", "capability profile", "tool calls", "\u{2014}"]
        let states: [ModelDiscoveryState] = [.idle, .loading, .models(["a"]), .models(["a", "b", "c"]), .empty,
                                             .noUsableModels, .authenticationFailed, .networkFailed, .malformed]
        let messages = states.compactMap(ModelSettingsCopy.discoveryMessage)
        try require(messages.count == states.count - 1, "Every state but idle shows a line")
        for text in ModelSettingsCopy.fixedStrings + messages {
            let lowered = text.lowercased()
            for word in banned {
                try require(!lowered.contains(word), "Endpoints and model copy never says '\(word)': \(text)")
            }
        }
        try require(ModelSettingsCopy.savedWithoutModel == "Saved. Add a model server and choose a model to start chatting.",
                    "The save line reads plainly: \(ModelSettingsCopy.savedWithoutModel)")
        try require(ModelSettingsCopy.discoveryMessage(.models(["a"])) == "Loaded 1 model", "One model reads singular")
        try require(ModelSettingsCopy.discoveryMessage(.models(["a", "b", "c"])) == "Loaded 3 models", "Three models read plural")
        try require(ModelSettingsCopy.discoveryMessage(.loading) == "Loading models…", "Loading reads plainly")
        try require(ModelSettingsCopy.noEndpoint == "Add a model server to begin." && ModelSettingsCopy.endpointFirst == "Add a model server first."
                        && ModelSettingsCopy.chooseModel == "Choose a model to see what it can do." && ModelSettingsCopy.looking == "Looking for models…"
                        && ModelSettingsCopy.usesTools == "Can use tools",
                    "The empty states, the refresh button and the switch read plainly")
        let exact: [(ModelDiscoveryState, String)] = [
            (.empty, "The endpoint returned an empty model list. Check the server, then retry."),
            (.noUsableModels, "The server listed models, but none of them can be used."),
            (.authenticationFailed, "Authentication failed. Check the API key, save it, then retry."),
            (.networkFailed, "Tandem could not reach the endpoint. Check its URL and network connection, then retry."),
            (.malformed, "The endpoint returned a model response Tandem could not read."),
            (.failed("The server said no."), "The server said no."),
        ]
        for (state, text) in exact {
            try require(ModelSettingsCopy.discoveryMessage(state) == text, "Each model list state shows its own line: \(text)")
        }
        let search = NativeChatToolCatalog.tools(veraAPIConfigured: false).first { $0.id == NativeWebTools.searchToolID }
        try require(search?.summary == "Searches the web and answers with sources.", "Web search says what it does: \(search?.summary ?? "missing")")
        try require(ModelSettingsCopy.setupGuideTip == "You can run the guide again at any time. Your saved endpoints, prompt, tools and chat history stay in place."
                        && ModelSettingsCopy.setupNote == "API keys are saved in your Mac keychain. Use the OpenAI-compatible API root ending in /v1.",
                    "The setup guide note on the tab and the note kept in the setup guide read as written")
        try require(ModelSettingsCopy.discoveryMessage(.idle) == nil, "Idle shows nothing on the face of the tab")
        print("  model settings copy OK (plain placeholders, tips, save line and loading lines)")
    }
}
