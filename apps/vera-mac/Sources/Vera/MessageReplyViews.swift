import SwiftUI

struct ComposerReplyBar: View {
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        if let pending = store.shownPendingReply {
            HStack(spacing: 6) {
                Image(systemName: MessageReplyCopy.symbol)
                    .font(.system(size: 11))
                Text(pending.quote)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button { store.cancelReply() } label: {
                    Image(systemName: MessageReplyCopy.cancelSymbol).font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(MessageReplyCopy.cancel)
                .help(MessageReplyCopy.cancel)
            }
            .foregroundStyle(Theme.textSecondary)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(MessageReplyCopy.barLead + pending.quote)
        }
    }
}

struct MessageReplyChip: View {
    @EnvironmentObject private var store: ChatStore
    let message: Message
    let companionThread: Bool

    static let maxWidth: CGFloat = 300

    var body: some View {
        if companionThread, message.role == .user, let reply = store.companionMarks.replies[message.id] {
            Text(reply.quote + "\u{2026}")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
                .frame(maxWidth: Self.maxWidth, alignment: .trailing)
                .padding(.bottom, -4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(MessageReplyCopy.chipLead + reply.quote)
        }
    }
}
