import Foundation

extension NativeRequestAuthorizer {
    static func refusalsReply(_ items: [String]) -> String {
        "{\"refusals\": " + NativeActionDescription.literalList(items) + "}"
    }

    static let noRestrictions = refusalsReply([])

    static func refusalCheckReply(_ decision: NativeRefusalDecision) -> String {
        "{\"decision\": \"" + decision.rawValue + "\"}"
    }

    static func asksRestrictions(_ messages: [NativeChatMessage]) -> Bool {
        messages.first?.content == restrictionPrompt
    }

    static func asksRefusalCheck(_ messages: [NativeChatMessage]) -> Bool {
        messages.first?.content == refusalCheckPrompt
    }

    static func answered(_ reply: String) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(NativeChatStreamSnapshot(content: reply, toolCalls: [], finishReason: "stop"))
            continuation.finish()
        }
    }
}

final class NativeRestrictionScript: @unchecked Sendable {
    enum Reply: Sendable {
        case text(String)
        case failure
        case toolCall
        case silence
    }

    private let lock = NSLock()
    private var reply: Reply
    private let check: @Sendable (String) -> Reply
    private var asked: [[NativeChatMessage]] = []
    private var checked: [[NativeChatMessage]] = []
    private var decided: [[NativeChatMessage]] = []

    init(_ reply: Reply, check: @escaping @Sendable (String) -> Reply = { _ in .text(NativeRequestAuthorizer.refusalCheckReply(.ruledOut)) }) {
        self.reply = reply
        self.check = check
    }

    var calls: Int { lock.withLock { asked.count } }
    var requests: [[NativeChatMessage]] { lock.withLock { asked } }
    var checkCalls: Int { lock.withLock { checked.count } }
    var checkRequests: [[NativeChatMessage]] { lock.withLock { checked } }
    var decisionCalls: Int { lock.withLock { decided.count } }
    func answer(_ next: Reply) { lock.withLock { reply = next } }

    func respond(_ messages: [NativeChatMessage]) async throws -> String {
        let current: Reply
        if NativeRequestAuthorizer.asksRestrictions(messages) {
            current = lock.withLock { () -> Reply in
                asked.append(messages)
                return reply
            }
        } else if NativeRequestAuthorizer.asksRefusalCheck(messages) {
            lock.withLock { checked.append(messages) }
            current = check(messages.last?.content ?? "")
        } else {
            lock.withLock { decided.append(messages) }
            return "{\"decision\": \"not_authorized\"}"
        }
        switch current {
        case .text(let text): return text
        case .failure: throw NativeChatClient.ClientError.http(500, "")
        case .toolCall: throw NativeRequestAuthorizer.ToolCallReply()
        case .silence:
            try await Task.sleep(for: .seconds(30))
            return NativeRequestAuthorizer.noRestrictions
        }
    }

    var transport: NativeRequestAuthorizer.Transport {
        { messages in try await self.respond(messages) }
    }
}

final class NativeRestrictionCards: @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [String] = []
    let approves: Bool

    init(approves: Bool) { self.approves = approves }

    var names: [String] { lock.withLock { shown } }

    func confirm(_ activity: NativeToolActivity) async -> Bool {
        lock.withLock { shown.append(activity.name) }
        return approves
    }
}

@MainActor
extension SelfTest {
    nonisolated static let restrictionText = "Look at my notes and tell me what to plant."

    static func runRequestRestrictions() async throws {
        try restrictionReplies()
        try restrictionDescriptions()
        try await restrictionNothingRefused()
        try await restrictionRuledOut()
        try await restrictionPerCall()
        try await restrictionScheduledResearch()
        try await restrictionUnclear()
        try await restrictionUnavailable()
        try await restrictionOncePerMessage()
        try await restrictionOrder()
        try await restrictionResolvedTarget()
        try await restrictionNeverRan()
        try await restrictionTargetMoves()
        try await restrictionRetry()
        try await restrictionPromptShape()
        try await restrictionCancellation()
        try await restrictionNotice()
        try await restrictionStore()
        try await restrictionSystemAccess()
        print("  request restrictions OK (strict replies, plain descriptions, nothing refused, ruled out, per call, scheduled research, unclear, questions down, once per message, message only, cancellation, settings notice, store, no macOS prompt for a ruled out call)")
    }

    nonisolated static func restrictionReader(_ hits: NativeChatRulesCounter, name: String = "read_notes") -> NativeToolDefinition {
        NativeToolDefinition(id: "fixture-" + name, name: name, title: "Read the notes", description: "Fixture",
                             parameters: .object(["type": .string("object")]),
                             confirmation: .none, timeout: .seconds(5), effect: .read, isAvailable: { true },
                             execute: { _ in hits.hit(); return .object(["notes": .string("Water the beans")]) })
    }

    nonisolated static func restrictionStarter(_ hits: NativeChatRulesCounter) -> NativeToolDefinition {
        NativeToolDefinition(id: NativeTaskTools.toolID, name: NativeTaskTools.toolName, title: "Start work", description: "Fixture",
                             parameters: .object(["type": .string("object"),
                                                  "properties": .object(["worker_type": .object(["type": .string("string")]),
                                                                         "objective": .object(["type": .string("string")])])]),
                             confirmation: .none, timeout: .seconds(5), effect: .read, isAvailable: { true },
                             execute: { _ in hits.hit(); return .object(["started": .bool(true)]) })
    }

    nonisolated static func restrictionCall(_ id: String, _ name: String, _ arguments: String = "{}") -> NativeChatToolCall {
        NativeChatToolCall(id: id, name: name, arguments: arguments)
    }

    nonisolated static func restrictionRound(_ calls: [NativeChatToolCall]) -> [NativeChatStreamSnapshot] {
        [NativeChatStreamSnapshot(content: "", toolCalls: calls, finishReason: "tool_calls")]
    }

    nonisolated static let restrictionDone = [NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")]

    nonisolated static func restrictionDrive(_ definitions: [NativeToolDefinition], _ rounds: [[NativeChatStreamSnapshot]], script: NativeRestrictionScript,
                                             text: String = restrictionText, message: UUID = UUID(),
                                             cache: NativeRequestRestrictionCache = NativeRequestRestrictionCache(),
                                             deadline: Duration = .seconds(2), cards: NativeRestrictionCards = NativeRestrictionCards(approves: false),
                                             observe: NativeRequestAuthorizer.Observer? = nil,
                                             history: [NativeChatMessage]? = nil, earlierAttempt: Bool = false) async throws -> (activities: [NativeToolActivity], transport: ScriptedNativeToolTransport) {
        let transport = ScriptedNativeToolTransport(rounds: rounds)
        let authorizer = NativeRequestAuthorizer(transport: script.transport, deadline: deadline, observe: observe)
        let check = NativeRestrictionCheck(authorizer: authorizer, messageID: message, text: text, cache: cache, earlierAttempt: earlierAttempt)
        let loop = NativeToolLoop(transport: transport, registry: NativeToolRegistry(definitions: definitions),
                                  confirm: { await cards.confirm($0) }, authorizer: authorizer, restrictions: check)
        var final: NativeToolTurnSnapshot?
        for try await snapshot in loop.stream(messages: history ?? [NativeChatMessage(role: "user", content: text)], model: "local-model",
                                              enabledToolIDs: Set(definitions.map(\.id))) {
            final = snapshot
        }
        return (final?.activities ?? [], transport)
    }

    nonisolated static func restrictionAction(_ content: String) -> String {
        guard let range = content.range(of: NativeRequestAuthorizer.actionLabel + "\n") else { return "" }
        return String(content[range.upperBound...])
    }

    private static func restrictionReplies() throws {
        let require = NativeTaskFixture.require
        let longest = Array(repeating: String(repeating: "x", count: NativeRequestAuthorizer.refusalItemLength), count: NativeRequestAuthorizer.refusalItemLimit)
        let accepted: [(String, [String])] = [
            (NativeRequestAuthorizer.noRestrictions, []),
            (NativeRequestAuthorizer.refusalsReply(["use any tools"]), ["use any tools"]),
            ("<think>They said no research.</think>" + NativeRequestAuthorizer.refusalsReply(["research anything", "write a document"]),
             ["research anything", "write a document"]),
            ("{\"refusals\":[\"look it up\"]}", ["look it up"]),
            (NativeRequestAuthorizer.refusalsReply(longest), longest),
        ]
        for (reply, items) in accepted {
            try require(NativeRequestAuthorizer.refusalItems(reply) == items, "A well formed list is read: \(reply.prefix(80))")
        }
        let malformed = [
            "{}",
            "{\"refusals\": [], \"why\": \"said so\"}",
            "{\"refusals\": \"use any tools\"}",
            "{\"refusals\": [1]}",
            "{\"refusals\": [\"\"]}",
            NativeRequestAuthorizer.refusalsReply(Array(repeating: "x", count: NativeRequestAuthorizer.refusalItemLimit + 1)),
            NativeRequestAuthorizer.refusalsReply([String(repeating: "x", count: NativeRequestAuthorizer.refusalItemLength + 1)]),
            "```json\n" + NativeRequestAuthorizer.noRestrictions + "\n```",
            NativeRequestAuthorizer.noRestrictions + " because nothing was refused",
            "{\"decision\": \"ruled_out\"}", "", "none", "[]",
            "{\"refusals\": [], \"refusals\": [\"use any tools\"]}",
            "{\"refusals\": []" + String(repeating: " ", count: NativeRequestAuthorizer.refusalReplyLimit) + "}",
        ]
        for reply in malformed {
            try require(NativeRequestAuthorizer.refusalItems(reply) == nil, "A list that doesn't match the schema exactly is not read: \(reply.prefix(80))")
        }
        let decisions: [(String, NativeRefusalDecision)] = [
            (NativeRequestAuthorizer.refusalCheckReply(.ruledOut), .ruledOut),
            (NativeRequestAuthorizer.refusalCheckReply(.notRuledOut), .notRuledOut),
            ("<think>Unsure.</think>" + NativeRequestAuthorizer.refusalCheckReply(.unclear), .unclear),
        ]
        for (reply, decision) in decisions {
            try require(NativeRequestAuthorizer.refusalDecision(reply) == decision, "A well formed answer is read: \(reply)")
        }
        for reply in ["{\"decision\": \"authorized\"}", "{\"decision\": \"ruled_out\", \"why\": \"x\"}", NativeRequestAuthorizer.noRestrictions,
                      "ruled_out", "", "{\"decision\": \"ruled_out\"" + String(repeating: " ", count: 260) + "}"] {
            try require(NativeRequestAuthorizer.refusalDecision(reply) == nil, "An answer that doesn't match the schema exactly is not read: \(reply.prefix(80))")
        }
        try require(NativeRequestAuthorizer.restrictionValidator != nil && NativeRequestAuthorizer.refusalCheckValidator != nil, "Both answer schemas compile")
        for prompt in [NativeRequestAuthorizer.restrictionPrompt, NativeRequestAuthorizer.refusalCheckPrompt, NativeRefusalList.ruledOutSentence] {
            try require(!prompt.contains("Ver" + "a") && !prompt.contains("\u{2014}"), "The fixed text names no product and has no long dashes: \(prompt)")
        }
    }

    private static func restrictionDescriptions() throws {
        let require = NativeTaskFixture.require
        let hits = NativeChatRulesCounter()
        func tool(_ id: String, _ name: String, _ title: String, _ effect: NativeToolEffect) -> NativeToolDefinition {
            NativeToolDefinition(id: id, name: name, title: title, description: "Fixture", parameters: .object(["type": .string("object")]),
                                 confirmation: .none, effect: effect, isAvailable: { true }, execute: { _ in .object([:]) })
        }
        let reminders = NativeRemindersTools.definitions(service: SelfTestRemindersService())
        func reminder(_ name: String) -> NativeToolDefinition { reminders.first { $0.name == name } ?? tool("none", name, name, .read) }
        let scheduler = NativeScheduleTools.definition(searchAvailable: { true }, save: { _ in throw NativeToolError.failed("unused") })
        let cases: [(NativeToolDefinition, [String: NativeJSONValue], String)] = [
            (tool(NativeWebTools.searchToolID, NativeWebTools.searchToolName, "Search the web", .read), ["query": .string("SECRET-QUERY")],
             "Search the web"),
            (tool(NativeWebTools.fetchToolID, NativeWebTools.fetchToolName, "Read a web page", .read), ["url": .string("https://example.com/a?SECRET=1")],
             "Read a web page on \"example.com\""),
            (restrictionStarter(hits), ["worker_type": .string("research"), "objective": .string("SECRET-OBJECTIVE")],
             "Start research on a question across web sources now, carrying on after this reply and reporting back in this chat"),
            (restrictionStarter(hits), ["worker_type": .string("document"), "objective": .string("SECRET-OBJECTIVE")],
             "Start writing a document for the Library now, carrying on after this reply and reporting back in this chat"),
            (scheduler, ["worker_type": .string("research"), "repeat": .string("every_hours"), "hours": .number(6), "instruction": .string("SECRET-INSTRUCTION")],
             "Set up a schedule that runs research on a question across web sources later, every 6 hours"),
            (reminder("apple_reminders_list"), ["list": .string("Errands")], "Read reminders from the list \"Errands\""),
            (reminder("apple_reminders_create"), ["list": .string("Errands"), "title": .string("SECRET-TITLE")], "Add a reminder to the list \"Errands\""),
            (reminder("apple_reminders_complete"), ["id": .string("SECRET-ID")], "Mark a reminder as done"),
            (restrictionReader(hits), [:], "Look something up with \"Read the notes\", which only reads and changes nothing"),
            (tool("fixture-garden", "plant_bulbs", "Plant the bulbs", .write), ["note": .string("SECRET-NOTE")], "Use \"Plant the bulbs\", which makes a change"),
        ]
        for (definition, arguments, expected) in cases {
            let described = NativeActionDescription.describe(definition, arguments: arguments)
            try require(described == expected && !described.contains("SECRET") && !described.contains("\u{2014}"),
                        "Every call is described plainly by what it would do, never by its free text: \(described)")
        }
    }

    private static func restrictionNothingRefused() async throws {
        let require = NativeTaskFixture.require
        let hits = NativeChatRulesCounter()
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.noRestrictions))
        let cards = NativeRestrictionCards(approves: false)
        let (activities, _) = try await restrictionDrive([restrictionReader(hits), restrictionStarter(hits)],
            [restrictionRound([restrictionCall("read", "read_notes"),
                               restrictionCall("start", NativeTaskTools.toolName, "{\"worker_type\":\"research\"}")]), restrictionDone],
            script: script, cards: cards)
        try require(hits.count == 2 && activities.allSatisfy { $0.state == .succeeded } && cards.names.isEmpty,
                    "With nothing refused, calls follow the usual rules")
        try require(script.calls == 1 && script.checkCalls == 0, "An empty list asks nothing more in this reply")
    }

    private static func restrictionRuledOut() async throws {
        let require = NativeTaskFixture.require
        let hits = NativeChatRulesCounter()
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["use any tools"])))
        let cards = NativeRestrictionCards(approves: true)
        let (activities, transport) = try await restrictionDrive([restrictionReader(hits), restrictionStarter(hits)],
            [restrictionRound([restrictionCall("read", "read_notes"),
                               restrictionCall("start", NativeTaskTools.toolName, "{\"worker_type\":\"research\"}")]), restrictionDone],
            script: script, cards: cards)
        let sentence = NativeRefusalList.ruledOutSentence
        try require(hits.count == 0 && cards.names.isEmpty && script.calls == 1 && script.checkCalls == 2,
                    "Ruled out calls run nothing, show no card, and each distinct call is asked about once")
        try require(activities.count == 2 && activities.allSatisfy { $0.state == .failed && ($0.result ?? "").contains(sentence) },
                    "Each ruled out call gets the fixed sentence: \(activities.map { $0.result ?? "" })")
        let toolMessages = (transport.histories.last ?? []).filter { $0.role == "tool" }
        try require(toolMessages.count == 2 && toolMessages.allSatisfy { $0.content.contains(sentence) }, "The model receives the fixed sentence")
    }

    private static func restrictionPerCall() async throws {
        let require = NativeTaskFixture.require
        let reads = NativeChatRulesCounter()
        let starts = NativeChatRulesCounter()
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["start research"]))) { content in
            .text(NativeRequestAuthorizer.refusalCheckReply(SelfTest.restrictionAction(content).hasPrefix("Start research") ? .ruledOut : .notRuledOut))
        }
        let cards = NativeRestrictionCards(approves: true)
        let (activities, _) = try await restrictionDrive([restrictionReader(reads), restrictionStarter(starts)],
            [restrictionRound([restrictionCall("research", NativeTaskTools.toolName, "{\"worker_type\":\"research\"}"),
                               restrictionCall("document", NativeTaskTools.toolName, "{\"worker_type\":\"document\"}"),
                               restrictionCall("read", "read_notes")]),
             restrictionRound([restrictionCall("again", "read_notes")]), restrictionDone],
            script: script, cards: cards)
        func activity(_ id: String) -> NativeToolActivity? { activities.first { $0.id == id } }
        try require(activity("research")?.state == .failed && (activity("research")?.result ?? "").contains(NativeRefusalList.ruledOutSentence),
                    "The call the list rules out does not run")
        try require(activity("document")?.state == .succeeded && activity("read")?.state == .succeeded && activity("again")?.state == .succeeded
                    && starts.count == 1 && reads.count == 2, "Calls the list doesn't rule out run as usual")
        try require(cards.names.isEmpty && script.calls == 1 && script.checkCalls == 4,
                    "Every call is asked about, and the same call again in a later round is asked again: \(script.checkCalls)")
        let last = script.checkRequests.last?.last?.content ?? ""
        try require(last.contains(NativeRequestAuthorizer.ranLabel + "\n1. ") && last.contains("\n2. ") && !last.contains("\n3. "),
                    "A later call is asked about with the calls that already ran in this reply: \(last)")
    }

    private static func restrictionScheduledResearch() async throws {
        let require = NativeTaskFixture.require
        let saved = NativeChatRulesCounter()
        let scheduler = NativeScheduleTools.definition(searchAvailable: { true }, save: { _ in
            saved.hit()
            throw NativeToolError.failed("unused")
        })
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["research anything"]))) { content in
            let action = SelfTest.restrictionAction(content).lowercased()
            return .text(NativeRequestAuthorizer.refusalCheckReply(action.contains("research") && action.contains("schedule") ? .ruledOut : .notRuledOut))
        }
        let cards = NativeRestrictionCards(approves: true)
        let arguments = "{\"title\":\"Tea\",\"worker_type\":\"research\",\"instruction\":\"Find out about green tea\",\"repeat\":\"daily\",\"time\":\"08:00\"}"
        let (activities, transport) = try await restrictionDrive([scheduler],
            [restrictionRound([restrictionCall("later", NativeScheduleTools.toolName, arguments)]), restrictionDone],
            script: script, text: "Don't research anything, just tell me what you know about green tea.", cards: cards)
        let asked = restrictionAction(script.checkRequests.first?.last?.content ?? "")
        try require(asked.contains("research") && asked.contains("schedule") && !asked.contains("green tea"),
                    "The check sees a plain description that says this schedules research, without the instruction text: \(asked)")
        try require(activities.first?.state == .failed && (activities.first?.result ?? "").contains(NativeRefusalList.ruledOutSentence)
                    && saved.count == 0 && cards.names.isEmpty,
                    "Saying not to research also rules out scheduling research for later, and no card is shown")
        try require((transport.histories.last ?? []).contains { $0.role == "tool" && $0.content.contains(NativeRefusalList.ruledOutSentence) },
                    "The model is told the person asked not to")
    }

    private static func restrictionUnclear() async throws {
        let require = NativeTaskFixture.require
        for approves in [false, true] {
            let hits = NativeChatRulesCounter()
            let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["look anything up"]))) { _ in
                .text(NativeRequestAuthorizer.refusalCheckReply(.unclear))
            }
            let cards = NativeRestrictionCards(approves: approves)
            let (activities, _) = try await restrictionDrive([restrictionReader(hits)], [restrictionRound([restrictionCall("read", "read_notes")]), restrictionDone],
                                                             script: script, cards: cards)
            try require(cards.names == ["read_notes"] && activities.first?.confirmationRequired == true, "An unclear answer puts a card on a read")
            try require(hits.count == (approves ? 1 : 0), "The read runs only when the card is approved: \(approves)")
        }
    }

    private static func restrictionUnavailable() async throws {
        let require = NativeTaskFixture.require
        let replies: [NativeRestrictionScript.Reply] = [.failure, .toolCall, .text("{\"refusals\": \"none\"}"), .text("Nothing, thanks."), .silence]
        for reply in replies {
            let hits = NativeChatRulesCounter()
            let script = NativeRestrictionScript(reply)
            let cards = NativeRestrictionCards(approves: false)
            let failures = NativeChatRulesCounter()
            let (activities, _) = try await restrictionDrive([restrictionReader(hits), restrictionReader(hits, name: "read_more")],
                [restrictionRound([restrictionCall("one", "read_notes"), restrictionCall("two", "read_more")]), restrictionDone],
                script: script, deadline: .milliseconds(200), cards: cards,
                observe: { source in if case .failed = source { failures.hit() } })
            try require(cards.names == ["read_notes", "read_more"] && hits.count == 0 && activities.allSatisfy { $0.confirmationRequired },
                        "When the first question can't be answered, every call asks first and nothing runs: \(reply)")
            try require(script.calls == 1 && script.checkCalls == 0 && failures.count == 1, "The question is tried once and reported as failed: \(reply)")
        }
        let hits = NativeChatRulesCounter()
        let failures = NativeChatRulesCounter()
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["use any tools"]))) { _ in .failure }
        let cards = NativeRestrictionCards(approves: false)
        _ = try await restrictionDrive([restrictionReader(hits), restrictionReader(hits, name: "read_more")],
            [restrictionRound([restrictionCall("one", "read_notes"), restrictionCall("two", "read_more")]), restrictionDone],
            script: script, cards: cards, observe: { source in if case .failed = source { failures.hit() } })
        try require(cards.names == ["read_notes", "read_more"] && hits.count == 0 && script.checkCalls == 1 && failures.count == 1,
                    "When the per call question can't be answered, that call and every later one in the reply ask first, without asking again")
    }

    private static func restrictionOncePerMessage() async throws {
        let require = NativeTaskFixture.require
        let hits = NativeChatRulesCounter()
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.noRestrictions))
        let cache = NativeRequestRestrictionCache()
        let message = UUID()
        let rounds = [restrictionRound([restrictionCall("a", "read_notes"), restrictionCall("b", "read_notes")]),
                      restrictionRound([restrictionCall("c", "read_notes")]), restrictionRound([restrictionCall("d", "read_notes")]), restrictionDone]
        _ = try await restrictionDrive([restrictionReader(hits)], rounds, script: script, message: message, cache: cache)
        try require(hits.count == 4 && script.calls == 1, "One question covers every call in every round of a message: \(script.calls)")
        _ = try await restrictionDrive([restrictionReader(hits)], rounds, script: script, message: message, cache: cache)
        try require(hits.count == 8 && script.calls == 1, "The same message is not asked about again")
        _ = try await restrictionDrive([restrictionReader(hits)], rounds, script: script, message: UUID(), cache: cache)
        try require(script.calls == 2, "A new message is asked about once")

        let listed = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["write anything"]))) { _ in
            .text(NativeRequestAuthorizer.refusalCheckReply(.notRuledOut))
        }
        let listedCache = NativeRequestRestrictionCache()
        let listedMessage = UUID()
        _ = try await restrictionDrive([restrictionReader(hits)], rounds, script: listed, message: listedMessage, cache: listedCache)
        _ = try await restrictionDrive([restrictionReader(hits)], rounds, script: listed, message: listedMessage, cache: listedCache)
        try require(listed.calls == 1 && listed.checkCalls == 8, "An allowance is never kept, so every call in every attempt is asked about: \(listed.checkCalls)")
        _ = try await restrictionDrive([restrictionReader(hits)], rounds, script: listed, message: UUID(), cache: listedCache)
        try require(listed.calls == 2 && listed.checkCalls == 12, "A new message asks about its calls again")

        let barred = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["read notes"])))
        let barredCache = NativeRequestRestrictionCache()
        let barredMessage = UUID()
        let barredHits = NativeChatRulesCounter()
        _ = try await restrictionDrive([restrictionReader(barredHits)], rounds, script: barred, message: barredMessage, cache: barredCache)
        _ = try await restrictionDrive([restrictionReader(barredHits)], rounds, script: barred, message: barredMessage, cache: barredCache)
        try require(barredHits.count == 0 && barred.calls == 1 && barred.checkCalls == 1, "A ruled out call is kept for the message and asked about once: \(barred.checkCalls)")

        let quiet = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["use any tools"])))
        let (activities, _) = try await restrictionDrive([restrictionReader(hits)], [restrictionDone], script: quiet)
        try require(quiet.calls == 0 && activities.isEmpty, "A reply with no tool calls asks nothing")
        let failing = NativeRestrictionScript(.failure)
        _ = try await restrictionDrive([restrictionReader(hits)], rounds, script: failing, message: message, cache: NativeRequestRestrictionCache())
        try require(failing.calls == 1, "A question that failed is not repeated within the reply")
    }

    private static func restrictionOrder() async throws {
        let require = NativeTaskFixture.require
        let hits = NativeChatRulesCounter()
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["use any tools after reading notes once"]))) { content in
            .text(NativeRequestAuthorizer.refusalCheckReply(content.contains(NativeRequestAuthorizer.ranLabel + "\n" + NativeRequestAuthorizer.noneRun) ? .notRuledOut : .ruledOut))
        }
        let (activities, _) = try await restrictionDrive([restrictionReader(hits)],
            [restrictionRound([restrictionCall("first", "read_notes")]), restrictionRound([restrictionCall("second", "read_notes")]), restrictionDone],
            script: script)
        func activity(_ id: String) -> NativeToolActivity? { activities.first { $0.id == id } }
        try require(hits.count == 1 && activity("first")?.state == .succeeded && activity("second")?.state == .failed
                    && (activity("second")?.result ?? "").contains(NativeRefusalList.ruledOutSentence) && script.checkCalls == 2,
                    "A limit on how many times or in what order is kept: the same call in a later round is asked again and doesn't inherit the first answer")
    }

    private static func restrictionResolvedTarget() async throws {
        let require = NativeTaskFixture.require
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("restriction-target-" + UUID().uuidString, isDirectory: true)
        let open = root.appendingPathComponent("Open", isDirectory: true)
        let kept = root.appendingPathComponent("Kept", isDirectory: true)
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("open".utf8).write(to: open.appendingPathComponent("notes.md"))
        try Data("kept".utf8).write(to: kept.appendingPathComponent("notes.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = NativeRestrictionGrants([FolderGrant(path: open.path)])
        let tools = NativeFolderTools.definitions(grants: { shared.value }, ledger: NativeFileChangeLedger())
        guard let read = tools.first(where: { $0.name == NativeFolderTools.readName }) else { throw NativeTaskFixture.Failure.assertion("read tool") }
        let arguments: [String: NativeJSONValue] = ["path": .string("notes.md")]
        let before = NativeProposedCall(read, arguments: arguments).description
        let message = UUID()
        let cache = NativeRequestRestrictionCache()
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["read anything in Kept"]))) { content in
            .text(NativeRequestAuthorizer.refusalCheckReply(SelfTest.restrictionAction(content).contains(kept.path) ? .ruledOut : .notRuledOut))
        }
        let authorizer = NativeRequestAuthorizer(transport: script.transport, deadline: .seconds(2))
        let check = NativeRestrictionCheck(authorizer: authorizer, messageID: message, text: restrictionText, cache: cache)
        let list = try await check.refusals()
        let first = try await check.outcome(NativeProposedCall(read, arguments: arguments), refusals: list)
        shared.set([FolderGrant(path: kept.path)])
        let after = NativeProposedCall(read, arguments: arguments).description
        let second = try await check.outcome(NativeProposedCall(read, arguments: arguments), refusals: list)
        try require(before.contains(open.path) && after.contains(kept.path) && !after.contains(open.path),
                    "A relative path is described by the folder it resolves to: \(before) | \(after)")
        try require(first == .allowed && second == .ruledOut && script.checkCalls == 2,
                    "When the shared folder changes, the same arguments are asked about again by where they now point")
    }

    private static func restrictionNeverRan() async throws {
        let require = NativeTaskFixture.require
        let hits = NativeChatRulesCounter()
        let failing = NativeToolDefinition(id: "fixture-check", name: "check_first", title: "Check the build", description: "Fixture",
                                           parameters: .object(["type": .string("object")]), confirmation: .none, timeout: .seconds(5), effect: .read,
                                           isAvailable: { true }, execute: { _ in throw NativeToolError.failed("Refused by a rule.") })
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["read notes before checking the build"]))) { content in
            .text(NativeRequestAuthorizer.refusalCheckReply(SelfTest.restrictionAction(content).contains("Read the notes")
                && content.contains(NativeRequestAuthorizer.ranLabel + "\n" + NativeRequestAuthorizer.noneRun) ? .ruledOut : .notRuledOut))
        }
        let (activities, _) = try await restrictionDrive([failing, restrictionReader(hits)],
            [restrictionRound([restrictionCall("check", "check_first")]), restrictionRound([restrictionCall("read", "read_notes")]), restrictionDone],
            script: script)
        let last = script.checkRequests.last?.last?.content ?? ""
        try require(activities.first { $0.id == "check" }?.state == .failed && hits.count == 0
                    && last.contains(NativeRequestAuthorizer.ranLabel + "\n" + NativeRequestAuthorizer.noneRun),
                    "A call that failed without running is never listed as already run, so a later call waiting on it stays refused: \(last)")

        let declining = NativeToolDefinition(id: "fixture-start", name: "start_plan", title: "Start the plan", description: "Fixture",
                                             parameters: .object(["type": .string("object")]), confirmation: .none, timeout: .seconds(5), effect: .read,
                                             isAvailable: { true }, execute: { _ in .object(["message": .string("Not started."), "started": .bool(false)]) })
        let waiting = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["read notes before the plan starts"]))) { content in
            .text(NativeRequestAuthorizer.refusalCheckReply(SelfTest.restrictionAction(content).contains("Read the notes")
                && content.contains(NativeRequestAuthorizer.ranLabel + "\n" + NativeRequestAuthorizer.noneRun) ? .ruledOut : .notRuledOut))
        }
        let (declined, _) = try await restrictionDrive([declining, restrictionReader(hits)],
            [restrictionRound([restrictionCall("start", "start_plan")]), restrictionRound([restrictionCall("read", "read_notes")]), restrictionDone],
            script: waiting)
        try require(declined.first { $0.id == "start" }?.state == .succeeded && hits.count == 0
                    && (waiting.checkRequests.last?.last?.content ?? "").contains(NativeRequestAuthorizer.ranLabel + "\n" + NativeRequestAuthorizer.noneRun),
                    "A call that answers that it didn't start is never listed as already run")
    }

    private static func restrictionTargetMoves() async throws {
        let require = NativeTaskFixture.require
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("restriction-moves-" + UUID().uuidString, isDirectory: true)
        let open = root.appendingPathComponent("Open", isDirectory: true)
        let kept = root.appendingPathComponent("Kept", isDirectory: true)
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("open".utf8).write(to: open.appendingPathComponent("notes.md"))
        try Data("KEPT-CONTENT".utf8).write(to: kept.appendingPathComponent("notes.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = NativeRestrictionGrants([FolderGrant(path: open.path)])
        let tools = NativeFolderTools.definitions(grants: { shared.value }, ledger: NativeFileChangeLedger())
        guard let read = tools.first(where: { $0.name == NativeFolderTools.readName }) else { throw NativeTaskFixture.Failure.assertion("read tool") }
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["read anything in Kept"]))) { content in
            shared.set([FolderGrant(path: kept.path)])
            return .text(NativeRequestAuthorizer.refusalCheckReply(SelfTest.restrictionAction(content).contains(kept.path) ? .ruledOut : .notRuledOut))
        }
        let cards = NativeRestrictionCards(approves: false)
        let (activities, transport) = try await restrictionDrive([read],
            [restrictionRound([restrictionCall("read", NativeFolderTools.readName, "{\"path\":\"notes.md\"}")]), restrictionDone],
            script: script, cards: cards)
        let told = (transport.histories.last ?? []).map(\.content).joined()
        try require(activities.first?.state != .succeeded && cards.names == [NativeFolderTools.readName] && !told.contains("KEPT-CONTENT"),
                    "When the shared folder changes while the question is out, the answer doesn't carry over: the call asks first and nothing is read")

        shared.set([FolderGrant(path: open.path)])
        let calm = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["read anything in Kept"]))) { content in
            .text(NativeRequestAuthorizer.refusalCheckReply(SelfTest.restrictionAction(content).contains(kept.path) ? .ruledOut : .notRuledOut))
        }
        let authorizer = NativeRequestAuthorizer(transport: calm.transport, deadline: .seconds(2))
        let check = NativeRestrictionCheck(authorizer: authorizer, messageID: UUID(), text: restrictionText, cache: NativeRequestRestrictionCache())
        let dispatching = ScriptedNativeToolTransport(rounds: [restrictionRound([restrictionCall("late", NativeFolderTools.readName, "{\"path\":\"notes.md\"}")]), restrictionDone])
        let loop = NativeToolLoop(transport: dispatching, registry: NativeToolRegistry(definitions: [read]),
                                  willExecute: { _ in shared.set([FolderGrant(path: kept.path)]); return true },
                                  confirm: { _ in false }, authorizer: authorizer, restrictions: check)
        var final: NativeToolTurnSnapshot?
        for try await snapshot in loop.stream(messages: [NativeChatMessage(role: "user", content: restrictionText)], model: "local-model",
                                              enabledToolIDs: [read.id]) {
            final = snapshot
        }
        let late = final?.activities.first
        let lateTold = (dispatching.histories.last ?? []).map(\.content).joined()
        try require(late?.state == .failed && (late?.result ?? "").contains(NativeRefusalList.targetMovedSentence) && !lateTold.contains("KEPT-CONTENT"),
                    "When the shared folder changes while the call is being dispatched, it doesn't run and the model is told why")
    }

    private static func restrictionRetry() async throws {
        let require = NativeTaskFixture.require
        let hits = NativeChatRulesCounter()
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["read notes more than once"]))) { content in
            .text(NativeRequestAuthorizer.refusalCheckReply(content.contains(NativeRequestAuthorizer.ranLabel + "\n" + NativeRequestAuthorizer.noneRun) ? .notRuledOut : .ruledOut))
        }
        let cache = NativeRequestRestrictionCache()
        let message = UUID()
        let rounds = [restrictionRound([restrictionCall("read", "read_notes")]), restrictionDone]
        _ = try await restrictionDrive([restrictionReader(hits)], rounds, script: script, message: message, cache: cache)
        let (again, _) = try await restrictionDrive([restrictionReader(hits)], rounds, script: script, message: message, cache: cache, earlierAttempt: true)
        try require(hits.count == 1 && again.first?.state == .failed && (again.first?.result ?? "").contains(NativeRefusalList.ruledOutSentence),
                    "Trying the same message again keeps what already ran, so a limit on how many times holds across attempts")
        let cards = NativeRestrictionCards(approves: false)
        let fresh = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["read notes more than once"])))
        let (lost, _) = try await restrictionDrive([restrictionReader(hits)], rounds, script: fresh, cache: NativeRequestRestrictionCache(),
                                                   cards: cards, earlierAttempt: true)
        try require(hits.count == 1 && cards.names == ["read_notes"] && lost.first?.confirmationRequired == true && fresh.checkCalls == 0,
                    "When an earlier attempt ran something and what it ran is no longer known, every call asks first")
        let quiet = NativeRestrictionScript(.text(NativeRequestAuthorizer.noRestrictions))
        _ = try await restrictionDrive([restrictionReader(hits)], rounds, script: quiet, cache: NativeRequestRestrictionCache(), earlierAttempt: true)
        try require(hits.count == 2, "A message with nothing refused carries on as usual on a later attempt")

        let partial = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["read notes more than twice"])))
        let partialCache = NativeRequestRestrictionCache()
        let partialMessage = UUID()
        let approving = NativeRestrictionCards(approves: true)
        _ = try await restrictionDrive([restrictionReader(hits)], rounds, script: partial, message: partialMessage, cache: partialCache,
                                       cards: approving, earlierAttempt: true)
        let declining = NativeRestrictionCards(approves: false)
        _ = try await restrictionDrive([restrictionReader(hits)], rounds, script: partial, message: partialMessage, cache: partialCache,
                                       cards: declining, earlierAttempt: true)
        try require(hits.count == 3 && approving.names == ["read_notes"] && declining.names == ["read_notes"] && partial.checkCalls == 0,
                    "Once what ran is lost, it stays lost for that message: a call approved after a relaunch doesn't make the next try look complete")
    }

    private static func restrictionPromptShape() async throws {
        let require = NativeTaskFixture.require
        let hits = NativeChatRulesCounter()
        let refusals = ["use tools after this one"]
        let script = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(refusals))) { _ in
            .text(NativeRequestAuthorizer.refusalCheckReply(.notRuledOut))
        }
        let text = "Read \"my notes\" and don't use tools after this one."
        let history = [NativeChatMessage(role: "system", content: "SYSTEM-PROMPT-TEXT"),
                       NativeChatMessage(role: "user", content: "EARLIER-MESSAGE-TEXT"),
                       NativeChatMessage(role: "assistant", content: "EARLIER-REPLY-TEXT"),
                       NativeChatMessage(role: "user", content: text + " ATTACHMENT-TEXT")]
        _ = try await restrictionDrive([restrictionReader(hits)], [restrictionRound([restrictionCall("a", "read_notes")]),
                                                                   restrictionRound([restrictionCall("b", "read_notes")]), restrictionDone],
                                       script: script, text: text, history: history)
        let asked = script.requests.first ?? []
        try require(asked.count == 2 && asked[0].role == "system" && asked[0].content == NativeRequestAuthorizer.restrictionPrompt
                    && asked[1].role == "user" && asked[1].content == NativeRequestAuthorizer.messageLabel + "\n" + NativeActionDescription.literal(text),
                    "The first question receives the fixed prompt and the message text, nothing else: \(asked.map(\.content))")
        let checked = script.checkRequests.first ?? []
        let action = NativeActionDescription.describe(restrictionReader(hits), arguments: [:])
        try require(checked.count == 2 && checked[0].role == "system" && checked[0].content == NativeRequestAuthorizer.refusalCheckPrompt
                    && checked[1].role == "user" && checked[1].content == NativeRequestAuthorizer.refusalCheckContent(text, refusals: refusals, action: action)
                    && checked[1].content == NativeRequestAuthorizer.messageLabel + "\n" + NativeActionDescription.literal(text) + "\n\n"
                        + NativeRequestAuthorizer.refusalsLabel + "\n[\"use tools after this one\"]\n\n"
                        + NativeRequestAuthorizer.ranLabel + "\n" + NativeRequestAuthorizer.noneRun + "\n\n" + NativeRequestAuthorizer.actionLabel + "\n" + action,
                    "The per call question receives the message as a JSON string, the list as a JSON array, what has run so far and the app's description: \(checked.map(\.content))")
        let second = script.checkRequests.dropFirst().first?.last?.content ?? ""
        try require(script.checkCalls == 2 && second == NativeRequestAuthorizer.refusalCheckContent(text, refusals: refusals, action: action, ran: [action])
                    && second.contains(NativeRequestAuthorizer.ranLabel + "\n1. " + action + "\n\n"),
                    "The second call's question lists the first call as already run: \(second)")
        let joined = (asked + checked).map(\.content).joined()
        try require(["SYSTEM-PROMPT-TEXT", "EARLIER-MESSAGE-TEXT", "EARLIER-REPLY-TEXT", "ATTACHMENT-TEXT", "Water the beans", "read_notes"].allSatisfy { !joined.contains($0) },
                    "No history, attachment, tool name or tool result reaches either question")
    }

    private static func restrictionCancellation() async throws {
        let require = NativeTaskFixture.require
        let script = NativeRestrictionScript(.silence)
        let authorizer = NativeRequestAuthorizer(transport: script.transport, deadline: .seconds(20))
        let pending = Task { try await authorizer.refusals("Do not use tools.") }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        var cancelled = false
        do { _ = try await pending.value } catch is CancellationError { cancelled = true }
        try require(cancelled, "Stopping during the first question stops, rather than turning into an answer")
        for loopScript in [NativeRestrictionScript(.silence),
                           NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["use any tools"]))) { _ in .silence }] {
            let hits = NativeChatRulesCounter()
            let running = Task {
                try await restrictionDrive([restrictionReader(hits)], [restrictionRound([restrictionCall("a", "read_notes")]), restrictionDone],
                                           script: loopScript, deadline: .seconds(20), cards: NativeRestrictionCards(approves: true))
            }
            try await Task.sleep(for: .milliseconds(50))
            running.cancel()
            _ = try? await running.value
            try await Task.sleep(for: .milliseconds(200))
            try require(hits.count == 0, "Stopping the reply during either question runs nothing")
        }
    }

    private static func restrictionNotice() async throws {
        let require = NativeTaskFixture.require
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil)
        let observe: NativeRequestAuthorizer.Observer = { source in await store.notePermissionCheck(source) }
        let hits = NativeChatRulesCounter()
        let failing = NativeRestrictionScript(.failure)
        for attempt in 1...3 {
            _ = try await restrictionDrive([restrictionReader(hits)], [restrictionRound([restrictionCall("a", "read_notes")]), restrictionDone],
                                           script: failing, observe: observe)
            try require((store.permissionQuestionsNotice != nil) == (attempt == 3), "The notice appears only after three failed questions in a row: \(attempt)")
        }
        try require(store.permissionQuestionsNotice == RulesCopy.permissionQuestionsFailing, "The notice is the fixed sentence")
        try require(RulesCopy.permissionQuestionsFailing == "Your model hasn't been able to answer the permission questions, so you've been asked before every action. Check the model in Settings, Model.",
                    "The notice says what happened and where to look")
        let working = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["use any tools"])))
        _ = try await restrictionDrive([restrictionReader(hits)], [restrictionRound([restrictionCall("a", "read_notes")]), restrictionDone],
                                       script: working, observe: observe)
        try require(store.permissionQuestionsNotice == nil && store.permissionCheckFailures == 0, "Any answer from the model clears it")
        let perCallDown = NativeRestrictionScript(.text(NativeRequestAuthorizer.refusalsReply(["use any tools"]))) { _ in .failure }
        _ = try await restrictionDrive([restrictionReader(hits)], [restrictionRound([restrictionCall("a", "read_notes")]), restrictionDone],
                                       script: perCallDown, observe: observe)
        try require(store.permissionCheckFailures == 1, "A per call question that fails counts too")
        store.notePermissionCheck(.failed(.invalidReply))
        store.notePermissionCheck(.failed(.tooLong))
        store.notePermissionCheck(.remembered)
        try require(store.permissionCheckFailures == 2, "A message that is too long and a remembered answer neither count nor clear")
        store.notePermissionCheck(.failed(.unavailable))
        try require(store.permissionQuestionsNotice != nil, "Failures of every question add up")
        let deciding = NativeRequestAuthorizer(transport: { _ in "{\"decision\": \"not_authorized\"}" }, observe: observe)
        _ = try await deciding.decide(try authorizationRequest(authorizationTold),
                                      NativeProposedAction(NativeProposedCall(authorizationSender(NativeChatRulesCounter()), arguments: [:]),
                                                           action: .networkSends, signature: "fixture"))
        try require(store.permissionQuestionsNotice == nil, "An answer to the action question clears it too")
        try require(!RulesCopy.permissionQuestionsFailing.contains("\u{2014}") && !RulesCopy.permissionQuestionsFailing.contains("Ver" + "a")
                    && RulesCopy.screenStrings(name: nil).contains(RulesCopy.permissionQuestionsFailing),
                    "The notice is plain copy checked with the rest of the screen")
    }

    private static func restrictionStore() async throws {
        let require = NativeTaskFixture.require
        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
        func make(_ hits: NativeChatRulesCounter, _ transport: ScriptedNativeToolTransport) async throws -> ChatStore {
            let search = NativeToolDefinition(id: NativeWebTools.searchToolID, name: NativeWebTools.searchToolName, title: "Search the web",
                description: "Fixture", parameters: .object(["type": .string("object"), "properties": .object(["query": .object(["type": .string("string")])])]),
                confirmation: .none, timeout: .seconds(5), effect: .read, isAvailable: { true },
                execute: { _ in hits.hit(); return .object(["results": .array([])]) })
            let store = ChatStore(nativeConfig: config, nativeTransport: transport, repository: try LocalChatRepository(inMemory: true),
                                  nativeToolRegistry: NativeToolRegistry(definitions: [search]), nativeSearchAvailable: { true },
                                  artifactPersistenceEnabled: false)
            await store.connect()
            store.newConversation()
            return store
        }
        func settle(_ store: ChatStore) async throws -> Bool {
            var waited = 0
            try await Task.sleep(nanoseconds: 20_000_000)
            while store.generating && waited < 500 {
                if !store.turnConfirmations.isEmpty { return true }
                try await Task.sleep(nanoseconds: 10_000_000); waited += 1
            }
            return !store.turnConfirmations.isEmpty
        }
        let rounds = [restrictionRound([restrictionCall("search", NativeWebTools.searchToolName, "{\"query\":\"tea\"}")]), restrictionDone]
        let typed = "Don't use any tools for this. @Search the web tea"

        let refusedHits = NativeChatRulesCounter()
        let refusing = ScriptedNativeToolTransport(rounds: rounds)
        refusing.answerRestrictions(NativeRequestAuthorizer.refusalsReply(["use any tools"]))
        let refusingStore = try await make(refusedHits, refusing)
        try require(refusingStore.turnToolIDs(for: typed) == [NativeWebTools.searchToolID], "The mention still offers its tool")
        try require(refusingStore.sendText(typed, fromComposer: true), "The message is accepted")
        let refusedCard = try await settle(refusingStore)
        let told = (refusing.histories.last ?? []).contains { $0.role == "tool" && $0.content.contains(NativeRefusalList.ruledOutSentence) }
        try require(!refusedCard && refusedHits.count == 0 && refusing.restrictionChecks.count == 1 && refusing.refusalChecks.count == 1 && told,
                    "A mention cannot beat a refusal: the mentioned tool does not run and the model is told why")
        try require(refusing.restrictionChecks.first == NativeRequestAuthorizer.messageLabel + "\n" + NativeActionDescription.literal(typed)
                    && restrictionAction(refusing.refusalChecks.first ?? "") == "Search the web",
                    "The store asks about the message as sent, and about the search by its plain description")

        let downHits = NativeChatRulesCounter()
        let down = ScriptedNativeToolTransport(rounds: rounds)
        down.answerRestrictions("I can't tell.")
        let downStore = try await make(downHits, down)
        try require(downStore.sendText("@Search the web tea", fromComposer: true), "The message is accepted")
        let downCard = try await settle(downStore)
        try require(downCard && downHits.count == 0 && downStore.permissionCheckFailures == 1,
                    "When the question can't be answered, a read waits on a card and the failure is counted")
        if let (messageID, card) = downStore.turnConfirmations.first.map({ ($0.key, $0.value) }) {
            downStore.resolveTurnConfirmation(messageID, decision: .decline, requestID: card.id, token: downStore.turnConfirmationTokens[messageID])
        }
        _ = try await settle(downStore)
        try require(downHits.count == 0, "Declining the card runs nothing")

        let untypedHits = NativeChatRulesCounter()
        let untyped = ScriptedNativeToolTransport(rounds: rounds)
        untyped.answerRestrictions(NativeRequestAuthorizer.refusalsReply(["use any tools"]))
        let untypedStore = try await make(untypedHits, untyped)
        try require(untypedStore.sendText("@Search the web tea", fromComposer: false), "A message sent by the app is accepted")
        _ = try await settle(untypedStore)
        try require(untyped.restrictionChecks.isEmpty && untyped.refusalChecks.isEmpty,
                    "Text the person didn't type in the composer is never put to the refusal questions")
    }

    private static func restrictionSystemAccess() async throws {
        let require = NativeTaskFixture.require
        func make(_ service: NativeToolAccessFixtureService, _ transport: ScriptedNativeToolTransport) throws -> ChatStore {
            let store = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: transport,
                repository: try LocalChatRepository(inMemory: true), nativeEnabledToolIDs: [NativeRemindersTools.toolID],
                nativeToolRegistry: NativeToolRegistry(definitions: NativeRemindersTools.definitions(service: service)),
                artifactPersistenceEnabled: false)
            store.asksForSystemAccess = true
            store.newConversation()
            return store
        }
        func send(_ store: ChatStore, _ text: String) async throws {
            try require(store.sendText(text, fromComposer: true), "The message is accepted")
            try await NativeSessionFixture.eventually("The reply completes") {
                store.selected?.messages.last?.role == .assistant && store.selected?.messages.last?.state == .complete
            }
        }
        func rounds(_ ids: [String]) -> [[NativeChatStreamSnapshot]] {
            ids.flatMap { [restrictionRound([restrictionCall($0, "apple_reminders_list")]), restrictionDone] }
        }

        let refused = NativeToolAccessFixtureService(.notDetermined, grants: true)
        let refusing = ScriptedNativeToolTransport(rounds: rounds(["ruled-out"]))
        refusing.answerRestrictions(NativeRequestAuthorizer.refusalsReply(["look at my reminders"]))
        let refusingStore = try make(refused, refusing)
        try await send(refusingStore, "Don't look at my reminders, just say hello.")
        try require(refused.requests == 0 && refusing.refusalChecks.count == 1
                    && restrictionAction(refusing.refusalChecks.first ?? "") == "Read reminders from every list",
                    "A message that rules out the Reminders call never makes macOS ask for access")
        try require((refusing.histories.last ?? []).contains { $0.role == "tool" && $0.content.contains(NativeRefusalList.ruledOutSentence) },
                    "The ruled out call is answered with the fixed sentence")

        let normal = NativeToolAccessFixtureService(.notDetermined, grants: true)
        let plain = ScriptedNativeToolTransport(rounds: rounds(["first", "second"]))
        let plainStore = try make(normal, plain)
        try require(normal.requests == 0, "Nothing is asked before a message is sent")
        try await send(plainStore, "What's on my reminders?")
        try require(normal.requests == 1, "The first Reminders call asks macOS once, just before it runs")
        try await send(plainStore, "And what about now?")
        try require(normal.requests == 1, "A later call doesn't ask again")
    }
}

final class NativeRestrictionGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [FolderGrant]

    init(_ grants: [FolderGrant]) { self.grants = grants }

    var value: [FolderGrant] { lock.withLock { grants } }
    func set(_ next: [FolderGrant]) { lock.withLock { grants = next } }
}
