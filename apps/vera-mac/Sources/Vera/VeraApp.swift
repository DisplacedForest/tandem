import SwiftUI
import AppKit

/// Forces a foreground, regular-activation window when launched from an SPM executable
/// (otherwise `swift run` can open the window in the background).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Only force the Dock/cmd-tab icon when running UNBUNDLED (`swift run`), where there's
        // no .icns. In a packaged .app the bundle's Vera.icns is the correct, mipmapped icon —
        // overriding it with the raw full-bleed PNG is what made the Dock icon look wrong.
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
        if !bundled, let icon = Brand.icon { NSApp.applicationIconImage = icon }
    }
    @MainActor static var keepsRunningAfterLastWindowClosed: () -> Bool = { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.keepsRunningAfterLastWindowClosed()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await NativePiNativeContext.presentation.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct VeraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: ChatStore
    @StateObject private var voice: VoiceSession
    @StateObject private var config: ConfigStore
    @StateObject private var updates = UpdateChecker()
    @StateObject private var engine = EngineManager()
    @StateObject private var presence: TandemLogoPresence
    @StateObject private var companionPresence: CompanionPresence
    @StateObject private var companion: CompanionCoordinator

    init() {
        let fixture = NativePiNativeContext.candidate
        let configInstance = fixture?.config ?? ConfigStore()
        let native = NativeMCPUIFixture.current != nil ? NativeChatConfig(baseURL: URL(string: "https://fixture.invalid/v1")!, apiKey: nil, model: "fixture", chatTemplateKwargs: nil) : fixture == nil ? configInstance.nativeResolved : nil
        let socket = fixture == nil ? VoiceSocketConfig.load().map { VeraSocket(config: $0) } : nil
        let repository: LocalChatRepository?
        let repositoryError: String?
        do {
            if let fixture {
                repository = try LocalChatRepository(url: fixture.root.url.appendingPathComponent("focused.sqlite"))
            } else {
                repository = try LocalChatRepository()
            }
            repositoryError = nil
        } catch {
            repository = nil
            repositoryError = "Local history couldn't open: \(error.localizedDescription)"
        }
        if let repository {
            var settings = configInstance.nativeSettings
            if (try? NativePromptMigration.run(repository: repository, settings: &settings)) == true {
                configInstance.nativeSettings = settings
                try? configInstance.save()
            }
        }
        let storeInstance = ChatStore(
            veraAPI: fixture == nil ? VeraAPIClient.resolved(model: native?.model ?? "") : nil,
            nativeConfig: native,
            nativeTransport: NativeMCPUIFixture.current?.chat ?? native.map { NativeChatClient.foreground(config: $0) },
            repository: repository,
            repositoryError: repositoryError,
            nativeTransportFactory: { configuration in NativeMCPUIFixture.current?.chat ?? NativeChatClient.foreground(config: configuration) },
            nativeSystemPrompt: configInstance.nativeSettings.systemPrompt,
            nativePersonaID: configInstance.nativeSettings.activePersonaID,
            nativeOwnerName: configInstance.ownerName,
            nativeAssistantName: configInstance.assistantName,
            nativeEnabledToolIDs: configInstance.nativeSettings.enabledToolIDs,
            nativeCapabilityOverrides: configInstance.nativeSettings.capabilityOverrides,
            visionBridgeConfig: configInstance.visionBridgeResolved,
            nativeMemorySettings: configInstance.nativeSettings.memory,
            nativeMemoryService: configInstance.nativeMemoryService,
            nativeRules: configInstance.nativeSettings.rules,
            nativeMCP: configInstance.nativeMCP,
            capabilityDeclarations: configInstance.capabilityTools.declarations,
            sweepOrphanedAttachments: fixture == nil,
            nativeTaskConfiguration: NativeMCPUIFixture.current == nil ? NativeTaskConfiguration(
                settings: { configInstance.nativeSettings },
                savedTemplate: { configInstance["chat_template_kwargs"] }) : nil,
            artifactPersistenceEnabled: fixture == nil)
        storeInstance.generatesConversationTitles = fixture == nil
        storeInstance.menuBarPreference = configInstance.menuBarKeepRunning
        if fixture == nil {
            AppDelegate.keepsRunningAfterLastWindowClosed = { [weak storeInstance] in storeInstance?.keepsRunningInMenuBar ?? false }
        }
        if fixture == nil {
            NativePiNativeContext.presentation = NativePiProduction.presentation(config: configInstance, store: storeInstance)
        }
        _store = StateObject(wrappedValue: storeInstance)
        _config = StateObject(wrappedValue: configInstance)
        _companion = StateObject(wrappedValue: CompanionCoordinator(store: storeInstance, config: configInstance))
        let voiceInstance = VoiceSession(client: VoiceClient(base: configInstance.voiceBase),
                                         socket: socket, store: storeInstance)
        voiceInstance.observe(configInstance)
        _voice = StateObject(wrappedValue: voiceInstance)
        _presence = StateObject(wrappedValue: TandemLogoPresence(store: storeInstance, voice: voiceInstance))
        _companionPresence = StateObject(wrappedValue: CompanionPresence(store: storeInstance, voice: voiceInstance))
    }

    var body: some Scene {
        WindowGroup("Tandem", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(voice)
                .environmentObject(config)
                .environmentObject(updates)
                .environmentObject(engine)
                .environmentObject(presence)
                .environment(\.companionName, store.assistantName)
                .environment(\.companionAppearance, config.companionAppearance)
                .environment(\.companionLiveState, companionPresence.state)
                .environmentObject(companion)
                .frame(minWidth: 920, minHeight: 600)
                .preferredColorScheme(config.colorSchemeOverride)
                .task { if NativePiNativeContext.candidate == nil { updates.start() } }
                .task { if NativePiNativeContext.candidate == nil { presence.start(); companionPresence.start() } }
                .task { if NativePiNativeContext.candidate == nil { await engine.reconcileOnLaunch() } }
                .task { if NativePiNativeContext.candidate == nil { await RemindersBridge.autostartIfEnabled(veraAPIBase: config.veraAPIBase) } }
                .task { if NativePiNativeContext.candidate == nil { companion.start() } }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(updates.checking ? "Checking…" : "Check for Updates…") {
                    Task { await updates.check(manual: true) }
                }
                .disabled(updates.checking)
            }
        }

        MenuBarExtra(isInserted: .constant(NativePiNativeContext.candidate == nil && store.keepsRunningInMenuBar)) {
            MenuBarStatusMenu()
                .environmentObject(store)
                .environmentObject(config)
                .environmentObject(companion)
        } label: {
            Label {
                Text(store.companionUnreadCount > 0 ? config.assistantName + " •" : config.assistantName)
            } icon: {
                Image(nsImage: TandemTemplate.image(pointSize: 18))
            }
        }

        Settings {
            SettingsView()
                .environmentObject(config)
                .environmentObject(store)
                .environmentObject(updates)
                .environmentObject(engine)
                .environmentObject(presence)
                .environment(\.companionName, store.assistantName)
                .environment(\.companionAppearance, config.companionAppearance)
                .environment(\.companionLiveState, companionPresence.state)
                .environmentObject(companion)
                .preferredColorScheme(config.colorSchemeOverride)
        }
    }
}

struct MenuBarStatusMenu: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var companion: CompanionCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let next = store.nextScheduledRun {
            Text("Next: \(next.schedule.title), \(NativeScheduleClock.relative(next.at, now: Date(), timeZone: next.schedule.timeZone))")
        } else {
            Text("Nothing scheduled")
        }
        let running = store.runningScheduledWorkCount
        if running > 0 {
            Text(running == 1 ? "1 scheduled run in progress" : "\(running) scheduled runs in progress")
        }
        let waiting = store.waitingScheduledWorkCount
        if waiting > 0 {
            Text(waiting == 1 ? "1 scheduled run is waiting for you" : "\(waiting) scheduled runs are waiting for you")
        }
        Divider()
        Button(config.companionActiveShortcut.map { "Quick ask  \($0.symbols)" } ?? "Quick ask") { companion.toggle() }
        Button("Open Tandem") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Scheduled work") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            store.section = .scheduled
        }
        Divider()
        Button("Quit Tandem") { NSApp.terminate(nil) }
    }
}
