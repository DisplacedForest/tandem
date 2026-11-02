import SwiftUI
import AppKit

enum CompanionState: String, CaseIterable, Sendable {
    case ready, thinking, listening, speaking, resting, needsYou

    var displayName: String {
        switch self {
        case .ready: return "Ready"
        case .thinking: return "Thinking"
        case .listening: return "Listening"
        case .speaking: return "Speaking"
        case .resting: return "Resting"
        case .needsYou: return "Needs you"
        }
    }

    func accessibilityLabel(name: String?) -> String {
        guard let name, !name.isEmpty else { return displayName }
        if self == .needsYou { return "\(name) needs you" }
        return "\(name) is \(displayName.lowercased())"
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

struct CompanionFigure: View {
    let appearance: CompanionAppearance
    let bodyPose: CompanionPose
    let face: CompanionPose
    let eyes: CompanionPose
    let size: CGFloat

    var body: some View {
        let unit = size / 100
        ZStack {
            CompanionBodyShape(shape: appearance.shape).fill(appearance.color.fill)
            CompanionHighlightShape(shape: appearance.shape).fill(Color.white.opacity(0.15))
            CompanionEyesShape(shape: appearance.shape, pose: eyes)
                .fill(appearance.color.eyeColor)
                .transformEffect(face.transform(origin: appearance.shape.faceAnchor, unit: unit))
        }
        .frame(width: size, height: size)
        .transformEffect(bodyPose.transform(origin: CompanionShape.bodyAnchor, unit: unit))
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
        renderSafe || renderingShot || (reduceMotion ?? systemReduceMotion) || !visible || !hostVisible
    }

    var body: some View {
        let motion = CompanionMotion.of(state)
        let still = paused
        TimelineView(.animation(minimumInterval: nil, paused: still)) { context in
            let elapsed: Double? = still ? nil : max(0, context.date.timeIntervalSince(entered))
            CompanionFigure(appearance: appearance,
                            bodyPose: motion.body.pose(at: elapsed),
                            face: motion.face.pose(at: elapsed),
                            eyes: motion.eyes.pose(at: elapsed),
                            size: size)
        }
        .frame(width: size, height: size)
        .background { if !renderSafe && !renderingShot { TandemHostVisibilityProbe { hostVisible = $0 } } }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: state) { entered = Date() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel(name: name))
        .accessibilityAddTraits(.isImage)
    }
}
