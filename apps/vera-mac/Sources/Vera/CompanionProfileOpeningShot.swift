import AppKit
import SwiftUI

@MainActor
final class CompanionProfileOpeningState: ObservableObject {
    @Published var profile = CompanionProfileState(launchedAt: Date())
}

private struct CompanionProfileOpeningHost: View {
    @ObservedObject var state: CompanionProfileOpeningState
    let model: CompanionOverviewModel

    var body: some View {
        CompanionProfileLayout(state: $state.profile, fixed: model) { Theme.conversationBackground }
    }
}

@MainActor
enum CompanionProfileOpeningShot {
    static let views: Set<String> = ["companion-profile-opening", "companion-profile-opening-short", "companion-profile-closing"]

    static func render(view: String, to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: try? LocalChatRepository(inMemory: true))
        NativeDotShotFixture.populate(store, paused: false, setupCompleted: true)
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        let state = CompanionProfileOpeningState()
        let size = NSSize(width: 900, height: view.hasSuffix("short") ? 380 : 760)
        let hosting = NSHostingView(rootView: CompanionProfileOpeningHost(state: state, model: CompanionOverviewFixture.profileModel(name: store.companion.leading))
            .environmentObject(store).environmentObject(config)
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height).background(Theme.bg))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if view == "companion-profile-closing" {
            state.profile.open()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            withAnimation(.easeOut(duration: 1.2)) { state.profile.close(now: Date()) }
        } else {
            withAnimation(.easeOut(duration: 1.2)) { state.profile.open() }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: AppLocations.checkedOutput(path)); print("Rendered profile transition"); exit(0) }
        catch { exit(1) }
    }
}
