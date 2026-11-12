import SwiftUI
import AppKit

enum MessageReaction: String, CaseIterable, Identifiable {
    case thumbsUp
    case thumbsDown

    var id: String { rawValue }

    static let offered: [MessageReaction] = [.thumbsUp, .thumbsDown]

    var emoji: String {
        switch self {
        case .thumbsUp: "\u{1F44D}"
        case .thumbsDown: "\u{1F44E}"
        }
    }

    var label: String {
        switch self {
        case .thumbsUp: "Thumbs up"
        case .thumbsDown: "Thumbs down"
        }
    }

    var rating: String {
        switch self {
        case .thumbsUp: "up"
        case .thumbsDown: "down"
        }
    }

    init?(rating: String?) {
        guard let match = Self.allCases.first(where: { $0.rating == rating }) else { return nil }
        self = match
    }

    static func marks(rating: String?) -> [MessageReaction] {
        MessageReaction(rating: rating).map { [$0] } ?? []
    }

    static func onAnnouncement(_ marks: [MessageReaction]) -> String {
        guard let first = marks.first else { return "No reaction" }
        return first.label + " is on"
    }
}

enum MessageMenuAction: String, CaseIterable, Identifiable {
    case copy
    case selectText

    var id: String { rawValue }

    static let offered: [MessageMenuAction] = [.copy, .selectText]

    var label: String {
        switch self {
        case .copy: "Copy"
        case .selectText: "Select text"
        }
    }

    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .selectText: "text.viewfinder"
        }
    }
}

enum MessageActions {
    static func offered(companionThread: Bool) -> Bool { companionThread }

    static func copiedText(_ message: Message) -> String {
        message.role == .user ? message.text : AssistantBody.copiedText(message)
    }

    static func selectableText(_ message: Message) -> String {
        let shown = message.role == .user ? message.text : AssistantBody.shownText(message)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard message.role == .assistant, let parsed = try? AttributedString(markdown: shown, options: options) else { return shown }
        return String(parsed.characters)
    }

    static func copy(_ message: Message) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedText(message), forType: .string)
    }

    static var accessibilityLabels: [String] {
        MessageMenuAction.offered.map(\.label) + MessageReaction.offered.map(\.label)
    }

    static var addedStrings: [String] {
        let announcements = [MessageReaction.onAnnouncement([])] + MessageReaction.offered.map { MessageReaction.onAnnouncement([$0]) }
        return accessibilityLabels + announcements + [MessageActionsMetrics.rowLabel, MessageActionsMetrics.menuLabel]
    }
}

struct MessageHoldTracker: Equatable {
    static let threshold: TimeInterval = 0.5
    static let tolerance: CGFloat = 4

    private(set) var origin: CGPoint?
    private(set) var startedAt: TimeInterval = 0
    private(set) var farthest: CGFloat = 0
    private(set) var released = false
    private(set) var cancelled = false

    mutating func down(at point: CGPoint, time: TimeInterval) {
        self = MessageHoldTracker()
        origin = point
        startedAt = time
    }

    mutating func moved(to point: CGPoint) {
        guard let origin else { return }
        farthest = max(farthest, hypot(point.x - origin.x, point.y - origin.y))
    }

    mutating func release() { released = true }

    mutating func cancel() { cancelled = true }

    mutating func reset() { self = MessageHoldTracker() }

    func opens(at time: TimeInterval) -> Bool {
        let pressed = origin != nil
        let stillDown = !released
        let heldLongEnough = time - startedAt >= Self.threshold
        let stayedPut = farthest <= Self.tolerance
        return pressed && stillDown && !cancelled && heldLongEnough && stayedPut
    }

    func opens(at time: TimeInterval, bubbleFrame: CGRect?, pointer: CGPoint?) -> Bool {
        guard let bubbleFrame, let pointer else { return false }
        let stillUnderPointer = !bubbleFrame.isEmpty && bubbleFrame.contains(pointer)
        return opens(at: time) && stillUnderPointer
    }

    var abandoned: Bool { origin == nil || released || cancelled || farthest > Self.tolerance }
}

enum MessageActionsEventKind: Equatable {
    case escape
    case secondaryClick
    case holdStart
}

struct MessageActionsEventContext: Equatable {
    var hostWindow: Bool
    var key: Bool
    var sheet: Bool
    var overlayOpen: Bool
    var onBubble: Bool
    var onOverlayControls: Bool
}

enum MessageActionsEventPolicy {
    static func acts(_ kind: MessageActionsEventKind, _ context: MessageActionsEventContext) -> Bool {
        let ownWindow = context.hostWindow && context.key && !context.sheet
        guard ownWindow else { return false }
        switch kind {
        case .escape:
            return context.overlayOpen
        case .secondaryClick, .holdStart:
            return context.onBubble && !context.onOverlayControls
        }
    }

    static func consumes(_ kind: MessageActionsEventKind, _ context: MessageActionsEventContext) -> Bool {
        kind != .holdStart && acts(kind, context)
    }
}

struct MessageActionsPlacement: Equatable {
    var row: CGPoint
    var menu: CGPoint

    static let gap: CGFloat = 8
    static let margin: CGFloat = 12

    static func place(message: CGRect, bounds: CGRect, row: CGSize, menu: CGSize) -> MessageActionsPlacement {
        let inner = bounds.insetBy(dx: margin, dy: margin)
        let placed = preferred(message: message, inner: inner, row: row, menu: menu)
        let rowY = clamp(placed.row.y, low: inner.minY, high: inner.maxY - row.height)
        let menuY = clamp(placed.menu.y, low: inner.minY, high: inner.maxY - menu.height)
        return MessageActionsPlacement(row: CGPoint(x: placed.row.x, y: rowY), menu: CGPoint(x: placed.menu.x, y: menuY))
    }

    private static func preferred(message: CGRect, inner: CGRect, row: CGSize, menu: CGSize) -> MessageActionsPlacement {
        let clipped = message.intersection(inner)
        let visible = clipped.isNull ? message : clipped
        let rowAbove = visible.minY - gap - row.height
        let menuBelow = visible.maxY + gap
        let roomAbove = rowAbove >= inner.minY
        let roomBelow = menuBelow + menu.height <= inner.maxY
        let rowX = clamp(message.minX, low: inner.minX, high: inner.maxX - row.width)
        let menuX = clamp(message.maxX - menu.width, low: inner.minX, high: inner.maxX - menu.width)
        let inside = MessageActionsPlacement(row: CGPoint(x: rowX, y: max(inner.minY, visible.minY + gap)),
                                             menu: CGPoint(x: menuX, y: min(inner.maxY - menu.height, visible.maxY - gap - menu.height)))
        switch (roomAbove, roomBelow) {
        case (true, true):
            return MessageActionsPlacement(row: CGPoint(x: rowX, y: rowAbove), menu: CGPoint(x: menuX, y: menuBelow))
        case (false, true):
            let rowY = visible.maxY + gap
            let menuY = rowY + row.height + gap
            let fits = menuY + menu.height <= inner.maxY
            return fits ? MessageActionsPlacement(row: CGPoint(x: rowX, y: rowY), menu: CGPoint(x: menuX, y: menuY)) : inside
        case (true, false):
            let menuY = rowAbove - gap - menu.height
            let fits = menuY >= inner.minY
            return fits ? MessageActionsPlacement(row: CGPoint(x: rowX, y: rowAbove), menu: CGPoint(x: menuX, y: menuY)) : inside
        case (false, false):
            return inside
        }
    }

    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}

enum MessageActionsMetrics {
    static let itemSize: CGFloat = 38
    static let rowPadding: CGFloat = 6
    static let rowSpacing: CGFloat = 4
    static let menuWidth: CGFloat = 184
    static let menuRowHeight: CGFloat = 36
    static let menuPadding: CGFloat = 6
    static let markOverhang: CGFloat = 10
    static let rowLabel = "Reactions"
    static let menuLabel = "Message actions"

    static var rowSize: CGSize {
        let count = CGFloat(MessageReaction.offered.count)
        let width = rowPadding * 2 + count * itemSize + max(0, count - 1) * rowSpacing
        return CGSize(width: width, height: itemSize + rowPadding * 2)
    }

    static var menuSize: CGSize {
        CGSize(width: menuWidth, height: CGFloat(MessageMenuAction.offered.count) * menuRowHeight + menuPadding * 2)
    }
}

struct MessageActionsTarget: Equatable {
    let messageID: UUID
    let conversationID: String?

    func current(in conversations: [Conversation]) -> Message? {
        let owner = conversations.first { $0.id == conversationID }
        let pool = owner.map { [$0] } ?? conversations
        for conversation in pool {
            if let message = conversation.messages.first(where: { $0.id == messageID }) { return message }
        }
        return nil
    }
}

@MainActor
@Observable
final class MessageActionsModel {
    var open: MessageActionsTarget?
    var selecting: UUID?

    struct Bubble: Equatable {
        let messageID: UUID
        let conversationID: String?
        let frame: CGRect
        let visible: CGRect
    }

    @ObservationIgnored private(set) var bubbles: [UUID: Bubble] = [:]
    @ObservationIgnored var hold = MessageHoldTracker()
    @ObservationIgnored var holdTarget: UUID?
    @ObservationIgnored var controls: [CGRect] = []
    @ObservationIgnored private(set) var openedAt: CGRect?
    @ObservationIgnored var anchorShown = false

    static let moveTolerance: CGFloat = 0.5

    init(open: MessageActionsTarget? = nil) { self.open = open }

    func register(_ id: UUID, conversationID: String?, frame: CGRect, visible: CGRect) {
        bubbles[id] = Bubble(messageID: id, conversationID: conversationID, frame: frame, visible: visible)
        guard open?.messageID == id else { return }
        guard let openedAt else { return }
        let movedX = abs(frame.minX - openedAt.minX) > Self.moveTolerance
        let movedY = abs(frame.minY - openedAt.minY) > Self.moveTolerance
        if movedX || movedY { close() }
    }

    func unregister(_ id: UUID) {
        bubbles[id] = nil
        if open?.messageID == id { close() }
        if holdTarget == id { cancelHold() }
    }

    func bubble(at point: CGPoint) -> Bubble? {
        bubbles.values.first { !$0.visible.isEmpty && $0.visible.contains(point) }
    }

    func onControls(_ point: CGPoint) -> Bool {
        open != nil && controls.contains { $0.contains(point) }
    }

    func visibleFrame(_ id: UUID) -> CGRect? { bubbles[id]?.visible }

    @discardableResult
    func present(_ id: UUID, conversationID: String?) -> Bool {
        guard let bubble = bubbles[id] else { return false }
        selecting = nil
        cancelHold()
        controls = []
        openedAt = bubble.frame
        open = MessageActionsTarget(messageID: id, conversationID: conversationID ?? bubble.conversationID)
        return true
    }

    func close() {
        controls = []
        openedAt = nil
        if open != nil { open = nil }
    }

    func dismissAll() {
        close()
        cancelHold()
    }

    func cancelHold() {
        hold.cancel()
        holdTarget = nil
    }

    func closeIfGone(in conversations: [Conversation]) {
        guard let open, open.current(in: conversations) == nil else { return }
        close()
    }

    func beginSelecting(_ id: UUID) {
        close()
        selecting = id
    }

    func endSelecting(_ id: UUID) {
        if selecting == id { selecting = nil }
    }
}

extension EnvironmentValues {
    @Entry var messageActions: MessageActionsModel? = nil
}

struct MessageActionsShownKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct MessageActionsAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
