import SwiftUI
import AppKit
import Combine

@MainActor
final class CompanionPresence: ObservableObject {
    @Published private(set) var state: CompanionState = .ready
    private weak var store: ChatStore?
    private weak var voice: VoiceSession?
    private var subscriptions: Set<AnyCancellable> = []
    private var appActive = true

    init(store: ChatStore, voice: VoiceSession) {
        self.store = store
        self.voice = voice
    }

    func start() {
        guard subscriptions.isEmpty, let store, let voice else { return }
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
        let voiceChanges = voice.$state.removeDuplicates().map { _ in () }
            .merge(with: voice.$isPlayingAudio.removeDuplicates().map { _ in () },
                        voice.$activeConversationID.removeDuplicates().map { _ in () })
        storeChanges.merge(with: voiceChanges)
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
        let snapshot = Self.snapshot(store: store, appActive: appActive,
                                     voiceCapturing: voice?.state == .listening, voicePlaying: voice?.isPlayingAudio == true,
                                     voiceConversationID: voice?.activeConversationID)
        let next = CompanionStateMapper.state(snapshot)
        if next != state { state = next }
    }

    static func snapshot(store: ChatStore, appActive: Bool = true, voiceCapturing: Bool = false,
                         voicePlaying: Bool = false, voiceConversationID: String? = nil) -> CompanionStateSnapshot {
        var snapshot = CompanionStateSnapshot()
        let threadID = store.veraThreadID
        let ownedSchedules = Set(store.schedules.filter { $0.owner == .dot }.map(\.id))
        let runs = store.scheduleRuns.values.flatMap { $0 }.filter { ownedSchedules.contains($0.scheduleID) }
        let linkedIDs = Set(runs.compactMap { $0.taskReferenceID.flatMap(UUID.init(uuidString:)) })
        let references = store.nativeTaskReferences.filter {
            (threadID != nil && $0.origin.conversationID == threadID) || linkedIDs.contains($0.id)
        }
        let knownIDs = Set(references.map(\.id))
        for reference in references {
            guard let display = try? NativeTaskProjection.display(reference: reference, snapshot: reference.snapshot) else { continue }
            snapshot.decisionPending = snapshot.decisionPending || display.card.status == .needsInput
            snapshot.foregroundGenerating = snapshot.foregroundGenerating || display.card.status == .working
        }
        for run in runs {
            if let id = run.taskReferenceID.flatMap(UUID.init(uuidString:)), knownIDs.contains(id) { continue }
            snapshot.decisionPending = snapshot.decisionPending || run.outcome == .waiting
            snapshot.foregroundGenerating = snapshot.foregroundGenerating || run.outcome == .running
        }
        let foreground = threadID != nil && store.turnExecutions.values.contains { $0.record.conversationID == threadID }
        let legacyForeground = store.isVeraThread(store.selectedID) && TandemLogoPresence.selectedTurnRunning(store)
        snapshot.foregroundGenerating = snapshot.foregroundGenerating || foreground || legacyForeground
        snapshot.decisionPending = snapshot.decisionPending || store.companionAwaitingApproval
            || (store.isVeraThread(store.selectedID) && TandemLogoPresence.selectedDecisionPending(store))
        snapshot.explicitlyResting = store.dotProfile.isPaused
        snapshot.appInactive = !appActive
        let companionVoice = threadID != nil && voiceConversationID == threadID
        snapshot.voiceCapturing = companionVoice && voiceCapturing
        snapshot.voicePlaying = companionVoice && voicePlaying
        return snapshot
    }
}
