import Foundation
import GRDB

extension NativePreferenceStore {
    static func identity(_ base: NativeWorkerIdentity, database: DatabaseQueue) -> NativeWorkerIdentity {
        var identity = base
        identity.preferences = NativePreferenceStore(database: database).activeStatements()
        return identity
    }
}

extension ChatStore {
    var nativePreferenceStore: NativePreferenceStore? {
        (repository as? LocalChatRepository).map { NativePreferenceStore(database: $0.database) }
    }

    func activePreferenceStatements() -> [String] {
        nativePreferenceStore?.activeStatements() ?? []
    }

    static func preferenceCaptureRequest(for turn: NativeConversationTurn, text: String) -> NativePreferenceCaptureRequest? {
        guard turn.mode == .chat, turn.companionEvent == nil, turn.answersAsk != true,
              let current = turn.history.lastIndex(where: { $0.id == turn.userMessageID }),
              turn.history[current].role == Message.Role.user.rawValue else { return nil }
        let written = turn.history[current].text
        guard written == text, !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let previous = turn.history[..<current].last(where: { $0.role == Message.Role.user.rawValue })
        return NativePreferenceCaptureRequest(
            key: NativePreferenceCaptureKey(turnID: turn.id.uuidString, conversationID: turn.conversationID,
                                            userMessageID: turn.userMessageID.uuidString),
            previousUserMessageID: previous?.id.uuidString, text: written)
    }

    func capturePreference(for turn: NativeConversationTurn, text: String, transport: any NativeChatTransport,
                           model: String) async -> NativePreferenceCaptureOutcome {
        guard capturesPreferences, let store = nativePreferenceStore,
              let request = Self.preferenceCaptureRequest(for: turn, text: text) else { return .none }
        let classify: @Sendable (String) async -> String?
        if let preferenceClassifier {
            classify = preferenceClassifier
        } else if !model.isEmpty {
            let timeout = preferenceClassifierTimeout
            classify = { text in await NativePreferenceClassifier.request(transport: transport, model: model, text: text, timeout: timeout) }
        } else {
            classify = { _ in nil }
        }
        let outcome = await NativePreferenceCapture.run(request, store: store, classify: classify)
        switch outcome {
        case .saved, .removed: preferencesRevision += 1
        case .none, .failed, .removalFailed: break
        }
        return outcome
    }
}
