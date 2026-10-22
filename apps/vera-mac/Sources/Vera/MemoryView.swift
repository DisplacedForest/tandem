import SwiftUI

struct MemoryView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore
    @State private var search = ""
    @State private var selectedGroup: NativeMemoryGroup?
    @State private var selectedBank: String?
    @State private var selectedCategory: NativeMemoryCategory?
    @State private var selectedStatus: NativeMemoryStatus? = .approved
    @State private var selectedExpiry = NativeMemoryExpiryFilter.all
    @State private var selected: NativeMemoryRecord?
    @State private var changeRequest = ""
    @State private var showClear = false
    @State private var showDomainRecord = false
    @State private var pendingRemoval: NativeMemoryRecord?
    @State private var upcoming: [String: [NativeDomainEntry]] = [:]
    @State private var upcomingSubjects: [NativeUpcomingSubject] = []
    @State private var openedUpcoming: NativeUpcomingSubject?
    @State private var unavailableSources: Set<String> = []

    private var visible: [NativeMemoryRecord] {
        let filter = NativeMemoryLibraryFilter(
            query: search, group: selectedGroup, bank: selectedBank,
            category: selectedCategory, status: selectedStatus, expiry: selectedExpiry)
        return store.memoryRecords.filter { filter.matches($0) }
    }

    private var banks: [String] {
        Array(Set(store.memoryRecords.map(\.bank) + upcomingSubjects.map(\.scope))).sorted()
    }

    private var visibleUpcoming: [NativeUpcomingSubject] {
        let filter = NativeMemoryLibraryFilter(
            query: search, group: selectedGroup, bank: selectedBank,
            category: selectedCategory, status: selectedStatus, expiry: selectedExpiry)
        return upcomingSubjects.compactMap { subject in
            guard filter.matches(subject) else { return nil }
            return NativeUpcomingSubject(entityID: subject.entityID, scope: subject.scope, label: subject.label,
                entries: filter.matchingEntries(subject), sources: subject.sources)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statusCard
                controls
                changeComposer
                if !store.memoryProposals.isEmpty { reviewQueue }
                library
            }
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
        }
        .background(Theme.bg)
        .sheet(item: $selected) { MemoryDetailView(memory: $0) }
        .sheet(item: $openedUpcoming) { NativeUpcomingSubjectView(subject: $0) }
        .sheet(isPresented: $showDomainRecord) { NativeDomainRecordView() }
        .confirmationDialog(
            "Clear all approved memory?", isPresented: $showClear,
            titleVisibility: .visible
        ) {
            Button("Clear approved memory", role: .destructive) { store.clearNativeMemory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes approved memory from later chat requests. Conversation history is not changed.")
        }
        .memoryRemovalConfirmation($pendingRemoval)
        .task { store.loadMemoryLibrary(); loadLibraryState() }
        .onChange(of: store.memoryRecords) { _, _ in loadLibraryState() }
        .onChange(of: store.memoryLibraryRevision) { _, _ in loadLibraryState() }
    }

    private func loadLibraryState() {
        guard let repository = store.repository as? LocalChatRepository else { return }
        upcoming = (try? repository.upcomingDomainCare()) ?? [:]
        upcomingSubjects = (try? repository.upcomingOnlySubjects()) ?? []
        unavailableSources = (try? repository.memoriesWithUnavailableSources()) ?? []
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Memory").font(.system(size: 26, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("A local, reviewable library of what Vera may remember about you.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Record from evidence") { showDomainRecord = true }
                .disabled(!config.nativeSettings.memory.enabled)
                .accessibilityLabel("Record from evidence")
                .accessibilityHint("Creates a record from a saved message for you to review")
            Text("\(visible.count + visibleUpcoming.count) shown")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.surface, in: Capsule())
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(statusColor)
                .frame(width: 34, height: 34).background(statusColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.memoryServiceState.label).font(.system(size: 13, weight: .semibold))
                if !statusDetail.isEmpty {
                    Text(statusDetail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                if !store.memoryRecallDescription.isEmpty {
                    Text(store.memoryRecallDescription).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                if let progress = store.memoryIndexingProgress {
                    Text(progress.label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                if let outcome = store.memoryGroomOutcome {
                    Text(outcome.label).font(.system(size: 11))
                        .foregroundStyle(outcome.error == nil ? Theme.textSecondary : .red)
                }
            }
            Spacer()
            SettingsLink { Text("Memory settings") }
                .accessibilityLabel("Memory settings")
                .accessibilityHint("Opens Memory settings")
        }
        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        .task { await store.probeMemoryEndpoint() }
    }

    private var statusIcon: String {
        switch store.memoryServiceState {
        case .ready: "checkmark.circle.fill"
        case .off: "pause.circle.fill"
        case .indexing: "arrow.triangle.2.circlepath"
        case .pendingReview, .maintenanceNeeded: "tray.full.fill"
        case .setupRequired: "gearshape.fill"
        case .retrievalUnavailable, .failed: "exclamationmark.triangle.fill"
        case .notice: "info.circle.fill"
        }
    }

    private var statusColor: Color {
        switch store.memoryServiceState {
        case .ready: .green
        case .pendingReview, .maintenanceNeeded: .orange
        case .retrievalUnavailable, .failed: .red
        case .notice: Theme.textSecondary
        default: Theme.accent
        }
    }

    private var statusDetail: String {
        switch store.memoryServiceState {
        case .off: "Nothing is retrieved, generated, maintained, or added to chat while Memory is off."
        case .setupRequired: "Choose an extraction model to suggest changes. Approved memory can be searched locally without one."
        case .ready: "Only approved, relevant, unexpired items can be added to native chat requests."
        case .indexing: "Vera is preparing approved memory."
        case .pendingReview: "Nothing in the queue changes approved memory until you accept it."
        case .maintenanceNeeded: "Review capacity, expiry, or consolidation suggestions. Only expired episodic items are removed automatically."
        case .retrievalUnavailable(let detail), .failed(let detail): "\(detail) Ordinary chat continues without memory context."
        case .notice: ""
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build your library").font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                MemoryActionCard(
                    icon: "text.magnifyingglass",
                    title: config.nativeSettings.memory.searchPastChats ? "Search past chats again" : "Search past chats",
                    detail: "Scans up to 12 completed local turns and creates proposals for review.",
                    action: searchPastChats)
                MemoryActionCard(
                    icon: "sparkles",
                    title: config.nativeSettings.memory.generateFromChats ? "Chat generation is on" : "Generate from chats",
                    detail: "Creates proposals after eligible completed turns. It never writes approved memory directly.",
                    action: { toggle(\.generateFromChats) })
            }
        }
    }

    private var changeComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask Memory to change").font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Describe what to remember, correct, merge, suppress, expire, or forget. Vera turns the request into a proposal for review.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                TextField("For example, remember that I prefer morning meetings", text: $changeRequest)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitChange() }
                    .accessibilityLabel("Memory change request")
                    .accessibilityHint("Describe what Memory should remember, correct, or forget")
                Button("Create proposal") { submitChange() }
                    .disabled(changeRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Create proposal")
                    .accessibilityHint("Turns your request into a proposal for review")
            }
        }
        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }

    private var reviewQueue: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Review").font(.system(size: 16, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("\(store.memoryProposals.count)")
                    .font(.system(size: 11, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.orange.opacity(0.16), in: Capsule())
                    .accessibilityLabel("\(store.memoryProposals.count) waiting for review")
            }
            ForEach(store.memoryProposals) { proposal in
                MemoryProposalRow(proposal: proposal)
            }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Library").font(.system(size: 16, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Button("Clear approved memory", role: .destructive) { showClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More library actions")
            }
            HStack(spacing: 8) {
                TextField("Search memory", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search memory")
                Menu(selectedGroup?.rawValue ?? "Group") {
                    Button("All groups") { selectedGroup = nil }
                    ForEach(NativeMemoryGroup.allCases) { group in
                        Button(group.rawValue) { selectedGroup = group }
                    }
                }
                .accessibilityLabel("Filter by group")
                .accessibilityValue(selectedGroup?.rawValue ?? "All groups")
                Menu(selectedBank ?? "Bank") {
                    Button("All banks") { selectedBank = nil }
                    ForEach(banks, id: \.self) { bank in
                        Button(bank) { selectedBank = bank }
                    }
                }
                .accessibilityLabel("Filter by bank")
                .accessibilityValue(selectedBank ?? "All banks")
                Menu(selectedCategory?.rawValue.capitalized ?? "Category") {
                    Button("All categories") { selectedCategory = nil }
                    ForEach(NativeMemoryCategory.allCases) { category in
                        Button(category.rawValue.capitalized) { selectedCategory = category }
                    }
                }
                .accessibilityLabel("Filter by category")
                .accessibilityValue(selectedCategory?.rawValue.capitalized ?? "All categories")
                Menu(selectedStatus?.rawValue.capitalized ?? "Status") {
                    Button("All statuses") { selectedStatus = nil }
                    Button("Approved") { selectedStatus = .approved }
                    Button("Suppressed") { selectedStatus = .suppressed }
                }
                .accessibilityLabel("Filter by status")
                .accessibilityValue(selectedStatus?.rawValue.capitalized ?? "All statuses")
                Menu(selectedExpiry == .all ? "Expiry" : selectedExpiry.rawValue) {
                    ForEach(NativeMemoryExpiryFilter.allCases) { expiry in
                        Button(expiry.rawValue) { selectedExpiry = expiry }
                    }
                }
                .accessibilityLabel("Filter by expiry")
                .accessibilityValue(selectedExpiry.rawValue)
            }
            ForEach(NativeMemoryGroup.allCases) { group in
                let items = visible.filter { $0.libraryGroup == group }
                let planned = visibleUpcoming.filter { $0.libraryGroup == group }
                if selectedGroup == nil || selectedGroup == group {
                    MemoryGroupSection(group: group, items: items, upcoming: upcoming, upcomingSubjects: planned,
                        unavailableSources: unavailableSources, selected: $selected, pendingRemoval: $pendingRemoval,
                        openedUpcoming: $openedUpcoming)
                }
            }
        }
    }

    private func submitChange() {
        let request = changeRequest
        changeRequest = ""
        store.requestMemoryChange(request)
    }

    private func toggle(_ keyPath: WritableKeyPath<NativeMemorySettings, Bool>) {
        config.updateMemory { $0[keyPath: keyPath].toggle() }
        try? config.save()
        store.updateNativeMemory(
            settings: config.nativeSettings.memory,
            service: config.nativeMemoryService)
    }

    private func searchPastChats() {
        store.scanPastChatsIfAllowed()
    }

}

private struct MemoryActionCard: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

struct NativeCareLineView: View {
    let line: NativeCareLine
    var size: CGFloat = 12
    var dateText: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: line.state.symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(line.activity).font(.system(size: size))
            Text(dateText.map { "Upcoming, " + $0 } ?? line.state.label)
                .font(.system(size: max(size - 1, 9), weight: .semibold)).foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch line.state {
        case .completed: .green
        case .planned: Theme.accent
        case .uncertain: .orange
        case .recommended, .possible, .notOccurred: Theme.textSecondary
        }
    }
}

struct MemoryLineView: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = Theme.textPrimary

    var body: some View {
        if let care = NativeCareLine.parse(text) {
            NativeCareLineView(line: care, size: size)
        } else {
            Text(text).font(.system(size: size)).foregroundStyle(color)
        }
    }
}

struct UpcomingCareView: View {
    let entry: NativeDomainEntry
    var size: CGFloat = 12

    var body: some View {
        if case .care(let activity, _) = entry.payload {
            NativeCareLineView(line: NativeCareLine(activity: activity, state: .planned), size: size,
                dateText: entry.occurredAt.formatted(date: .abbreviated, time: .omitted))
        }
    }
}

private struct MemoryRemovalConfirmation: ViewModifier {
    @EnvironmentObject var store: ChatStore
    @Binding var memory: NativeMemoryRecord?
    var onLeave: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete this memory?",
            isPresented: Binding(get: { memory != nil }, set: { if !$0 { memory = nil } }),
            titleVisibility: .visible, presenting: memory
        ) { item in
            if let source = item.sourceConversationID, store.conversations.contains(where: { $0.id == source }) {
                Button("Open source conversation") {
                    memory = nil
                    store.openMemorySource(item)
                    onLeave()
                }
            }
            Button("Delete", role: .destructive) {
                memory = nil
                store.deleteNativeMemory(item)
                onLeave()
            }
            Button("Cancel", role: .cancel) { memory = nil }
        } message: { _ in
            Text("Vera stops using this memory now and after relaunch. The source conversation stays. Delete it separately if you want it gone too.")
        }
    }
}

extension View {
    fileprivate func memoryRemovalConfirmation(_ memory: Binding<NativeMemoryRecord?>, onLeave: @escaping () -> Void = {}) -> some View {
        modifier(MemoryRemovalConfirmation(memory: memory, onLeave: onLeave))
    }
}

private struct MemoryGroupSection: View {
    @EnvironmentObject var store: ChatStore
    let group: NativeMemoryGroup
    let items: [NativeMemoryRecord]
    let upcoming: [String: [NativeDomainEntry]]
    let upcomingSubjects: [NativeUpcomingSubject]
    let unavailableSources: Set<String>
    @Binding var selected: NativeMemoryRecord?
    @Binding var pendingRemoval: NativeMemoryRecord?
    @Binding var openedUpcoming: NativeUpcomingSubject?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.rawValue).font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("\(items.count + upcomingSubjects.count)").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("\(items.count + upcomingSubjects.count) items")
            }
            if items.isEmpty && upcomingSubjects.isEmpty {
                Text("No approved memory in this section.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 8)
            }
            if !items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(items) { memory in
                        HStack(spacing: 12) {
                            Button { selected = memory } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(memory.title).font(.system(size: 13, weight: .semibold))
                                    MemoryLineView(text: memory.summary, color: Theme.textSecondary)
                                        .lineLimit(1)
                                    ForEach(upcoming[memory.id] ?? []) { entry in
                                        UpcomingCareView(entry: entry, size: 11)
                                    }
                                    if unavailableSources.contains(memory.id) {
                                        Text("Source no longer available")
                                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens details")
                            if memory.sensitiveConsent == true {
                                Image(systemName: "lock")
                                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                    .accessibilityLabel("Contains sensitive text")
                            }
                            Text(memory.updatedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                .accessibilityLabel("Updated " + memory.updatedAt.formatted(date: .long, time: .omitted))
                            Menu {
                                Button("Open details") { selected = memory }
                                Button("Delete", role: .destructive) { pendingRemoval = memory }
                            } label: {
                                Image(systemName: "ellipsis").foregroundStyle(Theme.textSecondary)
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .accessibilityLabel("More actions for " + memory.title)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        if memory.id != items.last?.id { Divider().overlay(Theme.hairline) }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
            }
            ForEach(upcomingSubjects) { subject in
                Button { openedUpcoming = subject } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(subject.label).font(.system(size: 13, weight: .semibold))
                            Text("Upcoming").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                        ForEach(subject.entries) { entry in
                            UpcomingCareView(entry: entry, size: 11)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(subject.label + ", upcoming")
                .accessibilityHint("Shows the planned care and its source")
            }
        }
    }
}

private struct NativeUpcomingSubjectView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) var dismiss
    let subject: NativeUpcomingSubject

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(subject.label).font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Done")
            }
            Text("Nothing here is current yet. Vera starts using it when the planned date arrives.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(subject.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            UpcomingCareView(entry: entry, size: 13)
                            if let source = subject.sources.first(where: { $0.id == entry.id }) {
                                Text(source.text).font(.system(size: 12)).textSelection(.enabled)
                                Button("Open source message") {
                                    store.openMemorySource(conversationID: source.source.conversationID, messageID: source.source.messageID)
                                    dismiss()
                                }
                                .accessibilityLabel("Open source message for " + source.text.prefix(60))
                            } else {
                                Text("Original source unavailable").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(width: 560, height: 380)
    }
}

private struct MemoryProposalRow: View {
    @EnvironmentObject var store: ChatStore
    let proposal: NativeMemoryProposal
    @State private var showReview = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: proposalIcon).foregroundStyle(.orange)
                .frame(width: 30, height: 30).background(.orange.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(proposal.title).font(.system(size: 13, weight: .semibold))
                MemoryLineView(text: proposal.summary, color: Theme.textSecondary)
                Text(proposal.displayLabel).font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Dismiss") { store.dismissMemoryProposal(proposal) }
                .accessibilityLabel("Dismiss proposal " + proposal.title)
                .accessibilityHint("Approved memory does not change")
            Button("Review") { showReview = true }.buttonStyle(.borderedProminent)
                .accessibilityLabel("Review proposal " + proposal.title)
        }
        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        .sheet(isPresented: $showReview) { MemoryProposalReviewView(proposal: proposal) }
    }

    private var proposalIcon: String {
        switch proposal.kind {
        case .create: "plus"
        case .update: "pencil"
        case .merge, .consolidate: "arrow.triangle.merge"
        case .suppress: "eye.slash"
        case .expire: "calendar.badge.clock"
        case .delete, .cleanup: "trash"
        }
    }
}

private struct MemoryProposalReviewView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) var dismiss
    let proposal: NativeMemoryProposal
    @State private var details: String
    @State private var reviewError: String?
    @State private var projected: [String]?
    @State private var awaitingNotice: String?

    init(proposal: NativeMemoryProposal) {
        self.proposal = proposal
        _details = State(initialValue: proposal.details.joined(separator: "\n"))
    }

    private var targets: [NativeMemoryRecord] {
        proposal.targetIDs.compactMap { id in store.memoryRecords.first { $0.id == id } }
    }

    private var domainCurrent: NativeMemoryRecord? {
        guard let domain = proposal.domain else { return nil }
        return store.memoryRecords.first {
            $0.domainEntityID == domain.entry.entityID && $0.bank == domain.entry.scope && $0.status == .approved
        }
    }

    private var affected: [NativeMemoryRecord] {
        proposal.domain == nil ? targets : (domainCurrent.map { [$0] } ?? [])
    }

    private var before: [NativeMemoryRecord] {
        if proposal.domain != nil { return affected }
        return [.update, .merge].contains(proposal.kind) ? targets : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(proposal.title).font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(proposal.displayLabel)
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.orange.opacity(0.12), in: Capsule())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close review")
                    .accessibilityHint("Closes without accepting or dismissing")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MemoryLineView(text: proposal.summary, size: 13, color: Theme.textSecondary)
                    if !affected.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(affected.count == 1 ? "Affects this memory" : "Affects these memories")
                                .font(.system(size: 12, weight: .semibold))
                            ForEach(affected) { record in
                                Label(record.title, systemImage: "tray.full")
                                    .font(.system(size: 12))
                            }
                        }
                    }
                    if !before.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Before").font(.system(size: 12, weight: .semibold))
                            ForEach(before) { record in
                                VStack(alignment: .leading, spacing: 4) {
                                    if before.count > 1 {
                                        Text(record.title).font(.system(size: 12, weight: .semibold))
                                    }
                                    if proposal.domain == nil {
                                        MemoryLineView(text: record.summary, size: 12, color: Theme.textSecondary)
                                    }
                                    ForEach(Array(record.details.enumerated()), id: \.offset) { _, line in
                                        MemoryLineView(text: line, size: 12)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    if let domain = proposal.domain {
                        Text("After").font(.system(size: 12, weight: .semibold))
                        VStack(alignment: .leading, spacing: 4) {
                            if let projected, !projected.isEmpty {
                                ForEach(Array(projected.enumerated()), id: \.offset) { _, line in
                                    MemoryLineView(text: line, size: 13).textSelection(.enabled)
                                }
                            } else if projected != nil {
                                Text(domain.entry.occurredAt > Date()
                                     ? "Takes effect on " + domain.entry.occurredAt.formatted(date: .long, time: .shortened)
                                     : "Nothing current is established yet")
                                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        if let awaitingNotice {
                            Text(awaitingNotice).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                        Text("Evidence being added").font(.system(size: 12, weight: .semibold))
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(proposal.details.enumerated()), id: \.offset) { _, line in
                                MemoryLineView(text: line, size: 12, color: Theme.textSecondary).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text(before.isEmpty ? "Proposed details" : "After").font(.system(size: 12, weight: .semibold))
                        TextEditor(text: $details).font(.system(size: 13)).frame(minHeight: 160)
                            .padding(6).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Proposed details")
                            .accessibilityHint("Edit the details before accepting. Each line is one detail.")
                    }
                }
            }
            if let reviewError { Text(reviewError).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                if let source = proposal.sourceConversationID {
                    Button("Open source conversation") {
                        store.openMemorySource(conversationID: source, messageID: proposal.sourceMessageID)
                        dismiss()
                    }
                    .accessibilityLabel("Open source conversation")
                } else {
                    Text("Requested in Memory")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Dismiss") { store.dismissMemoryProposal(proposal); dismiss() }
                    .accessibilityLabel("Dismiss proposal")
                    .accessibilityHint("Approved memory does not change")
                Button(proposal.domain == nil ? "Accept edited proposal" : "Accept record") {
                    if store.acceptMemoryProposal(proposal,
                        editedDetails: proposal.domain == nil ? details.split(whereSeparator: \.isNewline).map(String.init) : nil) {
                        dismiss()
                    } else if case .failed(let reason) = store.memoryServiceState { reviewError = reason }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(proposal.domain == nil ? nil : .defaultAction)
                .accessibilityLabel(proposal.domain == nil ? "Accept edited proposal" : "Accept record")
                .accessibilityHint("Applies this change to approved memory")
            }
        }
        .padding(24).frame(width: 640, height: 600)
        .task {
            guard proposal.domain != nil, let repository = store.repository as? LocalChatRepository else { return }
            let preview = repository.domainReviewPreview(proposal)
            projected = preview.after
            awaitingNotice = preview.notice
            if let error = preview.error { reviewError = error }
        }
    }
}

struct MemoryDetailView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) var dismiss
    let memory: NativeMemoryRecord
    let citedRevision: Int?
    var trace: NativeMemoryRetrievalTrace? = nil
    @State private var title: String
    @State private var summary: String
    @State private var details: String
    @State private var pendingRemoval: NativeMemoryRecord?
    @State private var evidence: [NativeMemoryEvidence] = []
    @State private var evidenceError: String?
    @State private var saveError: String?
    @State private var upcoming: [NativeDomainEntry] = []
    @State private var correcting = false

    init(memory: NativeMemoryRecord, citedRevision: Int? = nil, trace: NativeMemoryRetrievalTrace? = nil) {
        self.memory = memory
        self.citedRevision = citedRevision
        self.trace = trace
        _title = State(initialValue: memory.title)
        _summary = State(initialValue: memory.summary)
        _details = State(initialValue: memory.details.joined(separator: "\n"))
    }

    private var durability: String {
        guard let expiry = memory.expiry else { return "Kept until removed" }
        let date = expiry.formatted(date: .long, time: .omitted)
        return expiry > Date() ? "Expires on " + date : "Expired on " + date
    }

    private var correction: NativeDomainRecordPrefill {
        NativeDomainRecordPrefill(memoryID: memory.id, replaces: NativeDomainRecordPrefill.latest(evidence.first?.domainSources ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Memory detail").font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Done")
                    .accessibilityHint("Closes without saving")
            }
            if let citedRevision, evidence.first?.revision != citedRevision, !evidence.isEmpty {
                Text("This memory has changed since the answer. Saving edits the current memory.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Label(durability, systemImage: memory.expiry == nil ? "infinity" : "calendar.badge.clock")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if memory.sensitiveConsent == true {
                Label("Contains sensitive text", systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            if let trace, !trace.entry(for: memory.id).isEmpty {
                MemoryRecallTraceView(trace: trace, memoryID: memory.id)
            }
            TextField("Name", text: $title).textFieldStyle(.roundedBorder).disabled(memory.domainEntityID != nil)
                .accessibilityLabel("Name")
            TextField("Summary", text: $summary).textFieldStyle(.roundedBorder).disabled(memory.domainEntityID != nil)
                .accessibilityLabel("Summary")
            Text("Details").font(.system(size: 12, weight: .semibold))
            if memory.domainEntityID != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(memory.details.enumerated()), id: \.offset) { _, line in
                            MemoryLineView(text: line, size: 13)
                        }
                        ForEach(upcoming) { entry in
                            UpcomingCareView(entry: entry, size: 13)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(minHeight: 120)
                .padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                Text("Calculated from approved evidence. Use Correct to propose a change for review.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            } else {
                TextEditor(text: $details).font(.system(size: 13)).frame(minHeight: 180)
                    .padding(6).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Details")
                    .accessibilityHint("Each line is one detail")
            }
            if let saveError {
                Text(saveError).font(.system(size: 12)).foregroundStyle(.red)
            }
            if let evidenceError {
                Text(evidenceError).font(.system(size: 12)).foregroundStyle(.red)
            }
            if !evidence.isEmpty {
                DisclosureGroup("Sources and saved changes") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(evidence.enumerated()), id: \.element.id) { index, item in
                                evidenceRow(item, current: index == 0)
                            }
                        }
                    }.frame(maxHeight: 150)
                }
                .accessibilityLabel("Sources and saved changes")
            }
            HStack {
                if memory.sourceConversationID != nil {
                    Button("Open source conversation") {
                        store.openMemorySource(memory)
                        dismiss()
                    }
                    .accessibilityLabel("Open source conversation")
                } else {
                    Text("Created in Memory")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Delete", role: .destructive) { pendingRemoval = memory }
                    .accessibilityLabel("Delete memory")
                    .accessibilityHint("Asks for confirmation before Vera stops using this memory")
                if memory.domainEntityID != nil {
                    Button("Correct") { correcting = true }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(evidence.isEmpty)
                        .accessibilityLabel("Correct")
                        .accessibilityHint("Proposes a correction for review, with the current value filled in")
                } else {
                    Button("Save") {
                        if store.editNativeMemory(
                            memory, title: title, summary: summary,
                            details: details.split(whereSeparator: \.isNewline).map(String.init)) {
                            dismiss()
                        } else if case .failed(let detail) = store.memoryServiceState {
                            saveError = detail
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Save changes")
                }
            }
        }
        .padding(24).frame(width: 620, height: 660)
        .task {
            do { evidence = try store.memoryEvidence(memory.id) }
            catch { evidenceError = "Saved sources could not be opened. \(error.localizedDescription)" }
            if memory.domainEntityID != nil, let repository = store.repository as? LocalChatRepository {
                upcoming = ((try? repository.upcomingDomainCare()) ?? [:])[memory.id] ?? []
            }
        }
        .sheet(isPresented: $correcting) { NativeDomainRecordView(prefill: correction) }
        .memoryRemovalConfirmation($pendingRemoval) { dismiss() }
    }

    private func evidenceRow(_ item: NativeMemoryEvidence, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(current ? "Current" : "Earlier version")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(current ? Theme.accent : Theme.textSecondary)
                Text(item.record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                if item.revision == citedRevision {
                    Text("Used in this answer").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            .accessibilityElement(children: .combine)
            MemoryLineView(text: item.record.summary, size: 12).fontWeight(.medium)
            ForEach(item.domainSources) { source in
                VStack(alignment: .leading, spacing: 3) {
                    if source.superseded {
                        Label(source.supersededAt.map { "Superseded on " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Superseded",
                              systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    Text(source.text).font(.system(size: 12)).textSelection(.enabled)
                        .foregroundStyle(source.superseded ? Theme.textSecondary : Theme.textPrimary)
                    Button("Open source conversation") {
                        store.openMemorySource(conversationID: source.source.conversationID, messageID: source.source.messageID)
                        dismiss()
                    }
                        .accessibilityLabel("Open source conversation for " + source.text.prefix(60))
                }
            }
            if item.domainSources.isEmpty {
                if let text = item.sourceText {
                    Text(text).font(.system(size: 12)).textSelection(.enabled)
                    if let conversation = item.record.sourceConversationID {
                        Button("Open source message") {
                            store.openMemorySource(conversationID: conversation, messageID: item.record.sourceMessageID, expectedText: text)
                            dismiss()
                        }
                        .accessibilityLabel(current ? "Open source message" : "Open source message for this earlier version")
                    }
                } else {
                    Text(item.record.sourceConversationID == nil ? "Saved in Memory" : "Original source unavailable")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

struct NativeMemoryShotSurface: View {
    let variant: String
    private let rows = NativeMemoryRecord.shotLibrary

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { VeraMark(size: 20); Text("Vera").font(.system(size: 15, weight: .semibold)) }
                Label("Pulse", systemImage: "newspaper")
                Label("Memory", systemImage: "tray.full").foregroundStyle(Theme.accent)
                Divider().overlay(Theme.hairline)
                Text("CHATS").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textSecondary)
                Text("New chat").font(.system(size: 12))
                Spacer()
            }
            .padding(18).frame(width: 238).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.sidebar)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ZStack {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Memory").font(.system(size: 25, weight: .bold))
                            Text("A local, reviewable library of what Vera may remember about you.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text("\(rows.count) approved").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Theme.surface, in: Capsule())
                    }
                    stateCard
                    if variant == "memory-change" { changeCard }
                    if ["memory-review", "memory-duplicate", "memory-expiry"].contains(variant) { proposalCard }
                    library
                    Spacer()
                }
                .padding(26)
                .blur(radius: overlayVariant ? 1.5 : 0)
                if overlayVariant { Color.black.opacity(0.34) }
                overlay
            }
            .background(Theme.bg)
        }
        .foregroundStyle(Theme.textPrimary)
    }

    private var stateCard: some View {
        let state: (String, String, String, Color) = switch variant {
        case "memory-off": ("Memory is off", "Nothing is retrieved, generated, maintained, or added to chat.", "pause.circle.fill", Theme.accent)
        case "memory-setup": ("Set up embeddings to use memory in chat", "Ordinary chat still works without memory context.", "gearshape.fill", Theme.accent)
        case "memory-unavailable": ("Memory recall is unavailable", "The embeddings endpoint could not be reached. Ordinary chat continues.", "exclamationmark.triangle.fill", .red)
        default: ("Ready", "Only approved, relevant, unexpired items can be added to native chat requests.", "checkmark.circle.fill", .green)
        }
        return HStack(spacing: 10) {
            Image(systemName: state.2).foregroundStyle(state.3)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.0).font(.system(size: 12, weight: .semibold))
                Text(state.1).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text("Memory settings").font(.system(size: 11)).foregroundStyle(Theme.accent)
        }
        .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private var changeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask Memory to change").font(.system(size: 13, weight: .semibold))
            HStack {
                Text("Remember that I prefer morning meetings")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                Text("Create proposal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            Text("This request becomes a reviewable proposal. It does not write approved memory.")
                .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
        }
        .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var proposalCard: some View {
        let content: (String, String, String) = switch variant {
        case "memory-duplicate": ("Review similar memory", "A similar response preference already exists.", "Merge")
        case "memory-expiry": ("Conference plan expired", "This episodic item stopped appearing in recall on Aug 1, 2026.", "Delete")
        default: ("Meeting preference", "Prefers morning meetings when possible.", "Accept")
        }
        return HStack {
            Image(systemName: "tray.full.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.0).font(.system(size: 12, weight: .semibold))
                Text(content.1).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text("Dismiss").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            Text(content.2).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
        }
        .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.35)))
    }

    private var library: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(NativeMemoryGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 7) {
                    Text(group.rawValue).font(.system(size: 13, weight: .semibold))
                    ForEach(rows.filter { $0.libraryGroup == group }) { memory in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(memory.title).font(.system(size: 11, weight: .semibold))
                            MemoryLineView(text: memory.summary, size: 10, color: Theme.textSecondary)
                                .lineLimit(2)
                            ForEach(Array(memory.details.dropFirst().enumerated()), id: \.offset) { _, line in
                                MemoryLineView(text: line, size: 10, color: Theme.textSecondary).lineLimit(1)
                            }
                            Text(memory.updatedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 9)).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(10).frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
                    }
                }.frame(maxWidth: .infinity)
            }
        }
    }

    private var overlayVariant: Bool {
        ["memory-detail", "memory-clear"].contains(variant)
    }

    @ViewBuilder private var overlay: some View {
        switch variant {
        case "memory-detail":
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Response style").font(.system(size: 18, weight: .semibold)); Spacer(); Text("Done").foregroundStyle(Theme.accent) }
                Text("Prefers direct practical answers").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                Label("Kept until removed", systemImage: "infinity").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Text("Details").font(.system(size: 11, weight: .semibold))
                Text("Prefers direct practical answers with clear tradeoffs")
                    .font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                HStack { Text("Open source conversation").font(.system(size: 10)).foregroundStyle(Theme.accent); Spacer(); Text("Delete").foregroundStyle(.red); Text("Save").foregroundStyle(Theme.accent) }
            }.padding(22).frame(width: 560).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        case "memory-clear":
            VStack(alignment: .leading, spacing: 14) {
                Text("Clear all approved memory?").font(.system(size: 18, weight: .semibold))
                Text("This removes approved memory from later chat requests. Conversation history is not changed.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                HStack { Spacer(); Text("Cancel"); Text("Clear approved memory").foregroundStyle(.red) }
            }.padding(22).frame(width: 500).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        default: EmptyView()
        }
    }
}

struct MemoryRecallTraceView: View {
    let trace: NativeMemoryRetrievalTrace
    let memoryID: String
    @State private var expanded = false

    private var lines: [String] {
        trace.entry(for: memoryID).map { entry in
            "\(entry.source): rank \(entry.rank), score \(String(format: "%.3f", entry.score))"
        } + [trace.rerankNote]
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Why it was recalled", systemImage: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }
}
