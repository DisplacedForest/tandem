import SwiftUI

struct DotSheetShot: View {
    @EnvironmentObject var store: ChatStore
    let settings: Bool
    let options: [NativeDotServiceOption]
    let selected: Set<String>
    let goal: String

    private var resolver: NativeRuleResolver {
        store.ruleResolver(for: store.veraThreadID ?? "", requestText: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(settings ? store.assistantName : "Set up \(store.assistantName)").font(.system(size: 17, weight: .semibold))
            if !settings {
                Text(DotProfileCopy.subtitle(store.assistantName))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 12) {
                row("Name") { box(Text(store.assistantName).font(.system(size: 13)), height: nil) }
                row("Goal") { box(Text(goal).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true), height: settings ? 54 : 74) }
                row("Connected services") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(options) { option in
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: selected.contains(option.id) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(selected.contains(option.id) ? Theme.accent : Theme.textSecondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.name).font(.system(size: 12))
                                    if !settings {
                                        Text(option.detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                row("What asks first") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(NativeActionClass.configurable, id: \.self) { action in
                            HStack {
                                Text(action.title).font(.system(size: 12))
                                Spacer(minLength: 8)
                                HStack(spacing: 4) {
                                    Text(resolver.choice(for: action).title).font(.system(size: 12))
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                                }
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline, lineWidth: 1))
                            }
                        }
                    }
                }
                if settings {
                    row("Scheduled work") {
                        HStack {
                            Text(store.isDotPaused ? "Paused" : "Runs on schedule").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            pill(store.isDotPaused ? "Resume" : "Pause", primary: false)
                        }
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    row("Start over") {
                        HStack(alignment: .top) {
                            Text(DotProfileCopy.startOver(store.assistantName))
                                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 10)
                            pill("Reset", primary: false, destructive: true)
                        }
                    }
                }
            }
            .padding(.top, 14)
            HStack(spacing: 8) {
                if !settings { pill("Skip for now", primary: false) }
                Spacer()
                if settings { pill("Cancel", primary: false) }
                pill(settings ? "Save" : "Start", primary: true)
            }
            .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.system(size: 13)).frame(width: 128, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func box<Content: View>(_ content: Content, height: CGFloat?) -> some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
    }

    private func pill(_ title: String, primary: Bool, destructive: Bool = false) -> some View {
        Text(title).font(.system(size: 13, weight: .medium))
            .foregroundStyle(primary ? Color.white : (destructive ? Color.red : Theme.textPrimary))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Theme.accent : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary ? Color.clear : Theme.hairline, lineWidth: 1))
    }
}
