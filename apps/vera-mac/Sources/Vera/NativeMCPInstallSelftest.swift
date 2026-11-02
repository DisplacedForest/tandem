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

        try await runScopeNarrowing(catalog: catalog, entry: entry)
        try await runReconcile(catalog: catalog, entry: entry)
        try await runFailedWrite(catalog: catalog, entry: entry)
    }

    static let schema: NativeJSONValue = .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("string"), "maxLength": .number(200)])]),
        "additionalProperties": .bool(false),
    ])

    @MainActor
    @discardableResult
    static func markConnected(_ manager: NativeMCPManager, id: String) throws -> NativeMCPToolRecord {
        guard var state = manager.authority.access.snapshot().first(where: { $0.id == id }),
              let name = state.configuration.readTools.sorted().first else { throw Failure(description: "server \(id) is not configured") }
        let record = NativeMCPToolRecord(id: state.configuration.toolID(name), server: state.configuration, generation: state.generation, remoteName: name,
                                         description: "Synthetic read.", schema: schema, validator: try? NativeMCPJSONSchema(schema), reason: nil)
        state.connected = true
        state.status = "Connected"
        state.tools = [record]
        guard manager.authority.access.update(state) else { throw Failure(description: "could not mark \(id) connected") }
        manager.refresh()
        return record
    }

    @MainActor
    static func store(_ disk: Disk, _ manager: NativeMCPManager) -> ConfigStore {
        ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents }, nativeMCP: manager,
                    writeConfiguration: { disk.contents = $0; disk.writes += 1 })
    }

    @MainActor
    static func runScopeNarrowing(catalog: NativeMCPStarterCatalog, entry: NativeMCPStarterEntry) async throws {
        let disk = Disk()
        let manager = NativeMCPManager(servers: [])
        let config = store(disk, manager)
        let row = catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused", "worker"])
        guard let id = row["id"] as? String else { throw Failure(description: "row has no id") }
        try config.addNativeMCPServer(row)
        try await settle(manager) { manager.servers.map(\.id) == [id] }
        let record = try markConnected(manager, id: id)
        config.setNativeTool(record.id, enabled: true)
        let access = manager.authority.access
        try check(access.allowed(record, scope: "worker") && access.allowed(record, scope: "focused"), "the tool should start allowed in both scopes")
        let revision = access.permissionRevision()
        var narrowed = row
        narrowed["scopes"] = ["focused"]
        try config.updateNativeMCPServer(narrowed)
        try check(!access.allowed(record, scope: "worker"), "narrowing should revoke the worker scope before any await")
        try check(access.allowed(record, scope: "focused"), "narrowing should keep the focused scope")
        try check(!access.allowed(record, scope: "focused", revision: revision), "a call holding the old revision should fail closed")
        try check(access.snapshot().first?.connected == true, "narrowing should keep the connection")
        try check(config.nativeSettings.enabledToolIDs.contains(record.id), "narrowing should keep consent")
        await manager.authority.permissionsChanged()
        try check(!access.allowed(record, scope: "worker"), "the worker scope should stay revoked")
    }

    @MainActor
    static func runReconcile(catalog: NativeMCPStarterCatalog, entry: NativeMCPStarterEntry) async throws {
        let disk = Disk()
        let manager = NativeMCPManager(servers: [])
        let config = store(disk, manager)
        let first = catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"])
        let second = catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"])
        guard let firstID = first["id"] as? String, let secondID = second["id"] as? String else { throw Failure(description: "rows have no ids") }
        try config.addNativeMCPServer(first)
        try config.addNativeMCPServer(second)
        try await settle(manager) { manager.servers.count == 2 }
        try markConnected(manager, id: firstID)
        try markConnected(manager, id: secondID)
        let access = manager.authority.access
        guard let firstGeneration = access.snapshot().first(where: { $0.id == firstID })?.generation,
              let secondGeneration = access.snapshot().first(where: { $0.id == secondID })?.generation else { throw Failure(description: "missing states") }

        try config.addNativeMCPServer(catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"]))
        try await settle(manager) { manager.servers.count == 3 }
        await manager.authority.permissionsChanged()
        let afterAdd = access.snapshot()
        try check(afterAdd.first(where: { $0.id == firstID }).map { $0.connected && $0.generation == firstGeneration && $0.tools.count == 1 } == true, "adding a service should keep the first connection")
        try check(afterAdd.first(where: { $0.id == secondID }).map { $0.connected && $0.generation == secondGeneration } == true, "adding a service should keep the second connection")
        try check(afterAdd.last?.connected == false, "a new service should start disconnected")

        var moved = second
        moved["url"] = "https://mcp.example.com/mcp"
        try config.updateNativeMCPServer(moved)
        let afterUpdate = access.snapshot()
        try check(afterUpdate.first(where: { $0.id == firstID }).map { $0.connected && $0.generation == firstGeneration } == true, "updating the second service should leave the first connected")
        try check(afterUpdate.first(where: { $0.id == secondID }).map { !$0.connected && $0.tools.isEmpty && $0.generation != secondGeneration } == true, "updating the second service address should disconnect it")
        try await settle(manager) { manager.servers.first(where: { $0.id == secondID })?.configuration.endpoint.host == "mcp.example.com" }
        try check(manager.servers.first(where: { $0.id == firstID })?.connected == true, "the first service should stay connected after teardown")
    }

    @MainActor
    final class FlakyDisk {
        var contents: [String: Any] = [:]
        var failures = 0
    }

    struct WriteFailure: Error {}

    @MainActor
    static func runFailedWrite(catalog: NativeMCPStarterCatalog, entry: NativeMCPStarterEntry) async throws {
        let disk = FlakyDisk()
        let manager = NativeMCPManager(servers: [])
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents }, nativeMCP: manager,
                                 writeConfiguration: { value in
                                     if disk.failures > 0 { disk.failures -= 1; throw WriteFailure() }
                                     disk.contents = value
                                 })
        let row = catalog.configurationRow(for: entry, readTools: entry.readTools, scopes: ["focused"])
        guard let id = row["id"] as? String else { throw Failure(description: "row has no id") }
        try config.addNativeMCPServer(row)
        try await settle(manager) { manager.servers.map(\.id) == [id] }
        let record = try markConnected(manager, id: id)
        config.setNativeTool(record.id, enabled: true)
        try config.save()
        func persisted() -> (Bool, Bool) {
            let rows = disk.contents["native_mcp_servers"] as? [[String: Any]] ?? []
            return (rows.contains { $0["id"] as? String == id }, NativeChatSettings.load(from: disk.contents).enabledToolIDs.contains(record.id))
        }
        try check(persisted() == (true, true), "the row and consent should be saved before removal")

        disk.failures = 1
        do {
            try config.removeNativeMCPServer(id: id)
            throw Failure(description: "a failed write should fail the removal")
        } catch is NativeToolError {}
        try check(config.nativeMCPServerRows.contains { $0["id"] as? String == id }, "a failed removal should keep the row in memory")
        try check(config.nativeSettings.enabledToolIDs.contains(record.id), "a failed removal should keep consent in memory")
        try check(persisted() == (true, true), "a failed removal should leave the file untouched")
        try check(manager.authority.access.allowed(record, scope: "focused"), "a failed removal should leave the connection authorized")

        try config.removeNativeMCPServer(id: id)
        try check(config.nativeMCPServerRows.isEmpty && !config.nativeSettings.enabledToolIDs.contains(record.id), "a second removal should clear memory")
        try check(persisted() == (false, false), "a second removal should clear the row and consent in one write")
        try check(!manager.authority.access.allowed(record, scope: "focused"), "removal should revoke access immediately")
        try await settle(manager) { manager.servers.isEmpty }
    }
}
