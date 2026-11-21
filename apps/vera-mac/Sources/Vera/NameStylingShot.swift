import AppKit
import SwiftUI

@MainActor
enum NameStylingShot {
    static let views: Set<String> = ["name-dot-settings-reset-failed", "name-dot-settings", "name-surfaces", "name-surfaces-chat", "name-appearance-draft",
                                     "name-not-connected", "name-not-connected-chat", "name-artifacts-filter", "name-scheduled-paused",
                                     "name-thread-error", "name-saved-report", "name-saved-approval", "name-saved-scheduled",
                                     "name-saved-library", "name-library-after-reset", "name-panel-after-reset"]

    static func render(to path: String, view: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let name = CompanionNameShot.name(environment: ProcessInfo.processInfo.environment)
        let library: Set<String> = ["name-artifacts-filter", "name-saved-library", "name-library-after-reset", "name-panel-after-reset"]
        let store = library.contains(view) ? ArtifactShotFixture.store(variant: "artifacts").store
            : ChatStore(nativeConfig: nil, nativeTransport: nil, repository: try? LocalChatRepository(inMemory: true))
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(),
                                 readConfiguration: { name.map { ["assistant_name": $0] } ?? [:] },
                                 writeConfiguration: { _ in })
        if view.hasSuffix("-after-reset") { CompanionLibraryKeepFixture.startOver(store, name: name) }
        NativeDotShotFixture.populate(store, paused: view == "name-surfaces", setupCompleted: true)
        let colors = CompanionAppearance(shape: .pebble, color: .apricot)
        let size: NSSize
        let root: AnyView
        switch view {
        case "name-dot-settings":
            size = NSSize(width: 560, height: 700)
            root = AnyView(DotSettingsView())
        case "name-dot-settings-reset-failed":
            size = NSSize(width: 560, height: 760)
            store.reportCompanionConfigurationError(CompanionErrorCopy.resetLead, description: "The disk is full.", tail: CompanionErrorCopy.resetTail)
            root = AnyView(DotSettingsView(showsResetFailure: true))
        case "name-appearance-draft":
            size = NSSize(width: 680, height: 470)
            let fixture = CompanionAppearanceFixtureStore()
            fixture.stored = CompanionAppearance(shape: .fold, color: .periwinkle)
            root = AnyView(CompanionAppearancePicker(config: config, store: fixture))
        case "name-not-connected", "name-not-connected-chat":
            size = NSSize(width: 720, height: 360)
            if view == "name-not-connected-chat" { store.newConversation() }
            root = AnyView(EmptyChatView().padding(20))
        case "name-scheduled-paused":
            size = NSSize(width: 1000, height: 520)
            NativeScheduleShotFixture.populate(store, assistantPaused: true)
            CompanionNameShot.apply(to: store)
            store.schedules = store.schedules.filter { $0.owner == .dot } + store.schedules.filter { $0.owner != .dot }
            root = AnyView(ScheduledView(renderSafe: true))
        case "name-saved-report", "name-saved-approval":
            size = NSSize(width: 560, height: view == "name-saved-report" ? 420 : 300)
            CompanionNameShot.apply(to: store)
            let cards = CompanionSavedTextFixture.cards().filter { (card: NativeTaskCardPresentation) -> Bool in
                (card.status == .needsInput) == (view == "name-saved-approval")
            }
            root = AnyView(
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(cards, id: \.id) { (card: NativeTaskCardPresentation) in NativeTaskCardView(card: card, onDecide: { _ in }) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            )
        case "name-saved-scheduled":
            size = NSSize(width: 1000, height: 560)
            NativeScheduleShotFixture.populate(store)
            CompanionNameShot.apply(to: store)
            CompanionSavedTextFixture.scheduleRuns(store)
            store.schedules = store.schedules.filter { $0.owner == .dot } + store.schedules.filter { $0.owner != .dot }
            root = AnyView(ScheduledView(renderSafe: true))
        case "name-saved-library":
            size = NSSize(width: 1000, height: 600)
            CompanionNameShot.apply(to: store)
            let selection = CompanionSavedTextFixture.libraryItems(store)
            root = AnyView(ArtifactsView(initialSelection: selection))
        case "name-library-after-reset":
            size = NSSize(width: 1000, height: 600)
            if let thread = store.veraThreadID { CompanionLibraryKeepFixture.save(store, title: "Vent schedule", conversationID: thread) }
            let kept = store.artifactRecords.first { (record: ArtifactRecord) -> Bool in record.title == "Frost checklist" }?.id
            root = AnyView(ArtifactsView(initialSelection: kept, conversationFilter: store.veraThreadID))
        case "name-panel-after-reset":
            size = NSSize(width: CompanionProfileMetrics.width + 40, height: 700)
            root = AnyView(CompanionThreadPanel(fixed: store.companionOverviewModel()).padding(20).frame(maxHeight: .infinity, alignment: .top))
        case "name-artifacts-filter":
            size = NSSize(width: 1000, height: 600)
            root = AnyView(ArtifactsView(conversationFilter: store.veraThreadID))
        case "name-thread-error":
            size = NSSize(width: 900, height: 620)
            store.section = .vera
            store.openVeraThread()
            store.reportCompanionConfigurationError(CompanionErrorCopy.saveLead, description: "The disk is full.")
            root = AnyView(ChatPane())
        case "name-surfaces-chat":
            size = NSSize(width: 720, height: 360)
            store.newConversation()
            store.reportCompanionConfigurationError(CompanionErrorCopy.saveLead, description: "The disk is full.")
            root = AnyView(EmptyChatView().padding(20))
        default:
            size = NSSize(width: 720, height: 820)
            store.reportCompanionConfigurationError(CompanionErrorCopy.saveLead, description: "The disk is full.")
            root = AnyView(
                VStack(alignment: .leading, spacing: 18) {
                    PreferencesSettingsView()
                    CompanionOpeningView(error: store.companionOpeningErrorLine, retry: {}).frame(height: 90)
                    EmptyChatView().frame(height: 300)
                }
                .padding(20)
            )
        }
        let content = root
            .environmentObject(store).environmentObject(config)
            .environment(\.companionName, store.companionDisplayName)
            .environment(\.companionAppearance, colors)
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
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
