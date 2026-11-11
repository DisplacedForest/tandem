import Foundation

final class NativeCompanionLiveNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [String] = []
    func save(_ text: String) { lock.withLock { saved.append(text) } }
    var all: [String] { lock.withLock { saved } }
}

@MainActor
enum NativeCompanionLive {
    static let defaultAssignment = "Use web search to find the current list price of a Raspberry Pi 5 with 8 GB of memory, read one source page, then save a short note with the price and the source using save_note."

    static func notesTool(_ notes: NativeCompanionLiveNotes) -> NativeToolDefinition {
        var tool = NativeToolDefinition(
            id: "companion-live-notes", name: "save_note", title: "Save a note", description: "Save a short note for the person.",
            parameters: .object(["type": .string("object"),
                                 "properties": .object(["title": .object(["type": .string("string")]), "text": .object(["type": .string("string")])]),
                                 "required": .array([.string("title"), .string("text")])]),
            confirmation: .required, isAvailable: { true }, execute: { arguments in
                let title: String
                if case .string(let value)? = arguments["title"] { title = value } else { title = "" }
                let text: String
                if case .string(let value)? = arguments["text"] { text = value } else { text = "" }
                notes.save(title + ": " + text)
                return .object(["saved": .bool(true), "title": .string(title)])
            })
        tool.effect = .write
        tool.action = .networkSends
        return tool
    }

    static func run(arguments: [String]) async -> Int32 {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vera").standardizedFileURL.path
        guard let override = ProcessInfo.processInfo.environment["VERA_CONFIG_DIR"], !override.isEmpty,
              URL(fileURLWithPath: override).standardizedFileURL.path != home else {
            print("companion-live: set VERA_CONFIG_DIR to a separate folder holding a copy of config.json. It never runs against your own data.")
            return 2
        }
        let config = ConfigStore(writeConfiguration: { _ in })
        guard let native = config.nativeResolved else {
            print("companion-live: no chat profile is configured in \(override)/config.json.")
            return 2
        }
        let assignment = arguments.firstIndex(of: "--assignment").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? defaultAssignment
        let choice = arguments.contains("--decline") ? "decline" : "approve"
        let repository: LocalChatRepository
        do { repository = try LocalChatRepository() } catch {
            print("companion-live: FAIL the database could not open: \(error.localizedDescription)")
            return 1
        }
        var rules = config.nativeSettings.rules
        rules.choices[.networkSends] = .ask
        let store = ChatStore(nativeConfig: native, nativeTransport: NativeChatClient.foreground(config: native), repository: repository,
                              nativeAssistantName: config.suppliedAssistantName, nativeEnabledToolIDs: config.nativeSettings.enabledToolIDs,
                              nativeRules: rules,
                              nativeTaskConfiguration: NativeTaskConfiguration(settings: { config.nativeSettings },
                                                                               savedTemplate: { config["chat_template_kwargs"] }))
        let notes = NativeCompanionLiveNotes()
        store.companionWorkerRelay.extraTools = [notesTool(notes)]
        await store.connect()
        store.skipDotSetup()
        print("companion-live: model \(native.model), assignment: \(assignment)")
        if let failure = await store.startCompanionAssignment(assignment) {
            print("companion-live: FAIL could not start: \(failure.plain(name: store.companionName))")
            return 1
        }
        guard let reference = store.companionWorkReferences().last else {
            print("companion-live: FAIL no companion task was created")
            return 1
        }
        let projections = repository as any NativeTaskProjectionRepository
        var last = ""
        var answered: Set<String> = []
        let deadline = Date().addingTimeInterval(420)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            store.reloadNativeTaskReferences()
            guard let saved = try? projections.taskProjection(id: reference.id), let snapshot = saved.snapshot else { continue }
            let line = "\(snapshot.state.rawValue)"
            if line != last {
                print("companion-live: state \(line)")
                last = line
            }
            if snapshot.state == .needsDecision, let decision = snapshot.decision, !answered.contains(decision.id) {
                answered.insert(decision.id)
                let pick: String
                if decision.choices.contains("approve") { pick = choice }
                else if decision.choices.contains("continue") { pick = answered.count <= 1 ? "continue" : "finish" }
                else if decision.choices.contains("stop") { pick = "stop" }
                else { pick = decision.choices.first ?? "retry" }
                print("companion-live: decision \"\(CompanionSavedText.question(decision.prompt).plain(name: nil))\" choices \(decision.choices) answering \(pick)")
                store.answerNativeTask(reference.id.uuidString, choice: pick)
            }
            if snapshot.state.isTerminal {
                store.openVeraThread()
                for _ in 0..<10 where ((try? repository.artifactIDs(conversationID: reference.origin.conversationID)) ?? []).isEmpty {
                    store.reloadNativeTaskReferences()
                    store.reconcileTaskArtifacts(conversationID: reference.origin.conversationID)
                    try? await Task.sleep(for: .seconds(1))
                }
                let result = (try? NativeTaskStore(database: repository.database).get(snapshot.id))?.result
                    .flatMap { try? NativeTaskStore.object($0) } ?? [:]
                print("companion-live: summary \(result["summary"] as? String ?? "")")
                print("companion-live: effects \(result["effects"] ?? [])")
                print("companion-live: report\n\(result["report"] as? String ?? "")")
                let ledger = (try? NativeEffectLedgerStore(database: repository.database).records(taskID: snapshot.id)) ?? []
                print("companion-live: ledger \(ledger.map { "\($0.proposal.function) \($0.state.rawValue)" })")
                print("companion-live: notes saved by the fake adapter \(notes.all)")
                let artifacts = (try? repository.artifactIDs(conversationID: reference.origin.conversationID)) ?? []
                print("companion-live: artifacts in the companion conversation \(artifacts.count)")
                store.stopNativeTaskRecovery()
                return snapshot.state == .completed ? 0 : 1
            }
        }
        print("companion-live: FAIL the task did not settle within seven minutes (last state \(last))")
        store.stopNativeTaskRecovery()
        return 1
    }
}
