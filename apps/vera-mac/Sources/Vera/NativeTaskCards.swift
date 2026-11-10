import SwiftUI
import MarkdownUI

struct NativeTaskCardView: View {
    let card: NativeTaskCardPresentation
    var statusTitle: String? = nil
    var stopTitle: String? = nil
    var onCancel: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onDecide: ((String) -> Void)? = nil
    var onSaveAnswer: (() -> Void)? = nil
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
                CompanionNamedText(template: card.milestone)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let answer = card.answer, card.status == .completed {
                let resolved = CitationResolver.resolve(text: answer, sources: NativeResearchReportSafety.sources(card.sources),
                                                        allowRecovery: true)
                CitedText(resolved: resolved, style: .chat)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .safeReportContent()
                if !resolved.sources.isEmpty {
                    SourcesRow(sources: resolved.sources, numbered: false)
                }
            }
            if let details = card.details, !details.isEmpty, card.status == .needsInput {
                let block = Text(details)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                Group {
                    if details.count > 700 || details.split(separator: "\n").count > 10 {
                        ScrollView { block }.frame(height: 220)
                    } else {
                        block
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.bg))
                .accessibilityLabel("Action details: " + details)
            }
            if let note = card.connectionNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !card.sources.isEmpty && [.stopped, .needsInput, .failed].contains(card.status) {
                SourcesRow(sources: NativeResearchReportSafety.sources(card.sources))
            }
            if !card.sources.isEmpty && card.status == .completed && !card.isCompanion {
                SourcesRow(sources: NativeResearchReportSafety.sources(card.sources), numbered: false)
            }
            if let onSaveAnswer, card.answer != nil, card.status == .completed {
                Button("Save as document") { onSaveAnswer() }
                    .buttonStyle(.bordered)
                    .font(.system(size: 12))
                    .accessibilityLabel("Save as document, \(card.title)")
            }
            if isApproval {
                CardAnswerRow(answers: CardAnswers.task(choices: card.offeredChoices, covers: card.covers, neverTitle: card.neverTitle),
                              allowApprove: onDecide != nil, allowDecline: onDecide != nil,
                              onAllow: { answer(NativeCardChoiceKind.allowOnce.rawValue) },
                              onDecline: { answer(NativeCardChoiceKind.decline.rawValue) },
                              onItem: { answer($0) })
            } else if card.canCancel || !card.offeredChoices.isEmpty {
                HStack(spacing: 12) {
                    ForEach(card.offeredChoices, id: \.self) { choice in
                        if let title = NativeTaskCardPresentation.choiceTitle(choice) {
                            Button(title) { answer(choice) }
                                .buttonStyle(.bordered)
                                .disabled(!canAnswer(choice))
                                .accessibilityLabel("\(title), answer for \(card.title)")
                        }
                    }
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

    private var isApproval: Bool {
        card.status == .needsInput && card.offeredChoices.contains(NativeCardChoiceKind.allowOnce.rawValue)
            && card.offeredChoices.contains(NativeCardChoiceKind.decline.rawValue)
    }

    private func canAnswer(_ choice: String) -> Bool {
        onDecide != nil || (choice == "retry" && onRetry != nil)
    }

    private func answer(_ choice: String) {
        if let onDecide { onDecide(choice) } else if choice == "retry" { onRetry?() }
    }
}

struct NativeDisplayBlocksView: View {
    let blocks: [NativeDisplayBlock]
    var engineConfigured = true
    var connectedTaskIDs: Set<String>? = nil
    var onCancel: ((String) -> Void)? = nil
    var onRetry: ((String) -> Void)? = nil
    var onDecide: ((String, String) -> Void)? = nil
    var onSaveAnswer: ((String) -> Void)? = nil
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
                        onDecide: connected(card) ? onDecide.map { action in { action(card.id, $0) } } : nil,
                        onSaveAnswer: saved(card) ? nil : onSaveAnswer.map { action in { action(card.id) } },
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

    private func saved(_ card: NativeTaskCardPresentation) -> Bool { Self.answerSaved(card, in: blocks) }

    static func answerSaved(_ card: NativeTaskCardPresentation, in blocks: [NativeDisplayBlock]) -> Bool {
        blocks.contains { $0.id == "artifact:" + card.id }
    }

    private func connected(_ card: NativeTaskCardPresentation) -> Bool {
        engineConfigured && (connectedTaskIDs?.contains(card.id) ?? true)
    }

    private func displayCard(_ card: NativeTaskCardPresentation) -> NativeTaskCardPresentation {
        guard !connected(card) else { return card }
        var saved = card
        saved.canCancel = false
        saved.canRetry = false
        saved.choices = []
        saved.connectionNote = "Saved here. Background work is disconnected."
        return saved
    }
}

struct NativeResearchReportView: View {
    let artifact: NativeResearchArtifact
    @Environment(\.dismiss) private var dismiss

    var resolved: ResolvedCitations {
        CitationResolver.resolve(text: artifact.report,
                                 sources: artifact.sources.isEmpty ? [] : NativeResearchReportSafety.sources(artifact.sources),
                                 allowRecovery: true)
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
                let resolved = self.resolved
                VStack(alignment: .leading, spacing: 18) {
                    CitedText(resolved: resolved, style: .document)
                    if !resolved.sources.isEmpty {
                        SourcesRow(sources: resolved.sources, numbered: false)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 420, idealHeight: 640)
        .background(Theme.bg)
        .safeReportContent()
    }
}

extension View {
    func safeReportContent() -> some View {
        markdownImageProvider(NativeResearchImageProvider())
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
