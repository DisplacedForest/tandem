import AppKit
import SwiftUI

@MainActor
enum NativeToolAccessShot {
    static let views: [String: NativeSystemAccess] = [
        "tool-access-granted": .granted, "tool-access-ask": .notAsked, "tool-access-refused": .refused,
    ]

    static func render(view: String, to path: String, appearance: String) {
        guard let state = views[view] else { exit(1) }
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        let size = NSSize(width: 720, height: 220)
        let descriptor = NativeChatToolCatalog.tools(veraAPIConfigured: false, imageConfigured: false, searchConfigured: false, declarations: [])
            .first { $0.id == NativeRemindersTools.toolID }
        let access = NativeToolAccess(subject: "Reminders", settingsPane: nil, state: { state }, request: { false })
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let root = Form {
            Section("Tools") {
                Toggle(isOn: .constant(true)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor?.name ?? "")
                        Text(descriptor?.summary ?? "").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                NativeToolAccessRow(access: access)
            }
        }
        .formStyle(.grouped)
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
        do { try data.write(to: AppLocations.checkedOutput(path)); print("wrote \(path)"); exit(0) }
        catch { exit(1) }
    }
}
