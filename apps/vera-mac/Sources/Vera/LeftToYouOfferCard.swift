import SwiftUI

enum LeftToYouCopy {
    static let askFirst = "Ask me first next time"
    static let keep = "Keep it this way"
    static let kept = "Kept as it is."
    static let asksNext = " will ask first next time."

    static func because(_ action: NativeActionClass, chat: Bool) -> String {
        " left this to you because that's what you chose for \(RuleRows.thing(action))" + (chat ? " in this chat." : ".")
    }

    static func sentence(_ action: NativeActionClass, chat: Bool) -> CompanionLine {
        .parts([.name, .text(because(action, chat: chat))])
    }

    static let asked: CompanionLine = .parts([.name, .text(asksNext)])

    static var answers: CardAnswers {
        CardAnswers(allowTitle: askFirst, declineTitle: keep, allowMenu: [], declineMenu: [])
    }

    static func strings(_ action: NativeActionClass) -> [String] {
        var lines: [String] = []
        for chat in [false, true] {
            let sentence = sentence(action, chat: chat)
            lines.append(sentence.plain(name: nil))
            lines.append(CardSplitButton.spoken(askFirst, context: sentence.plain(name: nil)))
            lines.append(CardSplitButton.spoken(keep, context: sentence.plain(name: nil)))
        }
        return lines + [askFirst, keep, kept, asked.plain(name: nil), RuleOfferCopy.failed, RefusalCopy.changeInRules, "Step details"]
    }
}

struct LeftToYouOfferCard: View {
    let offer: NativeLeftToYouOffer
    let state: LeftToYouOfferState
    var onAnswer: ((LeftToYouAnswer) -> Void)? = nil
    @Environment(\.renderSafe) private var renderSafe
    @Environment(\.companionName) private var name

    var body: some View {
        if let action = NativeActionClass(rawValue: offer.action) {
            VStack(alignment: .leading, spacing: 10) {
                switch state.answer {
                case .kept?:
                    Text(LeftToYouCopy.kept)
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                case .askFirst?:
                    VStack(alignment: .leading, spacing: 3) {
                        CompanionLineText(line: LeftToYouCopy.asked)
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if renderSafe {
                            Text(RefusalCopy.changeInRules).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        } else {
                            SettingsSectionLink(RefusalCopy.changeInRules, tab: .rules).buttonStyle(.borderless).font(.system(size: 11))
                        }
                    }
                case nil:
                    question(action)
                }
            }
        }
    }

    private func question(_ action: NativeActionClass) -> some View {
        let line = LeftToYouCopy.sentence(action, chat: offer.source == NativeRuleWhy.Source.chat.rawValue)
        return VStack(alignment: .leading, spacing: 10) {
            CompanionLineText(line: line)
                .font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            step
            if state.failed {
                Text(RuleOfferCopy.failed)
                    .font(.system(size: ConversationMetrics.metaSize)).foregroundStyle(Theme.warmTextSecondary)
            }
            CardAnswerRow(answers: LeftToYouCopy.answers, defaultApproval: false, allowApprove: onAnswer != nil, allowDecline: onAnswer != nil,
                          context: line.plain(name: name),
                          onAllow: { onAnswer?(.askFirst) }, onDecline: { onAnswer?(.kept) }, onItem: { _ in })
        }
    }

    private var step: some View {
        let block = Text(verbatim: offer.step)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
        return Group {
            if offer.step.count > 700 || offer.step.split(separator: "\n").count > 10 {
                ScrollView { block }.frame(height: 220)
            } else {
                block
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.bg))
        .accessibilityLabel("Step details: " + offer.step)
    }
}
