import SwiftUI

enum StoppedStepCopy {
    static let leftRest = " did not run this step. It's left to you."
    static let declined = "You declined this step. It was not run."
    static let unconfirmed = "You stopped this work. Check whether this step happened."
    static let stepLabel = "Step: "

    static func line(_ reason: String) -> CompanionLine {
        switch reason {
        case NativeTaskStop.declined: return .literal(declined)
        case NativeTaskStop.unconfirmed: return .literal(unconfirmed)
        default: return .parts([.name, .text(leftRest)])
        }
    }

    static func strings(name: String?) -> [String] {
        [NativeTaskStop.left, NativeTaskStop.declined, NativeTaskStop.unconfirmed].map { line($0).plain(name: name) } + [stepLabel]
    }
}

struct StoppedStepView: View {
    let stop: NativeTaskStop
    let why: NativeRuleWhy?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CompanionLineText(line: StoppedStepCopy.line(stop.reason))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            let block = Text(verbatim: stop.step)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
            Group {
                if stop.step.count > 700 || stop.step.split(separator: "\n").count > 10 {
                    ScrollView { block }.frame(height: 220)
                } else {
                    block
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.bg))
            .accessibilityLabel(StoppedStepCopy.stepLabel + stop.step)
            if stop.reason == NativeTaskStop.left, let why {
                RefusalReasonLine(why: why)
            }
            if let earlier = stop.earlier, !earlier.isEmpty {
                Text(verbatim: earlier)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
