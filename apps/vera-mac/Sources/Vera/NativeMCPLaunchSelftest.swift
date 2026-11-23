import Foundation

@MainActor
enum NativeMCPLaunchSelftest {
    actor Slow: NativeMCPConnection {
        private let delay: Duration
        private let down: Bool
        init(_ delay: Duration, down: Bool = false) { self.delay = delay; self.down = down }
        func connect() async throws {
            try await Task.sleep(for: delay)
            if down { throw NativeMCPTransportError.network }
        }
        func listTools(cursor: String?) async throws -> NativeMCPPage {
            NativeMCPPage(tools: [await NativeMCPChangesSelftest.tool("look", readOnly: true)], nextCursor: nil)
        }
        func call(name: String, arguments: [String: NativeJSONValue]) async throws -> NativeJSONValue { .object(["reading": .number(7)]) }
        func disconnect() async {}
    }

    final class House: @unchecked Sendable {
        private let lock = NSLock()
        private var delayed: Duration = .zero
        private var away = false
        private var made = 0
        var count: Int { lock.withLock { made } }
        func set(delay: Duration = .zero, down: Bool = false) { lock.withLock { delayed = delay; away = down } }
        func make() -> Slow { lock.withLock { made += 1; return Slow(delayed, down: away) } }
    }

    static let id = "6b1f0e84-3a2d-4c57-9e10-8d4c2b7f5a36"
    static let row: [String: Any] = ["id": id, "name": "House", "url": "http://house.local:8123/private", "scopes": IntegrationsText.scopeKeys, "timeout_seconds": 2.0]
    static var unattended: String { IntegrationsText.scopeKeys[2] }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NativeToolError.failed(message) }
    }

    static func wait(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NativeToolError.failed(message)
    }

    @MainActor
    final class Disk {
        var contents: [String: Any]
        let keys = NativeCredentialFixtureStore()
        var loaded: [String: Any] {
            ["native_mcp_servers": NativeMCPAddressBook(store: keys).resolved(contents["native_mcp_servers"] as? [[String: Any]] ?? [])]
        }
        var broken = false
        init(_ contents: [String: Any]) { self.contents = contents }
    }

    static func launch(_ disk: Disk, _ house: House, delays: [Duration] = [.zero, .milliseconds(20)]) -> (NativeMCPManager, ConfigStore) {
        let (servers, _) = NativeMCPServerConfiguration.load(disk.loaded)
        let manager = NativeMCPManager(servers: servers, authenticatedFactory: { _, _ in house.make() }, reconnectDelays: delays)
        let config = ConfigStore(credentialStore: disk.keys, readConfiguration: { disk.contents }, nativeMCP: manager, writeConfiguration: {
            if disk.broken { throw NativeMCPTransportError.network }
            disk.contents = $0
        })
        return (manager, config)
    }

    static func stays(_ disk: Disk) -> Bool {
        (disk.contents["native_mcp_servers"] as? [[String: Any]])?.first?["stays_connected"] as? Bool ?? false
    }

    static func connected(_ manager: NativeMCPManager) -> Bool { manager.servers.first?.connected == true }

    static func run() async throws {
        try await reconnects()
        try await disconnects()
        try await overlapping()
        try await scheduled()
        try check(!IntegrationsText.footer(.none).contains("quits") && IntegrationsText.footer(.oauth).contains("quits"), "Only account sign-in says it ends when Tandem quits")
        print("NATIVE MCP LAUNCH SELFTEST OK")
    }

    static func reconnects() async throws {
        let disk = Disk(["native_mcp_servers": [row]]), house = House()
        let (untouched, untouchedConfig) = launch(disk, house)
        try await Task.sleep(for: .milliseconds(60))
        try check(house.count == 0 && !connected(untouched), "A service nobody connected isn't contacted at launch")
        await untouched.connect(id)
        try check(connected(untouched) && stays(disk), "Connecting is remembered")
        withExtendedLifetime(untouchedConfig) {}
        let (reopened, config) = launch(disk, house)
        try await wait("A service with no sign-in reconnects at launch") { connected(reopened) }
        house.set(down: true)
        await reopened.authority.disconnect(id, status: "The connection dropped")
        let before = house.count
        try await wait("It's tried again while unreachable") { house.count >= before + 3 }
        try check(IntegrationsText.state(reopened.servers[0], signingIn: false, reconnecting: reopened.reconnects(reopened.servers[0])) == "Reconnecting", "It says it's reconnecting")
        house.set()
        try await wait("It comes back by itself") { connected(reopened) }
        try config.updateNativeMCPServer(row.merging(["stays_connected": true, "url": "http://other.local:8123/private"]) { $1 })
        try check(!stays(disk), "A new address isn't connected to by itself")
        await config.settleNativeMCP()
        try await Task.sleep(for: .milliseconds(60))
        try check(!connected(reopened), "A moved service waits for the person")
    }

    static func disconnects() async throws {
        let disk = Disk(["native_mcp_servers": [row]]), house = House()
        let (first, firstConfig) = launch(disk, house)
        await first.connect(id)
        await first.disconnect(id)
        try check(!stays(disk) && !connected(first), "Disconnect is remembered")
        let count = house.count
        let (second, secondConfig) = launch(disk, house)
        try await Task.sleep(for: .milliseconds(60))
        try check(house.count == count && !connected(second), "Disconnect sticks across a relaunch")
        await second.connect(id)
        disk.broken = true
        await second.disconnect(id)
        try check(!connected(second) && second.servers[0].status == NativeMCPManager.disconnectUnsaved, "A Disconnect that can't be saved says so")
        try await Task.sleep(for: .milliseconds(60))
        try check(!connected(second), "It stays disconnected meanwhile")
        disk.broken = false
        await second.connect(id)
        house.set(delay: .milliseconds(30))
        await second.authority.disconnect(id, status: "The connection dropped")
        second.refresh()
        try await Task.sleep(for: .milliseconds(10))
        disk.contents["edited"] = "elsewhere"
        await second.disconnect(id)
        try await Task.sleep(for: .milliseconds(80))
        try check(disk.contents["edited"] as? String == "elsewhere" && stays(disk), "A file edited elsewhere isn't written over")
        try check(!connected(second) && second.servers[0].status == NativeMCPManager.disconnectUnsaved, "The reason outlasts a reconnect that was under way: \(second.servers[0].status)")
        disk.contents.removeValue(forKey: "edited")
        house.set()
        await second.connect(id)
        await second.disconnect(id)
        try check(!stays(disk), "Disconnecting again is remembered")
        for delay in 0..<25 {
            house.set(delay: .milliseconds(delay % 4))
            await second.connect(id)
            await second.authority.disconnect(id, status: "The connection dropped")
            second.refresh()
            try await Task.sleep(for: .milliseconds(delay % 5))
            await second.disconnect(id)
            try await Task.sleep(for: .milliseconds(15))
            second.refresh()
            try check(!connected(second) && !stays(disk), "A reconnect outlived Disconnect")
        }
        withExtendedLifetime((firstConfig, secondConfig)) {}
    }

    static func overlapping() async throws {
        let disk = Disk(["native_mcp_servers": [row.merging(["stays_connected": true]) { $1 }]]), house = House()
        house.set(delay: .milliseconds(80))
        let (manager, config) = launch(disk, house)
        try await wait("The launch reconnect starts") { house.count == 1 }
        await manager.connect(id)
        try check(connected(manager) && house.count == 1, "Connect waits for the reconnect under way and adds no second one")
        try check(manager.authority.definitions(scope: "focused").count == 1, "Its tools are there when Connect returns")
        withExtendedLifetime(config) {}
    }

    static func scheduled() async throws {
        let disk = Disk(["native_mcp_servers": [row.merging(["stays_connected": true]) { $1 }]]), house = House()
        house.set(delay: .milliseconds(80))
        let (manager, config) = launch(disk, house)
        await manager.settleReconnects(scope: unattended)
        try check(manager.authority.definitions(scope: unattended).count == 1, "A run at launch waits for the reconnect")
        house.set(down: true)
        await manager.authority.disconnect(id, status: "The connection dropped")
        let (waiting, waitingConfig) = launch(disk, house, delays: [.zero, .seconds(300)])
        try await wait("The first try fails") { house.count >= 3 && !waiting.servers[0].connecting && waiting.reconnects(waiting.servers[0]) }
        try await Task.sleep(for: .milliseconds(40))
        house.set()
        let started = ContinuousClock.now
        await waiting.settleReconnects(scope: unattended)
        try check(connected(waiting) && started.duration(to: .now) < .seconds(2), "A run tries a service that was waiting for its next turn")
        house.set(down: true)
        await waiting.authority.disconnect(id, status: "The connection dropped")
        let count = house.count
        await waiting.settleReconnects(scope: unattended)
        try check(!connected(waiting) && house.count > count, "An unreachable service doesn't hold a run up")
        await waiting.disconnect(id)
        let after = house.count
        await waiting.settleReconnects(scope: unattended)
        try check(house.count == after, "A run never reconnects what the person disconnected")
        withExtendedLifetime((config, waitingConfig)) {}
    }
}
