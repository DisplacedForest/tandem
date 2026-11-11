import SwiftUI

enum RulesCopy {
    static let headerTemplate = "These apply everywhere, including work \(CompanionSentence.placeholder) does without you. A chat can make them stricter, never looser."
    static let sectionTemplate = "What \(CompanionSentence.placeholder) may do"
    static let infoLabel = "What each choice means"
    static let floorSectionTitle = "Always left to you"
    static let imagesNote = "This also covers saving generated images."

    static func info(for action: NativeActionClass, choice: NativeRuleChoice) -> String {
        let detail = NativeRules.detail(for: action, choice: choice)
        return action == .fileEdits ? detail + " " + imagesNote : detail
    }

    static func infoLabel(for action: NativeActionClass) -> String { "About: \(action.title)" }

    static func explanationTemplate(_ choice: NativeRuleChoice) -> String {
        switch choice {
        case .act: return "\(CompanionSentence.placeholder) does it and shows you what happened."
        case .actIfPreapproved: return "\(CompanionSentence.placeholder) does it only when your message says to, like \"go ahead\". Otherwise you get asked."
        case .ask: return "You get a card to approve or decline."
        case .handOff: return "\(CompanionSentence.placeholder) tells you the step and you do it yourself."
        }
    }

    static func screenStrings(name: String?) -> [String] {
        var strings = [CompanionSentence.plain(headerTemplate, name: name), CompanionSentence.plain(sectionTemplate, name: name), infoLabel, floorSectionTitle]
        for choice in NativeRuleChoice.allCases {
            strings.append(choice.title)
            strings.append(CompanionSentence.plain(explanationTemplate(choice), name: name))
        }
        for action in NativeActionClass.allCases {
            strings.append(action.title)
            strings.append(action.detail)
            strings.append(infoLabel(for: action))
            for choice in NativeRuleChoice.allCases {
                strings.append(info(for: action, choice: choice))
            }
        }
        for item in NativeFloorItem.allCases {
            strings.append(item.title)
            strings.append(item.reason)
        }
        return strings + RulesAdvancedCopy.screenStrings(name: name)
    }
}

struct RulesChoiceHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CompanionNamedText(template: RulesCopy.headerTemplate)
                .font(.system(size: 12))
            ForEach(NativeRuleChoice.allCases, id: \.self) { choice in
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title).font(.system(size: 12))
                    CompanionNamedText(template: RulesCopy.explanationTemplate(choice))
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }
}

struct SavedRuleRow: View {
    let row: RuleRow
    var onToggle: () -> Void
    var onWiden: () -> Void
    var onRemove: () -> Void
    @Environment(\.companionName) private var name

    private var spoken: String { CompanionSentence.plain(row.line, name: name) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                CompanionNamedText(template: row.line)
                    .foregroundStyle(row.off ? Theme.textSecondary : Theme.textPrimary)
                if let note = row.note {
                    CompanionNamedText(template: note)
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let toggle = row.toggleTitle {
                Menu {
                    Button(toggle, action: onToggle)
                    if row.widens { Button(RuleRows.applyEverywhere, action: onWiden) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(RuleRows.more): \(spoken)")
                .help(RuleRows.more)
            }
            Button(RuleRows.remove, action: onRemove)
                .accessibilityLabel("\(RuleRows.remove): \(spoken)")
        }
        .padding(.vertical, 2)
    }
}

struct RulesSettingsTab: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @State private var showsChoiceHelp = false
    @State private var infoFor: NativeActionClass?
    @State private var rows: [RuleRow] = []
    @State private var widening: RuleRow?
    @State private var advanced: RulesAdvancedState

    init(advanced: RulesAdvancedState = RulesAdvancedState()) {
        _advanced = State(initialValue: advanced)
    }

    private func refresh() { rows = store.ruleRows() }

    private func infoShown(_ action: NativeActionClass) -> Binding<Bool> {
        Binding(get: { infoFor == action }, set: { infoFor = $0 ? action : nil })
    }

    private func binding(for action: NativeActionClass) -> Binding<NativeRuleChoice> {
        Binding(
            get: { config.nativeSettings.rules.choice(for: action) },
            set: { config.applyRule($0, for: action, store: store) })
    }

    private func detail(for action: NativeActionClass) -> String {
        RulesCopy.info(for: action, choice: config.nativeSettings.rules.choice(for: action))
    }

    var body: some View {
        Form {
            Section {
                if let notice = store.rulesNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                ForEach(NativeActionClass.configurable, id: \.self) { action in
                    HStack(spacing: 8) {
                        Picker(action.title, selection: binding(for: action)) {
                            ForEach(NativeRuleChoice.allCases, id: \.self) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        Button {
                            infoFor = infoFor == action ? nil : action
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(RulesCopy.infoLabel(for: action))
                        .help(RulesCopy.infoLabel(for: action))
                        .popover(isPresented: infoShown(action), arrowEdge: .trailing) {
                            Text(detail(for: action))
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                                .frame(width: 300, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                HStack {
                    CompanionNamedText(template: RulesCopy.sectionTemplate)
                    Spacer()
                    Button {
                        showsChoiceHelp.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(RulesCopy.infoLabel)
                    .help(RulesCopy.infoLabel)
                    .popover(isPresented: $showsChoiceHelp, arrowEdge: .bottom) {
                        RulesChoiceHelp()
                    }
                }
            }
            Section(RuleRows.sectionTitle) {
                if rows.isEmpty {
                    Text(RuleRows.empty).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                ForEach(rows) { row in
                    SavedRuleRow(row: row, onToggle: { store.toggleRule(row) },
                                 onWiden: { if row.widenQuestion == nil { store.widenRule(row) } else { widening = row } },
                                 onRemove: { store.removeRule(row) })
                }
            }
            Section(RulesCopy.floorSectionTitle) {
                ForEach(RulesAdvancedCopy.leftToYou(config.nativeSettings.rules), id: \.self) { item in
                    RulesLeftToYouRow(item: item, state: $advanced)
                }
            }
            RulesAdvancedSection(state: $advanced)
        }
        .formStyle(.grouped)
        .onDisappear { advanced.leave() }
        .onAppear {
            store.sweepRuleRecords()
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ruleRecordsChanged).receive(on: RunLoop.main)) { _ in refresh() }
        .onChange(of: store.conversations.map(\.title)) { _, _ in refresh() }
        .onChange(of: config.nativeSettings.rules) { _, _ in refresh() }
        .confirmationDialog(widening?.widenQuestion ?? "", isPresented: Binding(get: { widening != nil }, set: { if !$0 { widening = nil } }),
                            titleVisibility: .visible) {
            Button(RuleRows.widenConfirm) {
                if let row = widening { store.widenRule(row) }
                widening = nil
            }
            Button(RuleRows.cancel, role: .cancel) { widening = nil }
        }
    }
}
