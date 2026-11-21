import AppKit
import SwiftUI

@MainActor
enum PromptIdentityShot {
    static let views: Set<String> = ["preferences-add", "prompt-full-normal", "prompt-full-companion"]
    static let companionName = "Wren"
    static let fixtureDate = Date(timeIntervalSince1970: 1_785_000_000)

    static func store() -> ChatStore {
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: try? LocalChatRepository(inMemory: true),
                              nativeOwnerName: "Riley")
        store.adoptAssistantName(companionName)
        store.ensureVeraThread()
        if let library = store.promptLibrary {
            try? library.savePromptProfile(PromptProfile.fresh(name: "Default", scope: .persona, content: NativeChatSettings.defaultSystemPrompt))
            try? library.savePromptProfile(PromptProfile.fresh(name: "About me", scope: .user,
                                                               content: "I garden on weekends and prefer metric units."))
        }
        if let preferences = store.nativePreferenceStore {
            _ = try? preferences.add(statement: "Keep replies short")
            _ = try? preferences.add(statement: "Use metric units")
        }
        return store
    }

    static func render(to path: String, view: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let store = store()
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(),
                                 readConfiguration: { ["assistant_name": companionName] },
                                 writeConfiguration: { _ in })
        let size: NSSize
        let root: AnyView
        switch view {
        case "preferences-add":
            size = NSSize(width: 640, height: 300)
            root = AnyView(Form { Section("Preferences") { PreferencesSettingsView() } }.formStyle(.grouped))
        default:
            let companion = view == "prompt-full-companion"
            size = NSSize(width: 640, height: companion ? 2800 : 1760)
            root = AnyView(FullPromptSheet(
                preview: { store.fullPromptPreview(companion: $0, now: fixtureDate, timeZone: TimeZone(identifier: "America/Chicago") ?? .current) },
                companionLabel: store.companionDisplayName ?? "Companion",
                onEdit: { _ in }, onDone: {}, scrolls: false, companion: companion)
                .background(Theme.surface))
        }
        let content = root
            .environmentObject(store).environmentObject(config)
            .environment(\.companionName, store.companionDisplayName)
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Theme.bg)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: AppLocations.checkedOutput(path)); print("wrote \(path)"); exit(0) }
        catch { exit(1) }
    }
}
