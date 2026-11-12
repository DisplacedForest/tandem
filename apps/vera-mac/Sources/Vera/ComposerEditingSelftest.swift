import AppKit
import SwiftUI

@MainActor
private final class ComposerEditingDraft: ObservableObject {
    @Published var text = "alpha beta gamma"
}

private struct ComposerEditingField: View {
    @ObservedObject var draft: ComposerEditingDraft

    var body: some View {
        TextField("Message", text: $draft.text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .frame(width: 320)
    }
}

@MainActor
extension SelfTest {
    private static func composerEditor(_ text: String, selected: NSRange) -> NSTextView {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        editor.allowsUndo = true
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.makeFirstResponder(editor)
        editor.string = text
        editor.setSelectedRange(selected)
        return editor
    }

    private static func composerControl(in view: NSView) -> NSView? {
        if view is NSTextField || view is NSTextView { return view }
        for child in view.subviews {
            if let found = composerControl(in: child) { return found }
        }
        return nil
    }

    static func runComposerEditing() throws {
        let require = NativeTaskFixture.require

        let middle = composerEditor("alpha beta gamma", selected: NSRange(location: 5, length: 0))
        try require(ComposerEditing.newline(in: middle), "A new line is inserted when a message is being edited")
        try require(middle.string == "alpha\n beta gamma", "The new line lands at the caret, not at the end")
        try require(middle.selectedRange() == NSRange(location: 6, length: 0), "The caret sits right after the new line")
        middle.insertText("x", replacementRange: middle.selectedRange())
        try require(middle.string == "alpha\nx beta gamma", "Typing continues where the new line was put")

        let start = composerEditor("alpha", selected: NSRange(location: 0, length: 0))
        _ = ComposerEditing.newline(in: start)
        try require(start.string == "\nalpha", "A new line can be put at the start")

        let end = composerEditor("alpha", selected: NSRange(location: 5, length: 0))
        _ = ComposerEditing.newline(in: end)
        try require(end.string == "alpha\n", "A new line can be put at the end")

        let lines = composerEditor("one two\nthree four", selected: NSRange(location: 4, length: 9))
        _ = ComposerEditing.newline(in: lines)
        try require(lines.string == "one \n four", "A selection across lines is replaced by one new line")
        try require(lines.selectedRange() == NSRange(location: 5, length: 0), "The caret follows the replaced selection")

        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let accented = "e\u{301}"
        let mixed = composerEditor(family + accented, selected: NSRange(location: family.utf16.count, length: 0))
        _ = ComposerEditing.newline(in: mixed)
        try require(mixed.string == family + "\n" + accented, "Emoji and composed characters stay whole on both sides")

        let undone = composerEditor("alpha beta", selected: NSRange(location: 5, length: 0))
        _ = ComposerEditing.newline(in: undone)
        try require(undone.undoManager != nil, "The message text has native undo")
        undone.undoManager?.undo()
        try require(undone.string == "alpha beta", "Undo takes the new line back out")
        undone.undoManager?.redo()
        try require(undone.string == "alpha\n beta", "Redo puts it back in the same place")

        let composing = composerEditor("alpha", selected: NSRange(location: 5, length: 0))
        composing.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 5, length: 0))
        try require(ComposerEditing.composing(composing), "Text being composed by an input method is noticed")
        try require(!ComposerEditing.newline(in: composing) && !composing.string.contains("\n"),
                    "No new line is forced in while an input method is composing")
        try require(!ComposerEditing.composing(middle) && !ComposerEditing.composing(nil), "Ordinary text is not treated as composing")
        try require(!ComposerEditing.newline(in: nil), "With nothing being edited, nothing is inserted")

        let draft = ComposerEditingDraft()
        let hosting = NSHostingView(rootView: ComposerEditingField(draft: draft))
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 200)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let control = composerControl(in: hosting) else {
            throw NSError(domain: "selftest", code: 1, userInfo: [NSLocalizedDescriptionKey: "The message field has no native text control"])
        }
        window.makeFirstResponder(control)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let live = window.firstResponder as? NSTextView
        try require(live != nil, "The message field is edited through a native text view")
        live?.setSelectedRange(NSRange(location: 5, length: 0))
        try require(ComposerEditing.newline(in: live), "The message field accepts the new line")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try require(draft.text == "alpha\n beta gamma", "The draft gets the new line at the caret")
        live?.insertText("x", replacementRange: live?.selectedRange() ?? NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try require(draft.text == "alpha\nx beta gamma", "Typing after it continues at the caret in the draft")
        print("  composer editing OK (caret, selection, composed characters, undo, input method, live field)")
    }
}
