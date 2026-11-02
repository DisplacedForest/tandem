import SwiftUI
import AppKit

struct TandemLogoPose: Equatable, Sendable {
    var leftOffset: CGVector
    var leftScale: Double
    var rightOffset: CGVector
    var rightScale: Double
    var angle: Double
    var scale: Double

    static let rest = TandemLogoPose(leftOffset: .zero, leftScale: 1, rightOffset: .zero, rightScale: 1, angle: 0, scale: 1)

    static func mix(_ a: TandemLogoPose, _ b: TandemLogoPose, _ t: Double) -> TandemLogoPose {
        func m(_ x: Double, _ y: Double) -> Double { x * (1 - t) + y * t }
        var delta = (b.angle - a.angle).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let angle = t >= 1 ? b.angle : a.angle + delta * t
        return TandemLogoPose(
            leftOffset: CGVector(dx: m(a.leftOffset.dx, b.leftOffset.dx), dy: m(a.leftOffset.dy, b.leftOffset.dy)),
            leftScale: m(a.leftScale, b.leftScale),
            rightOffset: CGVector(dx: m(a.rightOffset.dx, b.rightOffset.dx), dy: m(a.rightOffset.dy, b.rightOffset.dy)),
            rightScale: m(a.rightScale, b.rightScale),
            angle: angle,
            scale: m(a.scale, b.scale))
    }
}

struct TandemLogoCircle: Equatable, Sendable {
    var center: CGPoint
    var radius: CGFloat

    var bounds: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

enum TandemLogoBox: Sendable {
    case mark
    case motion

    var rect: CGRect {
        switch self {
        case .mark: TandemLogoGeometry.markBox
        case .motion: TandemLogoGeometry.motionBox
        }
    }
}

enum TandemLogoGeometry {
    static let radius: CGFloat = 128
    static let leftCenter = CGPoint(x: 128, y: 128)
    static let rightCenter = CGPoint(x: 282, y: 128)
    static let pairCenter = CGPoint(x: 205, y: 128)
    static let viewSize = CGSize(width: 410, height: 256)
    static let markBox = CGRect(origin: .zero, size: viewSize)
    static let motionBox = CGRect(x: -65, y: -105, width: 540, height: 466)
    static let aspectRatio = viewSize.width / viewSize.height

    struct Layout {
        var left: TandemLogoCircle
        var right: TandemLogoCircle
        var leftGradient: (start: CGPoint, end: CGPoint)
        var rightGradient: (start: CGPoint, end: CGPoint)
        var overlapGradient: (start: CGPoint, end: CGPoint)
    }

    static func pairTransform(_ pose: TandemLogoPose) -> (CGPoint) -> CGPoint {
        let theta = pose.angle * .pi / 180
        let c = cos(theta), s = sin(theta), k = pose.scale
        return { p in
            let x = p.x - pairCenter.x, y = p.y - pairCenter.y
            return CGPoint(x: pairCenter.x + k * (x * c - y * s), y: pairCenter.y + k * (x * s + y * c))
        }
    }

    static func circles(for pose: TandemLogoPose) -> (left: TandemLogoCircle, right: TandemLogoCircle) {
        let t = pairTransform(pose)
        let l = CGPoint(x: leftCenter.x + pose.leftOffset.dx, y: leftCenter.y + pose.leftOffset.dy)
        let r = CGPoint(x: rightCenter.x + pose.rightOffset.dx, y: rightCenter.y + pose.rightOffset.dy)
        return (TandemLogoCircle(center: t(l), radius: radius * pose.leftScale * pose.scale),
                TandemLogoCircle(center: t(r), radius: radius * pose.rightScale * pose.scale))
    }

    static func layout(for pose: TandemLogoPose, in rect: CGRect, box: TandemLogoBox = .mark) -> Layout {
        let b = box.rect
        let k = min(rect.width / b.width, rect.height / b.height)
        let fit: (CGPoint) -> CGPoint = { p in
            CGPoint(x: rect.midX + k * (p.x - b.midX), y: rect.midY + k * (p.y - b.midY))
        }
        let t = pairTransform(pose)
        let place: (CGPoint) -> CGPoint = { fit(t($0)) }
        func circle(_ base: CGPoint, _ offset: CGVector, _ scale: Double) -> (TandemLogoCircle, (CGPoint, CGPoint)) {
            let c = CGPoint(x: base.x + offset.dx, y: base.y + offset.dy)
            let r = radius * scale
            let shape = TandemLogoCircle(center: place(c), radius: k * r * pose.scale)
            return (shape, (place(CGPoint(x: c.x - r, y: c.y - r)), place(CGPoint(x: c.x + r, y: c.y + r))))
        }
        let left = circle(leftCenter, pose.leftOffset, pose.leftScale)
        let right = circle(rightCenter, pose.rightOffset, pose.rightScale)
        return Layout(left: left.0, right: right.0,
                      leftGradient: (left.1.0, left.1.1),
                      rightGradient: (right.1.0, right.1.1),
                      overlapGradient: (place(.zero), place(CGPoint(x: viewSize.width, y: viewSize.height))))
    }

    static func paths(for pose: TandemLogoPose, in rect: CGRect) -> (left: Path, right: Path, overlap: Path) {
        paths(for: pose, in: rect, box: .mark)
    }

    static func paths(for pose: TandemLogoPose, in rect: CGRect, box: TandemLogoBox) -> (left: Path, right: Path, overlap: Path) {
        let l = layout(for: pose, in: rect, box: box)
        let left = Path(ellipseIn: l.left.bounds)
        let right = Path(ellipseIn: l.right.bounds)
        return (left, right, right.intersection(left))
    }
}

enum TandemPalette {
    static let left = [rgb(0xC9E6A5), rgb(0x90B66E)]
    static let right = [rgb(0xA7CF86), rgb(0x628F47)]
    static let overlap = [rgb(0xBADC97), rgb(0xA2C780)]

    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct TandemLogoView: View {
    var pose: TandemLogoPose = .rest
    var box: TandemLogoBox = .mark

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let layout = TandemLogoGeometry.layout(for: pose, in: rect, box: box)
            let left = Path(ellipseIn: layout.left.bounds)
            let right = Path(ellipseIn: layout.right.bounds)
            context.fill(left, with: .linearGradient(Gradient(colors: TandemPalette.left),
                                                     startPoint: layout.leftGradient.start, endPoint: layout.leftGradient.end))
            context.fill(right, with: .linearGradient(Gradient(colors: TandemPalette.right),
                                                      startPoint: layout.rightGradient.start, endPoint: layout.rightGradient.end))
            context.fill(right.intersection(left), with: .linearGradient(Gradient(colors: TandemPalette.overlap),
                                                                         startPoint: layout.overlapGradient.start, endPoint: layout.overlapGradient.end))
        }
        .aspectRatio(box.rect.width / box.rect.height, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Tandem")
        .accessibilityAddTraits(.isImage)
    }
}

struct TandemLogoStage: View {
    var pose: TandemLogoPose = .rest

    var body: some View {
        Color.clear
            .aspectRatio(TandemLogoGeometry.aspectRatio, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let mark = TandemLogoGeometry.markBox, motion = TandemLogoGeometry.motionBox
                    TandemLogoView(pose: pose, box: .motion)
                        .frame(width: proxy.size.width * motion.width / mark.width,
                               height: proxy.size.height * motion.height / mark.height)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Tandem")
            .accessibilityAddTraits(.isImage)
    }
}

enum TandemTemplate {
    static func size(pointSize: CGFloat) -> NSSize {
        NSSize(width: pointSize * TandemLogoGeometry.aspectRatio, height: pointSize)
    }

    static func image(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: size(pointSize: pointSize), flipped: true) { rect in
            let k = min(rect.width / TandemLogoGeometry.viewSize.width, rect.height / TandemLogoGeometry.viewSize.height)
            let r = TandemLogoGeometry.radius * k
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            for c in [TandemLogoGeometry.leftCenter, TandemLogoGeometry.rightCenter] {
                path.appendOval(in: NSRect(x: rect.minX + c.x * k - r, y: rect.minY + c.y * k - r, width: r * 2, height: r * 2))
            }
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tandem"
        return image
    }

    static func templatePath(in rect: CGRect) -> Path {
        let paths = TandemLogoGeometry.paths(for: .rest, in: rect)
        return paths.left.symmetricDifference(paths.right)
    }
}
