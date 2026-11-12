import SwiftUI

enum ConversationFigure: Equatable {
    case companion
    case mark
    case none
}

enum ConversationPresence {
    static func assistantName(companionThread: Bool, savedName: String) -> String {
        companionThread ? savedName : "Tandem"
    }

    static func greetingFigure(companionThread: Bool) -> ConversationFigure { companionThread ? .companion : .mark }
    static func replyFigure(companionThread: Bool) -> ConversationFigure { companionThread ? .companion : .none }

    static func showsWorkPanel(references: [NativeTaskReference], conversationID: String?, wide: Bool, canvasOpen: Bool) -> Bool {
        wide && !canvasOpen && !OngoingWork.items(references, conversationID: conversationID).isEmpty
    }

}

struct ConversationFigureView: View {
    let figure: ConversationFigure
    let size: CGFloat

    var body: some View {
        switch figure {
        case .companion: CompanionAvatar(size: size)
        case .mark: TandemLogoMark(size: size)
        case .none: EmptyView()
        }
    }
}

@MainActor
extension ChatStore {
    var conversationAssistantLead: String {
        ConversationPresence.assistantName(companionThread: isVeraThread(selectedID), savedName: companion.leading)
    }

    var conversationAssistantName: String {
        ConversationPresence.assistantName(companionThread: isVeraThread(selectedID), savedName: companion.inline)
    }
}
