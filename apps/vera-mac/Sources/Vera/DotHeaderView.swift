import SwiftUI

struct DotHeaderBar: View {
    let name: String
    let goal: String
    let rules: String
    let paused: Bool
    var onToggle: () -> Void = {}
    var onSettings: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            VeraMark(size: 18).frame(width: 18, height: 18)
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(goal.isEmpty ? "No standing goal yet" : goal.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Text(rules)
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            if paused {
                Text("Paused").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Button(action: onToggle) {
                HStack(spacing: 5) {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 9, weight: .semibold))
                    Text(paused ? "Resume" : "Pause").font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Theme.bg))
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(paused ? "Let \(name)'s scheduled work run again" : "Hold \(name)'s scheduled work. Chat keeps working.")
            Button(action: onSettings) {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change \(name)'s goal, services and rules")
            .accessibilityLabel("Settings for \(name)")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

struct DotHeaderView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore
    @State private var showingSettings = false

    var body: some View {
        DotHeaderBar(name: store.assistantName, goal: store.dotProfile.goal, rules: store.dotHeaderRules, paused: store.isDotPaused,
                     onToggle: { store.setDotState(store.isDotPaused ? .active : .paused) },
                     onSettings: { showingSettings = true })
            .sheet(isPresented: $showingSettings) {
                DotSettingsView().environmentObject(store).environmentObject(config)
            }
    }
}
