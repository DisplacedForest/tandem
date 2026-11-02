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
    private var activeTurn: TandemLogoTurnFocus?

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
        activeTurn = nil
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
        snapshot = nil
        activeTurn = nil
        controller.stop()
    }

    private func setActive(_ active: Bool) {
        appActive = active
        refresh()
    }

    static func selectedExecution(_ store: ChatStore) -> NativeTurnExecution? {
        guard let id = store.selectedID else { return nil }
        return store.turnExecutions.values.first { $0.record.conversationID == id }
    }

    static func selectedTurnRunning(_ store: ChatStore) -> Bool {
        guard store.generating, store.selectedID != nil else { return false }
        if store.turnExecutions.isEmpty { return true }
        return selectedExecution(store) != nil
    }

    static func decisionPending(confirmations: [UUID: NativeToolConfirmationRequest], assistantMessageID: UUID?,
                                fallback: Bool) -> Bool {
        guard let assistantMessageID else { return fallback }
        return confirmations[assistantMessageID] != nil
    }

    static func selectedDecisionPending(_ store: ChatStore) -> Bool {
        guard selectedTurnRunning(store) else { return false }
        let execution = selectedExecution(store)
        return decisionPending(confirmations: store.turnConfirmations, assistantMessageID: execution?.record.assistantMessageID,
                               fallback: store.turnExecutions.isEmpty && store.pendingToolConfirmation != nil)
    }

    static func terminalEvent(turn: NativeConversationTurn.State?, message: Message?) -> TandemLogoTurnOutcome {
        if let turn {
            switch turn {
            case .stopped: return .canceled
            case .interrupted: return .failed
            case .complete: return message.map(Self.spoke) == true ? .completed : .none
            case .pending, .running: return .none
            }
        }
        guard let message else { return .none }
        if message.failure != nil { return .failed }
        if message.state == .interrupted { return .canceled }
        return spoke(message) ? .completed : .none
    }

    private static func spoke(_ message: Message) -> Bool {
        message.state == .complete && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        next.decisionPending = Self.selectedDecisionPending(store)
        if running {
            let execution = Self.selectedExecution(store)
            activeTurn = TandemLogoTurnFocus(conversationID: selectedID, turnID: execution?.record.id,
                                             assistantMessageID: execution?.record.assistantMessageID)
        } else if let ended = activeTurn {
            activeTurn = nil
            if ended.conversationID == selectedID {
                let turnState = ended.turnID.flatMap { id in store.conversationTurns.first { $0.id == id }?.state }
                let messages = store.selected?.messages ?? []
                let message = ended.assistantMessageID.flatMap { id in messages.first { $0.id == id } }
                    ?? messages.last(where: { $0.role == .assistant })
                switch Self.terminalEvent(turn: turnState, message: message) {
                case .completed: next.turnCompleted = true
                case .failed: next.turnFailed = true
                case .canceled: next.turnCanceled = true
                case .none: break
                }
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

struct TandemLogoTurnFocus: Equatable {
    var conversationID: String?
    var turnID: UUID?
    var assistantMessageID: UUID?
}

enum TandemLogoTurnOutcome: Equatable {
    case none, completed, failed, canceled
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
