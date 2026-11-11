import SwiftUI
import AppKit

enum IntegrationsTab: String, CaseIterable, Identifiable, Hashable {
    case personal, catalogue

    var id: Self { self }

    var title: String {
        switch self {
        case .personal: return "Personal"
        case .catalogue: return "Public"
        }
    }
}

enum IntegrationsText {
    static let scopeKeys = ["focused", "assistant", "worker"]

    static func scopeOrder(_ companion: CompanionSubject) -> [(key: String, title: String)] {
        [("focused", "Focused chats"), ("assistant", companion.leading), ("worker", "Background work")]
    }

    static func scopes(_ scopes: Set<String>) -> CompanionLine {
        let titles = scopeOrder(CompanionSubject(nil)).filter { scopes.contains($0.key) }
            .map { (scope: (key: String, title: String)) -> String in scope.key == "assistant" ? CompanionSentence.placeholder : scope.title }
        let text = titles.joined(separator: ", ")
        return scopes.contains("assistant") ? .named(text) : .literal(text)
    }

    static func authentication(_ authentication: NativeMCPServerConfiguration.Authentication) -> String {
        switch authentication {
        case .none: return "No sign-in"
        case .bearer: return "Needs an access token"
        case .oauth: return "Signs in with your account"
        }
    }

    static func state(_ server: NativeMCPServerState, signingIn: Bool) -> String {
        if signingIn { return "Signing in" }
        if server.connecting { return "Connecting" }
        if server.connected { return server.configuration.authentication == .oauth ? "Signed in" : "Connected" }
        return "Not connected"
    }

    static let accountSignInNote = "Account sign-in needs details from the publisher in the configuration file; see the setup guide."

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "The change could not be saved."
    }
}

@MainActor
enum IntegrationsCatalogue {
    static let loaded: Result<NativeMCPStarterCatalog, any Error> = Result { try NativeMCPStarterCatalog.bundled() }
}

struct IntegrationsView: View {
    @EnvironmentObject var config: ConfigStore
    private let initialTab: IntegrationsTab
    private let initialSearch: String
    private let initialSelection: String?

    init(initialTab: IntegrationsTab = .personal, initialSearch: String = "", initialSelection: String? = nil) {
        self.initialTab = initialTab
        self.initialSearch = initialSearch
        self.initialSelection = initialSelection
    }

    var body: some View {
        IntegrationsDestination(manager: config.nativeMCP, initialTab: initialTab,
                                initialSearch: initialSearch, initialSelection: initialSelection)
    }
}

struct IntegrationsManageTarget: Identifiable {
    let id: String
    let existing: Bool
}

private struct IntegrationsDestination: View {
    @ObservedObject var manager: NativeMCPManager
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @Environment(\.renderSafe) private var renderSafe
    @State private var tab: IntegrationsTab
    @State private var search: String
    @State private var category: String?
    @State private var selectedServerID: String?
    @State private var selectedEntryID: String?
    @State private var installing: NativeMCPStarterEntry?
    @State private var managing: IntegrationsManageTarget?
    @State private var oauthReview: NativeMCPOAuthReview?
    @State private var readTest: NativeMCPReadTestController?
    @State private var temporaryTokens: [String: String] = [:]
    @State private var consentError: String?

    init(manager: NativeMCPManager, initialTab: IntegrationsTab, initialSearch: String, initialSelection: String?) {
        self.manager = manager
        _tab = State(initialValue: initialTab)
        _search = State(initialValue: initialSearch)
        _selectedServerID = State(initialValue: initialTab == .personal ? initialSelection : nil)
        _selectedEntryID = State(initialValue: initialTab == .catalogue ? initialSelection : nil)
    }

    private var catalogue: NativeMCPStarterCatalog? { try? IntegrationsCatalogue.loaded.get() }

    private var matches: [NativeMCPStarterEntry] {
        catalogue?.matching(query: search, category: category) ?? []
    }

    private var selectedServer: NativeMCPServerState? {
        manager.servers.first { $0.id == selectedServerID } ?? manager.servers.first
    }

    private var selectedEntry: NativeMCPStarterEntry? {
        matches.first { $0.id == selectedEntryID } ?? matches.first
    }

    private func installed(_ entry: NativeMCPStarterEntry) -> Bool {
        manager.servers.contains { $0.configuration.endpoint.absoluteString == entry.url.absoluteString }
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn.frame(width: 300)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            detailColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .sheet(item: $installing) { entry in
            IntegrationsInstallSheet(entry: entry) { id in
                tab = .personal
                selectedServerID = id
            }
        }
        .sheet(item: $managing) { target in
            IntegrationsManageSheet(target: target) { id in
                tab = .personal
                selectedServerID = id
            }
        }
        .sheet(item: $oauthReview) { review in
            NativeMCPOAuthReviewEditor(manager: manager, review: review)
        }
        .sheet(item: $readTest) { controller in
            NativeMCPReadTestEditor(controller: controller)
        }
        .onDisappear {
            guard !renderSafe else { return }
            temporaryTokens.removeAll()
            manager.cancelPendingOAuth()
            readTest?.close()
            readTest = nil
        }
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            IntegrationsSegmented(selection: $tab)
            switch tab {
            case .personal: personalList
            case .catalogue: catalogueList
            }
        }
        .padding(.horizontal, 12).padding(.top, 20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var personalList: some View {
        if let error = config.nativeMCPConfigurationError ?? manager.configurationError {
            IntegrationsNotice(text: error)
        }
        IntegrationsAddButton { managing = IntegrationsManageTarget(id: UUID().uuidString.lowercased(), existing: false) }
        ShotSafeScroll(renderSafe: renderSafe) {
            VStack(spacing: 2) {
                ForEach(manager.servers) { server in
                    let selected = server.id == selectedServer?.id
                    Button { selectedServerID = server.id } label: {
                        IntegrationsServerRow(name: server.configuration.name,
                                              state: IntegrationsText.state(server, signingIn: manager.oauthProgress[server.id] != nil),
                                              live: server.connected, selected: selected)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var catalogueList: some View {
        if let catalogue {
            IntegrationsSearchField(text: $search)
            IntegrationsFlowLayout(spacing: 6) {
                IntegrationsPill(title: "All", selected: category == nil) { category = nil }
                ForEach(catalogue.categories, id: \.self) { name in
                    IntegrationsPill(title: name, selected: category == name) { category = name }
                }
            }
            if matches.isEmpty {
                Text("Nothing matches.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            } else {
                ShotSafeScroll(renderSafe: renderSafe) {
                    VStack(spacing: 2) {
                        ForEach(matches) { entry in
                            let selected = entry.id == selectedEntry?.id
                            Button { selectedEntryID = entry.id } label: {
                                IntegrationsEntryRow(entry: entry, installed: installed(entry), selected: selected)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        } else {
            Text("The integration catalogue could not be loaded.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.top, 6)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch tab {
        case .personal:
            if let server = selectedServer {
                ShotSafeScroll(renderSafe: renderSafe) {
                    serverCard(server).id(server.id)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                personalEmpty
            }
        case .catalogue:
            if let entry = selectedEntry {
                ShotSafeScroll(renderSafe: renderSafe) {
                    entryCard(entry).id(entry.id)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Color.clear
            }
        }
    }

    private var personalEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: AppSection.integrations.icon).font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text("No connected services yet.").font(.system(size: 20, weight: .semibold))
            Text("Browse Public to install one, or add your own with Manage.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            IntegrationsAction(title: "Add your own…", symbol: "plus", prominent: true) {
                managing = IntegrationsManageTarget(id: UUID().uuidString.lowercased(), existing: false)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func serverCard(_ server: NativeMCPServerState) -> some View {
        let configuration = server.configuration
        let progress = manager.oauthProgress[server.id]
        let state = IntegrationsText.state(server, signingIn: progress != nil)
        let detail = progress ?? (server.status == state || server.status.hasPrefix("Connected") ? nil : server.status)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(configuration.name).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    if let publisher = configuration.publisher {
                        Text("by \(publisher)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(server.connected ? Theme.accent : Theme.textSecondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(state).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.top, 2)
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 8)
                HStack(spacing: 14) {
                    IntegrationsAction(title: "Manage", symbol: "slider.horizontal.3") {
                        managing = IntegrationsManageTarget(id: server.id, existing: true)
                    }
                    primaryAction(server, progress: progress)
                }
            }
            if let detail, detail != "Not connected" {
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if configuration.authentication == .bearer && !server.connected && !server.connecting {
                VStack(alignment: .leading, spacing: 6) {
                    IntegrationsSecureField(placeholder: "Temporary access token", text: Binding(
                        get: { temporaryTokens[server.id] ?? "" }, set: { temporaryTokens[server.id] = $0 }))
                    Text("Used only for this connection. Forgotten on disconnect or after one hour. Enter it again after reopening Tandem.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            if configuration.authentication == .oauth && server.connected && progress == nil {
                HStack(spacing: 10) {
                    IntegrationsAction(title: "Refresh sign-in", symbol: "arrow.clockwise") {
                        Task { await manager.refreshOAuth(server.id) }
                    }
                    Text("Sign-in lasts up to one hour.").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            IntegrationsSection(title: "Available in") {
                CompanionLineText(line: IntegrationsText.scopes(configuration.scopes)).font(.system(size: 13))
            }
            if let consentError {
                IntegrationsNotice(text: consentError)
            }
            IntegrationsSection(title: "Reads") {
                if server.tools.isEmpty {
                    Text(server.connected ? "This service offered no reads." : "Connect to see the reads this service offers.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(server.tools) { tool in toolRow(tool) }
                    }
                }
            }
            if let source = configuration.sourceURL {
                IntegrationsLink(title: "Publisher's page", url: source)
            }
            Text("Only reads you approve are available, and a service cannot grant itself more. Connections end when Tandem quits.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func primaryAction(_ server: NativeMCPServerState, progress: String?) -> some View {
        if server.connected || server.connecting || progress != nil {
            let pending = server.connecting || progress != nil
            IntegrationsAction(title: pending ? "Cancel connection" : "Disconnect", symbol: "xmark", prominent: true) {
                temporaryTokens.removeValue(forKey: server.id)
                manager.cancelOAuthLocally(server.id)
                Task { await manager.disconnect(server.id) }
            }
        } else if server.configuration.authentication == .oauth {
            IntegrationsAction(title: "Sign in", symbol: "person.badge.key", prominent: true) {
                oauthReview = manager.beginOAuthReview(server.id)
            }
        } else {
            IntegrationsAction(title: "Connect", symbol: "link", prominent: true) {
                let token = temporaryTokens.removeValue(forKey: server.id)
                Task { await manager.connect(server.id, token: token) }
            }
        }
    }

    private func toolRow(_ tool: NativeMCPToolRecord) -> some View {
        let enabled = config.nativeSettings.enabledToolIDs.contains(tool.id)
        let canTry = !renderSafe && NativeMCPReadTestController.scope(authority: manager.authority, record: tool) != nil
        return HStack(alignment: .top, spacing: 10) {
            IntegrationsSwitch(isOn: Binding(get: { enabled }, set: { setTool(tool.id, enabled: $0) }),
                               label: tool.remoteName, disabled: !tool.callable)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.remoteName).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tool.callable ? Theme.textPrimary : Theme.textSecondary)
                if let reason = tool.reason {
                    Text(reason).font(.system(size: 11)).foregroundStyle(Theme.accent)
                } else if !tool.description.isEmpty {
                    Text(tool.description).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            IntegrationsAction(title: "Try", symbol: "play", disabled: !(canTry || (renderSafe && enabled && tool.callable))) {
                readTest = NativeMCPReadTestController(manager: manager, record: tool)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
    }

    private func setTool(_ id: String, enabled: Bool) {
        let previous = config.nativeSettings.enabledToolIDs.contains(id)
        config.setNativeTool(id, enabled: enabled)
        store.updateNativeToolConsent(config.nativeSettings.enabledToolIDs)
        do {
            try config.save()
            consentError = nil
        } catch {
            config.setNativeTool(id, enabled: previous)
            store.updateNativeToolConsent(config.nativeSettings.enabledToolIDs)
            consentError = "The change couldn't be saved: \(IntegrationsText.message(error))"
        }
    }

    private func entryCard(_ entry: NativeMCPStarterEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    Text("by \(entry.publisher)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                if installed(entry) {
                    Label("Installed", systemImage: "checkmark").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    IntegrationsAction(title: "Install", symbol: "plus", prominent: true) { installing = entry }
                }
            }
            Text(entry.description).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                IntegrationsTag(text: entry.category)
                IntegrationsTag(text: IntegrationsText.authentication(entry.authentication))
            }
            IntegrationsLink(title: "Publisher's page", url: entry.sourceURL)
        }
    }
}

struct IntegrationsInstallSheet: View {
    @EnvironmentObject var config: ConfigStore
    @Environment(\.dismiss) private var dismiss
    let entry: NativeMCPStarterEntry
    let onInstalled: (String) -> Void
    @State private var reads: Set<String>
    @State private var scopes: Set<String> = ["focused", "assistant"]
    @State private var error: String?

    init(entry: NativeMCPStarterEntry, onInstalled: @escaping (String) -> Void) {
        self.entry = entry
        self.onInstalled = onInstalled
        _reads = State(initialValue: Set(entry.readTools))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install \(entry.name)").font(.title2)
                Text("by \(entry.publisher)").font(.callout).foregroundStyle(Theme.textSecondary)
            }
            IntegrationsField(label: "Service address") {
                Text(entry.url.absoluteString).font(.system(size: 12)).textSelection(.enabled)
            }
            IntegrationsField(label: "Sign-in") {
                Text(IntegrationsText.authentication(entry.authentication)).font(.system(size: 12))
            }
            IntegrationsField(label: "Reads") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.readTools, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { reads.contains(name) }, set: {
                            if $0 { reads.insert(name) } else { reads.remove(name) }
                        }))
                    }
                }
            }
            IntegrationsField(label: "Available in") {
                IntegrationsScopeToggles(scopes: $scopes)
            }
            Text("Only the reads you approve here become available. You can change this later under Manage.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            if entry.authentication == .oauth {
                Text(IntegrationsText.accountSignInNote).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.callout).foregroundStyle(Theme.accent) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if entry.authentication != .oauth {
                    Button("Install", action: install)
                        .keyboardShortcut(.defaultAction)
                        .disabled(reads.isEmpty || scopes.isEmpty)
                }
            }
        }
        .padding(24).frame(width: 480)
    }

    private func install() {
        guard entry.authentication != .oauth else { return }
        guard let catalogue = try? IntegrationsCatalogue.loaded.get() else {
            error = "The integration catalogue could not be loaded."
            return
        }
        let row = catalogue.configurationRow(
            for: entry,
            readTools: entry.readTools.filter { reads.contains($0) },
            scopes: IntegrationsText.scopeKeys.filter { scopes.contains($0) })
        do {
            try config.addNativeMCPServer(row)
            onInstalled(((row["id"] as? String) ?? "").lowercased())
            dismiss()
        } catch {
            self.error = IntegrationsText.message(error)
        }
    }
}

struct IntegrationsManageSheet: View {
    @EnvironmentObject var config: ConfigStore
    @Environment(\.dismiss) private var dismiss
    let target: IntegrationsManageTarget
    let onSaved: (String) -> Void
    @State private var loaded = false
    @State private var name = ""
    @State private var endpoint = ""
    @State private var reads = ""
    @State private var scopes: Set<String> = ["focused", "assistant"]
    @State private var authentication: NativeMCPServerConfiguration.Authentication = .none
    @State private var timeout = "20"
    @State private var error: String?
    @State private var confirmingRemove = false

    private var existingRow: [String: Any]? {
        config.nativeMCPServerRows.first { ($0["id"] as? String)?.lowercased() == target.id }
    }

    private var hasSignInDetails: Bool {
        target.existing && existingRow?["oauth"] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.existing ? "Manage \(name.isEmpty ? "service" : name)" : "Add a service").font(.title2)
            IntegrationsField(label: "Name") {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Name")
            }
            IntegrationsField(label: "Service address") {
                TextField("https://", text: $endpoint).textFieldStyle(.roundedBorder).accessibilityLabel("Service address")
            }
            IntegrationsField(label: "Approved reads, one per line") {
                TextEditor(text: $reads).font(.system(.body, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
                    .accessibilityLabel("Approved reads, one per line")
            }
            IntegrationsField(label: "Available in") {
                IntegrationsScopeToggles(scopes: $scopes)
            }
            HStack(alignment: .top, spacing: 20) {
                IntegrationsField(label: "Sign-in") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Sign-in", selection: $authentication) {
                            Text("No sign-in").tag(NativeMCPServerConfiguration.Authentication.none)
                            Text("Access token").tag(NativeMCPServerConfiguration.Authentication.bearer)
                            if hasSignInDetails {
                                Text("Sign in with an account").tag(NativeMCPServerConfiguration.Authentication.oauth)
                            }
                        }
                        .labelsHidden().fixedSize()
                        if !hasSignInDetails {
                            Text(IntegrationsText.accountSignInNote).font(.caption).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                IntegrationsField(label: "Timeout in seconds") {
                    TextField("20", text: $timeout).textFieldStyle(.roundedBorder).frame(width: 80)
                        .accessibilityLabel("Timeout in seconds")
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if target.existing {
                    Button("Remove…", role: .destructive) { confirmingRemove = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520)
        .onAppear(perform: load)
        .confirmationDialog("Remove \(name)? Its tools stop being available everywhere right away.",
                            isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let row = existingRow else { return }
        name = row["name"] as? String ?? ""
        endpoint = row["url"] as? String ?? ""
        reads = (row["read_tools"] as? [String] ?? []).joined(separator: "\n")
        scopes = Set(row["scopes"] as? [String] ?? ["focused", "assistant"])
        let stored = NativeMCPServerConfiguration.Authentication(rawValue: row["authentication"] as? String ?? "none") ?? .none
        authentication = stored == .oauth && row["oauth"] == nil ? .none : stored
        if let seconds = row["timeout_seconds"] as? Double {
            timeout = seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
        }
    }

    private func save() {
        guard let seconds = Double(timeout.trimmingCharacters(in: .whitespaces)) else {
            error = "Enter the timeout as a number of seconds."
            return
        }
        var row = target.existing ? (existingRow ?? [:]) : [:]
        row["id"] = target.id
        row["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        row["url"] = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        row["read_tools"] = reads.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        row["scopes"] = IntegrationsText.scopeKeys.filter { scopes.contains($0) }
        row["timeout_seconds"] = seconds
        if authentication == .oauth && !hasSignInDetails {
            error = IntegrationsText.accountSignInNote
            return
        }
        if authentication == .none { row.removeValue(forKey: "authentication") } else { row["authentication"] = authentication.rawValue }
        if authentication != .oauth { row.removeValue(forKey: "oauth") }
        do {
            if target.existing { try config.updateNativeMCPServer(row) } else { try config.addNativeMCPServer(row) }
            onSaved(target.id)
            dismiss()
        } catch {
            self.error = IntegrationsText.message(error)
        }
    }

    private func remove() {
        do {
            try config.removeNativeMCPServer(id: target.id)
            dismiss()
        } catch {
            self.error = IntegrationsText.message(error)
        }
    }
}

private struct IntegrationsScopeToggles: View {
    @EnvironmentObject var store: ChatStore
    @Binding var scopes: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(IntegrationsText.scopeOrder(store.companion), id: \.key) { scope in
                Toggle(scope.title, isOn: Binding(get: { scopes.contains(scope.key) }, set: {
                    if $0 { scopes.insert(scope.key) } else { scopes.remove(scope.key) }
                }))
            }
        }
    }
}

private struct IntegrationsField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}

private struct IntegrationsSegmented: View {
    @Binding var selection: IntegrationsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(IntegrationsTab.allCases) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(option.title).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(selected ? Theme.surfaceSelected : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
    }
}

private struct IntegrationsSearchField: View {
    @Environment(\.renderSafe) private var renderSafe
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if renderSafe {
                Text(text.isEmpty ? "Search integrations" : text).font(.system(size: 13))
                    .foregroundStyle(text.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                Spacer(minLength: 0)
            } else {
                TextField("Search integrations", text: $text).textFieldStyle(.plain).font(.system(size: 13))
                    .accessibilityLabel("Search integrations")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
    }
}

private struct IntegrationsSecureField: View {
    @Environment(\.renderSafe) private var renderSafe
    let placeholder: String
    @Binding var text: String

    var body: some View {
        if renderSafe {
            Text(placeholder).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
        } else {
            SecureField(placeholder, text: $text).textFieldStyle(.roundedBorder).accessibilityLabel(placeholder)
        }
    }
}

private struct IntegrationsSwitch: View {
    @Environment(\.renderSafe) private var renderSafe
    @Binding var isOn: Bool
    let label: String
    var disabled = false

    var body: some View {
        if renderSafe {
            Capsule().fill(isOn && !disabled ? Theme.accent : Theme.surfaceSelected)
                .frame(width: 30, height: 18)
                .overlay(alignment: isOn && !disabled ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 14, height: 14).padding(2)
                }
                .opacity(disabled ? 0.5 : 1)
        } else {
            Toggle(label, isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(disabled)
                .accessibilityLabel(label)
        }
    }
}

private struct IntegrationsAction: View {
    @Environment(\.renderSafe) private var renderSafe
    let title: String
    let symbol: String
    var prominent = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        if renderSafe {
            if prominent {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(disabled ? 0.5 : 1)
            } else {
                Label(title, systemImage: symbol).font(.system(size: 12))
                    .foregroundStyle(disabled ? Theme.textSecondary : Theme.accent)
            }
        } else if prominent {
            Button(title, action: action)
                .buttonStyle(.borderedProminent).controlSize(.small).font(.system(size: 12))
                .disabled(disabled)
                .accessibilityLabel(title)
        } else {
            Button(action: action) { Label(title, systemImage: symbol) }
                .buttonStyle(.borderless).font(.system(size: 12))
                .disabled(disabled)
                .accessibilityLabel(title)
        }
    }
}

private struct IntegrationsAddButton: View {
    @Environment(\.renderSafe) private var renderSafe
    let action: () -> Void

    var body: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
            Text("Add your own…").font(.system(size: 13, weight: .medium))
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
            Button(action: action) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("Add your own service")
        }
    }
}

private struct IntegrationsServerRow: View {
    let name: String
    let state: String
    let live: Bool
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: AppSection.integrations.icon).font(.system(size: 13))
                .foregroundStyle(live ? Theme.accent : Theme.textSecondary)
                .frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(state).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
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

private struct IntegrationsEntryRow: View {
    let entry: NativeMCPStarterEntry
    let installed: Bool
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(entry.publisher).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if installed {
                Text("Installed").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Theme.surfaceSelected : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct IntegrationsPill: View {
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
        .accessibilityLabel(title == "All" ? "Show all integrations" : "Show \(title)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct IntegrationsTag: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.surface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
    }
}

private struct IntegrationsLink: View {
    @Environment(\.renderSafe) private var renderSafe
    let title: String
    let url: URL

    var body: some View {
        if renderSafe {
            Label(title, systemImage: "arrow.up.right.square").font(.system(size: 12)).foregroundStyle(Theme.accent)
        } else {
            Link(destination: url) { Label(title, systemImage: "arrow.up.right.square") }
                .font(.system(size: 12))
                .help(url.absoluteString)
                .accessibilityLabel(title)
        }
    }
}

private struct IntegrationsNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

private struct IntegrationsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

private struct IntegrationsFlowLayout: Layout {
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
