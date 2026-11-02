import CryptoKit
import Foundation

final class CompanionScriptedTransport: NativeChatTransport, @unchecked Sendable {
    struct Request: Sendable {
        let messages: [NativeChatMessage]
        let tools: [String]
    }

    private let lock = NSLock()
    private var chat: [Request] = []
    private var summaries: [Request] = []
    private var failOn: Set<Int> = []
    private var noteCalls = 0

    var chatRequests: [Request] { lock.withLock { chat } }
    var summaryRequests: [Request] { lock.withLock { summaries } }
    var summaryCalls: Int { lock.withLock { summaries.count } }

    func failSummary(call: Int) { lock.withLock { _ = failOn.insert(call) } }

    func discoverModels() async throws -> [String] { ["local-model"] }

    static let notesMarker = "Companion notes: "

    func stream(
        messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]
    ) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        let request = Request(messages: messages, tools: tools.map(\.name))
        if messages.first?.content.hasPrefix(NativeCompanionContext.summaryInstruction) == true {
            let (call, fails) = lock.withLock { () -> (Int, Bool) in
                summaries.append(request)
                return (summaries.count, failOn.contains(summaries.count))
            }
            let content = Self.summary(from: messages.last?.content ?? "", call: call)
            return AsyncThrowingStream { continuation in
                if fails {
                    continuation.finish(throwing: NativeChatClient.ClientError.server("scripted summary failure"))
                } else {
                    continuation.yield(NativeChatStreamSnapshot(content: content, toolCalls: [], finishReason: "stop"))
                    continuation.finish()
                }
            }
        }
        let lastUser = messages.last(where: { $0.role == "user" })?.content ?? ""
        let answeredTool = messages.last?.role == "tool"
        var snapshot = NativeChatStreamSnapshot(content: "Reply to: " + String(lastUser.prefix(60)), toolCalls: [], finishReason: "stop")
        if !answeredTool, request.tools.contains(NativeContinuityNotesTool.toolName),
           let range = lastUser.range(of: "NOTE: ") {
            let text = Self.notesMarker + String(lastUser[range.upperBound...])
            let arguments = String(decoding: (try? JSONSerialization.data(withJSONObject: ["text": text])) ?? Data(), as: UTF8.self)
            let id = lock.withLock { () -> String in
                noteCalls += 1
                return "notes-\(noteCalls)"
            }
            snapshot = NativeChatStreamSnapshot(
                content: "", toolCalls: [NativeChatToolCall(id: id, name: NativeContinuityNotesTool.toolName, arguments: arguments)],
                finishReason: "tool_calls")
        }
        lock.withLock { chat.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    static func summary(from input: String, call: Int) -> String {
        var corrections: [String] = []
        if let expression = try? NSRegularExpression(pattern: #"CORRECTION: [^.]*\."#) {
            for match in expression.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
                guard let range = Range(match.range, in: input) else { continue }
                let found = String(input[range])
                if !corrections.contains(found) { corrections.append(found) }
            }
        }
        let turns = input.components(separatedBy: "User: ").count - 1
        return (["Summary \(call) condenses \(turns) turns."] + corrections + ["Later statements are current."]).joined(separator: " ")
    }
}

final class CompanionCaptureMemoryService: NativeMemoryServing, @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [String] = []

    var extractionInputs: [String] { lock.withLock { inputs } }

    func embed(_ text: String) async throws -> [Double] { [1, 0] }

    func proposals(
        user: String, assistant: String, sourceConversationID: String?, sourceMessageID: String?,
        existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] {
        lock.withLock { inputs.append(user + "\n" + assistant) }
        return []
    }

    func proposal(
        request: String, existing: @escaping @Sendable () throws -> [NativeMemoryRecord], now: Date
    ) async throws -> [NativeMemoryProposal] { [] }
}

@MainActor
enum NativeCompanionContextSelftest {
    static let focusedGolden = "fbd056d17b0de40a"

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NativeTaskFixture.Failure.assertion(message) }
    }

    static func run() async throws {
        try focused()
        try notes()
        try await longThread()
        try await store()
        print("  companion context: PASS (300-turn folding, failure resume, section and verbatim budgets, notes revisions, tool scope, focused parity)")
    }

    static func focused() throws {
        let legacy = NativeCompanionFocusedFixture.legacyHistory()
        try require(NativeCompanionFocusedFixture.digest(legacy).hasPrefix(focusedGolden),
                    "A focused chat builds the same history as before the companion budget existed")
        let composed = NativeCompanionContext.compose(
            input: NativeCompanionFocusedFixture.input(), messages: NativeCompanionFocusedFixture.messages(),
            suffix: NativeCompanionFocusedFixture.suffix, imageLoader: nil, capabilities: .textOnly,
            contextCeiling: NativeCompanionFocusedFixture.ceiling, companion: nil)
        try require(composed.history == legacy && NativeCompanionFocusedFixture.digest(composed.history).hasPrefix(focusedGolden),
                    "The send path composes a focused chat byte for byte as before")
        try require(!composed.assembled.sections.contains { $0.name == NativeCompanionContext.notesSectionName || $0.name == NativeCompanionContext.summarySectionName },
                    "A focused chat gets neither companion section")
    }

    static func notes() throws {
        let repository = try LocalChatRepository(inMemory: true)
        let conversation = Conversation(id: UUID().uuidString, title: "Companion", messages: [], updatedAt: Date())
        try repository.saveConversation(conversation)
        let budget = NativeCompanionContextBudget(contextCeiling: 2_000)
        let store = NativeContinuityNotesStore(database: repository.database, characterLimit: budget.notesTextCharacters)
        try require(try store.current(conversationID: conversation.id) == nil, "A new thread has no notes")
        let first = try store.append(conversationID: conversation.id, text: "  Tracking the review.  ", origin: .companion)
        let secret = "sk-" + String(repeating: "a1", count: 15)
        let second = try store.append(conversationID: conversation.id, text: "Key is \(secret) for the review.", origin: .companion)
        let third = try store.append(conversationID: conversation.id, text: String(repeating: "long ", count: 2_000), origin: .companion)
        try require(first == 1 && second == 2 && third == 3, "Notes revisions increment one at a time")
        let current = try store.current(conversationID: conversation.id)
        try require(current?.revision == 3 && (current?.text.count ?? .max) <= budget.notesTextCharacters,
                    "The newest revision is current and capped at the notes share")
        try repository.database.read { db in
            let stored = try String.fetchOne(db, sql: "SELECT text FROM native_continuity_notes WHERE conversation_id = ? AND revision = 2",
                                             arguments: [conversation.id]) ?? ""
            try require(!stored.contains(secret) && stored.contains(NativeDiagnosticRedaction.placeholder),
                        "Notes are redacted before they are stored")
        }
        let section = NativeCompanionContext.notesSection(current?.text ?? "", revisable: true)
        try require(section.count <= budget.notesCharacters, "The notes section fits its share with the longest allowed notes")
    }

    static func input() -> NativeContextInput {
        NativeContextInput(persona: "You are a steady companion.", timestamp: NativeCompanionFocusedFixture.timestamp,
                           timeZone: TimeZone(identifier: "UTC") ?? .current, memories: NativeCompanionFocusedFixture.memories(),
                           capabilities: .textOnly)
    }

    static let correction = "CORRECTION: the review moved to Thursday, not Tuesday."

    static func longThread() async throws {
        let repository = try LocalChatRepository(inMemory: true)
        let conversation = Conversation(id: UUID().uuidString, title: "Companion", messages: [], updatedAt: Date())
        try repository.saveConversation(conversation)
        let id = conversation.id
        let budget = NativeCompanionContextBudget(contextCeiling: 6_000)
        let folds = NativeThreadFoldStore(database: repository.database)
        let notesStore = NativeContinuityNotesStore(database: repository.database, characterLimit: budget.notesTextCharacters)
        let transport = CompanionScriptedTransport()
        let failingCall = 4
        transport.failSummary(call: failingCall)
        var messages: [Message] = []
        var nudged: Set<String> = []
        var nudges = 0
        var failedAt: Int?
        var lastAfterFailure: Int?
        var resumed = false
        var firstFoldTurn: Int?
        let compactor = NativeCompanionCompactor()

        func unfolded() throws -> [Message] {
            let last = try folds.lastFoldedOrdinal(conversationID: id)
            return try folds.orderedMessages(conversationID: id).filter { entry in last.map { entry.ordinal > $0 } ?? true }.map(\.message)
        }

        for turn in 0..<300 {
            let text = turn == 5 ? correction + " Please plan around it."
                : "Turn \(turn) asks about " + String(repeating: "the greenhouse plan ", count: 6)
            let user = Message(role: .user, text: text)
            let context = NativeCompanionContext.load(conversationID: id, database: repository.database, budget: budget,
                                                      notesToolAvailable: true, claimNudge: { nudged.insert($0).inserted })
            let composed = NativeCompanionContext.compose(
                input: input(), messages: messages + [user], suffix: "\n\nAnswer directly.", imageLoader: nil,
                capabilities: .textOnly, contextCeiling: nil, companion: context)
            let sections = composed.assembled.sections
            guard let notesSection = sections.first(where: { $0.name == NativeCompanionContext.notesSectionName }) else {
                throw NativeTaskFixture.Failure.assertion("Every companion send carries the notes section")
            }
            try require(notesSection.content.count <= budget.notesCharacters && !notesSection.truncated,
                        "The notes section stays within its share on turn \(turn)")
            if context.folds.isEmpty {
                try require(!sections.contains { $0.name == NativeCompanionContext.summarySectionName },
                            "No summary section before the first fold")
            } else {
                guard let summary = sections.first(where: { $0.name == NativeCompanionContext.summarySectionName }) else {
                    throw NativeTaskFixture.Failure.assertion("Every send after a fold carries the summary section")
                }
                try require(summary.content.count <= budget.summaryCharacters && !summary.truncated
                            && summary.content.contains(NativeCompanionContext.summaryPrecedence)
                            && summary.content.contains(context.folds.last?.summary ?? "\u{0}"),
                            "The summary section fits its share, keeps the newest summary and says later wins on turn \(turn)")
            }
            if let memory = sections.first(where: { $0.name == "memory" }) {
                try require(memory.content.count <= budget.memoryCharacters, "Memory stays within its share")
            }
            let carried = composed.history.dropFirst().reduce(0) { $0 + NativeChatHistoryBuilder.cost($1) }
            try require(carried <= budget.verbatimCharacters + budget.currentTurnCharacters,
                        "The verbatim share holds on turn \(turn)")
            try require(composed.history.last?.content == text, "The current turn is always sent")
            try require(!composed.history.contains { $0.content.contains("Turn 0 asks") } || context.folds.isEmpty,
                        "Folded turns are not resent verbatim")
            let prompt = composed.history.first?.content ?? ""
            if context.nudge {
                nudges += 1
                try require(prompt.contains(NativeCompanionContext.nudgeLine), "The first send after a fold nudges a notes revision")
            } else {
                try require(!prompt.contains(NativeCompanionContext.nudgeLine), "Only the first send after a fold carries the nudge")
            }
            var reply = Message(role: .assistant, text: "Reply \(turn): " + String(repeating: "noted ", count: 20))
            if turn % 9 == 4 {
                reply.toolActivities = [NativeToolActivity(
                    id: "lookup-\(turn)", toolID: "fixture-lookup", name: "lookup_fixture", title: "Look up", round: 0,
                    request: "{\"q\":\"\(turn)\"}", result: "{\"value\":\(turn)}", state: .succeeded, confirmationRequired: false)]
            }
            try repository.saveMessage(user, conversationID: id, ordinal: messages.count)
            try repository.saveMessage(reply, conversationID: id, ordinal: messages.count + 1)
            messages += [user, reply]

            if turn == 150 {
                try notesStore.append(conversationID: id, text: "Tracking the Thursday review.", origin: .companion)
            }
            let before = try folds.folds(conversationID: id)
            let costBefore = NativeCompanionContext.verbatimCost(try unfolded())
            let unfoldedTurnsBefore = try unfolded().filter { $0.role == .user }.count
            let failuresBefore = compactor.failureCount
            await compactor.compact(conversationID: id, store: folds, transport: transport, model: "local-model", budget: budget)
            try require(!compactor.isRunning(id), "A finished pass releases its guard")
            if compactor.failureCount > failuresBefore {
                try require(failedAt == nil && transport.summaryCalls == failingCall, "Only the scripted summary fails")
                let after = try folds.folds(conversationID: id)
                try require(after.count == transport.summaryCalls - 1, "The failed summary left no fold behind")
                try require(after.count >= before.count && Array(after.prefix(before.count)) == before, "Earlier folds are untouched by a failure")
                failedAt = turn
                lastAfterFailure = try folds.lastFoldedOrdinal(conversationID: id)
                continue
            }
            let after = try folds.folds(conversationID: id)
            let written = after.count - before.count
            if let failedAt, failedAt == turn - 1, !resumed {
                try require(written > 0 && after[before.count].firstOrdinal == (lastAfterFailure ?? -1) + 1,
                            "The next completed turn resumes folding at the right ordinal")
                resumed = true
            }
            let resumingTurn = failedAt.map { $0 == turn - 1 } ?? false
            if resumingTurn {
                try require(costBefore > budget.foldTargetCharacters, "A resumed pass only runs while over the fold target")
            } else if costBefore <= budget.verbatimCharacters {
                try require(written == 0, "Nothing folds while the verbatim share holds on turn \(turn)")
            } else if unfoldedTurnsBefore > NativeCompanionContextBudget.minimumVerbatimTurns {
                try require(written > 0, "Folding starts once the verbatim share is exceeded on turn \(turn)")
                if firstFoldTurn == nil { firstFoldTurn = turn }
            }
            let remaining = try unfolded()
            let remainingTurns = remaining.filter { $0.role == .user }.count
            try require(remainingTurns >= min(NativeCompanionContextBudget.minimumVerbatimTurns, turn + 1),
                        "At least the minimum number of turns stays verbatim")
            if written > 0 {
                try require(NativeCompanionContext.verbatimCost(remaining) <= budget.foldTargetCharacters
                            || remainingTurns <= NativeCompanionContextBudget.minimumVerbatimTurns,
                            "Folding continues until under the fold target on turn \(turn)")
            }
        }

        let written = try folds.folds(conversationID: id)
        try require(written.count >= 10, "A 300-turn thread folds many times (\(written.count))")
        try require(failedAt != nil && resumed, "The scripted failure happened and folding resumed")
        try require(firstFoldTurn != nil && nudges > 0, "Folds happened and the notes nudge fired")
        try require(written.first?.firstOrdinal == 0, "The first fold starts at the first message")
        try require(Set(written.map(\.firstMessageID)).count == written.count, "Every fold starts at a unique message")
        let ordered = try folds.orderedMessages(conversationID: id)
        for (index, fold) in written.enumerated() {
            if index > 0 {
                try require(fold.firstOrdinal == written[index - 1].lastOrdinal + 1, "Fold ranges are contiguous")
            }
            let range = ordered.filter { $0.ordinal >= fold.firstOrdinal && $0.ordinal <= fold.lastOrdinal }
            let users = range.filter { $0.message.role == .user }.count
            try require(users > 0 && users <= NativeCompanionContextBudget.foldBatchTurns, "Each fold covers at most one batch of turns")
            try require(range.first?.message.role == .user && range.last?.message.role == .assistant,
                        "A fold starts at a user turn and ends with its reply")
        }
        try require(written.first.map { $0.firstOrdinal <= 10 && $0.lastOrdinal >= 11 } == true,
                    "The correction turn is inside the first fold")
        try require(written.last?.summary.contains(correction) == true,
                    "A correction stated only in folded turns is carried into the latest fold")
        try require(transport.summaryRequests.allSatisfy { $0.tools.isEmpty }, "Summary requests advertise no tools")
        try require(transport.summaryRequests.dropFirst().allSatisfy { $0.messages.last?.content.contains("Earlier summaries") == true },
                    "Each later summary sees the earlier ones")
        let final = NativeCompanionContext.load(conversationID: id, database: repository.database, budget: budget,
                                                notesToolAvailable: true, claimNudge: { _ in false })
        let section = NativeCompanionContext.summarySection(final.folds.map(\.summary), cap: budget.summaryCharacters)
        try require(section.contains(NativeCompanionContext.summaryPrecedence) && section.contains(correction),
                    "The summary section states that later wins and keeps the carried correction")
        try require(final.notes?.text == "Tracking the Thursday review.", "Notes written mid-thread are read back")

        guard let last = written.last, let next = ordered.first(where: { $0.ordinal == last.lastOrdinal + 1 }),
              let skip = ordered.first(where: { $0.ordinal == last.lastOrdinal + 3 }) else {
            throw NativeTaskFixture.Failure.assertion("Unfolded messages remain")
        }
        let gap = NativeThreadFold(id: UUID().uuidString, conversationID: id, firstMessageID: skip.message.id.uuidString,
                                   lastMessageID: skip.message.id.uuidString, firstOrdinal: skip.ordinal, lastOrdinal: skip.ordinal,
                                   summary: "Out of order", model: "local-model", createdAt: Date())
        do { try folds.insert(gap); throw NativeTaskFixture.Failure.assertion("A gap must be rejected") }
        catch is NativeThreadFoldError {}
        let mismatch = NativeThreadFold(id: UUID().uuidString, conversationID: id, firstMessageID: skip.message.id.uuidString,
                                        lastMessageID: next.message.id.uuidString, firstOrdinal: next.ordinal, lastOrdinal: next.ordinal,
                                        summary: "Wrong message", model: "local-model", createdAt: Date())
        do { try folds.insert(mismatch); throw NativeTaskFixture.Failure.assertion("A mismatched message must be rejected") }
        catch is NativeThreadFoldError {}
        try require(try folds.folds(conversationID: id).count == written.count, "Rejected folds write nothing")
    }

    static func waitFor(_ reason: String, _ condition: () throws -> Bool) async throws {
        for _ in 0..<1_000 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NativeTaskFixture.Failure.assertion(reason)
    }

    static func store() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandem-companion-context-\(UUID().uuidString.lowercased())", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: artifacts)
        var options = NativeChatRequestOptions.none
        options.contextCeiling = 1_500
        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
                                      model: "local-model", chatTemplateKwargs: nil, options: options)
        var settings = NativeMemorySettings.fresh
        settings.enabled = true
        settings.embeddingsModel = "embed-model"
        settings.extractionModel = "extract-model"
        settings.bankScope = "personal"
        settings.generateFromChats = true
        let memory = CompanionCaptureMemoryService()
        let transport = CompanionScriptedTransport()
        let store = ChatStore(nativeConfig: config, nativeTransport: transport, repository: repository,
                              nativeAssistantName: "Ada", nativeMemorySettings: settings, nativeMemoryService: memory,
                              attachmentStore: NativeAttachmentStore(directory: artifacts), artifactPersistenceEnabled: false)
        await store.connect()
        defer { store.stopNativeTaskRecovery() }
        store.prepareCompanionThread()
        guard let threadID = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion thread exists") }
        let folds = NativeThreadFoldStore(database: repository.database)

        func settle(_ conversationID: String) async throws {
            try await waitFor("The reply in \(conversationID) settles") {
                let thread = store.conversations.first { $0.id == conversationID }
                return !store.generating && thread?.messages.contains { $0.state == .streaming } == false
            }
            try await waitFor("Compaction settles") { !store.companionCompactor.isRunning(conversationID) }
        }

        var notesRevisions: [Int] = []
        var sawSummary = false
        for turn in 0..<24 {
            let text: String
            switch turn {
            case 2: text = "NOTE: Keep the Thursday review in mind."
            case 14: text = "NOTE: The review is now on Friday."
            default: text = "Turn \(turn) " + String(repeating: "about the plan ", count: 8)
            }
            let requestsBefore = transport.chatRequests.count
            try require(store.sendText(text, conversationID: threadID), "The companion send is accepted on turn \(turn)")
            try await settle(threadID)
            let requests = Array(transport.chatRequests.dropFirst(requestsBefore))
            guard let first = requests.first, let system = first.messages.first?.content else {
                throw NativeTaskFixture.Failure.assertion("The companion turn reached the model")
            }
            try require(first.tools.contains(NativeContinuityNotesTool.toolName), "The companion thread advertises the notes tool")
            try require(system.contains(NativeCompanionContext.notesHeader) && system.contains(NativeCompanionContext.notesRevision),
                        "The companion prompt explains the notes and when to revise them")
            if system.contains(NativeCompanionContext.summaryHeader) { sawSummary = true }
            if let revision = store.companionNotes()?.revision, notesRevisions.last != revision { notesRevisions.append(revision) }
        }
        try require(notesRevisions == [1, 2], "Each notes call writes the next revision (\(notesRevisions))")
        try require(store.companionNotes()?.text == CompanionScriptedTransport.notesMarker + "The review is now on Friday.",
                    "The read accessor returns the current notes")
        let written = try folds.folds(conversationID: threadID)
        try require(!written.isEmpty && sawSummary, "The companion thread folded after a completed turn and sent the summary")
        try require(transport.chatRequests.contains { $0.messages.first?.content.contains(NativeCompanionContext.nudgeLine) == true },
                    "A send after a fold nudges a notes revision")
        try await waitFor("Memory extraction ran") { memory.extractionInputs.count >= 20 }
        try require(memory.extractionInputs.allSatisfy { !$0.contains(CompanionScriptedTransport.notesMarker) },
                    "Notes never reach memory extraction")

        store.newConversation()
        guard let focusedID = store.selectedID, focusedID != threadID else {
            throw NativeTaskFixture.Failure.assertion("A focused chat is selected")
        }
        let before = transport.chatRequests.count
        try require(store.sendText("NOTE: this should not become notes.", conversationID: focusedID), "The focused send is accepted")
        try await settle(focusedID)
        guard let focused = transport.chatRequests.dropFirst(before).first, let system = focused.messages.first?.content else {
            throw NativeTaskFixture.Failure.assertion("The focused turn reached the model")
        }
        try require(!focused.tools.contains(NativeContinuityNotesTool.toolName), "The notes tool is absent from a focused chat")
        try require(!system.contains(NativeCompanionContext.notesHeader) && !system.contains(NativeCompanionContext.summaryHeader),
                    "A focused chat gets no companion sections")
        try require(store.companionNotes()?.revision == 2, "A focused chat never writes the companion notes")
        try require(try folds.folds(conversationID: focusedID).isEmpty, "A focused chat never folds")
        store.resetDot()
        let notesStore = NativeContinuityNotesStore(database: repository.database, characterLimit: 1_000)
        try require(try folds.folds(conversationID: threadID).isEmpty && notesStore.current(conversationID: threadID) == nil,
                    "Start over removes the summaries and notes with the conversation")
        try require(store.veraThreadID != threadID && store.companionNotes() == nil, "A fresh companion thread starts without notes")
    }
}


enum NativeCompanionFocusedFixture {
    static let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    static func memories() -> [NativeMemoryRanked] {
        [NativeMemoryRanked(
            record: NativeMemoryRecord(
                id: "memory", title: "Coffee", summary: "Drinks oat lattes",
                details: ["Prefers oat milk lattes"], group: .profile, category: .preference,
                bank: "personal", durability: .durable, expiry: nil, status: .approved,
                embedding: [1, 0], sourceConversationID: nil, sourceMessageID: nil,
                createdAt: timestamp, updatedAt: timestamp),
            score: 1)]
    }

    static func tools() -> [NativeToolDefinition] {
        [NativeToolDefinition(
            id: "fixture-lookup", name: "lookup_fixture", title: "Look up", description: "Look up a fixture value.",
            parameters: .object(["type": .string("object")]), confirmation: .none,
            isAvailable: { true }, execute: { _ in .object([:]) })]
    }

    static func input() -> NativeContextInput {
        NativeContextInput(
            persona: "You are a careful assistant.", userScope: "Prefers short answers.",
            conversationInstructions: "Keep it about the garden.", timestamp: timestamp,
            timeZone: TimeZone(identifier: "UTC") ?? .current, ownerName: "Sam", assistantName: "Ada",
            memories: memories(), knowledgeGrounding: "Seeds ship in spring.",
            capabilities: .textOnly, tools: tools(),
            contracts: NativePresentationContract.chatDefaults.union([.citations]),
            unavailableNotes: ["Images are not set up."], assistantProfile: nil)
    }

    static func messages() -> [Message] {
        var result: [Message] = []
        for index in 0..<40 {
            result.append(Message(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index * 2)) ?? UUID(),
                                  role: .user, text: "Question \(index): " + String(repeating: "word ", count: 30 + index)))
            var reply = Message(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index * 2 + 1)) ?? UUID(),
                                role: .assistant, text: "Answer \(index): " + String(repeating: "reply ", count: 40))
            if index % 7 == 3 {
                reply.toolActivities = [NativeToolActivity(
                    id: "call-\(index)", toolID: "fixture-lookup", name: "lookup_fixture", title: "Look up", round: 0,
                    request: "{\"q\":\"\(index)\"}", result: "{\"value\":\(index)}", state: .succeeded, confirmationRequired: false)]
            }
            result.append(reply)
        }
        return result
    }

    static let suffix = "\n\nAnswer the user's question directly."
    static let ceiling = 3_000

    static func digest(_ history: [NativeChatMessage]) -> String {
        let serialized = history.map { message in
            [message.role, message.content, message.toolCallID ?? "",
             message.toolCalls.map { $0.id + "|" + $0.name + "|" + $0.arguments }.joined(separator: ";"),
             message.images.joined(separator: ";")].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(serialized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func legacyHistory() -> [NativeChatMessage] {
        let assembled = NativeContextAssembler.assemble(input())
        return NativeChatHistoryBuilder.build(messages: messages(), systemPrompt: assembled.prompt + suffix,
                                              capabilities: .textOnly, contextCeiling: ceiling)
    }
}
