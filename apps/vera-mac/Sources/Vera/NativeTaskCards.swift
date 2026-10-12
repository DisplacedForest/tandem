import SwiftUI
import MarkdownUI

struct NativeTaskCardView: View {
    let card: NativeTaskCardPresentation
    var onCancel: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(card.status.title, systemImage: card.status.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(card.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !card.milestone.isEmpty {
                Text(card.milestone)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = card.connectionNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !card.sources.isEmpty && [.stopped, .needsInput, .failed].contains(card.status) {
                SourcesRow(sources: NativeResearchReportSafety.sources(card.sources))
            }
            if card.canCancel || card.canRetry {
                HStack(spacing: 12) {
                    if card.canRetry { Button("Retry") { onRetry?() }.disabled(onRetry == nil) }
                    if card.canCancel { Button("Stop research") { onCancel?() }.disabled(onCancel == nil) }
                }
                .font(.system(size: 12))
            }
        }
        .padding(14)
        .frame(maxWidth: 480, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct NativeDisplayBlocksView: View {
    let blocks: [NativeDisplayBlock]
    var engineConfigured = true
    var connectedTaskIDs: Set<String>? = nil
    var onCancel: ((String) -> Void)? = nil
    var onRetry: ((String) -> Void)? = nil
    @State private var openReport: NativeResearchArtifact?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .taskCard(let card):
                    NativeTaskCardView(
                        card: displayCard(card),
                        onCancel: connected(card) ? onCancel.map { action in { action(card.id) } } : nil,
                        onRetry: connected(card) ? onRetry.map { action in { action(card.id) } } : nil)
                case .link(let link):
                    if let destination = link.destination {
                        Link(destination: destination) {
                            Label(link.title, systemImage: "link")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(2)
                        }
                        .foregroundStyle(Theme.accent)
                    } else {
                        Text(link.title).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                case .artifact(let artifact):
                    Button { openReport = artifact } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(artifact.title).font(.system(size: 13, weight: .medium)).lineLimit(3)
                                Text("Open report").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(12)
                        .frame(maxWidth: 480, alignment: .leading)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $openReport) { NativeResearchReportView(artifact: $0) }
    }

    private func connected(_ card: NativeTaskCardPresentation) -> Bool {
        engineConfigured && (connectedTaskIDs?.contains(card.id) ?? true)
    }

    private func displayCard(_ card: NativeTaskCardPresentation) -> NativeTaskCardPresentation {
        guard !connected(card) else { return card }
        var saved = card
        saved.canCancel = false
        saved.canRetry = false
        saved.connectionNote = "Saved here. The research engine is disconnected."
        return saved
    }
}

struct NativeResearchReportView: View {
    let artifact: NativeResearchArtifact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(artifact.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CitedProse(text: PulseMarkers.stripSourcesSection(artifact.report), sources: NativeResearchReportSafety.sources(artifact.sources))
                    if !artifact.sources.isEmpty { SourcesRow(sources: NativeResearchReportSafety.sources(artifact.sources)) }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 420, idealHeight: 640)
        .background(Theme.bg)
        .markdownImageProvider(NativeResearchImageProvider())
        .markdownInlineImageProvider(NativeResearchInlineImageProvider())
        .environment(\.openURL, OpenURLAction { url in
            NativeResearchReportSafety.destination(url.absoluteString) == nil ? .discarded : .systemAction
        })
    }
}
