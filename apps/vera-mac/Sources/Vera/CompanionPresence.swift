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
        let storeChanges = store.$generating.map { _ in () }
            .merge(with: store.$selectedID.map { _ in () }, store.$pendingToolConfirmation.map { _ in () },
                        store.$turnConfirmations.map { _ in () })
        let voiceChanges = voice.$state.removeDuplicates().map { _ in () }
            .merge(with: voice.$isPlayingAudio.removeDuplicates().map { _ in () })
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
        var snapshot = CompanionStateSnapshot()
        let running = TandemLogoPresence.selectedTurnRunning(store)
        snapshot.foregroundGenerating = running
        snapshot.decisionPending = TandemLogoPresence.selectedDecisionPending(store)
        snapshot.explicitlyResting = false
        snapshot.appInactive = !appActive
        if let voice {
            snapshot.voiceCapturing = voice.state == .listening
            snapshot.voicePlaying = voice.isPlayingAudio
        }
        let next = CompanionStateMapper.state(snapshot)
        if next != state { state = next }
    }
}

struct LiveCompanionAvatar: View {
    @EnvironmentObject private var presence: CompanionPresence
    @Environment(\.companionName) private var name
    @Environment(\.companionAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat

    var body: some View {
        CompanionAvatarView(appearance: appearance, state: presence.state, size: size, name: name, reduceMotion: reduceMotion)
    }
}
