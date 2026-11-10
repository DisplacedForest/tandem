import AppKit
import SwiftUI

@MainActor
enum RulesShot {
    static func render(view: String, to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" && view != "rules-dark" ? .light : .dark
        let showsHelp = view == "rules-info" || view == "rules-unnamed"
        let companion: String? = view == "rules-unnamed" ? nil : "Ada"
        let size = NSSize(width: showsHelp ? 1240 : 860, height: 980)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rules-shot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil,
                              attachmentStore: NativeAttachmentStore(directory: directory))
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let root = HStack(alignment: .top, spacing: 16) {
            RulesSettingsTab().frame(width: 860, height: 980)
            if showsHelp {
                RulesChoiceHelp()
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
            }
        }
        .environmentObject(store).environmentObject(config)
        .environment(\.companionName, companion)
        .environment(\.companionAppearance, CompanionAppearance(shape: .pebble, color: .apricot))
        .environment(\.colorScheme, scheme)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
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
