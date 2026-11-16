import AppKit
import SwiftUI

@MainActor
enum SettingsTabShot {
    static let prefix = "settings-tab-"

    static func render(view: String, to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        var name = String(view.dropFirst(prefix.count))
        let window = name.hasSuffix("-window")
        if window { name = String(name.dropLast("-window".count)) }
        let filled = name.hasSuffix("-filled")
        let tab = filled ? String(name.dropLast("-filled".count)) : name
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-tab-shot-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil,
                              attachmentStore: NativeAttachmentStore(directory: directory))
        var seed: [String: Any] = [:]
        if filled {
            setenv("VERA_API_BASE", "http://my-api-host:8089", 1)
            setenv(NativeImageTools.envName, "http://my-comfyui-host:8188", 1)
            setenv(NativeWebSearch.envName, "http://my-search-host:8088", 1)
            seed = ["vera_api_base": "http://my-api-host:8089", NativeImageTools.configKey: "http://my-comfyui-host:8188",
                    NativeWebSearch.configKey: "http://my-search-host:8088", "assistant_name": "Ada", "owner_name": "Sam"]
        }
        if tab == "services-local" { seed["engine_mode"] = "local" }
        if tab == "services-remote" { seed["engine_mode"] = "remote"; seed["vera_api_base"] = "http://my-api-host:8089" }
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { seed }, writeConfiguration: { _ in })
        if filled {
            config.addNativeProfile()
            config.activeProfileBinding(\.name).wrappedValue = "Home model server"
            config.activeProfileBinding(\.baseURL).wrappedValue = "https://models.example/v1"
            config.cacheDiscoveredModels(["qwen3-30b-a3b", "gemma-3-12b", "small-helper"])
            config.selectNativeModel("qwen3-30b-a3b")
        }
        let engine = EngineManager(configURL: directory.appendingPathComponent("config.json"))
        let updates = UpdateChecker()
        let companion = CompanionCoordinator(store: store, config: config)
        let presence = TandemLogoPresence(store: store)
        let height: CGFloat = ["model", "memory", "tools", "persona"].contains(tab) ? 1500 : 760
        let size = NSSize(width: 860, height: window ? 640 : height)
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let content: AnyView
        switch tab {
        case "endpoints": content = AnyView(ConnectionTab())
        case "model": content = AnyView(ModelTab())
        case "persona": content = AnyView(PersonaTab())
        case "memory": content = AnyView(NativeMemorySettingsTab())
        case "knowledge": content = AnyView(KnowledgeView())
        case "tools": content = AnyView(NativeToolsTab())
        case "image": content = AnyView(ImageTab())
        case "search": content = AnyView(SearchTab())
        case "services", "services-local", "services-remote": content = AnyView(ServicesTab())
        case "plugins": content = AnyView(PluginsView())
        case "identity": content = AnyView(IdentityTab())
        case "about": content = AnyView(AboutTab())
        default: exit(1)
        }
        let root = content
            .environmentObject(store).environmentObject(config).environmentObject(engine)
            .environmentObject(updates).environmentObject(companion).environmentObject(presence)
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Theme.bg)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let host = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.appearance = NSApplication.shared.appearance
        host.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: AppLocations.checkedOutput(path)); print("wrote \(path)"); exit(0) }
        catch { exit(1) }
    }
}
