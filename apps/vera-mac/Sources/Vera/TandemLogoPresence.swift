import SwiftUI
import AppKit
import Combine

@MainActor
final class TandemLogoPresence: ObservableObject {
    let controller: TandemMotionController
    private weak var store: ChatStore?
    private weak var voice: VoiceSession?
    private var subscriptions: Set<AnyCancellable> = []
    private var snapshot: TandemLogoSnapshot?
    private var appActive = true
    private var launchPending = false
    private var activeTurnConversation: String?

    init(store: ChatStore, voice: VoiceSession, controller: TandemMotionController = TandemMotionController()) {
        self.store = store
        self.voice = voice
        self.controller = controller
    }

    func start() {
        guard subscriptions.isEmpty, let store, let voice else { return }
        appActive = NSApplication.shared.isActive
        launchPending = true
        snapshot = nil
        activeTurnConversation = nil
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
            .merge(with: store.$selectedID.map { _ in () }, store.$pendingToolConfirmation.map { _ in () })
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
        snapshot = nil
        activeTurnConversation = nil
        controller.stop()
    }

    private func setActive(_ active: Bool) {
        appActive = active
        refresh()
    }

    static func selectedTurnRunning(_ store: ChatStore) -> Bool {
        guard store.generating, let id = store.selectedID else { return false }
        if store.turnExecutions.isEmpty { return true }
        return store.turnExecutions.values.contains { $0.record.conversationID == id }
    }

    static func terminalEvent(of message: Message?) -> (completed: Bool, failed: Bool, canceled: Bool) {
        guard let message else { return (false, false, false) }
        if message.failure != nil { return (false, true, false) }
        if message.state == .interrupted { return (false, false, true) }
        let spoke = message.state == .complete && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (spoke, false, false)
    }

    private func refresh() {
        guard let store else { return }
        var next = TandemLogoSnapshot()
        next.appActive = appActive
        next.launchedJustNow = launchPending
        launchPending = false
        let selectedID = store.selectedID
        let running = Self.selectedTurnRunning(store)
        next.generating = running
        next.decisionPending = running && store.pendingToolConfirmation != nil
        if running {
            activeTurnConversation = selectedID
        } else if let ended = activeTurnConversation {
            activeTurnConversation = nil
            if ended == selectedID {
                let event = Self.terminalEvent(of: store.selected?.messages.last(where: { $0.role == .assistant }))
                next.turnCompleted = event.completed
                next.turnFailed = event.failed
                next.turnCanceled = event.canceled
            }
        }
        if let voice {
            next.voiceCapturing = voice.state == .listening
            next.voicePlaying = voice.isPlayingAudio
        }
        let previous = snapshot
        snapshot = next
        guard previous != next, let (cue, loop) = TandemLogoCueMapper.cue(previous: previous, current: next) else { return }
        if loop && controller.activeSequence == cue.rawValue { return }
        controller.play(cue.rawValue, loop: loop)
    }
}

struct LiveTandemLogo: View {
    @EnvironmentObject private var presence: TandemLogoPresence
    var size: CGFloat

    var body: some View {
        AnimatedTandemLogo(controller: presence.controller)
            .frame(width: size * 410 / 256, height: size)
            .accessibilityLabel("Tandem")
    }
}
