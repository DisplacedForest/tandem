import Foundation

@MainActor
enum VoiceEntrySelftest {
    static func run() async throws {
        let require = NativeTaskFixture.require
        try requireMerge(require)
        try requireGate(require)
        try await requireDictation(require)
        try await requireDeniedMicrophone(require)
        try await requireUnreachableService(require)
        try await requireMidSessionFailure(require)
        try await requireVoiceChatFailure(require)
        print("VOICE ENTRY OK")
    }

    private static func requireMerge(_ require: (Bool, String) throws -> Void) throws {
        try require(ComposerDictation.merge(base: "", "hello") == "hello", "Dictation fills an empty draft")
        try require(ComposerDictation.merge(base: "Note:", " hello ") == "Note: hello", "Dictation is separated from typed text")
        try require(ComposerDictation.merge(base: "Note: ", "hello") == "Note: hello", "Existing trailing space is kept")
        try require(ComposerDictation.merge(base: "Note", "") == "Note", "Silence leaves the draft alone")
    }

    private static func requireGate(_ require: (Bool, String) throws -> Void) throws {
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        let environmentBase = ProcessInfo.processInfo.environment["VERA_VOICE_BASE"] ?? ""
        if environmentBase.isEmpty {
            try require(!config.voiceConfigured, "No voice address means voice is not configured")
            let bare = VoiceSession(client: VoiceClient(base: config.voiceBase), socket: nil, store: fixtureStore())
            try require(!bare.supportsDictation, "No voice address means no dictation")
            try require(!bare.supportsVoiceChat, "No voice address means no voice chat")
        }
        config["voice_base"] = "http://voice.test:8131"
        try require(config.voiceConfigured, "A voice address configures voice")
        let dictationOnly = VoiceSession(client: VoiceClient(base: config.voiceBase), socket: nil, store: fixtureStore())
        try require(dictationOnly.supportsDictation, "A voice address enables dictation")
        try require(!dictationOnly.supportsVoiceChat, "Voice chat needs the reply backend too")
        let socket = VeraSocket(config: VoiceSocketConfig(baseURL: URL(string: "http://chat.test")!, apiKey: "fixture", model: "fixture"))
        let full = VoiceSession(client: VoiceClient(base: config.voiceBase), socket: socket, store: fixtureStore())
        try require(full.supportsDictation && full.supportsVoiceChat, "A voice address and reply backend enable voice chat")
        config["voice_base"] = "   "
        try require(environmentBase.isEmpty ? !config.voiceConfigured : config.voiceConfigured, "A blank voice address follows the environment")
    }

    private static func requireDictation(_ require: (Bool, String) throws -> Void) async throws {
        let capture = FakeCapture()
        let source = FakeTranscriptSource(["hello", "world", "again", "more"])
        let session = makeSession(capture, source)
        let recorder = DictationRecorder()
        session.startDictation(onText: recorder.record)
        try await waitFor { capture.listening }
        try require(session.isDictating, "Dictation is running")
        try require(session.state == .idle && !session.isActive, "Dictation never opens the voice chat surface")
        session.utteranceEnded()
        try await waitFor { recorder.events.count == 1 }
        try require(recorder.events[0] == DictationEvent(text: "hello", isFinal: false), "The first phrase arrives as partial text")
        session.utteranceEnded()
        try await waitFor { recorder.events.count == 2 }
        try require(recorder.events[1] == DictationEvent(text: "hello world", isFinal: false), "Partial text accumulates")
        try require(session.state == .idle, "Dictation never thinks or speaks")
        session.stopDictation()
        try require(!session.isDictating, "Stopping clears the dictating state at once")
        try require(!capture.listening && capture.ended >= 1, "Stopping ends capture")
        try await waitFor { recorder.events.last?.isFinal == true }
        try require(recorder.events.last == DictationEvent(text: "hello world again", isFinal: true), "The final text includes the last phrase")
        try require(recorder.events.filter(\.isFinal).count == 1, "Exactly one final delivery")
        try require(session.entryError == nil, "A clean dictation reports nothing")
        try require(source.opened == 3, "Each phrase uses one transcript")
        let reran = DictationRecorder()
        session.startDictation(onText: reran.record)
        try await waitFor { capture.listening }
        try require(session.isDictating, "Dictation can start again after it finishes")
        session.stopDictation()
        try await waitFor { reran.events.last?.isFinal == true }
    }

    private static func requireDeniedMicrophone(_ require: (Bool, String) throws -> Void) async throws {
        let capture = FakeCapture()
        capture.authorized = false
        let session = makeSession(capture, FakeTranscriptSource(["unused"]))
        let recorder = DictationRecorder()
        session.startDictation(onText: recorder.record)
        try await waitFor { session.entryError != nil }
        try require(session.entryError == VoiceEntryFailure.microphoneDenied.message, "A denied microphone explains where to allow it")
        try require(!session.isDictating && !capture.listening && capture.begun == 0, "A denied microphone leaves dictation idle")
        try await waitFor { recorder.events.last?.isFinal == true }
        try require(recorder.events.allSatisfy { $0.text.isEmpty }, "A denied microphone adds no text")
    }

    private static func requireUnreachableService(_ require: (Bool, String) throws -> Void) async throws {
        let capture = FakeCapture()
        let source = FakeTranscriptSource([])
        let session = makeSession(capture, source)
        session.startDictation(onText: DictationRecorder().record)
        try await waitFor { session.entryError != nil }
        try require(session.entryError == VoiceEntryFailure.serviceUnreachable.message, "An unreachable service points at Settings")
        try require(!session.isDictating && !capture.listening && capture.ended >= 1, "An unreachable service releases the microphone")
        try require(session.state == .idle, "An unreachable service leaves no listening state")
    }

    private static func requireMidSessionFailure(_ require: (Bool, String) throws -> Void) async throws {
        let capture = FakeCapture()
        let source = FakeTranscriptSource(["kept"])
        let session = makeSession(capture, source)
        let recorder = DictationRecorder()
        session.startDictation(onText: recorder.record)
        try await waitFor { capture.listening }
        session.utteranceEnded()
        try await waitFor { recorder.events.last?.isFinal == true }
        try require(recorder.events.last?.text == "kept", "Text heard before a failure is kept")
        try require(session.entryError == VoiceEntryFailure.serviceUnreachable.message, "A lost service is reported")
        try require(!session.isDictating && !capture.listening, "A lost service stops dictation")
    }

    private static func requireVoiceChatFailure(_ require: (Bool, String) throws -> Void) async throws {
        let capture = FakeCapture()
        capture.authorized = false
        let session = makeSession(capture, FakeTranscriptSource(["unused"]))
        session.start()
        try await waitFor { session.entryError != nil }
        try require(session.entryError == VoiceEntryFailure.microphoneDenied.message, "Voice chat explains a denied microphone")
        try require(session.state == .idle && !session.isActive, "Voice chat stays closed after a failed start")
    }

    private static func fixtureStore() -> ChatStore {
        ChatStore(nativeConfig: nil, nativeTransport: nil, repository: try? LocalChatRepository(inMemory: true),
                  artifactPersistenceEnabled: false)
    }

    private static func makeSession(_ capture: FakeCapture, _ source: FakeTranscriptSource) -> VoiceSession {
        VoiceSession(client: VoiceClient(host: "voice.test"), socket: nil, store: fixtureStore(),
                     capture: capture, transcription: { try source.open() })
    }

    private static func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NativeTaskFixture.Failure.assertion("Timed out waiting for the voice session")
    }
}

private struct DictationEvent: Equatable {
    let text: String
    let isFinal: Bool
}

@MainActor
private final class DictationRecorder {
    var events: [DictationEvent] = []

    func record(_ text: String, _ isFinal: Bool) {
        events.append(DictationEvent(text: text, isFinal: isFinal))
    }
}

@MainActor
private final class FakeCapture: VoiceCaptureDevice {
    var authorized = true
    var listening = false
    var begun = 0
    var ended = 0

    func authorize() async -> Bool { authorized }
    func begin() throws { begun += 1 }
    func listen(_ on: Bool) { listening = on }

    func end() {
        listening = false
        ended += 1
    }
}

private final class FakeTranscriptSource: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String]
    private(set) var opened = 0

    init(_ texts: [String]) { self.texts = texts }

    func open() throws -> any VoiceTranscript {
        lock.lock(); defer { lock.unlock() }
        guard !texts.isEmpty else { throw VoiceError.notConfigured }
        opened += 1
        return FakeTranscript(texts.removeFirst())
    }
}

private final class FakeTranscript: VoiceTranscript, @unchecked Sendable {
    private let text: String

    init(_ text: String) { self.text = text }

    func send(_ pcm16k: Data) {}

    func finish() async throws -> String { text }
}
