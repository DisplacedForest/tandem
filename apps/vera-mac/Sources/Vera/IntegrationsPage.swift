import SwiftUI

struct IntegrationsPageHeader: View {
    @Binding var search: String
    let stacked: Bool
    let add: () -> Void

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 14) {
                heading
                controls
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                heading
                Spacer(minLength: 12)
                controls.fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Plugins").font(.system(size: 22, weight: .semibold)).accessibilityAddTraits(.isHeader)
            CompanionNamedText(template: IntegrationsPageModel.subtitle)
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            IntegrationsSearchField(text: $search)
                .frame(minWidth: stacked ? 0 : 200, maxWidth: stacked ? .infinity : 200)
            IntegrationsPageAdd(action: add)
        }
    }
}

private struct IntegrationsPageAdd: View {
    @Environment(\.renderSafe) private var renderSafe
    let action: () -> Void

    var body: some View {
        let label = Text("Add").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Theme.accent).clipShape(Capsule())
            .contentShape(Capsule())
        if renderSafe { label } else {
            Button(action: action) { label }.buttonStyle(.plain)
                .accessibilityLabel("Add your own service").help("Add your own")
        }
    }
}

struct IntegrationsPagePills: View {
    @Binding var selection: IntegrationsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach([IntegrationsTab.catalogue, .personal]) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(option.title).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(selected ? Theme.surfaceSelected : Color.clear)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }
}

struct IntegrationsPageSection<Content: View>: View {
    let title: String
    let open: Bool
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityValue(open ? "Open" : "Closed")
            .accessibilityAddTraits(.isHeader)
            if open { content() }
        }
    }
}

struct IntegrationsPageGrid<Content: View>: View {
    let columns: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 24), count: columns), alignment: .leading, spacing: 0) { content() }
    }
}

struct IntegrationsPageRow<Trailing: View>: View {
    let icon: String?
    let name: String
    let line: String
    var lineHelp: String? = nil
    var state: String? = nil
    var live = false
    let open: () -> Void
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 11) {
                    IntegrationsEntryIcon(name: icon, size: 20)
                        .frame(width: 28, height: 28)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: name).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).help(Text(verbatim: name))
                            if live { Circle().fill(Theme.accent).frame(width: 6, height: 6).help(state ?? "") }
                        }
                        Text(verbatim: line).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.tail).help(Text(verbatim: lineHelp ?? line))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: [name, state, line == state ? nil : line].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityHint("Opens its details")
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 53)
        .background(hovering ? Theme.surfaceHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }
}

struct IntegrationsPagePlus: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Install")
        .accessibilityLabel("Install \(name)")
    }
}

struct IntegrationsPageMenu: View {
    struct Item: Identifiable {
        let id: String
        let name: String
        let actions: [IntegrationsPageModel.MenuAction]
        let help: String?
    }

    @Environment(\.renderSafe) private var renderSafe
    let name: String
    let items: [Item]
    let perform: (IntegrationsPageModel.MenuAction, String) -> Void

    var body: some View {
        let dots = Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
            .frame(width: 28, height: 28).contentShape(Rectangle())
        if renderSafe { dots } else {
            Menu {
                if items.count == 1, let item = items.first {
                    buttons(item)
                } else {
                    ForEach(items) { item in Menu(item.name) { buttons(item) } }
                }
            } label: { dots }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("More")
            .accessibilityLabel("More for \(name)")
        }
    }

    @ViewBuilder
    private func buttons(_ item: Item) -> some View {
        ForEach(item.actions) { action in
            if action == .remove { Divider() }
            Button(role: action == .remove ? .destructive : nil) { perform(action, item.id) } label: {
                Label(action.title, systemImage: action.symbol)
            }
            .help(action == .disconnect ? item.help ?? "" : "")
        }
    }
}

struct IntegrationsMenuShot: View {
    let actions: [IntegrationsPageModel.MenuAction]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(actions) { action in
                if action == .remove { Rectangle().fill(Theme.hairline).frame(height: 1) }
                Label(action.title, systemImage: action.symbol).font(.system(size: 13))
                    .foregroundStyle(action == .remove ? Color.red : Theme.textPrimary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
            }
        }
        .padding(6).frame(width: 170, alignment: .leading)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
    }
}
