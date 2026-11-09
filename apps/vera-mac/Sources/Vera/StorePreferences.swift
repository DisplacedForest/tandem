import Foundation
import GRDB

extension NativePreferenceStore {
    static func identity(_ base: NativeWorkerIdentity, database: DatabaseQueue) -> NativeWorkerIdentity {
        var identity = base
        identity.preferences = NativePreferenceStore(database: database).activeStatements()
        return identity
    }

    static func turnGuard(id: UUID, attempt: UUID?) -> @Sendable (Database) throws -> Bool {
        let key = id.uuidString
        return { db in
            guard let attempt, let row = try Row.fetchOne(db, sql: "SELECT state, attempt FROM native_conversation_turns WHERE id = ?",
                                                          arguments: [key]) else { return false }
            let state: String? = row["state"]
            let saved: String? = row["attempt"]
            return state == NativeConversationTurn.State.running.rawValue && saved.flatMap(UUID.init(uuidString:)) == attempt
        }
    }
}

extension ChatStore {
    var nativePreferenceStore: NativePreferenceStore? {
        (repository as? LocalChatRepository).map { NativePreferenceStore(database: $0.database) }
    }

    func activePreferenceStatements() -> [String] {
        nativePreferenceStore?.activeStatements() ?? []
    }

    static func preferenceCaptureRequest(for turn: NativeConversationTurn, text: String, stored: [Message]?) -> NativePreferenceCaptureRequest? {
        guard turn.preferenceEligible == true, turn.mode == .chat, turn.companionEvent == nil,
              let current = turn.history.lastIndex(where: { $0.id == turn.userMessageID }),
              turn.history[current].role == Message.Role.user.rawValue else { return nil }
        let written = turn.history[current].text
        guard written == text, !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var previous: String?
        if let stored, let position = stored.firstIndex(where: { $0.id == turn.userMessageID }) {
            previous = stored[..<position].last(where: { $0.role == .user })?.id.uuidString
        }
        return NativePreferenceCaptureRequest(
            key: NativePreferenceCaptureKey(turnID: turn.id.uuidString, conversationID: turn.conversationID,
                                            userMessageID: turn.userMessageID.uuidString),
            previousUserMessageID: previous, text: written)
    }

    func capturePreference(for turn: NativeConversationTurn, text: String, transport: any NativeChatTransport,
                           model: String) async -> NativePreferenceCaptureOutcome {
        guard capturesPreferences, let store = nativePreferenceStore,
              let request = Self.preferenceCaptureRequest(for: turn, text: text,
                                                          stored: try? repository?.messages(conversationID: turn.conversationID)) else { return .none }
        let classify: @Sendable (String) async -> String?
        if let preferenceClassifier {
            classify = preferenceClassifier
        } else if !model.isEmpty {
            let timeout = preferenceClassifierTimeout
            classify = { text in await NativePreferenceClassifier.request(transport: transport, model: model, text: text, timeout: timeout) }
        } else {
            classify = { _ in nil }
        }
        let sameDatabase = (turnRepository as? LocalChatRepository).map { $0.database === store.database } ?? false
        let turnGuard = NativePreferenceStore.turnGuard(id: turn.id, attempt: turn.attempt)
        let stillCurrent: @Sendable (Database) throws -> Bool = { db in sameDatabase ? try turnGuard(db) : true }
        let isCurrent: @Sendable () async -> Bool = { @MainActor [weak self] in
            guard let self else { return false }
            return await self.turnCurrency(turn) == .current
        }
        let outcome = await NativePreferenceCapture.run(request, store: store, classify: classify,
                                                        isCurrent: isCurrent, stillCurrent: stillCurrent)
        switch outcome {
        case .saved, .removed: preferencesRevision += 1
        case .none, .failed, .full, .removalFailed: break
        }
        return outcome
    }
}
