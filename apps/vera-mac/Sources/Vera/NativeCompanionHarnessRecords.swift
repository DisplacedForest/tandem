import Foundation

extension NativeCompanionHarness {
    static let unsavedAllowMessage = "An allow record must be saved with saveRecords. The ledger looks an allow up in the database before it admits a write, so an allow held only in memory is refused as spent."

    var records: NativeRuleRecordStore {
        let clock = clock
        return NativeRuleRecordStore(database: repository.database, now: { clock.now })
    }

    @discardableResult
    mutating func saveRecords(_ next: [NativeRuleRecord]) throws -> [NativeRuleRecord] {
        let store = records
        let saved = try next.map { try store.add($0) }
        let rules = rules
        ChatStore.prepareRules(rules, from: store)
        environment.recordsChanged = { ChatStore.reloadRules(rules, from: store) }
        return saved
    }

    func setRecords(_ next: [NativeRuleRecord]) throws {
        rules.setRecords(next)
        try requireSavedAllows()
    }

    func requireSavedAllows() throws {
        let allows = rules.currentRecords.filter { $0.effect == .allow }
        guard !allows.isEmpty else { return }
        let saved = Set(try records.all().map(\.id))
        guard allows.allSatisfy({ saved.contains($0.id) }) else { throw NativeTaskFixture.Failure.assertion(Self.unsavedAllowMessage) }
    }
}

@MainActor
extension SelfTest {
    static func companionSavedAllows() async throws {
        let require = NativeTaskFixture.require
        let script: @Sendable ([NativeTaskGenerationMessage]) -> NativeTaskGenerationCompletion = { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call("water_bed", "{\"bed\":\"north\"}") : NativeCompanionScriptedModel.text("Watered the north bed.")
        }
        let allow = NativeRuleRecord(action: .networkSends, effect: .allow, statement: "Always allow sending")
        var saved = try NativeCompanionHarness(rules: [.networkSends: .ask], script: script)
        let stored = try saved.saveRecords([allow])
        let id = try saved.create()
        let done = try await saved.runUntilSettled()
        try require(done.state == .completed && saved.service.count("water_bed") == 1 && (try saved.effects(id)).map(\.state) == [.completed]
                        && saved.rules.currentRecords.map(\.id) == stored.map(\.id),
                    "A saved everywhere allow under an ask default is admitted and the write happens")

        func setupFailure(_ body: () throws -> Void) -> String? {
            do { try body() } catch NativeTaskFixture.Failure.assertion(let message) { return message } catch { return nil }
            return nil
        }
        let wrapped = try NativeCompanionHarness(rules: [.networkSends: .ask], script: script)
        try require(setupFailure { try wrapped.setRecords([allow]) } == NativeCompanionHarness.unsavedAllowMessage,
                    "Setting an allow in memory through the harness fails at once and names saveRecords")
        let direct = try NativeCompanionHarness(rules: [.networkSends: .ask], script: script)
        direct.rules.setRecords([allow])
        try require(setupFailure { _ = try direct.create() } == NativeCompanionHarness.unsavedAllowMessage && direct.service.count("water_bed") == 0,
                    "An allow put straight into the rule source fails when the task is created, before any admission")
        let late = try NativeCompanionHarness(rules: [.networkSends: .ask], script: script)
        let lateID = try late.create()
        late.rules.setRecords([allow])
        var lateMessage: String?
        do { _ = try await late.step() } catch NativeTaskFixture.Failure.assertion(let message) { lateMessage = message }
        try require(lateMessage == NativeCompanionHarness.unsavedAllowMessage && (try late.effects(lateID)).isEmpty,
                    "An allow put in memory after the task exists fails before the next step proposes anything")
        let restrictive = try NativeCompanionHarness(rules: [.networkSends: .act], script: script)
        try restrictive.setRecords([NativeRuleRecord(action: .networkSends, effect: .ask, statement: "Ask before sending")])
        _ = try restrictive.create()
        try require(try await restrictive.runUntilSettled().state == .needsDecision && restrictive.service.count("water_bed") == 0,
                    "A restrictive record may stay in memory and still tightens the decision")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("worker-saved-allow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = try FolderGrant.make(url: directory)

        var commands = try NativeCompanionHarness(rules: [.commands: .ask]) { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call(NativeCommandTools.runName, "{\"command\":\"echo admitted\"}") : NativeCompanionScriptedModel.text("Ran the check.")
        }
        let commandTools = ChatStore.companionCommandDefinitions(grants: { [grant] })
        let commandThread = commands.thread
        commands.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: commandThread.current, tools: commandTools) }
        try commands.saveRecords([NativeRuleRecord(action: .commands, effect: .allow, statement: "Always allow commands")])
        let commandID = try commands.create("Run the check")
        let ran = try await commands.runUntilSettled()
        let commandEffects = try commands.effects(commandID)
        var stdout = ""
        if case .object(let fields)? = commandEffects.first?.receipt, case .string(let text)? = fields["stdout"] { stdout = text }
        try require(ran.state == .completed && commandEffects.map(\.state) == [.completed] && stdout.contains("admitted"),
                    "A saved everywhere allow under an ask default runs a command through the production command tool without asking")

        let target = grant.path + "/note.txt"
        var folders = try NativeCompanionHarness(rules: [.fileEdits: .ask]) { messages in
            NativeCompanionScriptedModel.toolResults(messages).isEmpty
                ? NativeCompanionScriptedModel.call(NativeFolderTools.writeName, "{\"path\":\"\(target)\",\"content\":\"x\"}") : NativeCompanionScriptedModel.text("Saved it.")
        }
        let folderRules = folders.rules
        let folderThread = folders.thread
        let folderTools = NativeFolderTools.definitions(grants: { [grant] }, ledger: NativeFileChangeLedger(), edits: .ask, trash: .ask, live: { action in
            folderRules.resolver(for: folderThread.current, requestText: "").decision(for: action)
        })
        folders.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: folderThread.current, tools: folderTools) }
        try folders.saveRecords([NativeRuleRecord(action: .fileEdits, effect: .allow, statement: "Always allow file edits")])
        let folderID = try folders.create("Save the note")
        let wrote = try await folders.runUntilSettled()
        try require(wrote.state == .completed && FileManager.default.fileExists(atPath: target) && (try folders.effects(folderID)).map(\.state) == [.completed],
                    "A saved everywhere allow under an ask default writes a file through the production folder tools without asking")
    }
}
