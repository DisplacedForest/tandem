import Foundation
import GRDB

final class NativeCompanionWorkerRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var store: ChatStore?
    private var rules: NativeRuleSource?
    private var grants: NativeFolderGrantSource?
    private var extra: [NativeToolDefinition] = []

    var extraTools: [NativeToolDefinition] {
        get { lock.withLock { extra } }
        set { lock.withLock { extra = newValue } }
    }

    @MainActor
    func attach(_ store: ChatStore) {
        lock.withLock {
            self.store = store
            rules = store.nativeRuleSource
            grants = store.nativeGrantSource
        }
    }

    func environment(database: DatabaseQueue) -> NativeCompanionWorkerEnvironment {
        var environment = NativeCompanionWorkerEnvironment(
            context: { [weak self] _, connected in
                guard let store = self?.lock.withLock({ self?.store }) else { return nil }
                return await MainActor.run { store.companionWorkerContext(connectedToolIDs: connected) }
            },
            authority: { [weak self] conversation, request in
                let sources = self?.lock.withLock { (self?.rules, self?.grants) }
                guard let rules = sources?.0, let grants = sources?.1 else {
                    let closed = NativeRules(choices: Dictionary(uniqueKeysWithValues: NativeActionClass.allCases.map { ($0, NativeRuleChoice.handOff) }))
                    return NativeCompanionWorkerAuthority(resolver: NativeRuleResolver(global: closed, conversation: NativeConversationRules(),
                                                                                       requestText: request, revision: -1), grantsRevision: -1)
                }
                return NativeCompanionWorkerAuthority(resolver: rules.resolver(for: conversation, requestText: request), grantsRevision: grants.revision)
            },
            ledger: NativeEffectLedgerStore(database: database),
            tasks: NativeTaskStore(database: database))
        environment.preferences = { NativePreferenceStore(database: database).activeStatements() }
        environment.saveRules = { [weak self] records in
            let store = NativeRuleRecordStore(database: database)
            var saved = true
            for record in records where (try? store.add(record)) == nil { saved = false }
            if let rules = self?.lock.withLock({ self?.rules }) { ChatStore.reloadRules(rules, from: store) }
            DispatchQueue.main.async { NotificationCenter.default.post(name: .ruleRecordsChanged, object: nil) }
            return saved
        }
        environment.recordsChanged = { [weak self] in
            guard let rules = self?.lock.withLock({ self?.rules }) else { return }
            ChatStore.reloadRules(rules, from: NativeRuleRecordStore(database: database))
        }
        return environment
    }
}

extension ChatStore {
    nonisolated static func companionCommandDefinitions(grants: @escaping @Sendable () -> [FolderGrant]) -> [NativeToolDefinition] {
        NativeCommandTools.definitions(grants: grants, decision: .ask, reason: { _ in .rule }, record: { _ in })
    }

    func companionWorkerContext(connectedToolIDs: [String]?) -> NativeCompanionWorkerContext? {
        guard let threadID = veraThreadID else { return nil }
        var definitions = nativeSharedToolDefinitions
        let mcp = nativeMCP?.authority.definitions(scope: "worker") ?? []
        definitions.append(contentsOf: mcp)
        let rules = nativeRuleSource
        let source = nativeGrantSource
        definitions.append(contentsOf: NativeFolderTools.definitions(grants: { source.grants(for: threadID) }, ledger: NativeFileChangeLedger(),
                                                                     edits: .ask, trash: .ask, live: { action in
            rules.resolver(for: threadID, requestText: "").decision(for: action)
        }))
        definitions.append(contentsOf: Self.companionCommandDefinitions(grants: { source.grants(for: threadID) }))
        var enabled = enabledNativeToolIDs
        for server in nativeMCP?.servers ?? [] {
            for tool in server.tools where nativeMCP?.authority.access.allowed(tool, scope: "worker") == true { enabled.insert(tool.id) }
        }
        enabled = dotToolIDs(base: enabled)
        if let connectedToolIDs { enabled.formIntersection(connectedToolIDs) }
        let extra = companionWorkerRelay.extraTools
        definitions.append(contentsOf: extra)
        enabled.formUnion(extra.map(\.id))
        let tools = NativeToolRegistry(definitions: definitions).active(enabledIDs: enabled)
        return NativeCompanionWorkerContext(assistantName: companionName, threadID: threadID, tools: tools)
    }
}
