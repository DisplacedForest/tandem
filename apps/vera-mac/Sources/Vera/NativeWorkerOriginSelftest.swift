import Foundation
import GRDB

private actor NativeWorkerOriginRecorder {
    private(set) var prompts: [String: [NativeTaskGenerationMessage]] = [:]
    func record(_ job: NativeTaskGenerationJob) {
        prompts[job.taskID, default: []] += job.messages
    }
    func messages(_ taskID: String) -> [NativeTaskGenerationMessage] { prompts[taskID] ?? [] }
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

@MainActor
extension SelfTest {
    static func workerOriginContract() async throws {
        let require = NativeTaskFixture.require
        try workerOriginTable(require)
        try await workerOriginEndToEnd(require)
        try await workerOriginRelaunch(require, companion: false)
        try await workerOriginRelaunch(require, companion: true)
        print("  worker origin OK (companion name only for the companion's chat and its schedules, renames, relaunch, lost origin, owner and preferences kept)")
    }

    private static func workerOriginTable(_ require: (Bool, String) throws -> Void) throws {
        let rows: [(NativeWorkerOriginFacts, Bool, String)] = [
            (NativeWorkerOriginFacts(scheduleID: nil, scheduleOwner: nil, conversationIsCompanion: true), true, "companion chat"),
            (NativeWorkerOriginFacts(scheduleID: nil, scheduleOwner: nil, conversationIsCompanion: false), false, "ordinary chat"),
            (NativeWorkerOriginFacts(scheduleID: nil, scheduleOwner: nil, conversationIsCompanion: nil), false, "conversation lost"),
            (NativeWorkerOriginFacts(scheduleID: "s", scheduleOwner: .dot, conversationIsCompanion: nil), true, "companion schedule"),
            (NativeWorkerOriginFacts(scheduleID: "s", scheduleOwner: .dot, conversationIsCompanion: false), true, "companion schedule in another chat"),
            (NativeWorkerOriginFacts(scheduleID: "s", scheduleOwner: .conversation, conversationIsCompanion: nil), false, "chat schedule"),
            (NativeWorkerOriginFacts(scheduleID: "s", scheduleOwner: .conversation, conversationIsCompanion: true), false, "chat schedule in the companion chat"),
            (NativeWorkerOriginFacts(scheduleID: "s", scheduleOwner: nil, conversationIsCompanion: true), false, "schedule deleted"),
            (NativeWorkerOriginFacts(scheduleID: "s", scheduleOwner: nil, conversationIsCompanion: nil), false, "schedule and chat lost"),
        ]
        for (facts, expected, label) in rows {
            try require(NativeWorkerOrigin.belongsToCompanion(facts) == expected, "Origin table: \(label)")
        }
    }

    private static func originConversation(_ repository: LocalChatRepository, companion: Bool) throws -> String {
        if companion, let existing = try repository.listConversations().first(where: {
            $0.originType == ChatStore.veraThreadOriginType && $0.originID == ChatStore.veraThreadOriginID
        }) { return existing.id }
        let conversation = companion
            ? Conversation(id: UUID().uuidString, title: "Companion", messages: [], updatedAt: Date(),
                           originType: ChatStore.veraThreadOriginType, originID: ChatStore.veraThreadOriginID)
            : Conversation(id: UUID().uuidString, title: "Ordinary chat", messages: [], updatedAt: Date())
        try repository.saveConversation(conversation)
        return conversation.id
    }

    private static func originSubmit(_ harness: NativeTaskEngineHarness, companion: Bool,
                                     request: NativeResearchTaskRequest) async throws -> NativeTaskReference {
        let repository = harness.repository
        let conversationID = try originConversation(repository, companion: companion)
        let ordinal = try repository.messages(conversationID: conversationID).count
        let user = Message(role: .user, text: "Look into a fictional moon")
        let assistant = Message(role: .assistant, text: "", state: .streaming)
        try repository.saveMessage(user, conversationID: conversationID, ordinal: ordinal)
        try repository.saveMessage(assistant, conversationID: conversationID, ordinal: ordinal + 1)
        let origin = NativeTaskOrigin(conversationID: conversationID, userMessageID: user.id, assistantMessageID: assistant.id)
        return try await harness.service.submit(origin: origin, request: request, profile: harness.profile)
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

    private static func originFinish(_ harness: NativeTaskEngineHarness, _ reference: NativeTaskReference,
                                     _ label: String, _ require: (Bool, String) throws -> Void) async throws -> String {
        let done = try await harness.wait(seconds: 20) { try harness.state(reference) == .completed }
        try require(done, "\(label) completes")
        guard let id = try harness.repository.taskReference(id: reference.id)?.remoteTaskID else {
            throw NativeTaskFixture.Failure.assertion("\(label) has an engine task")
        }
        return id
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
        let research = { () throws -> NativeResearchTaskRequest in
            try NativeResearchTaskRequest(objective: "What color is the fictional moon Luma?", deliverables: ["A cited answer"])
        }
        let document = { () throws -> NativeResearchTaskRequest in
            try NativeResearchTaskRequest(objective: "Write a short note about Luma", deliverables: ["Luma is blue"], workerType: "document", title: "Luma note")
        }
        func check(_ taskID: String, named: String?, _ label: String) async throws {
            let messages = await recorder.messages(taskID)
            try require(!messages.isEmpty, "\(label) sent prompts")
            let systems = messages.filter { $0.role == "system" }.map(\.content)
            if let named {
                try require(systems.allSatisfy { $0.hasPrefix("You are \(named)") }, "\(label) opens every prompt with the companion's name")
            } else {
                try require(systems.allSatisfy { $0.hasPrefix("You are the user's assistant") }, "\(label) uses the no-name opening")
                try require(!messages.contains { $0.content.contains("Ada") || $0.content.contains("Grace") }, "\(label) never names the companion in any prompt")
            }
            let owned = systems.filter { $0.contains("Jordan") }
            try require(!owned.isEmpty, "\(label) still writes for the owner by name")
            try require(owned.allSatisfy { $0.contains("- Keep every answer short.") }, "\(label) still carries saved preferences")
        }

        let ordinaryResearch = try await originFinish(harness, try await originSubmit(harness, companion: false, request: research()), "Ordinary research", require)
        try await check(ordinaryResearch, named: nil, "Research from an ordinary chat")
        let ordinaryDocument = try await originFinish(harness, try await originSubmit(harness, companion: false, request: document()), "Ordinary document", require)
        try await check(ordinaryDocument, named: nil, "A document from an ordinary chat")
        let companionResearch = try await originFinish(harness, try await originSubmit(harness, companion: true, request: research()), "Companion research", require)
        try await check(companionResearch, named: "Ada", "Research from the companion's chat")
        let companionDocument = try await originFinish(harness, try await originSubmit(harness, companion: true, request: document()), "Companion document", require)
        try await check(companionDocument, named: "Ada", "A document from the companion's chat")

        let schedules = NativeScheduleStore(database: repository.database)
        var scheduled: [(String, Bool, String)] = []
        for owner in [NativeScheduleOwner.dot, .conversation] {
            for workerType in ["research", "document"] {
                let schedule = try NativeSchedule(owner: owner, workerType: workerType, title: "Luma \(workerType)",
                                                  instruction: "Write about the fictional moon Luma", cadence: .everyHours(6), timeZone: .current)
                try schedules.save(schedule)
                let label = "A \(workerType) schedule owned by \(owner == .dot ? "the companion" : "its own chat")"
                let taskID = try await originFinish(harness, try await originSubmit(harness, companion: owner == .dot, request: schedule.taskRequest()), label, require)
                try await check(taskID, named: owner == .dot ? "Ada" : nil, label)
                scheduled.append((taskID, owner == .dot, schedule.id))
            }
        }

        let store = harness.engine.store
        let resolve = NativeWorkerOrigin.resolver(source, database: repository.database)
        for (taskID, companion, scheduleID) in scheduled where companion {
            try schedules.delete(scheduleID)
            try require(resolve(try store.get(taskID)).assistantName == nil, "A companion schedule's task is name-free once the schedule is deleted")
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
        let companionThread = try originConversation(repository, companion: true)
        try repository.deleteConversation(companionThread)
        try require(resolve(documentRecord).assistantName == nil, "Deleting the companion's chat leaves its task name-free")
        try await repository.database.write { db in
            try db.execute(sql: "UPDATE native_engine_tasks SET creation_key = ? WHERE id = ?",
                           arguments: [UUID().uuidString, ordinaryResearch])
        }
        try require(resolve(try store.get(ordinaryResearch)).assistantName == nil, "A task with no outbox row is name-free")
        try require(resolve(try store.get(ordinaryResearch)).ownerName == "Jordan"
                    && resolve(try store.get(ordinaryResearch)).preferences == ["Keep every answer short."], "Lost origin keeps the owner and preferences")

        gate.hold()
        let renamed = try await originSubmit(harness, companion: true, request: research())
        try require(try await harness.wait(seconds: 20) { gate.isWaiting }, "The companion task pauses inside its searches")
        let renamedID = try harness.repository.taskReference(id: renamed.id)?.remoteTaskID ?? ""
        let beforeRename = await recorder.messages(renamedID).filter { $0.role == "system" }.map(\.content)
        try require(beforeRename.count == 1 && beforeRename[0].hasPrefix("You are Ada"), "The plan step used the name saved when it ran")
        source.update(assistantName: "Grace", ownerName: "Jordan")
        gate.release()
        _ = try await originFinish(harness, renamed, "The renamed companion task", require)
        let afterRename = await recorder.messages(renamedID).filter { $0.role == "system" }.map(\.content)
        try require(afterRename.count == 2 && afterRename[1].hasPrefix("You are Grace"), "The step after a rename uses the new name")
        let ordinaryAfter = try await originFinish(harness, try await originSubmit(harness, companion: false, request: research()), "Ordinary research after the rename", require)
        try await check(ordinaryAfter, named: nil, "Research from an ordinary chat after a rename")

        source.update(assistantName: nil, ownerName: "Jordan")
        let unnamedCompanion = try await originFinish(harness, try await originSubmit(harness, companion: true, request: research()), "Unnamed companion research", require)
        try await check(unnamedCompanion, named: nil, "Research from the companion's chat with no name saved")
        let unnamedOrdinary = try await originFinish(harness, try await originSubmit(harness, companion: false, request: document()), "Unnamed ordinary document", require)
        try await check(unnamedOrdinary, named: nil, "A document from an ordinary chat with no name saved")
        let unnamedSchedule = try NativeSchedule(owner: .dot, workerType: "document", title: "Unnamed brief",
                                                 instruction: "Write about the fictional moon Luma", cadence: .everyHours(6), timeZone: .current)
        try schedules.save(unnamedSchedule)
        let unnamedScheduled = try await originFinish(harness, try await originSubmit(harness, companion: true, request: unnamedSchedule.taskRequest()), "Unnamed companion schedule", require)
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
        let reference = try await originSubmit(first, companion: companion,
            request: try NativeResearchTaskRequest(objective: "What color is the fictional moon Luma?", deliverables: ["A cited answer"]))
        try require(try await first.wait(seconds: 20) { gate.isWaiting }, "\(label) is inside its searches")
        await first.crash()
        let taskID = try first.repository.taskReference(id: reference.id)?.remoteTaskID ?? ""
        gate.release()
        let second = try harness()
        try await second.start()
        _ = try await originFinish(second, reference, label, require)
        await second.stop()
        try require(try second.repository.taskReference(id: reference.id)?.remoteTaskID == taskID, "\(label) keeps its engine task")
        let systems = await recorder.messages(taskID).filter { $0.role == "system" }.map(\.content)
        try require(systems.count >= 2, "\(label) planned before and synthesized after the relaunch")
        let opening = companion ? "You are Ada" : "You are the user's assistant"
        try require(systems.allSatisfy { $0.hasPrefix(opening) }, "\(label) keeps the identity its origin gives it")
        if !companion {
            try require(!(await recorder.messages(taskID)).contains { $0.content.contains("Ada") }, "\(label) never names the companion")
        }
    }
}
