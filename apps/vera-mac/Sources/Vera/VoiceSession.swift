import SwiftUI
import Combine
import AVFoundation
import AppKit

/// The in-app voice session — a `@MainActor` state machine that orchestrates
/// mic capture → energy-VAD endpointing → Whisper STT → Vera (the shared OWUI socket) →
/// sentence-chunked Kokoro TTS → ordered playback, logging each turn into the chat thread.
/// No barge-in yet: while Vera is thinking/speaking the mic VAD is paused.
@MainActor
final class VoiceSession: ObservableObject {
    enum State: Equatable { case idle, listening, transcribing, thinking, speaking }

    @Published private(set) var state: State = .idle
    @Published private(set) var activeConversationID: String?
    @Published private(set) var isPlayingAudio = false
    @Published private(set) var level: Float = 0    // mic level 0...1 for the orb pulse
    @Published var lastError: String?
    @Published private(set) var statusLine: String?    // pipeline progress (e.g. "web search") while thinking
    @Published private(set) var debugDB: Float = -120   // live input level (dBFS) — diagnostics
    @Published private(set) var debugFrames = 0         // tap callbacks seen — diagnostics
    @Published private(set) var debugFloor: Float = -45 // adaptive noise floor (dBFS) — diagnostics
    @Published private(set) var debugSpeech = false     // VAD inSpeech state — diagnostics
    @Published private(set) var isDictating = false
    @Published var entryError: String?

    private var client: VoiceClient
    private let socket: VeraSocket?
    private unowned let store: ChatStore

    private let engine = AVAudioEngine()
    private let mic: MicCapture
    private let queue: AudioQueue

    private var streamTask: Task<Void, Never>?
    private var sttStream: (any VoiceTranscript)?
    private let capture: any VoiceCaptureDevice
    private var openTranscription: @Sendable () async throws -> any VoiceTranscript
    private let fixedTranscription: Bool
    private var configSubscription: AnyCancellable?
    private var opening = false
    private var chatGeneration = 0
    private var captureToken = 0
    private var captureOwner: Int?
    private var advancing = false
    private var dictationGeneration = 0
    private var dictationText = ""
    private var dictationHandler: (@MainActor (String, Bool) -> Void)?
    private var dictationTail: Task<Void, Never>?
    private var warmed = false
    private var playbackHold: Task<Void, Never>?
    private var playbackEvents = PlaybackEventFilter()

    var isActive: Bool { state != .idle }

    var supportsDictation: Bool { !client.host.isEmpty }

    var supportsVoiceChat: Bool { supportsDictation && socket != nil }

    var voiceHost: String { client.host }

    var hasPendingDictation: Bool { dictationTail != nil }

    var isOpening: Bool { opening }

    init(client: VoiceClient, socket: VeraSocket?, store: ChatStore,
         capture: (any VoiceCaptureDevice)? = nil,
         transcription: (@Sendable () async throws -> any VoiceTranscript)? = nil) {
        self.client = client
        self.socket = socket
        self.store = store
        let mic = MicCapture(engine: engine)
        self.mic = mic
        self.queue = AudioQueue(engine: engine)
        self.capture = capture ?? MicEngineCapture(engine: engine, mic: mic)
        self.openTranscription = transcription ?? Self.transcription(for: client)
        self.fixedTranscription = transcription != nil
        configureCallbacks()
    }

    private static func transcription(for client: VoiceClient) -> @Sendable () async throws -> any VoiceTranscript {
        { try await client.startTranscription() }
    }

    func observe(_ config: ConfigStore) {
        configSubscription = config.voiceBasePublisher
            .map { $0?.host ?? "" }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self, weak config] _ in
                Task { @MainActor in
                    guard let self, let config else { return }
                    self.configure(voiceBase: config.voiceBase)
                }
            }
    }

    func configure(voiceBase: URL?) {
        let next = VoiceClient(base: voiceBase)
        guard next.host != client.host else { return }
        var interrupted = false
        if isDictating {
            finishDictation(nil)
            interrupted = true
        }
        if state != .idle || opening {
            stop()
            interrupted = true
        }
        objectWillChange.send()
        client = next
        warmed = false
        if !fixedTranscription { openTranscription = Self.transcription(for: next) }
        if interrupted { entryError = VoiceEntryFailure.settingsChanged.message }
    }

    private func configureCallbacks() {
        mic.onLevel = { [weak self] lvl, db in Task { @MainActor in self?.updateLevel(lvl, db) } }
        // Stream captured 16 kHz mono PCM frames into the open STT connection while listening.
        mic.onFrame = { [weak self] pcm in Task { @MainActor in self?.sttStream?.send(pcm) } }
        mic.onUtterance = { [weak self] _ in Task { @MainActor in self?.utteranceEnded() } }
        mic.onDebug = { [weak self] floor, sp in Task { @MainActor in self?.debugFloor = floor; self?.debugSpeech = sp } }
        queue.onDrained = { [weak self] in Task { @MainActor in self?.handleDrained() } }
        queue.onPlayback = { [weak self] sequence, playing in Task { @MainActor in self?.playbackChanged(sequence, playing) } }
    }

    private func playbackChanged(_ sequence: Int, _ playing: Bool) {
        guard playbackEvents.admits(sequence) else { return }
        playbackHold?.cancel()
        playbackHold = nil
        if playing {
            isPlayingAudio = true
            return
        }
        guard state == .speaking, isPlayingAudio else {
            isPlayingAudio = false
            return
        }
        playbackHold = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.isPlayingAudio = false
        }
    }

    private func clearPlayback() {
        playbackHold?.cancel()
        playbackHold = nil
        isPlayingAudio = false
    }

    private func updateLevel(_ lvl: Float, _ db: Float) {
        debugDB = db
        debugFrames += 1
        guard state == .listening || isDictating else { return }
        level = lvl
    }

    // MARK: - Lifecycle

    func start() {
        guard state == .idle, !opening, !isDictating, dictationTail == nil else { return }
        activeConversationID = store.selectedID
        lastError = nil
        entryError = nil
        opening = true
        chatGeneration &+= 1
        let generation = chatGeneration
        Task {
            defer {
                opening = false
                if generation == chatGeneration && state == .idle { activeConversationID = nil }
            }
            let token: Int
            switch await openCapture(isCurrent: { [weak self] in self?.chatGeneration == generation }) {
            case .stale: return
            case .failed(let failure):
                entryError = failure.message
                return
            case .began(let began): token = began
            }
            queue.start()
            await prewarm()
            guard generation == chatGeneration else {
                releaseStaleStart(token)
                return
            }
            let stream = await openTranscript()
            guard generation == chatGeneration else {
                if let stream { Task { _ = try? await stream.finish() } }
                releaseStaleStart(token)
                return
            }
            guard let stream else {
                queue.stop()
                endCapture()
                entryError = VoiceEntryFailure.serviceUnreachable.message
                return
            }
            beginListening(with: stream)
        }
    }

    private func releaseStaleStart(_ token: Int) {
        guard captureOwner == token else { return }
        queue.stop()
        endCapture()
    }

    private func endCapture() {
        capture.end()
        captureOwner = nil
    }

    func stop() {
        chatGeneration &+= 1
        if isDictating { finishDictation(nil) }
        streamTask?.cancel(); streamTask = nil
        sttStream = nil
        queue.stop()
        clearPlayback()
        endCapture()
        level = 0
        state = .idle
        activeConversationID = nil
    }

    private func beginListening(with stream: (any VoiceTranscript)? = nil) {
        state = .listening
        level = 0
        statusLine = nil
        sttStream = stream
        if stream == nil {
            let generation = chatGeneration
            Task {
                let opened = await openTranscript()
                guard generation == chatGeneration, state == .listening else {
                    if let opened { Task { _ = try? await opened.finish() } }
                    return
                }
                sttStream = opened
            }
        }
        capture.listen(true)
    }

    private enum CaptureOpening {
        case began(Int)
        case failed(VoiceEntryFailure)
        case stale
    }

    private func openCapture(isCurrent: @MainActor () -> Bool) async -> CaptureOpening {
        let authorized = await capture.authorize()
        guard isCurrent() else { return .stale }
        guard authorized else { return .failed(.microphoneDenied) }
        do {
            try capture.begin()
        } catch {
            endCapture()
            return .failed(.microphoneUnavailable)
        }
        captureToken &+= 1
        captureOwner = captureToken
        return .began(captureToken)
    }

    private func openTranscript() async -> (any VoiceTranscript)? {
        try? await openTranscription()
    }

    func startDictation(onText: @escaping @MainActor (String, Bool) -> Void) {
        guard state == .idle, !opening, !isDictating, dictationTail == nil else { return }
        entryError = nil
        dictationGeneration &+= 1
        let generation = dictationGeneration
        dictationText = ""
        dictationHandler = onText
        isDictating = true
        Task {
            let token: Int
            switch await openCapture(isCurrent: { [weak self] in self?.dictationGeneration == generation && self?.isDictating == true }) {
            case .stale: return
            case .failed(let failure):
                finishDictation(failure)
                return
            case .began(let began): token = began
            }
            let stream = await openTranscript()
            guard generation == dictationGeneration, isDictating else {
                if let stream { Task { _ = try? await stream.finish() } }
                releaseAbandonedCapture(token)
                return
            }
            guard let stream else {
                finishDictation(.serviceUnreachable)
                return
            }
            sttStream = stream
            capture.listen(true)
        }
    }

    func stopDictation() {
        finishDictation(nil)
    }

    func utteranceEnded() {
        if isDictating {
            advanceDictation()
        } else {
            handleEndOfTurn()
        }
    }

    private func releaseAbandonedCapture(_ token: Int) {
        guard captureOwner == token else { return }
        endCapture()
    }

    private func finishDictation(_ failure: VoiceEntryFailure?) {
        guard isDictating else { return }
        let generation = dictationGeneration
        let handler = dictationHandler
        isDictating = false
        dictationHandler = nil
        endCapture()
        level = 0
        if let failure { entryError = failure.message }
        if let current = sttStream {
            sttStream = nil
            enqueueDictation(current, generation: generation)
        }
        let tail = dictationTail
        dictationTail = Task {
            await tail?.value
            guard generation == dictationGeneration else { return }
            handler?(dictationText, true)
            dictationTail = nil
        }
    }

    private func advanceDictation() {
        guard isDictating, !advancing, let finished = sttStream else { return }
        advancing = true
        let generation = dictationGeneration
        Task {
            let next = await openTranscript()
            advancing = false
            guard generation == dictationGeneration, isDictating, sttStream === finished else {
                if let next { Task { _ = try? await next.finish() } }
                return
            }
            sttStream = next
            enqueueDictation(finished, generation: generation)
            if next == nil { finishDictation(.serviceUnreachable) }
        }
    }

    private func enqueueDictation(_ stream: any VoiceTranscript, generation: Int) {
        let previous = dictationTail
        dictationTail = Task {
            await previous?.value
            guard generation == dictationGeneration else { return }
            do {
                let text = try await stream.finish()
                guard generation == dictationGeneration else { return }
                dictationText = ComposerDictation.merge(base: dictationText, text)
                if isDictating { dictationHandler?(dictationText, false) }
            } catch {
                guard generation == dictationGeneration else { return }
                if isDictating {
                    finishDictation(.serviceUnreachable)
                } else {
                    entryError = VoiceEntryFailure.serviceUnreachable.message
                }
            }
        }
    }

    /// Warm both models once at session open (in parallel) so the first real turn is fast: synth a
    /// throwaway phrase (Kokoro) and transcribe a short silent clip (Whisper). The heavy one-time
    /// model load also happens eagerly in the service at startup; this primes the per-session path.
    private func prewarm() async {
        guard !warmed, !fixedTranscription else { return }
        warmed = true
        async let tts: Data? = try? client.synthesize("Ready.", voice: nil)
        // Warm the streaming STT path: open a connection, push a short silent chunk, finalise.
        async let stt: String? = {
            guard let s = try? await client.startTranscription() else { return nil }
            s.send(MicCapture.pcm16(Array(repeating: 0, count: 3200)))   // 0.2s @ 16kHz
            return try? await s.finish()
        }()
        _ = await (tts, stt)
    }

    // MARK: - Turn handling

    private func handleEndOfTurn() {
        guard state == .listening else { return }
        capture.listen(false)
        state = .transcribing
        guard let stream = sttStream else { beginListening(); return }
        sttStream = nil
        let generation = chatGeneration
        Task {
            do {
                let text = try await stream.finish()
                guard generation == chatGeneration else { return }
                guard !text.isEmpty else { beginListening(); return }
                guard let socket, let turn = store.beginVoiceTurn(userText: text) else {
                    lastError = "Voice chat isn't set up. Check Settings."
                    beginListening(); return
                }
                state = .thinking
                NSSound(named: "Tink")?.play()
                streamReply(socket: socket, chatID: turn.chatID, messages: turn.messages, generation: generation)
            } catch {
                guard generation == chatGeneration else { return }
                lastError = error.localizedDescription
                beginListening()
            }
        }
    }

    private func streamReply(socket: VeraSocket, chatID: String, messages: [[String: Any]], generation: Int) {
        activeConversationID = chatID
        let messageID = UUID().uuidString
        var content = ""
        var spokenUpTo = 0   // character cursor into `content` already sent to TTS
        streamTask = Task {
            do {
                for try await event in socket.streamReply(chatID: chatID, messageID: messageID, messages: messages) {
                    if Task.isCancelled || generation != chatGeneration { return }
                    switch event {
                    case .sources:
                        break  // voice replies aren't rendered with chips
                    case .content(let raw):
                        content = raw
                        store.updateVoiceReply(chatID: chatID, text: content)
                        spokenUpTo = await flushSentences(content, from: spokenUpTo, generation: generation)
                    case .status(let s):
                        statusLine = s.replacingOccurrences(of: "_", with: " ")
                    case .done:
                        let chars = Array(content)
                        if spokenUpTo < chars.count {
                            let tail = String(chars[spokenUpTo...]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !tail.isEmpty { await speak(tail, generation: generation) }
                            spokenUpTo = chars.count
                        }
                        guard generation == chatGeneration else { return }
                        queue.markTurnComplete()
                    }
                }
            } catch {
                guard generation == chatGeneration else { return }
                if !Task.isCancelled {
                    lastError = error.localizedDescription
                    if state == .speaking { queue.markTurnComplete() }
                }
            }
            if generation == chatGeneration, state == .thinking { beginListening() }
        }
    }

    /// Flush speakable text beyond `from`. For the FIRST chunk of a turn (`from == 0`) we break at
    /// the first clause boundary (`,`/`;`/`:` as well as `.`/`!`/`?`) past a short minimum so audio
    /// starts fast; after that we batch on full sentence endings. Returns the new cursor.
    private func flushSentences(_ text: String, from: Int, generation: Int) async -> Int {
        let chars = Array(text)
        guard from < chars.count else { return from }
        let minLen = 12
        var lastBoundary = from

        if from == 0 {
            var i = from
            while i < chars.count {
                let c = chars[i]
                if c == "." || c == "!" || c == "?" || c == "," || c == ";" || c == ":" || c == "\n" {
                    let next = i + 1
                    if (next >= chars.count || chars[next] == " " || chars[next] == "\n"), (next - from) >= minLen {
                        lastBoundary = next; break   // first clause → speak immediately
                    }
                }
                i += 1
            }
        } else {
            var i = from
            while i < chars.count {
                let c = chars[i]
                if c == "." || c == "!" || c == "?" || c == "\n" {
                    let next = i + 1
                    if next >= chars.count || chars[next] == " " || chars[next] == "\n" { lastBoundary = next }
                }
                i += 1
            }
        }

        if lastBoundary > from {
            let sentence = String(chars[from..<lastBoundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { await speak(sentence, generation: generation) }
            return lastBoundary
        }
        return from
    }

    private func speak(_ text: String, generation: Int) async {
        let spoken = VoiceSession.speechText(text)
        guard !spoken.isEmpty, generation == chatGeneration else { return }
        if state != .speaking { state = .speaking }
        guard let wav = try? await client.synthesize(spoken, voice: nil), generation == chatGeneration else { return }
        queue.enqueue(wav: wav)
    }

    /// Convert markdown to plain spoken text — Kokoro otherwise pronounces "**" as "asterisk",
    /// "#" as "hashtag", etc. Display keeps the rich markdown; only TTS gets the stripped form.
    static func speechText(_ md: String) -> String {
        var s = NativeSpokenText.clean(md)
        // Remove any residual markers left by unpaired markdown across sentence-chunk boundaries.
        s = s.replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleDrained() {
        clearPlayback()
        guard state == .speaking else { return }
        beginListening()
    }

    /// Build a session pinned to a fixed visual state for headless screenshots
    /// (`--shot --view voice`). Not used by the running app.
    static func preview(state: State, level: Float, store: ChatStore) -> VoiceSession {
        let s = VoiceSession(client: VoiceClient(base: URL(string: "http://127.0.0.1:8131")!),
                             socket: nil, store: store)
        s.state = state
        s.level = level
        return s
    }

    // MARK: - Permission

    static func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default: return false
        }
    }
}

struct PlaybackEventFilter: Sendable {
    private(set) var latest = 0

    mutating func admits(_ sequence: Int) -> Bool {
        guard sequence > latest else { return false }
        latest = sequence
        return true
    }
}

enum VoiceEntryFailure: Equatable, Sendable {
    case microphoneDenied, microphoneUnavailable, serviceUnreachable, settingsChanged

    var message: String {
        switch self {
        case .microphoneDenied: "Microphone access is off. Allow it in System Settings, Privacy and Security."
        case .microphoneUnavailable: "The microphone didn't start. Check your input device in System Settings."
        case .serviceUnreachable: "The voice service didn't answer. Check its address in Settings."
        case .settingsChanged: "Voice stopped because its address changed in Settings. Start it again when you're ready."
        }
    }
}

@MainActor
protocol VoiceCaptureDevice: AnyObject {
    func authorize() async -> Bool
    func begin() throws
    func listen(_ on: Bool)
    func end()
}

protocol VoiceTranscript: AnyObject, Sendable {
    func send(_ pcm16k: Data)
    func finish() async throws -> String
}

extension TranscriptionStream: VoiceTranscript {}

@MainActor
final class MicEngineCapture: VoiceCaptureDevice {
    private let engine: AVAudioEngine
    private let mic: MicCapture

    init(engine: AVAudioEngine, mic: MicCapture) {
        self.engine = engine
        self.mic = mic
    }

    func authorize() async -> Bool { await VoiceSession.requestMic() }

    func begin() throws {
        mic.install()
        try engine.start()
    }

    func listen(_ on: Bool) { mic.setActive(on) }

    func end() {
        mic.setActive(false)
        mic.remove()
        engine.stop()
    }
}
