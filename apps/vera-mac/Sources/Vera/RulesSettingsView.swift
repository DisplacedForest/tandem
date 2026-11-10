import SwiftUI

enum RulesCopy {
    static let headerTemplate = "These apply everywhere, including work \(CompanionSentence.placeholder) does without you. A chat can make them stricter, never looser."
    static let sectionTemplate = "What \(CompanionSentence.placeholder) may do"
    static let infoLabel = "What each choice means"
    static let floorSectionTitle = "Always left to you"

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
            for choice in NativeRuleChoice.allCases {
                strings.append(NativeRules.detail(for: action, choice: choice))
            }
        }
        for item in NativeFloorItem.allCases {
            strings.append(item.title)
            strings.append(item.reason)
        }
        return strings
    }
}

struct RulesChoiceHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

struct RulesSettingsTab: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @State private var showsChoiceHelp = false

    private func binding(for action: NativeActionClass) -> Binding<NativeRuleChoice> {
        Binding(
            get: { config.nativeSettings.rules.choice(for: action) },
            set: { config.applyRule($0, for: action, store: store) })
    }

    private func detail(for action: NativeActionClass) -> String {
        NativeRules.detail(for: action, choice: config.nativeSettings.rules.choice(for: action))
    }

    private func floorDetail(_ item: NativeFloorItem) -> String {
        let rules = config.nativeSettings.rules
        guard let action = item.actionClass, rules.isLifted(item) else { return item.reason }
        return "Lifted: \(rules.choice(for: action).title)"
    }

    var body: some View {
        Form {
            Section {
                if let notice = store.rulesNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                CompanionNamedText(template: RulesCopy.headerTemplate)
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                ForEach(NativeActionClass.configurable, id: \.self) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        Picker(action.title, selection: binding(for: action)) {
                            ForEach(NativeRuleChoice.allCases, id: \.self) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        Text(detail(for: action)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
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
            Section(RulesCopy.floorSectionTitle) {
                ForEach(NativeFloorItem.allCases, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                        Text(floorDetail(item)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
    }
}
