import SwiftUI

struct RuleOfferCard: View {
    let offer: NativeRuleOffer
    var onAnswer: ((RuleOfferAnswer) -> Void)? = nil
    @Environment(\.renderSafe) private var renderSafe

    static func spoken(_ question: String, answers: CardAnswers) -> [String] {
        [CardSplitButton.spoken(answers.declineTitle, context: question), CardSplitButton.spoken(answers.allowTitle, context: question),
         CardSplitButton.spoken("More ways to \(answers.declineTitle.lowercased())", context: question),
         CardSplitButton.spoken("More ways to \(answers.allowTitle.lowercased())", context: question)]
            + (answers.declineMenu + answers.allowMenu).map { CardSplitButton.spoken($0.spoken, context: question) }
    }

    static func line(_ offer: NativeRuleOffer) -> String? {
        guard let action = offer.action else { return nil }
        switch offer.state {
        case .allowedHere: return RuleOfferCopy.allowedHere(action)
        case .allowedEverywhere: return RuleOfferCopy.allowedEverywhere(action)
        case .waiting, .closed: return nil
        }
    }

    var body: some View {
        if let action = offer.action {
            switch offer.state {
            case .waiting: question(action)
            case .allowedHere, .allowedEverywhere: after
            case .closed: EmptyView()
            }
        }
    }

    private func question(_ action: NativeActionClass) -> some View {
        let sentence = RuleOfferCopy.question(action)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                InterfaceIconView(icon: .needsYou, size: InterfaceIconSize.row).foregroundStyle(Theme.sage)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.sage.opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(sentence)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warmTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if offer.failed {
                        Text(RuleOfferCopy.failed)
                            .font(.system(size: ConversationMetrics.metaSize)).foregroundStyle(Theme.warmTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            CardAnswerRow(answers: CardAnswers.offer(), defaultApproval: false, allowApprove: onAnswer != nil, allowDecline: onAnswer != nil,
                          context: sentence,
                          onAllow: { onAnswer?(.allow) }, onDecline: { onAnswer?(.decline) },
                          onItem: { id in if let answer = RuleOfferAnswer(rawValue: id) { onAnswer?(answer) } })
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous)
            .stroke(Theme.cardStroke, lineWidth: 1))
    }

    @ViewBuilder private var after: some View {
        if let text = Self.line(offer) {
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if renderSafe {
                    Text(RefusalCopy.changeInRules).font(.system(size: 11)).foregroundStyle(Theme.accent)
                } else {
                    SettingsSectionLink(RefusalCopy.changeInRules, tab: .rules).buttonStyle(.borderless).font(.system(size: 11))
                }
            }
        }
    }
}
