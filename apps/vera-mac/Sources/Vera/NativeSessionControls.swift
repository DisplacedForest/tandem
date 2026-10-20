import SwiftUI

struct NativeAnswerControls: View {
    let status: String
    let canStop: Bool
    var stopLabel = "Stop answer"
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(status).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if canStop {
                Button(stopLabel, action: onStop)
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
        }
    }
}
