import Foundation

final class NativeFolderGrantSource: @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [String: [FolderGrant]] = [:]

    func set(_ value: [FolderGrant], for conversationID: String) {
        lock.lock(); defer { lock.unlock() }
        if value.isEmpty { grants.removeValue(forKey: conversationID) } else { grants[conversationID] = value }
    }

    func grants(for conversationID: String) -> [FolderGrant] {
        lock.lock(); defer { lock.unlock() }
        return grants[conversationID] ?? []
    }

    func replaceAll(_ conversations: [Conversation]) {
        lock.lock(); defer { lock.unlock() }
        grants = Dictionary(uniqueKeysWithValues: conversations.filter { !$0.grants.isEmpty }.map { ($0.id, $0.grants) })
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

    func clear(_ activityID: String) {
        lock.lock(); defer { lock.unlock() }
        reasons.removeValue(forKey: activityID)
    }
}

enum NativeToolDecision: Equatable, Sendable {
    case approve
    case approveSimilar
    case decline

    var approved: Bool { self != .decline }
}

extension ChatStore {
    var selectedGrants: [FolderGrant] { selected?.grants ?? [] }
    var selectedConversationRules: NativeConversationRules { selected?.rules ?? NativeConversationRules() }

    var folderToolsSupported: Bool { activeCapabilityResolution?.profile.supportsTools ?? false }

    var folderToolsUnsupportedReason: String? {
        guard let resolution = activeCapabilityResolution else { return "No model is set up, so a granted folder couldn't be used yet." }
        guard !resolution.profile.supportsTools else { return nil }
        let model = currentNativeConfig?.model ?? "This model"
        return "\(model) can't call tools, so it can't read or change files. Pick a model with tool calling in Settings, Model, or adjust this model's capabilities there."
    }

    func grants(for conversationID: String) -> [FolderGrant] {
        conversations.first(where: { $0.id == conversationID })?.grants ?? nativeGrantSource.grants(for: conversationID)
    }

    func folderToolDefinitions(for conversationID: String, ledger: NativeFileChangeLedger,
                               edits: NativeRuleDecision = .act(.rule), trash: NativeRuleDecision = .ask,
                               live: @escaping @Sendable (NativeActionClass) -> NativeRuleDecision? = { _ in nil },
                               alwaysAvailable: Bool = false) -> [NativeToolDefinition] {
        let source = nativeGrantSource
        return NativeFolderTools.definitions(grants: { source.grants(for: conversationID) }, ledger: ledger,
                                             edits: edits, trash: trash, live: live, alwaysAvailable: alwaysAvailable)
    }

    func commandToolDefinitions(for turn: NativeConversationTurn, decision: NativeRuleDecision,
                                record: @escaping @Sendable (NativeCommandRun) -> Void,
                                alwaysAvailable: Bool = false) -> [NativeToolDefinition] {
        let source = nativeGrantSource
        let conversationID = turn.conversationID
        let reasons = turnCommandReasonSource
        let rules = nativeRuleSource
        let text = turn.history.first(where: { $0.id == turn.userMessageID })?.text ?? ""
        return NativeCommandTools.definitions(grants: { source.grants(for: conversationID) }, decision: decision,
                                              reason: { reasons.reason(for: $0) }, record: record,
                                              live: { rules.resolver(for: conversationID, requestText: text).decision(forCommand: $0) },
                                              alwaysAvailable: alwaysAvailable)
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
    }

    func conversationRules(for conversationID: String) -> NativeConversationRules {
        conversations.first(where: { $0.id == conversationID })?.rules ?? NativeConversationRules()
    }

    func ruleResolver(for conversationID: String, requestText: String) -> NativeRuleResolver {
        NativeRuleResolver(global: nativeRules, conversation: conversationRules(for: conversationID), requestText: requestText)
    }

    func syncRuleSource() {
        nativeRuleSource.replaceAll(conversations.map { ($0.id, $0.rules) })
    }

    func tightenConversationRule(_ choice: NativeRuleChoice, for action: NativeActionClass, conversationID: String? = nil) {
        guard let id = conversationID ?? selectedID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].rules.tighten(choice, for: action, global: nativeRules)
        persistRules(index)
    }

    func approveCommandPrefix(_ command: String, conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].rules.approve(prefix: command)
        persistRules(index)
    }

    func revokeCommandPrefix(_ prefix: String, conversationID: String? = nil) {
        guard let id = conversationID ?? selectedID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].rules.revoke(prefix: prefix)
        persistRules(index)
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
            grantError = "Open a chat first, then grant the folder."
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
            grantError = "\(grant.name) is already inside the granted folder \(inside.name)."
            return
        }
        conversations[index].grants.removeAll { NativeFolderAccess.contains(root: grant.path, path: $0.path) }
        conversations[index].grants.append(grant)
        persistGrants(index)
        grantConsentTick &+= 1
    }

    func revokeGrant(_ grantID: String) {
        guard let id = selectedID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].grants.removeAll { $0.id == grantID }
        persistGrants(index)
    }

    private func persistGrants(_ index: Int) {
        let conversation = conversations[index]
        nativeGrantSource.set(conversation.grants, for: conversation.id)
        guard let repository else { return }
        do {
            conversations[index].isPersisted = true
            try repository.saveConversation(conversations[index])
        } catch {
            grantError = "The folder grant couldn't be saved: \(error.localizedDescription)"
        }
    }

    func syncGrantSource() {
        nativeGrantSource.replaceAll(conversations)
    }

}
