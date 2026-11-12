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
            previous = stored[..<position].last(where: { $0.role == .user && $0.contentType != .runOrigin })?.id.uuidString
        }
        return NativePreferenceCaptureRequest(
            key: NativePreferenceCaptureKey(turnID: turn.id.uuidString, conversationID: turn.conversationID,
                                            userMessageID: turn.userMessageID.uuidString),
            previousUserMessageID: previous, text: written)
    }

    func capturePreference(for turn: NativeConversationTurn, text: String, transport: any NativeChatTransport,
                           model: String) async -> NativePreferenceCaptureOutcome {
        guard capturesPreferences, let local = repository as? LocalChatRepository, (turnRepository as? LocalChatRepository) === local,
              let store = nativePreferenceStore,
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
        let stillCurrent = NativePreferenceStore.turnGuard(id: turn.id, attempt: turn.attempt)
        let isCurrent: @Sendable () async -> Bool = { @MainActor [weak self] in
            guard let self else { return false }
            return await self.turnCurrency(turn) == .current
        }
        let outcome = await NativePreferenceCapture.run(request, store: store, classify: classify,
                                                        isCurrent: isCurrent, stillCurrent: stillCurrent)
        switch outcome {
        case .saved, .removed:
            preferencesRevision += 1
            refreshPreferenceMarkers(conversationID: turn.conversationID)
        case .none, .failed, .full, .tooLong, .unavailable, .removalFailed: break
        }
        return outcome
    }

    func currentPreferenceNote(_ outcome: NativePreferenceCaptureOutcome, turn: NativeConversationTurn) -> String? {
        guard case .saved = outcome else { return outcome.note }
        guard let store = nativePreferenceStore,
              let record = try? store.capture(turnID: turn.id.uuidString, userMessageID: turn.userMessageID.uuidString),
              record.outcome == .saved, let id = record.preferenceID,
              let stored = try? store.preference(id: id), stored.status == .active else { return nil }
        return NativePreferenceCaptureOutcome.saved(stored.statement).note
    }

    func revertPreferenceCapture(_ turn: NativeConversationTurn) {
        guard let store = nativePreferenceStore, (try? store.revertCapture(turnID: turn.id.uuidString)) == true else { return }
        preferencesRevision += 1
        refreshPreferenceMarkers(conversationID: turn.conversationID)
    }

    func refreshPreferenceMarkers(conversationID: String) {
        guard let store = nativePreferenceStore, let current = try? store.captureMarkers(conversationID: conversationID) else { return }
        let next = current.isEmpty ? nil : current
        if preferenceMarkers[conversationID] != next { preferenceMarkers[conversationID] = next }
    }

    func preferenceMarker(for message: Message, in conversationID: String) -> TranscriptMarker? {
        preferenceMarkers[conversationID]?[message.id]
    }
}
