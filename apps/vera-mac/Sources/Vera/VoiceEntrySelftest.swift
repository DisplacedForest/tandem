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
        try await requireFinishFailures(require)
        try await requireDraftBinding(require)
        try await requireLiveConfiguration(require)
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

    private static func requireFinishFailures(_ require: (Bool, String) throws -> Void) async throws {
        let midCapture = FakeCapture()
        let mid = makeSession(midCapture, FakeTranscriptSource(["hello", nil, nil]))
        let midEvents = DictationRecorder()
        mid.startDictation(onText: midEvents.record)
        try await waitFor { midCapture.listening }
        mid.utteranceEnded()
        try await waitFor { midEvents.events.count == 1 }
        mid.utteranceEnded()
        try await waitFor { midEvents.events.last?.isFinal == true }
        try require(midEvents.events.last?.text == "hello", "A failed phrase keeps the text heard before it")
        try require(mid.entryError == VoiceEntryFailure.serviceUnreachable.message, "A failed phrase is reported")
        try require(!mid.isDictating && !midCapture.listening && midCapture.ended >= 1, "A failed phrase stops recording")

        let finalCapture = FakeCapture()
        let last = makeSession(finalCapture, FakeTranscriptSource(["hello", nil]))
        let lastEvents = DictationRecorder()
        last.startDictation(onText: lastEvents.record)
        try await waitFor { finalCapture.listening }
        last.utteranceEnded()
        try await waitFor { lastEvents.events.count == 1 }
        last.stopDictation()
        try await waitFor { lastEvents.events.last?.isFinal == true }
        try require(lastEvents.events.last?.text == "hello", "A failed last phrase keeps the earlier text")
        try require(last.entryError == VoiceEntryFailure.serviceUnreachable.message, "A failed last phrase is reported")
        try require(!last.isDictating && !finalCapture.listening, "A failed last phrase leaves nothing recording")
    }

    private static func requireDraftBinding(_ require: (Bool, String) throws -> Void) async throws {
        var binding = DictationDraftBinding(conversationID: "a", draft: "Hi")
        var draft = binding.apply("hello", to: "Hi")
        try require(draft == "Hi hello", "Dictation lands after the starting draft")
        draft += " there"
        draft = binding.apply("hello world", to: draft)
        try require(draft == "Hi hello world there", "Typing after dictation started survives a later partial")
        draft = binding.apply("hello world again", to: "Rewritten")
        try require(draft == "Rewritten hello world again", "A moved segment is appended instead of overwriting edits")

        let capture = FakeCapture()
        let session = makeSession(capture, FakeTranscriptSource(["one", "two", "three", "four", "five", "six"]))
        let box = DraftBox()
        let controller = ComposerDictationController()
        func start() {
            controller.start(voice: session, conversationID: box.selected, read: { box.draft },
                             write: { box.draft = $0 }, selected: { box.selected })
        }
        box.draft = "Start"
        start()
        try await waitFor { capture.listening }
        session.utteranceEnded()
        try await waitFor { box.draft == "Start one" }
        box.draft += " typed"
        session.utteranceEnded()
        try await waitFor { box.draft == "Start one two typed" }
        box.selected = "b"
        box.draft = "Other conversation"
        session.utteranceEnded()
        try await waitFor { !session.isDictating && !session.hasPendingDictation }
        try require(box.draft == "Other conversation", "A conversation switch leaves the other draft untouched")
        try require(!capture.listening && !controller.isBound, "A conversation switch stops capture")

        box.draft = ""
        start()
        try await waitFor { capture.listening }
        session.utteranceEnded()
        try await waitFor { box.draft == "five" }
        controller.detach(session)
        box.draft = ""
        try await waitFor { !session.isDictating && !session.hasPendingDictation }
        try require(box.draft.isEmpty, "A final delivery after Send does not repopulate the field")
        try require(!capture.listening, "Sending stops capture")
    }

    private static func requireLiveConfiguration(_ require: (Bool, String) throws -> Void) async throws {
        guard (ProcessInfo.processInfo.environment["VERA_VOICE_BASE"] ?? "").isEmpty else { return }
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        let capture = FakeCapture()
        let session = VoiceSession(client: VoiceClient(base: config.voiceBase), socket: nil, store: fixtureStore(),
                                   capture: capture, transcription: { try FakeTranscriptSource(["live"]).open() })
        session.observe(config)
        try require(!session.supportsDictation, "No address starts without dictation")
        config["voice_base"] = "http://first.test:8131"
        try await waitFor { session.supportsDictation }
        try require(session.voiceHost == "first.test", "Configuring from nothing enables dictation")
        config["voice_base"] = "http://second.test:8131"
        try await waitFor { session.voiceHost == "second.test" }
        try require(session.supportsDictation && session.entryError == nil, "Replacing an idle address is silent")
        session.startDictation(onText: DictationRecorder().record)
        try await waitFor { capture.listening }
        config["voice_base"] = "http://third.test:8131"
        try await waitFor { session.voiceHost == "third.test" }
        try require(!session.isDictating && !capture.listening, "Changing the address ends an active dictation")
        try require(session.entryError == VoiceEntryFailure.settingsChanged.message, "An interrupted dictation explains why")
        config["voice_base"] = ""
        try await waitFor { !session.supportsDictation }
        try require(!session.supportsVoiceChat && session.voiceHost.isEmpty, "Removing the address hides voice")
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

@MainActor
private final class DraftBox {
    var draft = ""
    var selected: String? = "a"
}

private final class FakeTranscriptSource: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String?]
    private(set) var opened = 0

    init(_ texts: [String?]) { self.texts = texts }

    func open() throws -> any VoiceTranscript {
        lock.lock(); defer { lock.unlock() }
        guard !texts.isEmpty else { throw VoiceError.notConfigured }
        opened += 1
        return FakeTranscript(texts.removeFirst())
    }
}

private final class FakeTranscript: VoiceTranscript, @unchecked Sendable {
    private let text: String?

    init(_ text: String?) { self.text = text }

    func send(_ pcm16k: Data) {}

    func finish() async throws -> String {
        guard let text else { throw VoiceError.notConfigured }
        return text
    }
}
