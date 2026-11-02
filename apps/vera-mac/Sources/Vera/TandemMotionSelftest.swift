import SwiftUI
import AppKit

@MainActor
extension SelfTest {
    static func runTandemMotion() async throws {
        let require = NativeTaskFixture.require
        let expected: [(String, Double, Bool)] = [
            ("Breathe", 4.8, true), ("Hello", 1.45, false), ("Exchange", 2.1, false), ("Orbit", 3.4, false),
            ("Rally", 1.8, false), ("Nudge", 1.5, false), ("Listen", 2.4, true), ("Speak", 1.65, true),
            ("Gather", 1.7, false), ("Pause", 1.2, false), ("Recover", 1.45, false), ("Rest", 2.7, false),
        ]
        guard let document = TandemMotionLibrary.document else {
            throw NativeTaskFixture.Failure.assertion("The motion timeline loads from the resource bundle")
        }
        let sequences = TandemMotionLibrary.sequences
        try require(sequences.count == 12, "The motion timeline has twelve sequences")
        for (sequence, want) in zip(sequences, expected) {
            try require(sequence.name == want.0 && abs(sequence.duration - want.1) < 1e-9 && sequence.loop == want.2,
                        "\(want.0) has the expected name, duration and loop policy")
        }
        try require(Set(TandemLogoCue.allCases.map(\.rawValue)) == Set(sequences.map(\.name)), "Every cue names a sequence")
        try require(document.viewBox == TandemLogoGeometry.motionBox, "The motion box matches the timeline geometry")
        try require(document.radius == Double(TandemLogoGeometry.radius) && document.left == TandemLogoGeometry.leftCenter
                    && document.right == TandemLogoGeometry.rightCenter && document.center == TandemLogoGeometry.pairCenter,
                    "The master geometry matches the timeline geometry")

        func near(_ a: TandemLogoCircle, _ b: TandemLogoCircle) -> Bool {
            abs(a.center.x - b.center.x) < 1e-6 && abs(a.center.y - b.center.y) < 1e-6 && abs(a.radius - b.radius) < 1e-6
        }
        func rendersAsRest(_ pose: TandemLogoPose) -> Bool {
            let a = TandemLogoGeometry.circles(for: pose), b = TandemLogoGeometry.circles(for: .rest)
            return near(a.left, b.left) && near(a.right, b.right)
        }
        let displacedStarts: Set<String> = ["Pause", "Rest"]
        for sequence in sequences {
            guard let first = sequence.frames.first, let last = sequence.frames.last else {
                throw NativeTaskFixture.Failure.assertion("\(sequence.name) has frames")
            }
            try require(first.time == 0 && last.time == 1, "\(sequence.name) spans the whole timeline")
            try require(rendersAsRest(last.pose), "\(sequence.name) ends at rest")
            try require(displacedStarts.contains(sequence.name) || rendersAsRest(first.pose), "\(sequence.name) starts at rest")
            for step in 0...200 {
                let pose = TandemLogoMotionCheck.sample(sequence, step, of: 200)
                let circles = TandemLogoGeometry.circles(for: pose)
                try require(document.viewBox.contains(circles.left.bounds) && document.viewBox.contains(circles.right.bounds),
                            "\(sequence.name) stays inside the motion box at step \(step)")
            }
            for frame in sequence.frames {
                try require(TandemMotionLibrary.pose(in: sequence, at: frame.time) == frame.pose,
                            "\(sequence.name) returns its keyframe exactly at \(frame.time)")
            }
            try require(TandemMotionLibrary.pose(in: sequence, at: -0.1) == .rest
                        && TandemMotionLibrary.pose(in: sequence, at: 1.1) == .rest, "\(sequence.name) rests outside its range")
        }
        if let orbit = TandemMotionLibrary.sequence(named: "Orbit") {
            try require(orbit.frames.last?.pose.angle == 360, "Orbit turns a full circle")
        }

        let rect = CGRect(x: 0, y: 0, width: 410, height: 256)
        let resting = TandemLogoGeometry.paths(for: .rest, in: rect)
        try require(!resting.overlap.isEmpty && resting.overlap.boundingRect.width > 1, "The resting pair overlaps")
        try require(abs(resting.overlap.boundingRect.width - 102) < 1, "The resting overlap is the lens between the circles")
        var apart = TandemLogoPose.rest
        apart.leftOffset = CGVector(dx: -160, dy: 0)
        apart.rightOffset = CGVector(dx: 160, dy: 0)
        let separated = TandemLogoGeometry.paths(for: apart, in: rect)
        try require(separated.overlap.isEmpty || separated.overlap.boundingRect.width < 1e-6, "Separated circles do not overlap")
        let wide = TandemLogoGeometry.paths(for: .rest, in: CGRect(x: 0, y: 0, width: 820, height: 256))
        try require(abs(wide.left.boundingRect.width - 256) < 1e-6 && abs(wide.left.boundingRect.minX - 205) < 1e-6,
                    "The master box fits a wider rect while keeping its aspect")

        let template = TandemTemplate.image(pointSize: 18)
        try require(template.isTemplate, "The template mark is a template image")
        try require(abs(template.size.height - 18) < 1e-9 && abs(template.size.width - 18 * 410 / 256) < 1e-9,
                    "The template mark has the expected size")
        let templatePath = TandemTemplate.templatePath(in: rect)
        try require(!templatePath.contains(CGPoint(x: 205, y: 128)) && templatePath.contains(CGPoint(x: 60, y: 128))
                    && templatePath.contains(CGPoint(x: 350, y: 128)), "The template knocks out the intersection")

        let frame = 1.0 / 60.0
        func run(_ controller: TandemMotionController, seconds: Double) {
            var t = 0.0
            while t < seconds { controller.advance(by: frame); t += frame }
        }

        let hello = TandemMotionController(reduceMotion: false, manualClock: true)
        hello.isVisible = true
        var helloDone = 0
        hello.play("Hello") { helloDone += 1 }
        try require(hello.activeSequence == "Hello" && !hello.isDriving, "Hello starts on the manual clock")
        run(hello, seconds: 0.6)
        try require(hello.pose != .rest, "Hello moves the pair")
        run(hello, seconds: 1.2)
        try require(hello.pose == .rest && hello.activeSequence == nil && helloDone == 1, "Hello completes once and ends at rest")

        let interrupted = TandemMotionController(reduceMotion: false, manualClock: true)
        interrupted.isVisible = true
        var orbitDone = 0, nudgeDone = 0
        interrupted.play("Orbit") { orbitDone += 1 }
        run(interrupted, seconds: 1.2)
        let live = interrupted.pose
        try require(live != .rest, "Orbit is underway before the interrupt")
        interrupted.play("Nudge") { nudgeDone += 1 }
        let nudgeStart = TandemMotionLibrary.sequence(named: "Nudge")?.frames.first?.pose ?? .rest
        interrupted.advance(by: TandemMotionController.blendDuration / 2)
        let blended = interrupted.pose
        let whole = TandemLogoMotionCheck.distance(live, nudgeStart)
        let parts = TandemLogoMotionCheck.distance(live, blended) + TandemLogoMotionCheck.distance(blended, nudgeStart)
        try require(blended != live && TandemLogoMotionCheck.distance(blended, nudgeStart) < whole && abs(parts - whole) < 1e-6,
                    "The interrupt blends from the live pose toward the new sequence")
        try require(interrupted.activeSequence == "Nudge", "The interrupt takes over the active sequence")
        run(interrupted, seconds: 2)
        try require(nudgeDone == 1 && orbitDone == 0, "Only the latest completion fires")
        try require(interrupted.pose == .rest && interrupted.activeSequence == nil, "The interrupt ends at rest")

        let stopping = TandemMotionController(reduceMotion: false, manualClock: true)
        stopping.isVisible = true
        stopping.play("Breathe")
        run(stopping, seconds: 1.3)
        try require(stopping.pose != .rest && stopping.activeSequence == "Breathe", "Breathe loops until stopped")
        run(stopping, seconds: 6)
        try require(stopping.activeSequence == "Breathe" && stopping.isAnimating, "A looping sequence keeps running")
        run(stopping, seconds: 0.5)
        stopping.stop()
        try require(stopping.activeSequence == nil, "Stopping clears the active sequence")
        run(stopping, seconds: 1.5)
        try require(stopping.pose == .rest && !stopping.isAnimating, "Stopping eases back to rest")

        let reduced = TandemMotionController(reduceMotion: true, manualClock: true)
        reduced.isVisible = true
        var reducedDone = 0
        reduced.play("Hello") { reducedDone += 1 }
        run(reduced, seconds: 0.5)
        try require(reduced.pose == .rest && !reduced.isAnimating && reducedDone == 1, "Reduce Motion keeps the pair at rest")
        reduced.play("Listen")
        try require(reduced.pose == .rest && reduced.activeSequence == "Listen", "Reduce Motion records a loop for status only")

        let hidden = TandemMotionController(reduceMotion: false, manualClock: true)
        var hiddenDone = 0
        hidden.play("Hello") { hiddenDone += 1 }
        run(hidden, seconds: 0.5)
        try require(hidden.pose == .rest, "An unseen controller does not advance")
        hidden.isVisible = true
        run(hidden, seconds: 0.5)
        let held = hidden.pose
        hidden.isVisible = false
        run(hidden, seconds: 0.5)
        try require(hidden.pose == held && held != .rest, "Hiding holds the last pose")
        hidden.isVisible = true
        run(hidden, seconds: TandemMotionController.blendDuration + 0.05)
        try require(hidden.pose == .rest && hiddenDone == 1 && hidden.activeSequence == nil,
                    "An interrupted one-shot completes to rest when shown again")

        let looping = TandemMotionController(reduceMotion: false, manualClock: true)
        looping.isVisible = true
        looping.play("Listen")
        run(looping, seconds: 0.7)
        looping.isVisible = false
        looping.isVisible = true
        run(looping, seconds: 0.3)
        try require(looping.activeSequence == "Listen" && looping.isAnimating, "A looping sequence resumes when shown again")

        let driven = TandemMotionController(reduceMotion: false)
        try require(!driven.isDriving, "An idle controller has no timer")
        driven.play("Hello")
        try require(!driven.isDriving, "An unseen controller has no timer")
        driven.isVisible = true
        try require(driven.isDriving, "A visible animation runs its timer")
        driven.isPaused = true
        try require(!driven.isDriving, "Pausing stops the timer")
        driven.isPaused = false
        driven.stop()
        driven.isVisible = false
        try require(!driven.isDriving, "Hiding stops the timer")

        let hosted = TandemMotionController(reduceMotion: false)
        let first = UUID(), second = UUID()
        hosted.play("Breathe")
        hosted.setHost(first, visible: true)
        hosted.setHost(second, visible: true)
        hosted.setHost(first, visible: false)
        try require(hosted.isVisible && hosted.isDriving, "One remaining visible host keeps the animation running")
        hosted.setHost(second, visible: false)
        try require(!hosted.isVisible && !hosted.isDriving, "Hiding the last host stops the timer")
        hosted.setHost(first, visible: true)
        try require(hosted.isDriving, "A host that reappears restarts the timer")
        hosted.stop()
        hosted.setHost(first, visible: false)

        let toggled = TandemMotionController(reduceMotion: false)
        toggled.isVisible = true
        toggled.play("Breathe")
        try require(toggled.isDriving, "A visible loop drives its timer before Reduce Motion changes")
        toggled.reduceMotion = true
        try require(!toggled.isDriving && toggled.pose == .rest && toggled.activeSequence == "Breathe",
                    "Turning Reduce Motion on mid-loop stops the timer and rests the pair")
        toggled.reduceMotion = false
        try require(toggled.isDriving && toggled.activeSequence == "Breathe", "Turning Reduce Motion off resumes the loop")
        toggled.stop()
        toggled.isVisible = false
        try require(TandemMotionGalleryView.reduces(system: true, toggle: false) && TandemMotionGalleryView.reduces(system: false, toggle: true)
                    && !TandemMotionGalleryView.reduces(system: false, toggle: false), "The gallery reduces motion when either the system or its toggle asks")

        let rect10 = CGRect(x: 0, y: 0, width: 10, height: 10)
        let probeWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        probeWindow.isReleasedWhenClosed = false
        try require(!TandemHostVisibilityView.hostVisible(window: nil, occluded: false, hidden: false, visibleRect: rect10),
                    "A host without a window is not visible")
        try require(!TandemHostVisibilityView.hostVisible(window: probeWindow, occluded: false, hidden: false, visibleRect: rect10),
                    "A host in a window that is not on screen is not visible")
        probeWindow.orderFront(nil)
        try require(TandemHostVisibilityView.hostVisible(window: probeWindow, occluded: false, hidden: false, visibleRect: rect10),
                    "A host in a shown window with a visible rect is visible")
        try require(!TandemHostVisibilityView.hostVisible(window: probeWindow, occluded: true, hidden: false, visibleRect: rect10),
                    "An occluded window hides its host")
        try require(!TandemHostVisibilityView.hostVisible(window: probeWindow, occluded: false, hidden: true, visibleRect: rect10),
                    "A hidden view hides its host")
        try require(!TandemHostVisibilityView.hostVisible(window: probeWindow, occluded: false, hidden: false, visibleRect: .zero),
                    "A host scrolled out of its clip is not visible")

        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let page = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 600))
        let probe = TandemHostVisibilityView(frame: CGRect(x: 0, y: 500, width: 200, height: 40))
        var seen: [Bool] = []
        probe.onChange = { seen.append($0) }
        page.addSubview(probe)
        scroll.documentView = page
        probeWindow.contentView = scroll
        scroll.contentView.scroll(to: .zero)
        probe.evaluate()
        try require(!probe.isHostVisible, "A probe scrolled out of view reports hidden")
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        probe.evaluate()
        let onScreen = probeWindow.occlusionState.contains(.visible)
        try require(probe.isHostVisible == onScreen, "A probe scrolled into view reports the window's visibility")
        probeWindow.orderOut(nil)
        probe.evaluate()
        try require(!probe.isHostVisible, "A probe in a window ordered out reports hidden")
        try require(seen.last == false || seen.isEmpty, "The probe reports its last change")
        probeWindow.close()

        let done = Message(role: .assistant, text: "Here it is.")
        var stopped = Message(role: .assistant, text: "Partial")
        stopped.state = .interrupted
        stopped.failure = "Stopped."
        var broken = Message(role: .assistant, text: "")
        broken.state = .interrupted
        broken.failure = "The model did not answer."
        let silent = Message(role: .assistant, text: "   ")
        try require(TandemLogoPresence.terminalEvent(turn: .stopped, message: stopped) == .canceled,
                    "A turn the user stopped reads as canceled even though its message carries a reason")
        try require(TandemLogoPresence.terminalEvent(turn: .interrupted, message: broken) == .failed, "An interrupted turn reads as failed")
        try require(TandemLogoPresence.terminalEvent(turn: .complete, message: done) == .completed, "A finished answer with text reads as completed")
        try require(TandemLogoPresence.terminalEvent(turn: .complete, message: silent) == .none, "An empty answer plays no completion")
        try require(TandemLogoPresence.terminalEvent(turn: .running, message: done) == .none, "A turn still running plays nothing")
        try require(TandemLogoPresence.terminalEvent(turn: nil, message: stopped) == .failed
                    && TandemLogoPresence.terminalEvent(turn: nil, message: done) == .completed
                    && TandemLogoPresence.terminalEvent(turn: nil, message: nil) == .none,
                    "Without a turn record the message alone decides")

        let activity = NativeToolActivity(id: "call-1", toolID: "search", name: "search", title: "Search", round: 0,
                                          request: "{}", result: nil, state: .pending, confirmationRequired: true)
        let mine = UUID(), theirs = UUID()
        let confirmations = [theirs: NativeToolConfirmationRequest(activity: activity)]
        try require(!TandemLogoPresence.decisionPending(confirmations: confirmations, assistantMessageID: mine, fallback: true),
                    "Another conversation's approval does not nudge the selected one")
        try require(TandemLogoPresence.decisionPending(confirmations: confirmations, assistantMessageID: theirs, fallback: false),
                    "The selected conversation's own approval nudges")
        try require(TandemLogoPresence.decisionPending(confirmations: [:], assistantMessageID: nil, fallback: true)
                    && !TandemLogoPresence.decisionPending(confirmations: [:], assistantMessageID: nil, fallback: false),
                    "Without a turn record the shared pending flag decides")

        var filter = PlaybackEventFilter()
        try require(filter.admits(1) && filter.admits(3) && !filter.admits(2) && !filter.admits(3) && filter.admits(4),
                    "A playback event that arrives after a newer one is ignored")

        try runTandemCueMapper()
        print("PASS tandem motion: twelve sequences, smoothstep sampling, live overlap, template mark, interruption, host visibility, Reduce Motion, cue mapping")
    }

    static func runTandemCueMapper() throws {
        let require = NativeTaskFixture.require
        func cue(_ previous: TandemLogoSnapshot?, _ edit: (inout TandemLogoSnapshot) -> Void) -> (TandemLogoCue, Bool)? {
            var current = previous ?? .idle
            edit(&current)
            return TandemLogoCueMapper.cue(previous: previous, current: current).map { ($0.cue, $0.loop) }
        }
        func expect(_ got: (TandemLogoCue, Bool)?, _ want: (TandemLogoCue, Bool)?, _ message: String) throws {
            try require(got?.0 == want?.0 && got?.1 == want?.1, message)
        }
        let idle = TandemLogoSnapshot.idle
        try expect(cue(idle) { _ in }, nil, "An idle app has no cue")
        try expect(cue(nil) { _ in }, nil, "A first idle snapshot has no cue")
        try expect(cue(idle) { $0.launchedJustNow = true }, (.hello, false), "Launch says hello")
        var launched = idle; launched.launchedJustNow = true
        try expect(cue(launched) { _ in }, nil, "Hello plays once")
        try expect(cue(idle) { $0.decisionPending = true }, (.nudge, false), "A pending decision nudges")
        var pending = idle; pending.decisionPending = true
        try expect(cue(pending) { _ in }, nil, "A pending decision nudges once")
        try expect(cue(idle) { $0.turnCompleted = true }, (.gather, false), "A finished turn gathers")
        try expect(cue(idle) { $0.turnFailed = true }, (.recover, false), "A failed turn recovers")
        try expect(cue(idle) { $0.turnCanceled = true }, (.pause, false), "A canceled turn pauses")
        try expect(cue(idle) { $0.handoff = true }, (.exchange, false), "A handoff exchanges")
        var completed = idle; completed.turnCompleted = true
        try expect(cue(completed) { _ in }, nil, "A held completion flag is not a new edge")
        try expect(cue(idle) { $0.voiceCapturing = true }, (.listen, true), "Capture listens")
        try expect(cue(idle) { $0.voicePlaying = true }, (.speak, true), "Playback speaks")
        try expect(cue(idle) { $0.generating = true }, (.orbit, true), "Generation orbits")
        var generating = idle; generating.generating = true
        try expect(cue(generating) { _ in }, (.orbit, true), "Orbit holds while generating")
        try expect(cue(idle) { $0.appActive = false }, (.rest, false), "Leaving the app rests")
        var away = idle; away.appActive = false
        try expect(cue(away) { _ in }, nil, "Rest plays once")
        try expect(cue(generating) { $0.generating = false }, (.rest, false), "Ending a loop settles to rest")
        try expect(cue(idle) { $0.idleBreathing = true }, (.breathe, true), "Breathing is opt in")
        try expect(cue(idle) { $0.idleBreathing = true; $0.appActive = false }, (.rest, false), "Breathing stops when the app is inactive")

        try expect(cue(idle) { $0.voicePlaying = true; $0.voiceCapturing = true; $0.generating = true }, (.speak, true),
                   "Playback outranks capture")
        try expect(cue(idle) { $0.voiceCapturing = true; $0.decisionPending = true }, (.listen, true), "Capture outranks a decision")
        try expect(cue(idle) { $0.decisionPending = true; $0.turnFailed = true }, (.nudge, false), "A decision outranks a failure")
        try expect(cue(idle) { $0.turnFailed = true; $0.turnCompleted = true }, (.recover, false), "A failure outranks a completion")
        try expect(cue(idle) { $0.turnCompleted = true; $0.generating = true }, (.gather, false), "A completion outranks generation")
        try expect(cue(idle) { $0.generating = true; $0.appActive = false }, (.orbit, true), "Generation outranks rest")
        try expect(cue(idle) { $0.generating = true; $0.launchedJustNow = true }, (.orbit, true), "Generation outranks hello")
        var snapshot = idle
        snapshot.turnFailed = true
        try require(TandemLogoCueMapper.cue(previous: idle, current: snapshot)?.cue
                    == TandemLogoCueMapper.cue(previous: idle, current: snapshot)?.cue, "The mapper is deterministic")
    }
}

enum TandemLogoMotionCheck {
    static func sample(_ sequence: TandemMotionSequence, _ step: Int, of steps: Int) -> TandemLogoPose {
        TandemMotionLibrary.pose(in: sequence, at: Double(step) / Double(steps))
    }

    static func distance(_ a: TandemLogoPose, _ b: TandemLogoPose) -> Double {
        var angle = (b.angle - a.angle).truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle < -180 { angle += 360 }
        let parts = [a.leftOffset.dx - b.leftOffset.dx, a.leftOffset.dy - b.leftOffset.dy, a.leftScale - b.leftScale,
                     a.rightOffset.dx - b.rightOffset.dx, a.rightOffset.dy - b.rightOffset.dy, a.rightScale - b.rightScale,
                     angle, a.scale - b.scale]
        return parts.map { $0 * $0 }.reduce(0, +).squareRoot()
    }
}
