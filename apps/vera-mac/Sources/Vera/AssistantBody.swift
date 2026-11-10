import SwiftUI
import AppKit
import MarkdownUI

struct AssistantBody: View {
    enum Section { case bubble, extras, actions }

    @EnvironmentObject var store: ChatStore
    let message: Message
    var section: Section = .bubble
    var companionThread = false
    var nativeActions = true
    var onAnswer: ((UUID, [String], String) -> Void)? = nil
    var onOpenArtifact: ((Artifact) -> Void)? = nil

    var body: some View {
        switch section {
        case .bubble:
            if let card = message.pulse {
                PulseArticleView(card: card, apiBase: store.mediaBase)
            } else {
                bubble
            }
        case .extras:
            if message.pulse == nil { extras }
        case .actions:
            if message.pulse == nil { actions }
        }
    }

    private var parsed: (clean: String, calls: [ToolCall]) { ToolCallParser.parse(message.text) }

    private struct ReplyCitations {
        let body: String
        let sources: [PulseSource]
    }

    private func replyCitations(_ clean: String) -> ReplyCitations? {
        if !message.sources.isEmpty {
            return ReplyCitations(body: CitationResolver.withoutMatchingList(clean, sources: message.sources), sources: message.sources)
        }
        let allowRecovery = message.state != .streaming
        guard allowRecovery, let recovered = CitationResolver.recover(clean) else { return nil }
        return ReplyCitations(body: recovered.body, sources: recovered.sources)
    }

    @ViewBuilder private var bubble: some View {
        let clean = parsed.clean
        let cited = replyCitations(clean)
        let display = cited?.body ?? clean
        if !display.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(VeraBlocks.segments(display)) { seg in
                    switch seg {
                    case .prose(_, let t):
                        if let cited { CitedText(text: t, sources: cited.sources, style: .chat, allowRecovery: false) }
                        else { ProseMarkdown(text: t) }
                    case .chart(_, let spec): ChartBlockView(spec: spec)
                    case .stats(_, let cards): StatCardsView(cards: cards)
                    }
                }
            }
            .padding(.horizontal, companionThread ? ConversationMetrics.bubblePaddingH : 0)
            .padding(.vertical, companionThread ? ConversationMetrics.bubblePaddingV : 0)
            .background(companionThread ? Theme.assistantBubble : .clear)
            .clipShape(RoundedRectangle(cornerRadius: companionThread ? ConversationMetrics.bubbleRadius : 0, style: .continuous))
        } else if message.state == .streaming && message.toolActivities.isEmpty && message.ask == nil {
            ProgressView().controlSize(.small)
                .padding(.horizontal, companionThread ? ConversationMetrics.bubblePaddingH : 0)
                .padding(.vertical, companionThread ? ConversationMetrics.bubblePaddingV : 0)
                .background(companionThread ? Theme.assistantBubble : .clear)
                .clipShape(RoundedRectangle(cornerRadius: companionThread ? ConversationMetrics.bubbleRadius : 0, style: .continuous))
                .accessibilityLabel("Working on your answer")
        }
    }

    @ViewBuilder private var extras: some View {
        let parsed = parsed
        let groups = ToolCallParser.group(parsed.calls)
        let sources = replyCitations(parsed.clean)?.sources ?? []
        if !groups.isEmpty || message.ask != nil || !message.artifacts.isEmpty || !sources.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { ToolGroupChip(group: $0) }
                if message.ask != nil {
                    VeraAskCard(message: message, canAnswer: nativeActions && store.canSubmitChat, onAnswer: onAnswer)
                }
                ForEach(message.artifacts) { art in
                    Button { onOpenArtifact?(art) } label: { ArtifactChip(artifact: art) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open " + ArtifactChip.displayTitle(art))
                }
                if !sources.isEmpty {
                    SourcesRow(sources: sources)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var actions: some View {
        let clean = parsed.clean
        if !clean.isEmpty {
            HStack(spacing: 16) {
                msgAction("doc.on.doc", label: "Copy response") {
                    copyText(CitationResolver.exportText(clean, sources: replyCitations(clean)?.sources ?? []))
                }
                if nativeActions {
                    msgAction("hand.thumbsup", label: "Good response", on: store.messageRatings[message.id] == "up") { rate("up") }
                    msgAction("hand.thumbsdown", label: "Bad response", on: store.messageRatings[message.id] == "down") { rate("down") }
                }
            }
            .padding(.top, 2)
        }
    }

    private func rate(_ sentiment: String) {
        if nativeActions, let convo = store.selected { store.rateMessage(message, in: convo, sentiment) }
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func msgAction(_ icon: String, label: String, on: Bool = false, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            Image(systemName: on ? icon + ".fill" : icon)
                .font(.system(size: 13)).foregroundStyle(on ? Theme.sage : Theme.warmTextSecondary)
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityLabel(label)
        .help(label)
    }
}

struct ProseMarkdown: View {
    let text: String
    var body: some View {
        StableProseMarkdown(text: text).equatable()
    }
}

private struct StableProseMarkdown: View, Equatable {
    let text: String
    private static let proseTheme = MarkdownUI.Theme.basic
        .text { ForegroundColor(Theme.warmTextPrimary); FontSize(ConversationMetrics.bodySize) }
        .code { FontFamilyVariant(.monospaced); BackgroundColor(Theme.cardFill) }
        .link { ForegroundColor(Theme.accent) }
        .table { configuration in
            ScrollView(.horizontal) {
                configuration.label.fixedSize(horizontal: true, vertical: false)
            }
            .markdownMargin(top: 0, bottom: 16)
        }

    var body: some View {
        Markdown(SourceFormatter.apply(text))
            .markdownTheme(Self.proseTheme)
            .textSelection(.enabled)
    }
}

struct ToolCall: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let detail: String
}

/// Consecutive calls of the same tool, collapsed into one row (avoids a stack of identical chips).
struct ToolCallGroup: Identifiable {
    let id = UUID()
    let name: String
    let calls: [ToolCall]
    var label: String {
        name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
            .map { $0.lowercased() }.joined(separator: " ")
    }
}

enum ToolCallParser {
    static func parse(_ text: String) -> (clean: String, calls: [ToolCall]) {
        let ns = text as NSString
        var calls: [ToolCall] = []
        if let re = try? NSRegularExpression(
            pattern: "<details type=\"tool_calls\"[^>]*?name=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</details>", options: []) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                var inner = ns.substring(with: m.range(at: 2))
                inner = inner.replacingOccurrences(of: "<summary>[\\s\\S]*?</summary>", with: "", options: .regularExpression)
                calls.append(ToolCall(name: name, detail: decode(inner).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        var clean = text
        // Reasoning blocks are model thinking, never part of the reply — stripped entirely.
        if let re = try? NSRegularExpression(
            pattern: "<details type=\"(?:tool_calls|reasoning)\"[\\s\\S]*?</details>", options: []) {
            clean = re.stringByReplacingMatches(in: clean, range: NSRange(location: 0, length: (clean as NSString).length), withTemplate: "")
        }
        // Strip an incomplete trailing block while streaming.
        if let re = try? NSRegularExpression(pattern: "<details type=\"(?:tool_calls|reasoning)\"[\\s\\S]*$", options: []) {
            let cns = clean as NSString
            if let mm = re.firstMatch(in: clean, range: NSRange(location: 0, length: cns.length)) {
                clean = cns.replacingCharacters(in: mm.range, with: "")
            }
        }
        return (clean.trimmingCharacters(in: .whitespacesAndNewlines), calls)
    }

    /// Collapse runs of the same tool name into groups (preserving interleaving with other tools).
    static func group(_ calls: [ToolCall]) -> [ToolCallGroup] {
        var groups: [ToolCallGroup] = []
        for c in calls {
            if let last = groups.last, last.name == c.name {
                groups[groups.count - 1] = ToolCallGroup(name: last.name, calls: last.calls + [c])
            } else {
                groups.append(ToolCallGroup(name: c.name, calls: [c]))
            }
        }
        return groups
    }

    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\n", with: "\n")
    }
}

/// A collapsible "used <tool>" chip representing one or more consecutive calls of the same tool.
/// Shows a ×N count when repeated; expands to each call's raw detail.
struct ToolGroupChip: View {
    let group: ToolCallGroup
    @State private var open = false
    private var details: [ToolCall] { group.calls.filter { !$0.detail.isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if !details.isEmpty { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 9))
                    Text("Used \(group.label)").font(.system(size: 11, weight: .medium))
                    if group.calls.count > 1 {
                        Text("\(group.calls.count)×").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.surface).clipShape(Capsule())
                    }
                    if !details.isEmpty {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8))
                    }
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, call in
                        Text(call.detail)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}
