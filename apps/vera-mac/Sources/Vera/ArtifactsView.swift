import SwiftUI
import AppKit
import MarkdownUI

extension ArtifactKind {
    var label: String {
        switch self {
        case .document: return "Document"
        case .image: return "Image"
        case .fileChange: return "File change"
        case .canvas: return "Canvas"
        }
    }

    var symbol: String {
        switch self {
        case .document: return "doc.text"
        case .image: return "photo"
        case .fileChange: return "doc.badge.ellipsis"
        case .canvas: return "rectangle.and.pencil.and.ellipsis"
        }
    }
}

enum ArtifactKindFilter: CaseIterable, Identifiable, Hashable {
    case all, document, image, fileChange, canvas

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "All"
        case .document: return "Documents"
        case .image: return "Images"
        case .fileChange: return "File changes"
        case .canvas: return "Canvas"
        }
    }

    func matches(_ kind: ArtifactKind) -> Bool {
        switch self {
        case .all: return true
        case .document: return kind == .document
        case .image: return kind == .image
        case .fileChange: return kind == .fileChange
        case .canvas: return kind == .canvas
        }
    }
}

enum ArtifactDateLabel {
    static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = Date.FormatStyle(date: .omitted, time: .omitted).month(.abbreviated).day()
        return sameYear ? date.formatted(style) : date.formatted(style.year())
    }

    static func origin(_ record: ArtifactRecord) -> String {
        let title = record.originTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "No conversation" : title
    }
}

struct ArtifactLibrarySelection: Equatable {
    var selectedID: String?
    var search = ""
    var filter: ArtifactKindFilter = .all
    var conversationFilter: String?

    func visible(_ records: [ArtifactRecord]) -> [ArtifactRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            guard filter.matches(record.kind) else { return false }
            if let conversationFilter, record.conversationID != conversationFilter { return false }
            guard !query.isEmpty else { return true }
            return record.title.localizedCaseInsensitiveContains(query)
                || (record.originTitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func selected(in records: [ArtifactRecord]) -> ArtifactRecord? {
        guard let selectedID else { return nil }
        return visible(records).first { $0.id == selectedID }
    }

    func resolved(in records: [ArtifactRecord]) -> ArtifactRecord? {
        var settled = self
        settled.reconcile(records)
        return settled.selected(in: records)
    }

    mutating func reconcile(_ records: [ArtifactRecord]) {
        let shown = visible(records)
        if let selectedID, shown.contains(where: { $0.id == selectedID }) { return }
        selectedID = shown.first?.id
    }

    mutating func open(_ id: String, in records: [ArtifactRecord]) -> Bool {
        guard let record = records.first(where: { $0.id == id }) else {
            reconcile(records)
            return false
        }
        search = ""
        if !filter.matches(record.kind) { filter = .all }
        if let conversationFilter, record.conversationID != conversationFilter { self.conversationFilter = nil }
        selectedID = record.id
        return true
    }

    mutating func adoptConversation(_ id: String, in records: [ArtifactRecord]) {
        conversationFilter = id
        search = ""
        filter = .all
        reconcile(records)
    }

    mutating func apply(conversation: String?, open id: String?, in records: [ArtifactRecord]) {
        if let conversation { adoptConversation(conversation, in: records) }
        if let id { _ = open(id, in: records) }
    }

    static func companionFilterTitle(name: String?) -> String {
        "From \(name ?? "your companion")"
    }

    static func companionOriginLabel(name: String?) -> String {
        name ?? "Your companion"
    }
}

extension ChatStore {
    func artifactOriginLabel(_ record: ArtifactRecord) -> String {
        if let id = record.conversationID, isVeraThread(id) {
            return ArtifactLibrarySelection.companionOriginLabel(name: companionName)
        }
        return ArtifactDateLabel.origin(record)
    }
}

struct ArtifactsView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.renderSafe) private var renderSafe
    @State private var state: ArtifactLibrarySelection
    @State private var exportNotice: ArtifactExportNotice?
    @State private var noticeDismissal: Task<Void, Never>?

    init(initialSelection: String? = nil, conversationFilter: String? = nil,
         initialFilter: ArtifactKindFilter = .all, initialSearch: String = "",
         initialExportNotice: ArtifactExportNotice? = nil) {
        _state = State(initialValue: ArtifactLibrarySelection(
            selectedID: initialSelection, search: initialSearch, filter: initialFilter,
            conversationFilter: conversationFilter))
        _exportNotice = State(initialValue: initialExportNotice)
    }

    private var conversationFilterTitle: String? {
        guard let conversationFilter = state.conversationFilter else { return nil }
        if store.isVeraThread(conversationFilter) {
            return ArtifactLibrarySelection.companionFilterTitle(name: store.companionName)
        }
        return store.conversations.first { $0.id == conversationFilter }.map { "From \($0.title)" }
    }

    private var filtered: [ArtifactRecord] {
        state.visible(store.artifactRecords)
    }

    private var selected: ArtifactRecord? {
        state.resolved(in: store.artifactRecords)
    }

    var body: some View {
        Group {
            if store.artifactRecords.isEmpty {
                DestinationPlaceholder(section: .artifacts)
            } else {
                HStack(spacing: 0) {
                    listColumn.frame(width: 300)
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    detailColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .onAppear {
            if !renderSafe { store.reloadArtifacts() }
            consumeRequests()
            state.reconcile(store.artifactRecords)
        }
        .onChange(of: store.requestedArtifactID) { _, _ in consumeRequests() }
        .onChange(of: store.pendingLibraryConversationID) { _, _ in consumeRequests() }
        .onChange(of: state.search) { _, _ in state.reconcile(store.artifactRecords) }
        .onChange(of: state.filter) { _, _ in state.reconcile(store.artifactRecords) }
        .onChange(of: state.conversationFilter) { _, _ in state.reconcile(store.artifactRecords) }
        .onChange(of: store.artifactRecords) { _, records in state.reconcile(records) }
    }

    private func consumeRequests() {
        let conversation = store.pendingLibraryConversationID
        let id = store.requestedArtifactID
        guard conversation != nil || id != nil else { return }
        store.pendingLibraryConversationID = nil
        store.requestedArtifactID = nil
        state.apply(conversation: conversation, open: id, in: store.artifactRecords)
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            ArtifactFlowLayout(spacing: 6) {
                ForEach(ArtifactKindFilter.allCases) { option in
                    ArtifactFilterPill(title: option.title, selected: option == state.filter) { state.filter = option }
                }
            }
            if let title = conversationFilterTitle {
                Button {
                    state.conversationFilter = nil
                } label: {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 12, weight: .medium))
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.surfaceSelected))
                }
                .buttonStyle(.plain)
                .help("Showing only results from this conversation")
                .accessibilityLabel("\(title). Clear filter")
            }
            if filtered.isEmpty {
                Spacer(minLength: 0)
            } else {
                ShotSafeScroll(renderSafe: renderSafe) {
                    VStack(spacing: 2) {
                        ForEach(filtered) { record in
                            ArtifactRow(record: record, origin: store.artifactOriginLabel(record),
                                        selected: record.id == selected?.id)
                                .contentShape(Rectangle())
                                .onTapGesture { state.selectedID = record.id }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { state.selectedID = record.id }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if renderSafe {
                Text(state.search.isEmpty ? "Search your Library" : state.search).font(.system(size: 13))
                    .foregroundStyle(state.search.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                Spacer(minLength: 0)
            } else {
                TextField("Search your Library", text: $state.search).textFieldStyle(.plain).font(.system(size: 13))
                    .accessibilityLabel("Search your Library")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            if let exportNotice {
                ArtifactExportStrip(
                    notice: exportNotice, renderSafe: renderSafe,
                    chooseAnother: { chooseAnotherLocation() }, dismiss: { dismissNotice() })
            }
            if let selected {
                ArtifactDetail(record: selected, onSaveAs: beginExport).id(selected.id)
            } else {
                Text("Nothing matches your search or filters.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var exportFlow: ArtifactExportFlow {
        let store = store
        return ArtifactExportFlow(
            exporter: ArtifactExporter(read: { store.artifactSource($0) }),
            choose: { fileName, directory in Self.chooseDestination(fileName: fileName, directory: directory) })
    }

    private static func chooseDestination(fileName: String, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func beginExport(_ record: ArtifactRecord, _ version: ArtifactVersion, _ fileName: String) {
        guard let notice = exportFlow.begin(record, version: version, fileName: fileName) else { return }
        show(notice)
    }

    private func chooseAnotherLocation() {
        guard let attempt = exportNotice?.attempt,
              let notice = exportFlow.chooseAnother(attempt) else { return }
        show(notice)
    }

    private func dismissNotice() {
        noticeDismissal?.cancel()
        noticeDismissal = nil
        exportNotice = nil
    }

    private func show(_ notice: ArtifactExportNotice) {
        noticeDismissal?.cancel()
        noticeDismissal = nil
        exportNotice = notice
        guard !renderSafe else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: notice.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        guard notice.isSaved else { return }
        noticeDismissal = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, exportNotice == notice else { return }
            exportNotice = nil
            noticeDismissal = nil
        }
    }
}

private struct ArtifactExportStrip: View {
    let notice: ArtifactExportNotice
    let renderSafe: Bool
    let chooseAnother: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: notice.isSaved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(notice.isSaved ? Theme.accent : Color.orange)
                    .accessibilityHidden(true)
                Text(notice.message).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !notice.isSaved { controls.fixedSize() }
            }
            .padding(.horizontal, 24).padding(.vertical, 9)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .background(Theme.surface)
        .accessibilityElement(children: .contain)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if notice.canChooseLocation { control("Save somewhere else…", action: chooseAnother) }
            if renderSafe {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            } else {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
    }

    @ViewBuilder
    private func control(_ title: String, action: @escaping () -> Void) -> some View {
        if renderSafe {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.accent)
        } else {
            Button(title, action: action)
                .buttonStyle(.borderless).font(.system(size: 12))
                .accessibilityLabel(title)
        }
    }
}

private struct ArtifactFilterPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(selected ? Theme.surfaceSelected : Theme.surface)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(title.lowercased())")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct ArtifactRow: View {
    let record: ArtifactRecord
    let origin: String
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.kind.symbol).font(.system(size: 13)).foregroundStyle(Theme.accent)
                .frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(origin) · \(ArtifactDateLabel.text(record.updatedAt))")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Theme.surfaceSelected : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.kind.label), \(record.title)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct ArtifactDetail: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.renderSafe) private var renderSafe
    let record: ArtifactRecord
    let onSaveAs: (ArtifactRecord, ArtifactVersion, String) -> Void
    @State private var chosenVersionID: String?
    @State private var revising = false

    var body: some View {
        let versions = store.artifactVersions(record.id)
        let version = versions.first { $0.id == chosenVersionID } ?? versions.last
        VStack(alignment: .leading, spacing: 0) {
            header(versions: versions, version: version)
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let version {
                ShotSafeScroll(renderSafe: renderSafe) {
                    ArtifactContent(record: record, version: version)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("This item has no saved versions.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $revising) {
            ArtifactReviseSheet { change in store.reviseArtifact(record, change: change) }
        }
    }

    private func header(versions: [ArtifactVersion], version: ArtifactVersion?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                        .textSelection(.enabled)
                    Text("\(record.kind.label) · \(store.artifactOriginLabel(record)) · \(ArtifactDateLabel.text(version?.createdAt ?? record.updatedAt))")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if versions.count > 1, let version {
                    versionPicker(versions: versions, current: version)
                }
            }
            if let version { actions(version: version) }
        }
    }

    @ViewBuilder
    private func versionPicker(versions: [ArtifactVersion], current: ArtifactVersion) -> some View {
        let label = "Version \(current.ordinal) of \(versions.count)"
        if renderSafe {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .foregroundStyle(Theme.textSecondary)
        } else {
            Menu {
                ForEach(versions.reversed()) { item in
                    Button {
                        chosenVersionID = item.id
                    } label: {
                        if item.id == current.id {
                            Label("Version \(item.ordinal)", systemImage: "checkmark")
                        } else {
                            Text("Version \(item.ordinal)")
                        }
                    }
                }
            } label: {
                Text(label).font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Version")
            .accessibilityValue(label)
        }
    }

    private struct ActionItem: Identifiable {
        let id: String
        let symbol: String
        let run: () -> Void
    }

    private func actionItems(version: ArtifactVersion) -> [ActionItem] {
        var items: [ActionItem] = []
        if store.artifactConversationExists(record) {
            items.append(ActionItem(id: "Open in conversation", symbol: "bubble.left.and.text.bubble.right") {
                store.openArtifactConversation(record)
            })
            items.append(ActionItem(id: "Revise", symbol: "pencil") { revising = true })
        }
        let contentKept = record.kind != .fileChange || version.details.contentAvailable
        if contentKept {
            items.append(ActionItem(id: "Save as…", symbol: "square.and.arrow.down") { onSaveAs(record, version, suggestedName(version)) })
        }
        if let reveal = revealURL(version) {
            items.append(ActionItem(id: "Reveal in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([reveal])
            })
        }
        if contentKept {
            items.append(ActionItem(id: "Copy", symbol: "doc.on.doc") { copy(version) })
        }
        return items
    }

    private func actions(version: ArtifactVersion) -> some View {
        let items = actionItems(version: version)
        return HStack(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if renderSafe {
                    if index == 0 {
                        Text(item.id).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Label(item.id, systemImage: item.symbol).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                } else if index == 0 {
                    Button(item.id, action: item.run)
                        .buttonStyle(.borderedProminent).controlSize(.small).font(.system(size: 12))
                        .accessibilityLabel(item.id)
                } else {
                    Button(action: item.run) { Label(item.id, systemImage: item.symbol) }
                        .buttonStyle(.borderless).font(.system(size: 12))
                        .accessibilityLabel(item.id)
                }
            }
        }
    }

    private func revealURL(_ version: ArtifactVersion) -> URL? {
        switch record.kind {
        case .image:
            return store.artifactFileURL(version)
        case .fileChange:
            let details = version.details
            let candidates = details.changeKind == .trashed
                ? [details.movedFrom, details.filePath] : [details.filePath, details.movedFrom]
            guard let path = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                return nil
            }
            return URL(fileURLWithPath: path)
        case .document, .canvas:
            return nil
        }
    }

    private func suggestedName(_ version: ArtifactVersion) -> String {
        if record.kind == .fileChange, let path = version.details.filePath {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty { return name }
        }
        let ext = URL(fileURLWithPath: version.fileName).pathExtension
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = record.title.components(separatedBy: disallowed).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
        let base = String(cleaned.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let stem = base.isEmpty ? record.kind.label : base
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    private func copy(_ version: ArtifactVersion) {
        let pasteboard = NSPasteboard.general
        switch record.kind {
        case .image:
            guard let data = store.artifactData(version), let image = NSImage(data: data) else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        case .document, .canvas, .fileChange:
            guard let text = store.artifactText(version) else { return }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}

private struct ArtifactContent: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.renderSafe) private var renderSafe
    let record: ArtifactRecord
    let version: ArtifactVersion

    var body: some View {
        switch record.kind {
        case .document: document
        case .canvas: canvas
        case .image: image
        case .fileChange: ArtifactFileChangeContent(version: version, text: store.artifactText(version) ?? "")
        }
    }

    private var missing: some View {
        Text("This item is no longer on disk.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder
    private var document: some View {
        if let text = store.artifactText(version) {
            VStack(alignment: .leading, spacing: 18) {
                if version.details.sources.isEmpty {
                    NativeArtifactMarkdown(text: text).equatable()
                } else {
                    let sources = NativeResearchReportSafety.sources(version.details.sources)
                    CitedProse(text: PulseMarkers.stripSourcesSection(text), sources: sources)
                    SourcesRow(sources: sources)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .markdownImageProvider(NativeResearchImageProvider())
            .markdownInlineImageProvider(NativeResearchInlineImageProvider())
            .environment(\.openURL, OpenURLAction { url in
                NativeResearchReportSafety.destination(url.absoluteString) == nil ? .discarded : .systemAction
            })
        } else {
            missing
        }
    }

    @ViewBuilder
    private var canvas: some View {
        if let text = store.artifactText(version) {
            let artifact = Artifact(id: version.id, title: record.title, type: version.details.canvasType ?? .markdown,
                                    language: version.details.language ?? "", content: text)
            if renderSafe && artifact.type == .markdown {
                NativeArtifactMarkdown(text: text).equatable()
            } else {
                ArtifactPreview(artifact: artifact)
                    .frame(minHeight: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
            }
        } else {
            missing
        }
    }

    @ViewBuilder
    private var image: some View {
        if let data = store.artifactData(version), let picture = NSImage(data: data) {
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: min(picture.size.width, 640), alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
                .accessibilityLabel(version.details.prompt ?? record.title)
        } else {
            Text("This image is no longer on disk.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct ArtifactDiffCell: Hashable {
    enum Tone { case same, removed, added }
    let text: String
    let tone: Tone
}

private struct ArtifactDiffRow: Identifiable {
    let id: Int
    let left: ArtifactDiffCell?
    let right: ArtifactDiffCell?
    let gap: Bool
}

private struct ArtifactFileChangeContent: View {
    let version: ArtifactVersion
    let text: String

    private var details: ArtifactDetails { version.details }
    private var kind: NativeFileChangeKind { details.changeKind ?? .edited }

    private var change: NativeFileChange {
        NativeFileChange(path: details.filePath ?? version.fileName, kind: kind, movedFrom: details.movedFrom)
    }

    private var sides: (before: String, after: String) {
        switch kind {
        case .created: return ("", text)
        case .trashed: return (details.beforeText ?? text, "")
        case .edited: return (details.beforeText ?? "", text)
        case .moved, .directory: return ("", "")
        }
    }

    private var rows: [ArtifactDiffRow] {
        let (before, after) = sides
        guard before != after else { return [] }
        var rows: [ArtifactDiffRow] = []
        for hunk in NativeLineDiff.hunks(before: before, after: after) {
            if hunk.id > 0 { rows.append(ArtifactDiffRow(id: rows.count, left: nil, right: nil, gap: true)) }
            var removed: [String] = []
            var added: [String] = []
            func flush() {
                for index in 0..<max(removed.count, added.count) {
                    rows.append(ArtifactDiffRow(
                        id: rows.count,
                        left: index < removed.count ? ArtifactDiffCell(text: removed[index], tone: .removed) : nil,
                        right: index < added.count ? ArtifactDiffCell(text: added[index], tone: .added) : nil,
                        gap: false))
                }
                removed.removeAll()
                added.removeAll()
            }
            for line in hunk.lines {
                switch line {
                case .same(let value):
                    flush()
                    let cell = ArtifactDiffCell(text: value, tone: .same)
                    rows.append(ArtifactDiffRow(id: rows.count, left: cell, right: cell, gap: false))
                case .removed(let value): removed.append(value)
                case .added(let value): added.append(value)
                }
            }
            flush()
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(change.title).font(.system(size: 14, weight: .medium))
                if let path = details.filePath {
                    Text(path).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                }
                if let movedFrom = details.movedFrom, kind == .moved {
                    Text("from \(movedFrom)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            if !details.contentAvailable {
                Text("The file's contents weren't kept.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            } else {
                if details.truncated {
                    Text("This change was too large to keep in full.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                let rows = rows
                if !rows.isEmpty { diff(rows) }
            }
        }
    }

    private func diff(_ rows: [ArtifactDiffRow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                columnTitle("Before")
                Rectangle().fill(Theme.hairline).frame(width: 1)
                columnTitle("After")
            }
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ForEach(rows) { row in
                HStack(spacing: 0) {
                    cell(row.left, gap: row.gap)
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    cell(row.right, gap: row.gap)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes to \(change.name)")
    }

    private func columnTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func cell(_ cell: ArtifactDiffCell?, gap: Bool) -> some View {
        let tone = cell?.tone ?? .same
        let color: Color = tone == .removed ? .red : (tone == .added ? .green : Theme.textSecondary)
        let fill: Color = tone == .removed ? Color.red.opacity(0.08) : (tone == .added ? Color.green.opacity(0.08) : .clear)
        return Text(gap ? "…" : (cell?.text ?? ""))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(gap ? Theme.textSecondary : color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12).padding(.vertical, 1)
            .background(cell == nil ? Color.clear : fill)
            .textSelection(.enabled)
    }
}

private struct ArtifactReviseSheet: View {
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var change = ""

    private var trimmed: String { change.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should change?").font(.system(size: 15, weight: .semibold))
            TextField("Describe the change", text: $change, axis: .vertical)
                .lineLimit(4...10)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("What should change")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send") {
                    onSend(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct ArtifactFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
