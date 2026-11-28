import Foundation

struct NativeMCPInstallOffer: Identifiable, Equatable, Sendable {
    let name: String
    let label: String
    let detail: String
    let change: Bool
    let usable: Bool
    var id: String { name }
}

@MainActor
final class NativeMCPInstallDraft: ObservableObject {
    enum Step: Equatable { case fill, checking, review, installing, installed }
    nonisolated static let unreachable = "Tandem couldn't see what this server offers. Check what you entered, then try again."
    nonisolated static let nothing = "This server doesn't offer any tools."

    let entry: NativeMCPStarterEntry
    let id = UUID().uuidString.lowercased()
    @Published var values: [String: String] = [:]
    @Published var permissions = NativeMCPStandingPermission()
    @Published var offTools: Set<String> = []
    @Published var scopes = Set(IntegrationsText.scopeKeys)
    @Published private(set) var step: Step = .fill
    @Published private(set) var offers: [NativeMCPInstallOffer] = []
    @Published private(set) var error: String?
    private(set) var endpoint: URL?
    nonisolated static let leftBehind = "This didn't connect, and it couldn't be taken out of your services. Try again, or remove it under Personal."
    private let factory: NativeMCPAuthority.AuthenticatedFactory?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var stored = false
    private weak var config: ConfigStore?

    init(entry: NativeMCPStarterEntry, factory: NativeMCPAuthority.AuthenticatedFactory? = nil) {
        self.entry = entry
        self.factory = factory
    }

    init(reviewing entry: NativeMCPStarterEntry, offers: [NativeMCPInstallOffer]) {
        self.entry = entry
        factory = nil
        step = .review
        self.offers = offers
    }

    var reads: [NativeMCPInstallOffer] { offers.filter { !$0.change } }
    var changes: [NativeMCPInstallOffer] { offers.filter(\.change) }
    var filled: Bool { entry.fields.allSatisfy { !$0.required || !value($0).isEmpty } }
    var canInstall: Bool { step == .review && !offers.isEmpty && !scopes.isEmpty }
    var busy: Bool { step == .checking || step == .installing }
    var title: String { entry.isOwn ? "Add a service" : "Install \(entry.name)" }
    private var name: String { entry.nameField.map(value) ?? entry.name }
    private var publisher: String? { entry.publisher.isEmpty ? nil : entry.publisher }
    var count: String { "\(offers.count) \(offers.count == 1 ? "tool" : "tools"), \(changes.count) write, \(reads.count) read" }

    private func value(_ field: NativeMCPStarterField) -> String {
        (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var token: String? { entry.credentialField.map(value).flatMap { $0.isEmpty ? nil : $0 } }
    private var authentication: NativeMCPServerConfiguration.Authentication { token == nil ? .none : entry.authentication }

    func beginCheck() {
        guard step == .fill, operation == nil else { return }
        operation = Task { [weak self] in
            await self?.check()
            self?.operation = nil
        }
    }

    func check() async {
        guard step == .fill, filled, entry.authentication != .oauth else { return }
        error = nil
        let endpoint: URL
        let configuration: NativeMCPServerConfiguration
        var authorization: NativeMCPAuthorization?
        do {
            endpoint = try entry.endpoint(values)
            configuration = try NativeMCPServerConfiguration(id: id, name: name, endpoint: endpoint, readTools: [], authentication: authentication,
                                                             publisher: publisher, sourceURL: entry.sourceURL)
        } catch {
            self.error = IntegrationsText.message(error)
            return
        }
        if let token {
            do { authorization = try NativeMCPAuthorization(serverID: id, endpoint: endpoint, token: token) } catch {
                self.error = "That doesn't look like a token. Copy it again and paste all of it."
                return
            }
        }
        let generation = UUID()
        self.generation = generation
        step = .checking
        let authority = NativeMCPAuthority(servers: [configuration], authenticatedFactory: factory)
        await authority.connect(id, authorization: authorization)
        let state = authority.access.snapshot().first
        await authority.disconnect(id)
        guard self.generation == generation, !Task.isCancelled else { return }
        guard let state, state.connected, !state.tools.isEmpty else {
            step = .fill
            error = state?.connected == true ? Self.nothing : Self.unreachable
            return
        }
        self.endpoint = endpoint
        offers = state.tools.map { tool in
            let checked = tool.outputSchema == nil || tool.outputValidator != nil
            return NativeMCPInstallOffer(name: tool.remoteName, label: tool.title ?? tool.remoteName, detail: tool.description.trimmingCharacters(in: .whitespacesAndNewlines),
                                         change: tool.state != .read, usable: tool.validator != nil && tool.schema.pi("type") == .string("object") && checked)
        }
        step = .review
    }

    @discardableResult
    func cancel() -> Bool {
        generation = UUID()
        operation?.cancel()
        operation = nil
        if step == .installing { step = .fill }
        let warned = error == Self.leftBehind
        guard withdraw() || warned else {
            error = Self.leftBehind
            if let config { Task { [id] in await config.nativeMCP.disconnect(id) } }
            return false
        }
        values = [:]
        return true
    }

    private func withdraw() -> Bool {
        guard stored, let config else { return true }
        if config.nativeMCPServerRows.contains(where: { ($0["id"] as? String)?.lowercased() == id }) {
            do { try config.removeNativeMCPServer(id: id) } catch { return false }
        }
        stored = false
        return true
    }

    @discardableResult
    func install(_ config: ConfigStore) -> Task<Void, Never>? {
        guard canInstall, let catalogue = try? IntegrationsCatalogue.loaded.get(), let endpoint else {
            error = "The service could not be installed. Try again."
            return nil
        }
        error = nil
        self.config = config
        var row = catalogue.configurationRow(for: entry, name: name, endpoint: endpoint, authentication: authentication,
                                             scopes: IntegrationsText.scopeKeys.filter { scopes.contains($0) }, id: id)
        row = permissions.applying(to: row)
        if !offTools.isEmpty { row["off_tools"] = offTools.sorted() }
        do {
            if stored { try config.updateNativeMCPServer(row) } else { try config.addNativeMCPServer(row) }
        } catch {
            self.error = IntegrationsText.message(error)
            return nil
        }
        stored = true
        let generation = UUID()
        self.generation = generation
        step = .installing
        let token = token
        let id = id
        let task = Task {
            await config.settleNativeMCP()
            guard self.generation == generation else { return }
            await config.nativeMCP.connect(id, token: token)
            guard self.generation == generation else { return }
            operation = nil
            let state = config.nativeMCP.servers.first { $0.id == id }
            if state?.connected == true {
                stored = false
                values = [:]
                step = .installed
                return
            }
            let reason = state?.status ?? Self.unreachable
            let withdrawn = withdraw()
            await config.settleNativeMCP()
            guard self.generation == generation else { return }
            error = withdrawn ? reason : Self.leftBehind
            step = .fill
        }
        operation = task
        return task
    }
}
