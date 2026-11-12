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
        try openStateFollowsBubble()
        try holdAfterScroll()
        try copyUsesCurrentMessage()
        try eventPolicy()
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

    static func openStateFollowsBubble() throws {
        let model = MessageActionsModel()
        let first = UUID()
        let second = UUID()
        let frame = CGRect(x: 100, y: 200, width: 400, height: 60)
        try require(!model.present(first, conversationID: "c"), "Nothing opens on a bubble that isn't drawn")
        model.register(first, conversationID: "c", frame: frame, visible: frame)
        model.register(second, conversationID: "c", frame: frame.offsetBy(dx: 0, dy: 100), visible: frame.offsetBy(dx: 0, dy: 100))
        try require(model.present(first, conversationID: "c") && model.open?.messageID == first, "Opens on a drawn bubble")
        model.unregister(first)
        try require(model.open == nil, "Unregistering the open bubble closes it")
        try require(model.present(second, conversationID: "c") && model.open?.messageID == second, "A new open succeeds after that")

        model.register(first, conversationID: "c", frame: frame, visible: frame)
        try require(model.present(first, conversationID: "c") && model.open?.messageID == first, "A new open replaces one already open")
        let kept = [CGRect(x: 1, y: 2, width: 3, height: 4)]
        model.controls = kept
        try require(model.present(first, conversationID: "c") && model.controls == kept, "Opening the open message again keeps its row and menu protected")
        model.hold.down(at: .zero, time: 0)
        model.holdTarget = first
        model.close()
        let holdEnded = model.holdTarget == nil && model.hold.abandoned
        try require(holdEnded && model.open == nil, "Closing ends a pending hold")
        try require(model.present(first, conversationID: "c"), "It opens again after closing")

        model.register(first, conversationID: "c", frame: frame.insetBy(dx: 0, dy: -20).offsetBy(dx: 0, dy: 20), visible: frame)
        try require(model.open?.messageID == first, "The open bubble growing below its top edge stays open")
        model.register(first, conversationID: "c", frame: frame.offsetBy(dx: 0, dy: -300), visible: .zero)
        try require(model.open == nil, "The open bubble moving, as in any scroll, closes it")

        let message = Message(role: .assistant, text: "Here")
        let conversation = Conversation(id: "c", title: "C", messages: [message], updatedAt: Date())
        model.register(message.id, conversationID: "c", frame: frame, visible: frame)
        _ = model.present(message.id, conversationID: "c")
        model.closeIfGone(in: [conversation])
        try require(model.open?.messageID == message.id, "Stays open while the message exists")
        var emptied = conversation
        emptied.messages = []
        model.closeIfGone(in: [emptied])
        try require(model.open == nil, "Closes when the message is no longer in the conversation")
    }

    static func holdAfterScroll() throws {
        let origin = CGPoint(x: 100, y: 100)
        let pointer = CGPoint(x: 150, y: 220)
        let frame = CGRect(x: 100, y: 200, width: 400, height: 60)

        var steady = MessageHoldTracker()
        steady.down(at: origin, time: 10)
        try require(steady.opens(at: 10.6, bubbleFrame: frame, pointer: pointer), "A steady hold over its bubble opens")

        var scrolled = MessageHoldTracker()
        scrolled.down(at: origin, time: 10)
        scrolled.cancel()
        try require(!scrolled.opens(at: 11) && !scrolled.opens(at: 11, bubbleFrame: frame, pointer: pointer), "A scroll during the hold never opens")
        try require(scrolled.abandoned, "A scroll abandons the hold for good")
        scrolled.moved(to: origin)
        try require(!scrolled.opens(at: 20), "A cancelled hold stays cancelled")

        var shifted = MessageHoldTracker()
        shifted.down(at: origin, time: 10)
        try require(!shifted.opens(at: 10.6, bubbleFrame: frame.offsetBy(dx: 0, dy: 300), pointer: pointer),
                    "The bubble moved away from the pointer never opens")
        try require(!shifted.opens(at: 10.6, bubbleFrame: nil, pointer: pointer), "A bubble that is gone never opens")
        try require(!shifted.opens(at: 10.6, bubbleFrame: frame, pointer: nil), "An unknown pointer never opens")
    }

    static func copyUsesCurrentMessage() throws {
        var message = Message(role: .assistant, text: "Partial ans", state: .streaming)
        let target = MessageActionsTarget(messageID: message.id, conversationID: "c")
        var conversation = Conversation(id: "c", title: "C", messages: [message], updatedAt: Date())
        try require(target.current(in: [conversation]).map(MessageActions.copiedText) == "Partial ans", "Copy reads the message as it is now")
        message.text = "The finished answer."
        message.state = .complete
        conversation.messages = [message]
        try require(target.current(in: [conversation]).map(MessageActions.copiedText) == "The finished answer.",
                    "Copy after the reply changed yields the new text")
        conversation.messages = []
        try require(target.current(in: [conversation]) == nil, "A removed message resolves to nothing")
    }

    static func eventPolicy() throws {
        let own = MessageActionsEventContext(hostWindow: true, key: true, sheet: false, overlayOpen: true, onBubble: true, onOverlayControls: false)
        try require(MessageActionsEventPolicy.consumes(.escape, own), "Escape in the host window with it open is consumed")
        try require(MessageActionsEventPolicy.consumes(.secondaryClick, own), "A right click on a bubble in the host window is consumed")
        try require(!MessageActionsEventPolicy.consumes(.holdStart, own), "A press never consumes its event")
        try require(!MessageActionsEventPolicy.acts(.holdStart, own), "A press never starts a hold while one is open")

        var closed = own
        closed.overlayOpen = false
        try require(MessageActionsEventPolicy.acts(.holdStart, closed), "A press on a bubble starts a hold when nothing is open")
        try require(!MessageActionsEventPolicy.consumes(.escape, closed), "Escape passes through when nothing is open")

        for (label, change) in [("another window", { (c: inout MessageActionsEventContext) in c.hostWindow = false }),
                                ("a window that isn't key", { (c: inout MessageActionsEventContext) in c.key = false }),
                                ("a window with a sheet", { (c: inout MessageActionsEventContext) in c.sheet = true })] {
            var context = own
            change(&context)
            for kind in [MessageActionsEventKind.escape, .secondaryClick, .holdStart] {
                try require(!MessageActionsEventPolicy.acts(kind, context) && !MessageActionsEventPolicy.consumes(kind, context),
                            "Nothing is acted on or consumed in \(label)")
            }
        }

        var offBubble = own
        offBubble.onBubble = false
        try require(!MessageActionsEventPolicy.consumes(.secondaryClick, offBubble), "A right click off any bubble passes through")
        var onControls = own
        onControls.onOverlayControls = true
        try require(!MessageActionsEventPolicy.acts(.secondaryClick, onControls) && !MessageActionsEventPolicy.acts(.holdStart, onControls),
                    "Clicks on the row or menu are left to them")
    }
}
