import Foundation

enum NativeToolResultBudgetSelftest {
    static func require(_ value: Bool, _ message: String) throws {
        try NativeBoundedToolFixture.require(value, "Tool result budget: " + message)
    }
    static func decode(_ text: String) throws -> NativeJSONValue {
        try .piDecode(JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
    }
    static func bounded(_ value: NativeJSONValue, budget: Int = NativeToolResultBudget.defaultBytes) throws -> NativeJSONValue {
        let text = try NativeToolResultBudget.serialized(value, maximumBytes: budget)
        try require(text.utf8.count <= budget, "serialized bytes exceed budget")
        let result = try decode(text)
        try require(result.pi("truncated") == .bool(true), "missing visible truncation marker")
        try require(result.pi("truncation_reason").piString?.contains("\(budget) bytes") == true, "missing truncation reason")
        return result
    }
    static func run() async throws {
        let cap = NativeToolResultBudget.defaultBytes
        let ordinary: [NativeJSONValue] = [.object(["z": .string("slashes / quotes \" and newline\n"), "a": .bool(true)]),
            .array([.string("café 東京"), .number(12), .null]), .string("plain result"), .number(7), .bool(false), .null]
        for value in ordinary {
            let before = try NativeToolLoop.serializedResult(value)
            let after = try NativeToolResultBudget.serialized(value, maximumBytes: cap)
            try require(before == after && decode(after) == value, "under-budget result changed")
        }
        let overhead = try NativeToolLoop.serializedResult(.object(["report": .string("")])).utf8.count
        let exact: NativeJSONValue = .object(["report": .string(String(repeating: "a", count: cap - overhead))])
        let exactWire = try NativeToolLoop.serializedResult(exact)
        try require(exactWire.utf8.count == cap, "boundary fixture size")
        try require(try NativeToolResultBudget.serialized(exact, maximumBytes: cap) == exactWire, "exact budget changed")
        let over: NativeJSONValue = .object(["report": .string(String(repeating: "a", count: cap - overhead + 1))])
        let shrunk = try bounded(over)
        try require(shrunk.pi("report").piString?.hasPrefix(String(repeating: "a", count: 100)) == true, "marker overhead removed leading text")

        let lead = "Observed result [1]. "
        let sources: NativeJSONValue = .array([.object(["n": .number(1), "url": .string("https://source.example/first"), "title": .string("First source")])])
        let report = lead + String(repeating: "Cited findings [1]. ", count: 10_000)
        let research: NativeJSONValue = .object(["report": .string(report), "sources": sources])
        let researchFit = try bounded(research, budget: NativeToolResultBudget.researchBytes)
        try require(researchFit.pi("report").piString?.hasPrefix(lead) == true && researchFit.pi("sources") == sources, "leading cited report or source lost")
        let longURL = "https://source.example/" + String(repeating: "source", count: 25_000)
        let largeSources: NativeJSONValue = .array((0..<1500).map { .object(["url": .string("https://source.example/\($0)"), "title": .string(String(repeating: "Source title ", count: 20))]) })
        let combined = try bounded(.object(["report": .string(report), "sources": largeSources]), budget: NativeToolResultBudget.researchBytes)
        try require(combined.pi("report").piString?.hasPrefix(lead) == true, "combined report and sources removed leading citation")
        guard let combinedSources = combined.pi("sources").piArray, let originalSources = largeSources.piArray else { throw NativeToolError.failed("Combined sources were lost") }
        try require(!combinedSources.isEmpty && combinedSources == Array(originalSources.prefix(combinedSources.count)), "source identity changed")
        let protected = try bounded(.object(["report": .string(report), "sources": .array([.object(["url": .string(longURL), "id": .string("source-one"), "title": .string("First")])])]), budget: NativeToolResultBudget.researchBytes)
        try require(protected.pi("sources").piArray == nil && protected.pi("text").piString != nil, "oversized URL was shortened into a citation target")
        let researchOverhead = try NativeToolLoop.serializedResult(.object(["report": .string(""), "sources": sources])).utf8.count
        let researchExact: NativeJSONValue = .object(["report": .string(String(repeating: "a", count: NativeToolResultBudget.researchBytes - researchOverhead)), "sources": sources])
        let researchExactWire = try NativeToolLoop.serializedResult(researchExact)
        try require(try NativeToolResultBudget.serialized(researchExact, maximumBytes: NativeToolResultBudget.researchBytes) == researchExactWire, "128 KiB research changed")

        let items: [NativeJSONValue] = (0..<2000).map { .object(["id": .number(Double($0)), "title": .string("Reminder \($0) " + String(repeating: "x", count: 80))]) }
        let list = try bounded(.object(["reminders": .array(items), "list": .string("Fixture")]))
        guard let kept = list.pi("reminders").piArray else { throw NativeToolError.failed("Structured reminders were lost") }
        try require(!kept.isEmpty && kept.count < items.count && kept == Array(items.prefix(kept.count)), "list tail order or leading items changed")
        let rootList = try bounded(.array(items), budget: 1024)
        try require(rootList.pi("result").piArray?.first == items.first, "root list leading item lost")
        let hugeFirst: NativeJSONValue = .object(["items": .array([.object(["text": .string(lead + String(repeating: "x", count: 4000))]), .string("tail")])])
        let nested = try bounded(hugeFirst, budget: 512)
        try require(nested.pi("items").piArray?.first?.pi("text").piString?.hasPrefix(lead) == true, "oversized first list item lost")

        for unit in ["\"\n\\/\u{0001}", "東京🪴é", "e" + String(repeating: "\u{0301}", count: 200)] {
            let text = lead + String(repeating: unit, count: 800)
            for budget in [256, 257, 511, 1024, 4096] {
                let value = try bounded(.object(["text": .string(text)]), budget: budget)
                guard let prefix = value.pi("text").piString else { throw NativeToolError.failed("Text prefix missing") }
                try require(text.utf8.starts(with: prefix.utf8) && !prefix.contains("\u{fffd}"), "UTF-8 or JSON escaping corrupted prefix")
            }
        }
        let awkward: NativeJSONValue = .object([String(repeating: "key", count: 3000): .number(1)])
        let fallback = try bounded(awkward, budget: 256)
        let original = try NativeToolLoop.serializedResult(awkward)
        try require(fallback.pi("text").piString.map { original.hasPrefix($0) && !$0.isEmpty } == true, "fallback is not a leading prefix")
        let collision = try bounded(.object(["truncated": .bool(false), "truncation_reason": .string("stale"), "report": .string(report)]), budget: 512)
        try require(collision.pi("truncation_reason") != .string("stale"), "original metadata masked truncation")
        for budget in [-1, 0, 16] {
            var rejected = false
            do { _ = try NativeToolResultBudget.serialized(.object(["text": .string(report)]), maximumBytes: budget) }
            catch { rejected = true }
            try require(rejected, "impossible budget was silently exceeded")
        }
        for data in [Data("{\"value\":1}".utf8), Data(String(repeating: "a", count: 40_000).utf8), Data(String(repeating: "\"\n", count: 16_000).utf8), Data("{\"items\":\"\(String(repeating: "x", count: 32_000))\"}".utf8)] {
            let value = NativeCapabilityTools.value(from: data)
            let original = try NativeToolLoop.serializedResult(value)
            try require(try NativeToolResultBudget.serialized(value, maximumBytes: cap) == original, "capability serialization changed")
        }
        try await loopCases(research: research, researchExact: researchExact)
        print("  tool result budgets OK (exact serialized bytes, research override, leading structure, UTF-8, escaping, capability parity, model history)")
    }

    static func loopCases(research: NativeJSONValue, researchExact: NativeJSONValue) async throws {
        let searchClient = NativeWebSearchClient { _, _ in
            let value: NativeJSONValue = .object(["results": .array((research.pi("sources").piArray ?? []).map { source in
                .object(["title": source.pi("title"), "url": source.pi("url"), "content": research.pi("report")])
            })])
            return (try NativeToolLoop.serializedResult(value).data(using: .utf8)!, 200)
        }
        let fetchClient = NativePageFetchClient { url, _, _ in
            NativePageResponse(status: 200, contentType: "text/plain", body: Data(String(repeating: "東京の雨 ", count: 4_000).utf8), truncated: false, finalURL: url)
        }
        let web = NativeWebTools.definitions(searchBase: { URL(string: "https://search.example") }, searchClient: searchClient, fetchClient: fetchClient)
        guard let search = web.first(where: { $0.name == "web_search" }), let fetch = web.first(where: { $0.name == "fetch_page" }) else { throw NativeToolError.unavailable }
        try require(search.resultByteBudget == 32_768 && fetch.resultByteBudget == 32_768, "built-in definitions have wrong budgets")
        let text = try await modelResult(search, arguments: "{\"query\":\"fixture\",\"max_results\":10}")
        try require(text.utf8.count <= search.resultByteBudget && decode(text).pi("truncated") == .null
                    && (decode(text).pi("results").piArray ?? []).allSatisfy { ($0.pi("content").piString?.count ?? 0) <= NativeWebSearch.snippetCharacters },
                    "search results exceeded their snippet caps")
        let fetched = try await modelResult(fetch, arguments: "{\"url\":\"https://pages.example/report\",\"max_chars\":20000}")
        try require(fetched.utf8.count <= fetch.resultByteBudget && decode(fetched).pi("truncated") == .bool(true), "model received an unbounded page result")
        let intact = NativeToolDefinition(id: "deep-research", name: "deep_research", title: "Deep research", description: "Fixture",
            parameters: search.parameters, confirmation: .none, resultByteBudget: NativeToolResultBudget.researchBytes, isAvailable: { true }, execute: { _ in researchExact })
        try require(try await modelResult(intact, arguments: "{\"query\":\"fixture\"}") == NativeToolLoop.serializedResult(researchExact), "128 KiB model history changed")
        let scalar = definition(.string("small scalar"))
        try require(try await modelResult(scalar) == NativeToolLoop.serializedResult(.string("small scalar")), "scalar result failed in loop")
        let errorText = "error " + String(repeating: "e" + String(repeating: "\u{0301}", count: 500), count: 300)
        let failure = NativeToolDefinition(id: "fixture", name: "fixture", title: "Fixture", description: "Fixture", parameters: .object(["type": .string("object"), "properties": .object([:])]), confirmation: .none,
            resultByteBudget: 512, isAvailable: { true }, execute: { _ in throw NativeToolError.failed(errorText) })
        let error = try await modelResult(failure)
        try require(error.utf8.count <= 512 && decode(error).pi("truncated") == .bool(true), "error result exceeded budget")
        for count in [500, 501, 40_000] {
            let description = String(repeating: "e", count: count)
            let errorValue = try decode(NativeToolResultBudget.serializedError(description, maximumBytes: NativeToolResultBudget.defaultBytes))
            try require(errorValue.pi("error") == .string(String(description.prefix(500))), "error character boundary changed")
            try require(errorValue.pi("truncated") == (count > 500 ? .bool(true) : .null), "error character shortening was not disclosed")
            if count > 500 {
                try require(errorValue.pi("truncation_reason").piString?.contains("500 characters") == true, "error character reason missing")
            }
        }
        let asciiError = String(repeating: "Failure detail. ", count: 4000)
        let asciiFailure = NativeToolDefinition(id: "fixture", name: "fixture", title: "Fixture", description: "Fixture", parameters: .object(["type": .string("object"), "properties": .object([:])]), confirmation: .none,
            isAvailable: { true }, execute: { _ in throw NativeToolError.failed(asciiError) })
        let asciiResult = try await modelResult(asciiFailure)
        let asciiValue = try decode(asciiResult)
        try require(asciiResult.utf8.count <= NativeToolResultBudget.defaultBytes && asciiValue.pi("truncated") == .bool(true), "ASCII error was silently shortened")
        try require(asciiValue.pi("error").piString?.hasPrefix("Failure detail. ") == true, "leading error detail lost")
        let capability = NativeCapabilityTools.value(from: Data(String(repeating: "\"\n", count: 16_000).utf8))
        try require(try await modelResult(definition(capability)) == NativeToolLoop.serializedResult(capability), "model-facing capability bytes changed")
    }
    static func definition(_ value: NativeJSONValue) -> NativeToolDefinition {
        NativeToolDefinition(id: "fixture", name: "fixture", title: "Fixture", description: "Fixture", parameters: .object(["type": .string("object"), "properties": .object([:])]), confirmation: .none,
            isAvailable: { true }, execute: { _ in value })
    }
    static func modelResult(_ definition: NativeToolDefinition, arguments: String = "{}") async throws -> String {
        let transport = ScriptedNativeToolTransport(rounds: [
            [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: "budget-call", name: definition.name, arguments: arguments)], finishReason: "tool_calls")],
            [NativeChatStreamSnapshot(content: "Fixture answer", toolCalls: [], finishReason: "stop")],
        ])
        var final: NativeToolTurnSnapshot?
        for try await snapshot in NativeToolLoop(transport: transport, registry: NativeToolRegistry(definitions: [definition])).stream(
            messages: [NativeChatMessage(role: "user", content: "Fixture request")], model: "fixture", enabledToolIDs: [definition.id]) { final = snapshot }
        guard let activity = final?.activities.first, let result = activity.result,
              let sent = transport.histories.last?.last(where: { $0.role == "tool" })?.content else { throw NativeToolError.failed("No model-facing result") }
        try require(result == sent, "activity and model result differ")
        return sent
    }
}
