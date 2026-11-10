import SwiftUI

struct RulesSettingsTab: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore

    private func binding(for action: NativeActionClass) -> Binding<NativeRuleChoice> {
        Binding(
            get: { config.nativeSettings.rules.choice(for: action) },
            set: { config.applyRule($0, for: action, store: store) })
    }

    private func floorDetail(_ item: NativeFloorItem) -> String {
        let rules = config.nativeSettings.rules
        guard let action = item.actionClass, rules.isLifted(item) else { return item.reason }
        return "Lifted: \(rules.choice(for: action).title)"
    }

    var body: some View {
        Form {
            Section("What asks first") {
                if let notice = store.rulesNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Text("These defaults apply to every chat and to work Vera does on her own. A chat can tighten them, never loosen them.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                ForEach(NativeActionClass.configurable, id: \.self) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        Picker(action.title, selection: binding(for: action)) {
                            ForEach(NativeRuleChoice.allCases, id: \.self) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        Text(action.detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("Handed to you") {
                ForEach(NativeFloorItem.allCases, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                        Text(floorDetail(item)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("How the choices work") {
                Text("Act without asking runs the action and shows what happened on the turn. Act only when the request pre-approves it runs only when your message says so in plain words, such as \"go ahead\" or \"no need to ask\", and asks otherwise. Pre-approval is recognized only when a sentence of your request is exactly the phrase on its own: \"Run the tests. Go ahead.\" runs, while \"Go ahead and run the tests\" asks. Ask first puts a card on the turn with Approve, Decline and, for commands, Approve similar, which lets later commands in that chat with the same first words run without asking. Hand off to me means Vera describes what she would do and leaves it to you. Act without asking for commands relies on a declared table of sending and destructive commands; when unsure, keep commands on Ask first.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
        .formStyle(.grouped)
    }
}
