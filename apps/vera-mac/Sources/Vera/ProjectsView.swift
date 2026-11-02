import SwiftUI
import AppKit

enum ProjectDateLabel {
    static func text(_ date: Date, now: Date = Date()) -> String {
        let label = ArtifactDateLabel.text(date, now: now)
        return label == "Today" || label == "Yesterday" ? label.lowercased() : label
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct ProjectsView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.renderSafe) private var renderSafe
    @State private var selectedID: String?
    @State private var creating = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    init(initialSelection: String? = nil) {
        _selectedID = State(initialValue: initialSelection)
    }

    private var selected: ProjectRecord? {
        store.projects.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn.frame(width: 300)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            detailColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .onAppear {
            guard !renderSafe else { return }
            store.reloadProjects()
            store.reloadArtifacts()
        }
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if creating && !renderSafe {
                nameField
            } else {
                newProjectButton
            }
            ShotSafeScroll(renderSafe: renderSafe) {
                VStack(spacing: 2) {
                    ForEach(store.projects) { project in
                        ProjectRow(project: project, chats: store.projectConversations(project.id).count,
                                   selected: project.id == selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedID = project.id }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { selectedID = project.id }
                    }
                }
                .padding(.bottom, 12)
            }
            .modifier(ProjectTopAnchored())
        }
        .padding(.horizontal, 12).padding(.top, 20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var newProjectButton: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
            Text("New project").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
        if renderSafe {
            label
        } else {
            Button {
                newName = ""
                creating = true
                nameFocused = true
            } label: { label.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel("New project")
        }
    }

    private var nameField: some View {
        HStack(spacing: 6) {
            Image(systemName: AppSection.projects.icon).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextField("Project name", text: $newName)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($nameFocused)
                .onSubmit(create)
                .onExitCommand { creating = false }
                .accessibilityLabel("Project name")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, lineWidth: 1))
        .onChange(of: nameFocused) { _, focused in
            if !focused && newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { creating = false }
        }
    }

    private func create() {
        if let project = store.createProject(name: newName) { selectedID = project.id }
        newName = ""
        creating = false
    }

    @ViewBuilder
    private var detailColumn: some View {
        if store.projects.isEmpty {
            DestinationPlaceholder(section: .projects)
        } else if let selected {
            ProjectDetail(project: selected) { selectedID = nil }.id(selected.id)
        } else {
            Text("Select a project").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectRecord
    let chats: Int
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: AppSection.projects.icon).font(.system(size: 13)).foregroundStyle(Theme.accent)
                .frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(chats) \(chats == 1 ? "chat" : "chats") · updated \(ProjectDateLabel.text(project.updatedAt))")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Theme.surfaceSelected : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct ProjectDetail: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.renderSafe) private var renderSafe
    let project: ProjectRecord
    let onDeleted: () -> Void
    @State private var instructions: String
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false
    @FocusState private var instructionsFocused: Bool

    init(project: ProjectRecord, onDeleted: @escaping () -> Void) {
        self.project = project
        self.onDeleted = onDeleted
        _instructions = State(initialValue: project.instructions)
    }

    private var instructionsChanged: Bool {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines) != project.instructions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ShotSafeScroll(renderSafe: renderSafe) {
                VStack(alignment: .leading, spacing: 24) {
                    instructionsSection
                    foldersSection
                    filesSection
                    conversationsSection
                    tasksSection
                    artifactsSection
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(ProjectTopAnchored())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Rename project", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") { store.renameProject(project.id, name: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \u{201C}\(project.name)\u{201D}?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteProject(project.id)
                onDeleted()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its chats and artifacts are kept; they just stop being grouped.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2, perform: beginRename)
                Text("Created \(ProjectDateLabel.text(project.createdAt))")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            HStack(spacing: 14) {
                ProjectAction(title: "New chat", symbol: "square.and.pencil", prominent: true) {
                    store.newConversation(inProject: project.id)
                }
                ProjectAction(title: "Rename", symbol: "pencil", action: beginRename)
                ProjectAction(title: "Delete…", symbol: "trash") { confirmingDelete = true }
            }
        }
    }

    private func beginRename() {
        renameText = project.name
        renaming = true
    }

    private func saveInstructions() {
        guard instructionsChanged else { return }
        store.setProjectInstructions(project.id, instructions)
    }

    private var instructionsSection: some View {
        ProjectSection(title: "Instructions") {
            ZStack(alignment: .topLeading) {
                if renderSafe {
                    Text(instructions.isEmpty ? " " : instructions).font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 5).padding(.vertical, 8)
                } else {
                    TextEditor(text: $instructions)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .focused($instructionsFocused)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Project instructions")
                        .onChange(of: instructionsFocused) { _, focused in
                            if !focused { saveInstructions() }
                        }
                }
                if instructions.isEmpty {
                    Text("What should every chat in this project know?")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 5).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 96, alignment: .topLeading)
            .padding(.horizontal, 8)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
            if instructionsChanged {
                HStack(spacing: 14) {
                    ProjectAction(title: "Save", symbol: "checkmark", prominent: true, action: saveInstructions)
                    ProjectAction(title: "Discard", symbol: "arrow.uturn.backward") { instructions = project.instructions }
                }
            }
        }
    }

    private var foldersSection: some View {
        let folders = project.grants.filter { !$0.readOnly }
        return ProjectSection(title: "Folders") {
            ForEach(folders) { grant in
                ProjectItemRow(symbol: "folder", title: grant.name, detail: grant.path, removeLabel: "Remove \(grant.name)") {
                    store.removeProjectFolder(project.id, grantID: grant.id)
                }
            }
            if folders.isEmpty { ProjectEmptyLine(text: "No folders yet.") }
            ProjectAction(title: "Add folder…", symbol: "folder.badge.plus", action: addFolder)
        }
    }

    private var filesSection: some View {
        ProjectSection(title: "Files") {
            ForEach(project.files) { file in
                ProjectItemRow(symbol: "doc", title: file.name, detail: ProjectDateLabel.size(file.byteSize),
                               removeLabel: "Remove \(file.name)") {
                    store.removeProjectFile(project.id, fileID: file.id)
                }
            }
            if project.files.isEmpty { ProjectEmptyLine(text: "No files yet.") }
            Text("Chats in this project can read these files but not change them.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            ProjectAction(title: "Add files…", symbol: "doc.badge.plus", action: addFiles)
        }
    }

    private var conversationsSection: some View {
        let chats = store.projectConversations(project.id)
        return ProjectSection(title: "Chats") {
            ForEach(chats) { chat in
                ProjectLinkRow(symbol: "bubble.left", title: chat.title, detail: ProjectDateLabel.text(chat.updatedAt)) {
                    store.select(chat.id)
                }
            }
            if chats.isEmpty { ProjectEmptyLine(text: "No chats yet.") }
        }
    }

    private var tasksSection: some View {
        let tasks = store.projectTaskReferences(project.id)
        return ProjectSection(title: "Background work") {
            ForEach(tasks) { task in
                let document = task.createRequest.workerType == "document"
                let status = (try? NativeTaskProjection.display(reference: task, snapshot: task.snapshot))?.card.status
                ProjectItemRow(symbol: status?.symbol(document: document) ?? "clock",
                               title: task.request.displayTitle,
                               detail: status?.title(document: document))
            }
            if tasks.isEmpty { ProjectEmptyLine(text: "No background work yet.") }
        }
    }

    private var artifactsSection: some View {
        let artifacts = store.projectArtifacts(project.id)
        return ProjectSection(title: "Artifacts") {
            ForEach(artifacts) { record in
                ProjectLinkRow(symbol: record.kind.symbol, title: record.title, detail: record.kind.label) {
                    store.section = .artifacts
                }
            }
            if artifacts.isEmpty { ProjectEmptyLine(text: "No artifacts yet.") }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addProjectFolder(project.id, url: url)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { store.addProjectFile(project.id, url: url) }
    }
}

private struct ProjectTopAnchored: ViewModifier {
    func body(content: Content) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { content }
            .clipped()
    }
}

private struct ProjectSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

private struct ProjectEmptyLine: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
    }
}

private struct ProjectAction: View {
    @Environment(\.renderSafe) private var renderSafe
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        if renderSafe {
            if prominent {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Label(title, systemImage: symbol).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
        } else if prominent {
            Button(title, action: action)
                .buttonStyle(.borderedProminent).controlSize(.small).font(.system(size: 12))
                .accessibilityLabel(title)
        } else {
            Button(action: action) { Label(title, systemImage: symbol) }
                .buttonStyle(.borderless).font(.system(size: 12))
                .accessibilityLabel(title)
        }
    }
}

private struct ProjectItemRow: View {
    @Environment(\.renderSafe) private var renderSafe
    let symbol: String
    let title: String
    let detail: String?
    var removeLabel: String? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let onRemove {
                if renderSafe {
                    Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                } else {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle").font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textSecondary)
                    .help(removeLabel ?? "Remove")
                    .accessibilityLabel(removeLabel ?? "Remove")
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
    }
}

private struct ProjectLinkRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.accent).frame(width: 18)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 8)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
    }
}
