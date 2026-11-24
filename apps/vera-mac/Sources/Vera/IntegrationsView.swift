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
    static let companionScope = "assistant"
    static let ownWorkScope = "worker"
    static let companionScopes: Set<String> = [companionScope, ownWorkScope]
    static let scopeKeys = ["focused", companionScope, ownWorkScope]

    static let ownWork = "Work {name} does on its own"

    static func scopeOrder(_ companion: CompanionSubject) -> [(key: String, title: String)] {
        [("focused", "Focused chats"), ("assistant", companion.leading), (ownWorkScope, CompanionSentence.plain(ownWork, name: companion.name))]
    }

    static func scopes(_ scopes: Set<String>) -> CompanionLine {
        let titles = scopeOrder(CompanionSubject(nil)).filter { scopes.contains($0.key) }
            .map { (scope: (key: String, title: String)) -> String in
                switch scope.key {
                case companionScope: return CompanionSentence.placeholder
                case ownWorkScope: return ownWork
                default: return scope.title
                }
            }
        let text = titles.joined(separator: ", ")
        return !scopes.isDisjoint(with: companionScopes) ? .named(text) : .literal(text)
    }

    static func authentication(_ authentication: NativeMCPServerConfiguration.Authentication) -> String {
        switch authentication {
        case .none: return "No sign-in"
        case .bearer: return "Needs an access token"
        case .oauth: return "Signs in with your account"
        }
    }

    static func state(_ server: NativeMCPServerState, signingIn: Bool, reconnecting: Bool = false) -> String {
        if signingIn { return "Signing in" }
        if reconnecting { return "Reconnecting" }
        if server.connecting { return "Connecting" }
        if server.connected { return server.configuration.authentication == .oauth ? "Signed in" : "Connected" }
        return "Not connected"
    }

    static let tokenNote = "Kept in your Mac's keychain until you disconnect or remove this service, or change its address."
    static let disconnectNote = "Disconnecting removes the saved token."
    static let tokenSaved = "Token saved"

    static func footer(_ authentication: NativeMCPServerConfiguration.Authentication, reports: Bool = false) -> String {
        let approved = reports ? "The service decides which tools it offers and which of them only read. You can turn any of them off." : "Only what you approve is available, and a service cannot give itself more."
        return authentication == .oauth ? approved + " Connections end when Tandem quits." : approved
    }

    static let accountSignInNote = "Account sign-in needs details from the publisher in the configuration file; see the setup guide."

    static func removeQuestion(_ name: String) -> String { "Remove \(name)? Its tools stop being available everywhere right away." }

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

    init(initialTab: IntegrationsTab = .catalogue, initialSearch: String = "") {
        self.initialTab = initialTab
        self.initialSearch = initialSearch
    }

    var body: some View {
        IntegrationsDestination(manager: config.nativeMCP, initialTab: initialTab, initialSearch: initialSearch)
    }
}

struct IntegrationsManageTarget: Identifiable {
    let id: String
}

enum IntegrationsDetailTarget: Identifiable, Equatable {
    case entry(NativeMCPStarterEntry)
    case server(String)

    var id: String {
        switch self {
        case .entry(let entry): return "entry:" + entry.id
        case .server(let id): return "server:" + id
        }
    }
}

private struct IntegrationsDestination: View {
    @ObservedObject var manager: NativeMCPManager
    @EnvironmentObject var config: ConfigStore
    @Environment(\.renderSafe) private var renderSafe
    @State private var tab: IntegrationsTab
    @State private var search: String
    @State private var closed: Set<String> = []
    @State private var detail: IntegrationsDetailTarget?
    @State private var installing: NativeMCPStarterEntry?
    @State private var managing: IntegrationsManageTarget?
    @State private var oauthReview: NativeMCPOAuthReview?
    @State private var removing: NativeMCPServerState?
    @State private var removeError: String?

    init(manager: NativeMCPManager, initialTab: IntegrationsTab, initialSearch: String) {
        self.manager = manager
        _tab = State(initialValue: initialTab)
        _search = State(initialValue: initialSearch)
    }

    private var catalogue: NativeMCPStarterCatalog? { try? IntegrationsCatalogue.loaded.get() }
    private var entries: [NativeMCPStarterEntry] { catalogue?.entries ?? [] }

    var body: some View {
        GeometryReader { space in
            let width = min(max(0, space.size.width - 64), IntegrationsPageModel.contentWidth)
            let columns = IntegrationsPageModel.columns(for: width)
            ShotSafeScroll(renderSafe: renderSafe) {
                VStack(alignment: .leading, spacing: 18) {
                    IntegrationsPageHeader(search: $search, stacked: width < IntegrationsPageModel.headerRowWidth) { installing = .own }
                    IntegrationsPagePills(selection: $tab)
                    if let removeError { IntegrationsNotice(text: removeError) }
                    switch tab {
                    case .catalogue: publicPage(columns)
                    case .personal: personalPage(columns)
                    }
                }
                .frame(width: width, alignment: .leading)
                .padding(.top, 72).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .sheet(item: $installing) { entry in
            IntegrationsInstallSheet(draft: NativeMCPInstallDraft(entry: entry)) { _ in
                if entry.isOwn { tab = .personal }
            }
        }
        .sheet(item: $managing) { target in
            IntegrationsManageSheet(target: target) { _ in }
        }
        .sheet(item: $oauthReview) { review in
            NativeMCPOAuthReviewEditor(manager: manager, review: review)
        }
        .sheet(item: $detail) { target in
            IntegrationsDetailSheet(manager: manager, target: target)
        }
        .confirmationDialog(removing.map { IntegrationsText.removeQuestion($0.configuration.name) } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible,
                            presenting: removing) { server in
            Button("Remove", role: .destructive) { remove(server.id) }
            Button("Cancel", role: .cancel) {}
        }
        .onDisappear {
            guard !renderSafe else { return }
            manager.cancelPendingOAuth()
        }
    }

    @ViewBuilder
    private func publicPage(_ columns: Int) -> some View {
        if let catalogue {
            let sections = IntegrationsPageModel.sections(catalogue.matching(query: search, category: nil))
            if sections.isEmpty {
                noMatch
            } else {
                ForEach(sections) { section in
                    let open = !closed.contains(section.title)
                    IntegrationsPageSection(title: section.title, open: open) {
                        if open { closed.insert(section.title) } else { closed.remove(section.title) }
                    } content: {
                        IntegrationsPageGrid(columns: columns) {
                            ForEach(section.entries) { entryRow($0) }
                        }
                    }
                }
            }
        } else {
            Text("The list could not be loaded.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func personalPage(_ columns: Int) -> some View {
        if let error = config.nativeMCPConfigurationError ?? manager.configurationError {
            IntegrationsNotice(text: error)
        }
        let matches = IntegrationsPageModel.matching(manager.servers, entries: entries, query: search)
        if manager.servers.isEmpty {
            personalEmpty
        } else if matches.isEmpty {
            noMatch
        } else {
            IntegrationsPageGrid(columns: columns) {
                ForEach(matches) { serverRow($0) }
            }
        }
    }

    private var noMatch: some View {
        Text(IntegrationsPageModel.noMatch).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
    }

    private var personalEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: AppSection.integrations.icon).font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text(IntegrationsPageModel.emptyTitle).font(.system(size: 20, weight: .semibold))
            Text(IntegrationsPageModel.emptyDetail)
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            IntegrationsAction(title: "Add your own…", symbol: "plus", prominent: true) {
                installing = .own
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func entryRow(_ entry: NativeMCPStarterEntry) -> some View {
        let servers = IntegrationsPageModel.installed(entry, in: manager.servers)
        let state = servers.count == 1 ? servers.first.map { manager.shownState($0) } : nil
        return IntegrationsPageRow(icon: entry.icon, name: entry.name, line: entry.description,
                                   state: servers.isEmpty ? nil : state ?? "Installed", live: servers.contains(where: \.connected)) {
            detail = servers.count == 1 ? servers.first.map { .server($0.id) } : .entry(entry)
        } trailing: {
            switch IntegrationsPageModel.trailing(entry, in: manager.servers) {
            case .install: IntegrationsPagePlus(name: entry.name) { installing = entry }
            case .menu: menu(entry.name, servers)
            }
        }
    }

    private func serverRow(_ server: NativeMCPServerState) -> some View {
        let entry = IntegrationsPageModel.entry(for: server, in: entries)
        let state = manager.shownState(server)
        return IntegrationsPageRow(icon: entry?.icon, name: server.configuration.name,
                                   line: IntegrationsPageModel.line(server, state: state, entry: entry),
                                   lineHelp: server.connected || server.status == "Not connected" || server.status == state ? nil : server.status,
                                   state: state, live: server.connected) {
            detail = .server(server.id)
        } trailing: {
            menu(server.configuration.name, [server])
        }
    }

    private func menu(_ name: String, _ servers: [NativeMCPServerState]) -> some View {
        let items = servers.map { server in
            IntegrationsPageMenu.Item(id: server.id, name: server.configuration.name,
                                      actions: IntegrationsPageModel.menu(manager.connection(server)),
                                      help: manager.hasSavedToken(server.id) ? IntegrationsText.disconnectNote : nil)
        }
        return IntegrationsPageMenu(name: name, items: items, perform: perform)
    }

    private func perform(_ action: IntegrationsPageModel.MenuAction, _ id: String) {
        removeError = nil
        switch action {
        case .manage: managing = IntegrationsManageTarget(id: id)
        case .connect:
            if manager.asksForToken(id) { detail = .server(id) } else { Task { await manager.connect(id) } }
        case .signIn: oauthReview = manager.beginOAuthReview(id)
        case .cancel, .disconnect: manager.endConnection(id)
        case .remove: removing = manager.servers.first { $0.id == id }
        }
    }

    private func remove(_ id: String) {
        do { try config.removeNativeMCPServer(id: id) } catch { removeError = IntegrationsText.message(error) }
    }
}

extension NativeMCPManager {
    func connection(_ server: NativeMCPServerState) -> IntegrationsPageModel.Connection {
        IntegrationsPageModel.Connection(authentication: server.configuration.authentication, connected: server.connected, connecting: server.connecting,
                                         signingIn: oauthProgress[server.id] != nil, reconnecting: reconnects(server), kept: keeps(server))
    }

    func shownState(_ server: NativeMCPServerState) -> String {
        IntegrationsText.state(server, signingIn: oauthProgress[server.id] != nil, reconnecting: reconnects(server))
    }

    func asksForToken(_ id: String) -> Bool {
        servers.first { $0.id == id }?.configuration.authentication == .bearer && !hasSavedToken(id)
    }

    func endConnection(_ id: String) {
        cancelOAuthLocally(id)
        Task { await disconnect(id) }
    }
}

struct IntegrationsDetailSheet: View {
    @ObservedObject var manager: NativeMCPManager
    let target: IntegrationsDetailTarget
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.renderSafe) private var renderSafe
    @State private var installing: NativeMCPStarterEntry?
    @State private var managing: IntegrationsManageTarget?
    @State private var oauthReview: NativeMCPOAuthReview?
    @State private var readTest: NativeMCPReadTestController?
    @State private var enteredTokens: [String: String] = [:]
    @State private var consentError: String?
    @State private var opened: String?

    init(manager: NativeMCPManager, target: IntegrationsDetailTarget) {
        self.manager = manager
        self.target = target
    }

    private var entries: [NativeMCPStarterEntry] { (try? IntegrationsCatalogue.loaded.get())?.entries ?? [] }

    private var server: NativeMCPServerState? {
        if let opened { return manager.servers.first { $0.id == opened } }
        guard case .server(let id) = target else { return nil }
        return manager.servers.first { $0.id == id }
    }

    private var gone: Bool {
        guard server == nil else { return false }
        if case .server = target { return true }
        return opened != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let server {
                ShotSafeScroll(renderSafe: renderSafe) {
                    serverCard(server).id(server.id)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 520, alignment: .top).clipped()
            } else if case .entry(let entry) = target {
                entryCard(entry).padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.controlSize(.small).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .frame(width: 620)
        .background(Theme.bg)
        .sheet(item: $installing) { entry in
            IntegrationsInstallSheet(draft: NativeMCPInstallDraft(entry: entry)) { opened = $0 }
        }
        .sheet(item: $managing) { target in
            IntegrationsManageSheet(target: target) { _ in }
        }
        .sheet(item: $oauthReview) { review in
            NativeMCPOAuthReviewEditor(manager: manager, review: review)
        }
        .sheet(item: $readTest) { controller in
            NativeMCPReadTestEditor(controller: controller)
        }
        .onChange(of: gone) { _, gone in if gone, !renderSafe { dismiss() } }
        .onDisappear {
            guard !renderSafe else { return }
            enteredTokens.removeAll()
            readTest?.close()
            readTest = nil
        }
    }

    private func installed(_ entry: NativeMCPStarterEntry) -> Bool {
        manager.servers.contains { entry.matches($0.configuration) }
    }

    private func serverCard(_ server: NativeMCPServerState) -> some View {
        let configuration = server.configuration
        let progress = manager.oauthProgress[server.id]
        let state = IntegrationsText.state(server, signingIn: progress != nil, reconnecting: reconnects(server))
        let detail = reconnects(server) ? nil : progress ?? (server.status == state || server.status.hasPrefix("Connected") ? nil : server.status)
        let reads = server.tools.filter { $0.state == .read || $0.asksBecauseOfService }
        let changes = server.tools.filter { $0.state == .change && !$0.asksBecauseOfService }
        let unapproved = server.tools.filter { $0.state == .unapproved }
        let listed = IntegrationsPageModel.entry(for: server, in: entries)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                IntegrationsEntryIcon(name: listed?.icon, size: 36)
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
                        managing = IntegrationsManageTarget(id: server.id)
                    }
                    primaryAction(server, progress: progress)
                }
            }
            if let description = listed?.description {
                Text(description).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            if let detail, detail != "Not connected" {
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if configuration.authentication == .bearer && !server.connected && !server.connecting && !reconnects(server) {
                VStack(alignment: .leading, spacing: 6) {
                    IntegrationsSecureField(placeholder: "Access token", text: Binding(
                        get: { enteredTokens[server.id] ?? "" }, set: { enteredTokens[server.id] = $0 }))
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
            IntegrationsSection(title: "Read") {
                if reads.isEmpty {
                    Text(server.connected ? (server.tools.isEmpty ? "This service offered no reads." : "No reads are approved.") : "Connect to see the reads this service offers.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(reads) { tool in toolRow(tool, warning: tool.asksBecauseOfService ? "\(configuration.name) says this can change things, so it asks first." : nil) }
                    }
                }
            }
            if !changes.isEmpty {
                IntegrationsSection(title: "Write") {
                    VStack(spacing: 6) {
                        ForEach(changes) { tool in toolRow(tool, warning: nil) }
                    }
                }
            }
            if !unapproved.isEmpty {
                IntegrationsSection(title: "Not approved") {
                    VStack(spacing: 6) {
                        ForEach(unapproved) { tool in toolRow(tool, warning: nil, described: true) }
                    }
                }
            }
            ForEach(server.notes, id: \.self) { note in
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let source = configuration.sourceURL {
                IntegrationsLink(title: "Publisher's page", url: source)
            }
            Text(IntegrationsText.footer(configuration.authentication, reports: configuration.reportsTools))
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reconnects(_ server: NativeMCPServerState) -> Bool { manager.reconnects(server) }

    @ViewBuilder
    private func primaryAction(_ server: NativeMCPServerState, progress: String?) -> some View {
        let saved = manager.hasSavedToken(server.id)
        if server.connected || server.connecting || progress != nil || reconnects(server) {
            let pending = !manager.keeps(server) && (server.connecting || progress != nil)
            IntegrationsAction(title: pending ? "Cancel connection" : "Disconnect", symbol: "xmark", prominent: true, help: saved ? IntegrationsText.disconnectNote : nil) {
                enteredTokens.removeValue(forKey: server.id)
                manager.endConnection(server.id)
            }
        } else if server.configuration.authentication == .oauth {
            IntegrationsAction(title: "Sign in", symbol: "person.badge.key", prominent: true) {
                oauthReview = manager.beginOAuthReview(server.id)
            }
        } else {
            IntegrationsAction(title: "Connect", symbol: "link", prominent: true) {
                let token = enteredTokens.removeValue(forKey: server.id).flatMap { $0.isEmpty ? nil : $0 }
                Task { await manager.connect(server.id, token: token) }
            }
        }
    }

    private func toolRow(_ tool: NativeMCPToolRecord, warning: String?, described: Bool = false) -> some View {
        let enabled = manager.authority.access.isOn(tool)
        let tryable = tool.state == .read
        let canTry = !renderSafe && NativeMCPReadTestController.scope(authority: manager.authority, record: tool) != nil
        return HStack(alignment: .top, spacing: 10) {
            if !described {
                IntegrationsSwitch(isOn: Binding(get: { enabled }, set: { setTool(tool, enabled: $0) }),
                                   label: tool.remoteName, disabled: !tool.callable)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.remoteName).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tool.callable ? Theme.textPrimary : Theme.textSecondary)
                if let reason = tool.reason, !described {
                    Text(reason).font(.system(size: 11)).foregroundStyle(Theme.accent)
                } else if !tool.description.isEmpty {
                    Text(tool.description).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                if let warning {
                    Text(warning).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if tryable {
                IntegrationsAction(title: "Try", symbol: "play", disabled: !(canTry || (renderSafe && enabled && tool.callable))) {
                    readTest = NativeMCPReadTestController(manager: manager, record: tool)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
    }

    private func setTool(_ tool: NativeMCPToolRecord, enabled: Bool) {
        if tool.server.reportsTools {
            do { try config.setNativeMCPTool(tool, enabled: enabled); consentError = nil }
            catch { consentError = "The change couldn't be saved: \(IntegrationsText.message(error))" }
            return
        }
        let id = tool.id
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
                IntegrationsEntryIcon(name: entry.icon, size: 36)
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
                if entry.credentialField?.required ?? true { IntegrationsTag(text: IntegrationsText.authentication(entry.authentication)) }
            }
            if let source = entry.sourceURL { IntegrationsLink(title: "Publisher's page", url: source) }
        }
    }
}

struct IntegrationsEntryIcon: View {
    let name: String?
    let size: CGFloat

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor private static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        let file = name as NSString
        guard let url = VeraResources.url(file.deletingPathExtension, ext: file.pathExtension), let image = NSImage(contentsOf: url) else { return nil }
        if file.pathExtension == "svg" {
            image.isTemplate = true
            image.size = NSSize(width: 144, height: 144)
        }
        cache[name] = image
        return image
    }

    var body: some View {
        Group {
            if let image = name.flatMap(Self.image) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().foregroundStyle(Theme.textPrimary)
            } else {
                Image(systemName: AppSection.integrations.icon).font(.system(size: size * 0.5)).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct IntegrationsInstallSheet: View {
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.renderSafe) private var renderSafe
    @StateObject private var draft: NativeMCPInstallDraft
    @State private var writesOpen: Bool
    @State private var readsOpen = false
    let onInstalled: (String) -> Void

    init(draft: @autoclosure @escaping () -> NativeMCPInstallDraft, writesOpen: Bool = false, onInstalled: @escaping (String) -> Void) {
        _draft = StateObject(wrappedValue: draft())
        _writesOpen = State(initialValue: writesOpen)
        self.onInstalled = onInstalled
    }

    private var entry: NativeMCPStarterEntry { draft.entry }
    private var reviewing: Bool { [.review, .installing, .installed].contains(draft.step) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if !entry.isOwn { IntegrationsEntryIcon(name: entry.icon, size: 36) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title).font(.title2)
                    if !entry.isOwn { Text("by \(entry.publisher)").font(.callout).foregroundStyle(Theme.textSecondary) }
                }
            }
            if reviewing { review.disabled(draft.busy) } else { fill }
            if let error = draft.error {
                Text(error).font(.callout).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if draft.busy {
                    if !renderSafe { ProgressView().controlSize(.small) }
                    Text(draft.step == .checking ? "Seeing what your server offers" : "Connecting").font(.callout).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Cancel") { if draft.cancel() { dismiss() } }.controlSize(.small).keyboardShortcut(.cancelAction)
                if reviewing {
                    IntegrationsAction(title: entry.isOwn ? "Add" : "Install", symbol: "plus", prominent: true, disabled: !draft.canInstall, action: install)
                        .keyboardShortcut(.defaultAction)
                } else if entry.authentication != .oauth {
                    IntegrationsAction(title: "Continue", symbol: "arrow.right", prominent: true, disabled: !draft.filled || draft.step == .checking) { draft.beginCheck() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 480)
        .onChange(of: draft.step) { _, step in
            guard step == .installed else { return }
            store.connectAddedService(draft.id, scopes: draft.scopes)
            onInstalled(draft.id)
            dismiss()
        }
        .onDisappear { if !renderSafe { draft.cancel() } }
    }

    @ViewBuilder
    private var fill: some View {
        if entry.authentication == .oauth {
            Text(IntegrationsText.accountSignInNote).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(entry.fields) { field in
            IntegrationsField(label: field.label, help: help(field)) {
                if field.secret {
                    IntegrationsSecureField(placeholder: "Paste it here", label: field.label, text: value(field))
                } else if renderSafe {
                    IntegrationsStaticField(text: draft.values[field.id] ?? field.placeholder ?? "", dimmed: draft.values[field.id] == nil)
                } else {
                    TextField(field.placeholder ?? "", text: value(field)).textFieldStyle(.roundedBorder).accessibilityLabel(field.label)
                }
            }
        }
        .disabled(draft.step == .checking)
    }

    @ViewBuilder
    private var review: some View {
        HStack(spacing: 5) {
            Text(verbatim: draft.count).font(.system(size: 13, weight: .medium))
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .help(Self.ruleNote).accessibilityLabel(Self.ruleNote)
        }
        ShotSafeScroll(renderSafe: renderSafe) {
            VStack(alignment: .leading, spacing: 10) {
                group("Write", draft.changes, open: $writesOpen)
                group("Read", draft.reads, open: $readsOpen)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: writesOpen || readsOpen ? 360 : 80).clipped()
        IntegrationsField(label: "Available in") {
            IntegrationsScopeToggles(scopes: $draft.scopes).tint(Theme.accent)
        }
    }

    private static let ruleNote = "Reads run when they're needed. Writes follow your settings in Rules."

    @ViewBuilder
    private func group(_ title: String, _ offers: [NativeMCPInstallOffer], open: Binding<Bool>) -> some View {
        if !offers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { open.wrappedValue.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary).frame(width: 12)
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Text(verbatim: "\(offers.count)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(offers.count)")
                .accessibilityValue(open.wrappedValue ? "Open" : "Closed")
                if open.wrappedValue {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(offers) { offer in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: offer.label).font(.system(size: 13, weight: .medium))
                                if !offer.usable {
                                    Text("Tandem can't use this one.").font(.system(size: 11)).foregroundStyle(Theme.accent)
                                }
                                if !offer.detail.isEmpty {
                                    Text(verbatim: offer.detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                        .lineLimit(3).help(Text(verbatim: offer.detail))
                                }
                            }
                        }
                    }
                    .padding(.leading, 18)
                }
            }
        }
    }

    private func help(_ field: NativeMCPStarterField) -> String? {
        let parts = [field.help, field.target == .credential ? IntegrationsText.tokenNote : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func value(_ field: NativeMCPStarterField) -> Binding<String> {
        Binding(get: { draft.values[field.id] ?? "" }, set: { draft.values[field.id] = $0 })
    }

    private func install() {
        draft.install(config)
    }
}

struct IntegrationsManageSheet: View {
    @EnvironmentObject var config: ConfigStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.renderSafe) private var renderSafe
    let target: IntegrationsManageTarget
    let onSaved: (String) -> Void
    @State private var loaded = false
    @State private var name = ""
    @State private var endpoint = ""
    @State private var reads = ""
    @State private var acts = ""
    @State private var scopes = Set(IntegrationsText.scopeKeys)
    @State private var authentication: NativeMCPServerConfiguration.Authentication = .none
    @State private var timeout = "20"
    @State private var error: String?
    @State private var confirmingRemove = false

    init(target: IntegrationsManageTarget, filled row: [String: Any]? = nil, onSaved: @escaping (String) -> Void) {
        self.target = target
        self.onSaved = onSaved
        guard let row else { return }
        let fields = Self.fields(row)
        _loaded = State(initialValue: true)
        _name = State(initialValue: fields.name)
        _endpoint = State(initialValue: fields.endpoint)
        _reads = State(initialValue: fields.reads)
        _acts = State(initialValue: fields.acts)
        _scopes = State(initialValue: fields.scopes)
        _authentication = State(initialValue: fields.authentication)
        if let timeout = fields.timeout { _timeout = State(initialValue: timeout) }
    }

    private var existingRow: [String: Any]? {
        config.nativeMCPServerRows.first { ($0["id"] as? String)?.lowercased() == target.id }
    }

    private var reportsTools: Bool {
        guard let row = existingRow else { return false }
        return row["read_tools"] == nil && row["act_tools"] == nil
    }

    private var addressChanged: Bool {
        guard let row = existingRow else { return false }
        return row["authentication"] as? String != NativeMCPServerConfiguration.Authentication.bearer.rawValue
            || row["url"] as? String != endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSignInDetails: Bool {
        existingRow?["oauth"] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage \(name.isEmpty ? "service" : name)").font(.title2)
            IntegrationsField(label: "Name") {
                if renderSafe { IntegrationsStaticField(text: name) } else {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Name")
                }
            }
            IntegrationsField(label: "Service address") {
                if renderSafe { IntegrationsStaticField(text: endpoint) } else {
                    TextField("https://", text: $endpoint).textFieldStyle(.roundedBorder).accessibilityLabel("Service address")
                }
            }
            if !reportsTools {
            IntegrationsField(label: "Approved reads, one per line") {
                if renderSafe { IntegrationsStaticField(text: reads, lines: true) } else {
                    TextEditor(text: $reads).font(.system(.body, design: .monospaced))
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
                        .accessibilityLabel("Approved reads, one per line")
                }
            }
            IntegrationsField(label: "Approved writes, one per line") {
                if renderSafe { IntegrationsStaticField(text: acts, lines: true) } else {
                    TextEditor(text: $acts).font(.system(.body, design: .monospaced))
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
                        .accessibilityLabel("Approved writes, one per line")
                }
            }
            }
            IntegrationsField(label: "Available in") {
                IntegrationsScopeToggles(scopes: $scopes).tint(Theme.accent)
            }
            HStack(alignment: .top, spacing: 20) {
                IntegrationsField(label: "Sign-in", help: hasSignInDetails ? nil : IntegrationsText.accountSignInNote) {
                        Picker("Sign-in", selection: $authentication) {
                            Text("No sign-in").tag(NativeMCPServerConfiguration.Authentication.none)
                            Text("Access token").tag(NativeMCPServerConfiguration.Authentication.bearer)
                            if hasSignInDetails {
                                Text("Sign in with an account").tag(NativeMCPServerConfiguration.Authentication.oauth)
                            }
                        }
                        .labelsHidden().fixedSize()
                }
                IntegrationsField(label: "Timeout in seconds") {
                    if renderSafe { IntegrationsStaticField(text: timeout).frame(width: 80) } else {
                        TextField("20", text: $timeout).textFieldStyle(.roundedBorder).frame(width: 80)
                            .accessibilityLabel("Timeout in seconds")
                    }
                }
            }
            if authentication == .bearer {
                IntegrationsTokenField(manager: config.nativeMCP, id: target.id, addressChanged: addressChanged)
            }
            if let error { Text(error).font(.callout).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Remove…", role: .destructive) { confirmingRemove = true }.controlSize(.small)
                Spacer()
                Button("Cancel") { dismiss() }.controlSize(.small).keyboardShortcut(.cancelAction)
                IntegrationsAction(title: "Save", symbol: "checkmark", prominent: true, action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520)
        .onAppear(perform: load)
        .confirmationDialog(IntegrationsText.removeQuestion(name),
                            isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        }
    }

    private static func fields(_ row: [String: Any]) -> (name: String, endpoint: String, reads: String, acts: String, scopes: Set<String>,
                                                        authentication: NativeMCPServerConfiguration.Authentication, timeout: String?) {
        let stored = NativeMCPServerConfiguration.Authentication(rawValue: row["authentication"] as? String ?? "none") ?? .none
        let seconds = row["timeout_seconds"] as? Double
        return (row["name"] as? String ?? "", row["url"] as? String ?? "",
                (row["read_tools"] as? [String] ?? []).joined(separator: "\n"), (row["act_tools"] as? [String] ?? []).joined(separator: "\n"),
                Set(row["scopes"] as? [String] ?? ["focused", "assistant"]), stored == .oauth && row["oauth"] == nil ? .none : stored,
                seconds.map { $0 == $0.rounded() ? String(Int($0)) : String($0) })
    }

    static func row(_ existing: [String: Any], id: String, name: String, endpoint: String, reads: String, acts: String, scopes: Set<String>,
                    seconds: Double, authentication: NativeMCPServerConfiguration.Authentication) -> [String: Any] {
        var row = existing
        row["id"] = id
        row["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        row["url"] = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing["id"] != nil, existing["read_tools"] == nil, existing["act_tools"] == nil, reads.isEmpty, acts.isEmpty {
            return signed(row, scopes: scopes, seconds: seconds, authentication: authentication)
        }
        var changed = Set<String>()
        let changes = acts.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && changed.insert($0).inserted }
        var seen = changed
        let kept = reads.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        row["read_tools"] = kept
        if changes.isEmpty { row.removeValue(forKey: "act_tools") } else { row["act_tools"] = changes }
        let asks = (row["asks_tools"] as? [String] ?? []).filter(kept.contains)
        if asks.isEmpty { row.removeValue(forKey: "asks_tools") } else { row["asks_tools"] = asks }
        return signed(row, scopes: scopes, seconds: seconds, authentication: authentication)
    }

    private static func signed(_ filled: [String: Any], scopes: Set<String>, seconds: Double,
                               authentication: NativeMCPServerConfiguration.Authentication) -> [String: Any] {
        var row = filled
        row["scopes"] = IntegrationsText.scopeKeys.filter { scopes.contains($0) }
        row["timeout_seconds"] = seconds
        if authentication == .none { row.removeValue(forKey: "authentication") } else { row["authentication"] = authentication.rawValue }
        if authentication != .oauth { row.removeValue(forKey: "oauth") }
        return row
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let row = existingRow else { return }
        let fields = Self.fields(row)
        name = fields.name
        endpoint = fields.endpoint
        reads = fields.reads
        acts = fields.acts
        scopes = fields.scopes
        authentication = fields.authentication
        if let seconds = fields.timeout { timeout = seconds }
    }

    private func save() {
        guard let seconds = Double(timeout.trimmingCharacters(in: .whitespaces)) else {
            error = "Enter the timeout as a number of seconds."
            return
        }
        if authentication == .oauth && !hasSignInDetails {
            error = IntegrationsText.accountSignInNote
            return
        }
        let row = Self.row(existingRow ?? [:], id: target.id, name: name, endpoint: endpoint, reads: reads, acts: acts,
                           scopes: scopes, seconds: seconds, authentication: authentication)
        do {
            try config.updateNativeMCPServer(row)
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

private struct IntegrationsTokenField: View {
    @ObservedObject var manager: NativeMCPManager
    let id: String
    let addressChanged: Bool
    @State private var token = ""
    @State private var replacing = false
    @State private var working = false
    @State private var error: String?

    private var server: NativeMCPServerState? { manager.servers.first { $0.id == id } }
    private var saved: Bool { manager.hasSavedToken(id) }

    var body: some View {
        IntegrationsField(label: "Access token") {
            VStack(alignment: .leading, spacing: 6) {
                if addressChanged {
                    Text(saved ? "Saving this address removes the saved token." : "Save first, then enter the token.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                } else if saved && !replacing {
                    HStack(spacing: 14) {
                        Label(IntegrationsText.tokenSaved, systemImage: "checkmark").font(.system(size: 13))
                        IntegrationsAction(title: "Replace", symbol: "arrow.triangle.2.circlepath") { replacing = true }
                        IntegrationsAction(title: "Disconnect", symbol: "xmark", help: IntegrationsText.disconnectNote) { disconnect() }
                    }
                } else {
                    HStack(spacing: 10) {
                        IntegrationsSecureField(placeholder: "Access token", text: $token)
                        IntegrationsAction(title: saved ? "Replace" : "Connect", symbol: "link", disabled: working || token.isEmpty) { submit() }
                        if saved { IntegrationsAction(title: "Cancel", symbol: "xmark", disabled: working) { token = ""; replacing = false } }
                    }
                }
                if let error { Text(error).font(.callout).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private func submit() {
        let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
        token = ""
        working = true
        error = nil
        Task {
            if saved {
                error = await manager.replaceToken(id, with: entered)
            } else {
                await manager.connect(id, token: entered)
                error = server?.connected == true ? nil : server?.status
            }
            working = false
            replacing = false
        }
    }

    private func disconnect() {
        error = nil
        Task {
            await manager.disconnect(id)
            error = saved ? NativeMCPManager.tokenUnremoved : nil
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
    var help: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                if let help {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .help(help).accessibilityLabel(help)
                }
            }
            content()
        }
    }
}

private struct IntegrationsStaticField: View {
    let text: String
    var lines = false
    var dimmed = false

    var body: some View {
        Text(text).font(lines ? .system(.body, design: .monospaced) : .system(size: 13))
            .foregroundStyle(dimmed ? Theme.textSecondary : Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: lines ? 90 : nil, alignment: .topLeading)
            .padding(.horizontal, lines ? 4 : 6).padding(.vertical, lines ? 2 : 3)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct IntegrationsSearchField: View {
    @Environment(\.renderSafe) private var renderSafe
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if renderSafe {
                Text(text.isEmpty ? "Search plugins" : text).font(.system(size: 13))
                    .foregroundStyle(text.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                Spacer(minLength: 0)
            } else {
                TextField("Search plugins", text: $text).textFieldStyle(.plain).font(.system(size: 13))
                    .accessibilityLabel("Search plugins")
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
    var label: String?
    @Binding var text: String

    var body: some View {
        if renderSafe {
            Text(text.isEmpty ? placeholder : String(repeating: "•", count: 24)).font(.system(size: 13)).foregroundStyle(text.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
        } else {
            SecureField(placeholder, text: $text).textFieldStyle(.roundedBorder).accessibilityLabel(label ?? placeholder)
                .help(IntegrationsText.tokenNote)
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

struct IntegrationsAction: View {
    @Environment(\.renderSafe) private var renderSafe
    let title: String
    let symbol: String
    var prominent = false
    var disabled = false
    var help: String? = nil
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
                .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent).controlSize(.small).font(.system(size: 12))
                .disabled(disabled)
                .accessibilityLabel(title)
                .help(help ?? "")
        } else {
            Button(action: action) { Label(title, systemImage: symbol) }
                .buttonStyle(.borderless).font(.system(size: 12))
                .disabled(disabled)
                .accessibilityLabel(title)
                .help(help ?? "")
        }
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

struct IntegrationsNotice: View {
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
