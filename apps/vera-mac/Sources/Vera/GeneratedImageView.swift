import SwiftUI
import AppKit

struct GeneratedImageView: View {
    let attachment: MessageAttachment
    var store: NativeAttachmentStore? = nil
    @State private var image: NSImage?
    @State private var missing = false

    private var fileURL: URL? {
        guard let store, let fileName = attachment.fileName else { return nil }
        return store.url(for: fileName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if missing {
                    Label("This image is no longer on disk", systemImage: "photo")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Skeleton().frame(height: 240)
                }
            }
            .frame(maxWidth: 480)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .accessibilityLabel(attachment.name)
            if image != nil, let fileURL {
                HStack(spacing: 14) {
                    Button("Open") { NSWorkspace.shared.open(fileURL) }
                    Button("Save") { save(fileURL) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            }
        }
        .task(id: attachment.id) {
            guard let store, let fileName = attachment.fileName, let loaded = store.image(for: fileName) else {
                missing = true
                return
            }
            image = loaded
        }
    }

    private func save(_ source: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.resolvingSymlinksInPath() != source.resolvingSymlinksInPath() else { return }
        do {
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try FileManager.default.copyItem(at: source, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "The image couldn't be saved"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
