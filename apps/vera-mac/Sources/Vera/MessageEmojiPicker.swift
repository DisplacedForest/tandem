import SwiftUI
import AppKit

struct MessageEmojiPickerHost: View {
    @EnvironmentObject private var store: ChatStore
    let model: MessageActionsModel

    var body: some View {
        MessageEmojiReceiver(active: model.picking != nil, onEmoji: picked, onText: typed, onEnd: ended, onCancel: cancelled)
            .frame(width: 1, height: 1)
            .offset(x: model.pickingAt.x, y: model.pickingAt.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func picked(_ emoji: String) {
        let target = model.picking
        model.endPicking()
        if let target, target.current(in: store.conversations) != nil {
            store.toggleReaction(emoji, on: target.messageID)
        }
        store.focusTick &+= 1
    }

    private func typed(_ text: String) {
        model.endPicking()
        store.draft += text
        store.focusTick &+= 1
    }

    private func ended() {
        model.endPicking()
    }

    private func cancelled() {
        model.endPicking()
        store.focusTick &+= 1
    }
}

struct MessageEmojiReceiver: NSViewRepresentable {
    let active: Bool
    let onEmoji: (String) -> Void
    let onText: (String) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void

    final class ReceiverView: NSTextView {
        var onEmoji: (String) -> Void = { _ in }
        var onText: (String) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onCancel: () -> Void = {}
        private(set) var armed = false
        var wanted = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func arm() {
            guard !armed, let window else { onEnd(); return }
            armed = true
            string = ""
            guard window.makeFirstResponder(self) else {
                armed = false
                onEnd()
                return
            }
            NSApp.orderFrontCharacterPalette(nil)
        }

        func disarm() {
            guard armed else { return }
            armed = false
            string = ""
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }

        private func settle() {
            armed = false
            string = ""
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }

        override func insertText(_ string: Any, replacementRange: NSRange) {
            let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
            guard armed, !text.isEmpty else { return }
            settle()
            if let emoji = MessageReaction.emoji(in: text) {
                onEmoji(emoji)
            } else {
                onText(text)
            }
        }

        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}

        override func doCommand(by selector: Selector) {
            guard armed else { return }
            settle()
            onCancel()
        }

        override func cancelOperation(_ sender: Any?) {
            doCommand(by: #selector(cancelOperation(_:)))
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned, armed {
                armed = false
                string = ""
                let end = onEnd
                DispatchQueue.main.async { end() }
            }
            return resigned
        }
    }

    func makeNSView(context: Context) -> ReceiverView {
        let view = ReceiverView(usingTextLayoutManager: false)
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.alphaValue = 0
        view.setAccessibilityElement(false)
        apply(view)
        return view
    }

    func updateNSView(_ view: ReceiverView, context: Context) {
        apply(view)
        view.wanted = active
        if active, !view.armed {
            DispatchQueue.main.async { if view.wanted, !view.armed { view.arm() } }
        } else if !active, view.armed {
            view.disarm()
        }
    }

    private func apply(_ view: ReceiverView) {
        view.onEmoji = onEmoji
        view.onText = onText
        view.onEnd = onEnd
        view.onCancel = onCancel
    }
}
