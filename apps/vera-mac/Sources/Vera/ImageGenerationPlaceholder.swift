import SwiftUI

enum ImagePlaceholderEffect: Int, CaseIterable, Equatable, Sendable {
    case dots
    case raster
    case mosaic

    static func variant(for id: String) -> ImagePlaceholderEffect {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let cases = ImagePlaceholderEffect.allCases
        return cases[Int(hash % UInt64(cases.count))]
    }
}

enum NativeToolActivityPresentation: Equatable {
    case chip
    case imagePlaceholder
    case hidden

    static func forActivity(_ activity: NativeToolActivity) -> NativeToolActivityPresentation {
        guard activity.name == NativeImageTools.toolName else { return .chip }
        switch activity.state {
        case .pending: return .imagePlaceholder
        case .succeeded: return .hidden
        case .failed, .canceled: return .chip
        }
    }
}

struct ImageGenerationPlaceholder: View {
    let activity: NativeToolActivity
    var onCancel: (() -> Void)? = nil
    var effectOverride: ImagePlaceholderEffect? = nil
    var frozenTime: Double? = nil

    static let maxWidth: CGFloat = 480
    static let maxHeight: CGFloat = 480

    private var effect: ImagePlaceholderEffect {
        effectOverride ?? ImagePlaceholderEffect.variant(for: activity.id)
    }

    private var fraction: Double { activity.progress?.fraction ?? 0 }

    private var requestedSize: NativeImageSize {
        guard let data = activity.request.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let size = try? NativeImageSize.parse(object["size"] as? String) else { return .standard }
        return size
    }

    private var boxSize: CGSize {
        let size = requestedSize
        let aspect = CGFloat(size.width) / CGFloat(size.height)
        var width = Self.maxWidth
        var height = width / aspect
        if height > Self.maxHeight {
            height = Self.maxHeight
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Creating image")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            ZStack(alignment: .bottom) {
                effectCanvas
                HStack {
                    if let onCancel {
                        Button("Cancel", action: onCancel)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Theme.surface.opacity(0.9)))
                            .accessibilityLabel("Cancel image generation")
                    }
                    Spacer()
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.surface.opacity(0.9)))
                        .accessibilityLabel(activity.progress?.label ?? "Starting")
                }
                .padding(12)
            }
            .frame(width: boxSize.width, height: boxSize.height)
            .background(Theme.surface.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Creating image, \(Int((fraction * 100).rounded())) percent")
    }

    @ViewBuilder private var effectCanvas: some View {
        if let frozenTime {
            Canvas { context, size in
                ImagePlaceholderPainter.draw(effect, in: &context, size: size, time: frozenTime, progress: fraction)
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    ImagePlaceholderPainter.draw(effect, in: &context, size: size, time: time, progress: fraction)
                }
            }
        }
    }
}

enum ImagePlaceholderPainter {
    static func draw(_ effect: ImagePlaceholderEffect, in context: inout GraphicsContext, size: CGSize, time: Double, progress: Double) {
        switch effect {
        case .dots: dots(in: &context, size: size, time: time, progress: progress)
        case .raster: raster(in: &context, size: size, time: time, progress: progress)
        case .mosaic: mosaic(in: &context, size: size, time: time, progress: progress)
        }
    }

    private static func noise(_ x: Int, _ y: Int) -> Double {
        var hash = UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15
        hash ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2AE3D27D4EB4F
        hash ^= hash >> 29
        hash = hash &* 0xBF58476D1CE4E5B9
        hash ^= hash >> 32
        return Double(hash % 10_000) / 10_000
    }

    private static func dots(in context: inout GraphicsContext, size: CGSize, time: Double, progress: Double) {
        let spacing: CGFloat = 18
        let columns = Int(size.width / spacing)
        let rows = Int(size.height / spacing)
        let originX = (size.width - CGFloat(columns - 1) * spacing) / 2
        let originY = (size.height - CGFloat(rows - 1) * spacing) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxDistance = hypot(center.x, center.y)
        let revealRadius = maxDistance * (0.25 + 0.75 * progress)
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: originX + CGFloat(column) * spacing, y: originY + CGFloat(row) * spacing)
                let distance = hypot(point.x - center.x, point.y - center.y)
                let wave = 0.5 + 0.5 * sin(Double(distance) / 28 - time * 2.4)
                let inside = distance <= revealRadius
                let strength = inside ? 0.35 + 0.65 * wave : 0.08 + 0.1 * wave
                let radius = inside ? 1.6 + 1.9 * wave : 1.2
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                let color = inside ? Theme.accentGlow : Theme.textSecondary
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(strength)))
            }
        }
    }

    private static func raster(in context: inout GraphicsContext, size: CGSize, time: Double, progress: Double) {
        let pitch: CGFloat = 6
        let lines = Int(size.height / pitch)
        let filled = Int(Double(lines) * progress)
        let band = (time * 0.35).truncatingRemainder(dividingBy: 1.2) - 0.1
        for line in 0..<lines {
            let y = CGFloat(line) * pitch + pitch / 2
            let position = Double(line) / Double(max(lines - 1, 1))
            let shimmer = max(0, 1 - abs(position - band) * 6)
            let isFilled = line < filled
            let inset = isFilled ? 10 + CGFloat(noise(line, 7)) * 26 : 18 + CGFloat(noise(line, 3)) * 60
            let alpha = isFilled ? 0.35 + 0.5 * shimmer : 0.08 + 0.18 * shimmer
            let color = isFilled ? Theme.accent : Theme.textSecondary
            var path = Path()
            path.move(to: CGPoint(x: inset, y: y))
            path.addLine(to: CGPoint(x: size.width - inset, y: y))
            context.stroke(path, with: .color(color.opacity(alpha)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    private static func mosaic(in context: inout GraphicsContext, size: CGSize, time: Double, progress: Double) {
        let tile: CGFloat = 26
        let columns = Int(ceil(size.width / tile))
        let rows = Int(ceil(size.height / tile))
        let sweep = (time * 0.5).truncatingRemainder(dividingBy: 1.4) - 0.2
        for row in 0..<rows {
            for column in 0..<columns {
                let order = noise(column, row)
                let developed = order < progress
                let diagonal = (Double(column) / Double(max(columns - 1, 1)) + Double(row) / Double(max(rows - 1, 1))) / 2
                let shimmer = max(0, 1 - abs(diagonal - sweep) * 5)
                let rect = CGRect(x: CGFloat(column) * tile + 2, y: CGFloat(row) * tile + 2, width: tile - 4, height: tile - 4)
                let tone = noise(row, column)
                let color = developed ? (tone > 0.5 ? Theme.accent : Theme.accentGlow) : Theme.textSecondary
                let alpha = developed ? 0.14 + 0.22 * tone + 0.22 * shimmer : 0.05 + 0.12 * shimmer
                context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(alpha)))
            }
        }
    }
}
