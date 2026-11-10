import AppKit
import SwiftUI

@MainActor
enum CompanionNameShot {
    static let views: Set<String> = ["companion-name-prompt"]

    static let variable = "TANDEM_SHOT_COMPANION"
    static let sampleName = NativeDotShotFixture.name

    static func name(environment: [String: String]) -> String? {
        guard let value = environment[variable] else { return sampleName }
        return value == "none" ? nil : CompanionSubject(value).name ?? sampleName
    }

    static func apply(to store: ChatStore, environment: [String: String] = ProcessInfo.processInfo.environment) {
        store.adoptAssistantName(name(environment: environment))
    }

    static func render(to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        let size = NSSize(width: 520, height: 300)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil)
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let root = CompanionNamePrompt()
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
            .environmentObject(store).environmentObject(config)
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
            .background(Theme.bg)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: path)); print("wrote \(path)"); exit(0) }
        catch { exit(1) }
    }
}
