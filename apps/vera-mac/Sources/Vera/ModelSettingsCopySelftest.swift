import Foundation

@MainActor
extension SelfTest {
    static func runModelSettingsCopy() async throws {
        let require = NativeTaskFixture.require
        let banned = ["identifier", "probed", "runtime", "routed", "/v1 model endpoint", "model id", "\u{2014}"]
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
        try require(ModelSettingsCopy.discoveryMessage(.idle) == nil, "Idle shows nothing on the face of the tab")
        print("  model settings copy OK (plain placeholders, tips, save line and loading lines)")
    }
}
