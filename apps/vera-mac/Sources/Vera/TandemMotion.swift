import SwiftUI
import AppKit
import QuartzCore

struct TandemMotionKeyframe: Equatable, Sendable {
    var time: Double
    var pose: TandemLogoPose
}

struct TandemMotionSequence: Sendable {
    var name: String
    var duration: Double
    var loop: Bool
    var use: String
    var frames: [TandemMotionKeyframe]
}

struct TandemMotionDocument: Sendable {
    var viewBox: CGRect
    var radius: Double
    var left: CGPoint
    var right: CGPoint
    var center: CGPoint
    var sequences: [TandemMotionSequence]
}

enum TandemMotionLibrary {
    enum Failure: Error { case missing, malformed(String) }

    private struct RawGeometry: Decodable {
        var viewBox: [Double]
        var radius: Double
        var left: [Double]
        var right: [Double]
        var center: [Double]
    }

    private struct RawSequence: Decodable {
        var name: String
        var duration: Double
        var loop: Bool
        var use: String
        var frames: [[Double]]
    }

    private struct RawDocument: Decodable {
        var geometry: RawGeometry
        var frameFields: [String]
        var sequences: [RawSequence]
    }

    static let expectedFields = ["time", "lx", "ly", "ls", "rx", "ry", "rs", "angle", "scale"]

    static let document: TandemMotionDocument? = {
        let url = VeraResources.url("motion", ext: "json")
            ?? VeraResources.bundle?.url(forResource: "motion", withExtension: "json", subdirectory: "brand")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }()

    static var sequences: [TandemMotionSequence] { document?.sequences ?? [] }

    static func sequence(named name: String) -> TandemMotionSequence? {
        sequences.first { $0.name == name }
    }

    static func decode(_ data: Data) throws -> TandemMotionDocument {
        let raw = try JSONDecoder().decode(RawDocument.self, from: data)
        guard raw.frameFields == expectedFields else { throw Failure.malformed("frame fields") }
        let g = raw.geometry
        guard g.viewBox.count == 4, g.left.count == 2, g.right.count == 2, g.center.count == 2 else {
            throw Failure.malformed("geometry")
        }
        let sequences = try raw.sequences.map { s -> TandemMotionSequence in
            guard s.duration > 0, s.frames.count >= 2 else { throw Failure.malformed(s.name) }
            let frames = try s.frames.map { f -> TandemMotionKeyframe in
                guard f.count == expectedFields.count else { throw Failure.malformed(s.name) }
                return TandemMotionKeyframe(time: f[0], pose: TandemLogoPose(
                    leftOffset: CGVector(dx: f[1], dy: f[2]), leftScale: f[3],
                    rightOffset: CGVector(dx: f[4], dy: f[5]), rightScale: f[6],
                    angle: f[7], scale: f[8]))
            }
            for pair in zip(frames, frames.dropFirst()) where pair.1.time <= pair.0.time {
                throw Failure.malformed(s.name)
            }
            return TandemMotionSequence(name: s.name, duration: s.duration, loop: s.loop, use: s.use, frames: frames)
        }
        return TandemMotionDocument(
            viewBox: CGRect(x: g.viewBox[0], y: g.viewBox[1], width: g.viewBox[2], height: g.viewBox[3]),
            radius: g.radius,
            left: CGPoint(x: g.left[0], y: g.left[1]),
            right: CGPoint(x: g.right[0], y: g.right[1]),
            center: CGPoint(x: g.center[0], y: g.center[1]),
            sequences: sequences)
    }

    static func smoothstep(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * (3 - 2 * x)
    }

    static func pose(in sequence: TandemMotionSequence, at progress: Double) -> TandemLogoPose {
        let frames = sequence.frames
        guard let first = frames.first, let last = frames.last,
              progress >= first.time, progress <= last.time, frames.count > 1 else { return .rest }
        var index = frames.count - 2
        for i in 0..<(frames.count - 1) where frames[i + 1].time > progress {
            index = i
            break
        }
        let a = frames[index], b = frames[index + 1]
        let e = smoothstep((progress - a.time) / (b.time - a.time))
        if e == 0 { return a.pose }
        if e == 1 { return b.pose }
        func m(_ x: Double, _ y: Double) -> Double { x * (1 - e) + y * e }
        return TandemLogoPose(
            leftOffset: CGVector(dx: m(a.pose.leftOffset.dx, b.pose.leftOffset.dx), dy: m(a.pose.leftOffset.dy, b.pose.leftOffset.dy)),
            leftScale: m(a.pose.leftScale, b.pose.leftScale),
            rightOffset: CGVector(dx: m(a.pose.rightOffset.dx, b.pose.rightOffset.dx), dy: m(a.pose.rightOffset.dy, b.pose.rightOffset.dy)),
            rightScale: m(a.pose.rightScale, b.pose.rightScale),
            angle: m(a.pose.angle, b.pose.angle),
            scale: m(a.pose.scale, b.pose.scale))
    }
}

@MainActor
final class TandemMotionController: ObservableObject {
    static let blendDuration: Double = 0.18

    private struct Playback {
        var name: String?
        var sequence: TandemMotionSequence?
        var loop: Bool
        var from: TandemLogoPose
        var target: TandemLogoPose
        var blend: Double
        var elapsed: Double
        var generation: Int
        var completion: (() -> Void)?
    }

    @Published private(set) var pose: TandemLogoPose = .rest
    @Published private(set) var activeSequence: String?

    var speed: Double = 1
    var reduceMotion: Bool {
        didSet {
            guard reduceMotion != oldValue else { return }
            if reduceMotion { snapToRest() } else if let name = activeSequence, playback == nil { play(name, loop: true) }
            updateDriver()
        }
    }
    var isVisible: Bool = false {
        didSet {
            guard isVisible != oldValue else { return }
            if !isVisible {
                hiddenDuringPlayback = playback != nil
            } else if hiddenDuringPlayback, var p = playback, p.sequence != nil, !p.loop {
                p.sequence = nil
                p.from = pose
                p.target = .rest
                p.blend = Self.blendDuration
                p.elapsed = 0
                playback = p
            }
            if isVisible { hiddenDuringPlayback = false }
            updateDriver()
        }
    }
    var isPaused: Bool = false {
        didSet { updateDriver() }
    }

    var isAnimating: Bool { playback != nil }
    var isDriving: Bool { timer != nil }

    private let manualClock: Bool
    private var playback: Playback?
    private var generation = 0
    private var lastRequest: (name: String, loop: Bool?)?
    private var hiddenDuringPlayback = false
    private var visibleHosts: Set<UUID> = []
    private var timer: Timer?
    private var lastTick: CFTimeInterval?

    init(reduceMotion: Bool? = nil, manualClock: Bool = false) {
        self.reduceMotion = reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.manualClock = manualClock
    }

    func setHost(_ id: UUID, visible: Bool) {
        if visible { visibleHosts.insert(id) } else { visibleHosts.remove(id) }
        isVisible = !visibleHosts.isEmpty
    }

    func play(_ name: String, loop: Bool? = nil, completion: (() -> Void)? = nil) {
        generation += 1
        guard let sequence = TandemMotionLibrary.sequence(named: name) else { return }
        lastRequest = (name, loop)
        let shouldLoop = loop ?? sequence.loop
        if reduceMotion {
            playback = nil
            pose = .rest
            activeSequence = shouldLoop ? name : nil
            updateDriver()
            if !shouldLoop { completion?() }
            return
        }
        let target = sequence.frames.first?.pose ?? .rest
        playback = Playback(name: name, sequence: sequence, loop: shouldLoop, from: pose, target: target,
                            blend: pose == target ? 0 : Self.blendDuration, elapsed: 0,
                            generation: generation, completion: completion)
        activeSequence = name
        updateDriver()
    }

    func stop() {
        generation += 1
        activeSequence = nil
        if reduceMotion || pose == .rest {
            playback = nil
            pose = .rest
            updateDriver()
            return
        }
        let duration = TandemMotionLibrary.sequence(named: "Pause")?.duration ?? 1.2
        playback = Playback(name: nil, sequence: nil, loop: false, from: pose, target: .rest,
                            blend: duration, elapsed: 0, generation: generation, completion: nil)
        updateDriver()
    }

    func replay() {
        guard let last = lastRequest else { return }
        play(last.name, loop: last.loop)
    }

    func advance(by seconds: Double) {
        guard isVisible, !isPaused, !reduceMotion, var p = playback else { return }
        p.elapsed += max(seconds, 0) * speed
        playback = p
        render()
    }

    private func render() {
        guard let p = playback else { return }
        if p.elapsed < p.blend {
            pose = .mix(p.from, p.target, TandemMotionLibrary.smoothstep(p.elapsed / p.blend))
            return
        }
        guard let sequence = p.sequence else { finish(); return }
        let t = p.elapsed - p.blend
        if p.loop {
            pose = TandemMotionLibrary.pose(in: sequence, at: t.truncatingRemainder(dividingBy: sequence.duration) / sequence.duration)
            return
        }
        if t >= sequence.duration { finish(); return }
        pose = TandemMotionLibrary.pose(in: sequence, at: t / sequence.duration)
    }

    private func finish() {
        let done = playback
        playback = nil
        pose = .rest
        if done?.name != nil { activeSequence = nil }
        updateDriver()
        if let done, done.generation == generation { done.completion?() }
    }

    private func snapToRest() {
        guard let p = playback else { pose = .rest; return }
        playback = nil
        pose = .rest
        activeSequence = p.loop ? p.name : nil
        if !p.loop, p.generation == generation { p.completion?() }
    }

    private func updateDriver() {
        let shouldRun = !manualClock && isVisible && !isPaused && !reduceMotion && playback != nil
        if shouldRun, timer == nil {
            lastTick = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                guard self != nil else { timer.invalidate(); return }
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !shouldRun, let timer {
            timer.invalidate()
            self.timer = nil
            lastTick = nil
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - (lastTick ?? now)
        lastTick = now
        advance(by: min(dt, 0.1))
    }
}

struct AnimatedTandemLogo: View {
    @ObservedObject var controller: TandemMotionController
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var hostID = UUID()
    @State private var appeared = false
    @State private var hostVisible = false

    private var reduce: Bool { reduceMotionOverride ?? systemReduceMotion }

    var body: some View {
        TandemLogoStage(pose: reduce ? .rest : controller.pose)
            .background(TandemHostVisibilityProbe { visible in
                hostVisible = visible
                if appeared { controller.setHost(hostID, visible: visible) }
            })
            .onAppear {
                controller.reduceMotion = reduce
                appeared = true
                controller.setHost(hostID, visible: hostVisible)
            }
            .onDisappear {
                appeared = false
                controller.setHost(hostID, visible: false)
            }
            .onChange(of: reduce) { _, value in controller.reduceMotion = value }
    }
}

struct TandemHostVisibilityProbe: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TandemHostVisibilityView {
        let view = TandemHostVisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TandemHostVisibilityView, context: Context) {
        view.onChange = onChange
        view.evaluate()
    }
}

final class TandemHostVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private(set) var isHostVisible = false
    private let observers = TandemObserverBag()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebind()
        evaluate()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        rebind()
        evaluate()
    }

    override func layout() {
        super.layout()
        evaluate()
    }

    override func viewDidHide() {
        super.viewDidHide()
        evaluate()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        evaluate()
    }

    static func hostVisible(window: NSWindow?, occluded: Bool, hidden: Bool, visibleRect: CGRect) -> Bool {
        guard let window, window.isVisible, !window.isMiniaturized, !occluded, !hidden else { return false }
        return !visibleRect.isEmpty
    }

    func evaluate() {
        let occluded = !(window?.occlusionState.contains(.visible) ?? false)
        let value = Self.hostVisible(window: window, occluded: occluded, hidden: isHiddenOrHasHiddenAncestor, visibleRect: visibleRect)
        guard value != isHostVisible else { return }
        isHostVisible = value
        onChange?(value)
    }

    private func rebind() {
        let center = NotificationCenter.default
        observers.clear()
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.add(center.addObserver(forName: name, object: window, queue: .main, using: handler))
            }
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.add(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: handler))
        }
    }
}

final class TandemObserverBag: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) { tokens.append(token) }

    func clear() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    deinit { clear() }
}
