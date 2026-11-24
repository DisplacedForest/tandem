import SwiftUI

struct NativeServiceTool: Codable, Hashable, Sendable {
    var tool: String
    var service: String
    var detail: String
    var host: String? = nil

    var words: String { "\(tool) in \(service)" }
    var fits: Bool { [tool, service].allSatisfy { CardAnswers.shown($0) != nil } && words.unicodeScalars.count <= 240 }
}

struct ServiceAllowConfirm: Equatable, Hashable, Identifiable, Sendable {
    struct Quote: Equatable, Hashable, Sendable {
        let title: String
        let text: String
    }

    let question: String
    let quotes: [Quote]

    var id: String { question }
    var digest: String { piHash(Data(([question] + quotes.flatMap { [$0.title, $0.text] }).map { "\($0.utf8.count):\($0)" }.joined().utf8)) }
    var confirmed: ServiceAllowConfirmed { ServiceAllowConfirmed(digest: digest) }

    func accepts(_ given: ServiceAllowConfirmed?) -> Bool { given?.digest == digest }

    static let allow = "Allow"
    static let cancel = "Cancel"

    static func undescribed(_ service: String) -> String { "\(service) doesn't describe it." }

    static func tool(_ tool: NativeServiceTool) -> ServiceAllowConfirm {
        let said = NativeToolRepair.plain(tool.detail)
        return ServiceAllowConfirm(question: "Allow everything \(tool.tool) can do in \(tool.service) without asking?",
                                   quotes: [Quote(title: tool.tool, text: said.isEmpty ? undescribed(tool.service) : tool.detail.trimmingCharacters(in: .whitespacesAndNewlines))])
    }
}

struct ServiceAllowConfirmed: Equatable, Hashable, Sendable {
    let digest: String
}

struct ServiceAllowConfirmSheet: View {
    let confirm: ServiceAllowConfirm
    let onAllow: (ServiceAllowConfirmed) -> Void
    let onCancel: () -> Void
    @Environment(\.renderSafe) private var renderSafe

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: confirm.question)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warmTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ShotSafeScroll(renderSafe: renderSafe) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(confirm.quotes, id: \.self) { quote in
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 1).fill(Theme.cardStroke).frame(width: 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: quote.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warmTextPrimary)
                                Text(verbatim: quote.text).font(.system(size: 12)).foregroundStyle(Theme.warmTextSecondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: renderSafe ? nil : 280)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(ServiceAllowConfirm.cancel, action: onCancel)
                    .buttonStyle(ConversationButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                Button(ServiceAllowConfirm.allow) { onAllow(confirm.confirmed) }
                    .buttonStyle(ConversationButtonStyle(kind: .primary))
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
        .background(Theme.cardFill)
    }
}
