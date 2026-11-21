import SwiftUI

struct TypingDots: View {
    static let period: Double = 1.2
    static let stagger: Double = 0.16
    static let restingLift: Double = 0.5

    var size: CGFloat = 7
    var label = "Working on your answer"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func lift(time: Double, index: Int) -> Double {
        let cycle = time / period - Double(index) * stagger
        let phase = cycle - cycle.rounded(.down)
        guard phase < 0.6 else { return 0 }
        let wave = sin(phase / 0.6 * .pi)
        return wave * wave
    }

    var body: some View {
        Group {
            if reduceMotion {
                dots { _ in Self.restingLift }
            } else {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    dots { Self.lift(time: time, index: $0) }
                }
            }
        }
        .frame(height: max(size * 2.4, 17))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func dots(_ lift: @escaping (Int) -> Double) -> some View {
        HStack(spacing: size * 0.6) {
            ForEach(0..<3, id: \.self) { index in
                let amount = lift(index)
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: size, height: size)
                    .scaleEffect(0.8 + 0.3 * amount)
                    .opacity(0.4 + 0.6 * amount)
            }
        }
    }
}

@MainActor
extension SelfTest {
    static func runTypingDots() throws {
        let require = NativeTaskFixture.require
        let samples = stride(from: 0.0, to: TypingDots.period * 3, by: 0.01)
        try require(samples.allSatisfy { time in (0..<3).allSatisfy { (0...1).contains(TypingDots.lift(time: time, index: $0)) } },
                    "Each dot stays between resting and fully raised")
        let peaks = (0..<3).map { index in
            samples.filter { $0 < TypingDots.period }.max { TypingDots.lift(time: $0, index: index) < TypingDots.lift(time: $1, index: index) } ?? 0
        }
        try require(peaks[0] < peaks[1] && peaks[1] < peaks[2], "The dots rise one after another, left to right")
        try require(samples.allSatisfy { abs(TypingDots.lift(time: $0, index: 1) - TypingDots.lift(time: $0 + TypingDots.period, index: 1)) < 0.0001 },
                    "The motion loops with no jump between cycles")
        try require(abs(TypingDots.lift(time: 0.299, index: 0) - TypingDots.lift(time: 0.3, index: 0)) < 0.05,
                    "The motion is smooth from one frame to the next")
        print("  typing dots OK (bounded, staggered left to right, seamless loop, smooth)")
    }
}
