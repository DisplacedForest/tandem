import SwiftUI
import MarkdownUI

struct NativeTaskCardView: View {
    let card: NativeTaskCardPresentation
    var statusTitle: String? = nil
    var stopTitle: String? = nil
    var onCancel: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(statusTitle ?? card.statusTitle, systemImage: card.statusSymbol)
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
                    if card.canCancel { Button(stopTitle ?? card.stopTitle) { onCancel?() }.disabled(onCancel == nil) }
                }
                .font(.system(size: 12))
            }
        }
        .padding(14)
        .frame(maxWidth: 480, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(highlighted ? Theme.sage : Theme.hairline, lineWidth: highlighted ? 2 : 1))
        .animation(.easeOut(duration: 0.3), value: highlighted)
    }
}

struct NativeDisplayBlocksView: View {
    let blocks: [NativeDisplayBlock]
    var engineConfigured = true
    var connectedTaskIDs: Set<String>? = nil
    var onCancel: ((String) -> Void)? = nil
    var onRetry: ((String) -> Void)? = nil
    var highlightedTaskID: String? = nil
    @State private var openReport: NativeResearchArtifact?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .taskCard(let card):
                    NativeTaskCardView(
                        card: displayCard(card),
                        onCancel: connected(card) ? onCancel.map { action in { action(card.id) } } : nil,
                        onRetry: connected(card) ? onRetry.map { action in { action(card.id) } } : nil,
                        highlighted: highlightedTaskID == card.id)
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
                case .fileChange(let change):
                    NativeFileChangeCard(change: change)
                case .commandRun(let run):
                    NativeCommandRunCard(run: run)
                case .artifact(let artifact):
                    Button { openReport = artifact } label: {
                        ConversationResultRow(title: artifact.title, action: artifact.openTitle)
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
        saved.connectionNote = "Saved here. Background work is disconnected."
        return saved
    }
}

struct NativeResearchReportView: View {
    let artifact: NativeResearchArtifact
    @Environment(\.dismiss) private var dismiss

    var reportText: String {
        artifact.sources.isEmpty ? artifact.report : PulseMarkers.stripSourcesSection(artifact.report)
    }

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
                    if artifact.sources.isEmpty {
                        NativeArtifactMarkdown(text: reportText).equatable()
                    } else {
                        CitedProse(text: reportText, sources: NativeResearchReportSafety.sources(artifact.sources))
                        SourcesRow(sources: NativeResearchReportSafety.sources(artifact.sources))
                    }
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

struct NativeArtifactMarkdown: View, Equatable {
    let text: String
    private static let theme = MarkdownUI.Theme.basic
        .text { ForegroundColor(Theme.textPrimary); FontSize(14) }
        .code { FontFamilyVariant(.monospaced); BackgroundColor(Theme.surface) }
        .link { ForegroundColor(Theme.accent) }

    var content: MarkdownContent { MarkdownContent(text) }

    var body: some View {
        Markdown(content)
            .markdownTheme(Self.theme)
            .textSelection(.enabled)
    }
}
