import Foundation

@MainActor
enum CapabilitySelfTest {
    static func run(root: URL) async throws {
        let legacy: [String: Any] = ["protocol_version": 1, "foreground": true, "worker": true, "computers": false, "transport": "mock"]
        var fixture = legacy
        fixture["transport_detail"] = "app-owned-provider-fixture"
        fixture["provider"] = "fixture"
        fixture["model"] = "qwen/qwen3.8-flash"
        var cloud = legacy
        cloud["transport"] = "cloud"
        cloud["transport_detail"] = "app-owned-openrouter"
        cloud["provider"] = "openrouter"
        cloud["model"] = "qwen/qwen3.8-flash"
        var oldNativeMock = legacy
        oldNativeMock["transport_detail"] = "native-mock"
        let valid: [(String, [String: Any], String)] = [
            ("legacy", legacy, "Test runtime"), ("provider-fixture", fixture, "Test runtime"),
            ("native-mock-detail", oldNativeMock, "Test runtime"), ("cloud", cloud, "Cloud model")
        ]
        let endpoint = URL(string: "http://127.0.0.1:49155")!
        try PrototypeSelfTest.require(Capabilities.encodedByteCount("a\"b\nc\u{1}\u{1F600}") == 17, "Encoded byte count matches the runtime's JSON measure")
        var bounded = legacy
        bounded["message_bytes"] = 16
        do {
            let transport = ContractFixture()
            await transport.advertise(try JSONSerialization.data(withJSONObject: bounded))
            let store = try PrototypeStore(configuration: PrototypeConfiguration(dataRoot: root.appendingPathComponent("bounded"), endpoint: endpoint, workspaceRoot: nil),
                                           client: PrototypeClient(base: endpoint) { try await transport.send($0) })
            await transport.bind(store.saved.assistantID, store.saved.assistant.id)
            await store.refresh()
            try PrototypeSelfTest.require(store.canSend && store.accepts("sixteen bytes xx") && !store.accepts("seventeen bytes x") && !store.accepts("twelve\u{1F600}\u{1F600}\u{1F600}"),
                                          "Composer limit follows the advertised message budget")
            store.setDraft("seventeen bytes x")
            await store.send()
            try PrototypeSelfTest.require(await transport.requests.isEmpty, "Oversized draft never leaves the composer")
            store.setDraft("sixteen bytes xx")
            await store.send()
            try PrototypeSelfTest.require(await transport.requests.count == 1, "Draft inside the budget is sent")
        }
        for (name, payload, label) in valid {
            let transport = ContractFixture()
            await transport.advertise(try JSONSerialization.data(withJSONObject: payload))
            let store = try PrototypeStore(configuration: PrototypeConfiguration(dataRoot: root.appendingPathComponent(name), endpoint: endpoint, workspaceRoot: nil),
                                           client: PrototypeClient(base: endpoint) { try await transport.send($0) })
            await transport.bind(store.saved.assistantID, store.saved.assistant.id)
            await store.refresh()
            try PrototypeSelfTest.require(store.canSend && store.connectionLabel == label, "Supported capability label: " + name)
            store.setDraft("Fixture-only capability check")
            await store.send()
            let requests = await transport.requests
            try PrototypeSelfTest.require(store.pending == nil && requests.count == 1, "Supported mode uses injected sender: " + name)
            store.setDraft("Interrupted fixture reply")
            await transport.interruptNextMessage()
            await store.send()
            await store.reviewUnconfirmedReply()
            try PrototypeSelfTest.require(store.canAbandonReply && store.connectionLabel == label,
                                          "Supported capability permits explicit recovery review: " + name)
        }
        var invalid: [(String, [String: Any])] = []
        for key in ["transport_detail", "provider", "model"] {
            var missing = cloud
            missing.removeValue(forKey: key)
            invalid.append(("missing-" + key, missing))
            var mismatch = cloud
            mismatch[key] = "unsupported"
            invalid.append(("mismatched-" + key, mismatch))
            var null = cloud
            null[key] = NSNull()
            invalid.append(("null-" + key, null))
            var wrongType = cloud
            wrongType[key] = 12
            invalid.append(("nonstring-" + key, wrongType))
        }
        for value in ["", "unknown", "native-mock", "app-owned-mock", "Cloud"] {
            var unknown = cloud
            unknown["transport"] = value
            invalid.append(("unknown-" + value, unknown))
        }
        var mismatch = cloud
        mismatch["provider"] = "fixture"
        mismatch["transport_detail"] = "app-owned-provider-fixture"
        invalid.append(("fixture-advertised-as-cloud", mismatch))
        for (name, payload) in [("mock", legacy), ("cloud", cloud)] {
            var unsupportedVersion = payload
            unsupportedVersion["protocol_version"] = 2
            invalid.append(("protocol-" + name, unsupportedVersion))
        }
        for (name, payload) in invalid {
            let transport = ContractFixture()
            let good = try JSONSerialization.data(withJSONObject: legacy)
            let bad = try JSONSerialization.data(withJSONObject: payload)
            await transport.advertise(good)
            let store = try PrototypeStore(configuration: PrototypeConfiguration(dataRoot: root.appendingPathComponent("invalid-" + name), endpoint: endpoint, workspaceRoot: nil),
                                           client: PrototypeClient(base: endpoint) { try await transport.send($0) })
            await transport.bind(store.saved.assistantID, store.saved.assistant.id)
            await store.refresh()
            try PrototypeSelfTest.require(store.canSend, "Fixture starts connected")
            await transport.advertise(bad)
            await store.refresh()
            store.setDraft("Must not send")
            await store.send()
            let rejectedRequests = await transport.requests
            try PrototypeSelfTest.require(!store.canSend && store.connectionError != nil && store.connectionLabel == "Not connected"
                                          && rejectedRequests.isEmpty && store.pending == nil, "Invalid capability blocks Send: " + name)
            await transport.advertise(good)
            await store.refresh()
            await transport.interruptNextMessage()
            await store.send()
            guard let original = store.pending else { throw PrototypeError.invalidResponse }
            let originalTasks = Set(store.visibleTasks.map(\.id))
            let reopened = try PrototypeStore(configuration: store.configuration, client: store.client)
            await reopened.retry()
            let unvalidatedRequests = await transport.requests
            try PrototypeSelfTest.require(reopened.capabilities == nil && reopened.pending?.messageID == original.messageID
                                          && unvalidatedRequests.count == 1, "Restart retry waits for validated capabilities: " + name)
            await transport.advertise(bad)
            await store.reviewUnconfirmedReply()
            store.abandonUnconfirmedReply()
            await store.retry()
            let requests = await transport.requests
            try PrototypeSelfTest.require(!store.canAbandonReply && store.connectionError != nil && store.connectionLabel == "Not connected"
                                          && store.pending?.messageID == original.messageID && requests.count == 1
                                          && Set(store.visibleTasks.map(\.id)) == originalTasks,
                                          "Invalid recovery capability preserves pending work without requests: " + name)
            await transport.advertise(good)
            await store.reviewUnconfirmedReply()
            try PrototypeSelfTest.require(store.canAbandonReply, "Supported capability restores explicit review: " + name)
        }
        print("PASS: strict cloud metadata, truthful mock/cloud labels, legacy mock compatibility, invalid capabilities block Send and recovery")
    }
}
