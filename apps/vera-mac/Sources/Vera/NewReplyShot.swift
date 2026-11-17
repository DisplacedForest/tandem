import AppKit
import SwiftUI

@MainActor
enum NewReplyShot {
    static let views: Set<String> = ["new-reply-marker", "new-reply-marker-two", "new-reply-marker-narrow", "new-reply-marker-two-narrow"]

    static func render(view: String, to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        let size = NSSize(width: view.hasSuffix("narrow") ? 640 : 1000, height: 760)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("new-reply-shot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil,
                              attachmentStore: NativeAttachmentStore(directory: directory))
        store.newConversation()
        let count = view.contains("two") ? 2 : 1
        let messages = [
            Message(role: .user, text: "Write up a comparison of insulation options for the workshop."),
            Message(role: .assistant, text: "I'll write that up. We can keep talking here."),
            Message(role: .user, text: "While that's running, how should I measure the walls?"),
            Message(role: .assistant, text: """
            Start with the wall lengths and the ceiling height, then note every door and window separately.

            Measure each wall at the floor and again at the ceiling, since older walls are rarely square. Write the larger number down.

            For each opening, record the width, the height and how far it sits from the nearest corner, so the insulation can be cut around it.

            Then add up the wall areas and take the openings away. That number, plus about ten percent for offcuts, is what to buy.

            If any wall has pipes or wiring running through it, mark where they are before you start, so nothing gets cut by mistake.

            Keep the notes in one place. The comparison will use the same numbers when it's ready.
            """),
        ]
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(messages) { message in
                        MessageRow(message: message, companionThread: false)
                    }
                }
                .padding(28)
                .frame(maxWidth: ConversationMetrics.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(true)
            .overlay(alignment: .bottom) {
                NewReplyMarker(count: count) {}.padding(.bottom, 8)
            }
            ComposerField().padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
                .frame(maxWidth: ConversationMetrics.columnWidth)
        }
            .environmentObject(store).environmentObject(config)
            .frame(width: size.width, height: size.height)
            .background(Theme.conversationBackground).environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: AppLocations.checkedOutput(path)); print("Rendered new reply marker") }
        catch { exit(1) }
    }
}
