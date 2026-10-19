import SwiftUI

struct IconRail: View {
    let selection: AppSection
    let onSelect: (AppSection) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(AppSection.railOrder) { item in
                railButton(item)
                if item == .vera || item == .integrations {
                    Rectangle().fill(Theme.hairline).frame(width: 22, height: 1).padding(.vertical, 4)
                }
            }
            Spacer(minLength: 0)
            SettingsLink {
                railGlyph(Image(systemName: "gearshape"), selected: false)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.vertical, 10)
        .frame(width: 56)
        .frame(maxHeight: .infinity)
        .background(Theme.ink)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
    }

    private func railButton(_ item: AppSection) -> some View {
        let active = selection.rail == item
        return Button { onSelect(item) } label: {
            Group {
                if item == .vera {
                    railGlyph(VeraMark(size: 22), selected: active)
                } else {
                    railGlyph(Image(systemName: item.icon), selected: active)
                }
            }
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func railGlyph<Content: View>(_ content: Content, selected: Bool) -> some View {
        content
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.surfaceHover : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct DestinationPlaceholder: View {
    let section: AppSection

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: section.icon).font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text(section.placeholder?.title ?? section.title).font(.system(size: 20, weight: .semibold))
            Text(section.placeholder?.note ?? "")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text("Nothing here yet.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .accessibilityElement(children: .combine)
    }
}

struct SidebarHeading: View {
    let title: String
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
