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
    private var turnEndPending = false
    private var lastGenerating = false

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
        lastGenerating = store.generating
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.setActive(true) } }
            .store(in: &subscriptions)
        center.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.setActive(false) } }
            .store(in: &subscriptions)
        store.$generating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.generatingChanged(value) } }
            .store(in: &subscriptions)
        store.objectWillChange
            .merge(with: voice.objectWillChange)
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &subscriptions)
        refresh()
    }

    func stop() {
        subscriptions.removeAll()
        snapshot = nil
        turnEndPending = false
        controller.stop()
    }

    private func setActive(_ active: Bool) {
        appActive = active
        refresh()
    }

    private func generatingChanged(_ value: Bool) {
        if lastGenerating && !value { turnEndPending = true }
        lastGenerating = value
    }

    private func refresh() {
        guard let store else { return }
        var next = TandemLogoSnapshot()
        next.appActive = appActive
        next.launchedJustNow = launchPending
        launchPending = false
        next.generating = store.generating
        next.decisionPending = store.pendingToolConfirmation != nil
        if turnEndPending && !store.generating {
            turnEndPending = false
            if let last = store.selected?.messages.last(where: { $0.role == .assistant }) {
                if last.failure != nil {
                    next.turnFailed = true
                } else if last.state == .interrupted {
                    next.turnCanceled = true
                } else if last.state == .complete && !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    next.turnCompleted = true
                }
            }
        }
        if let voice {
            next.voiceCapturing = voice.state == .listening
            next.voicePlaying = voice.state == .speaking
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
