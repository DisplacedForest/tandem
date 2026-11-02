import SwiftUI

struct DotHeaderBar: View {
    let name: String
    let paused: Bool
    var onToggle: () -> Void = {}
    var onSettings: () -> Void = {}
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 10) {
            CompanionAvatar(size: 24)
            Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
            if paused {
                Text("Paused").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if let trailing { trailing }
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
    var trailing: AnyView? = nil

    var body: some View {
        DotHeaderBar(name: store.assistantName, paused: store.isDotPaused,
                     onToggle: { store.setDotState(store.isDotPaused ? .active : .paused) },
                     onSettings: { showingSettings = true }, trailing: trailing)
            .sheet(isPresented: $showingSettings) {
                DotSettingsView().environmentObject(store).environmentObject(config)
            }
    }
}
