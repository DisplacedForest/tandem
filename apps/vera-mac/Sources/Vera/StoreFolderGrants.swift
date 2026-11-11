import Foundation

final class NativeFolderGrantSource: @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [String: [FolderGrant]] = [:]
    private var revisionValue = 0

    var revision: Int {
        lock.lock(); defer { lock.unlock() }
        return revisionValue
    }

    func set(_ value: [FolderGrant], for conversationID: String) {
        lock.lock(); defer { lock.unlock() }
        let next: [FolderGrant]? = value.isEmpty ? nil : value
        guard grants[conversationID] != next else { return }
        grants[conversationID] = next
        revisionValue += 1
    }

    func grants(for conversationID: String) -> [FolderGrant] {
        lock.lock(); defer { lock.unlock() }
        return grants[conversationID] ?? []
    }

    func replaceAll(_ conversations: [Conversation]) {
        lock.lock(); defer { lock.unlock() }
        let next = Dictionary(uniqueKeysWithValues: conversations.filter { !$0.grants.isEmpty }.map { ($0.id, $0.grants) })
        guard grants != next else { return }
        grants = next
        revisionValue += 1
    }
}

final class NativeCommandReasonSource: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String: NativeRuleReason] = [:]

    func set(_ reason: NativeRuleReason, for activityID: String) {
        lock.lock(); defer { lock.unlock() }
        reasons[activityID] = reason
    }

    func reason(for activityID: String) -> NativeRuleReason? {
        lock.lock(); defer { lock.unlock() }
        return reasons[activityID]
    }

    func clear(prefix: String) {
        lock.lock(); defer { lock.unlock() }
        reasons = reasons.filter { !$0.key.hasPrefix(prefix) }
    }
}

final class NativeDeclineSource: @unchecked Sendable {
    private let lock = NSLock()
    private var declined: [UUID: Set<String>] = [:]

    func record(_ key: String, turn: UUID) {
        lock.lock(); defer { lock.unlock() }
        declined[turn, default: []].insert(key)
    }

    func contains(_ key: String, turn: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return declined[turn]?.contains(key) ?? false
    }

    func clear(turn: UUID) {
        lock.lock(); defer { lock.unlock() }
        declined.removeValue(forKey: turn)
    }
}

extension ChatStore {
    var selectedGrants: [FolderGrant] { selected?.grants ?? [] }
    var selectedConversationRules: NativeConversationRules { selected?.rules ?? NativeConversationRules() }

    var folderToolsSupported: Bool { activeCapabilityResolution?.profile.supportsTools ?? false }

    var folderToolsUnsupportedReason: String? {
        guard let resolution = activeCapabilityResolution else { return "No model is set up, so a shared folder couldn't be used yet." }
        guard !resolution.profile.supportsTools else { return nil }
        let model = currentNativeConfig?.model ?? "This model"
        return "\(model) can't call tools, so it can't read or change files. Pick a model with tool calling in Settings, Model, or adjust this model's capabilities there."
    }

    func grants(for conversationID: String) -> [FolderGrant] {
        guard conversations.contains(where: { $0.id == conversationID }) else { return nativeGrantSource.grants(for: conversationID) }
        return effectiveGrants(for: conversationID)
    }

    func folderToolDefinitions(for conversationID: String, ledger: NativeFileChangeLedger,
                               edits: NativeRuleDecision = .act(.rule), trash: NativeRuleDecision = .ask,
                               live: @escaping @Sendable (NativeActionClass) -> NativeRuleDecision? = { _ in nil },
                               liveTargets: (@Sendable (NativeActionClass, [[NativeRuleTarget]]) -> NativeRuleVerdict?)? = nil,
                               instruction: (@Sendable (NativeActionClass, [[NativeRuleTarget]], String) -> NativeInstructionPending?)? = nil,
                               alwaysAvailable: Bool = false) -> [NativeToolDefinition] {
        let source = nativeGrantSource
        return NativeFolderTools.definitions(grants: { source.grants(for: conversationID) }, ledger: ledger,
                                             edits: edits, trash: trash, live: live, liveTargets: liveTargets, instruction: instruction,
                                             alwaysAvailable: alwaysAvailable)
    }

    func commandToolDefinitions(for turn: NativeConversationTurn, decision: NativeRuleDecision,
                                record: @escaping @Sendable (NativeCommandRun) -> Void,
                                alwaysAvailable: Bool = false) -> [NativeToolDefinition] {
        let source = nativeGrantSource
        let conversationID = turn.conversationID
        let reasons = turnCommandReasonSource
        let rules = nativeRuleSource
        let records = nativeRuleRecordStore
        let declines = turnDeclineSource
        let turnID = turn.id
        let scope = Self.scopedBlockID("", turn: turn)
        let typed = typedWords(for: turn)
        let uses = turnInstructionUses(for: turn)
        let closures = Self.commandLive(rules, store: records, conversationID: conversationID, requestText: typed.said, typed: typed, uses: uses)
        return NativeCommandTools.definitions(grants: { source.grants(for: conversationID) }, decision: decision,
                                              reason: { reasons.reason(for: scope + $0) }, record: record,
                                              live: closures.live, liveTargets: closures.liveTargets,
                                              instruction: { command, action, subjects, about in
                                                  Self.commandInstruction(rules, store: records, conversationID: conversationID, requestText: typed.said,
                                                                          typed: typed, uses: uses, command: command, action: action, subjects: subjects,
                                                                          about: about)
                                              },
                                              declined: { declines.contains($0, turn: turnID) },
                                              alwaysAvailable: alwaysAvailable)
    }

    nonisolated static func commandResolver(_ rules: NativeRuleSource, conversationID: String, requestText: String, typed: NativeTypedWords,
                                            uses: NativeInstructionUses?, command: String, action: NativeActionClass,
                                            subjects: [[NativeRuleTarget]]) -> NativeRuleResolver {
        var resolver = rules.resolver(for: conversationID, requestText: requestText, typed: typed).tool(NativeCommandTools.toolID, subjects: subjects)
        resolver.uses = uses
        if action == .commands, NativeCommandPrefix.isSimple(command) { resolver.asked = NativeInstructionClaim(verbs: NativeCommandTools.verbs) }
        return resolver
    }

    nonisolated static func commandDecision(_ rules: NativeRuleSource, store: NativeRuleRecordStore? = nil, conversationID: String,
                                            requestText: String, typed: NativeTypedWords = .none, uses: NativeInstructionUses? = nil,
                                            command: String, action: NativeActionClass,
                                            subjects: [[NativeRuleTarget]]) -> NativeRuleVerdict {
        let resolver = commandResolver(rules, conversationID: conversationID, requestText: requestText, typed: typed, uses: uses,
                                       command: command, action: action, subjects: subjects)
        let result = judged(resolver, action: action, command: action == .commands ? command : nil, store: store)
        return verdict(result.decided.decision, authorizing: result.decided.authorizedBy, resolver: resolver, rules: rules, store: store,
                       why: result.decided.why, spending: result.spending)
    }

    nonisolated static func commandInstruction(_ rules: NativeRuleSource, store: NativeRuleRecordStore? = nil, conversationID: String,
                                               requestText: String, typed: NativeTypedWords = .none, uses: NativeInstructionUses? = nil,
                                               command: String, action: NativeActionClass, subjects: [[NativeRuleTarget]],
                                               about: String) -> NativeInstructionPending? {
        let resolver = commandResolver(rules, conversationID: conversationID, requestText: requestText, typed: typed, uses: uses,
                                       command: command, action: action, subjects: subjects)
        return pending(resolver, action: action, command: action == .commands ? command : nil, store: store, about: about)
    }

    nonisolated static func commandLive(_ rules: NativeRuleSource, store: NativeRuleRecordStore?, conversationID: String, requestText: String,
                                        typed: NativeTypedWords = .none, uses: NativeInstructionUses? = nil)
        -> (live: @Sendable (String, NativeActionClass) -> NativeRuleDecision?,
            liveTargets: @Sendable (String, NativeActionClass, [[NativeRuleTarget]]) -> NativeRuleVerdict?) {
        let live: @Sendable (String, NativeActionClass) -> NativeRuleDecision? = { command, action in
            let resolver = rules.resolver(for: conversationID, requestText: requestText, typed: typed).tool(NativeCommandTools.toolID, targets: [])
            return action == .commands ? resolver.decision(forCommand: command) : resolver.decision(for: action)
        }
        let liveTargets: @Sendable (String, NativeActionClass, [[NativeRuleTarget]]) -> NativeRuleVerdict? = { command, action, subjects in
            commandDecision(rules, store: store, conversationID: conversationID, requestText: requestText, typed: typed, uses: uses,
                            command: command, action: action, subjects: subjects)
        }
        return (live, liveTargets)
    }

    nonisolated static func toolResolver(_ rules: NativeRuleSource, conversationID: String, requestText: String, typed: NativeTypedWords,
                                         uses: NativeInstructionUses?, asked: NativeInstructionClaim?, toolID: String,
                                         subjects: [[NativeRuleTarget]]) -> NativeRuleResolver {
        var resolver = rules.resolver(for: conversationID, requestText: requestText, typed: typed).tool(toolID, subjects: subjects)
        resolver.uses = uses
        resolver.asked = asked
        return resolver
    }

    nonisolated static func toolDecision(_ rules: NativeRuleSource, store: NativeRuleRecordStore? = nil, conversationID: String,
                                         requestText: String, typed: NativeTypedWords = .none, uses: NativeInstructionUses? = nil,
                                         asked: NativeInstructionClaim? = nil, toolID: String, action: NativeActionClass,
                                         subjects: [[NativeRuleTarget]]) -> NativeRuleVerdict {
        instructedVerdict(toolResolver(rules, conversationID: conversationID, requestText: requestText, typed: typed, uses: uses, asked: asked,
                                       toolID: toolID, subjects: subjects),
                          action: action, rules: rules, store: store)
    }

    nonisolated static func toolInstruction(_ rules: NativeRuleSource, store: NativeRuleRecordStore? = nil, conversationID: String,
                                            requestText: String, typed: NativeTypedWords = .none, uses: NativeInstructionUses? = nil,
                                            asked: NativeInstructionClaim? = nil, toolID: String, action: NativeActionClass,
                                            subjects: [[NativeRuleTarget]], about: String) -> NativeInstructionPending? {
        pending(toolResolver(rules, conversationID: conversationID, requestText: requestText, typed: typed, uses: uses, asked: asked,
                             toolID: toolID, subjects: subjects),
                action: action, store: store, about: about)
    }

    nonisolated static func judged(_ resolver: NativeRuleResolver, action: NativeActionClass, command: String? = nil, store: NativeRuleRecordStore?)
        -> (decided: (decision: NativeRuleDecision, authorizedBy: [String], why: NativeRuleWhy?), spending: String?) {
        let honoring = store != nil && resolver.durable
        let decided = resolver.judge(action, command: command, honoringLimitedUse: honoring)
        let spending = decided.decision == .act(.instruction)
            ? resolver.instructed(resolver.query(for: action, command: command), honoringLimitedUse: honoring) : nil
        return (decided, spending)
    }

    nonisolated static func pending(_ resolver: NativeRuleResolver, action: NativeActionClass, command: String? = nil,
                                    store: NativeRuleRecordStore?, about: String) -> NativeInstructionPending? {
        guard let uses = resolver.uses, let signature = judged(resolver, action: action, command: command, store: store).spending else { return nil }
        return NativeInstructionPending(signature: signature, about: about, refuse: { uses.take(signature) })
    }

    nonisolated static func instructedVerdict(_ resolver: NativeRuleResolver, action: NativeActionClass, rules: NativeRuleSource,
                                              store: NativeRuleRecordStore?) -> NativeRuleVerdict {
        let result = judged(resolver, action: action, store: store)
        return verdict(result.decided.decision, authorizing: result.decided.authorizedBy, resolver: resolver, rules: rules, store: store,
                       why: result.decided.why, spending: result.spending)
    }

    nonisolated static func followsRules(_ definition: NativeToolDefinition) -> Bool {
        definition.effect == .write && !definition.governed && !definition.proposes && definition.id != NativeCompanionProfileTools.toolID
    }

    nonisolated static func ruled(_ definition: NativeToolDefinition, rules: NativeRuleSource, store: NativeRuleRecordStore?,
                                  conversationID: String, requestText: String, typed: NativeTypedWords = .none,
                                  uses: NativeInstructionUses? = nil) -> NativeToolDefinition {
        guard followsRules(definition) else { return definition }
        let original = definition
        let claim: @Sendable ([String: NativeJSONValue]) -> NativeInstructionClaim? = { arguments in
            original.verbs.isEmpty || original.demandsConfirmation ? nil
                : NativeInstructionClaim(verbs: original.verbs, names: original.instructionNames?(arguments) ?? [], nothing: original.namesNothing)
        }
        let decide: @Sendable ([String: NativeJSONValue]) -> (NativeActionClass, NativeRuleVerdict) = { arguments in
            let action = original.actionClass(for: arguments) ?? .otherChanges
            var verdict = toolDecision(rules, store: store, conversationID: conversationID, requestText: requestText, typed: typed, uses: uses,
                                       asked: claim(arguments), toolID: original.id,
                                       action: action, subjects: original.ruleSubjects?(arguments) ?? [])
            if case .act = verdict.decision, original.demandsConfirmation { verdict.why = NativeRuleWhy.tool(action) }
            return (action, verdict)
        }
        let ownConfirmation: @Sendable ([String: NativeJSONValue]) -> Bool = { arguments in
            original.confirmationFor?(arguments) ?? (original.confirmation == .required)
        }
        var wrapped = definition
        wrapped.governed = true
        wrapped.alwaysAsks = original.demandsConfirmation
        wrapped.confirmationFor = { arguments in
            if original.proposesFor?(arguments) == true { return ownConfirmation(arguments) }
            let decision = decide(arguments).1.decision
            if decision == .handOff { return false }
            return decision.requiresConfirmation || ownConfirmation(arguments)
        }
        wrapped.instructionFor = { arguments in
            guard original.proposesFor?(arguments) != true, !ownConfirmation(arguments) else { return nil }
            let action = original.actionClass(for: arguments) ?? .otherChanges
            let asked = claim(arguments)
            let subjects = original.ruleSubjects?(arguments) ?? []
            return toolInstruction(rules, store: store, conversationID: conversationID, requestText: requestText, typed: typed, uses: uses,
                                   asked: asked, toolID: original.id, action: action, subjects: subjects,
                                   about: NativeInstructionCheck.about(original, arguments: arguments, targets: subjects.flatMap { $0 },
                                                                       names: asked?.names ?? []))
        }
        wrapped.execute = { arguments in
            try original.preflight?(arguments)
            if !NativeRuleAdmission.admitted, original.proposesFor?(arguments) != true {
                let (action, verdict) = decide(arguments)
                let commit = try NativeRuleResolver.gate(verdict, fallback: nil, planned: .act(.rule), action: action,
                                                         approved: NativeToolCallContext.confirmed ?? false)
                try commit()
            }
            return try await original.execute(arguments)
        }
        return wrapped
    }

    nonisolated static func folderResolver(_ rules: NativeRuleSource, conversationID: String, requestText: String, typed: NativeTypedWords,
                                           uses: NativeInstructionUses?, action: NativeActionClass,
                                           subjects: [[NativeRuleTarget]]) -> NativeRuleResolver {
        var resolver = rules.resolver(for: conversationID, requestText: requestText, typed: typed).tool(NativeFolderTools.toolID, subjects: subjects)
        resolver.uses = uses
        resolver.asked = NativeFolderTools.verbs[action].map { NativeInstructionClaim(verbs: $0) }
        return resolver
    }

    nonisolated static func folderDecision(_ rules: NativeRuleSource, store: NativeRuleRecordStore? = nil, conversationID: String,
                                           requestText: String, typed: NativeTypedWords = .none, uses: NativeInstructionUses? = nil,
                                           action: NativeActionClass, subjects: [[NativeRuleTarget]]) -> NativeRuleVerdict {
        instructedVerdict(folderResolver(rules, conversationID: conversationID, requestText: requestText, typed: typed, uses: uses,
                                         action: action, subjects: subjects),
                          action: action, rules: rules, store: store)
    }

    nonisolated static func folderInstruction(_ rules: NativeRuleSource, store: NativeRuleRecordStore? = nil, conversationID: String,
                                              requestText: String, typed: NativeTypedWords = .none, uses: NativeInstructionUses? = nil,
                                              action: NativeActionClass, subjects: [[NativeRuleTarget]], about: String) -> NativeInstructionPending? {
        pending(folderResolver(rules, conversationID: conversationID, requestText: requestText, typed: typed, uses: uses,
                               action: action, subjects: subjects),
                action: action, store: store, about: about)
    }

    nonisolated static func verdict(_ decision: NativeRuleDecision, authorizing: [String], resolver: NativeRuleResolver,
                                    rules: NativeRuleSource, store: NativeRuleRecordStore?, why: NativeRuleWhy? = nil,
                                    spending: String? = nil) -> NativeRuleVerdict {
        if decision == .act(.instruction) {
            guard let spending, let uses = resolver.uses else { return NativeRuleVerdict(.ask, why: why) }
            let revision = resolver.revision
            let durable = resolver.durable ? store : nil
            return NativeRuleVerdict(decision, why: why, confirm: {
                guard NativeInstructionCheck.cleared == spending else { return false }
                if let durable, (try? durable.confirm(revision: revision, authorizing: [])) != .authorized { return false }
                return uses.take(spending)
            })
        }
        guard case .act = decision, resolver.durable, let store else { return NativeRuleVerdict(decision, why: why) }
        let revision = resolver.revision
        return NativeRuleVerdict(decision, why: why, confirm: {
            let confirmed = (try? store.confirm(revision: revision, authorizing: authorizing)) == .authorized
            if confirmed, !authorizing.isEmpty { reloadRules(rules, from: store) }
            return confirmed
        })
    }

    func fileChangeLedger(for turn: NativeConversationTurn) -> NativeFileChangeLedger {
        let ledger = NativeFileChangeLedger()
        ledger.attach { [weak self] _, change in
            Task { @MainActor [weak self] in self?.attachFileChange(change, turn: turn) }
        }
        return ledger
    }

    func attachFileChange(_ change: NativeFileChange, turn: NativeConversationTurn) {
        attachDisplayBlock(.fileChange(change), turn: turn)
    }

    func attachDisplayBlock(_ block: NativeDisplayBlock, turn: NativeConversationTurn) {
        var stored: [NativeDisplayBlock]?
        do {
            stored = try (repository as? LocalChatRepository)?.appendDisplayBlock(block, messageID: turn.assistantMessageID)
        } catch {
            grantError = "A file change couldn't be saved to the chat: \(error.localizedDescription)"
        }
        guard let conversation = conversations.firstIndex(where: { $0.id == turn.conversationID }),
              let reply = conversations[conversation].messages.firstIndex(where: { $0.id == turn.assistantMessageID }) else { return }
        if let stored {
            conversations[conversation].messages[reply].displayBlocks = stored
        } else if let existing = conversations[conversation].messages[reply].displayBlocks.firstIndex(where: { $0.id == block.id }) {
            conversations[conversation].messages[reply].displayBlocks[existing] = block
        } else {
            conversations[conversation].messages[reply].displayBlocks.append(block)
        }
        if case .fileChange(let change) = block {
            recordFileChangeArtifact(change, conversationID: turn.conversationID, messageID: turn.assistantMessageID.uuidString,
                                     revising: artifactRevisionTarget(messageID: turn.userMessageID.uuidString))
        }
    }

    func conversationRules(for conversationID: String) -> NativeConversationRules {
        conversations.first(where: { $0.id == conversationID })?.rules ?? NativeConversationRules()
    }

    func ruleResolver(for conversationID: String, requestText: String, typed: NativeTypedWords = .none) -> NativeRuleResolver {
        let projectID = conversations.first(where: { $0.id == conversationID })?.projectID
        var resolver = NativeRuleResolver(global: nativeRules, conversation: conversationRules(for: conversationID), requestText: requestText,
                                          records: nativeRuleSource.currentRecords,
                                          context: NativeRuleContext(conversationID: conversationID, projectID: projectID))
        resolver.typed = typed
        return resolver
    }

    func turnInstructionUses(for turn: NativeConversationTurn) -> NativeInstructionUses {
        let key = turn.attempt ?? turn.id
        if let existing = turnInstructionUseSources[key] { return existing }
        let created = NativeInstructionUses()
        turnInstructionUseSources[key] = created
        return created
    }

    func typedWords(for turn: NativeConversationTurn) -> NativeTypedWords {
        guard turn.companionEvent == nil else { return .none }
        var marked = (try? turnRepository?.typedMessageIDs(conversationID: turn.conversationID)) ?? []
        if turn.preferenceEligible == true { marked.insert(turn.userMessageID) }
        return Self.typedWords(history: turn.history, current: turn.userMessageID, marked: marked)
    }

    nonisolated static func typedWords(history: [NativeTurnHistoryMessage], current: UUID, marked: Set<UUID>) -> NativeTypedWords {
        let end = history.firstIndex { $0.id == current } ?? history.count
        let earlier = history[..<end].filter { $0.role == "user" && marked.contains($0.id) }.map(\.text)
        let own = end < history.count && marked.contains(current) ? history[end].text : nil
        return NativeTypedWords(typed: own, earlier: earlier)
    }

    func syncRuleSource() {
        nativeRuleSource.replaceAll(conversations.map { ($0.id, $0.rules) })
        syncRuleProjects()
    }

    func tightenConversationRule(_ choice: NativeRuleChoice, for action: NativeActionClass, conversationID: String? = nil) {
        guard let id = conversationID ?? selectedID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].rules.tighten(choice, for: action, global: nativeRules)
        persistRules(index)
        announceRuleChange()
    }

    func clearConversationRule(for action: NativeActionClass, conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }), conversations[index].rules.choices[action] != nil else { return }
        conversations[index].rules.choices[action] = nil
        persistRules(index)
        announceRuleChange()
    }

    private func persistRules(_ index: Int) {
        nativeRuleSource.set(conversations[index].rules, for: conversations[index].id)
        guard let repository else { return }
        do {
            conversations[index].isPersisted = true
            try repository.saveConversation(conversations[index])
        } catch {
            grantError = "The rule couldn't be saved: \(error.localizedDescription)"
        }
    }

    func grantFolder(_ url: URL) {
        if selectedID == nil || !conversations.contains(where: { $0.id == selectedID }) { newConversation() }
        guard let id = selectedID, let index = conversations.firstIndex(where: { $0.id == id }) else {
            grantError = "Open a chat first, then share the folder."
            return
        }
        grantError = nil
        let grant: FolderGrant
        do { grant = try FolderGrant.make(url: url) } catch {
            grantError = error.localizedDescription
            return
        }
        if conversations[index].grants.contains(where: { $0.path == grant.path }) { return }
        if let inside = conversations[index].grants.first(where: { NativeFolderAccess.contains(root: $0.path, path: grant.path) }) {
            grantError = "\(grant.name) is already inside the shared folder \(inside.name)."
            return
        }
        conversations[index].grants.removeAll { NativeFolderAccess.contains(root: grant.path, path: $0.path) }
        conversations[index].grants.append(grant)
        persistGrants(index)
        grantConsentTick &+= 1
    }

    func revokeGrant(_ grantID: String) {
        guard let id = selectedID else { return }
        stopSharing(conversationID: id, grantID: grantID)
    }

    @discardableResult
    func stopSharing(conversationID: String, grantID: String) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        let before = conversations[index]
        conversations[index].grants.removeAll { $0.id == grantID }
        if persistGrants(index) { return true }
        if let current = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[current].grants = before.grants
            conversations[current].isPersisted = before.isPersisted
            refreshConversationGrants(conversationID)
        }
        return false
    }

    var sharedFolderRows: [SharedFolderRow] {
        SharedFolderRows.rows(conversations: conversations, projects: projects, companionThreadID: veraThreadID, name: companionName)
    }

    @discardableResult
    func stopSharing(_ row: SharedFolderRow) -> Bool {
        let chatLine = grantError
        let projectLine = projectError
        let saved: Bool
        switch row.kind {
        case .chat(let conversationID, let grantID): saved = stopSharing(conversationID: conversationID, grantID: grantID)
        case .project(let projectID, let grantID): saved = removeProjectFolder(projectID, grantID: grantID)
        }
        if saved {
            if rulesNotice == SharedFolderRows.failed { rulesNotice = nil }
        } else {
            grantError = chatLine
            projectError = projectLine
            rulesNotice = SharedFolderRows.failed
        }
        return saved
    }

    @discardableResult
    private func persistGrants(_ index: Int) -> Bool {
        let conversation = conversations[index]
        refreshConversationGrants(conversation.id)
        guard let repository else { return true }
        do {
            conversations[index].isPersisted = true
            try repository.saveConversation(conversations[index])
            return true
        } catch {
            grantError = "The shared folder couldn't be saved: \(error.localizedDescription)"
            return false
        }
    }

    func syncGrantSource() {
        nativeGrantSource.replaceAll(conversations)
        for conversation in conversations where conversation.projectID != nil {
            refreshConversationGrants(conversation.id)
        }
    }

}
