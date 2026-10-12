import AppKit
import SwiftUI

@MainActor
enum RenderTest {
    static func render(_ store: PrototypeStore, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        for (name, panel, width, scheme) in [
            ("activity-dark", SidePanel.activity, 1140.0, ColorScheme.dark),
            ("outputs-light", SidePanel.outputs, 1140.0, ColorScheme.light),
            ("computers-narrow", SidePanel.computers, 860.0, ColorScheme.dark)
        ] {
            store.panel = panel
            NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let content = PrototypeView(store: store).frame(width: width, height: 760)
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 760)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            try PrototypeSelfTest.require(!window.isVisible, "Offscreen render must not show a window")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw PrototypeError.invalidResponse }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PrototypeError.invalidResponse }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
            window.contentView = nil
        }
        print("PASS: offscreen dark, light and narrow layouts; no visible windows")
    }
}
