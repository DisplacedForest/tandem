import SwiftUI
import AppKit

private struct MemorySourceActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

extension EnvironmentValues {
    var inspectMemorySource: (@MainActor (String) -> Void)? {
        get { self[MemorySourceActionKey.self] }
        set { self[MemorySourceActionKey.self] = newValue }
    }
}

/// The one citation language for the whole app: numbered `[n]` / `[n,m]` refs are pulled out
/// of prose and rendered as tappable favicon+host capsule chips beneath the paragraph that
/// cited them. Pulse detail and chat replies both consume these — never a second implementation.

/// Pull EVERY `[n]` / `[n,m]` citation group from a paragraph (Vera cites mid-sentence, not just at
/// the end) → (clean text with refs removed + spacing tidied, aggregated source numbers).
func extractRefs(_ text: String) -> (String, [Int]) {
    // Match a bracket group that starts with a digit (so it never eats an [[img:N]] token).
    guard let re = try? NSRegularExpression(pattern: "\\s*\\[[0-9][0-9,\\s]*\\]") else { return (text, []) }
    let ns = text as NSString
    let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return (text, []) }
    var nums: [Int] = []
    for m in matches {
        nums += ns.substring(with: m.range).components(separatedBy: CharacterSet(charactersIn: "[], ")).compactMap { Int($0) }
    }
    var clean = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    // Tidy the gaps the refs left behind: space-before-punctuation, doubled spaces.
    clean = clean.replacingOccurrences(of: "\\s+([.,;:!?])", with: "$1", options: .regularExpression)
    clean = clean.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
    return (clean.trimmingCharacters(in: .whitespacesAndNewlines), Array(Set(nums)).sorted())
}

func sourceIsLinked(_ url: String) -> Bool {
    let scheme = url.prefix(8).lowercased()
    return scheme.hasPrefix("http://") || scheme.hasPrefix("https://")
}

struct CitationChip: View {
    @Environment(\.inspectMemorySource) private var inspectMemory
    let source: PulseSource

    private var spokenName: String {
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? sourceHost(source.url) : title
    }

    var body: some View {
        if sourceIsLinked(source.url) {
            if let destination = NativeResearchReportSafety.destination(source.url) {
                Button { NSWorkspace.shared.open(destination) } label: {
                    label(sourceHost(source.url), favicon: true)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel(spokenName)
                .help(spokenName)
            } else {
                label(sourceHost(source.url), favicon: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenName)
                    .help(spokenName)
            }
        } else if NativeMemoryCitation.recordID(source.url) != nil, let inspectMemory {
            Button { inspectMemory(source.url) } label: {
                label(source.title, favicon: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spokenName)
        } else {
            label(source.title.isEmpty ? source.url : source.title, favicon: false)
        }
    }

    private func label(_ text: String, favicon: Bool) -> some View {
        HStack(spacing: 5) {
            if favicon { Favicon(urlString: source.url) }
            Text(text).font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.surface).clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        .contentShape(Capsule())
    }
}

private struct SourcesListExpandedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sourcesListExpanded: Bool {
        get { self[SourcesListExpandedKey.self] }
        set { self[SourcesListExpandedKey.self] = newValue }
    }
}

struct SourcesRow: View {
    @Environment(\.sourcesListExpanded) private var startsExpanded
    let sources: [PulseSource]
    var initiallyExpanded: Bool? = nil
    var numbered = true
    @State private var toggled = false

    private var expanded: Bool { (initiallyExpanded ?? startsExpanded) != toggled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { toggled.toggle() }
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: -6) {
                        ForEach(sources.filter { sourceIsLinked($0.url) }.prefix(5)) { Favicon(urlString: $0.url) }
                    }
                    Text("Sources").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    Text("\(sources.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.surface).clipShape(Capsule())
                    Spacer()
                    InterfaceIconView(icon: expanded ? .collapse : .expand, size: InterfaceIconSize.small).foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Sources, \(sources.count)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sources) { SourceListRow(source: $0, numbered: numbered) }
                }
                .padding(.bottom, 12)
            }
        }
    }
}

private struct SourceListRow: View {
    @Environment(\.inspectMemorySource) private var inspectMemory
    let source: PulseSource
    let numbered: Bool

    private var linked: Bool { sourceIsLinked(source.url) }

    private var name: String {
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return linked ? sourceHost(source.url) : source.url
    }

    var body: some View {
        if linked, let destination = NativeResearchReportSafety.destination(source.url) {
            Button { NSWorkspace.shared.open(destination) } label: { content }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel(name)
                .help(name)
        } else if NativeMemoryCitation.recordID(source.url) != nil, let inspectMemory {
            Button { inspectMemory(source.url) } label: { content }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            if numbered {
                Text("\(source.n)").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 18, alignment: .trailing)
            }
            if linked { Favicon(urlString: source.url) }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                if linked {
                    Text(sourceHost(source.url)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

enum CitationStyle {
    case chat, document
}

struct CitedText: View {
    @Environment(\.renderSafe) private var renderSafe
    let resolved: ResolvedCitations
    let style: CitationStyle

    init(text: String, sources: [PulseSource], style: CitationStyle = .chat, allowRecovery: Bool = true) {
        resolved = CitationResolver.resolve(text: text, sources: sources, allowRecovery: allowRecovery)
        self.style = style
    }

    init(resolved: ResolvedCitations, style: CitationStyle) {
        self.resolved = resolved
        self.style = style
    }

    var body: some View {
        if resolved.sources.isEmpty {
            markdown(resolved.blocks.map(\.text).joined(separator: "\n\n"))
        } else {
            VStack(alignment: .leading, spacing: style == .chat ? 10 : 14) {
                ForEach(Array(resolved.blocks.enumerated()), id: \.offset) { index, block in
                    Group {
                        if block.isCode, renderSafe {
                            staticCode(block.text)
                        } else if block.isCode || block.refs.isEmpty {
                            markdown(block.text)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                markdown(block.text)
                                CitationChipRow(refs: block.refs, sources: resolved.sources)
                            }
                        }
                    }
                    .padding(.top, style == .document && index > 0 && !block.isCode && block.text.hasPrefix("#") ? 10 : 0)
                }
            }
        }
    }

    private func staticCode(_ text: String) -> some View {
        var lines = text.components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "`" || $0 == "~" }), !last.isEmpty {
            lines.removeLast()
        }
        return Text(lines.joined(separator: "\n"))
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textPrimary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func markdown(_ text: String) -> some View {
        switch style {
        case .chat: ProseMarkdown(text: text)
        case .document: NativeArtifactMarkdown(text: text).equatable()
        }
    }
}

struct CitationChipRow: View {
    let refs: [Int]
    let sources: [PulseSource]

    var body: some View {
        let chips = refs.compactMap { n in sources.first { $0.n == n } }
        if !chips.isEmpty {
            WrappingLayout(spacing: 6) {
                ForEach(chips) { CitationChip(source: $0) }
            }
        }
    }
}

struct WrappingLayout: Layout {
    var spacing: CGFloat

    private func fitted(_ subview: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > width else { return ideal }
        return CGSize(width: width, height: subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = fitted(subview, within: width)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for subview in subviews {
            let size = fitted(subview, within: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A chat prose segment with the Pulse citation treatment: paragraphs render with their `[n]`
/// refs stripped and the matching chips beneath. Segments containing fenced code render whole
/// (never split a fence), with the segment's chips aggregated below.
struct CitedProse: View {
    let text: String
    let sources: [PulseSource]

    var body: some View {
        if text.contains("```") {
            let (_, refs) = extractRefs(text)
            VStack(alignment: .leading, spacing: 8) {
                ProseMarkdown(text: text)
                chipRow(refs)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, para in
                    let t = para.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        let (clean, refs) = extractRefs(t)
                        VStack(alignment: .leading, spacing: 8) {
                            ProseMarkdown(text: clean)
                            chipRow(refs)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chipRow(_ refs: [Int]) -> some View {
        let chips = refs.compactMap { n in sources.first { $0.n == n } }
        if !chips.isEmpty {
            HStack(spacing: 6) { ForEach(chips) { CitationChip(source: $0) } }
        }
    }
}
