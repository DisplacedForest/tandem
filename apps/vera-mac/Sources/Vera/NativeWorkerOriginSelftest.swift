import Foundation
import GRDB

private actor NativeWorkerOriginRecorder {
    private(set) var jobs: [String: [[NativeTaskGenerationMessage]]] = [:]
    func record(_ job: NativeTaskGenerationJob) { jobs[job.taskID, default: []].append(job.messages) }
    func messages(_ taskID: String) -> [NativeTaskGenerationMessage] { (jobs[taskID] ?? []).flatMap { $0 } }
    func count(_ taskID: String) -> Int { jobs[taskID]?.count ?? 0 }
    func messages(_ taskID: String, from index: Int) -> [NativeTaskGenerationMessage] { (jobs[taskID] ?? []).dropFirst(index).flatMap { $0 } }
}

private final class NativeWorkerOriginGate: @unchecked Sendable {
    private let lock = NSLock()
    private var holding = false
    private var waiting = false
    func hold() { lock.withLock { holding = true; waiting = false } }
    func release() { lock.withLock { holding = false } }
    var isWaiting: Bool { lock.withLock { waiting } }
    private func arrive() -> Bool {
        lock.withLock {
            if holding { waiting = true }
            return holding
        }
    }
    func pass() async {
        while arrive() {
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled { return }
        }
    }
    func stall() async throws {
        if arrive() { try await Task.sleep(for: .seconds(30)) }
    }
}

private enum NativeWorkerOriginEdit { case switchOwner, delete }

@MainActor
extension SelfTest {
    static func workerOriginContract() async throws {
        let require = NativeTaskFixture.require
        try workerOriginTable(require)
        try await workerOriginEndToEnd(require)
        try await workerOriginRelaunch(require, companion: false)
        try await workerOriginRelaunch(require, companion: true)
        for workerType in ["research", "document"] {
            for companion in [false, true] {
                try await workerOriginScheduleEdit(require, workerType: workerType, companion: companion, edit: .switchOwner, relaunch: false)
                try await workerOriginScheduleEdit(require, workerType: workerType, companion: companion, edit: .switchOwner, relaunch: true)
                try await workerOriginScheduleEdit(require, workerType: workerType, companion: companion, edit: .delete, relaunch: false)
            }
        }
        try await workerOriginStoreSchedules(require)
        print("  worker origin OK (companion name only for work delivered to the companion's conversation: chats, the task tool, schedules fired and edited or deleted mid-run, renames, relaunch and retry, lost origin, owner and preferences kept)")
    }

    private static func workerOriginTable(_ require: (Bool, String) throws -> Void) throws {
        let rows: [(NativeWorkerOriginFacts, Bool, String)] = [
            (NativeWorkerOriginFacts(conversationIsCompanion: true), true, "companion conversation"),
            (NativeWorkerOriginFacts(conversationIsCompanion: false), false, "ordinary or schedule chat"),
            (NativeWorkerOriginFacts(conversationIsCompanion: nil), false, "conversation, outbox row or task link missing"),
        ]
        for (facts, expected, label) in rows {
            try require(NativeWorkerOrigin.belongsToCompanion(facts) == expected, "Origin table: \(label)")
        }
    }

    private static func companionThread(_ repository: LocalChatRepository) throws -> String {
        if let existing = try repository.listConversations().first(where: {
            $0.originType == ChatStore.veraThreadOriginType && $0.originID == ChatStore.veraThreadOriginID
        }) { return existing.id }
        let thread = Conversation(id: UUID().uuidString, title: "Companion", messages: [], updatedAt: Date(),
                                  originType: ChatStore.veraThreadOriginType, originID: ChatStore.veraThreadOriginID)
        try repository.saveConversation(thread)
        return thread.id
    }

    private static func ordinaryChat(_ repository: LocalChatRepository) throws -> String {
        let conversation = Conversation(id: UUID().uuidString, title: "Ordinary chat", messages: [], updatedAt: Date())
        try repository.saveConversation(conversation)
        return conversation.id
    }

    private static func originChat(_ repository: LocalChatRepository, companion: Bool) throws -> String {
        companion ? try companionThread(repository) : try ordinaryChat(repository)
    }

    private static func scheduleChat(_ repository: LocalChatRepository, _ schedule: NativeSchedule, store: NativeScheduleStore) throws -> String {
        if schedule.owner == .dot { return try companionThread(repository) }
        let conversation = Conversation(id: UUID().uuidString, title: schedule.title, messages: [], updatedAt: Date(),
                                        originType: ChatStore.scheduleOriginType, originID: schedule.id, titleSource: .user)
        try repository.saveConversation(conversation)
        var saved = schedule
        saved.conversationID = conversation.id
        try store.save(saved)
        return conversation.id
    }

    private static func originTurn(_ repository: LocalChatRepository, conversationID: String) throws -> NativeTaskOrigin {
        let ordinal = try repository.messages(conversationID: conversationID).count
        let user = Message(role: .user, text: "Look into a fictional moon")
        let assistant = Message(role: .assistant, text: "", state: .streaming)
        try repository.saveMessage(user, conversationID: conversationID, ordinal: ordinal)
        try repository.saveMessage(assistant, conversationID: conversationID, ordinal: ordinal + 1)
        return NativeTaskOrigin(conversationID: conversationID, userMessageID: user.id, assistantMessageID: assistant.id)
    }

    private static func originSubmit(_ harness: NativeTaskEngineHarness, conversationID: String,
                                     request: NativeResearchTaskRequest) async throws -> NativeTaskReference {
        let origin = try originTurn(harness.repository, conversationID: conversationID)
        return try await harness.service.submit(origin: origin, request: request, profile: harness.profile)
    }

    private static func originSubmit(_ harness: NativeTaskEngineHarness, companion: Bool,
                                     request: NativeResearchTaskRequest) async throws -> NativeTaskReference {
        try await originSubmit(harness, conversationID: try originChat(harness.repository, companion: companion), request: request)
    }

    nonisolated private static func originReply(_ job: NativeTaskGenerationJob) -> String {
        switch job.phase {
        case "plan": return "{\"subquestions\": [\"What is Luma?\", \"Where is Luma?\"]}"
        case "outline": return "{\"sections\":[{\"heading\":\"Overview\",\"instructions\":\"Describe the moon\"}]}"
        case let phase where phase.hasPrefix("draft"): return "{\"text\":\"Draft of the overview.\"}"
        case let phase where phase.hasPrefix("revise"): return "Revised overview."
        default: return "Luma is blue [1].\n\nSources\n[1] Fictional moon guide"
        }
    }

    private static func originResearch() throws -> NativeResearchTaskRequest {
        try NativeResearchTaskRequest(objective: "What color is the fictional moon Luma?", deliverables: ["A cited answer"])
    }

    private static func originDocument() throws -> NativeResearchTaskRequest {
        try NativeResearchTaskRequest(objective: "Write a short note about Luma", deliverables: ["Luma is blue"], workerType: "document", title: "Luma note")
    }

    private static func originEngineID(_ harness: NativeTaskEngineHarness, _ reference: NativeTaskReference, _ label: String) throws -> String {
        guard let id = try harness.repository.taskReference(id: reference.id)?.remoteTaskID else {
            throw NativeTaskFixture.Failure.assertion("\(label) has an engine task")
        }
        return id
    }

    private static func originFinish(_ harness: NativeTaskEngineHarness, _ reference: NativeTaskReference,
                                     _ label: String, _ require: (Bool, String) throws -> Void) async throws -> String {
        let done = try await harness.wait(seconds: 20) { try harness.state(reference) == .completed }
        try require(done, "\(label) completes")
        return try originEngineID(harness, reference, label)
    }

    private static func originPrompts(_ messages: [NativeTaskGenerationMessage], named: String?, _ label: String,
                                      _ require: (Bool, String) throws -> Void) throws {
        try require(!messages.isEmpty, "\(label) sent prompts")
        let systems = messages.filter { $0.role == "system" }.map(\.content)
        if let named {
            try require(systems.allSatisfy { $0.hasPrefix("You are \(named)") }, "\(label) opens every prompt with the companion's name")
        } else {
            try require(systems.allSatisfy { $0.hasPrefix("You are the user's assistant") }, "\(label) uses the no-name opening")
            try require(!messages.contains { $0.content.contains("Ada") || $0.content.contains("Grace") }, "\(label) never names the companion in any prompt")
        }
    }

    private static func workerOriginEndToEnd(_ require: (Bool, String) throws -> Void) async throws {
        let recorder = NativeWorkerOriginRecorder()
        let gate = NativeWorkerOriginGate()
        let repository = try LocalChatRepository(inMemory: true)
        let source = NativeWorkerIdentitySource()
        source.update(assistantName: "Ada", ownerName: "Jordan")
        try NativePreferenceStore(database: repository.database).add(statement: "Keep every answer short.")
        let search = NativeResearchSearch { query, _ in
            await gate.pass()
            return [NativeResearchSource(n: 0, title: "Fictional moon guide", url: "https://fictional.test/\(query.count)",
                                         content: "The fictional moon Luma is blue. Asked: \(query)")]
        }
        let harness = try NativeTaskEngineHarness.make(repository: repository, counter: NativeTaskEngineCounter(), search: search,
                                                       identity: NativeWorkerOrigin.resolver(source, database: repository.database)) { job in
            await recorder.record(job)
            return originReply(job)
        }
        try await harness.start()
        func check(_ taskID: String, named: String?, _ label: String) async throws {
            let messages = await recorder.messages(taskID)
            try originPrompts(messages, named: named, label, require)
            let owned = messages.filter { $0.role == "system" && $0.content.contains("Jordan") }.map(\.content)
            try require(!owned.isEmpty, "\(label) still writes for the owner by name")
            try require(owned.allSatisfy { $0.contains("- Keep every answer short.") }, "\(label) still carries saved preferences")
        }

        let ordinaryResearch = try await originFinish(harness, try await originSubmit(harness, companion: false, request: originResearch()), "Ordinary research", require)
        try await check(ordinaryResearch, named: nil, "Research from an ordinary chat")
        let ordinaryDocument = try await originFinish(harness, try await originSubmit(harness, companion: false, request: originDocument()), "Ordinary document", require)
        try await check(ordinaryDocument, named: nil, "A document from an ordinary chat")
        let companionResearch = try await originFinish(harness, try await originSubmit(harness, companion: true, request: originResearch()), "Companion research", require)
        try await check(companionResearch, named: "Ada", "Research from the companion's chat")
        let companionDocument = try await originFinish(harness, try await originSubmit(harness, companion: true, request: originDocument()), "Companion document", require)
        try await check(companionDocument, named: "Ada", "A document from the companion's chat")

        for companion in [false, true] {
            for workerType in ["research", "document"] {
                let label = "The \(workerType) task tool from \(companion ? "the companion's chat" : "an ordinary chat")"
                let origin = try originTurn(repository, conversationID: try originChat(repository, companion: companion))
                let tool = NativeTaskTools.definition(service: harness.service, origin: origin, profile: harness.profile,
                                                      searchAvailable: { true }, didSave: { _ in })
                _ = try await tool.execute(["worker_type": .string(workerType), "title": .string("Luma"),
                                            "objective": .string("Write about the fictional moon Luma"),
                                            "deliverables": .array([.string("Luma is blue")])])
                guard let reference = try repository.taskReferences(conversationID: origin.conversationID)
                    .first(where: { $0.origin.userMessageID == origin.userMessageID }) else {
                    throw NativeTaskFixture.Failure.assertion("\(label) saves a task")
                }
                try require(reference.origin.conversationID == origin.conversationID, "\(label) delivers to the chat it was used in")
                try await check(try await originFinish(harness, reference, label, require), named: companion ? "Ada" : nil, label)
            }
        }

        let schedules = NativeScheduleStore(database: repository.database)
        var scheduled: [(String, Bool, String, NativeTaskReference)] = []
        for owner in [NativeScheduleOwner.dot, .conversation] {
            for workerType in ["research", "document"] {
                let schedule = try NativeSchedule(owner: owner, workerType: workerType, title: "Luma \(workerType)",
                                                  instruction: "Write about the fictional moon Luma", cadence: .everyHours(6), timeZone: .current)
                try schedules.save(schedule)
                let conversationID = try scheduleChat(repository, schedule, store: schedules)
                let label = "A \(workerType) schedule owned by \(owner == .dot ? "the companion" : "its own chat")"
                let reference = try await originSubmit(harness, conversationID: conversationID, request: schedule.taskRequest())
                let taskID = try await originFinish(harness, reference, label, require)
                try await check(taskID, named: owner == .dot ? "Ada" : nil, label)
                scheduled.append((taskID, owner == .dot, schedule.id, reference))
            }
        }

        let store = harness.engine.store
        let resolve = NativeWorkerOrigin.resolver(source, database: repository.database)
        for (taskID, companion, scheduleID, _) in scheduled {
            try schedules.delete(scheduleID)
            try require(resolve(try store.get(taskID)).assistantName == (companion ? "Ada" : nil),
                        "Deleting a schedule leaves its task with the identity its conversation gives")
        }
        let companionRecord = try store.get(companionResearch)
        try require(resolve(companionRecord).assistantName == "Ada", "The companion's chat task resolves to the name")
        try await repository.database.write { db in
            try db.execute(sql: """
                UPDATE native_task_outbox SET conversation_id = NULL, orphaned = 1
                WHERE id = (SELECT creation_key FROM native_engine_tasks WHERE id = ?)
                """, arguments: [companionResearch])
        }
        try require(resolve(companionRecord).assistantName == nil, "An orphaned outbox row leaves the task name-free")
        let documentRecord = try store.get(companionDocument)
        try require(resolve(documentRecord).assistantName == "Ada", "The companion document still resolves before its chat is deleted")
        try repository.deleteConversation(try companionThread(repository))
        try require(resolve(documentRecord).assistantName == nil, "Deleting the companion's chat leaves its task name-free")
        try await repository.database.write { db in
            try db.execute(sql: "UPDATE native_engine_tasks SET creation_key = ? WHERE id = ?",
                           arguments: [UUID().uuidString, ordinaryResearch])
        }
        let unlinked = resolve(try store.get(ordinaryResearch))
        try require(unlinked.assistantName == nil, "A task with no outbox row is name-free")
        try require(unlinked.ownerName == "Jordan" && unlinked.preferences == ["Keep every answer short."], "Lost origin keeps the owner and preferences")

        gate.hold()
        let renamed = try await originSubmit(harness, companion: true, request: originResearch())
        try require(try await harness.wait(seconds: 20) { gate.isWaiting }, "The companion task pauses inside its searches")
        let renamedID = try originEngineID(harness, renamed, "The renamed companion task")
        let beforeRename = await recorder.messages(renamedID).filter { $0.role == "system" }.map(\.content)
        try require(beforeRename.count == 1 && beforeRename[0].hasPrefix("You are Ada"), "The plan step used the name saved when it ran")
        source.update(assistantName: "Grace", ownerName: "Jordan")
        gate.release()
        _ = try await originFinish(harness, renamed, "The renamed companion task", require)
        let afterRename = await recorder.messages(renamedID).filter { $0.role == "system" }.map(\.content)
        try require(afterRename.count == 2 && afterRename[1].hasPrefix("You are Grace"), "The step after a rename uses the new name")
        let ordinaryAfter = try await originFinish(harness, try await originSubmit(harness, companion: false, request: originResearch()), "Ordinary research after the rename", require)
        try await check(ordinaryAfter, named: nil, "Research from an ordinary chat after a rename")

        source.update(assistantName: nil, ownerName: "Jordan")
        let unnamedCompanion = try await originFinish(harness, try await originSubmit(harness, companion: true, request: originResearch()), "Unnamed companion research", require)
        try await check(unnamedCompanion, named: nil, "Research from the companion's chat with no name saved")
        let unnamedOrdinary = try await originFinish(harness, try await originSubmit(harness, companion: false, request: originDocument()), "Unnamed ordinary document", require)
        try await check(unnamedOrdinary, named: nil, "A document from an ordinary chat with no name saved")
        let unnamedSchedule = try NativeSchedule(owner: .dot, workerType: "document", title: "Unnamed brief",
                                                 instruction: "Write about the fictional moon Luma", cadence: .everyHours(6), timeZone: .current)
        try schedules.save(unnamedSchedule)
        let unnamedScheduled = try await originFinish(harness, try await originSubmit(harness, conversationID: try scheduleChat(repository, unnamedSchedule, store: schedules),
                                                                                      request: unnamedSchedule.taskRequest()), "Unnamed companion schedule", require)
        try await check(unnamedScheduled, named: nil, "A companion schedule with no name saved")
        await harness.stop()
    }

    private static func workerOriginRelaunch(_ require: (Bool, String) throws -> Void, companion: Bool) async throws {
        let label = companion ? "A relaunched companion task" : "A relaunched ordinary task"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chat.sqlite")
        let recorder = NativeWorkerOriginRecorder()
        let gate = NativeWorkerOriginGate()
        let search = NativeResearchSearch { query, _ in
            if query == "Where is Luma?" { try await gate.stall() }
            return [NativeResearchSource(n: 0, title: "Guide", url: "https://fictional.test/\(query.count)", content: "Luma is blue. \(query)")]
        }
        func harness() throws -> NativeTaskEngineHarness {
            let repository = try LocalChatRepository(url: url)
            let source = NativeWorkerIdentitySource()
            source.update(assistantName: "Ada", ownerName: "Jordan")
            return try NativeTaskEngineHarness.make(repository: repository, counter: NativeTaskEngineCounter(), search: search,
                                                    identity: NativeWorkerOrigin.resolver(source, database: repository.database)) { job in
                await recorder.record(job)
                return originReply(job)
            }
        }
        gate.hold()
        let first = try harness()
        try await first.start()
        let reference = try await originSubmit(first, companion: companion, request: try originResearch())
        try require(try await first.wait(seconds: 20) { gate.isWaiting }, "\(label) is inside its searches")
        await first.crash()
        let taskID = try originEngineID(first, reference, label)
        gate.release()
        let second = try harness()
        try await second.start()
        _ = try await originFinish(second, reference, label, require)
        await second.stop()
        try require(try originEngineID(second, reference, label) == taskID, "\(label) keeps its engine task")
        try require(await recorder.count(taskID) >= 2, "\(label) planned before and synthesized after the relaunch")
        try originPrompts(await recorder.messages(taskID), named: companion ? "Ada" : nil, label, require)
    }

    private static func workerOriginScheduleEdit(_ require: (Bool, String) throws -> Void, workerType: String, companion: Bool,
                                                 edit: NativeWorkerOriginEdit, relaunch: Bool) async throws {
        let label = "A \(workerType) run for a schedule \(companion ? "owned by the companion" : "delivering to its own chat")"
            + (edit == .delete ? " deleted mid-run" : " switched mid-run") + (relaunch ? " and relaunched" : "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chat.sqlite")
        let recorder = NativeWorkerOriginRecorder()
        let gate = NativeWorkerOriginGate()
        let holdPhase = "draft-0"
        let search = NativeResearchSearch { query, _ in
            if relaunch { try await gate.stall() } else { await gate.pass() }
            return [NativeResearchSource(n: 0, title: "Guide", url: "https://fictional.test/\(query.count)", content: "Luma is blue. \(query)")]
        }
        func harness() throws -> NativeTaskEngineHarness {
            let repository = try LocalChatRepository(url: url)
            let source = NativeWorkerIdentitySource()
            source.update(assistantName: "Ada", ownerName: "Jordan")
            return try NativeTaskEngineHarness.make(repository: repository, counter: NativeTaskEngineCounter(), search: search,
                                                    identity: NativeWorkerOrigin.resolver(source, database: repository.database)) { job in
                await recorder.record(job)
                if job.phase == holdPhase {
                    if relaunch { try await gate.stall() } else { await gate.pass() }
                }
                return originReply(job)
            }
        }
        let first = try harness()
        let schedules = NativeScheduleStore(database: first.repository.database)
        let schedule = try NativeSchedule(owner: companion ? .dot : .conversation, workerType: workerType, title: "Luma \(workerType)",
                                          instruction: "Write about the fictional moon Luma", cadence: .everyHours(6), timeZone: .current)
        try schedules.save(schedule)
        let deliveryID = try scheduleChat(first.repository, schedule, store: schedules)
        gate.hold()
        try await first.start()
        let reference = try await originSubmit(first, conversationID: deliveryID, request: try schedule.taskRequest())
        try require(try await first.wait(seconds: 20) { gate.isWaiting }, "\(label) is mid-run")
        let taskID = try originEngineID(first, reference, label)
        let before = await recorder.count(taskID)
        switch edit {
        case .switchOwner:
            guard let existing = try schedules.get(schedule.id) else { throw NativeTaskFixture.Failure.assertion("\(label) has its schedule") }
            let switched = try NativeSchedule(id: existing.id, owner: companion ? .conversation : .dot, conversationID: nil,
                                              workerType: existing.workerType, title: existing.title, instruction: existing.instruction,
                                              cadence: existing.cadence, timeZone: existing.timeZone, enabled: existing.enabled,
                                              lastRunAt: existing.lastRunAt, lastOutcome: existing.lastOutcome, createdAt: existing.createdAt)
            try schedules.save(switched)
        case .delete:
            try schedules.delete(schedule.id)
        }
        let finisher: NativeTaskEngineHarness
        if relaunch {
            await first.crash()
            gate.release()
            finisher = try harness()
            try await finisher.start()
            if workerType == "document" {
                try require(try await finisher.wait(seconds: 20) { try finisher.state(reference) == .needsDecision }, "\(label) pauses for a retry after the relaunch")
                await finisher.tracker.retry(reference.id)
            }
        } else {
            gate.release()
            finisher = first
        }
        _ = try await originFinish(finisher, reference, label, require)
        await finisher.stop()
        try require(try originEngineID(finisher, reference, label) == taskID, "\(label) keeps its engine task")
        let after = await recorder.messages(taskID, from: before)
        try require(after.contains { $0.role == "system" }, "\(label) ran a prompt step after the change")
        let named: String? = companion ? "Ada" : nil
        try originPrompts(after, named: named, "\(label), after the change,", require)
        try originPrompts(await recorder.messages(taskID), named: named, label, require)
        let delivered = try finisher.repository.taskReference(id: reference.id)?.origin.conversationID
        let stored = try await finisher.repository.database.read { db in
            try String.fetchOne(db, sql: "SELECT conversation_id FROM native_task_outbox WHERE id = ?", arguments: [reference.id.uuidString])
        }
        try require(delivered == deliveryID && stored == deliveryID, "\(label) still delivers to the conversation it started in")
        let reply = try finisher.repository.messages(conversationID: deliveryID).first { $0.id == reference.origin.assistantMessageID }
        try require(reply?.displayBlocks.contains { if case .artifact = $0 { return true }; return false } == true,
                    "\(label) puts its result in the conversation it started in")
    }

    private static func workerOriginStoreSchedules(_ require: (Bool, String) throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(url: directory.appendingPathComponent("chat.sqlite"))
        let config = NativeChatConfig(baseURL: URL(string: "https://fixture.invalid/v1")!, apiKey: nil, model: "fixture", chatTemplateKwargs: nil)
        let store = ChatStore(nativeConfig: config, nativeTransport: nil, repository: repository, nativeAssistantName: "Ada",
                              nativeSearchAvailable: { true }, artifactPersistenceEnabled: false)
        await store.connect()
        guard let engine = store.nativeTaskLocalEngine else { throw NativeTaskFixture.Failure.assertion("The store runs the local engine") }
        let resolve = NativeWorkerOrigin.resolver(store.nativeWorkerIdentity, database: repository.database)
        for workerType in ["research", "document"] {
            for owner in [NativeScheduleOwner.dot, .conversation] {
                let label = "A fired \(workerType) schedule \(owner == .dot ? "owned by the companion" : "delivering to its own chat")"
                var draft = NativeScheduleDraft()
                draft.title = "Luma \(workerType)"
                draft.instruction = "Write about the fictional moon Luma"
                draft.workerType = workerType
                draft.owner = owner
                guard let schedule = store.createSchedule(draft) else { throw NativeTaskFixture.Failure.assertion("\(label) saves") }
                let probe = NativeScheduleRun(scheduleID: schedule.id, scheduledFor: Date(), outcome: .running)
                guard case .started(let referenceText) = await store.fireSchedule(schedule, run: probe, bind: { _, _ in }),
                      let referenceID = UUID(uuidString: referenceText),
                      let reference = try repository.taskReference(id: referenceID), let taskID = reference.remoteTaskID else {
                    throw NativeTaskFixture.Failure.assertion("\(label) starts a task")
                }
                let delivery = reference.origin.conversationID
                try require(store.isVeraThread(delivery) == (owner == .dot), "\(label) delivers to \(owner == .dot ? "the companion's conversation" : "its own chat")")
                let expected: String? = owner == .dot ? "Ada" : nil
                try require(resolve(try engine.store.get(taskID)).assistantName == expected, "\(label) resolves the identity its conversation gives")
                draft.owner = owner == .dot ? .conversation : .dot
                store.updateSchedule(schedule.id, with: draft)
                let edited = try store.nativeScheduleStore?.get(schedule.id)
                try require(edited?.owner == draft.owner && edited?.conversationID == nil, "Editing where results go switches the owner and clears the saved chat")
                try require(resolve(try engine.store.get(taskID)).assistantName == expected, "\(label) keeps its identity after the schedule is switched")
                try require(try repository.taskReference(id: referenceID)?.origin.conversationID == delivery, "\(label) keeps its delivery chat after the switch")
                store.deleteSchedule(schedule.id)
                try require(resolve(try engine.store.get(taskID)).assistantName == expected, "\(label) keeps its identity after the schedule is deleted")
            }
        }
        store.stopNativeTaskRecovery()
    }
}
