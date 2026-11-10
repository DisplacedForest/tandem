import SwiftUI

struct TranscriptFollow: Equatable {
    private(set) var following = true
    private(set) var readerScrolling = false

    var showsJump: Bool { !following }

    mutating func begin(atLatest: Bool = true) {
        following = atLatest
        readerScrolling = false
    }

    mutating func scrollPhase(reader: Bool) {
        readerScrolling = reader
    }

    mutating func geometry(nearBottom: Bool) {
        guard readerScrolling else { return }
        following = nearBottom
    }

    mutating func jumpToLatest() {
        following = true
    }

    mutating func revealed() {
        following = false
    }

    mutating func messagesAdded(fromReader: Bool) {
        if fromReader { following = true }
    }
}

struct JumpToLatestButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
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
        var follow = TranscriptFollow()
        try require(follow.following && !follow.showsJump, "A chat starts at the latest message and follows it")
        follow.geometry(nearBottom: false)
        try require(follow.following, "Content growing under a reader who is following is not taken as scrolling away")
        follow.scrollPhase(reader: true)
        follow.geometry(nearBottom: true)
        try require(follow.following, "A small scroll that stays at the bottom keeps following")
        follow.geometry(nearBottom: false)
        follow.scrollPhase(reader: false)
        try require(!follow.following && follow.showsJump, "Scrolling up stops following and shows the way back")
        follow.geometry(nearBottom: false)
        follow.geometry(nearBottom: true)
        follow.messagesAdded(fromReader: false)
        try require(!follow.following, "Streaming text, layout changes and new replies leave a reader who scrolled away where they are")
        follow.scrollPhase(reader: true)
        follow.geometry(nearBottom: true)
        follow.scrollPhase(reader: false)
        try require(follow.following && !follow.showsJump, "Scrolling back to the bottom resumes following")
        follow.revealed()
        follow.geometry(nearBottom: false)
        try require(!follow.following, "Opening a source or a task holds that place against the next update")
        follow.jumpToLatest()
        try require(follow.following && !follow.showsJump, "The arrow resumes following")
        follow.revealed()
        follow.messagesAdded(fromReader: true)
        try require(follow.following, "Sending a message returns to the latest")
        follow.scrollPhase(reader: true)
        follow.geometry(nearBottom: false)
        follow.begin()
        try require(follow.following && !follow.readerScrolling, "Another conversation starts fresh at its latest message")
        follow.begin(atLatest: false)
        try require(!follow.following && follow.showsJump, "A conversation restored to an earlier message starts with following off")
        print("  transcript follow OK (follows at the bottom, growth is not scrolling, scroll away, updates while away, scroll back, arrow, reveal, send, conversation change, restored position)")
    }
}
