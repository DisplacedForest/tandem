import AppKit
import SwiftUI

@MainActor
enum TypingDotsShot {
    static let views: Set<String> = ["typing-dots-bubble", "typing-dots-plain"]

    static func render(view: String, to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        let size = NSSize(width: 760, height: 260)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typing-dots-shot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil,
                              attachmentStore: NativeAttachmentStore(directory: directory))
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        let companion = view == "typing-dots-bubble"
        let messages = [
            Message(role: .user, text: "How cold does it get tonight?"),
            Message(role: .assistant, text: "", state: .streaming),
        ]
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: VStack(alignment: .leading, spacing: 22) {
            ForEach(messages) { message in
                MessageRow(message: message, companionThread: companion)
            }
            Spacer(minLength: 0)
        }
            .padding(28)
            .frame(maxWidth: ConversationMetrics.columnWidth, alignment: .leading)
            .frame(width: size.width, height: size.height)
            .environmentObject(store).environmentObject(config)
            .background(Theme.conversationBackground).environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: AppLocations.checkedOutput(path)); print("Rendered typing dots") }
        catch { exit(1) }
    }
}
