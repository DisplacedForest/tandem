import Foundation

@MainActor
enum NativeMCPStandingPermissionSelftest {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NativeToolError.failed(message) }
    }

    static func definition(_ manager: NativeMCPManager, _ id: String, _ name: String, scope: String = "focused") throws -> NativeToolDefinition {
        guard let server = manager.servers.first(where: { $0.id == id }),
              let tool = manager.authority.definitions(scope: scope).first(where: { $0.id == server.configuration.toolID(name) }) else {
            throw NativeToolError.failed("The fixture permission tool is missing")
        }
        return tool
    }

    static func ruled(_ definition: NativeToolDefinition, rules: NativeRuleSource = NativeRuleSource()) -> NativeToolDefinition {
        ChatStore.ruled(definition, rules: rules, store: nil, conversationID: "fixture-conversation", requestText: "Update the fixture")
    }

    static func run() async throws {
        let tools = [NativeMCPChangesSelftest.tool("read_item", readOnly: true),
                     NativeMCPChangesSelftest.tool("update_item", readOnly: false),
                     NativeMCPChangesSelftest.tool("dispatch_change", readOnly: false)]
        let endpoint = URL(string: "https://permissions.example/mcp")!
        let connection = NativeMCPChangesConnection(tools)
        let keys = NativeCredentialFixtureStore()
        let manager = NativeMCPManager(servers: [], authenticatedFactory: { _, _ in connection }, tokens: keys)
        let disk = NativeMCPInstallSelftest.Disk()
        let config = ConfigStore(credentialStore: keys, readConfiguration: { disk.contents }, nativeMCP: manager, writeConfiguration: { next in
            if disk.failing?(next) == true { throw NativeToolError.failed("Synthetic save failure") }
            disk.contents = next
        })
        let draft = NativeMCPInstallDraft(entry: .own, factory: { _, _ in connection })
        draft.values = ["name": "Fixture service", "address": endpoint.absoluteString]
        await draft.check()
        try require(draft.canInstall && draft.permissions.isEmpty && draft.offTools.isEmpty, "Setup never infers trust from discovery")
        draft.permissions.tools = ["update_item"]
        draft.offTools = ["read_item"]
        await draft.install(config)?.value
        try require(draft.step == .installed, "Setup saves the selected tool permission")
        let id = draft.id
        let selected = try definition(manager, id, "update_item")
        let dispatcher = try definition(manager, id, "dispatch_change")
        try require(selected.connectionPermission?() == true && dispatcher.connectionPermission?() == false, "Selected permission covers only that tool")
        try require(manager.authority.definitions(scope: "focused").allSatisfy { !$0.title.hasSuffix("read_item") }, "A disabled setup tool is unavailable")
        try require(ruled(selected).confirmationFor?([:]) == false && ruled(dispatcher).confirmationFor?([:]) == true,
                    "Setup choices govern the foreground approval gate")
        _ = try await ruled(selected).execute([:])
        try require(connection.count("update_item") == 1, "A permitted foreground change executes without a confirmation")
        let worker = try definition(manager, id, "update_item", scope: IntegrationsText.ownWorkScope)
        let base = NativeRuleResolver(global: .defaults, conversation: NativeConversationRules(), requestText: "Update the fixture")
        try require(NativeCompanionWorker.ruleDecision(worker, [:], resolver: base, honoringLimitedUse: false).decision == .act(.grant),
                    "The delegated gate uses the same saved setup permission")
        try require(NativeReadOnlyRun.refusal(run: NativeRunOrigin(mode: "scheduled", scheduleID: "fixture"),
                    call: NativeRunCall(toolID: worker.id, function: worker.name, effect: worker.effect)) != nil,
                    "Setup permission never changes the unattended write boundary")

        let rules = NativeRuleSource()
        rules.setRecords([NativeRuleRecord(action: .serviceChanges, toolID: selected.id, effect: .forbid, statement: "Never update the fixture")])
        try require(ruled(selected, rules: rules).chatDecision?([:]).decision == .handOff, "A saved never wins over setup permission")
        try require(NativeCompanionWorker.ruleDecision(worker, [:], resolver: rules.resolver(for: "fixture-conversation", requestText: ""),
                    honoringLimitedUse: false).decision == .handOff, "A saved never also wins in delegated work")
        rules.setRecords([NativeRuleRecord(action: .serviceChanges, toolID: selected.id, effect: .ask, statement: "Ask before updating the fixture")])
        try require(ruled(selected, rules: rules).confirmationFor?([:]) == true, "A saved ask wins over setup permission")
        rules.setRecords([])
        rules.set(NativeConversationRules(choices: [.serviceChanges: .ask]), for: "fixture-conversation")
        try require(ruled(selected, rules: rules).confirmationFor?([:]) == true, "An explicit conversation restriction wins")
        let failed = NativeRuleSource()
        failed.fail()
        try require(ruled(selected, rules: failed).confirmationFor?([:]) == true, "Unreadable rules cannot be bypassed by setup permission")

        guard var row = config.nativeMCPServerRows.first else { throw NativeToolError.failed("The saved fixture is missing") }
        row = NativeMCPStandingPermission(all: true).applying(to: row)
        try config.updateNativeMCPServer(row)
        try require(!selected.isAvailable(), "Changing grants invalidates already-advertised tool definitions")
        try await NativeMCPAuthoritySelftest.reject { _ = try await selected.execute([:]) }
        let broad = try definition(manager, id, "dispatch_change")
        try require(ruled(broad).confirmationFor?([:]) == false, "Whole-service permission includes dispatcher tools")
        _ = try await ruled(broad).execute([:])
        try require(connection.count("dispatch_change") == 1, "A permitted dispatcher executes once")
        await connection.set(tools + [NativeMCPChangesSelftest.tool("new_action", readOnly: false)])
        await manager.disconnect(id)
        try require(!broad.isAvailable(), "Disconnect immediately invalidates usable permission")
        await manager.connect(id)
        try require(try definition(manager, id, "new_action").connectionPermission?() == true, "Whole-service permission includes newly discovered tools")
        try require(manager.authority.definitions(scope: "focused").allSatisfy { !$0.title.hasSuffix("read_item") }, "Whole-service permission does not enable a disabled tool")

        let restartedConnection = NativeMCPChangesConnection(tools)
        let restarted = ConfigStore(credentialStore: keys, readConfiguration: { disk.contents },
            nativeMCP: NativeMCPManager(servers: [], authenticatedFactory: { _, _ in restartedConnection }, tokens: keys),
            writeConfiguration: { disk.contents = $0 })
        let reloaded = NativeMCPServerConfiguration.load(restarted.raw).0
        try require(reloaded.first?.permissions.all == true, "Saved setup permission survives configuration reload")
        let retired = restarted.nativeMCP.applyConfigurationSynchronously(reloaded)
        await restarted.nativeMCP.retireConfiguration(retired)
        await restarted.nativeMCP.connect(id)
        try require(try definition(restarted.nativeMCP, id, "dispatch_change").connectionPermission?() == true, "Reloaded permission reaches live authority")
        await restarted.nativeMCP.disconnect(id)

        row = config.nativeMCPServerRows[0]
        row["name"] = "Renamed fixture"
        try config.updateNativeMCPServer(row)
        try require(try definition(manager, id, "dispatch_change").connectionPermission?() == true, "A name edit keeps the grant")
        let beforeFailure = try definition(manager, id, "dispatch_change")
        disk.failing = { _ in true }
        do {
            try config.updateNativeMCPServer(NativeMCPStandingPermission().applying(to: config.nativeMCPServerRows[0]))
            throw NativeToolError.failed("The fixture write should fail")
        } catch {
            try require(beforeFailure.connectionPermission?() == true, "A failed configuration write preserves existing authority")
        }
        disk.failing = nil
        try config.updateNativeMCPServer(NativeMCPStandingPermission().applying(to: config.nativeMCPServerRows[0]))
        try require(!beforeFailure.isAvailable(), "Revocation invalidates a previously planned call")
        try await NativeMCPAuthoritySelftest.reject { _ = try await beforeFailure.execute([:]) }
        try require(ruled(try definition(manager, id, "dispatch_change")).confirmationFor?([:]) == true, "After revocation the same tool asks again")
        try require(connection.count("dispatch_change") == 1, "Revocation prevented dispatch before any side effect")

        row = NativeMCPStandingPermission(all: true).applying(to: config.nativeMCPServerRows[0])
        try config.updateNativeMCPServer(row)
        let old = try definition(manager, id, "dispatch_change")
        row["url"] = "https://replacement.example/mcp"
        try config.updateNativeMCPServer(row)
        try require(!old.isAvailable() && manager.servers.first?.configuration.permissions.isEmpty == true,
                    "Changing the address removes setup authority before another call")
        try require(config.nativeMCPServerRows[0]["permissions"] == nil, "The old setup grant is removed from saved state")
        var copied = NativeMCPStandingPermission(all: true).applying(to: ["id": id, "name": "Fixture", "url": endpoint.absoluteString])
        copied["url"] = "https://other.example/mcp"
        try require(NativeMCPServerConfiguration.load(["native_mcp_servers": [copied]]).0.first?.permissions.isEmpty == true,
                    "A copied policy cannot follow an edited address in the config file")
        copied["permissions"] = ["all": true]
        try require(NativeMCPServerConfiguration.load(["native_mcp_servers": [copied]]).1 != nil, "Malformed policy fails closed")
        try config.removeNativeMCPServer(id: id)
        try require(manager.servers.isEmpty, "Removing the service removes its authority")
        print("NATIVE MCP SETUP PERMISSIONS SELFTEST OK")
    }
}
