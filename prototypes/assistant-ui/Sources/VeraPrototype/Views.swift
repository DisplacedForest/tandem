import AppKit
import SwiftUI

struct PrototypeView: View {
    @ObservedObject var store: PrototypeStore
    @Environment(\.colorScheme) private var colorScheme
    private var background: Color { colorScheme == .dark ? Color(white: 0.105) : Color(white: 0.99) }
    private var panelBackground: Color { colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.96) }
    @FocusState private var composerFocused: Bool
    @State private var outputError: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $store.destination) {
                Button(action: store.newChat) {
                    Label("New Chat", systemImage: "square.and.pencil").foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("new-chat")
                Label("Vera", systemImage: "sparkle").foregroundStyle(.primary)
                    .tag(Destination.assistant)
                    .accessibilityIdentifier("vera-destination")
                if !store.saved.conversations.isEmpty {
                    Section("Chats") {
                        ForEach(store.saved.conversations) { chat in
                            Text(chat.title).lineLimit(2).tag(Destination.conversation(chat.id))
                                .help(chat.title)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            HSplitView {
                conversation.frame(minWidth: 350, maxWidth: .infinity)
                inspector.frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
            }
        }
        .background(background)
        .frame(minWidth: 860, minHeight: 600)
        .task(id: store.conversation.id) {
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.conversation.title).font(.headline).lineLimit(1)
                Spacer()
                Text(store.connectionLabel).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("connection-status")
            }
            .padding(20)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(store.messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.role == "user" ? "You" : "Vera")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                                    .font(.system(size: 15)).lineSpacing(5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(message.id)
                            .accessibilityElement(children: .combine)
                        }
                        if store.busyConversations.contains(store.conversation.id) {
                            ProgressView().controlSize(.small).accessibilityLabel("Waiting for Vera")
                        }
                        Color.clear.frame(height: 1).id("transcript-end")
                    }
                    .padding(24).frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: store.messages.count) { _, _ in proxy.scrollTo("transcript-end", anchor: .bottom) }
            }
            VStack(alignment: .leading, spacing: 10) {
                if let error = store.conversationError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if store.pending != nil && !store.busyConversations.contains(store.conversation.id) {
                    HStack {
                        Text("Message not confirmed").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry message") { Task { await store.retry() } }
                            .disabled(store.connectionError != nil)
                    }
                }
                if store.conversation.draft.unicodeScalars.count > 8000 {
                    Text("Messages can contain up to 8,000 characters.").font(.caption).foregroundStyle(.red)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Message Vera", text: Binding(get: { store.conversation.draft }, set: store.setDraft), axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(2...7)
                        .focused($composerFocused).accessibilityLabel("Message Vera")
                        .accessibilityIdentifier("message-composer")
                    Button { Task { await store.send() } } label: {
                        Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                            .frame(width: 24, height: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canSend || store.conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.conversation.draft.unicodeScalars.count > 8000)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send message").help("Send message (Command-Return)")
                    .accessibilityIdentifier("send-message")
                }
                .padding(14)
                .background(panelBackground, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(composerFocused ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1))
            }
            .padding(20)
        }
        .background(background)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Details", selection: $store.panel) {
                ForEach(SidePanel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(16).accessibilityIdentifier("detail-panels")
            Divider()
            if let error = store.connectionError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.callout)
                    Button("Reconnect") { Task { await store.refresh() } }.disabled(store.refreshing)
                }.padding(16)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch store.panel {
                    case .activity: activity
                    case .outputs: outputs
                    case .computers: computers
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(panelBackground)
    }

    @ViewBuilder private var activity: some View {
        if store.visibleTasks.isEmpty {
            empty(store.capabilities == nil ? "Activity unavailable" : "No activity yet", icon: "clock")
        }
        ForEach(store.visibleTasks) { task in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: task.state == "completed" ? "checkmark.circle" : task.state == "needs_decision" ? "questionmark.circle" : "circle.dotted")
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.title).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
                        Text(task.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let summary = task.result?.summary, !summary.isEmpty {
                    Text(summary).font(.callout).textSelection(.enabled)
                }
                if task.state == "needs_decision", let decision = task.decision {
                    Text(decision.prompt).font(.callout).textSelection(.enabled)
                    HStack {
                        Button("Approve") { Task { await store.reply(task, approved: true) } }
                            .disabled(store.savedReply(task) == false)
                            .accessibilityLabel("Approve: \(task.title)")
                        Button("Decline") { Task { await store.reply(task, approved: false) } }
                            .disabled(store.savedReply(task) == true)
                            .accessibilityLabel("Decline: \(task.title)")
                    }
                    .disabled(task.cancelRequested || store.busyTasks.contains(task.id) || store.connectionError != nil)
                }
                if task.canStop {
                    Button("Stop") { Task { await store.stop(task) } }
                        .disabled(store.busyTasks.contains(task.id) || store.connectionError != nil)
                        .accessibilityLabel("Stop: \(task.title)")
                        .accessibilityIdentifier("stop-\(task.id)")
                }
                if let error = store.taskErrors[task.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.bottom, 4)
            Divider()
        }
    }

    @ViewBuilder private var outputs: some View {
        if !store.visibleTasks.contains(where: { !($0.result?.artifacts ?? []).isEmpty }) {
            empty(store.capabilities == nil ? "Outputs unavailable" : "No outputs yet", icon: "doc")
        }
        ForEach(store.visibleTasks) { task in
            ForEach(Array((task.result?.artifacts ?? []).enumerated()), id: \.offset) { _, artifact in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        guard let url = artifact.resolved(in: store.configuration.workspaceRoot) else {
                            outputError = PrototypeError.artifact.localizedDescription
                            return
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label(artifact.title.nonempty ?? "Output", systemImage: "doc")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(artifact.resolved(in: store.configuration.workspaceRoot) == nil)
                    .accessibilityLabel("Reveal output: \(artifact.title)")
                    .help("Reveal in Finder")
                    Text(task.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if artifact.resolved(in: store.configuration.workspaceRoot) == nil {
                        Text("File unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let outputError { Text(outputError).font(.caption).foregroundStyle(.red) }
    }

    private var computers: some View {
        VStack(alignment: .leading, spacing: 12) {
            empty("No computers connected", icon: "desktopcomputer")
            Text("Computer execution isn't available in this prototype.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func empty(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.callout).foregroundStyle(.secondary).padding(.top, 8)
    }
}

struct PrototypeApplication: App {
    static var launchStore: PrototypeStore?
    let store: PrototypeStore
    init() {
        guard let prepared = Self.launchStore else { fatalError("Prototype configuration is required") }
        store = prepared
    }
    var body: some Scene {
        WindowGroup("Vera Prototype") { PrototypeView(store: store) }
            .defaultSize(width: 1140, height: 760)
    }
}
