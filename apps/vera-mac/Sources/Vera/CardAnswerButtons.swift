import SwiftUI

struct CardMenuItem: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    var note: String? = nil

    var spoken: String { note.map { title + ". " + $0 } ?? title }
}

struct CardAnswers: Equatable {
    var allowTitle = "Allow"
    var declineTitle = "Decline"
    var allowMenu: [CardMenuItem] = []
    var declineMenu: [CardMenuItem] = []

    static let allowOrder: [NativeCardChoiceKind] = [.allowHere, .allowSchedule, .allowAlways]
    static let displayLimit = 400

    static func shown(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.unicodeScalars.count <= displayLimit, !text.contains(where: \.isNewline) else { return nil }
        return text
    }

    static func chat(_ request: NativeToolConfirmationRequest) -> CardAnswers {
        var answers = CardAnswers()
        guard let subject = request.subject else { return answers }
        if let scope = shown(NativeCardChoices.scope(subject)) {
            for kind in allowOrder {
                guard let choice = request.choices.first(where: { $0.kind == kind }) else { continue }
                answers.allowMenu.append(CardMenuItem(id: kind.rawValue, title: choice.title, note: scope))
            }
        }
        if NativeCardChoices.declineMenu, let never = request.choices.first(where: { $0.kind == .never }), shown(never.title) != nil {
            answers.declineMenu = [CardMenuItem(id: NativeCardChoiceKind.never.rawValue, title: never.title,
                                                note: subject.toolID == NativeCommandTools.toolID ? NativeCardChoices.neverHelp : nil)]
        }
        return answers
    }

    static func task(choices: [String], covers: String?, neverTitle: String?, run: Bool = false) -> CardAnswers {
        var answers = CardAnswers()
        if let scope = shown(covers) {
            for kind in allowOrder where choices.contains(kind.rawValue) {
                var title = NativeCardChoices.wireTitle(kind.rawValue) ?? kind.rawValue
                if run, kind == .allowHere { title = "Always allow for this run" }
                answers.allowMenu.append(CardMenuItem(id: kind.rawValue, title: title, note: scope))
            }
        }
        guard NativeCardChoices.declineMenu,
              let wire = choices.first(where: { NativeCardChoices.kind(wire: $0) == .never }) else { return answers }
        let commands = wire == NativeCardChoices.commandNever
        guard commands || shown(neverTitle) != nil, var title = commands ? NativeCardChoices.wireTitle(wire) : neverTitle else { return answers }
        if run, commands { title = "Never run commands in this run" }
        answers.declineMenu = [CardMenuItem(id: wire, title: title, note: commands ? NativeCardChoices.neverHelp : nil)]
        return answers
    }
}

struct CardSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct CardSplitButton: View {
    static let caretWidth: CGFloat = 30
    static let height: CGFloat = 28

    let title: String
    let kind: ConversationButtonStyle.Kind
    var isDefault = false
    var enabled = true
    let items: [CardMenuItem]
    let onPrimary: () -> Void
    let onItem: (String) -> Void

    private var ink: Color { kind == .primary ? Theme.onSage : Theme.warmTextPrimary }

    private var label: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
            .padding(.leading, 14).padding(.trailing, items.isEmpty ? 14 : 10)
            .frame(height: Self.height)
    }

    var body: some View {
        HStack(spacing: 0) {
            if isDefault {
                Button(action: onPrimary) { label }.buttonStyle(CardSegmentStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button(action: onPrimary) { label }.buttonStyle(CardSegmentStyle())
            }
            if !items.isEmpty {
                Rectangle().fill(kind == .primary ? Theme.onSage.opacity(0.35) : Theme.cardStroke).frame(width: 1, height: 16)
                Menu {
                    ForEach(items) { item in
                        Button {
                            onItem(item.id)
                        } label: {
                            Text(item.title)
                            if let note = item.note { Text(note) }
                        }
                        .accessibilityLabel(item.spoken)
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(ink)
                        .frame(width: Self.caretWidth, height: Self.height)
                }
                .menuStyle(.button)
                .buttonStyle(CardSegmentStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More ways to \(title.lowercased())")
            }
        }
        .background(Capsule().fill(kind == .primary ? Theme.sage : Color.clear))
        .overlay(Capsule().stroke(kind == .primary ? Color.clear : Theme.cardStroke, lineWidth: 1))
        .clipShape(Capsule())
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }
}

struct CardAnswerRow: View {
    let answers: CardAnswers
    var defaultApproval = true
    var allowApprove = true
    var allowDecline = true
    let onAllow: () -> Void
    let onDecline: () -> Void
    let onItem: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            CardSplitButton(title: answers.declineTitle, kind: .secondary, enabled: allowDecline, items: answers.declineMenu,
                            onPrimary: onDecline, onItem: onItem)
            CardSplitButton(title: answers.allowTitle, kind: .primary, isDefault: defaultApproval, enabled: allowApprove,
                            items: answers.allowMenu, onPrimary: onAllow, onItem: onItem)
        }
    }
}

struct CardMenuPreview: View {
    let heading: String
    let items: [CardMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 13))
                    if let note = item.note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.textSecondary) }
                }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}
