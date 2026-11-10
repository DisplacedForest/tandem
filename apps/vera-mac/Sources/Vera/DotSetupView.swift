import SwiftUI

enum DotProfileCopy {
    static func subtitle(_ name: String) -> String {
        "Give \(name) a standing goal, choose what it can reach and set what asks first. You can change all of this later from the header."
    }

    static func startOver(_ name: String) -> String {
        "Removes the conversation, what \(name) remembered from it and its schedules. Artifacts stay in Artifacts."
    }

    static let pausedNote = "While paused, scheduled work is skipped and nothing catches up later. Chat keeps working."
    static let servicesNote = "Turned off here means it stays off in this conversation, even when it is on in Settings."
    static let noServices = "Nothing is turned on in Settings yet. Tools you turn on there show up here."
    static let rulesNote = "These can only ask more than your defaults in Settings, never less."

    @MainActor
    static func draftRules(_ store: ChatStore) -> [NativeActionClass: NativeRuleChoice] {
        guard let id = store.veraThreadID else { return [:] }
        return store.conversationRules(for: id).choices
    }

    @MainActor
    static func commitRules(_ rules: [NativeActionClass: NativeRuleChoice], revokedPrefixes: Set<String> = [], store: ChatStore) {
        guard let id = store.veraThreadID else { return }
        for action in NativeActionClass.configurable {
            store.tightenConversationRule(rules[action] ?? store.nativeRules.choice(for: action), for: action, conversationID: id)
        }
        let approved = Set(store.approvedCommandRecords(for: id).map(\.id))
        for record in revokedPrefixes.sorted() where approved.contains(record) {
            store.revokeRuleRecord(id: record)
        }
    }

    static func counter(_ count: Int) -> String? {
        guard count > NativeDotProfile.goalLimit - 300 else { return nil }
        return "\(count.formatted()) of \(NativeDotProfile.goalLimit.formatted()) characters"
    }

    @MainActor
    static func saveName(_ name: String, config: ConfigStore, store: ChatStore) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = config["assistant_name"]
        guard trimmed != previous.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        config["assistant_name"] = trimmed
        do {
            try config.save()
        } catch {
            config["assistant_name"] = previous
            return "The name couldn't be saved: \(error.localizedDescription)"
        }
        store.adoptAssistantName(config.suppliedAssistantName)
        return nil
    }
}

struct DotProfileForm: View {
    @EnvironmentObject var store: ChatStore
    @Binding var name: String
    @Binding var goal: String
    @Binding var selected: Set<String>
    @Binding var rules: [NativeActionClass: NativeRuleChoice]
    @Binding var revokedPrefixes: Set<String>
    let options: [NativeDotServiceOption]

    private var goalBinding: Binding<String> {
        Binding(get: { goal }, set: { goal = String($0.prefix(NativeDotProfile.goalLimit)) })
    }

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("Name"))
            VStack(alignment: .leading, spacing: 6) {
                Text("Goal")
                TextEditor(text: goalBinding)
                    .font(.system(size: 13))
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
                if let counter = DotProfileCopy.counter(goal.count) {
                    Text(counter).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Connected services")
                if options.isEmpty {
                    Text(DotProfileCopy.noServices).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                } else {
                    Text(DotProfileCopy.servicesNote).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    ForEach(options) { option in
                        Toggle(isOn: Binding(
                            get: { selected.contains(option.id) },
                            set: { if $0 { selected.insert(option.id) } else { selected.remove(option.id) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.name).font(.system(size: 12))
                                Text(option.detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                Text("What asks first")
                Text(DotProfileCopy.rulesNote).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                ConversationRulesEditor(conversationID: store.veraThreadID, embedded: true, draft: $rules, revokedPrefixes: $revokedPrefixes)
            }
            .padding(.top, 6)
        }
        .formStyle(.columns)
    }
}
