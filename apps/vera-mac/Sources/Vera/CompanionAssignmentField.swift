import SwiftUI

struct CompanionAssignmentField: View {
    @EnvironmentObject var store: ChatStore
    @State private var draft = ""
    @State private var error: String?
    @State private var submitting = false

    static let staticRendering = ProcessInfo.processInfo.arguments.contains("--shot")

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canStart: Bool { !trimmed.isEmpty && !submitting && !store.dotProfile.isPaused }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Give \(store.assistantName) work")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            HStack(alignment: .center, spacing: 8) {
                if Self.staticRendering {
                    Text("What should \(store.assistantName) work on?")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("What should \(store.assistantName) work on?", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .onSubmit(start)
                        .accessibilityLabel("Assignment for \(store.assistantName)")
                }
                Button(action: start) {
                    Image(systemName: submitting ? "hourglass" : "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(canStart ? Theme.onAccent : Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(canStart ? Theme.accent : Theme.surface))
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .accessibilityLabel("Start this work")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
            if store.dotProfile.isPaused {
                Text("\(store.assistantName) is paused.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func start() {
        guard canStart else { return }
        let assignment = trimmed
        submitting = true
        error = nil
        Task { @MainActor in
            let failure = await store.startCompanionAssignment(assignment)
            submitting = false
            if let failure {
                error = failure
            } else {
                draft = ""
            }
        }
    }
}
