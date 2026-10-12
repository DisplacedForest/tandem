import Foundation

enum NativeBoundedToolFixture {
    enum Failure: Error { case assertion(String) }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    static func call(_ id: String, _ name: String = "web_search", query: String = "fixture") -> NativeChatToolCall {
        NativeChatToolCall(id: id, name: name, arguments: "{\"query\":\"\(query)\"}")
    }

    static func round(_ calls: [NativeChatToolCall], content: String = "") -> NativeChatStreamSnapshot {
        NativeChatStreamSnapshot(content: content, toolCalls: calls, finishReason: calls.isEmpty ? "stop" : "tool_calls")
    }

    static func definition(_ ledger: NativeBoundedToolLedger, name: String = "web_search",
                           confirmation: NativeToolConfirmation = .none, delay: Duration? = nil,
                           result: NativeJSONValue? = nil) -> NativeToolDefinition {
        NativeToolDefinition(id: name == "web_search" ? NativeWebTools.searchToolID : name == "deep_research" ? NativeWebTools.researchToolID : "fixture-action",
            name: name, title: "Fixture operation", description: "Synthetic fixture", parameters: .object([
                "type": .string("object"), "properties": .object(["query": .object(["type": .string("string")])]),
                "required": .array([.string("query")]), "additionalProperties": .bool(false)]), confirmation: confirmation,
            isAvailable: { true }, execute: { arguments in
                await ledger.start(arguments)
                if let delay { await Task.detached { try? await Task.sleep(for: delay) }.value }
                await ledger.finish()
                return result ?? .object(["results": .array([.object([
                    "title": .string("Fixture ![image](https://image.test/pixel)"),
                    "url": .string("https://source.test/fact"),
                    "content": .string("The fictional moon is blue. <script>ignored</script> ![remote](https://image.test/pixel)")]),
                    .object(["title": .string("Invalid"), "url": .string("https://user:secret@source.test/private")])])])
            })
    }

    static func collect(_ loop: NativeToolLoop, enabled: Set<String> = [NativeWebTools.searchToolID, NativeWebTools.researchToolID, "fixture-action"]) async throws -> NativeToolTurnSnapshot {
        var last = NativeToolTurnSnapshot(content: "", activities: [])
        for try await snapshot in loop.stream(messages: [NativeChatMessage(role: "user", content: "Synthetic question")],
                                               model: "fixture", enabledToolIDs: enabled) {
            try Task.checkCancellation()
            last = snapshot
        }
        try Task.checkCancellation()
        return last
    }

    static func run() async throws {
        let searches = NativeBoundedToolLedger()
        let transport = NativeBoundedToolTransport([
            .value(round([call("one", query: "different one"), call("two", query: "different two"), call("three", query: "different three")], content: "I found some leads.")),
            .value(round([call("four")], content: "Unsupported fabricated result")),
        ])
        let final = try await collect(NativeToolLoop(transport: transport, registry: NativeToolRegistry(definitions: [definition(searches)])))
        let searchCount = await searches.started
        try require(searchCount == 2 && transport.schemas.count == 2 && transport.schemas[1].isEmpty,
                    "Distinct lookups stop after two and synthesize once without tools")
        try require(final.isPartial && final.content.contains("I found some leads.") && final.content.contains("partial source excerpts"),
                    "Fallback preserves partial model content and identifies uncertainty")
        try require(final.content.contains("https://source.test/fact") && !final.content.contains("![")
            && !final.content.contains("<script>") && !final.content.contains("user:secret")
            && !final.content.contains("Unsupported fabricated result"), "Fallback escapes untrusted evidence and rejects tool-calling synthesis")
        try require(final.activities.filter { $0.state == .succeeded }.count == 2 && final.activities.last?.state == .failed,
                    "Unexecuted calls cannot appear successful")

        let reusedSearches = NativeBoundedToolLedger()
        let repeatedSearches = NativeBoundedToolTransport([
            .value(round([call("repeat-one"), NativeChatToolCall(id: "repeat-two", name: "web_search", arguments: "{ \"query\": \"\\u0066ixture\" }")])),
            .value(round([call("repeat-three")])), .value(round([], content: "The source result is available.")),
        ])
        _ = try await collect(NativeToolLoop(transport: repeatedSearches,
            registry: NativeToolRegistry(definitions: [definition(reusedSearches)])))
        let reusedCount = await reusedSearches.started
        try require(reusedCount == 1 && repeatedSearches.schemas.count == 3 && !repeatedSearches.schemas[2].isEmpty,
                    "Successful exact searches reuse validated arguments across rounds without spending lookup budget")
        let failedSearches = NativeBoundedToolLedger()
        let retrySearches = NativeBoundedToolTransport([.value(round([call("error-one"), call("error-two")])), .value(round([], content: "Search is unavailable."))])
        _ = try await collect(NativeToolLoop(transport: retrySearches, registry: NativeToolRegistry(definitions: [
            definition(failedSearches, result: .object(["error": .string("Unavailable")]))])))
        let failedSearchCount = await failedSearches.started
        try require(failedSearchCount == 2, "Failed searches are never cached")
        let reusedIDs = NativeBoundedToolLedger()
        let confirmations = NativeBoundedToolLedger()
        let reusedTransport = NativeBoundedToolTransport([
            .value(round([call("same-id")])), .value(round([call("same-id", "action", query: "mutation")])),
            .value(round([], content: "The action was not performed.")),
        ])
        let reusedFinal = try await collect(NativeToolLoop(transport: reusedTransport, registry: NativeToolRegistry(definitions: [
            definition(reusedIDs), definition(reusedIDs, name: "action", confirmation: .required)]),
            confirm: { _ in await confirmations.start([:]); return true }))
        let idCalls = await reusedIDs.started
        let consentCalls = await confirmations.started
        try require(idCalls == 1 && consentCalls == 0 && reusedFinal.activities.first?.name == "web_search"
            && reusedFinal.activities.first?.state == .succeeded && reusedTransport.schemas.last?.isEmpty == true,
                    "Reused call identity cannot authorize a new action through stale activity")
        let duplicateIDs = NativeBoundedToolLedger()
        let duplicateTransport = NativeBoundedToolTransport([.value(round([call("duplicate", "action"), call("duplicate", "action")])),
            .value(round([], content: "No actions were run."))])
        _ = try await collect(NativeToolLoop(transport: duplicateTransport,
            registry: NativeToolRegistry(definitions: [definition(duplicateIDs, name: "action")])))
        let duplicateCount = await duplicateIDs.started
        try require(duplicateCount == 0, "Ambiguous identities within a batch cannot execute")

        let truncated = NativeBoundedToolTransport([.value(NativeChatStreamSnapshot(content: "Partial text", toolCalls: [], finishReason: "length"))])
        let truncatedFinal = try await collect(NativeToolLoop(transport: truncated, registry: NativeToolRegistry(definitions: [])))
        try require(truncatedFinal.isPartial && truncatedFinal.content == "Partial text", "Truncated normal response remains resumable")

        let interruptedLedger = NativeBoundedToolLedger()
        let interrupted = NativeBoundedToolTransport([.value(round([call("first-search")])), .failure])
        let interruptedFinal = try await collect(NativeToolLoop(transport: interrupted,
            registry: NativeToolRegistry(definitions: [definition(interruptedLedger)])))
        try require(interruptedFinal.isPartial && interruptedFinal.content.contains("https://source.test/fact")
            && interrupted.schemas.count == 2, "Provider failure after one result preserves usable evidence")

        let actions = NativeBoundedToolLedger()
        let actionTransport = NativeBoundedToolTransport([
            .value(round((1...10).map { call("action\($0)", "action") })), .value(round([], content: "The completed actions are available.")),
        ])
        let actionFinal = try await collect(NativeToolLoop(transport: actionTransport,
            registry: NativeToolRegistry(definitions: [definition(actions, name: "action")])))
        let actionCount = await actions.started
        try require(actionCount == 8 && actionTransport.schemas.last?.isEmpty == true && !actionFinal.isPartial,
                    "Eight-call cap retains repeated action semantics and allows one final answer")

        let rounds = NativeBoundedToolLedger()
        let fourRounds = NativeBoundedToolTransport((1...4).map { .value(round([call("round\($0)", "action")])) }
            + [.value(round([call("forbidden", "action")]))])
        let roundFinal = try await collect(NativeToolLoop(transport: fourRounds,
            registry: NativeToolRegistry(definitions: [definition(rounds, name: "action")]), maximumWebSearchCalls: 8))
        let roundCount = await rounds.started
        try require(roundCount == 4 && fourRounds.schemas.count == 5 && fourRounds.schemas.last?.isEmpty == true
            && roundFinal.isPartial && !roundFinal.content.isEmpty, "Four tool rounds have a bounded useful exit")

        let seven = NativeBoundedToolLedger()
        let sevenTransport = NativeBoundedToolTransport([
            .value(round([call("s1", query: "one"), call("s2", query: "two")])),
            .value(round([call("s3", query: "three"), call("s4", query: "four")])),
            .value(round([call("s5", query: "five"), call("s6", query: "six")])),
            .value(round([call("r1", "deep_research")])),
            .value(round([call("s7", query: "seven"), call("s8", query: "eight")])),
        ])
        let sevenFinal = try await collect(NativeToolLoop(transport: sevenTransport, registry: NativeToolRegistry(definitions: [
            definition(seven), definition(seven, name: "deep_research", result: .object(["report": .string(""), "errors": .array([.string("Model unavailable")])]))
        ]), maximumWebSearchCalls: 8))
        let sevenCount = await seven.started
        try require(sevenCount == 7 && sevenFinal.isPartial && !sevenFinal.content.isEmpty
            && sevenTransport.schemas.last?.isEmpty == true, "Seven calls then two further requests cannot end with a blank error")

        let failed = NativeBoundedToolLedger()
        let evidence: NativeJSONValue = .object(["report": .string(""), "errors": .array([.string("Model unavailable")]),
            "sources": .array([.object(["n": .number(1), "title": .string("Evidence"), "url": .string("https://source.test/fact")])])])
        let failedTransport = NativeBoundedToolTransport([.value(round([call("research", "deep_research")])), .value(round([]))])
        let failedFinal = try await collect(NativeToolLoop(transport: failedTransport,
            registry: NativeToolRegistry(definitions: [definition(failed, name: "deep_research", result: evidence)])))
        try require(failedFinal.activities.first?.state == .failed && failedFinal.activities.first?.result?.contains("sources") == true
            && failedFinal.isPartial && failedFinal.content.contains("https://source.test/fact"), "Empty failed research retains source evidence")
        try require(NativeToolLoop.resultFailed(.object(["error": .string("Unavailable")]), toolName: "action"),
                    "Structured tool errors cannot be successful")

        let timeoutLedger = NativeBoundedToolLedger()
        let timeoutTransport = NativeBoundedToolTransport([.value(round([call("slow")])), .value(round([], content: "The lookup did not finish."))])
        let start = ContinuousClock.now
        let timeoutFinal = try await collect(NativeToolLoop(transport: timeoutTransport,
            registry: NativeToolRegistry(definitions: [definition(timeoutLedger, delay: .milliseconds(250))]),
            executionTimeout: .milliseconds(20)))
        try require(start.duration(to: .now) < .milliseconds(180) && timeoutFinal.activities.first?.state == .failed,
                    "Resistant executor cannot hold a timed-out turn")
        for failure in [NativeBoundedToolTransport.Reply.failure, .resistant] {
            let ledger = NativeBoundedToolLedger()
            let synthesis = NativeBoundedToolTransport([.value(round([call("a", query: "first"), call("b", query: "second")])), failure])
            let began = ContinuousClock.now
            let result = try await collect(NativeToolLoop(transport: synthesis,
                registry: NativeToolRegistry(definitions: [definition(ledger)]), synthesisTimeout: .milliseconds(20)))
            try require(result.isPartial && !result.content.isEmpty && synthesis.schemas.count == 2
                && began.duration(to: .now) < .milliseconds(180), "Failed or resistant synthesis has one bounded fallback")
        }
        let revoked = NativeBoundedToolLedger()
        let revokedTransport = NativeBoundedToolTransport([.value(round([call("before-stop", "action"), call("after-stop", "action")]))])
        do {
            _ = try await collect(NativeToolLoop(transport: revokedTransport,
                registry: NativeToolRegistry(definitions: [definition(revoked, name: "action")]),
                authorize: { await revoked.started == 0 }))
            throw Failure.assertion("Revoked ownership must propagate cancellation")
        } catch is CancellationError {}
        let revokedCount = await revoked.started
        try require(revokedCount == 1 && revokedTransport.schemas.count == 1, "Revoked turn cannot start another action")
        let consentGate = NativeBoundedToolAuthorization()
        let consentLedger = NativeBoundedToolLedger()
        let consentTransport = NativeBoundedToolTransport([.value(round([call("consent", "action")]))])
        do {
            _ = try await collect(NativeToolLoop(transport: consentTransport,
                registry: NativeToolRegistry(definitions: [definition(consentLedger, name: "action", confirmation: .required)]),
                authorize: { await consentGate.allowed }, confirm: { _ in await consentGate.revoke(); return true }))
            throw Failure.assertion("Late consent cannot override revoked ownership")
        } catch is CancellationError {}
        let consentCount = await consentLedger.started
        try require(consentCount == 0, "Ownership is checked again after human confirmation")
        let preflightLedger = NativeBoundedToolLedger()
        let preflight = NativeBoundedToolPreflight()
        let preflightTransport = NativeBoundedToolTransport([.value(round([call("persist-first", "action")]))])
        do {
            _ = try await collect(NativeToolLoop(transport: preflightTransport,
                registry: NativeToolRegistry(definitions: [definition(preflightLedger, name: "action")]),
                willExecute: { activity in await preflight.record(activity); return false }))
            throw Failure.assertion("Failed durable preflight must stop dispatch")
        } catch is CancellationError {}
        let preflightCalls = await preflightLedger.started
        let markers = await preflight.activities
        try require(preflightCalls == 0 && markers.count == 1 && markers[0].name == "action"
            && markers[0].request == call("persist-first", "action").arguments && markers[0].state == .pending,
                    "Exact pending activity must pass durable preflight before execution")

        let patientLedger = NativeBoundedToolLedger()
        let patientTransport = NativeBoundedToolTransport([.value(round([call("patient", "action")])), .value(round([], content: "Confirmed action finished."))])
        _ = try await collect(NativeToolLoop(transport: patientTransport,
            registry: NativeToolRegistry(definitions: [definition(patientLedger, name: "action", confirmation: .required)]),
            executionTimeout: .milliseconds(10), confirm: { _ in try? await Task.sleep(for: .milliseconds(30)); return true }))
        let patientCount = await patientLedger.started
        try require(patientCount == 1, "Human confirmation does not inherit the executor deadline")
        try await cancellation(confirmation: false)
        try await cancellation(confirmation: true)
        try await cancellation(confirmation: false, preflight: true)
        print("  bounded tool answers OK (two searches, four rounds, eight calls, partial evidence, bounded synthesis, cancellation)")
    }

    static func cancellation(confirmation: Bool, preflight: Bool = false) async throws {
        let ledger = NativeBoundedToolLedger()
        let confirmations = NativeBoundedToolLedger()
        let transport = NativeBoundedToolTransport([.value(round([call("first", "action"), call("second", "action")]))])
        let loop = NativeToolLoop(transport: transport, registry: NativeToolRegistry(definitions: [
            definition(ledger, name: "action", confirmation: confirmation ? .required : .none, delay: .milliseconds(250))]),
            willExecute: { _ in
                if preflight {
                    await confirmations.start([:])
                    await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
                }
                return true
            }, confirm: { _ in
                await confirmations.start([:])
                await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
                return true
            })
        let consumer = Task { try await collect(loop) }
        for _ in 0..<100 {
            let started = confirmation || preflight ? await confirmations.started : await ledger.started
            if started > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let started = confirmation || preflight ? await confirmations.started : await ledger.started
        try require(started == 1, "Cancellation fixture reached the callback")
        let began = ContinuousClock.now
        consumer.cancel()
        do {
            _ = try await consumer.value
            throw Failure.assertion("Cancellation must not complete the turn normally")
        } catch is CancellationError {}
        try require(began.duration(to: .now) < .milliseconds(150), "Stop returns before resistant callback")
        try await Task.sleep(for: .milliseconds(300))
        let count = await ledger.started
        try require(count == (confirmation || preflight ? 0 : 1) && transport.schemas.count == 1,
                    "No later tool or model call starts after cancellation")
    }
}

actor NativeBoundedToolLedger {
    var started = 0
    var finished = 0
    func start(_ arguments: [String: NativeJSONValue]) { started += 1 }
    func finish() { finished += 1 }
}

final class NativeBoundedToolTransport: NativeChatTransport, @unchecked Sendable {
    enum Reply: Sendable { case value(NativeChatStreamSnapshot), failure, resistant }
    private let lock = NSLock()
    private var replies: [Reply]
    private var captured: [[NativeToolSchema]] = []

    init(_ replies: [Reply]) { self.replies = replies }
    var schemas: [[NativeToolSchema]] { lock.withLock { captured } }
    func discoverModels() async throws -> [String] { ["fixture"] }
    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        let reply: Reply = lock.withLock {
            captured.append(tools)
            return replies.isEmpty ? .failure : replies.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch reply {
                case .value(let value): continuation.yield(value); continuation.finish()
                case .failure: continuation.finish(throwing: NativeToolError.failed("Synthetic model failure"))
                case .resistant:
                    await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
                    continuation.yield(NativeBoundedToolFixture.round([], content: "Late text"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

actor NativeBoundedToolAuthorization {
    var allowed = true
    func revoke() { allowed = false }
}

actor NativeBoundedToolPreflight {
    var activities: [NativeToolActivity] = []
    func record(_ activity: NativeToolActivity) { activities.append(activity) }
}
