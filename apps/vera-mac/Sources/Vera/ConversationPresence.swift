import SwiftUI

enum ConversationFigure: Equatable {
    case companion
    case mark
    case none
}

enum ConversationHeaderKind: Equatable {
    case conversation
    case none
}

enum ConversationPresence {
    static func assistantName(companionThread: Bool, savedName: String) -> String {
        companionThread ? savedName : "Tandem"
    }

    static func headerTitle(conversationTitle: String?) -> String {
        guard let title = conversationTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Tandem" }
        return title
    }

    static func headerKind(companionThread: Bool) -> ConversationHeaderKind { companionThread ? .none : .conversation }
    static func headerFigure(companionThread: Bool) -> ConversationFigure { companionThread ? .companion : .none }
    static func headerShowsStatus(companionThread: Bool) -> Bool { companionThread }
    static func greetingFigure(companionThread: Bool) -> ConversationFigure { companionThread ? .companion : .mark }
    static func replyFigure(companionThread: Bool) -> ConversationFigure { companionThread ? .companion : .none }

    static func showsWorkPanel(references: [NativeTaskReference], conversationID: String?, wide: Bool, canvasOpen: Bool) -> Bool {
        wide && !canvasOpen && !OngoingWork.items(references, conversationID: conversationID).isEmpty
    }

    static func showsWorkButton(references: [NativeTaskReference], conversationID: String?, wide: Bool, canvasOpen: Bool) -> Bool {
        !references.isEmpty && !showsWorkPanel(references: references, conversationID: conversationID, wide: wide, canvasOpen: canvasOpen)
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
    var conversationAssistantName: String {
        ConversationPresence.assistantName(companionThread: isVeraThread(selectedID), savedName: assistantName)
    }
}
