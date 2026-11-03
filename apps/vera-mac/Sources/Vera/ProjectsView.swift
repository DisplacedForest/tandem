import SwiftUI
import AppKit

struct ProjectPreview: View {
    @EnvironmentObject var store: ChatStore
    let project: ProjectRecord
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(project.name, systemImage: "folder").font(.system(size: 16, weight: .semibold))
            let count = store.projectConversations(project.id).count
            Label("\(count) \(count == 1 ? "chat" : "chats")", systemImage: "bubble.left")
                .foregroundStyle(Theme.textSecondary)
            if !project.grants.isEmpty {
                Divider()
                ForEach(project.grants) { grant in
                    Label(grant.path, systemImage: "folder")
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            Divider()
            Button(action: onEdit) { Label("Edit project", systemImage: "gearshape") }
                .buttonStyle(.plain)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.textPrimary)
        .padding(18).frame(width: 340, alignment: .leading)
        .background(Theme.surface)
    }
}

struct ProjectEditor: View {
    @Environment(\.renderSafe) private var renderSafe
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord
    @State private var name: String
    @State private var instructions: String
    @State private var grants: [FolderGrant]
    @State private var error: String?
    @State private var managingFiles = false
    @State private var confirmingDelete = false

    init(project: ProjectRecord) {
        self.project = project
        _name = State(initialValue: project.name)
        _instructions = State(initialValue: project.instructions)
        _grants = State(initialValue: project.grants)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit project").font(.system(size: 20, weight: .semibold))
            ShotSafeScroll(renderSafe: renderSafe) {
                VStack(alignment: .leading, spacing: 18) {
                    if renderSafe {
                        Text(name).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        TextField("Project name", text: $name)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Project name")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source folders").fontWeight(.medium)
                        ForEach(grants) { grant in
                            HStack {
                                Label(grant.name, systemImage: "folder")
                                    .help(grant.path)
                                Spacer()
                                Button { grants.removeAll { $0.id == grant.id } } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(grant.name)")
                            }.padding(10).background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 8))
                        }
                        Button(action: addFolder) { Label("Add folder", systemImage: "folder.badge.plus") }
                            .buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Instructions").fontWeight(.medium)
                        Group {
                            if renderSafe {
                                Text(instructions).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            } else {
                                TextEditor(text: $instructions).scrollContentBackground(.hidden)
                                    .accessibilityLabel("Project instructions")
                            }
                        }
                        .font(.system(size: 13)).padding(8).frame(height: 100)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { managingFiles = true } label: {
                        Label("Manage project files", systemImage: "doc.on.doc")
                    }.buttonStyle(.plain)
                }
            }.frame(maxHeight: 360)
            if let error {
                Text(error).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Delete project", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.plain)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(.system(size: 13)).padding(24).frame(width: 520)
        .foregroundStyle(Theme.textPrimary).background(Theme.surface)
        .sheet(isPresented: $managingFiles) { ProjectFilesEditor(projectID: project.id) }
        .confirmationDialog("Delete \(project.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.clearProjectError()
                store.deleteProject(project.id)
                if store.project(project.id) == nil { dismiss() } else { error = store.projectError }
            }
        } message: {
            Text("Its chats and saved work are kept. They stop being grouped in this project.")
        }
    }

    private func save() {
        if store.saveProjectEdits(project.id, name: name, instructions: instructions, grants: grants) {
            dismiss()
        } else { error = store.projectError }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let grant = try FolderGrant.make(url: url)
            if !grants.contains(where: { $0.path == grant.path }) { grants.append(grant) }
        } catch { self.error = error.localizedDescription }
    }
}

struct ProjectFilesEditor: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    let projectID: String
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Project files").font(.system(size: 20, weight: .semibold))
            Text("Chats can read these files. Adding or removing a file saves immediately.")
                .foregroundStyle(Theme.textSecondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(store.project(projectID)?.files ?? []) { file in
                        HStack {
                            Label(file.name, systemImage: "doc").lineLimit(1)
                            Spacer()
                            Button("Remove") {
                                store.clearProjectError()
                                store.removeProjectFile(projectID, fileID: file.id)
                                error = store.projectError
                            }.accessibilityLabel("Remove \(file.name)")
                        }
                    }
                }
            }.frame(maxHeight: 240)
            if let error { Text(error).foregroundStyle(Theme.textSecondary) }
            HStack {
                Button("Add files", action: addFiles)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 13)).padding(24).frame(width: 480)
            .foregroundStyle(Theme.textPrimary).background(Theme.surface)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        store.clearProjectError()
        for url in panel.urls {
            store.addProjectFile(projectID, url: url)
            if let failure = store.projectError { error = failure; return }
        }
        error = nil
    }
}

struct ProjectsView: View {
    @Environment(\.renderSafe) private var renderSafe
    @EnvironmentObject var store: ChatStore
    @State private var editing: ProjectRecord?
    @State private var creating = false
    @State private var name = ""
    let initialSelection: String?

    init(initialSelection: String? = nil) { self.initialSelection = initialSelection }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Projects").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("New project") { name = ""; creating = true }
            }
            if let error = store.projectError { Text(error).foregroundStyle(Theme.textSecondary) }
            ShotSafeScroll(renderSafe: renderSafe) {
                VStack(spacing: 4) {
                    ForEach(store.projects) { project in
                        HStack(spacing: 14) {
                            Button { editing = project } label: {
                                Label(project.name, systemImage: "folder")
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Edit \(project.name)")
                            Button { store.newConversation(inProject: project.id) } label: {
                                Image(systemName: "square.and.pencil")
                            }.buttonStyle(.plain).help("New chat in \(project.name)")
                                .accessibilityLabel("New chat in \(project.name)")
                        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(28).frame(maxWidth: 620).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Theme.textPrimary).background(Theme.bg)
        .sheet(item: $editing) { ProjectEditor(project: $0) }
        .alert("New project", isPresented: $creating) {
            TextField("Project name", text: $name)
            Button("Create") { if let project = store.createProject(name: name) { editing = project } }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            if !renderSafe, let initialSelection { editing = store.project(initialSelection) }
        }
    }
}
