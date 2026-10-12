import SwiftUI

private struct DomainSourceChoice: Identifiable {
    let conversation: String
    let title: String
    let message: Message
    var id: String { message.id.uuidString }
}

struct NativeDomainRecordView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [DomainSourceChoice] = []
    @State private var sourceID = ""
    @State private var selectedMemory = ""
    @State private var entityID = UUID()
    @State private var label = ""
    @State private var scope = "personal"
    @State private var kind = "Observed count"
    @State private var quantity = ""
    @State private var predicate = ""
    @State private var value = ""
    @State private var occurredAt = Date()
    @State private var replaces = ""
    @State private var entries: [NativeDomainEntry] = []
    @State private var error: String?
    private let kinds = ["Observed count", "Added", "Removed", "Fact", "Care completed", "Care planned", "Care recommended", "Care possible", "Care did not occur", "Retract evidence"]

    private var records: [NativeMemoryRecord] { store.memoryRecords.filter { $0.domainEntityID != nil && $0.status == .approved } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record from evidence").font(.title2.bold())
            Text("Choose what the source establishes. You’ll review the proposed change before it affects memory.")
                .font(.callout).foregroundStyle(Theme.textSecondary)
            Form {
                Picker("Subject", selection: $selectedMemory) {
                    Text("New subject").tag("")
                    ForEach(records) { Text($0.title).tag($0.id) }
                }
                if selectedMemory.isEmpty {
                    TextField("Subject name", text: $label)
                    TextField("Memory library", text: $scope)
                }
                Picker("Source", selection: $sourceID) {
                    Text("Choose a saved message").tag("")
                    ForEach(sources) { Text($0.title + ": " + String($0.message.text.prefix(90))).tag($0.id) }
                }
                if let source = sources.first(where: { $0.id == sourceID }) {
                    ScrollView { Text(source.message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
                }
                Picker("Record", selection: $kind) { ForEach(kinds, id: \.self) { Text($0).tag($0) } }
                if ["Observed count", "Added", "Removed"].contains(kind) { TextField("Number", text: $quantity) }
                if kind == "Fact" {
                    TextField("Property", text: $predicate)
                    TextField("Value", text: $value)
                } else if kind.hasPrefix("Care") { TextField("Activity", text: $predicate) }
                DatePicker("When this was true or happened", selection: $occurredAt)
                if !entries.isEmpty {
                    Picker("Correction", selection: $replaces) {
                        Text("Does not replace earlier evidence").tag("")
                        ForEach(entries.filter { $0.status != .deleted }) {
                            Text(LocalChatRepository.domainDescription($0) + " (" + $0.occurredAt.formatted(date: .abbreviated, time: .shortened) + ")").tag($0.id.uuidString)
                        }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Propose for review", action: propose).buttonStyle(.borderedProminent)
                    .disabled(sourceID.isEmpty || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 650, height: 650)
        .task {
            do {
                guard let repository = store.repository as? LocalChatRepository else { throw NativeDomainError.sourceUnavailable }
                for conversation in try repository.listConversations().prefix(50) where !conversation.memoryExcluded {
                    for message in try repository.recentMessages(conversationID: conversation.id, limit: 20)
                        where message.role == .user && message.state == .complete && message.failure == nil {
                        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !NativeMemorySafety.containsSensitiveData(text), !text.lowercased().hasPrefix("private:"),
                              !text.lowercased().hasPrefix("do not remember"), text.utf8.count <= 8192 else { continue }
                        sources.append(DomainSourceChoice(conversation: conversation.id, title: conversation.title, message: message))
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: selectedMemory) { _, id in
            replaces = ""
            if let memory = records.first(where: { $0.id == id }), let entity = memory.domainEntityID {
                entityID = entity
                label = memory.title
                scope = memory.bank
                entries = (try? (store.repository as? LocalChatRepository)?.domainEntries(entity, scope: scope)) ?? []
            } else { entityID = UUID(); label = ""; scope = "personal"; entries = [] }
        }
    }

    private func propose() {
        do {
            guard let source = sources.first(where: { $0.id == sourceID }) else { throw NativeDomainError.sourceUnavailable }
            let payload: NativeDomainPayload
            switch kind {
            case "Observed count": payload = .stock(kind: .baseline, quantity: try NativeDomainQuantity(quantity, unit: .count))
            case "Added": payload = .stock(kind: .addition, quantity: try NativeDomainQuantity(quantity, unit: .count))
            case "Removed": payload = .stock(kind: .removal, quantity: try NativeDomainQuantity(quantity, unit: .count))
            case "Fact": payload = .fact(predicate: predicate, value: value, quantity: nil)
            case "Care completed": payload = .care(activity: predicate, status: .completed)
            case "Care planned": payload = .care(activity: predicate, status: .planned)
            case "Care recommended": payload = .care(activity: predicate, status: .recommended)
            case "Care possible": payload = .care(activity: predicate, status: .possible)
            case "Care did not occur": payload = .care(activity: predicate, status: .notOccurred)
            default: payload = .retraction
            }
            let entry = NativeDomainEntry(id: UUID(), entityID: entityID, scope: scope.trimmingCharacters(in: .whitespacesAndNewlines),
                occurredAt: occurredAt, validUntil: nil, learnedAt: Date(), actor: "user",
                source: NativeDomainSource(conversationID: source.conversation, messageID: source.id,
                    version: LocalChatRepository.domainHash(source.message.text), lowerUTF8: 0, upperUTF8: source.message.text.utf8.count),
                evidence: .asserted, entityResolved: true, status: .supported,
                supersedes: UUID(uuidString: replaces).map { [$0] } ?? [], payload: payload)
            try store.proposeDomainRecord(entry, label: label.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
