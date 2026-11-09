import SwiftUI

struct PreferencesSettingsView: View {
    @EnvironmentObject var store: ChatStore
    @State private var rows: [NativePreference] = []
    @State private var draft = ""
    @State private var editingID: String?
    @State private var editingText = ""
    @State private var problem: String?

    var body: some View {
        if let preferences = store.nativePreferenceStore {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(store.assistantName) follows these everywhere. You can also just say one in chat.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                ForEach(rows) { row in
                    if editingID == row.id {
                        HStack(spacing: 8) {
                            TextField("Preference", text: $editingText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { save(row, preferences) }
                            Button("Save") { save(row, preferences) }
                                .disabled(editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Cancel") { editingID = nil }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text(row.statement).font(.system(size: 12)).textSelection(.enabled)
                            Spacer()
                            Button("Edit") {
                                editingID = row.id
                                editingText = row.statement
                            }
                            Button("Remove", role: .destructive) { remove(row, preferences) }
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Never use em dashes", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { add(preferences) }
                    Button("Add") { add(preferences) }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .onAppear { reload(preferences) }
            .onChange(of: store.preferencesRevision) { reload(preferences) }
        } else {
            Label("Local storage is unavailable, so preferences cannot be edited.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(.orange)
        }
    }

    private func reload(_ preferences: NativePreferenceStore) {
        do {
            rows = try preferences.active()
            problem = nil
        } catch {
            problem = "Preferences couldn't load."
        }
    }

    private func add(_ preferences: NativePreferenceStore) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try preferences.add(statement: text, check: NativePreferenceRecognizer.check(for: text))
            draft = ""
            reload(preferences)
        } catch {
            problem = "That preference couldn't save."
        }
    }

    private func save(_ row: NativePreference, _ preferences: NativePreferenceStore) {
        do {
            try preferences.updateStatement(id: row.id, statement: editingText)
            editingID = nil
            reload(preferences)
        } catch {
            problem = "That change couldn't save."
        }
    }

    private func remove(_ row: NativePreference, _ preferences: NativePreferenceStore) {
        do {
            try preferences.remove(id: row.id)
            if editingID == row.id { editingID = nil }
            reload(preferences)
        } catch {
            problem = "That preference couldn't be removed."
        }
    }
}
