import SwiftUI

struct IconRail: View {
    let selection: AppSection
    @Binding var expanded: Bool
    let onSelect: (AppSection) -> Void
    static let collapsedWidth: CGFloat = 56
    static let expandedWidth: CGFloat = 184
    static let topInset: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                railGlyph(Image(systemName: expanded ? "sidebar.left" : "sidebar.right"), label: nil, selected: false)
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse navigation" : "Expand navigation")
            .accessibilityLabel(expanded ? "Collapse navigation" : "Expand navigation")
            ForEach(AppSection.railOrder) { item in
                railButton(item)
                if item == .vera || item == .integrations {
                    Rectangle().fill(Theme.hairline).frame(width: 22, height: 1).padding(.vertical, 4).padding(.leading, 9)
                }
            }
            Spacer(minLength: 0)
            SettingsLink {
                railGlyph(Image(systemName: "gearshape"), label: "Settings", selected: false)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.top, Self.topInset)
        .padding(.bottom, 10)
        .padding(.horizontal, 9)
        .frame(width: expanded ? Self.expandedWidth : Self.collapsedWidth, alignment: .leading)
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
                    railGlyph(VeraMark(size: 22), label: item.title, selected: active)
                } else {
                    railGlyph(Image(systemName: item.icon), label: item.title, selected: active)
                }
            }
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func railGlyph<Content: View>(_ content: Content, label: String?, selected: Bool) -> some View {
        HStack(spacing: 10) {
            content
                .font(.system(size: 17, weight: .medium))
                .frame(width: 38, height: 38)
            if expanded, let label {
                Text(label).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
        }
        .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
        .frame(width: expanded ? Self.expandedWidth - 18 : 38, height: 38, alignment: .leading)
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
