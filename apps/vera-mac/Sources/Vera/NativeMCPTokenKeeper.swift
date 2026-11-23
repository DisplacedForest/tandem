import Foundation

@MainActor
final class NativeMCPTokenKeeper {
    private struct Saved: Codable {
        let endpoint: String
        let token: String
    }
    private let store: any NativeCredentialStore
    private(set) var saved: Set<String> = []
    private(set) var unremoved: Set<String> = []
    private var paused: Set<String> = []
    private var opening: [String: NativeMCPAuthorization] = [:]
    private var retries: [String: Task<Void, Never>] = [:]
    private var turns: [String: Int] = [:]
    private var attempts: [String: Int] = [:]
    private var attempting: [String: UUID] = [:]

    init(store: any NativeCredentialStore) { self.store = store }

    static func account(_ id: String) -> String { "connected-service." + id }

    nonisolated static let holders = "connected-services"

    func load(_ servers: [NativeMCPServerConfiguration], prunes: Bool) {
        if prunes { forgetStrays(Set(servers.filter { $0.authentication == .bearer }.map(\.id))) }
        for server in servers where server.authentication == .bearer {
            do {
                guard let value = try store.readForStartup(for: Self.account(server.id)) else { continue }
                saved.insert(server.id)
                try? remember(server.id)
                if Self.token(value, for: server) == nil { discard(server.id) }
            } catch { saved.insert(server.id) }
        }
    }

    func read(_ server: NativeMCPServerConfiguration) -> String? {
        guard saved.contains(server.id) else { return nil }
        do {
            guard let value = try store.readForStartup(for: Self.account(server.id)) else {
                saved.remove(server.id)
                return nil
            }
            guard let token = Self.token(value, for: server) else {
                discard(server.id)
                return nil
            }
            return token
        } catch { return nil }
    }

    private func held() throws -> Set<String> {
        guard let value = try store.readForStartup(for: Self.holders) else { return [] }
        return try JSONDecoder().decode(Set<String>.self, from: Data(value.utf8))
    }

    private func hold(_ ids: Set<String>) throws {
        let data = try JSONEncoder().encode(ids.sorted())
        try store.set(ids.isEmpty ? nil : String(decoding: data, as: UTF8.self), for: Self.holders)
    }

    private func remember(_ id: String) throws {
        let ids = try held()
        if !ids.contains(id) { try hold(ids.union([id])) }
    }

    private func forgetStrays(_ kept: Set<String>) {
        guard let ids = try? held(), !ids.isEmpty else { return }
        var left = ids
        for id in ids.subtracting(kept) where (try? store.set(nil, for: Self.account(id))) != nil { left.remove(id) }
        if left != ids { try? hold(left) }
    }

    private func discard(_ id: String) {
        do { try forget(id) } catch { unremoved.insert(id) }
    }

    func raw(_ id: String) throws -> String? { try store.readForStartup(for: Self.account(id)) }

    func restore(_ values: [String: String]) -> Bool {
        var restored = true
        for (id, value) in values {
            do {
                try remember(id)
                try store.set(value, for: Self.account(id))
                saved.insert(id)
                paused.remove(id)
            } catch { restored = false }
        }
        return restored
    }

    func save(_ token: String, server: NativeMCPServerConfiguration) throws {
        let value = try JSONEncoder().encode(Saved(endpoint: server.endpoint.absoluteString, token: token))
        try remember(server.id)
        try store.set(String(decoding: value, as: UTF8.self), for: Self.account(server.id))
        saved.insert(server.id)
    }

    func forget(_ id: String) throws {
        pause(id)
        guard saved.contains(id) else { return }
        try store.set(nil, for: Self.account(id))
        if let ids = try? held(), ids.contains(id) { try? hold(ids.subtracting([id])) }
        saved.remove(id)
        unremoved.remove(id)
    }

    @discardableResult
    func pause(_ id: String) -> Int {
        turns[id, default: 0] += 1
        paused.insert(id)
        attempts[id] = nil
        retries.removeValue(forKey: id)?.cancel()
        opening.removeValue(forKey: id)?.revoke()
        return turns[id, default: 0]
    }

    func turn(_ id: String) -> Int { turns[id, default: 0] }
    func isCurrent(_ turn: Int, id: String) -> Bool { turns[id, default: 0] == turn }

    func resume(_ id: String) {
        paused.remove(id)
        attempts[id] = nil
    }

    func isPaused(_ id: String) -> Bool { paused.contains(id) }
    func wants(_ id: String) -> Bool { saved.contains(id) && !paused.contains(id) }
    func settled(_ id: String) { attempts[id] = nil }
    func begin(_ authorization: NativeMCPAuthorization, id: String) { opening[id] = authorization }
    func finish(_ authorization: NativeMCPAuthorization, id: String) {
        if opening[id] === authorization { opening.removeValue(forKey: id) }
    }

    func retry(_ id: String, delays: [Duration], attempt: @escaping @MainActor () async -> Void, then: @escaping @MainActor () -> Void) {
        guard retries[id] == nil, let last = delays.last else { return }
        let count = attempts[id, default: 0]
        attempts[id] = count + 1
        let delay = count < delays.count ? delays[count] : last
        retries[id] = run(id, after: delay, attempt: attempt, then: then)
    }

    func runNow(_ id: String, attempt: @escaping @MainActor () async -> Void, then: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        if let pending = inFlight(id) { return pending }
        retries.removeValue(forKey: id)?.cancel()
        attempts[id] = max(1, attempts[id, default: 0])
        let task = run(id, after: .zero, attempt: attempt, then: then)
        retries[id] = task
        return task
    }

    func inFlight(_ id: String) -> Task<Void, Never>? { attempting[id] == nil ? nil : retries[id] }

    private func run(_ id: String, after delay: Duration, attempt: @escaping @MainActor () async -> Void, then: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let mark = UUID()
        return Task { [weak self] in
            do { if delay > .zero { try await Task.sleep(for: delay) } } catch { return }
            guard !Task.isCancelled else { return }
            self?.attempting[id] = mark
            await attempt()
            if self?.attempting[id] == mark { self?.attempting.removeValue(forKey: id) }
            guard !Task.isCancelled else { return }
            self?.retries.removeValue(forKey: id)
            then()
        }
    }

    private static func token(_ value: String, for server: NativeMCPServerConfiguration) -> String? {
        guard let decoded = try? JSONDecoder().decode(Saved.self, from: Data(value.utf8)),
              decoded.endpoint == server.endpoint.absoluteString else { return nil }
        return decoded.token
    }
}
