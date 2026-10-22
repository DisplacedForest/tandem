import AppKit
import SwiftUI

struct NativeCommandRunCard: View {
    let run: NativeCommandRun
    @State private var expanded: Bool
    @Environment(\.renderSafe) private var renderSafe

    init(run: NativeCommandRun) {
        self.run = run
        let lines = run.stdout.split(separator: "\n", omittingEmptySubsequences: false).count
            + run.stderr.split(separator: "\n", omittingEmptySubsequences: false).count
        _expanded = State(initialValue: run.hasOutput && lines <= 20)
    }

    private var symbol: String {
        switch run.outcome {
        case .ran: return run.exitCode == 0 ? "terminal" : "exclamationmark.triangle"
        case .timedOut: return "clock.badge.exclamationmark"
        case .canceled: return "stop.circle"
        case .declined: return "hand.raised"
        case .refused: return "nosign"
        }
    }

    private var tint: Color {
        switch run.outcome {
        case .ran: return run.exitCode == 0 ? Theme.accent : Color.orange
        case .timedOut, .canceled, .refused: return Color.orange
        case .declined: return Theme.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(run.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(3).textSelection(.enabled)
                    Text(run.directory.isEmpty ? run.statusLine : "In \(run.directoryName). \(run.statusLine)")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    if let decision = run.decisionLine {
                        Text(decision).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if run.hasOutput {
                    if renderSafe {
                        Text(expanded ? "Hide output" : "Show output").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    } else {
                        Button(expanded ? "Hide output" : "Show output") { expanded.toggle() }
                            .buttonStyle(.borderless).font(.system(size: 11))
                    }
                }
            }
            .padding(12)
            if expanded && run.hasOutput {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ShotSafeScroll(renderSafe: renderSafe, axis: [.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !run.stdout.isEmpty {
                            NativeCommandOutputBlock(text: run.stdout, truncated: run.stdoutTruncated)
                        }
                        if !run.stderr.isEmpty {
                            if !run.stdout.isEmpty {
                                Text("Errors").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                            }
                            NativeCommandOutputBlock(text: run.stderr, truncated: run.stderrTruncated)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: renderSafe ? nil : 320)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct NativeCommandOutputBlock: View {
    let text: String
    let truncated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text.trimmingCharacters(in: .newlines))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if truncated {
                Text(NativeCommandRun.truncationMarker).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct ConversationRulesButton: View {
    @EnvironmentObject private var store: ChatStore
    @State private var open = false

    private var tightened: Bool { !store.selectedConversationRules.isEmpty }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checklist").font(.system(size: 11, weight: .medium))
                Text(tightened ? "Rules for this chat" : "Rules").font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().stroke(tightened ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Tighten what asks first in this chat, or take back a command approval")
        .popover(isPresented: $open, arrowEdge: .top) {
            ConversationRulesEditor().environmentObject(store)
        }
    }
}

struct ConversationRulesEditor: View {
    @EnvironmentObject private var store: ChatStore

    private var rules: NativeConversationRules { store.selectedConversationRules }

    private func choices(for action: NativeActionClass) -> [NativeRuleChoice] {
        let base = store.nativeRules.choice(for: action)
        return NativeRuleChoice.allCases.filter { $0.strictness >= base.strictness }
    }

    private func binding(for action: NativeActionClass) -> Binding<NativeRuleChoice> {
        Binding(
            get: { NativeRuleChoice.stricter(store.nativeRules.choice(for: action), rules.choices[action] ?? .act) },
            set: { store.tightenConversationRule($0, for: action) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rules for this chat").font(.system(size: 13, weight: .semibold))
            Text("A chat can only ask more than your defaults in Settings, Rules, never less.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            ForEach(NativeActionClass.allCases.filter { !$0.isFixed }, id: \.self) { action in
                Picker(action.title, selection: binding(for: action)) {
                    ForEach(choices(for: action), id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .font(.system(size: 12))
            }
            if !rules.approvedCommandPrefixes.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text("Commands approved for this chat").font(.system(size: 12, weight: .medium))
                ForEach(rules.approvedCommandPrefixes, id: \.self) { prefix in
                    HStack(spacing: 8) {
                        Text(prefix).font(.system(size: 11, design: .monospaced))
                        Spacer(minLength: 8)
                        Button {
                            store.revokeCommandPrefix(prefix)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                        .help("Ask again before commands starting with \(prefix)")
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}
