import Foundation
import GRDB

struct NativeCompanionContextBudget: Equatable, Sendable {
    static let notesShare = 0.10
    static let summaryShare = 0.20
    static let verbatimShare = 0.45
    static let memoryShare = 0.15
    static let minimumVerbatimTurns = 8
    static let foldTargetFraction = 0.6
    static let foldBatchTurns = 12
    static let foldSummaryFraction = 0.5
    static let defaultCeilingTokens = 32_768
    static let ceilingEnvironmentKey = "VERA_COMPANION_CONTEXT_TOKENS"

    static var configuredDefaultCeiling: Int {
        ProcessInfo.processInfo.environment[ceilingEnvironmentKey].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            ?? defaultCeilingTokens
    }

    let ceilingTokens: Int

    init(contextCeiling: Int?) {
        ceilingTokens = max(contextCeiling ?? Self.configuredDefaultCeiling, 1)
    }

    var totalCharacters: Int { ceilingTokens * NativeChatHistoryBuilder.approximateCharactersPerToken }

    func characters(_ share: Double) -> Int {
        Int((Double(totalCharacters) * share).rounded(.down))
    }

    var notesCharacters: Int { characters(Self.notesShare) }
    var notesTextCharacters: Int { max(notesCharacters - NativeCompanionContext.notesFramingCharacters, 0) }
    var summaryCharacters: Int { characters(Self.summaryShare) }
    var verbatimCharacters: Int { characters(Self.verbatimShare) }
    var memoryCharacters: Int { min(NativeContextAssembler.Caps.memory, characters(Self.memoryShare)) }
    var currentTurnCharacters: Int {
        characters(max(1 - Self.notesShare - Self.summaryShare - Self.verbatimShare - Self.memoryShare, 0))
    }
    var foldTargetCharacters: Int { Int((Double(verbatimCharacters) * Self.foldTargetFraction).rounded(.down)) }
    var foldSummaryCharacters: Int { Int((Double(summaryCharacters) * Self.foldSummaryFraction).rounded(.down)) }

    func historyCeiling(systemPrompt: String) -> Int {
        let perToken = NativeChatHistoryBuilder.approximateCharactersPerToken
        let characters = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count
            + verbatimCharacters + currentTurnCharacters
        return (characters + perToken - 1) / perToken
    }
}

struct NativeThreadFold: Equatable, Sendable {
    let id: String
    let conversationID: String
    let firstMessageID: String
    let lastMessageID: String
    let firstOrdinal: Int
    let lastOrdinal: Int
    let summary: String
    let model: String
    let createdAt: Date
}

enum NativeThreadFoldError: Error, LocalizedError, Equatable {
    case notContiguous(expected: Int?, found: Int)
    case invalidRange
    case unknownMessage

    var errorDescription: String? {
        switch self {
        case .notContiguous: return "Earlier turns can only be condensed in order."
        case .invalidRange: return "The condensed range is empty."
        case .unknownMessage: return "The condensed range no longer matches the conversation."
        }
    }
}

struct NativeThreadFoldStore: Sendable {
    let database: DatabaseQueue

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_thread_folds (
                id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                first_message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                last_message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                first_ordinal INTEGER NOT NULL,
                last_ordinal INTEGER NOT NULL,
                summary TEXT NOT NULL,
                model TEXT NOT NULL,
                created_at DOUBLE NOT NULL,
                CHECK (last_ordinal >= first_ordinal)
            );
            CREATE UNIQUE INDEX native_thread_folds_start ON native_thread_folds(conversation_id, first_message_id);
            CREATE INDEX native_thread_folds_order ON native_thread_folds(conversation_id, first_ordinal);
            """)
    }

    func insert(_ fold: NativeThreadFold) throws {
        try database.write { db in
            guard fold.lastOrdinal >= fold.firstOrdinal,
                  !fold.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeThreadFoldError.invalidRange
            }
            let previous = try Int.fetchOne(db, sql: "SELECT MAX(last_ordinal) FROM native_thread_folds WHERE conversation_id = ?",
                                            arguments: [fold.conversationID])
            let expected: Int?
            if let previous {
                expected = previous + 1
            } else {
                expected = try Int.fetchOne(db, sql: "SELECT MIN(ordinal) FROM messages WHERE conversation_id = ?",
                                            arguments: [fold.conversationID])
            }
            guard let expected, fold.firstOrdinal == expected else {
                throw NativeThreadFoldError.notContiguous(expected: expected, found: fold.firstOrdinal)
            }
            let first = try String.fetchOne(db, sql: "SELECT id FROM messages WHERE conversation_id = ? AND ordinal = ?",
                                            arguments: [fold.conversationID, fold.firstOrdinal])
            let last = try String.fetchOne(db, sql: "SELECT id FROM messages WHERE conversation_id = ? AND ordinal = ?",
                                           arguments: [fold.conversationID, fold.lastOrdinal])
            guard first == fold.firstMessageID, last == fold.lastMessageID else { throw NativeThreadFoldError.unknownMessage }
            try db.execute(sql: """
                INSERT INTO native_thread_folds
                    (id, conversation_id, first_message_id, last_message_id, first_ordinal, last_ordinal, summary, model, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [fold.id, fold.conversationID, fold.firstMessageID, fold.lastMessageID,
                                 fold.firstOrdinal, fold.lastOrdinal, fold.summary, fold.model,
                                 fold.createdAt.timeIntervalSince1970])
        }
    }

    func folds(conversationID: String) throws -> [NativeThreadFold] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, conversation_id, first_message_id, last_message_id, first_ordinal, last_ordinal, summary, model, created_at
                FROM native_thread_folds WHERE conversation_id = ? ORDER BY first_ordinal ASC
                """, arguments: [conversationID]).map { row in
                NativeThreadFold(id: row["id"], conversationID: row["conversation_id"],
                                 firstMessageID: row["first_message_id"], lastMessageID: row["last_message_id"],
                                 firstOrdinal: row["first_ordinal"], lastOrdinal: row["last_ordinal"],
                                 summary: row["summary"], model: row["model"],
                                 createdAt: Date(timeIntervalSince1970: row["created_at"]))
            }
        }
    }

    func lastFoldedOrdinal(conversationID: String) throws -> Int? {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(last_ordinal) FROM native_thread_folds WHERE conversation_id = ?",
                             arguments: [conversationID])
        }
    }

    func foldedMessageIDs(conversationID: String) throws -> Set<UUID> {
        try database.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM messages
                WHERE conversation_id = ?
                  AND ordinal <= (SELECT MAX(last_ordinal) FROM native_thread_folds WHERE conversation_id = ?)
                """, arguments: [conversationID, conversationID])
            return Set(ids.compactMap(UUID.init(uuidString:)))
        }
    }

    func orderedMessages(conversationID: String) throws -> [(ordinal: Int, message: Message)] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ordinal, id, role, content, created_at, state, failure, model_id,
                       tool_activity_json, content_type, metadata_json, attachments_json,
                       route_json, sources_json, spoken_text, display_blocks_json
                FROM messages WHERE conversation_id = ? ORDER BY ordinal ASC
                """, arguments: [conversationID]).compactMap { row in
                guard let message = LocalChatRepository.decodeMessages([row]).first else { return nil }
                return (ordinal: row["ordinal"], message: message)
            }
        }
    }
}

enum NativeContinuityNoteOrigin: String, Sendable {
    case companion
}

struct NativeContinuityNote: Equatable, Sendable {
    let conversationID: String
    let revision: Int
    let text: String
    let origin: String
    let createdAt: Date
}

struct NativeContinuityNotesStore: Sendable {
    let database: DatabaseQueue
    let characterLimit: Int

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE native_continuity_notes (
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL,
                text TEXT NOT NULL,
                origin TEXT NOT NULL,
                created_at DOUBLE NOT NULL,
                PRIMARY KEY (conversation_id, revision)
            )
            """)
    }

    static func prepared(_ text: String, limit: Int) -> String {
        let redacted = NativeDiagnosticRedaction.text(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(redacted.prefix(max(limit, 0))).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func current(conversationID: String) throws -> NativeContinuityNote? {
        try database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT conversation_id, revision, text, origin, created_at FROM native_continuity_notes
                WHERE conversation_id = ? ORDER BY revision DESC LIMIT 1
                """, arguments: [conversationID]).map { row in
                NativeContinuityNote(conversationID: row["conversation_id"], revision: row["revision"], text: row["text"],
                                     origin: row["origin"], createdAt: Date(timeIntervalSince1970: row["created_at"]))
            }
        }
    }

    @discardableResult
    func append(conversationID: String, text: String, origin: NativeContinuityNoteOrigin, now: Date = Date()) throws -> Int {
        let stored = Self.prepared(text, limit: characterLimit)
        return try database.write { db in
            let revision = (try Int.fetchOne(db, sql: "SELECT MAX(revision) FROM native_continuity_notes WHERE conversation_id = ?",
                                             arguments: [conversationID]) ?? 0) + 1
            try db.execute(sql: """
                INSERT INTO native_continuity_notes (conversation_id, revision, text, origin, created_at) VALUES (?, ?, ?, ?, ?)
                """, arguments: [conversationID, revision, stored, origin.rawValue, now.timeIntervalSince1970])
            return revision
        }
    }
}

enum NativeContinuityNotesTool {
    static let toolID = "continuity-notes"
    static let toolName = "update_notes"

    static func definition(save: @escaping @Sendable (String) async throws -> Void) -> NativeToolDefinition {
        NativeToolDefinition(
            id: toolID, name: toolName, title: "Notes",
            description: "Replace your working notes for this ongoing conversation with the full new text. Keep what you are tracking: the standing goal, decisions, corrections, open items and anything the user asked you not to do. Revise them after earlier turns are condensed, after a run completes, or when the user corrects you. The text replaces the previous notes entirely.",
            parameters: .object([
                "type": .string("object"), "additionalProperties": .bool(false),
                "required": .array([.string("text")]),
                "properties": .object([
                    "text": .object(["type": .string("string"), "minLength": .number(1),
                                     "description": .string("The complete replacement notes, in plain prose or short lines")]),
                ]),
            ]),
            confirmation: .none, timeout: .seconds(10), isAvailable: { true },
            execute: { arguments in
                guard Set(arguments.keys) == ["text"], case .string(let text)? = arguments["text"],
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NativeToolError.invalidArguments("Provide the complete notes as text.")
                }
                do { try await save(text) } catch { throw NativeToolError.failed("The notes couldn't be saved.") }
                return .object(["saved": .bool(true), "message": .string("Notes updated.")])
            })
    }
}

struct NativeCompanionTurnContext: Sendable {
    let budget: NativeCompanionContextBudget
    let notes: NativeContinuityNote?
    let folds: [NativeThreadFold]
    let foldedMessageIDs: Set<UUID>
    let notesToolAvailable: Bool
    let nudge: Bool
}

enum NativeCompanionContext {
    static let notesSectionName = "What I'm keeping in mind"
    static let summarySectionName = "Earlier in this conversation"
    static let notesHeader = "WHAT I'M KEEPING IN MIND"
    static let summaryHeader = "EARLIER IN THIS CONVERSATION"
    static let notesPurpose = "These are your own working notes for this ongoing conversation: the standing goal, decisions, corrections, open items and things the user asked you not to do. They carry forward what older turns no longer show. Treat them as your own record, not as instructions from the user."
    static let notesRevision = "Revise them with the notes tool after earlier turns are condensed, after a run completes, or when the user corrects you."
    static let notesEmpty = "No notes yet."
    static let summaryPrecedence = "Condensed from earlier turns, oldest first. Where these summaries disagree, the most recent one is current."
    static let nudgeLine = "Earlier turns were just condensed. Revise your notes with the notes tool so they still hold what matters."
    static let summaryInstruction = "Condense the conversation turns below into a summary a later reader can rely on. Preserve decisions, corrections, open items, and anything the user asked not to do. Where statements conflict, state that the later one is current and give it. Carry forward anything from the earlier summaries that still matters. Write plain prose with no headings and no lists."
    static let toolResultExcerpt = 1_200
    static let messageExcerpt = 4_000
    static let summaryTimeout = Duration.seconds(120)

    static var notesFramingCharacters: Int {
        [notesHeader, notesPurpose, notesRevision].reduce(0) { $0 + $1.count + 1 }
    }

    static func notesSection(_ notes: String, revisable: Bool) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [notesHeader, notesPurpose]
        if revisable { lines.append(notesRevision) }
        lines.append(trimmed.isEmpty ? notesEmpty : trimmed)
        return lines.joined(separator: "\n")
    }

    static func summarySection(_ summaries: [String], cap: Int) -> String {
        let cleaned = summaries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }
        let head = summaryHeader + "\n" + summaryPrecedence
        var kept: [String] = []
        var used = head.count
        for summary in cleaned.reversed() {
            let cost = summary.count + 2
            if used + cost > cap, !kept.isEmpty { break }
            kept.insert(summary, at: 0)
            used += cost
        }
        return ([head] + kept).joined(separator: "\n\n")
    }

    static func load(conversationID: String, database: DatabaseQueue, budget: NativeCompanionContextBudget,
                     notesToolAvailable: Bool, claimNudge: (String) -> Bool) -> NativeCompanionTurnContext {
        let folds = NativeThreadFoldStore(database: database)
        let notesStore = NativeContinuityNotesStore(database: database, characterLimit: budget.notesTextCharacters)
        let written = (try? folds.folds(conversationID: conversationID)) ?? []
        let folded = (try? folds.foldedMessageIDs(conversationID: conversationID)) ?? []
        let notes = try? notesStore.current(conversationID: conversationID)
        var nudge = false
        if notesToolAvailable, let latest = written.last, notes.map({ $0.createdAt < latest.createdAt }) ?? true {
            nudge = claimNudge(latest.id)
        }
        return NativeCompanionTurnContext(budget: budget, notes: notes, folds: written, foldedMessageIDs: folded,
                                          notesToolAvailable: notesToolAvailable, nudge: nudge)
    }

    static func verbatim(_ messages: [Message], context: NativeCompanionTurnContext) -> [Message] {
        messages.filter { !context.foldedMessageIDs.contains($0.id) }
    }

    static func compose(
        input: NativeContextInput, messages: [Message], suffix: String,
        imageLoader: ((MessageAttachment) -> String?)?, capabilities: ModelCapabilityProfile,
        contextCeiling: Int?, companion: NativeCompanionTurnContext?
    ) -> (assembled: NativeAssembledContext, history: [NativeChatMessage]) {
        guard let companion else {
            let assembled = NativeContextAssembler.assemble(input)
            return (assembled, NativeChatHistoryBuilder.build(
                messages: messages, systemPrompt: assembled.prompt + suffix,
                imageLoader: imageLoader, capabilities: capabilities, contextCeiling: contextCeiling))
        }
        var scoped = input
        scoped.continuityNotes = companion.notes?.text ?? ""
        scoped.continuityNotesRevisable = companion.notesToolAvailable
        scoped.threadSummary = companion.folds.map(\.summary)
        scoped.companionBudget = companion.budget
        let assembled = NativeContextAssembler.assemble(scoped)
        let prompt = assembled.prompt + suffix + (companion.nudge && companion.notesToolAvailable ? "\n\n" + nudgeLine : "")
        let history = NativeChatHistoryBuilder.build(
            messages: verbatim(messages, context: companion), systemPrompt: prompt,
            imageLoader: imageLoader, capabilities: capabilities,
            contextCeiling: companion.budget.historyCeiling(systemPrompt: prompt))
        return (assembled, history)
    }

    static func verbatimCost(_ messages: [Message]) -> Int {
        NativeChatHistoryBuilder.build(messages: messages, systemPrompt: "", imageLoader: { _ in "" })
            .reduce(0) { $0 + NativeChatHistoryBuilder.cost($1) }
    }

    static func batch(_ unfolded: [(ordinal: Int, message: Message)], budget: NativeCompanionContextBudget)
        -> [(ordinal: Int, message: Message)]? {
        let userTurns = unfolded.filter { $0.message.role == .user }.count
        let take = min(NativeCompanionContextBudget.foldBatchTurns, userTurns - NativeCompanionContextBudget.minimumVerbatimTurns)
        guard take > 0 else { return nil }
        var selected: [(ordinal: Int, message: Message)] = []
        var turnStart = 0
        var users = 0
        for entry in unfolded {
            if entry.message.role == .user {
                if users == take { break }
                users += 1
                turnStart = selected.count
            }
            if entry.message.state == .streaming {
                selected.removeSubrange(turnStart...)
                break
            }
            selected.append(entry)
        }
        guard selected.contains(where: { $0.message.role == .user }) else { return nil }
        for (offset, entry) in selected.enumerated() where offset > 0 && entry.ordinal != selected[offset - 1].ordinal + 1 {
            return nil
        }
        return selected
    }

    static func transcript(_ messages: [Message]) -> String {
        var lines: [String] = []
        for message in messages where message.state == .complete {
            if message.role == .user {
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append("User: " + String(text.prefix(messageExcerpt))) }
                continue
            }
            for activity in message.toolActivities.sorted(by: { $0.round < $1.round }) {
                let result = String((activity.result ?? "no result").prefix(toolResultExcerpt))
                lines.append("Assistant used \(activity.title) with \(String(activity.request.prefix(toolResultExcerpt))). Result: \(result)")
            }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append("Assistant: " + String(text.prefix(messageExcerpt))) }
        }
        return lines.joined(separator: "\n")
    }

    static func summaryRequest(_ messages: [Message], previous: [NativeThreadFold], limit: Int) -> [NativeChatMessage] {
        let words = max(limit / 6, 40)
        var body: [String] = []
        if !previous.isEmpty {
            body.append("Earlier summaries, oldest first:\n" + previous.map(\.summary).joined(separator: "\n\n"))
        }
        body.append("Turns to condense:\n" + transcript(messages))
        return [
            NativeChatMessage(role: "system", content: summaryInstruction + " Keep it under \(words) words."),
            NativeChatMessage(role: "user", content: body.joined(separator: "\n\n")),
        ]
    }

    static func summarize(_ request: [NativeChatMessage], transport: any NativeChatTransport, model: String) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                var content = ""
                for try await snapshot in transport.stream(messages: request, model: model, tools: []) {
                    content = snapshot.content
                }
                return content
            }
            group.addTask {
                try await Task.sleep(for: summaryTimeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let content = first else { throw CancellationError() }
            return content
        }
    }

    @discardableResult
    static func compact(
        conversationID: String, folds store: NativeThreadFoldStore, transport: any NativeChatTransport,
        model: String, budget: NativeCompanionContextBudget, resuming: Bool = false, now: @Sendable () -> Date = { Date() }
    ) async throws -> Int {
        var written = 0
        while true {
            try Task.checkCancellation()
            let ordered = try store.orderedMessages(conversationID: conversationID)
            let last = try store.lastFoldedOrdinal(conversationID: conversationID)
            let unfolded = ordered.filter { entry in last.map { entry.ordinal > $0 } ?? true }
            let threshold = written == 0 && !resuming ? budget.verbatimCharacters : budget.foldTargetCharacters
            guard verbatimCost(unfolded.map(\.message)) > threshold,
                  let selected = batch(unfolded, budget: budget),
                  let first = selected.first, let final = selected.last else { break }
            let previous = try store.folds(conversationID: conversationID)
            let request = summaryRequest(selected.map(\.message), previous: previous, limit: budget.foldSummaryCharacters)
            let raw = try await summarize(request, transport: transport, model: model)
            let summary = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(budget.foldSummaryCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { throw NativeThreadFoldError.invalidRange }
            try store.insert(NativeThreadFold(
                id: UUID().uuidString, conversationID: conversationID,
                firstMessageID: first.message.id.uuidString, lastMessageID: final.message.id.uuidString,
                firstOrdinal: first.ordinal, lastOrdinal: final.ordinal,
                summary: summary, model: model, createdAt: now()))
            written += 1
        }
        return written
    }
}

final class NativeCompanionCompactor: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Set<String> = []
    private var pending: Set<String> = []
    private var nudged: [String: String] = [:]
    private var retrying: Set<String> = []
    private var failures = 0

    var failureCount: Int { lock.withLock { failures } }

    func isRunning(_ conversationID: String) -> Bool {
        lock.withLock { running.contains(conversationID) || pending.contains(conversationID) }
    }

    func claimNudge(conversationID: String, foldID: String) -> Bool {
        lock.withLock {
            guard nudged[conversationID] != foldID else { return false }
            nudged[conversationID] = foldID
            return true
        }
    }

    func forget(_ conversationID: String) {
        lock.withLock { _ = nudged.removeValue(forKey: conversationID) }
    }

    private func begin(_ conversationID: String) -> Bool {
        lock.withLock {
            guard !running.contains(conversationID) else {
                pending.insert(conversationID)
                return false
            }
            running.insert(conversationID)
            return true
        }
    }

    private func finishPass(_ conversationID: String) -> Bool {
        lock.withLock {
            if pending.remove(conversationID) != nil { return true }
            running.remove(conversationID)
            return false
        }
    }

    func compact(conversationID: String, store: NativeThreadFoldStore, transport: any NativeChatTransport,
                 model: String, budget: NativeCompanionContextBudget) async {
        guard begin(conversationID) else { return }
        repeat {
            let resuming = lock.withLock { retrying.contains(conversationID) }
            do {
                try await NativeCompanionContext.compact(conversationID: conversationID, folds: store, transport: transport,
                                                         model: model, budget: budget, resuming: resuming)
                lock.withLock { _ = retrying.remove(conversationID) }
            } catch {
                lock.withLock {
                    failures += 1
                    retrying.insert(conversationID)
                }
            }
        } while finishPass(conversationID)
    }
}

extension ChatStore {
    func companionNotesStore(budget: NativeCompanionContextBudget) -> NativeContinuityNotesStore? {
        guard let local = repository as? LocalChatRepository else { return nil }
        return NativeContinuityNotesStore(database: local.database, characterLimit: budget.notesTextCharacters)
    }

    func companionNotes() -> (text: String, revision: Int)? {
        guard let threadID = veraThreadID,
              let store = companionNotesStore(budget: NativeCompanionContextBudget(contextCeiling: currentNativeConfig?.options.contextCeiling)),
              let note = try? store.current(conversationID: threadID) else { return nil }
        return (note.text, note.revision)
    }

    func companionAllowsNotesTool(_ turn: NativeConversationTurn, supportsTools: Bool, authority: NativeTurnToolAuthority) -> Bool {
        isVeraThread(turn.conversationID) && turn.mode != .continuous && supportsTools && authority.allowsTools
            && repository is LocalChatRepository
    }

    func companionNotesToolDefinition(for turn: NativeConversationTurn, contextCeiling: Int?) -> NativeToolDefinition? {
        guard isVeraThread(turn.conversationID), turn.mode != .continuous,
              let store = companionNotesStore(budget: NativeCompanionContextBudget(contextCeiling: contextCeiling)) else { return nil }
        let conversationID = turn.conversationID
        return NativeContinuityNotesTool.definition { text in
            try store.append(conversationID: conversationID, text: text, origin: .companion)
        }
    }

    func companionTurnContext(conversationID: String, contextCeiling: Int?, notesToolAvailable: Bool) -> NativeCompanionTurnContext? {
        guard isVeraThread(conversationID), let local = repository as? LocalChatRepository else { return nil }
        let compactor = companionCompactor
        return NativeCompanionContext.load(
            conversationID: conversationID, database: local.database,
            budget: NativeCompanionContextBudget(contextCeiling: contextCeiling), notesToolAvailable: notesToolAvailable,
            claimNudge: { compactor.claimNudge(conversationID: conversationID, foldID: $0) })
    }

    func scheduleCompanionCompaction(conversationID: String, transport: any NativeChatTransport, model: String, contextCeiling: Int?) {
        guard isVeraThread(conversationID), let local = repository as? LocalChatRepository, !model.isEmpty else { return }
        let compactor = companionCompactor
        let store = NativeThreadFoldStore(database: local.database)
        let budget = NativeCompanionContextBudget(contextCeiling: contextCeiling)
        Task.detached(priority: .utility) {
            await compactor.compact(conversationID: conversationID, store: store, transport: transport, model: model, budget: budget)
        }
    }
}
