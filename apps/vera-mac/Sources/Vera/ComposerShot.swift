import AppKit
import SwiftUI

@MainActor
enum ComposerShot {
    static func render(view: String, to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        let size = NSSize(width: view.hasSuffix("narrow") ? 380 : 1000, height: view.contains("project") ? 620 : 320)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("composer-shot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil,
                              attachmentStore: NativeAttachmentStore(directory: directory))
        store.newConversation()
        if view.contains("project") {
            let project = ProjectRecord(id: "garden", name: "Spring garden", instructions: "", grants: [], files: [], createdAt: Date(), updatedAt: Date())
            store.projects = [project]
            store.newConversation(inProject: project.id)
        }
        if view.contains("multiline") {
            store.draft = "Compare the two plans.\nInclude the materials, timing and tradeoffs.\nKeep the final recommendation brief."
        }
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: Group {
            if view.contains("project-empty") { EmptyChatView() }
            else { ComposerField() }
        }
            .environmentObject(store).environmentObject(config)
            .padding(24).frame(width: size.width, height: size.height)
            .background(Theme.conversationBackground).environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        if let editor = window.firstResponder as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: path)); print("Rendered composer") }
        catch { exit(1) }
    }
}
