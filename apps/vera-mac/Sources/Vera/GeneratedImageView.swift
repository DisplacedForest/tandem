import SwiftUI
import AppKit

struct GeneratedImageView: View {
    let attachment: MessageAttachment
    var store: NativeAttachmentStore? = nil
    @Environment(\.renderSafe) private var renderSafe
    @State private var image: NSImage?
    @State private var missing = false
    @State private var exportNotice: ArtifactExportNotice?
    @State private var noticeDismissal: Task<Void, Never>?

    init(attachment: MessageAttachment, store: NativeAttachmentStore? = nil, initialNotice: ArtifactExportNotice? = nil) {
        self.attachment = attachment
        self.store = store
        _exportNotice = State(initialValue: initialNotice)
    }

    private var fileURL: URL? {
        guard let store, let fileName = attachment.fileName else { return nil }
        return store.url(for: fileName)
    }

    private var shownImage: NSImage? {
        if let image { return image }
        guard renderSafe, let store, let fileName = attachment.fileName else { return nil }
        return store.image(for: fileName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let image = shownImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if missing {
                    Label { Text("This image is no longer on disk") } icon: { InterfaceIconView(icon: .image, size: InterfaceIconSize.small) }
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
            if shownImage != nil, let fileURL {
                HStack(spacing: 14) {
                    if renderSafe {
                        ForEach(["Open", "Save", "Show in Finder"], id: \.self) { Text($0) }
                    } else {
                        Button("Open") { NSWorkspace.shared.open(fileURL) }
                        Button("Save") { save(fileURL) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
                if let exportNotice {
                    ArtifactExportStrip(
                        notice: exportNotice, renderSafe: renderSafe,
                        chooseAnother: { chooseAnotherLocation() }, dismiss: { dismissNotice() })
                        .frame(maxWidth: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
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

    private var exportFlow: ArtifactExportFlow {
        ArtifactExportFlow(
            exporter: ArtifactExporter(),
            choose: { fileName, directory in Self.chooseDestination(fileName: fileName, directory: directory) })
    }

    private static func chooseDestination(fileName: String, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func save(_ source: URL) {
        guard let notice = exportFlow.begin(file: source, title: attachment.name, fileName: attachment.name) else { return }
        show(notice)
    }

    private func chooseAnotherLocation() {
        guard let attempt = exportNotice?.attempt,
              let notice = exportFlow.chooseAnother(attempt) else { return }
        show(notice)
    }

    private func dismissNotice() {
        noticeDismissal?.cancel()
        noticeDismissal = nil
        exportNotice = nil
    }

    private func show(_ notice: ArtifactExportNotice) {
        noticeDismissal?.cancel()
        noticeDismissal = nil
        exportNotice = notice
        guard !renderSafe else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: notice.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        guard notice.isSaved else { return }
        noticeDismissal = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, exportNotice == notice else { return }
            exportNotice = nil
            noticeDismissal = nil
        }
    }
}
