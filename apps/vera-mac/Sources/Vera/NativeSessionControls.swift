import SwiftUI

struct NativeSessionModeControl: View {
    let mode: NativeSessionMode
    let onSelect: (NativeSessionMode) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("Session", selection: Binding(get: { mode }, set: onSelect)) {
                ForEach(NativeSessionMode.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 182)
            Text(mode.detail)
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

struct NativeAnswerControls: View {
    let status: String
    let canStop: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(status).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if canStop {
                Button("Stop answer", action: onStop)
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
        }
    }
}
