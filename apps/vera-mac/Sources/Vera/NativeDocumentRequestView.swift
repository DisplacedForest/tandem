import SwiftUI
import VeraAssistantUI

struct NativeDocumentRequestView: View {
    @ObservedObject var session: AssistantSession
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var brief = ""
    @State private var inputs = ""
    private var valid: Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.unicodeScalars.count <= 200 && !title.contains("\n") && !title.contains("\r")
            && !brief.isEmpty && brief.unicodeScalars.count <= 2000 && inputs.unicodeScalars.count <= 2000
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create document").font(.title2)
            Text("Vera drafts and revises a Markdown document from your brief and notes. You can keep chatting while it works.")
                .foregroundStyle(.secondary)
            TextField("Title", text: $title).accessibilityLabel("Document title")
            Text("What should the document cover?")
            TextEditor(text: $brief).frame(height: 110).accessibilityLabel("Document brief")
            Text("Notes to include (optional)")
            TextEditor(text: $inputs).frame(height: 110).accessibilityLabel("Document notes")
            Text("Up to 200 characters for the title and 2,000 each for the brief and notes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let title = title, brief = brief, inputs = inputs
                    dismiss()
                    Task { await session.createDocument(title: title, brief: brief, inputs: inputs) }
                }.disabled(!valid || !session.canCreateDocument).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
    }
}
