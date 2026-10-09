import Foundation

@MainActor
private final class WorkflowSelectionTransport {
    var requests: [URLRequest] = []
    private var pending: [Int: CheckedContinuation<(Data, Int), Error>] = [:]

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func wait(_ count: Int) async throws {
        for _ in 0..<10000 {
            if requests.count >= count { return }
            await Task.yield()
        }
        throw URLError(.timedOut)
    }

    func reply(_ index: Int, _ object: [String: Any], status: Int = 200) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let continuation = pending.removeValue(forKey: index) else { throw URLError(.badServerResponse) }
        continuation.resume(returning: (data, status))
    }

    func fail(_ index: Int) throws {
        guard let continuation = pending.removeValue(forKey: index) else { throw URLError(.badServerResponse) }
        continuation.resume(throwing: URLError(.cannotConnectToHost))
    }

    func close() {
        let remaining = pending.values
        pending.removeAll()
        for continuation in remaining { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
enum WorkflowSelectionTests {
    private static let base = URL(string: "https://workflow.invalid")!

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "WorkflowSelectionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func catalog(_ label: String) -> [String: Any] {
        ["nodes": [["type": "fixture.step", "label": label, "description": "A fixture step.", "category": "core"]],
         "profile": ["id": "generic", "spine": [], "insertable_categories": ["core"], "pairs": [], "triggers": []]]
    }

    private static func overview(_ flow: String, _ label: String, state: String = "active") -> [String: Any] {
        ["workflow": ["id": flow + "-" + label, "version": 1, "state": state,
                      "definition": ["id": flow, "nodes": [["id": label + "-step", "type": "fixture.step", "config": [:]]],
                                     "edges": [], "positions": [:]]],
         "latest_run": ["id": label + "-run", "state": "completed", "started_at": 1.0],
         "flow": ["label": label, "description": label + " description"]]
    }

    private static func store(_ transport: WorkflowSelectionTransport) -> WorkflowEditorStore {
        let store = WorkflowEditorStore { try await transport.send($0) }
        store.configure(base: base)
        return store
    }

    private static func complete(_ operation: Task<Void, Never>, _ transport: WorkflowSelectionTransport,
                                 start: Int, flow: String, label: String) async throws {
        try await transport.wait(start + 1)
        try require(transport.requests[start].url?.path == "/agentic/workflows/\(flow)/catalog", "Catalog must target the selected workflow")
        try transport.reply(start, catalog(label))
        try await transport.wait(start + 2)
        try require(transport.requests[start + 1].url?.path == "/agentic/workflows/\(flow)", "Overview must target the same workflow")
        try transport.reply(start + 1, overview(flow, label))
        await operation.value
    }

    private static func select(_ store: WorkflowEditorStore, _ transport: WorkflowSelectionTransport,
                               _ flow: String, _ label: String) async throws {
        let start = transport.requests.count
        let operation = Task { await store.select(flow) }
        try await complete(operation, transport, start: start, flow: flow, label: label)
    }

    private static func selected(_ store: WorkflowEditorStore, _ flow: String, _ label: String, catalogLabel: String? = nil) throws {
        try require(store.flowID == flow && store.phase == .ready && store.active?.id == flow + "-" + label,
                    "A response changed the selected workflow")
        try require(store.catalog?.nodes.first?.label == (catalogLabel ?? label) && store.flowFace?.label == label
                    && store.latestRun?.id == label + "-run" && !store.runStale && !store.runUnreadable,
                    "A response mixed workflow metadata or run state")
    }

    private static func idleAndRetry() async throws {
        let transport = WorkflowSelectionTransport()
        defer { transport.close() }
        let store = store(transport)
        await store.refresh()
        await store.refreshRun()
        try require(store.flowID.isEmpty && transport.requests.isEmpty, "Idle store must not poll a workflow")
        let first = Task { await store.select("pulse") }
        try await transport.wait(1)
        first.cancel()
        try transport.reply(0, catalog("canceled"))
        await first.value
        try require(store.catalog == nil && transport.requests.count == 1, "Canceled selection must not publish or continue")
        let retry = Task { await store.select("pulse") }
        try await transport.wait(2)
        try transport.reply(1, catalog("Pulse"))
        try await transport.wait(3)
        try require(store.catalog == nil && store.active == nil, "Catalog must wait for its overview")
        await store.refreshRun()
        try require(transport.requests.count == 3, "Run refresh must not supersede the initial catalog load")
        try transport.reply(2, overview("pulse", "Pulse"))
        await retry.value
        try selected(store, "pulse", "Pulse")
        store.draft = store.active
        await store.select("pulse")
        try require(transport.requests.count == 3 && store.draft != nil, "Ready same-flow selection must preserve its draft")
        let failed = Task { await store.refresh() }
        try await transport.wait(4)
        try transport.fail(3)
        await failed.value
        try require(store.phase == .unavailable, "Current refresh failure must remain visible")
        try await select(store, transport, "pulse", "Retried")
        try require(store.draft?.id == "pulse-Pulse", "Unavailable retry must preserve the local draft")
    }

    private static func switching(catalogHeld: Bool, failed: Bool, returnsToFirst: Bool) async throws {
        let transport = WorkflowSelectionTransport()
        defer { transport.close() }
        let store = store(transport)
        let old = Task { await store.select("pulse") }
        try await transport.wait(1)
        var held = 0
        if !catalogHeld {
            try transport.reply(0, catalog("Old"))
            try await transport.wait(2)
            held = 1
        }
        try await select(store, transport, "home", "Home")
        if returnsToFirst { try await select(store, transport, "pulse", "Current") }
        if failed { try transport.fail(held) }
        else { try transport.reply(held, catalogHeld ? catalog("Old") : overview("pulse", "Old")) }
        await old.value
        try selected(store, returnsToFirst ? "pulse" : "home", returnsToFirst ? "Current" : "Home")
        try require(store.note == nil && store.draft == nil && !store.busy, "Stale selection response changed editing state")
    }

    private static func configuration(catalogHeld: Bool, failed: Bool) async throws {
        let transport = WorkflowSelectionTransport()
        defer { transport.close() }
        let store = store(transport)
        let old = Task { await store.select("pulse") }
        try await transport.wait(1)
        var held = 0
        if !catalogHeld {
            try transport.reply(0, catalog("Old"))
            try await transport.wait(2)
            held = 1
        }
        store.configure(base: URL(string: "https://replacement.invalid")!)
        store.configure(base: base)
        try await select(store, transport, "pulse", "Configured")
        if failed { try transport.fail(held) }
        else { try transport.reply(held, catalogHeld ? catalog("Old") : overview("pulse", "Old")) }
        await old.value
        try selected(store, "pulse", "Configured")
        let run = Task { await store.refreshRun() }
        let index = transport.requests.count
        try await transport.wait(index + 1)
        store.configure(base: nil)
        try transport.fail(index)
        await run.value
        try require(store.phase == .unavailable && store.catalog == nil && store.active == nil && !store.runStale,
                    "Disconnected configuration accepted an old run failure")
        let count = transport.requests.count
        await store.refresh()
        await store.refreshRun()
        try require(transport.requests.count == count, "Disconnected configuration issued requests")
    }

    private static func responseOrdering(failed: Bool) async throws {
        let transport = WorkflowSelectionTransport()
        defer { transport.close() }
        let store = store(transport)
        try await select(store, transport, "pulse", "Initial")
        let old = Task { await store.refresh() }
        try await transport.wait(3)
        try transport.reply(2, catalog("Old"))
        try await transport.wait(4)
        try require(store.catalog?.nodes.first?.label == "Initial", "Partial refresh replaced a compatible catalog")
        let newer = Task { await store.refreshRun() }
        try await transport.wait(5)
        try transport.reply(4, overview("pulse", "LatestRun"))
        await newer.value
        if failed { try transport.fail(3) } else { try transport.reply(3, overview("pulse", "Old")) }
        await old.value
        try selected(store, "pulse", "LatestRun", catalogLabel: "Initial")
        let oldRun = Task { await store.refreshRun() }
        try await transport.wait(6)
        let refresh = Task { await store.refresh() }
        try await complete(refresh, transport, start: 6, flow: "pulse", label: "LatestPair")
        if failed { try transport.fail(5) } else { try transport.reply(5, overview("pulse", "OldRun")) }
        await oldRun.value
        try selected(store, "pulse", "LatestPair")
        let failedPair = Task { await store.refresh() }
        try await transport.wait(9)
        try transport.reply(8, catalog("Unpaired"))
        try await transport.wait(10)
        try transport.fail(9)
        await failedPair.value
        try require(store.phase == .unavailable && store.catalog?.nodes.first?.label == "LatestPair"
                    && store.active?.id == "pulse-LatestPair", "Overview failure published an unpaired catalog")
    }

    private static func staleRun(failed: Bool, reconfigure: Bool) async throws {
        let transport = WorkflowSelectionTransport()
        defer { transport.close() }
        let store = store(transport)
        try await select(store, transport, "pulse", "Initial")
        let old = Task { await store.refreshRun() }
        try await transport.wait(3)
        if reconfigure {
            store.configure(base: URL(string: "https://replacement.invalid")!)
            try await select(store, transport, "pulse", "Current")
            try require(transport.requests[3].url?.host == "replacement.invalid", "Configured base was not used")
        } else {
            try await select(store, transport, "home", "Home")
            try await select(store, transport, "pulse", "Current")
        }
        if failed { try transport.fail(2) } else { try transport.reply(2, overview("pulse", "Old")) }
        await old.value
        try selected(store, "pulse", "Current")
    }

    private static func draftAndSave(failed: Bool, saving: Bool) async throws {
        let transport = WorkflowSelectionTransport()
        defer { transport.close() }
        let store = store(transport)
        try await select(store, transport, "pulse", "Initial")
        if saving { store.draft = store.active }
        let old = Task { if saving { await store.save() } else { await store.beginDraft() } }
        try await transport.wait(3)
        try await select(store, transport, "home", "Home")
        let current = Task { await store.beginDraft() }
        try await transport.wait(6)
        if failed { try transport.fail(2) } else { try transport.reply(2, overview("pulse", "OldDraft", state: "draft")) }
        await old.value
        try require(store.busy && store.draft == nil && store.note == nil, "Old mutation changed the current operation")
        try transport.reply(5, overview("home", "CurrentDraft", state: "draft"))
        await current.value
        try require(!store.busy && store.draft?.id == "home-CurrentDraft", "Current draft did not finish")
    }

    private static func promote(failed: Bool, savedFirst: Bool) async throws {
        let transport = WorkflowSelectionTransport()
        defer { transport.close() }
        let store = store(transport)
        try await select(store, transport, "pulse", "Initial")
        store.draft = store.active
        let old = Task { await store.promote() }
        try await transport.wait(3)
        var held = 2
        if savedFirst {
            try transport.reply(2, overview("pulse", "Saved", state: "draft"))
            try await transport.wait(4)
            try require(transport.requests[3].url?.path == "/agentic/workflow-drafts/pulse-Saved/promote", "Promotion did not use the saved draft")
            held = 3
        }
        try await select(store, transport, "home", "Current")
        let count = transport.requests.count
        if failed { try transport.fail(held) } else { try transport.reply(held, overview("pulse", "Promoted")) }
        await old.value
        try selected(store, "home", "Current")
        try require(transport.requests.count == count && store.draft == nil && store.note == nil && !store.busy,
                    "Old promotion published or dispatched follow-up work")
    }

    private static func delayedPlacement() async throws {
        let transport = WorkflowSelectionTransport()
        defer { transport.close() }
        let store = store(transport)
        try await select(store, transport, "pulse", "Initial")
        let old = Task { await store.placeNode("fixture.step", at: CGPoint(x: 300, y: 300)) }
        try await transport.wait(3)
        try await select(store, transport, "home", "Current")
        store.draft = store.active
        let current = store.draft
        try transport.reply(2, overview("pulse", "OldDraft", state: "draft"))
        await old.value
        try require(store.draft == current && store.note == nil, "Old node placement edited the new workflow")
    }

    static func run() async throws {
        try await idleAndRetry()
        for failed in [false, true] {
            for catalogHeld in [false, true] {
                for returnsToFirst in [false, true] {
                    try await switching(catalogHeld: catalogHeld, failed: failed, returnsToFirst: returnsToFirst)
                }
                try await configuration(catalogHeld: catalogHeld, failed: failed)
            }
            try await responseOrdering(failed: failed)
            for reconfigure in [false, true] { try await staleRun(failed: failed, reconfigure: reconfigure) }
            for saving in [false, true] { try await draftAndSave(failed: failed, saving: saving) }
            for savedFirst in [false, true] { try await promote(failed: failed, savedFirst: savedFirst) }
        }
        try await delayedPlacement()
        for locked in [WorkflowEditorStore.lockedFixture(), WorkflowEditorStore.veinFixture()] {
            try require(!locked.canvasHint.contains("port"), "Active locked fixture advertised connections")
            locked.draft = locked.active
            try require(locked.canvasHint == "Drag to arrange · select a node to adjust its settings", "Locked snapshot hint differs from live editing")
        }
        print("  workflow selection OK (idle, Pulse, stale responses, endpoint changes, ordering, mutations and locked hints)")
    }
}
