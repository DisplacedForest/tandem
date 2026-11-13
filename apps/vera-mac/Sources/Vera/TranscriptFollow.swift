import SwiftUI

struct TranscriptGeometry: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
}

struct ComposerSend: Equatable {
    var conversationID: String?
    var count = 0
}

struct TranscriptFollow: Equatable {
    static let latestMargin: CGFloat = 48
    static let restMargin: CGFloat = 4
    static let movement: CGFloat = 0.5

    private(set) var conversationID: String?
    private(set) var following = true
    private(set) var atLatest = true
    private(set) var holding = false
    private(set) var readerScrolling = false
    private var last: TranscriptGeometry?
    private var seenSends = 0

    var showsJump: Bool { !following && !atLatest }

    mutating func scope(_ id: String, sends: Int) {
        guard conversationID != id else { return }
        self = TranscriptFollow()
        conversationID = id
        seenSends = sends
    }

    mutating func scrollPhase(reader: Bool) {
        readerScrolling = reader
    }

    @discardableResult
    mutating func geometry(_ next: TranscriptGeometry) -> Bool {
        let distance = next.contentHeight - next.offset - next.containerHeight
        atLatest = distance <= Self.latestMargin
        defer { last = next }
        guard let last else { return false }
        let up = next.offset < last.offset - Self.movement
        let down = next.offset > last.offset + Self.movement
        let sameSize = abs(next.contentHeight - last.contentHeight) < Self.movement
            && abs(next.containerHeight - last.containerHeight) < Self.movement
        guard up || down else { return following && !sameSize && distance > Self.restMargin && !readerScrolling }
        if readerScrolling { holding = false }
        guard readerScrolling || (sameSize && !holding) else { return false }
        if up, distance > Self.restMargin {
            following = false
        } else if down, atLatest {
            following = true
        }
        return false
    }

    mutating func jumpToLatest() {
        following = true
        holding = false
    }

    mutating func hold() {
        following = false
        holding = true
    }

    @discardableResult
    mutating func sent(_ sends: Int) -> Bool {
        guard sends != seenSends else { return false }
        seenSends = sends
        following = true
        holding = false
        return true
    }
}

@MainActor
final class TranscriptFollowBox {
    var state = TranscriptFollow()
}

struct JumpToLatestButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            InterfaceIconView(icon: .latest, size: InterfaceIconSize.regular)
                .foregroundStyle(Theme.textPrimary.opacity(hovering ? 1 : 0.85))
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .background(Theme.surface.opacity(0.7), in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Jump to latest")
        .accessibilityLabel("Jump to latest")
    }
}

@MainActor
extension SelfTest {
    static func runTranscriptFollow() throws {
        let require = NativeTaskFixture.require
        func at(_ offset: CGFloat, content: CGFloat = 2000, container: CGFloat = 600) -> TranscriptGeometry {
            TranscriptGeometry(offset: offset, contentHeight: content, containerHeight: container)
        }
        var follow = TranscriptFollow()
        follow.scope("a", sends: 0)
        follow.geometry(at(1400))
        try require(follow.following && follow.atLatest && !follow.showsJump, "A chat starts at the latest message and follows it")
        try require(follow.geometry(at(1400, content: 2300)), "Growth of any kind under a reader who is following asks the view to catch up")
        try require(follow.following && !follow.atLatest && !follow.showsJump, "Content growing under a reader who is following is not taken as scrolling away")
        follow.geometry(at(1700, content: 2300))
        try require(follow.following && follow.atLatest, "Following the growth keeps following")
        follow.scrollPhase(reader: true)
        follow.geometry(at(1700, content: 2600))
        try require(follow.following, "Growth while a finger rests on the trackpad is not scrolling away")
        follow.geometry(at(2000, content: 2600))
        follow.geometry(at(1970, content: 2600))
        follow.scrollPhase(reader: false)
        try require(!follow.following && !follow.showsJump, "A small scroll up stops following, with nothing below to jump to yet")
        try require(!follow.geometry(at(1970, content: 2900)), "Growth under a reader who scrolled away asks for nothing")
        try require(!follow.following && follow.showsJump, "The next growth leaves the reader in place and shows the way back")
        follow.geometry(at(1970, content: 2900, container: 560))
        follow.geometry(at(1970, content: 3200, container: 560))
        try require(!follow.following, "Streaming text, a taller composer and new replies leave a reader who scrolled away where they are")
        follow.scrollPhase(reader: true)
        follow.geometry(at(2640, content: 3200, container: 560))
        follow.scrollPhase(reader: false)
        try require(follow.following && !follow.showsJump, "Scrolling back to the bottom resumes following")
        follow.geometry(at(2000, content: 3200, container: 560))
        try require(!follow.following && follow.showsJump, "Scrolling away without a reported gesture, as a scroll bar drag would, also stops following")
        follow.geometry(at(2640, content: 3200, container: 560))
        try require(follow.following, "Returning the same way resumes following")
        follow.geometry(at(2700, content: 3200, container: 560))
        follow.geometry(at(2640, content: 3200, container: 560))
        try require(follow.following, "Bouncing off the end is not scrolling away")
        follow.geometry(at(2600, content: 3200, container: 600))
        try require(follow.following, "A window resize that moves the view is not scrolling away")
        follow.hold()
        follow.geometry(at(900, content: 3200, container: 600))
        follow.geometry(at(2590, content: 3200, container: 600))
        try require(!follow.following && !follow.showsJump, "Opening a source or a task near the end holds it without resuming, and shows no arrow when nothing is below")
        follow.geometry(at(2590, content: 3600, container: 600))
        try require(!follow.following && follow.showsJump, "That place holds against the next update")
        follow.jumpToLatest()
        try require(follow.following && !follow.showsJump, "The arrow resumes following")
        follow.hold()
        try require(!follow.sent(0) && !follow.following, "A scheduled run or a reload that adds messages is not the reader sending")
        try require(follow.sent(1) && follow.following, "Sending a message returns to the latest")
        try require(!follow.sent(1), "One send is taken once")
        follow.hold()
        follow.scope("a", sends: 1)
        try require(!follow.following && follow.holding, "A place held just before the conversation finishes opening survives it")
        follow.scrollPhase(reader: true)
        follow.scope("b", sends: 1)
        try require(follow.following && follow.atLatest && !follow.holding && !follow.readerScrolling, "Another conversation starts fresh at its latest message")
        try require(!follow.sent(1), "A send in the conversation left behind does not carry over")
        let suite = "transcript-follow-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NativeTaskFixture.Failure.assertion("Isolated transcript storage") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let messages = [UUID(), UUID(), UUID()]
        let saved = CompanionTranscriptContinuity(defaults: defaults)
        _ = saved.begin(conversationID: "c", messages: messages)
        saved.observe(visible: [messages[1], messages[2]], ordered: messages, conversationID: "c")
        saved.follows(false, conversationID: "c")
        try require(CompanionTranscriptContinuity(defaults: defaults).begin(conversationID: "c", messages: messages) == nil,
                    "Nothing is saved while a saved position is still being restored")
        saved.finishRestoring(conversationID: "c")
        saved.follows(false, conversationID: "c")
        try require(CompanionTranscriptContinuity(defaults: defaults).begin(conversationID: "c", messages: messages) == messages[1],
                    "A small scroll up is saved with the message being read, without a gesture having been reported")
        saved.follows(true, conversationID: "c")
        try require(CompanionTranscriptContinuity(defaults: defaults).begin(conversationID: "c", messages: messages) == nil,
                    "The arrow or a send is saved as back at the latest")
        saved.follows(false, conversationID: "other")
        try require(CompanionTranscriptContinuity(defaults: defaults).begin(conversationID: "c", messages: messages) == nil,
                    "A stale callback for another conversation saves nothing")
        print("  transcript follow OK (follows at the bottom, growth is not scrolling, small and large scrolls away, scroll bar style moves, bounce, resize, updates while away, scroll back, arrow only with content below, reveal hold, explicit send, conversation change, catch up on any growth, saved companion position)")
    }
}
