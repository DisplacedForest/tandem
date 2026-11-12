import SwiftUI
import AppKit

enum CompanionState: String, CaseIterable, Sendable {
    case ready, thinking, listening, speaking, resting, needsYou, researching, writing, changing

    var displayName: String {
        switch self {
        case .ready: return "Ready"
        case .thinking: return "Thinking"
        case .listening: return "Listening"
        case .speaking: return "Speaking"
        case .resting: return "Resting"
        case .needsYou: return "Needs you"
        case .researching: return "Researching"
        case .writing: return "Writing"
        case .changing: return "Making a change"
        }
    }

    var working: Bool { self == .researching || self == .writing || self == .changing }

    func accessibilityLabel(name: String?) -> String {
        let subject = CompanionSentence.savedName(name) ?? "Your companion"
        if self == .needsYou { return "\(subject) needs you" }
        return "\(subject) is \(displayName.lowercased())"
    }
}

struct CompanionPose: Equatable, Sendable {
    var tx: CGFloat = 0
    var ty: CGFloat = 0
    var rotation: Double = 0
    var sx: CGFloat = 1
    var sy: CGFloat = 1

    static let identity = CompanionPose()

    func mixed(with other: CompanionPose, _ t: Double) -> CompanionPose {
        let f = CGFloat(t)
        return CompanionPose(tx: tx + (other.tx - tx) * f, ty: ty + (other.ty - ty) * f,
                             rotation: rotation + (other.rotation - rotation) * t,
                             sx: sx + (other.sx - sx) * f, sy: sy + (other.sy - sy) * f)
    }

    func transform(origin: CGPoint, unit: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: origin.x * unit + tx * unit, y: origin.y * unit + ty * unit)
            .rotated(by: rotation * .pi / 180)
            .scaledBy(x: sx, y: sy)
            .translatedBy(x: -origin.x * unit, y: -origin.y * unit)
    }
}

enum CompanionEasing: Sendable {
    case ease, easeInOut

    private var controls: (Double, Double, Double, Double) {
        switch self {
        case .ease: return (0.25, 0.1, 0.25, 1)
        case .easeInOut: return (0.42, 0, 0.58, 1)
        }
    }

    func value(_ x: Double) -> Double {
        let (x1, y1, x2, y2) = controls
        let bx = { (t: Double) in 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t }
        let by = { (t: Double) in 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<24 {
            if bx(t) < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return by(t)
    }
}

struct CompanionTrack: Sendable {
    struct Stop: Sendable {
        let at: Double
        let pose: CompanionPose
    }

    let duration: Double
    let easing: CompanionEasing
    let repeats: Bool
    let stops: [Stop]

    init(_ duration: Double, _ easing: CompanionEasing, repeats: Bool = true, _ entries: [([Double], CompanionPose)]) {
        self.duration = duration
        self.easing = easing
        self.repeats = repeats
        stops = entries.flatMap { entry in entry.0.map { Stop(at: $0 / 100, pose: entry.1) } }.sorted { $0.at < $1.at }
    }

    func pose(at elapsed: Double) -> CompanionPose {
        guard let first = stops.first, let last = stops.last else { return .identity }
        if !repeats && elapsed >= duration { return last.pose }
        let progress = repeats ? (elapsed / duration).truncatingRemainder(dividingBy: 1) : max(0, elapsed / duration)
        if progress <= first.at { return first.pose }
        for (a, b) in zip(stops, stops.dropFirst()) where progress <= b.at {
            let span = b.at - a.at
            guard span > 0 else { return b.pose }
            return a.pose.mixed(with: b.pose, easing.value((progress - a.at) / span))
        }
        return last.pose
    }
}

struct CompanionChannel: Sendable {
    let still: CompanionPose
    let track: CompanionTrack?

    init(_ still: CompanionPose = .identity, _ track: CompanionTrack? = nil) {
        self.still = still
        self.track = track
    }

    func pose(at elapsed: Double?) -> CompanionPose {
        guard let elapsed, let track else { return still }
        return track.pose(at: elapsed)
    }
}

struct CompanionMotion: Sendable {
    let body: CompanionChannel
    let face: CompanionChannel
    let eyes: CompanionChannel
    var prop = CompanionChannel()

    private static func p(tx: CGFloat = 0, ty: CGFloat = 0, r: Double = 0, sx: CGFloat = 1, sy: CGFloat = 1) -> CompanionPose {
        CompanionPose(tx: tx, ty: ty, rotation: r, sx: sx, sy: sy)
    }

    private static func blink(_ duration: Double) -> CompanionTrack {
        CompanionTrack(duration, .ease, [([0, 39, 45, 49, 55, 100], p()), ([42, 52], p(sy: 0.1))])
    }

    static func of(_ state: CompanionState) -> CompanionMotion {
        switch state {
        case .ready:
            return CompanionMotion(
                body: CompanionChannel(.identity, CompanionTrack(4, .easeInOut, [
                    ([0, 100], p(ty: 1, sx: 1.02, sy: 0.98)),
                    ([50], p(ty: -2, sx: 0.99, sy: 1.03)),
                ])),
                face: CompanionChannel(),
                eyes: CompanionChannel(.identity, blink(4.8)))
        case .thinking:
            return CompanionMotion(
                body: CompanionChannel(p(ty: 1, r: -8), CompanionTrack(3.4, .easeInOut, [
                    ([0, 100], p(ty: 1, r: -8)),
                    ([20, 35], p(ty: -2, r: -10, sx: 0.98, sy: 1.04)),
                    ([65, 80], p(ty: -3, r: 9, sx: 1.03, sy: 0.98)),
                ])),
                face: CompanionChannel(p(tx: -5, ty: -3), CompanionTrack(3.4, .easeInOut, [
                    ([0, 35, 100], p(tx: -5, ty: -3)),
                    ([65, 80], p(tx: 5, ty: -2)),
                ])),
                eyes: CompanionChannel(p(sy: 0.8), CompanionTrack(3.4, .easeInOut, [
                    ([0, 35, 100], p(sy: 0.8)),
                    ([65, 80], p(sy: 1.1)),
                ])))
        case .listening:
            let perked = p(ty: -3, r: -6, sx: 0.96, sy: 1.08)
            return CompanionMotion(
                body: CompanionChannel(perked, CompanionTrack(2.6, .easeInOut, [
                    ([0, 100], perked),
                    ([35], p(ty: -5, r: -10, sx: 0.94, sy: 1.12)),
                    ([60], p(ty: -1, r: -7, sx: 1.03, sy: 1.02)),
                    ([78], p(ty: -4, r: -6, sx: 0.97, sy: 1.08)),
                ])),
                face: CompanionChannel(p(tx: 2, ty: -4)),
                eyes: CompanionChannel(p(sy: 1.16), CompanionTrack(5, .ease, [
                    ([0, 56, 62, 100], p(sy: 1.16)),
                    ([59], p(sy: 0.12)),
                ])))
        case .speaking:
            let open = p(sx: 1.12, sy: 1.3)
            return CompanionMotion(
                body: CompanionChannel(p(r: -2, sx: 1.03, sy: 0.97), CompanionTrack(1.65, .easeInOut, [
                    ([0, 100], p(ty: 0, r: -2, sx: 1.03, sy: 0.97)),
                    ([18], p(ty: -5, r: 3, sx: 0.91, sy: 1.15)),
                    ([36], p(ty: 2, r: -3, sx: 1.12, sy: 0.9)),
                    ([56], p(ty: -3, r: 2, sx: 0.95, sy: 1.09)),
                    ([73], p(ty: 1, r: 4, sx: 1.06, sy: 0.95)),
                    ([86], p(ty: -2, r: 0, sx: 0.98, sy: 1.05)),
                ])),
                face: CompanionChannel(.identity, CompanionTrack(1.65, .easeInOut, [
                    ([0, 100], p()),
                    ([18], p(tx: 2, ty: -2)),
                    ([36], p(tx: -2, ty: 1)),
                    ([56], p(tx: 1, ty: -2)),
                    ([73], p(tx: 2, ty: 0)),
                ])),
                eyes: CompanionChannel(open, CompanionTrack(4.3, .ease, [
                    ([0, 39, 45, 49, 55, 100], open),
                    ([42, 52], p(sx: 1.12, sy: 0.1)),
                ])))
        case .resting:
            return CompanionMotion(
                body: CompanionChannel(p(ty: 6, sx: 1.06, sy: 0.83), CompanionTrack(4.2, .easeInOut, [
                    ([0, 100], p(ty: 6, r: -3, sx: 1.06, sy: 0.83)),
                    ([50], p(ty: 2, r: -1, sx: 1.1, sy: 0.92)),
                ])),
                face: CompanionChannel(),
                eyes: CompanionChannel(p(sy: 0.18)))
        case .researching:
            let left = p(ty: -1, r: -5, sx: 0.98, sy: 1.03)
            return CompanionMotion(
                body: CompanionChannel(left, CompanionTrack(2.8, .easeInOut, [
                    ([0, 100], left),
                    ([22], p(ty: -3, r: -7, sx: 0.96, sy: 1.06)),
                    ([50, 62], p(ty: -1, r: 5, sx: 0.98, sy: 1.03)),
                    ([78], p(ty: -3, r: 7, sx: 0.96, sy: 1.06)),
                ])),
                face: CompanionChannel(p(tx: -7, ty: -2), CompanionTrack(2.8, .easeInOut, [
                    ([0, 30, 100], p(tx: -7, ty: -2)),
                    ([50, 80], p(tx: 7, ty: -2)),
                ])),
                eyes: CompanionChannel(p(sx: 1.08, sy: 1.22), CompanionTrack(2.8, .ease, [
                    ([0, 36, 44, 100], p(sx: 1.08, sy: 1.22)),
                    ([40], p(sx: 1.08, sy: 0.12)),
                ])),
                prop: CompanionChannel(p(tx: -4), CompanionTrack(2.8, .easeInOut, [
                    ([0, 30, 100], p(tx: -4)),
                    ([50, 80], p(tx: 5, ty: -3)),
                ])))
        case .writing:
            let down = p(ty: 3, r: 4, sx: 1.03, sy: 0.95)
            return CompanionMotion(
                body: CompanionChannel(down, CompanionTrack(1.2, .easeInOut, [
                    ([0, 100], down),
                    ([25], p(tx: -2, ty: 4, r: 2, sx: 1.05, sy: 0.93)),
                    ([50], p(ty: 2, r: 5, sx: 1.02, sy: 0.97)),
                    ([75], p(tx: 2, ty: 4, r: 6, sx: 1.05, sy: 0.93)),
                ])),
                face: CompanionChannel(p(tx: 2, ty: 6), CompanionTrack(2.4, .easeInOut, [
                    ([0, 100], p(tx: -3, ty: 6)),
                    ([50], p(tx: 5, ty: 6)),
                ])),
                eyes: CompanionChannel(p(sy: 0.55), CompanionTrack(4.6, .ease, [
                    ([0, 46, 54, 100], p(sy: 0.55)),
                    ([50], p(sy: 0.1)),
                ])),
                prop: CompanionChannel(p(), CompanionTrack(0.6, .easeInOut, [
                    ([0, 100], p()),
                    ([25], p(tx: -4, ty: 1, r: -6)),
                    ([75], p(tx: 3, ty: -1, r: 5)),
                ])))
        case .changing:
            let set = p(tx: 2, ty: -1, r: 6)
            return CompanionMotion(
                body: CompanionChannel(set, CompanionTrack(1.8, .easeInOut, [
                    ([0, 100], set),
                    ([18], p(tx: -3, ty: 2, r: -4, sx: 1.08, sy: 0.9)),
                    ([42], p(tx: 6, ty: -5, r: 10, sx: 0.94, sy: 1.1)),
                    ([64], p(tx: 3, ty: 1, r: 5, sx: 1.05, sy: 0.95)),
                ])),
                face: CompanionChannel(p(tx: 5, ty: -1), CompanionTrack(1.8, .easeInOut, [
                    ([0, 100], p(tx: 5, ty: -1)),
                    ([18], p(tx: 1, ty: 1)),
                    ([42], p(tx: 7, ty: -3)),
                ])),
                eyes: CompanionChannel(p(sx: 1.05, sy: 0.9), CompanionTrack(3.6, .ease, [
                    ([0, 44, 52, 100], p(sx: 1.05, sy: 0.9)),
                    ([48], p(sx: 1.05, sy: 0.1)),
                ])),
                prop: CompanionChannel(p(r: -8), CompanionTrack(1.8, .easeInOut, [
                    ([0, 100], p(r: -8)),
                    ([18], p(r: 14)),
                    ([42], p(r: -24)),
                    ([64], p(r: 6)),
                ])))
        case .needsYou:
            let attentive = p(ty: -2, r: -10)
            return CompanionMotion(
                body: CompanionChannel(attentive, CompanionTrack(0.9, .easeInOut, repeats: false, [
                    ([0], p()),
                    ([22], p(ty: 3, sx: 1.1, sy: 0.88)),
                    ([52], p(ty: -9, r: -12, sx: 0.95, sy: 1.1)),
                    ([76], p(ty: 1, r: -8, sx: 1.04, sy: 0.97)),
                    ([100], attentive),
                ])),
                face: CompanionChannel(p(tx: 4, ty: -3)),
                eyes: CompanionChannel())
        }
    }
}

struct CompanionBodyShape: Shape {
    let shape: CompanionShape
    func path(in rect: CGRect) -> Path { shape.bodyPath(in: rect) }
}

struct CompanionHighlightShape: Shape {
    let shape: CompanionShape
    func path(in rect: CGRect) -> Path { shape.highlightPath(in: rect) ?? Path() }
}

struct CompanionEyesShape: Shape {
    let shape: CompanionShape
    let pose: CompanionPose

    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 100
        let eyes = shape.eyeFrames(in: rect)
        var path = Path()
        for eye in [eyes.left, eyes.right] {
            let width = eye.width * pose.sx
            let height = eye.height * pose.sy
            let frame = CGRect(x: eye.midX - width / 2, y: eye.midY - height / 2, width: width, height: height)
            let radius = CompanionShape.eyeCornerRadius * unit
            path.addRoundedRect(in: frame, cornerSize: CGSize(width: radius * pose.sx, height: radius * pose.sy))
        }
        return path
    }
}

enum CompanionProp: Equatable, Sendable {
    case magnifier, pencil, wrench

    static let anchor = CGPoint(x: 78, y: 76)

    static func of(_ state: CompanionState) -> CompanionProp? {
        switch state {
        case .researching: return .magnifier
        case .writing: return .pencil
        case .changing: return .wrench
        default: return nil
        }
    }

    func strokes(unit: CGFloat) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
        switch self {
        case .magnifier:
            path.addEllipse(in: CGRect(x: 57 * unit, y: 52 * unit, width: 30 * unit, height: 30 * unit))
            path.move(to: point(83, 78))
            path.addLine(to: point(97, 93))
        case .pencil:
            path.move(to: point(94, 50))
            path.addLine(to: point(70, 84))
        case .wrench:
            path.move(to: point(64, 95))
            path.addLine(to: point(84, 66))
        }
        return path
    }

    func fills(unit: CGFloat) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
        switch self {
        case .magnifier:
            path.addEllipse(in: CGRect(x: 60 * unit, y: 55 * unit, width: 24 * unit, height: 24 * unit))
        case .pencil:
            path.move(to: point(63, 94))
            path.addLine(to: point(65, 80))
            path.addLine(to: point(75, 87))
            path.closeSubpath()
        case .wrench:
            path.move(to: point(79, 50))
            path.addLine(to: point(98, 63))
            path.addLine(to: point(91, 74))
            path.addLine(to: point(72, 61))
            path.closeSubpath()
        }
        return path
    }

    var weight: CGFloat {
        switch self {
        case .magnifier: return 7
        case .pencil: return 11
        case .wrench: return 8
        }
    }
}

struct CompanionPropView: View {
    let prop: CompanionProp
    let color: Color
    let unit: CGFloat

    var body: some View {
        ZStack {
            prop.strokes(unit: unit)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: (prop.weight + 5) * unit, lineCap: .round, lineJoin: .round))
            if prop != .magnifier {
                prop.fills(unit: unit)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 5 * unit, lineJoin: .round))
            }
            prop.fills(unit: unit).fill(prop == .magnifier ? Color.white.opacity(0.85) : color)
            prop.strokes(unit: unit)
                .stroke(color, style: StrokeStyle(lineWidth: prop.weight * unit, lineCap: .round, lineJoin: .round))
        }
    }
}

struct CompanionFigure: View {
    let appearance: CompanionAppearance
    let bodyPose: CompanionPose
    let face: CompanionPose
    let eyes: CompanionPose
    let size: CGFloat
    var prop: CompanionProp? = nil
    var propPose: CompanionPose = .identity

    static let clearance: CGFloat = 0.12

    static func inner(for size: CGFloat) -> CGFloat { size * (1 - 2 * clearance) }

    static func bodyBounds(shape: CompanionShape, pose: CompanionPose, size: CGFloat) -> CGRect {
        let inner = inner(for: size)
        let inset = size * clearance
        let path = shape.bodyPath(in: CGRect(x: 0, y: 0, width: inner, height: inner))
            .applying(pose.transform(origin: CompanionShape.bodyAnchor, unit: inner / 100))
        return path.boundingRect.offsetBy(dx: inset, dy: inset)
    }

    var body: some View {
        let inner = Self.inner(for: size)
        let unit = inner / 100
        ZStack {
            CompanionBodyShape(shape: appearance.shape).fill(appearance.color.fill)
            CompanionHighlightShape(shape: appearance.shape).fill(Color.white.opacity(0.15))
            CompanionEyesShape(shape: appearance.shape, pose: eyes)
                .fill(appearance.color.eyeColor)
                .transformEffect(face.transform(origin: appearance.shape.faceAnchor, unit: unit))
        }
        .frame(width: inner, height: inner)
        .transformEffect(bodyPose.transform(origin: CompanionShape.bodyAnchor, unit: unit))
        .overlay {
            if let prop {
                CompanionPropView(prop: prop, color: appearance.color.eyeColor, unit: unit)
                    .frame(width: inner, height: inner)
                    .transformEffect(propPose.transform(origin: CompanionProp.anchor, unit: unit))
            }
        }
        .frame(width: size, height: size)
    }
}

struct CompanionAvatarView: View {
    let appearance: CompanionAppearance
    let state: CompanionState
    var size: CGFloat = 48
    var name: String?
    var renderSafe = false
    var reduceMotion: Bool?

    @State private var visible = false
    @State private var hostVisible = false
    @State private var entered = Date()
    @State private var attention = CompanionAttentionMotion()
    @State private var attentionFrame = CGRect.zero
    @Environment(\.companionAttentionInput) private var attentionInput
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.renderSafe) private var renderingShot

    init(appearance: CompanionAppearance, state: CompanionState, size: CGFloat = 48, name: String? = nil,
         renderSafe: Bool = false, reduceMotion: Bool? = nil) {
        self.appearance = appearance
        self.state = state
        self.size = size
        self.name = name
        self.renderSafe = renderSafe
        self.reduceMotion = reduceMotion
    }

    private var paused: Bool {
        renderSafe || renderingShot || (reduceMotion ?? systemReduceMotion) || !visible || !hostVisible || !attentionInput.active
    }

    private func eyePose(motion: CompanionMotion, elapsed: Double?, still: Bool) -> CompanionPose {
        var pose = motion.eyes.pose(at: elapsed)
        if !still && state != .resting {
            if state == .ready { pose.sy = attention.blink }
            else { pose.sy *= attention.blink }
        }
        return pose
    }

    var body: some View {
        let motion = CompanionMotion.of(state)
        let still = paused
        TimelineView(.animation(minimumInterval: nil, paused: still)) { context in
            let elapsed: Double? = still ? nil : max(0, context.date.timeIntervalSince(entered))
            CompanionFigure(appearance: appearance,
                            bodyPose: still ? motion.body.pose(at: nil) : attention.body(motion.body.pose(at: elapsed)),
                            face: CompanionAttentionMotion.containedFace(still ? motion.face.pose(at: nil) : attention.face(motion.face.pose(at: elapsed)),
                                eyes: eyePose(motion: motion, elapsed: elapsed, still: still), shape: appearance.shape),
                            eyes: eyePose(motion: motion, elapsed: elapsed, still: still),
                            size: size, prop: CompanionProp.of(state), propPose: motion.prop.pose(at: elapsed))
                .onChange(of: context.date) { _, _ in
                    attention.step(now: ProcessInfo.processInfo.systemUptime, input: attentionInput, frame: attentionFrame,
                                   state: state, enabled: !still, random: { Double.random(in: 0...1) })
                }
        }
        .frame(width: size, height: size)
        .background { if !renderSafe && !renderingShot { CompanionAttentionGeometry { attentionFrame = $0 } } }
        .background { if !renderSafe && !renderingShot { TandemHostVisibilityProbe { hostVisible = $0 } } }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: state) { entered = Date() }
        .onChange(of: paused) { _, _ in attention.reset(); entered = Date() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel(name: name))
        .accessibilityAddTraits(.isImage)
    }
}
