import Foundation

enum NativeMCPInstallSelftest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    @MainActor
    final class Disk {
        var contents: [String: Any] = [:]
        var writes = 0
    }

    @MainActor
    static func settle(_ manager: NativeMCPManager, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "the connected services did not update, found \(manager.servers.map(\.configuration.name))")
    }

    @MainActor
    static func run() async throws {
        let disk = Disk()
        disk.contents = ["unrelated_setting": "kept"]
        let manager = NativeMCPManager(servers: [])
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents }, nativeMCP: manager,
                                 writeConfiguration: { disk.contents = $0; disk.writes += 1 })
        try check(config.nativeMCPServerRows.isEmpty && config.nativeMCPConfigurationError == nil, "a fresh configuration should have no services")

        let catalog = try NativeMCPStarterCatalog.bundled()
        guard let entry = catalog.entries.first(where: { $0.id == "deepwiki" }) else { throw Failure(description: "catalogue entry missing") }
        let row = catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused", "worker"])
        guard let id = row["id"] as? String else { throw Failure(description: "row has no id") }
        try config.addNativeMCPServer(row)
        let written = disk.contents["native_mcp_servers"] as? [[String: Any]] ?? []
        try check(written.count == 1 && written[0]["id"] as? String == id, "the written configuration should hold the new row")
        try check(written[0]["publisher"] as? String == entry.publisher, "the written row should keep the publisher")
        try check(disk.contents["unrelated_setting"] as? String == "kept", "other settings should survive the write")
        try await settle(manager) { manager.servers.map(\.id) == [id] }
        guard let configuration = manager.servers.first?.configuration else { throw Failure(description: "manager has no server") }
        try check(configuration.scopes == ["focused", "worker"], "scopes should match the row")

        let toolID = configuration.toolID(entry.readTools[0])
        config.setNativeTool(toolID, enabled: true)
        config.setNativeTool("web-search", enabled: true)
        try config.save()
        try check(config.nativeSettings.enabledToolIDs.contains(toolID), "the tool should be enabled before removal")

        var renamed = row
        renamed["name"] = "Repository wiki"
        try config.updateNativeMCPServer(renamed)
        try check((disk.contents["native_mcp_servers"] as? [[String: Any]])?.first?["name"] as? String == "Repository wiki", "update should rename the written row")
        try await settle(manager) { manager.servers.first?.configuration.name == "Repository wiki" }
        try check(config.nativeSettings.enabledToolIDs.contains(toolID), "a rename should keep enabled tools")

        var broken = row
        broken["url"] = "http://mcp.example.com/mcp"
        do {
            try config.updateNativeMCPServer(broken)
            throw Failure(description: "an insecure address should be refused")
        } catch let error as NativeToolError {
            try check(!(error.errorDescription ?? "").isEmpty, "the refusal should carry a message")
        }
        try check((disk.contents["native_mcp_servers"] as? [[String: Any]])?.first?["url"] as? String == entry.url.absoluteString, "a refused update should not be written")

        try config.removeNativeMCPServer(id: id)
        try check(disk.contents["native_mcp_servers"] == nil, "removal should delete the row")
        try await settle(manager) { manager.servers.isEmpty }
        try check(!config.nativeSettings.enabledToolIDs.contains(toolID), "removal should prune the server's enabled tools")
        try check(config.nativeSettings.enabledToolIDs.contains("web-search"), "removal should keep unrelated enabled tools")
        let persisted = NativeChatSettings.load(from: disk.contents)
        try check(!persisted.enabledToolIDs.contains(toolID), "the pruned tool should not be persisted")

        for _ in 0..<8 {
            try config.addNativeMCPServer(catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"]))
        }
        let writesBefore = disk.writes
        do {
            try config.addNativeMCPServer(catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"]))
            throw Failure(description: "a ninth service should be refused")
        } catch let error as NativeToolError {
            try check(error.errorDescription?.contains("eight") == true, "the refusal should explain the limit")
        }
        try check(disk.writes == writesBefore && config.nativeMCPServerRows.count == 8, "a refused add should not write")
        try await settle(manager) { manager.servers.count == 8 }
    }
}
