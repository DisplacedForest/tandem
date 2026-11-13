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

    static func offer() -> CardAnswers {
        CardAnswers(allowMenu: [CardMenuItem(id: RuleOfferAnswer.allowEverywhere.rawValue, title: RuleOfferCopy.allowEverywhere)],
                    declineMenu: [CardMenuItem(id: RuleOfferAnswer.neverOffer.rawValue, title: RuleOfferCopy.neverOffer)])
    }

    static let wholeNever = "Never allow it for this"
    static let commandsNever = "Never run commands for this"
    static let sendStart = "Never send to "
    static let scopeEnd = " for this"
    static let earlierEnds = [" in this task", " for this work"]

    static func current(_ title: String) -> String {
        switch title {
        case "Never allow this in this task", "Never allow it for this work": return wholeNever
        case "Never run commands in this task", "Never run commands for this work": return commandsNever
        default:
            guard title.hasPrefix(sendStart), let end = earlierEnds.first(where: title.hasSuffix) else { return title }
            return String(title.dropLast(end.count)) + scopeEnd
        }
    }

    static func scoped(_ title: String) -> Bool {
        title == wholeNever || title == commandsNever || (title.hasPrefix(sendStart) && title.hasSuffix(scopeEnd))
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
        title = current(title)
        if run, scoped(title) { title += " run" }
        answers.declineMenu = [CardMenuItem(id: wire, title: title, note: commands ? NativeCardChoices.neverHelp : nil)]
        return answers
    }
}

struct CardQuestion: Equatable {
    static let stopID = "card.stop_work"

    var answers: CardAnswers
    var allow: String
    var decline: String?
    var even = false

    static let evenAnswers: Set<String> = ["it_happened", "it_did_not"]

    enum Route: Equatable {
        case stop
        case answer(String)
    }

    static func route(_ id: String) -> Route { id == stopID ? .stop : .answer(id) }

    static func make(choices: [String], stop: String?, answerable: (String) -> Bool = { _ in true }) -> CardQuestion? {
        let offered = choices.filter { NativeTaskCardPresentation.choiceTitle($0) != nil && answerable($0) }
        guard let first = offered.first, let title = NativeTaskCardPresentation.choiceTitle(first) else { return nil }
        var answers = CardAnswers(allowTitle: title, declineTitle: "")
        let rest = Array(offered.dropFirst())
        guard let second = rest.first, let secondTitle = NativeTaskCardPresentation.choiceTitle(second) else {
            guard let stop else { return CardQuestion(answers: answers, allow: first, decline: nil) }
            answers.declineTitle = stop
            return CardQuestion(answers: answers, allow: first, decline: stopID)
        }
        answers.declineTitle = secondTitle
        answers.declineMenu = rest.dropFirst().compactMap { choice in
            NativeTaskCardPresentation.choiceTitle(choice).map { CardMenuItem(id: choice, title: $0) }
        }
        if let stop, !rest.contains("stop") { answers.declineMenu.append(CardMenuItem(id: stopID, title: stop)) }
        return CardQuestion(answers: answers, allow: first, decline: second, even: evenAnswers.isSuperset(of: [first, second]))
    }

    var controls: Int { decline == nil ? 1 : 2 }
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
    var context: String? = nil
    let items: [CardMenuItem]
    let onPrimary: () -> Void
    let onItem: (String) -> Void

    private var ink: Color { kind == .primary ? Theme.onSage : Theme.warmTextPrimary }

    static func spoken(_ text: String, context: String?) -> String { context.map { text + ", " + $0 } ?? text }

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
                    .accessibilityLabel(Self.spoken(title, context: context))
            } else {
                Button(action: onPrimary) { label }.buttonStyle(CardSegmentStyle())
                    .accessibilityLabel(Self.spoken(title, context: context))
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
                        .accessibilityLabel(Self.spoken(item.spoken, context: context))
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(ink)
                        .frame(width: Self.caretWidth, height: Self.height)
                }
                .menuStyle(.button)
                .buttonStyle(CardSegmentStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Self.spoken("More ways to \(title.lowercased())", context: context))
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
    var even = false
    var allowApprove = true
    var allowDecline = true
    var context: String? = nil
    let onAllow: () -> Void
    let onDecline: () -> Void
    let onItem: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            CardSplitButton(title: answers.declineTitle, kind: .secondary, enabled: allowDecline, context: context, items: answers.declineMenu,
                            onPrimary: onDecline, onItem: onItem)
            CardSplitButton(title: answers.allowTitle, kind: even ? .secondary : .primary, isDefault: defaultApproval, enabled: allowApprove,
                            context: context, items: answers.allowMenu, onPrimary: onAllow, onItem: onItem)
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
                    Text(item.title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
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
