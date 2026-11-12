import Foundation
import CoreGraphics

@MainActor
enum MessageActionsSelftest {
    static let require = NativeTaskFixture.require

    static func run() throws {
        try offeredOnlyInCompanion()
        try copyMatchesOldCopy()
        try thumbRules()
        try placement()
        try holdRule()
        try offeredItems()
        try copySweep()
        print("MESSAGE ACTIONS SELFTEST OK")
    }

    static func offeredOnlyInCompanion() throws {
        try require(MessageActions.offered(companionThread: true), "The companion's conversation offers message actions")
        try require(!MessageActions.offered(companionThread: false), "An ordinary chat offers no message actions")
        let ordinaryKeepsRow = AssistantBody.showsActionRow(companionThread: false)
        let companionDropsRow = !AssistantBody.showsActionRow(companionThread: true)
        try require(ordinaryKeepsRow && companionDropsRow, "An ordinary chat keeps its icon row and the companion's conversation does not")
    }

    static func oldCopy(_ message: Message) -> String {
        let clean = ToolCallParser.parse(message.text).clean
        let sources: [PulseSource]
        if message.delivery != nil {
            sources = []
        } else if !message.sources.isEmpty {
            sources = message.sources
        } else {
            sources = CitationResolver.recover(clean)?.sources ?? []
        }
        return CitationResolver.exportText(clean, sources: sources)
    }

    static func copyMatchesOldCopy() throws {
        let sources = [PulseSource(n: 1, title: "Boston Public Library", url: "https://www.bpl.org/locations/central/"),
                       PulseSource(n: 2, title: "Seattle Public Library", url: "https://www.spl.org/hours-and-locations/central-library")]
        let cited = Message(role: .assistant, text: "Bates Hall is the classic reading room [1]. Level 10 is quieter [2].", sources: sources)
        let copied = MessageActions.copiedText(cited)
        try require(copied == oldCopy(cited), "Copy on a reply with sources matches the old copy")
        try require(copied.contains("## Sources") && copied.contains("https://www.bpl.org/locations/central/"),
                    "Copy on a reply with sources includes the source list")

        let conversationID = "message-actions-selftest"
        let delivered = NativeTaskDeliveryShot.messages(view: "result-message", conversationID: conversationID).last { $0.delivery != nil }
        guard let delivered else { throw NativeBoundedToolFixture.Failure.assertion("A delivered result exists") }
        try require(MessageActions.copiedText(delivered) == oldCopy(delivered), "Copy on a delivered result matches the old copy")
        try require(!MessageActions.copiedText(delivered).isEmpty, "Copy on a delivered result is not empty")

        let own = Message(role: .user, text: "Which of those stay open late?\nCheck the official hours.")
        try require(MessageActions.copiedText(own) == own.text, "Copy on his own message is exactly his text")

        let tooled = Message(role: .assistant, text: "<details type=\"tool_calls\" done=\"true\" name=\"web_search\"><summary>Tool Executed</summary>x</details>\nPlain answer.")
        try require(MessageActions.copiedText(tooled) == oldCopy(tooled) && MessageActions.copiedText(tooled) == "Plain answer.",
                    "Copy leaves out tool call blocks like the old copy")
    }

    static func thumbRules() throws {
        let store = ChatStore()
        let conversation = Conversation(id: "thumbs", title: "Thumbs", messages: [], updatedAt: Date())
        let first = Message(role: .assistant, text: "One")
        let second = Message(role: .assistant, text: "Two")
        func marks(_ message: Message) -> [MessageReaction] { MessageReaction.marks(rating: store.messageRatings[message.id]) }

        try require(marks(first).isEmpty, "No mark before a pick")
        store.rateMessage(first, in: conversation, MessageReaction.thumbsUp.rating)
        try require(marks(first) == [.thumbsUp], "Thumbs up shows its mark")
        store.rateMessage(first, in: conversation, MessageReaction.thumbsUp.rating)
        try require(marks(first).isEmpty, "Picking thumbs up again clears it")
        store.rateMessage(first, in: conversation, MessageReaction.thumbsUp.rating)
        store.rateMessage(first, in: conversation, MessageReaction.thumbsDown.rating)
        try require(marks(first) == [.thumbsDown], "Thumbs down replaces thumbs up")
        try require(marks(second).isEmpty, "Another message keeps its own state")
        store.rateMessage(second, in: conversation, MessageReaction.thumbsUp.rating)
        try require(marks(first) == [.thumbsDown] && marks(second) == [.thumbsUp], "Each message holds one thumb of its own")
        try require(MessageReaction.onAnnouncement(marks(second)) == "Thumbs up is on", "The row announces the thumb that is on")
        try require(MessageReaction.onAnnouncement([]) == "No reaction", "The row announces when no thumb is on")
    }

    static func placement() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1180, height: 900)
        let row = MessageActionsMetrics.rowSize
        let menu = MessageActionsMetrics.menuSize
        let gap = MessageActionsPlacement.gap
        let margin = MessageActionsPlacement.margin
        func inside(_ origin: CGPoint, _ size: CGSize) -> Bool {
            let rect = CGRect(origin: origin, size: size)
            return bounds.insetBy(dx: margin, dy: margin).contains(rect)
        }
        func overlap(_ placed: MessageActionsPlacement) -> Bool {
            CGRect(origin: placed.row, size: row).intersects(CGRect(origin: placed.menu, size: menu))
        }

        let middle = CGRect(x: 300, y: 400, width: 500, height: 60)
        let both = MessageActionsPlacement.place(message: middle, bounds: bounds, row: row, menu: menu)
        try require(both.row == CGPoint(x: middle.minX, y: middle.minY - gap - row.height), "Room on both sides puts the row above, leading aligned")
        try require(both.menu == CGPoint(x: middle.maxX - menu.width, y: middle.maxY + gap), "Room on both sides puts the menu below, trailing aligned")

        let top = CGRect(x: 300, y: 20, width: 500, height: 60)
        let noAbove = MessageActionsPlacement.place(message: top, bounds: bounds, row: row, menu: menu)
        let rowBelow = noAbove.row.y >= top.maxY
        let menuBelowRow = noAbove.menu.y >= noAbove.row.y + row.height
        try require(rowBelow && menuBelowRow, "No room above moves the row below the message, with the menu under it")
        try require(inside(noAbove.row, row) && inside(noAbove.menu, menu) && !overlap(noAbove), "No room above keeps both inside the window")

        let bottom = CGRect(x: 300, y: 820, width: 500, height: 60)
        let noBelow = MessageActionsPlacement.place(message: bottom, bounds: bounds, row: row, menu: menu)
        let menuAbove = noBelow.menu.y + menu.height <= bottom.minY
        let rowAbove = noBelow.row.y + row.height <= bottom.minY
        try require(menuAbove && rowAbove, "No room below moves the menu above the message")
        try require(inside(noBelow.row, row) && inside(noBelow.menu, menu) && !overlap(noBelow), "No room below keeps both inside the window")

        let tall = CGRect(x: 300, y: -200, width: 500, height: 1600)
        let fill = MessageActionsPlacement.place(message: tall, bounds: bounds, row: row, menu: menu)
        try require(inside(fill.row, row) && inside(fill.menu, menu), "A message taller than the window keeps both inside the window")
        try require(!overlap(fill), "A message taller than the window keeps the row and menu apart")

        let gone = CGRect(x: 300, y: -400, width: 500, height: 60)
        let offscreen = MessageActionsPlacement.place(message: gone, bounds: bounds, row: row, menu: menu)
        try require(inside(offscreen.row, row) && inside(offscreen.menu, menu), "A message outside the window still keeps both inside it")

        let edge = CGRect(x: 1100, y: 400, width: 60, height: 40)
        let clamped = MessageActionsPlacement.place(message: edge, bounds: bounds, row: row, menu: menu)
        try require(inside(clamped.row, row) && inside(clamped.menu, menu), "A message near the side keeps both inside the window")
    }

    static func holdRule() throws {
        let origin = CGPoint(x: 100, y: 100)
        var held = MessageHoldTracker()
        held.down(at: origin, time: 10)
        held.moved(to: CGPoint(x: 102, y: 101))
        try require(!held.opens(at: 10.3), "Not open before the threshold")
        try require(held.opens(at: 10 + MessageHoldTracker.threshold), "Held past the threshold without moving opens")

        var dragged = MessageHoldTracker()
        dragged.down(at: origin, time: 10)
        dragged.moved(to: CGPoint(x: 100 + MessageHoldTracker.tolerance + 2, y: 100))
        dragged.moved(to: origin)
        try require(!dragged.opens(at: 11), "Moving beyond the allowed distance never opens, even after coming back")
        try require(dragged.abandoned, "A drag abandons the hold")

        var early = MessageHoldTracker()
        early.down(at: origin, time: 10)
        early.release()
        try require(!early.opens(at: 11), "Released early does not open")

        try require(!MessageHoldTracker().opens(at: 100), "No press never opens")
    }

    static func offeredItems() throws {
        try require(MessageReaction.offered == [.thumbsUp, .thumbsDown], "The row offers thumbs up then thumbs down")
        try require(MessageReaction.offered.map(\.label) == ["Thumbs up", "Thumbs down"], "Reaction labels")
        try require(MessageReaction.offered.map(\.emoji) == ["\u{1F44D}", "\u{1F44E}"], "Reactions are emoji")
        try require(MessageMenuAction.offered == [.copy, .selectText], "The menu offers Copy then Select text")
        try require(MessageMenuAction.offered.map(\.label) == ["Copy", "Select text"], "Menu labels")
        try require(MessageActions.accessibilityLabels == ["Copy", "Select text", "Thumbs up", "Thumbs down"],
                    "Accessibility actions are Copy, Select text, Thumbs up, Thumbs down")
    }

    static func copySweep() throws {
        let banned = ["vera", "background", "worker", "agent", "task", "he", "she", "him", "her", "his", "hers"]
        for text in MessageActions.addedStrings + MessageMenuAction.offered.map(\.symbol) {
            let words = text.lowercased().split { !$0.isLetter }.map(String.init)
            let hit = banned.first { words.contains($0) }
            try require(hit == nil, "\"\(text)\" has no banned word")
            try require(!text.contains("\u{2014}"), "\"\(text)\" has no em dash")
        }
    }
}
