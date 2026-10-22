import SwiftUI
import AppKit

private struct RenderSafeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var renderSafe: Bool {
        get { self[RenderSafeKey.self] }
        set { self[RenderSafeKey.self] = newValue }
    }
}

struct FolderGrantChips: View {
    let grants: [FolderGrant]
    var unsupported: String? = nil
    var onRemove: (String) -> Void
    @Environment(\.renderSafe) private var renderSafe

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(grants) { grant in
                FolderGrantChip(grant: grant, onRemove: { onRemove(grant.id) })
            }
        }
        .padding(.vertical, 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if renderSafe {
                chips
            } else {
                ScrollView(.horizontal, showsIndicators: false) { chips }
            }
            if let unsupported {
                Label(unsupported, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct FolderGrantChip: View {
    let grant: FolderGrant
    var onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
            Text(grant.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0.55)
            .accessibilityLabel("Stop working in \(grant.name)")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.surfaceHover)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        .onHover { hover = $0 }
        .help(grant.path)
        .accessibilityElement(children: .combine)
    }
}

struct NativeFileChangeCard: View {
    let change: NativeFileChange
    @State private var expanded: Bool
    @Environment(\.renderSafe) private var renderSafe

    init(change: NativeFileChange) {
        self.change = change
        let lines = NativeLineDiff.hunks(before: change.kind == .created ? "" : (change.before ?? ""), after: change.after ?? "").reduce(0) { $0 + $1.lines.count }
        _expanded = State(initialValue: (change.kind == .edited || change.kind == .created) && lines > 0 && lines <= 30)
    }

    private var hunks: [NativeLineDiff.Hunk] {
        switch change.kind {
        case .edited: return NativeLineDiff.hunks(before: change.before ?? "", after: change.after ?? "")
        case .created: return NativeLineDiff.hunks(before: "", after: change.after ?? "")
        case .moved, .directory: return []
        }
    }

    private var summary: String {
        if change.truncated { return "Too large to show here. Open the file to see it." }
        switch change.kind {
        case .created, .edited: return NativeLineDiff.summary(before: change.before, after: change.after)
        case .moved: return "from \(change.movedFrom.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? "")"
        case .directory: return "New folder"
        }
    }

    private var symbol: String {
        switch change.kind {
        case .created: return "doc.badge.plus"
        case .edited: return "pencil.line"
        case .moved: return "arrow.right.doc.on.clipboard"
        case .directory: return "folder.badge.plus"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(summary).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if renderSafe {
                    Text("Open").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    Text("Reveal").font(.system(size: 11)).foregroundStyle(Theme.accent)
                } else {
                    if !hunks.isEmpty {
                        Button(expanded ? "Hide changes" : "Show changes") { expanded.toggle() }
                            .buttonStyle(.borderless).font(.system(size: 11))
                    }
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: change.path)) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: change.path)]) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            .padding(12)
            if expanded && !hunks.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ShotSafeScroll(renderSafe: renderSafe, axis: [.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(hunks) { hunk in
                            if hunk.id > 0 {
                                Text("…").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 12).padding(.vertical, 2)
                            }
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                NativeDiffLine(line: line)
                            }
                        }
                        if change.truncated {
                            Text("The file was too large to show in full.").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                .padding(12)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: renderSafe ? nil : 360)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(change.title)
    }
}

struct NativeDiffLine: View {
    let line: NativeLineDiff.Line

    private var text: String {
        switch line {
        case .same(let value): return "  " + value
        case .removed(let value): return "- " + value
        case .added(let value): return "+ " + value
        }
    }

    private var color: Color {
        switch line {
        case .same: return Theme.textSecondary
        case .removed: return Color.red
        case .added: return Color.green
        }
    }

    private var background: Color {
        switch line {
        case .same: return .clear
        case .removed: return Color.red.opacity(0.08)
        case .added: return Color.green.opacity(0.08)
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 1)
            .background(background)
    }
}
