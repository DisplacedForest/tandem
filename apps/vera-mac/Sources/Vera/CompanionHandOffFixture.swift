import Foundation

@MainActor
enum CompanionHandOffFixture {
    static let reply = "I'll start on that now."

    static func handOff(_ store: ChatStore, assignment: String, reply: String = reply) async throws -> NativeTaskReference {
        guard let repository = store.repository, let service = store.nativeTaskService, store.nativeTaskEngine.base != nil,
              let nativeConfig = store.currentNativeConfig else {
            throw NativeTaskFixture.Failure.assertion("The companion conversation can start work")
        }
        let profile = store.nativeTaskEnrollment ?? (try? store.nativeTaskConfiguration?.enroll(config: nativeConfig))
        let trimmed = assignment.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try ChatStore.companionRequest(trimmed, connectedToolIDs: store.dotProfile.connectedToolIDs?.sorted(), said: trimmed)
        store.ensureVeraThread()
        guard let conversationID = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion conversation exists") }
        let user = Message(role: .user, text: request.objective)
        let answer = Message(role: .assistant, text: reply, state: .complete, modelID: nativeConfig.model)
        let ordinal = try repository.messages(conversationID: conversationID).count
        try repository.saveMessage(user, conversationID: conversationID, ordinal: ordinal)
        try repository.saveMessage(answer, conversationID: conversationID, ordinal: ordinal + 1)
        if let index = store.conversations.firstIndex(where: { $0.id == conversationID }) {
            if !store.conversations[index].messages.isEmpty || store.selectedID == conversationID {
                store.conversations[index].messages.append(contentsOf: [user, answer])
            }
            store.conversations[index].updatedAt = Date()
            store.conversations[index].isPersisted = true
            try repository.saveConversation(store.conversations[index])
        }
        let origin = NativeTaskOrigin(conversationID: conversationID, userMessageID: user.id, assistantMessageID: answer.id)
        let reference = try await service.submit(origin: origin, request: request, profile: profile)
        store.reloadNativeTaskReferences()
        if reference.deliveryState == .rejected {
            throw NativeTaskFixture.Failure.assertion(reference.lastDeliveryError ?? "The work was not accepted")
        }
        return reference
    }
}
