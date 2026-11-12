import AppKit

@MainActor
enum ComposerEditing {
    static var editor: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }

    static func composing(_ editor: NSTextView?) -> Bool { editor?.hasMarkedText() ?? false }

    static func newline(in editor: NSTextView?) -> Bool {
        guard let editor, editor.isEditable, !editor.hasMarkedText() else { return false }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
    }
}
