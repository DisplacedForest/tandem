import SwiftUI

@MainActor
final class PluginsStore: ObservableObject {
    enum Phase { case loading, unconfigured, unreachable, unsupported, ready }
    @Published var phase: Phase = .loading
    @Published var entries: [PluginEntry] = []
    @Published var busy: Set<String> = []
    @Published var error: String?

    private var client: IntegrationsClient?
    var baseDescription: String { client?.base.absoluteString ?? "vera-api" }

    func configure(base: URL?) {
        client = base.map { IntegrationsClient(base: $0) }
        if client == nil { phase = .unconfigured }
    }

    func refresh() async {
        guard let client else { phase = .unconfigured; return }
        switch await client.fetch() {
        case .unreachable: phase = .unreachable
        case .unsupported: phase = .unsupported
        case .ok(let list):
            entries = list
            phase = .ready
        }
    }

    /// Live connection probe (used by the sheet's Test button).
    func test(id: String, fields: [String: String]?) async -> (ok: Bool, detail: String) {
        guard let client else { return (false, "vera-api isn't configured") }
        return await client.test(id: id, fields: fields)
    }

    func save(id: String, fields: [String: String], enable: Bool?) async -> String? {
        guard let client else { return "vera-api isn't configured" }
        busy.insert(id); defer { busy.remove(id) }
        if let detail = await client.save(id: id, fields: fields.isEmpty ? nil : fields, enabled: enable) {
            return detail
        }
        await refresh()
        return nil
    }

    /// Toggle a whole plugin on/off from its card.
    func setEnabled(_ entry: PluginEntry, _ on: Bool) {
        guard let client else { return }
        busy.insert(entry.id)
        Task {
            if let detail = await client.save(id: entry.id, enabled: on) {
                error = detail
            } else {
                await refresh()
            }
            busy.remove(entry.id)
        }
    }

    /// Toggle an experimental feature. `ack` must be true on a first-time enable —
    /// the consent sheet collects it; the server enforces it (400 without).
    /// Returns the refusal detail, nil on success.
    func setFeature(_ entry: PluginEntry, _ feature: PluginFeature, enabled: Bool, ack: Bool) async -> String? {
        guard let client else { return "vera-api isn't configured" }
        busy.insert(entry.id); defer { busy.remove(entry.id) }
        let detail = await client.save(id: entry.id,
                                       features: [feature.id: (enabled: enabled, ack: ack)])
        if detail == nil { await refresh() }
        return detail
    }

}
