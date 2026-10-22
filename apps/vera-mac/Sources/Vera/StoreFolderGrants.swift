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

extension ChatStore {
    var selectedGrants: [FolderGrant] { selected?.grants ?? [] }

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

    func folderToolDefinitions(for conversationID: String) -> [NativeToolDefinition] {
        let source = nativeGrantSource
        return NativeFolderTools.definitions(grants: { source.grants(for: conversationID) }, ledger: nativeFileChangeLedger)
    }

    func grantFolder(_ url: URL) {
        guard let id = selectedID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
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

    func liftFileChanges(_ activities: [NativeToolActivity], conversation: Int, reply: Int) async {
        for activity in activities where activity.toolID == NativeFolderTools.toolID && activity.state != .pending {
            let changes = await nativeFileChangeLedger.take(activity.id)
            guard !changes.isEmpty, conversation < conversations.count, reply < conversations[conversation].messages.count else { continue }
            for change in changes where !conversations[conversation].messages[reply].displayBlocks.contains(where: { $0.id == "file:" + change.id }) {
                conversations[conversation].messages[reply].displayBlocks.append(.fileChange(change))
            }
        }
    }
}
