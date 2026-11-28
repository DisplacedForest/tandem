import SwiftUI
import MarkdownUI

struct NativeTaskCardView: View {
    let card: NativeTaskCardPresentation
    var statusTitle: String? = nil
    var stopTitle: String? = nil
    var onCancel: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onDecide: ((String) -> Void)? = nil
    var highlighted = false
    var companionThread = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !companionThread {
            Label { Text(statusTitle ?? card.statusTitle) } icon: { InterfaceIconView(icon: card.statusIcon, size: InterfaceIconSize.small) }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(card.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            }
            if companionThread, card.milestone.isEmpty {
                Text(card.statusTitle).font(.system(size: ConversationMetrics.bodySize))
            }
            if let stop = card.stoppedStep {
                StoppedStepView(stop: stop, why: card.why)
            }
            if !card.milestone.isEmpty, card.stoppedStep == nil, companionThread || !Self.repeatsStatus(card.milestone, status: statusTitle ?? card.statusTitle) {
                CompanionLineText(line: milestoneLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if card.needsYou, card.stoppedStep == nil, let why = card.why {
                RefusalReasonLine(why: why)
            }
            if let answer = card.answer, card.status == .completed, card.stoppedStep == nil {
                let resolved = CitationResolver.resolve(text: answer, sources: NativeResearchReportSafety.sources(card.sources),
                                                        allowRecovery: false)
                CitedText(resolved: resolved, style: .chat)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .safeReportContent()
                if !resolved.sources.isEmpty {
                    SourcesRow(sources: resolved.sources, numbered: false)
                }
            }
            if let details = card.details, !details.isEmpty, card.status == .needsInput {
                let block = Text(plainDetails ? CompanionPermissionText.savedDetails(details, service: card.service?.service) : details)
                    .font(.system(size: companionThread ? 13 : 11, design: plainDetails ? .default : .monospaced))
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
                .accessibilityLabel("Action details: " + (plainDetails ? CompanionPermissionText.savedDetails(details, service: card.service?.service) : details))
            }
            if let note = card.connectionNote.map(SavedWording.current) {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !card.sources.isEmpty,
               [.stopped, .needsInput, .failed].contains(card.status) || (card.status == .completed && !card.isCompanion) {
                SourcesRow(sources: NativeResearchReportSafety.sources(card.sources), numbered: false)
            }
            if isApproval {
                CardAnswerRow(answers: (companionThread || card.isCompanion) && card.service != nil ? CardAnswers() : CardAnswers.task(choices: card.offeredChoices, covers: card.covers, neverTitle: card.neverTitle, service: card.service),
                              allowApprove: onDecide != nil, allowDecline: onDecide != nil,
                              onAllow: { answer(NativeCardChoiceKind.allowOnce.rawValue) },
                              onDecline: { answer(NativeCardChoiceKind.decline.rawValue) },
                              onItem: { answer($0) }, onConfirmed: { _, confirmed in answer(NativeCardChoices.confirmedWire(confirmed)) })
                    .id(card.details ?? card.id)
            } else if let question = CardQuestion.make(choices: card.offeredChoices,
                                                       stop: card.canCancel && onCancel != nil ? (stopTitle ?? card.stopTitle) : nil,
                                                       answerable: canAnswer) {
                if let decline = question.decline {
                    CardAnswerRow(answers: question.answers, defaultApproval: false, even: question.even,
                                  onAllow: { answer(question.allow) }, onDecline: { answer(decline) }, onItem: { answer($0) })
                } else {
                    Button(question.answers.allowTitle) { answer(question.allow) }
                        .buttonStyle(ConversationButtonStyle(kind: .secondary))
                        .accessibilityLabel("\(question.answers.allowTitle), answer for \(card.title)")
                }
            } else if card.canCancel {
                Button(stopTitle ?? card.stopTitle) { onCancel?() }.disabled(onCancel == nil)
                    .buttonStyle(ConversationButtonStyle(kind: .secondary))
            }
        }
        .padding(14)
        .frame(maxWidth: 480, alignment: .leading)
        .background(companionThread ? Theme.assistantBubble : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: companionThread ? ConversationMetrics.bubbleRadius : 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(highlighted ? Theme.sage : Theme.hairline, lineWidth: highlighted ? 2 : 1))
        .animation(.easeOut(duration: 0.3), value: highlighted)
    }

    static func repeatsStatus(_ line: String, status: String) -> Bool {
        func plain(_ text: String) -> String {
            var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix(".") { value.removeLast() }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return plain(line) == plain(status)
    }

    private var plainDetails: Bool { companionThread || card.isCompanion || card.service != nil }

    private var milestoneLine: CompanionLine {
        if plainDetails, isApproval, let service = card.service {
            return .literal(CompanionPermissionText.question(service: service.service, action: service.tool, details: card.details))
        }
        return card.milestoneLine
    }

    private var isApproval: Bool {
        card.status == .needsInput && card.offeredChoices.contains(NativeCardChoiceKind.allowOnce.rawValue)
            && card.offeredChoices.contains(NativeCardChoiceKind.decline.rawValue)
    }

    private func canAnswer(_ choice: String) -> Bool {
        onDecide != nil || (choice == "retry" && onRetry != nil)
    }

    private func answer(_ id: String) {
        switch CardQuestion.route(id) {
        case .stop: onCancel?()
        case .answer(let choice): if let onDecide { onDecide(choice) } else if choice == "retry" { onRetry?() }
        }
    }
}

struct NativeDisplayBlocksView: View {
    let blocks: [NativeDisplayBlock]
    var companionThread = false
    var engineConfigured = true
    var connectedTaskIDs: Set<String>? = nil
    var onCancel: ((String) -> Void)? = nil
    var onRetry: ((String) -> Void)? = nil
    var onDecide: ((String, String) -> Void)? = nil
    var highlightedTaskID: String? = nil
    var onRuleOffer: ((String, RuleOfferAnswer, ServiceAllowConfirmed?) -> Void)? = nil
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
                        highlighted: highlightedTaskID == card.id,
                        companionThread: companionThread)
                case .link(let link):
                    if let destination = link.destination {
                        Link(destination: destination) {
                            Label { Text(link.title) } icon: { InterfaceIconView(icon: .link, size: InterfaceIconSize.regular) }
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
                case .ruleOffer(let offer):
                    RuleOfferCard(offer: offer, onAnswer: onRuleOffer.map { action in { action(block.id, $0, $1) } })
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
        saved.choices = []
        saved.connectionNote = "Saved here. This continues once it reconnects."
        return saved
    }
}

struct NativeResearchReportView: View {
    let artifact: NativeResearchArtifact
    @Environment(\.dismiss) private var dismiss

    var resolved: ResolvedCitations {
        CitationResolver.resolve(text: artifact.report,
                                 sources: artifact.sources.isEmpty ? [] : NativeResearchReportSafety.sources(artifact.sources),
                                 allowRecovery: false)
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

extension NativeTaskCardPresentation {
    var milestoneLine: CompanionLine {
        CompanionSavedText.line(milestone, appWritten: isCompanion && status == .needsInput)
    }
}
