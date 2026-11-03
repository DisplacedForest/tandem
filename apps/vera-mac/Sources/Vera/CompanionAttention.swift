import AppKit
import SwiftUI

struct CompanionAttentionInput: Equatable {
    var pointer: CGPoint?
    var pointerTime: TimeInterval = -.infinity
    var pointerOutside = false
    var composer: CGPoint?
    var composerFocused = false
    var typedTime: TimeInterval = -.infinity
    var active = false
}

struct CompanionAttentionTuning {
    var eyeStiffness = 105.0
    var eyeDamping = 20.0
    var bodyStiffness = 35.0
    var bodyDamping = 12.0
    var handoff = 2.5
    var hoverCooldown = 5.0
    var blinkRange = 3.2...6.8
    var maximumDelta = 1.0 / 30
}

struct CompanionAttentionMotion {
    var gaze = CGPoint.zero
    var velocity = CGPoint.zero
    var lean = 0.0
    var leanVelocity = 0.0
    var blink = 1.0
    var perk = 0.0
    private(set) var lastTime: TimeInterval?
    private var nextBlink = 0.0
    private var blinkStarted = -Double.infinity
    private var nextGlance = 0.0
    private var glanceUntil = 0.0
    private var glance = CGPoint.zero
    private var hoverStarted = -Double.infinity
    private var lastPerk = -Double.infinity
    private var hovering = false
    var tuning = CompanionAttentionTuning()

    static func target(_ point: CGPoint, frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: max(-6, min(6, (point.x - frame.midX) / max(80, frame.width) * 6)),
                       y: max(-4, min(4, (frame.midY - point.y) / max(80, frame.height) * 4)))
    }

    mutating func reset() {
        gaze = .zero; velocity = .zero; lean = 0; leanVelocity = 0; blink = 1; perk = 0
        lastTime = nil; nextBlink = 0; nextGlance = 0; hovering = false
        blinkStarted = -.infinity; hoverStarted = -.infinity
    }

    mutating func step(now: TimeInterval, input: CompanionAttentionInput, frame: CGRect,
                       state: CompanionState, enabled: Bool, random: () -> Double) {
        guard enabled, input.active, state != .resting else { reset(); return }
        guard let previous = lastTime else {
            lastTime = now
            nextBlink = now + tuning.blinkRange.lowerBound + random() * (tuning.blinkRange.upperBound - tuning.blinkRange.lowerBound)
            nextGlance = now + 7 + random() * 5
            return
        }
        lastTime = now
        let dt = max(0, min(tuning.maximumDelta, now - previous))
        let voice = state == .listening || state == .speaking
        if voice { gaze = .zero; velocity = .zero; lean = 0; leanVelocity = 0 }
        var target = CGPoint.zero
        if !voice {
            if let point = input.pointer, now - input.pointerTime < tuning.handoff {
                target = Self.target(point, frame: frame)
            } else if let point = input.composer, (!input.pointerOutside || input.typedTime > input.pointerTime),
                      input.composerFocused || now - input.typedTime < tuning.handoff {
                target = Self.target(point, frame: frame)
            } else if input.pointer != nil, state == .ready {
                if now >= nextGlance {
                    glance = CGPoint(x: (random() * 2 - 1) * 2, y: (random() * 2 - 1))
                    glanceUntil = now + 0.8
                    nextGlance = now + 7 + random() * 5
                }
                if now < glanceUntil { target = glance }
            }
        }
        let near = input.pointer.map { frame.insetBy(dx: -frame.width * 0.3, dy: -frame.height * 0.3).contains($0) } ?? false
        if near && !hovering && now - lastPerk >= tuning.hoverCooldown && state == .ready {
            hoverStarted = now; lastPerk = now
        }
        hovering = near
        perk = state == .ready && now - hoverStarted < 0.6 ? sin(max(0, now - hoverStarted) / 0.6 * .pi) * 1.5 : 0
        velocity.x += (tuning.eyeStiffness * (target.x - gaze.x) - tuning.eyeDamping * velocity.x) * dt
        velocity.y += (tuning.eyeStiffness * (target.y - gaze.y) - tuning.eyeDamping * velocity.y) * dt
        gaze.x = max(-6, min(6, gaze.x + velocity.x * dt))
        gaze.y = max(-4, min(4, gaze.y + velocity.y * dt))
        leanVelocity += (tuning.bodyStiffness * (target.x / 2 - lean) - tuning.bodyDamping * leanVelocity) * dt
        lean = max(-3, min(3, lean + leanVelocity * dt))
        if now >= nextBlink {
            blinkStarted = now
            nextBlink = now + tuning.blinkRange.lowerBound + random() * (tuning.blinkRange.upperBound - tuning.blinkRange.lowerBound)
        }
        let closure = now - blinkStarted
        blink = closure < 0.18 ? 1 - 0.9 * sin(max(0, closure) / 0.18 * .pi) : 1
    }

    func face(_ pose: CompanionPose) -> CompanionPose {
        var result = pose
        result.tx = max(-6, min(6, result.tx + gaze.x))
        result.ty = max(-4, min(4, result.ty + gaze.y))
        return result
    }

    static func containedFace(_ proposed: CompanionPose, eyes: CompanionPose, shape: CompanionShape) -> CompanionPose {
        let path = shape.bodyPath(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let frames = shape.eyeFrames(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        var result = proposed
        for _ in 0..<20 {
            let fits = [frames.left, frames.right].allSatisfy { frame in
                let width = frame.width * eyes.sx / 2
                let height = frame.height * eyes.sy / 2
                return [-1.0, 0, 1].allSatisfy { x in
                    [-1.0, 0, 1].allSatisfy { y in
                        path.contains(CGPoint(x: frame.midX + result.tx + x * width,
                                              y: frame.midY + result.ty + y * height))
                    }
                }
            }
            if fits { return result }
            result.tx *= 0.75; result.ty *= 0.75
        }
        return .identity
    }

    func body(_ pose: CompanionPose) -> CompanionPose {
        var result = pose
        result.rotation += lean
        result.ty -= perk
        return result
    }
}

@MainActor
final class CompanionAttentionSource: ObservableObject {
    @Published private(set) var input = CompanionAttentionInput()
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    func pointer(_ point: CGPoint?) {
        guard input.active else { return }
        input.pointer = point
        input.pointerOutside = point == nil
        input.pointerTime = clock()
    }

    func activate(_ active: Bool) {
        guard input.active != active else { return }
        input.active = active
        input.pointer = nil
        input.pointerOutside = false
        input.pointerTime = -.infinity
    }

    func composer(_ point: CGPoint?, focused: Bool, typed: Bool = false) {
        input.composer = point
        input.composerFocused = focused
        if typed { input.typedTime = clock() }
    }
}

private struct CompanionAttentionInputKey: EnvironmentKey {
    static let defaultValue = CompanionAttentionInput()
}

private struct CompanionAttentionSourceKey: EnvironmentKey {
    static let defaultValue: CompanionAttentionSource? = nil
}

extension EnvironmentValues {
    var companionAttentionInput: CompanionAttentionInput {
        get { self[CompanionAttentionInputKey.self] }
        set { self[CompanionAttentionInputKey.self] = newValue }
    }
    var companionAttentionSource: CompanionAttentionSource? {
        get { self[CompanionAttentionSourceKey.self] }
        set { self[CompanionAttentionSourceKey.self] = newValue }
    }
}

struct CompanionAttentionHost: NSViewRepresentable {
    let source: CompanionAttentionSource
    var enabled: Bool
    func makeNSView(context: Context) -> CompanionAttentionHostView { CompanionAttentionHostView() }
    func updateNSView(_ view: CompanionAttentionHostView, context: Context) {
        view.source = source
        view.enabled = enabled
        DispatchQueue.main.async { [weak view] in view?.evaluate() }
    }
}

final class CompanionAttentionHostView: NSView {
    weak var source: CompanionAttentionSource?
    var enabled = true
    private var area: NSTrackingArea?
    private let observers = TandemObserverBag()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next)
        area = next
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.clear()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                observers.add(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.evaluate() }
                })
            }
        }
        evaluate()
    }
    override func viewDidHide() { super.viewDidHide(); evaluate() }
    override func viewDidUnhide() { super.viewDidUnhide(); evaluate() }
    func evaluate() {
        let active = enabled && window?.isKeyWindow == true && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        source?.activate(active)
    }
    override func mouseMoved(with event: NSEvent) { source?.pointer(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { source?.pointer(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { source?.pointer(nil) }
}

struct CompanionAttentionGeometry: NSViewRepresentable {
    var changed: (CGRect) -> Void
    func makeNSView(context: Context) -> CompanionAttentionGeometryView { CompanionAttentionGeometryView() }
    func updateNSView(_ view: CompanionAttentionGeometryView, context: Context) { view.changed = changed; view.report() }
}

final class CompanionAttentionGeometryView: NSView {
    var changed: ((CGRect) -> Void)?
    private var reported = CGRect.null
    private let observers = TandemObserverBag()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); report() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); rebind(); report() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); rebind(); report() }
    private func rebind() {
        observers.clear()
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.add(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
        }
    }
    func report() {
        let frame = window == nil ? .zero : convert(bounds, to: nil)
        guard frame != reported else { return }
        reported = frame
        DispatchQueue.main.async { [weak self] in self?.changed?(frame) }
    }
}

struct CompanionComposerAttention: ViewModifier {
    var focused: Bool
    var draft: String
    @Environment(\.companionAttentionSource) private var source
    @State private var frame = CGRect.zero
    func body(content: Content) -> some View {
        content
            .background { CompanionAttentionGeometry { frame = $0 } }
            .onChange(of: frame) { _, _ in update() }
            .onChange(of: focused) { _, _ in update() }
            .onChange(of: draft) { _, _ in update(typed: true) }
            .onDisappear { source?.composer(nil, focused: false) }
    }
    private func update(typed: Bool = false) {
        source?.composer(CGPoint(x: frame.midX, y: frame.midY), focused: focused, typed: typed)
    }
}

struct CompanionAttentionWindow: ViewModifier {
    @StateObject private var source = CompanionAttentionSource()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.renderSafe) private var renderingShot
    func body(content: Content) -> some View {
        content
            .background { if !renderingShot { CompanionAttentionHost(source: source, enabled: !reduceMotion) } }
            .environment(\.companionAttentionInput, source.input)
            .environment(\.companionAttentionSource, source)
    }
}
