import SwiftUI
import AppKit
import Combine

@MainActor
final class CompanionPresence: ObservableObject {
    @Published private(set) var state: CompanionState = .ready
    private weak var store: ChatStore?
    private var subscriptions: Set<AnyCancellable> = []
    private var appActive = true

    init(store: ChatStore) {
        self.store = store
    }

    func start() {
        guard subscriptions.isEmpty, let store else { return }
        appActive = NSApplication.shared.isActive
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.setActive(true) } }
            .store(in: &subscriptions)
        center.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.setActive(false) } }
            .store(in: &subscriptions)
        let storeChanges = Publishers.MergeMany([
            store.$generating.map { _ in () }.eraseToAnyPublisher(),
            store.$selectedID.map { _ in () }.eraseToAnyPublisher(),
            store.$veraThreadID.map { _ in () }.eraseToAnyPublisher(),
            store.$pendingToolConfirmation.map { _ in () }.eraseToAnyPublisher(),
            store.$turnConfirmations.map { _ in () }.eraseToAnyPublisher(),
            store.$conversationTurns.map { _ in () }.eraseToAnyPublisher(),
            store.$nativeTaskReferences.map { _ in () }.eraseToAnyPublisher(),
            store.$schedules.map { _ in () }.eraseToAnyPublisher(),
            store.$scheduleRuns.map { _ in () }.eraseToAnyPublisher(),
            store.$dotProfile.map { _ in () }.eraseToAnyPublisher(),
        ])
        storeChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &subscriptions)
        refresh()
    }

    func stop() {
        subscriptions.removeAll()
        state = .ready
    }

    private func setActive(_ active: Bool) {
        appActive = active
        refresh()
    }

    private func refresh() {
        guard let store else { return }
        let snapshot = Self.snapshot(store: store, appActive: appActive)
        let next = CompanionStateMapper.state(snapshot)
        if next != state { state = next }
    }

    static func snapshot(store: ChatStore, appActive: Bool = true, voiceCapturing: Bool = false,
                         voicePlaying: Bool = false, voiceConversationID: String? = nil) -> CompanionStateSnapshot {
        var snapshot = CompanionStateSnapshot()
        let threadID = store.veraThreadID
        let background = store.companionBackgroundWork
        snapshot.backgroundRunning = background.running
        snapshot.backgroundNeedsAnswer = background.needsAnswer
        let foreground = threadID != nil && store.turnExecutions.values.contains { $0.record.conversationID == threadID }
        let legacyForeground = store.isVeraThread(store.selectedID) && TandemLogoPresence.selectedTurnRunning(store)
        snapshot.foregroundGenerating = foreground || legacyForeground
        snapshot.decisionPending = store.companionAwaitingApproval
            || (store.isVeraThread(store.selectedID) && TandemLogoPresence.selectedDecisionPending(store))
        snapshot.explicitlyResting = store.dotProfile.isPaused
        snapshot.appInactive = !appActive
        let companionVoice = threadID != nil && voiceConversationID == threadID
        snapshot.voiceCapturing = companionVoice && voiceCapturing
        snapshot.voicePlaying = companionVoice && voicePlaying
        return snapshot
    }
}
