import SwiftUI

struct OngoingWorkItem: Identifiable, Equatable {
    enum Glyph: Equatable { case done, running, waiting, problem }

    let id: String
    let conversationID: String
    let title: String
    let state: String
    let glyph: Glyph
    let artifact: NativeResearchArtifact?
    let reference: NativeTaskReference?

    init(id: String, conversationID: String, title: String, state: String, glyph: Glyph,
         artifact: NativeResearchArtifact?, reference: NativeTaskReference?) {
        self.id = id
        self.conversationID = conversationID
        self.title = title
        self.state = state
        self.glyph = glyph
        self.artifact = artifact
        self.reference = reference
    }

    init(reference: NativeTaskReference, title: String, state: String, glyph: Glyph, artifact: NativeResearchArtifact?) {
        self.init(id: reference.id.uuidString, conversationID: reference.origin.conversationID, title: title, state: state,
                  glyph: glyph, artifact: artifact, reference: reference)
    }

    var isActive: Bool { glyph == .running || glyph == .waiting }
}

struct OngoingWorkGroup: Identifiable, Equatable {
    let conversationID: String?
    let title: String
    let items: [OngoingWorkItem]

    var id: String { conversationID ?? "" }
}

enum OngoingWorkMetrics {
    static let panelWidth: CGFloat = 380
    static let minimumWindowWidth: CGFloat = 1120
    static let glyphSize: CGFloat = 28
}

enum OngoingWork {
    static let otherTitle = "Other"
    static let readyToOpen = "Ready to open"

    static func presentation(status: NativeTaskCardPresentation.Status, document: Bool,
                             hasArtifact: Bool) -> (glyph: OngoingWorkItem.Glyph, state: String) {
        let label = status.title(document: document)
        switch status {
        case .completed: return (.done, hasArtifact ? readyToOpen : label)
        case .preparing, .queued, .working, .stopping: return (.running, label)
        case .needsInput: return (.waiting, label)
        case .failed, .stopped: return (.problem, label)
        }
    }

    static func item(_ reference: NativeTaskReference) -> OngoingWorkItem {
        let document = reference.createRequest.workerType == "document"
        let display = try? NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot)
        let status = display?.card.status ?? .preparing
        let artifact = display?.artifact
        let shown = presentation(status: status, document: document, hasArtifact: artifact != nil)
        return OngoingWorkItem(reference: reference, title: reference.request.displayTitle,
                               state: display?.card.listState(shown.state) ?? shown.state, glyph: shown.glyph, artifact: artifact)
    }

    static func items(_ references: [NativeTaskReference], conversationID: String?) -> [OngoingWorkItem] {
        guard let conversationID else { return [] }
        return references.reversed().filter { $0.origin.conversationID == conversationID }.map(item)
    }

    static func activeCount(_ references: [NativeTaskReference], conversationID: String?) -> Int {
        items(references, conversationID: conversationID).filter(\.isActive).count
    }

    static func groups(_ references: [NativeTaskReference], conversations: [Conversation]) -> [OngoingWorkGroup] {
        let titles = Dictionary(conversations.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        var known: [String: [OngoingWorkItem]] = [:]
        var other: [OngoingWorkItem] = []
        for reference in references.reversed() {
            let entry = item(reference)
            guard titles[entry.conversationID] != nil else { other.append(entry); continue }
            if known[entry.conversationID] == nil { order.append(entry.conversationID) }
            known[entry.conversationID, default: []].append(entry)
        }
        var result = order.map { id in
            OngoingWorkGroup(conversationID: id, title: titles[id] ?? otherTitle, items: known[id] ?? [])
        }
        if !other.isEmpty { result.append(OngoingWorkGroup(conversationID: nil, title: otherTitle, items: other)) }
        return result
    }

    static func revealApplies(origin: String, selectedConversationID: String?, generation: Int,
                              latestGeneration: Int, cancelled: Bool = false) -> Bool {
        !cancelled && generation == latestGeneration && selectedConversationID == origin
    }

    static func owningMessageID(taskID: String, fallback: UUID?, in messages: [Message]) -> UUID? {
        let block = "task:" + taskID
        if let owner = messages.first(where: { $0.displayBlocks.contains { $0.id == block } }) { return owner.id }
        guard let fallback, messages.contains(where: { $0.id == fallback }) else { return nil }
        return fallback
    }
}

extension ChatStore {
    func revealOngoingWork(_ reference: NativeTaskReference) {
        let target = reference.origin.conversationID
        guard conversations.contains(where: { $0.id == target }) else { return }
        taskRevealGeneration &+= 1
        if selectedID != target || !(section == .chat || section == .vera) { select(target) }
        pendingTaskReveal = reference.id.uuidString
    }
}

struct OngoingWorkGlyph: View {
    let glyph: OngoingWorkItem.Glyph

    var body: some View {
        ZStack {
            switch glyph {
            case .done:
                Circle().fill(Theme.sage.opacity(0.18))
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.sage)
            case .running:
                Circle().stroke(Theme.cardStroke, lineWidth: 2).padding(4)
                Circle().trim(from: 0, to: 0.3).stroke(Theme.sage, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(4)
            case .waiting:
                Circle().fill(Theme.warmTextSecondary.opacity(0.16))
                Image(systemName: "clock").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.warmTextPrimary)
            case .problem:
                Circle().fill(Theme.accent.opacity(0.18))
                Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
            }
        }
        .frame(width: OngoingWorkMetrics.glyphSize, height: OngoingWorkMetrics.glyphSize)
        .accessibilityHidden(true)
    }
}

struct OngoingWorkCard: View {
    let item: OngoingWorkItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                OngoingWorkGlyph(glyph: item.glyph)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.warmTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.state)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warmTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warmTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(item.state)")
    }
}

struct OngoingWorkPanel: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.renderSafe) private var renderSafe
    let conversationID: String?
    let onSelect: (NativeTaskReference) -> Void
    var onClose: (() -> Void)? = nil
    @State private var showingAll = false

    var body: some View {
        let items = OngoingWork.items(store.nativeTaskReferences, conversationID: conversationID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Ongoing work")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.warmTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let onClose {
                    Button("Done", action: onClose)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Close ongoing work")
                }
            }
            .frame(height: ConversationMetrics.avatarSize)
            .padding(.horizontal, 24).padding(.top, onClose == nil ? 36 : 24).padding(.bottom, 16)
            if items.isEmpty {
                Text("Nothing running right now.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.warmTextSecondary)
                    .padding(.horizontal, 24)
                Spacer(minLength: 0)
            } else if renderSafe {
                list(items)
                Spacer(minLength: 0)
            } else {
                ScrollView { list(items) }
            }
            if !store.nativeTaskReferences.isEmpty {
                Button { showingAll = true } label: {
                    Text("View all work")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.sage)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.conversationBackground)
        .sheet(isPresented: $showingAll) {
            OngoingWorkAllSheet(onGo: { reference in
                showingAll = false
                onSelect(reference)
            })
            .environmentObject(store)
        }
    }

    private func list(_ items: [OngoingWorkItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                OngoingWorkCard(item: item) { if let reference = item.reference { onSelect(reference) } }
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 8)
    }
}

struct OngoingWorkAllSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    let onGo: (NativeTaskReference) -> Void

    var body: some View {
        let groups = OngoingWork.groups(store.nativeTaskReferences, conversations: store.conversations)
        VStack(spacing: 0) {
            HStack {
                Text("All work")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.warmTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close all work")
            }
            .padding(20)
            Rectangle().fill(Theme.cardStroke).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.warmTextSecondary)
                                .lineLimit(1)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.items) { item in
                                row(item, canGo: group.conversationID != nil)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 520)
        .background(Theme.conversationBackground)
    }

    private func row(_ item: OngoingWorkItem, canGo: Bool) -> some View {
        HStack(spacing: 12) {
            OngoingWorkGlyph(glyph: item.glyph)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.warmTextPrimary)
                    .lineLimit(2)
                Text(item.state)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warmTextSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if canGo, let reference = item.reference {
                Button("Go") { onGo(reference) }
                    .accessibilityLabel("Go to \(item.title)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }
}

struct OngoingWorkFooter: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.sage)
        }
        .buttonStyle(.plain)
    }
}
