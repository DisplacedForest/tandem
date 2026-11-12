import Foundation

extension ChatStore {
    func refreshNativeTaskDeliveries() {
        guard let local = repository as? LocalChatRepository else { return }
        nativeTaskResultDeliveries = (try? local.taskResultDeliveries()) ?? nativeTaskResultDeliveries
        recoverDeliveredDocuments()
    }

    @discardableResult
    func deliverNativeTaskMessages(_ updates: [NativeTaskMessageUpdate], now: Date = Date()) -> Bool {
        guard let local = repository as? LocalChatRepository else { return false }
        var delivered = false
        var seen: Set<UUID> = []
        for update in updates {
            guard let id = update.referenceID, seen.insert(id).inserted,
                  !nativeTaskResultDeliveries.keys.contains(id),
                  let posts = try? local.deliverTaskMessages(id: id, now: now) else { continue }
            for post in posts {
                noteDeliveredConversation(post)
                delivered = true
            }
        }
        if delivered { refreshNativeTaskDeliveries() } else { recoverDeliveredDocuments() }
        return reconcileDeliveredMessages() || delivered
    }

    func noteDeliveredConversation(_ post: NativeTaskDeliveredPost) {
        if let index = conversations.firstIndex(where: { $0.id == post.conversationID }) {
            conversations[index].updatedAt = max(conversations[index].updatedAt, post.message.createdAt)
            conversations[index].isPersisted = true
        } else if let stored = try? repository?.listConversations().first(where: { $0.id == post.conversationID }) {
            conversations.insert(stored, at: 0)
        }
    }

    func recoverDeliveredDocuments() {
        guard artifactRepository != nil, let local = repository as? LocalChatRepository,
              let documents = try? local.deliveredDocuments() else { return }
        for post in documents {
            recordTaskArtifacts(post.message.displayBlocks, conversationID: post.conversationID, messageID: post.message.id.uuidString)
        }
    }

    @discardableResult
    func reconcileDeliveredMessages() -> Bool {
        guard let local = repository as? LocalChatRepository else { return false }
        let loaded = Set(conversations.filter { !$0.messages.isEmpty || $0.id == selectedID }.map(\.id))
        guard !loaded.isEmpty, let stored = try? local.deliveredMessages(conversationIDs: loaded) else { return false }
        var placed = false
        var ordinals: [String: [UUID: Int]] = [:]
        for entry in stored {
            guard let index = conversations.firstIndex(where: { $0.id == entry.post.conversationID }),
                  !conversations[index].messages.contains(where: { $0.id == entry.post.message.id }) else { continue }
            let conversationID = entry.post.conversationID
            if ordinals[conversationID] == nil {
                ordinals[conversationID] = (try? local.messageOrdinals(conversationID: conversationID)) ?? [:]
            }
            let known = ordinals[conversationID] ?? [:]
            let messages = conversations[index].messages
            let position = messages.firstIndex { message in (known[message.id] ?? Int.min) > entry.ordinal } ?? messages.endIndex
            conversations[index].messages.insert(entry.post.message, at: position)
            conversations[index].updatedAt = max(conversations[index].updatedAt, entry.post.message.createdAt)
            placed = true
        }
        return placed
    }

    func deliveredMessageID(for referenceID: UUID) -> UUID? {
        nativeTaskResultDeliveries[referenceID] ?? nil
    }

    var nativeTaskNewFlowIDs: Set<UUID> {
        Set(nativeTaskReferences.map(\.id).filter { !settledBeforeDelivery($0) })
    }

    func settledBeforeDelivery(_ referenceID: UUID) -> Bool {
        guard let entry = nativeTaskResultDeliveries[referenceID] else { return false }
        return entry == nil
    }

    func resultWasDelivered(_ referenceID: UUID) -> Bool {
        deliveredMessageID(for: referenceID) != nil
    }

    func revealDeliveredResult(_ referenceID: UUID, conversationID: String) -> Bool {
        guard let messageID = deliveredMessageID(for: referenceID),
              conversations.contains(where: { $0.id == conversationID }) else { return false }
        if selectedID != conversationID || !(section == .chat || section == .vera) { select(conversationID) }
        pendingHighlightMessageID = messageID
        return true
    }
}

enum TranscriptVisibility {
    static func shows(_ message: Message) -> Bool {
        if message.contentType == .runOrigin { return message.role == .assistant && !message.displayBlocks.isEmpty }
        guard message.role == .assistant, message.state == .complete else { return true }
        let empty = message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !(empty && message.displayBlocks.isEmpty && message.toolActivities.isEmpty && message.artifacts.isEmpty
                 && message.attachments.isEmpty && message.ask == nil && message.pulse == nil)
    }
}
