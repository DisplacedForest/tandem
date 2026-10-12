import AppKit
import SwiftUI

@MainActor
enum NativeSessionShot {
    static func render(view: String, to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        let mode: NativeSessionMode = view.contains("continuous") ? .continuous : .chat
        let size = NSSize(width: view.hasSuffix("narrow") ? 600 : 900, height: 650)
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: NativeSessionShotSurface(mode: mode)
            .frame(width: size.width, height: size.height).background(Theme.bg).environment(\.colorScheme, scheme))
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
        do { try data.write(to: URL(fileURLWithPath: path)); print("Rendered session controls") }
        catch { exit(1) }
    }
}

struct NativeSessionShotSurface: View {
    let mode: NativeSessionMode
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("A conversation with Vera").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Text("Can you check the match report?")
                .padding(12).background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .trailing)
            NativeAnswerControls(status: "Checking the match report", canStop: true, onStop: {})
            Text("What can I make from the food in my fridge?")
                .padding(12).background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .trailing)
            if mode == .chat {
                NativeAnswerControls(status: "Waiting to answer", canStop: true, onStop: {})
            } else {
                Text("Tell me what you have, or attach a photo of the shelves. I can suggest a few meals.")
                    .font(.system(size: 14)).foregroundStyle(Theme.textPrimary)
                NativeTaskCardView(card: NativeTaskCardPresentation(id: "sample-research", title: "Compare workshop insulation",
                    status: .working, milestone: "Checking the remaining sources.", canCancel: true),
                    onCancel: {}, onRetry: {})
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 12) {
                Text("Message Vera…").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            }
            .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(30)
    }
}
