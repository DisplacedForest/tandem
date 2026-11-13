import Foundation
import SwiftUI

struct CompanionTranscriptPosition: Codable, Equatable {
    var messageID: UUID?
    var followsLatest = true
}

@MainActor
final class CompanionTranscriptContinuity: ObservableObject {
    @Published private(set) var position = CompanionTranscriptPosition()
    private(set) var restoring = true
    private var conversationID: String?
    private var userScrolled = false
    private var firstVisible: UUID?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppLocations.preferences) { self.defaults = defaults }

    func begin(conversationID: String, messages: [UUID]) -> UUID? {
        self.conversationID = conversationID
        restoring = true
        userScrolled = false
        firstVisible = nil
        let data = defaults.data(forKey: key(conversationID))
        position = data.flatMap { try? JSONDecoder().decode(CompanionTranscriptPosition.self, from: $0) } ?? CompanionTranscriptPosition()
        if !position.followsLatest && !messages.contains(where: { $0 == position.messageID }) { position = CompanionTranscriptPosition() }
        return position.followsLatest ? nil : position.messageID
    }

    func finishRestoring(conversationID: String) {
        guard self.conversationID == conversationID else { return }
        restoring = false
    }

    func scrollPhaseChanged(_ phase: ScrollPhase) {
        userScrolled = !restoring && (phase == .tracking || phase == .interacting || phase == .decelerating)
    }

    func observe(visible: [UUID], ordered: [UUID], conversationID: String) {
        guard self.conversationID == conversationID, let first = ordered.first(where: { visible.contains($0) }) else { return }
        firstVisible = first
        guard !restoring, userScrolled else { return }
        position.messageID = first
        save()
    }

    func observe(nearBottom: Bool, conversationID: String) {
        guard self.conversationID == conversationID, !restoring, userScrolled else { return }
        position.followsLatest = nearBottom
        save()
    }

    func follows(_ latest: Bool, conversationID: String) {
        guard self.conversationID == conversationID, !restoring else { return }
        if !latest {
            guard let anchor = firstVisible ?? position.messageID else { return }
            position.messageID = anchor
        }
        position.followsLatest = latest
        save()
    }

    var shouldFollowLatest: Bool { !restoring && position.followsLatest }

    private func key(_ id: String) -> String { "companion.transcript.position." + id }

    private func save() {
        guard let conversationID, let data = try? JSONEncoder().encode(position) else { return }
        defaults.set(data, forKey: key(conversationID))
    }
}

struct CompanionOpeningView: View {
    let error: CompanionLine?
    var needsConnection = false
    var canRetry = true
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            if let error {
                CompanionLineText(line: error).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                if needsConnection {
                    SettingsSectionLink("Open Settings", tab: .connection).buttonStyle(.bordered)
                } else if canRetry {
                    Button("Try again", action: retry).buttonStyle(.bordered)
                }
            } else {
                ProgressView().controlSize(.small).accessibilityLabel("Opening conversation")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}

extension ChatStore {
    nonisolated static let companionNeedsConnection = "Choose a chat connection in Settings to start the conversation."

    var companionOpeningError: String? {
        if let chatConfigurationError { return chatConfigurationError }
        if repository == nil { return "Local history couldn't open. Reopen Tandem to try again." }
        if !pendingProfileAvailable { return Self.companionNeedsConnection }
        return nil
    }

    var companionOpeningErrorLine: CompanionLine? {
        if chatConfigurationError != nil { return chatConfigurationErrorLine }
        return companionOpeningError.map(CompanionLine.literal)
    }
}
