import SwiftUI

struct CompanionAppearanceDraft: Equatable {
    var name: String
    var appearance: CompanionAppearance
    let originalName: String

    init(name: String, appearance: CompanionAppearance) {
        self.name = name
        self.appearance = appearance
        originalName = name
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var displayName: String { trimmedName.isEmpty ? originalName : trimmedName }
    var subject: CompanionSubject { CompanionSubject(displayName) }

    var nameChanged: Bool { !trimmedName.isEmpty && trimmedName != originalName }

    @MainActor
    func commit(config: ConfigStore, store: any CompanionAppearanceStore, chat: ChatStore? = nil) throws {
        let previousName = config["assistant_name"]
        let previousAppearance = store.load()
        do {
            if nameChanged { config["assistant_name"] = trimmedName }
            try store.save(appearance)
            try config.save()
        } catch {
            config["assistant_name"] = previousName
            try? store.save(previousAppearance)
            throw error
        }
        if nameChanged { chat?.adoptAssistantName(trimmedName) }
    }
}

struct CompanionAppearancePicker: View {
    @ObservedObject var config: ConfigStore
    private let store: any CompanionAppearanceStore
    private let renderSafe: Bool
    private let chat: ChatStore?
    @State private var draft: CompanionAppearanceDraft
    @State private var failed = false
    @FocusState private var focus: Focus?
    @Environment(\.dismiss) private var dismiss

    private enum Focus: Hashable {
        case name
        case shape(CompanionShape)
        case color(CompanionColor)
    }

    init(config: ConfigStore, store: (any CompanionAppearanceStore)? = nil, chat: ChatStore? = nil, renderSafe: Bool = false) {
        self.config = config
        self.renderSafe = renderSafe
        self.chat = chat
        let resolved = store ?? ConfigCompanionAppearanceStore(config: config)
        self.store = resolved
        _draft = State(initialValue: CompanionAppearanceDraft(name: config.suppliedAssistantName ?? "", appearance: resolved.load()))
    }

    var body: some View {
        if renderSafe {
            content
                .frame(width: 640, height: 560)
                .background(Theme.bg)
        } else {
            VStack(spacing: 0) {
                content
                Rectangle().fill(Theme.hairline).frame(height: 1)
                footer
            }
            .modifier(CompanionAttentionWindow())
            .frame(width: 680, height: 470)
            .background(Theme.surface)
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            options
                .padding(renderSafe ? 24 : 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            preview
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Customize \(draft.subject.inline)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 8) {
                label("Name")
                if renderSafe {
                    Text(draft.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceHover))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline, lineWidth: 1))
                } else {
                    TextField("Name", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .name)
                        .onSubmit(save)
                        .accessibilityLabel("Name")
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                label("Shape")
                HStack(spacing: 12) {
                    ForEach(CompanionShape.allCases, id: \.self) { shape in shapeCard(shape) }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                label("Color")
                HStack(spacing: 14) {
                    ForEach(CompanionColor.allCases, id: \.self) { color in swatch(color) }
                }
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            CompanionAvatarView(appearance: draft.appearance, state: .ready, size: 160, name: draft.subject.name,
                                renderSafe: renderSafe)
            Text(draft.subject.leading)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 16)
            Spacer(minLength: 0)
        }
        .frame(width: renderSafe ? 230 : 260)
        .frame(maxHeight: .infinity)
        .background(Theme.bg.opacity(0.35))
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if failed {
                Text("Couldn't save. Try again.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }

    private func shapeCard(_ shape: CompanionShape) -> some View {
        let selected = draft.appearance.shape == shape
        let focused = focus == .shape(shape)
        return VStack(spacing: 8) {
            CompanionAvatarView(appearance: CompanionAppearance(shape: shape, color: draft.appearance.color),
                                state: .ready, size: 60, renderSafe: true)
            Text(shape.displayName)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
        }
        .frame(width: 112, height: 104)
        .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Theme.surfaceSelected : Theme.surfaceHover))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(focused ? Theme.accent : (selected ? Theme.textPrimary : Color.clear), lineWidth: focused ? 2 : 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { pick(shape) }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .shape(shape))
        .onKeyPress(.space) { pick(shape); return .handled }
        .onKeyPress(.leftArrow) { stepShape(-1); return .handled }
        .onKeyPress(.rightArrow) { stepShape(1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shape.displayName)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick(shape) }
    }

    private func swatch(_ color: CompanionColor) -> some View {
        let selected = draft.appearance.color == color
        let focused = focus == .color(color)
        return Circle()
            .fill(color.fill)
            .frame(width: 32, height: 32)
            .padding(4)
            .overlay(Circle().strokeBorder(focused ? Theme.accent : (selected ? Theme.textPrimary : Color.clear), lineWidth: 2))
            .contentShape(Circle())
            .onTapGesture { pick(color) }
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .color(color))
            .onKeyPress(.space) { pick(color); return .handled }
            .onKeyPress(.leftArrow) { stepColor(-1); return .handled }
            .onKeyPress(.rightArrow) { stepColor(1); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(color.displayName)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { pick(color) }
    }

    private func pick(_ shape: CompanionShape) {
        draft.appearance.shape = shape
        focus = .shape(shape)
    }

    private func pick(_ color: CompanionColor) {
        draft.appearance.color = color
        focus = .color(color)
    }

    private func stepShape(_ delta: Int) {
        let all = CompanionShape.allCases
        let index = all.firstIndex(of: draft.appearance.shape) ?? 0
        pick(all[(index + delta + all.count) % all.count])
    }

    private func stepColor(_ delta: Int) {
        let all = CompanionColor.allCases
        let index = all.firstIndex(of: draft.appearance.color) ?? 0
        pick(all[(index + delta + all.count) % all.count])
    }

    private func save() {
        do {
            try draft.commit(config: config, store: store, chat: chat)
            failed = false
            dismiss()
        } catch {
            failed = true
        }
    }
}
