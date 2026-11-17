import Foundation

@MainActor
extension SelfTest {
    private static let repairInputs: NativeJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([.string("packet")]),
        "properties": .object([
            "packet": .object(["type": .string("string"), "minLength": .number(1),
                               "description": .string("The seed packet to find, as written on its label.")]),
            "count": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(99),
                              "description": .string("How many packets are wanted.")]),
            "kind": .object(["type": .string("string"), "enum": .array([.string("seed"), .string("bulb")]),
                             "description": .string("What sort of packet it is.")]),
            "filters": .object(["type": .string("object"), "additionalProperties": .bool(false),
                                "properties": .object(["shelf": .object(["type": .string("string"),
                                                                         "enum": .array([.string("north"), .string("south")])])]),
                                "description": .string("Where to look.")]),
            "items": .object(["type": .string("array"), "maxItems": .number(4),
                              "items": .object(["type": .string("object"), "required": .array([.string("name")]),
                                                "properties": .object(["name": .object(["type": .string("string"), "minLength": .number(1)])])]),
                              "description": .string("Other packets to find alongside it.")]),
            "wait": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(1000),
                             "description": .string("Milliseconds the lookup takes in this fixture.")]),
        ]),
    ])

    private static func repairShelf(_ log: NativeToolExtensionLog, name: String = "shelf_lookup", id: String = "repair-shelf",
                                    timeout: Duration? = .seconds(5),
                                    answer: (@Sendable ([String: NativeJSONValue]) -> NativeJSONValue)? = nil) -> NativeToolDefinition {
        NativeToolDefinition(
            id: id, name: name, title: "Look up a shelf",
            description: "Reads which greenhouse shelf holds a seed packet. When to use: the person asks where a packet is kept.",
            parameters: repairInputs, confirmation: .none, timeout: timeout, effect: .read, isAvailable: { true },
            execute: { arguments in
                log.started(arguments)
                if case .number(let wait)? = arguments["wait"], wait > 0 {
                    try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
                }
                log.ended(arguments)
                if let answer { return answer(arguments) }
                return .object(["echo": .object(arguments), "shelf": .string("B3")])
            })
    }

    private static func repairEcho(_ arguments: [String: NativeJSONValue]) -> NativeJSONValue {
        .object(["echo": .object(arguments), "shelf": .string("B3")])
    }

    private static func repairFields(_ text: String?) -> [String: NativeJSONValue] {
        guard let text, let data = text.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data),
              case .object(let fields)? = try? NativeJSONValue(any: any) else { return [:] }
        return fields
    }

    private static func repairText(_ value: NativeJSONValue?) -> String {
        if case .string(let text)? = value { return text }
        return ""
    }

    private static func repairNames(_ value: NativeJSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { if case .string(let name) = $0 { name } else { nil } }
    }

    private static func repairProblems(_ fields: [String: NativeJSONValue]) -> [NativeSchemaProblem] {
        guard case .array(let items)? = fields["problems"] else { return [] }
        return items.compactMap { item -> NativeSchemaProblem? in
            guard case .object(let entry) = item, case .string(let at)? = entry["at"], case .string(let expected)? = entry["expected"] else { return nil }
            return NativeSchemaProblem(path: at, expected: expected)
        }
    }

    private static func repairResults(_ transport: ScriptedNativeToolTransport) -> [String: String] {
        var found: [String: String] = [:]
        for message in transport.histories.last ?? [] where message.role == "tool" {
            if let id = message.toolCallID { found[id] = message.content }
        }
        return found
    }

    private static func repairLoop(_ registry: NativeToolRegistry, rounds: [[NativeChatStreamSnapshot]], enabled: Set<String>,
                                   timeout: Duration = NativeToolLoop.defaultExecutionTimeout,
                                   effects: NativeChatEffectHook? = nil) async throws -> (NativeToolTurnSnapshot?, ScriptedNativeToolTransport) {
        let transport = ScriptedNativeToolTransport(rounds: rounds)
        let loop = NativeToolLoop(transport: transport, registry: registry, executionTimeout: timeout, effects: effects)
        var final: NativeToolTurnSnapshot?
        for try await snapshot in loop.stream(messages: [NativeChatMessage(role: "user", content: "Where are the seed packets?")],
                                              model: "local-model", enabledToolIDs: enabled) {
            final = snapshot
        }
        return (final, transport)
    }

    private static func repairRound(_ calls: [NativeChatToolCall]) -> [NativeChatStreamSnapshot] {
        [NativeChatStreamSnapshot(content: "", toolCalls: calls, finishReason: "tool_calls")]
    }

    static func runNativeToolRepair() async throws {
        let require = NativeTaskFixture.require
        let summary = [
            try repairCounting(),
            try repairActivityRow(),
            try await repairArguments(),
            try await repairCorrection(),
            try await repairFragments(),
            try await repairCancel(),
            try await repairUncertainWrite(),
            try await repairReturned(),
            try await repairRequestShape(),
            try await repairHandedOff(),
        ]
        try require(summary.allSatisfy { !$0.isEmpty }, "Every repair check reports what it covered")
        print("  native tool repair OK (\(summary.joined(separator: "; ")))")
    }

    private static func repairCounting() throws -> String {
        let require = NativeTaskFixture.require
        let problem = NativeToolCallProblem(message: NativeToolError.invalidArguments("Missing required field 'packet'").localizedDescription,
                                            fields: ["not_run": .bool(true), "fault": .string(NativeToolCallFault.invalidArguments.rawValue),
                                                     "fix": .string(NativeToolRepair.correct)])
        try require(NativeToolRepairs.maximumRepairs == 2, "Two repairs are allowed for each name")
        var repairs = NativeToolRepairs()
        let first = repairs.answer(problem, key: "shelf_lookup")
        try require(first.fields["repairs_left"] == NativeJSONValue.number(2) && first.fields["closed"] == nil && first.message == problem.message
                    && repairs.counts["shelf_lookup"] == 1 && !repairs.isClosed("shelf_lookup"),
                    "The first failed call has two repairs left: \(first.fields)")
        let second = repairs.answer(problem, key: "shelf_lookup")
        try require(second.fields["repairs_left"] == NativeJSONValue.number(1) && second.fields["closed"] == nil
                    && repairs.counts["shelf_lookup"] == 2 && !repairs.isClosed("shelf_lookup"),
                    "The second failed call has one repair left: \(second.fields)")
        let third = repairs.answer(problem, key: "shelf_lookup")
        try require(third.fields["closed"] == NativeJSONValue.bool(true) && third.fields["repairs_left"] == NativeJSONValue.number(0)
                    && third.fields["fix"] == NativeJSONValue.string(NativeToolRepair.stop) && third.fields["not_run"] == NativeJSONValue.bool(true)
                    && third.message == problem.message && repairs.isClosed("shelf_lookup") && repairs.counts["shelf_lookup"] == nil,
                    "The third failed call closes that name: \(third.fields)")
        repairs.settled("shelf_lookup")
        let afterClosing = repairs.answer(problem, key: "shelf_lookup")
        try require(repairs.isClosed("shelf_lookup") && afterClosing.fields["closed"] == NativeJSONValue.bool(true) && afterClosing.fields["repairs_left"] == NativeJSONValue.number(0),
                    "A closed name stays closed even after a valid call")
        _ = repairs.answer(problem, key: "label_shelf")
        try require(repairs.counts["label_shelf"] == 1 && !repairs.isClosed("label_shelf"), "Each name keeps its own count")
        repairs.settled("label_shelf")
        let fresh = repairs.answer(problem, key: "label_shelf")
        try require(repairs.counts["label_shelf"] == 1 && fresh.fields["repairs_left"] == NativeJSONValue.number(2), "A valid call resets the count for its name")
        _ = repairs.answer(problem, key: NativeToolRepairs.unknownKey)
        try require(repairs.counts[NativeToolRepairs.unknownKey] == 1 && repairs.counts["label_shelf"] == 1,
                    "Unknown names share one count kept apart from real names")
        let saved = try JSONDecoder().decode(NativeToolRepairs.self, from: try JSONEncoder().encode(repairs))
        try require(saved == repairs && saved.isClosed("shelf_lookup"), "The counts survive being saved and read back")

        guard let validator = NativeToolSchemaCache.shared.validator(repairInputs) else {
            throw NativeTaskFixture.Failure.assertion("The repair fixture schema compiles")
        }
        let crowded: NativeJSONValue = .object(["count": .string("two"), "kind": .string("tuber"), "colour": .string("red"),
                                                "wait": .number(-1), "filters": .object(["shelf": .string("east")])])
        try require(validator.problems(crowded, limit: 2).count == 2 && validator.problems(crowded).count == 4
                    && validator.problems(crowded, limit: 0).count == 1,
                    "The problems listed are bounded by their limit: \(validator.problems(crowded, limit: 10))")
        try require(validator.problems(crowded).first == NativeSchemaProblem(path: "packet", expected: "is required"),
                    "A missing field is listed first under its own name")
        try require(validator.problems(.object(["packet": .string("Beans")])).isEmpty, "Arguments that fit have no problems")

        let constants = [NativeToolRepair.correct, NativeToolRepair.choose, NativeToolRepair.stop, NativeToolRepair.unconfirmed,
                         NativeToolRepair.repeated, NativeToolRepair.emptyResult, NativeToolRepair.mismatchedResult,
                         NativeToolRepair.refusedTooOften]
        let stems = ["ta" + "sk", "back" + "ground", "work" + "er", "ag" + "ent", "eng" + "ine", "pro" + "vider"]
        for text in constants {
            let lowered = text.lowercased()
            try require(!text.contains("Ve" + "ra") && !stems.contains { lowered.contains($0) } && !text.contains("\u{2014}"),
                        "The repair wording is plain: \(text)")
        }
        return "repairs count two then close each name, a valid call resets an open count, closed stays closed, unknown names share a count, problems are bounded, and the wording is plain"
    }

    private static func repairActivityRow() throws -> String {
        let require = NativeTaskFixture.require
        let unavailable = NativeToolError.unavailable.localizedDescription
        let closedArguments = try NativeToolResultBudget.serialized(NativeToolRepair.closed(key: "shelf_lookup", unknown: unavailable).value,
                                                                    maximumBytes: 20000)
        let closedUnknown = try NativeToolResultBudget.serialized(NativeToolRepair.closed(key: NativeToolRepairs.unknownKey, unknown: unavailable).value,
                                                                  maximumBytes: 20000)
        let offered = try NativeToolResultBudget.serialized(NativeToolRepair.unknown(unavailable, offered: ["shelf_lookup"]).value, maximumBytes: 20000)
        let unsure = try NativeToolResultBudget.serialized(NativeToolRepair.uncertain(NativeToolLoop.timedOutMessage).value, maximumBytes: 20000)
        let again = try NativeToolResultBudget.serialized(NativeToolRepair.repeatedWrite().value, maximumBytes: 20000)
        try require(NativeToolActivityChip.shownResult(closedArguments) == NativeToolActivityChip.incomplete,
                    "A closed call shows the incomplete line: \(NativeToolActivityChip.shownResult(closedArguments))")
        try require(NativeToolActivityChip.shownResult(closedUnknown) == NativeToolActivityChip.unavailable
                    && NativeToolActivityChip.shownResult(offered) == NativeToolActivityChip.unavailable,
                    "An unknown name shows the unavailable line, open or closed")
        try require(NativeToolActivityChip.shownResult(unsure) == NativeToolLoop.timedOutMessage
                    && NativeToolActivityChip.shownResult(again) == NativeToolRepair.repeated,
                    "An unconfirmed write shows only its sentence: \(NativeToolActivityChip.shownResult(unsure))")
        return "the activity row shows one plain line for every corrective result"
    }

    private static func repairArguments() async throws -> String {
        let require = NativeTaskFixture.require
        let call = NativeWebToolsSelftest.call
        let reply = NativeWebToolsSelftest.reply
        let log = NativeToolExtensionLog()
        let shelf = repairShelf(log)
        let counter = repairShelf(log, name: "shelf_count", id: "repair-count")
        let registry = NativeToolRegistry(definitions: [shelf, counter])
        let enabled: Set<String> = [shelf.id, counter.id]
        let lead = NativeToolError.invalidArguments("").localizedDescription
        let invalid = NativeJSONValue.string(NativeToolCallFault.invalidArguments.rawValue)
        try require(registry.issues.isEmpty, "The repair fixtures pass the registry")

        let (malformed, malformedTransport) = try await repairLoop(
            registry, rounds: [call("bad-json", "shelf_lookup", #"{"packet": "#), reply("No shelf.")], enabled: enabled)
        let broken = repairFields(repairResults(malformedTransport)["bad-json"])
        try require(log.all.isEmpty && malformed?.activities.first?.state == .failed
                    && broken["fault"] == NativeJSONValue.string(NativeToolCallFault.malformedArguments.rawValue) && broken["not_run"] == NativeJSONValue.bool(true)
                    && broken["repairs_left"] == NativeJSONValue.number(2) && broken["fix"] == NativeJSONValue.string(NativeToolRepair.correct)
                    && repairText(broken["error"]).hasPrefix(lead),
                    "Arguments that are not JSON are answered as malformed and nothing runs: \(broken)")
        try require(NativeToolActivityChip.shownResult(malformed?.activities.first?.result ?? "") == NativeToolActivityChip.incomplete,
                    "A malformed call shows the incomplete line")

        let cases: [(raw: String, problems: [NativeSchemaProblem], label: String)] = [
            (#"{"count":2}"#, [NativeSchemaProblem(path: "packet", expected: "is required")], "A missing required field"),
            (#"{"packet":"Beans","count":"two"}"#, [NativeSchemaProblem(path: "count", expected: "must be a whole number")], "A wrong type"),
            (#"{"packet":"Beans","kind":"tuber"}"#, [NativeSchemaProblem(path: "kind", expected: "must be one of: seed, bulb")], "A value outside its choices"),
            (#"{"packet":"Beans","count":0}"#, [NativeSchemaProblem(path: "count", expected: "must be at least 1")], "A value below its minimum"),
            (#"{"packet":"Beans","count":100}"#, [NativeSchemaProblem(path: "count", expected: "must be at most 99")], "A value above its maximum"),
            (#"{"packet":"Beans","filters":{"shelf":"east"}}"#, [NativeSchemaProblem(path: "filters.shelf", expected: "must be one of: north, south")],
             "A wrong value inside an object"),
            (#"{"packet":"Beans","items":[{"name":"Kale"},{}]}"#, [NativeSchemaProblem(path: "items[1].name", expected: "is required")],
             "A missing field inside a list item"),
            (#"{"packet":"Beans","colour":"red"}"#, [NativeSchemaProblem(path: "colour", expected: "is not a field this call accepts")],
             "A field the schema does not declare"),
        ]
        for (index, item) in cases.enumerated() {
            log.clear()
            let callID = "bad-\(index)"
            let (checked, checkedTransport) = try await repairLoop(
                registry, rounds: [call(callID, "shelf_lookup", item.raw), reply("No shelf.")], enabled: enabled)
            let fields = repairFields(repairResults(checkedTransport)[callID])
            try require(log.all.isEmpty && checked?.activities.first?.state == .failed && fields["fault"] == invalid
                        && fields["not_run"] == NativeJSONValue.bool(true) && fields["repairs_left"] == NativeJSONValue.number(2)
                        && fields["fix"] == NativeJSONValue.string(NativeToolRepair.correct) && repairText(fields["error"]).hasPrefix(lead)
                        && repairProblems(fields) == item.problems,
                        "\(item.label) is answered with where it went wrong and nothing runs: \(fields)")
            try require(NativeToolActivityChip.shownResult(checked?.activities.first?.result ?? "") == NativeToolActivityChip.incomplete,
                        "\(item.label) shows the incomplete line")
        }

        log.clear()
        let (missing, missingTransport) = try await repairLoop(
            registry, rounds: [call("call-missing", "shelf_missing", #"{"packet":"Beans"}"#), reply("No shelf.")], enabled: enabled)
        let refusal = repairFields(repairResults(missingTransport)["call-missing"])
        try require(log.all.isEmpty && missing?.activities.first?.state == .failed
                    && refusal["error"] == NativeJSONValue.string(NativeToolError.unavailable.localizedDescription)
                    && refusal["fault"] == NativeJSONValue.string(NativeToolCallFault.unknownTool.rawValue) && refusal["not_run"] == NativeJSONValue.bool(true)
                    && repairNames(refusal["offered"]) == ["shelf_count", "shelf_lookup"] && refusal["repairs_left"] == NativeJSONValue.number(2)
                    && refusal["fix"] == NativeJSONValue.string(NativeToolRepair.choose),
                    "An unknown name is answered with the names that are offered and nothing runs: \(refusal)")
        try require(NativeToolActivityChip.shownResult(missing?.activities.first?.result ?? "") == NativeToolActivityChip.unavailable,
                    "An unknown name shows the unavailable line")

        let patterned = NativeToolDefinition(
            id: "repair-code", name: "shelf_code", title: "Read a shelf code",
            description: "Reads a shelf by its code. When to use: the person gives a shelf code.",
            parameters: .object(["type": .string("object"), "properties": .object([
                "code": .object(["type": .string("string"), "minLength": .number(1), "pattern": .string("^[A-Z][0-9]$"),
                                 "description": .string("The shelf code.")]),
            ])]),
            confirmation: .none, effect: .read, isAvailable: { true },
            execute: { arguments in
                log.started(arguments)
                return .object(["shelf": .string("B3")])
            })
        let guarded = NativeToolRegistry(definitions: [shelf, patterned])
        try require(guarded.issues == [NativeToolIssue(name: "shelf_code", reason: .unsupportedSchema)]
                    && guarded.definitions.map(\.name) == ["shelf_lookup"],
                    "A tool whose schema uses pattern is kept out and reported")
        log.clear()
        let (coded, codedTransport) = try await repairLoop(
            guarded, rounds: [call("call-code", "shelf_code", #"{"code":"B3"}"#), reply("No shelf.")], enabled: [shelf.id, patterned.id])
        let codedFields = repairFields(repairResults(codedTransport)["call-code"])
        try require(codedTransport.schemas.first?.map(\.name) == ["shelf_lookup"] && log.all.isEmpty && coded?.activities.first?.state == .failed
                    && codedFields["fault"] == NativeJSONValue.string(NativeToolCallFault.unknownTool.rawValue) && repairNames(codedFields["offered"]) == ["shelf_lookup"],
                    "A tool kept out by the registry is never offered and a call to it is answered as unknown: \(codedFields)")
        return "malformed, missing, mistyped, out of range, nested and undeclared arguments and unknown or unsupported names are answered with what to fix and run nothing"
    }

    private static func repairCorrection() async throws -> String {
        let require = NativeTaskFixture.require
        let call = NativeWebToolsSelftest.call
        let reply = NativeWebToolsSelftest.reply
        let log = NativeToolExtensionLog()
        let shelf = repairShelf(log)
        let counter = repairShelf(log, name: "shelf_count", id: "repair-count")
        let registry = NativeToolRegistry(definitions: [shelf, counter])
        let enabled: Set<String> = [shelf.id, counter.id]
        let invalid = NativeJSONValue.string(NativeToolCallFault.invalidArguments.rawValue)
        let beans: [String: NativeJSONValue] = ["packet": .string("Beans")]

        let (fixed, fixedTransport) = try await repairLoop(registry, rounds: [
            call("fix-1", "shelf_lookup", #"{"count":2}"#),
            call("fix-2", "shelf_lookup", #"{"packet":"Beans"}"#),
            reply("Shelf B3."),
        ], enabled: enabled)
        let fixedResults = repairResults(fixedTransport)
        let fixedHistories = fixedTransport.histories
        try require(log.all == [NativeToolExtensionLog.Entry(call: "fix-2", arguments: beans)]
                    && NativeJSONValue.object(repairFields(fixedResults["fix-2"])) == repairEcho(beans)
                    && repairFields(fixedResults["fix-1"])["fault"] == invalid && fixed?.content == "Shelf B3.",
                    "A corrected call runs once with the corrected arguments: \(log.all)")
        try require(fixedHistories.count == 3
                    && fixedHistories[1].last?.role == "tool" && fixedHistories[1].last?.toolCallID == "fix-1"
                    && fixedHistories[2].last?.role == "tool" && fixedHistories[2].last?.toolCallID == "fix-2"
                    && fixed?.activities.map(\.id) == ["fix-1", "fix-2"],
                    "Each round's answer carries that round's own call id")

        log.clear()
        let (spent, spentTransport) = try await repairLoop(registry, rounds: [
            call("ex-1", "shelf_lookup", #"{"count":2}"#),
            call("ex-2", "shelf_lookup", #"{"count":2}"#),
            repairRound([NativeChatToolCall(id: "ex-3", name: "shelf_lookup", arguments: #"{"count":2}"#),
                         NativeChatToolCall(id: "ex-4", name: "shelf_count", arguments: #"{"packet":"Kale"}"#)]),
            reply("I couldn't look that up."),
        ], enabled: enabled)
        let spentResults = repairResults(spentTransport)
        let firstFields = repairFields(spentResults["ex-1"])
        let secondFields = repairFields(spentResults["ex-2"])
        let thirdFields = repairFields(spentResults["ex-3"])
        let spentSchemas = spentTransport.schemas
        try require(firstFields["repairs_left"] == NativeJSONValue.number(2) && secondFields["repairs_left"] == NativeJSONValue.number(1)
                    && thirdFields["closed"] == NativeJSONValue.bool(true) && thirdFields["repairs_left"] == NativeJSONValue.number(0)
                    && thirdFields["fix"] == NativeJSONValue.string(NativeToolRepair.stop) && thirdFields["not_run"] == NativeJSONValue.bool(true) && thirdFields["fault"] == invalid,
                    "Two repairs are offered and the third failure closes the name: \(thirdFields)")
        try require(log.all == [NativeToolExtensionLog.Entry(call: "ex-4", arguments: ["packet": .string("Kale")])],
                    "No failed call runs, and the other call in the closing round still runs: \(log.all)")
        try require(spentSchemas.count == 4 && spentSchemas.count <= NativeToolLoop.maximumRounds + 1
                    && spentSchemas.prefix(3).allSatisfy { !$0.isEmpty } && spentSchemas[3].isEmpty
                    && spent?.content == "I couldn't look that up." && spent?.isPartial == false,
                    "After a name closes the turn asks once more without tools and ends with that answer: \(spentSchemas.map(\.count))")
        try require(NativeToolActivityChip.shownResult(spent?.activities.first(where: { $0.id == "ex-3" })?.result ?? "") == NativeToolActivityChip.incomplete,
                    "A closed call shows the incomplete line")

        log.clear()
        let (lost, lostTransport) = try await repairLoop(registry, rounds: [
            call("u-1", "shelf_a", "{}"), call("u-2", "shelf_b", "{}"), call("u-3", "shelf_c", "{}"), reply("Those shelves don't exist."),
        ], enabled: enabled)
        let lostResults = repairResults(lostTransport)
        let lostThird = repairFields(lostResults["u-3"])
        try require(repairFields(lostResults["u-1"])["repairs_left"] == NativeJSONValue.number(2) && repairFields(lostResults["u-2"])["repairs_left"] == NativeJSONValue.number(1)
                    && lostThird["closed"] == NativeJSONValue.bool(true) && lostThird["fault"] == NativeJSONValue.string(NativeToolCallFault.unknownTool.rawValue)
                    && lostThird["offered"] == nil && lostTransport.schemas.count == 4 && lostTransport.schemas.last?.isEmpty == true
                    && lost?.content == "Those shelves don't exist." && log.all.isEmpty,
                    "Different unknown names share one count and close together: \(lostThird)")

        log.clear()
        let (reset, resetTransport) = try await repairLoop(registry, rounds: [
            call("r-1", "shelf_lookup", #"{"count":2}"#),
            call("r-2", "shelf_lookup", #"{"packet":"Beans"}"#),
            call("r-3", "shelf_lookup", #"{"count":2}"#),
            reply("Shelf B3."),
        ], enabled: enabled)
        let resetResults = repairResults(resetTransport)
        try require(repairFields(resetResults["r-1"])["repairs_left"] == NativeJSONValue.number(2) && repairFields(resetResults["r-3"])["repairs_left"] == NativeJSONValue.number(2)
                    && repairFields(resetResults["r-3"])["closed"] == nil
                    && log.all == [NativeToolExtensionLog.Entry(call: "r-2", arguments: beans)]
                    && resetTransport.schemas.count == 4 && resetTransport.schemas.last?.isEmpty == false && reset?.content == "Shelf B3.",
                    "A valid call between two failed ones resets the count")

        for badFirst in [true, false] {
            log.clear()
            let bad = NativeChatToolCall(id: badFirst ? "p-bad" : "q-bad", name: "shelf_lookup", arguments: #"{"count":2}"#)
            let good = NativeChatToolCall(id: badFirst ? "p-good" : "q-good", name: "shelf_lookup", arguments: #"{"packet":"Chard","count":3}"#)
            let calls = badFirst ? [bad, good] : [good, bad]
            let (pair, pairTransport) = try await repairLoop(registry, rounds: [repairRound(calls), reply("Chard is on B3.")], enabled: enabled)
            let sent: [String: NativeJSONValue] = ["packet": .string("Chard"), "count": .number(3)]
            let pairResults = repairResults(pairTransport)
            let goodFields = repairFields(pairResults[good.id])
            let badFields = repairFields(pairResults[bad.id])
            let answeredIDs = (pairTransport.histories.last ?? []).filter { $0.role == "tool" }.compactMap(\.toolCallID)
            try require(log.all == [NativeToolExtensionLog.Entry(call: good.id, arguments: sent)],
                        "The valid call in a mixed round runs once with exactly what was sent: \(log.all)")
            try require(answeredIDs == calls.map(\.id) && NativeJSONValue.object(goodFields) == repairEcho(sent)
                        && goodFields["error"] == nil && goodFields["fault"] == nil && badFields["fault"] == invalid
                        && pair?.activities.first(where: { $0.id == good.id })?.state == .succeeded
                        && pair?.activities.first(where: { $0.id == bad.id })?.state == .failed,
                        "Each call in a mixed round is answered under its own id, and the failure stays on its own call")
        }
        return "a corrected call runs once under its own id, three failures close a name and the turn answers without tools, unknown names share a count, a valid call resets it, and a mixed round keeps each answer on its own call"
    }

    private static func repairFragments() async throws -> String {
        let require = NativeTaskFixture.require
        let log = NativeToolExtensionLog()
        let shelf = repairShelf(log)
        let registry = NativeToolRegistry(definitions: [shelf])
        let payloads = [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"frag-one","type":"function","function":{"name":"shelf_","arguments":"{\"packet\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"frag-two","type":"function","function":{"name":"shelf_lookup","arguments":"{\"pac"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"lookup","arguments":"\"Beans\",\"cou"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"ket\":\"Kale\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"nt\":3}"}}]},"finish_reason":"tool_calls"}]}"#,
        ]
        var accumulator = NativeChatDeltaAccumulator()
        var latest: NativeChatStreamSnapshot?
        for payload in payloads { latest = try accumulator.consume(payload) }
        guard let assembled = latest else { throw NativeTaskFixture.Failure.assertion("The fragments assemble into a snapshot") }
        try require(assembled.finishReason == "tool_calls" && assembled.toolCalls == [
            NativeChatToolCall(id: "frag-one", name: "shelf_lookup", arguments: #"{"packet":"Beans","count":3}"#),
            NativeChatToolCall(id: "frag-two", name: "shelf_lookup", arguments: #"{"packet":"Kale"}"#),
        ], "Two interleaved calls are rebuilt exactly from their fragments: \(assembled.toolCalls)")
        let (both, _) = try await repairLoop(registry, rounds: [[assembled], NativeWebToolsSelftest.reply("Both are on B3.")], enabled: [shelf.id])
        try require(log.all == [NativeToolExtensionLog.Entry(call: "frag-one", arguments: ["packet": .string("Beans"), "count": .number(3)]),
                                NativeToolExtensionLog.Entry(call: "frag-two", arguments: ["packet": .string("Kale")])]
                    && both?.activities.allSatisfy { $0.state == .succeeded } == true,
                    "Each rebuilt call runs once with its own arguments: \(log.all)")

        log.clear()
        var cut = NativeChatDeltaAccumulator()
        _ = try cut.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"frag-cut","type":"function","function":{"name":"shelf_lookup","arguments":"{\"packet\":"}}]}}]}"#)
        let truncated = try cut.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Bea"}}]},"finish_reason":"tool_calls"}]}"#)
        try require(truncated.toolCalls == [NativeChatToolCall(id: "frag-cut", name: "shelf_lookup", arguments: #"{"packet":"Bea"#)],
                    "A call cut off mid-argument is assembled as sent: \(truncated.toolCalls)")
        let (shortened, shortenedTransport) = try await repairLoop(registry, rounds: [[truncated], NativeWebToolsSelftest.reply("No shelf.")],
                                                                   enabled: [shelf.id])
        let cutFields = repairFields(repairResults(shortenedTransport)["frag-cut"])
        try require(log.all.isEmpty && shortened?.activities.first?.state == .failed
                    && cutFields["fault"] == NativeJSONValue.string(NativeToolCallFault.malformedArguments.rawValue) && cutFields["repairs_left"] == NativeJSONValue.number(2),
                    "A call whose arguments were cut off is answered as malformed and nothing runs: \(cutFields)")
        return "fragmented calls rebuild exactly and run once each, and a cut-off call is answered as malformed"
    }

    private static func repairCancel() async throws -> String {
        let require = NativeTaskFixture.require
        let log = NativeToolExtensionLog()
        let shelf = repairShelf(log)
        let transport = ScriptedNativeToolTransport(rounds: [
            NativeWebToolsSelftest.call("stop-1", "shelf_lookup", #"{"count":2}"#),
            repairRound([NativeChatToolCall(id: "stop-2", name: "shelf_lookup", arguments: #"{"packet":"Beans","wait":900}"#),
                         NativeChatToolCall(id: "stop-3", name: "shelf_lookup", arguments: #"{"packet":"Kale"}"#)]),
            NativeWebToolsSelftest.reply("Never."),
        ])
        let loop = NativeToolLoop(transport: transport, registry: NativeToolRegistry(definitions: [shelf]))
        let enabled: Set<String> = [shelf.id]
        let consumer = Task { () async throws -> NativeToolTurnSnapshot? in
            var last: NativeToolTurnSnapshot?
            for try await snapshot in loop.stream(messages: [NativeChatMessage(role: "user", content: "Where are the beans?")],
                                                  model: "local-model", enabledToolIDs: enabled) {
                try Task.checkCancellation()
                last = snapshot
            }
            try Task.checkCancellation()
            return last
        }
        for _ in 0..<200 {
            if !log.all.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try require(log.all.map(\.call) == ["stop-2"], "The handler is running when the turn is stopped: \(log.all)")
        consumer.cancel()
        var canceled = false
        do { _ = try await consumer.value } catch is CancellationError { canceled = true }
        try await Task.sleep(nanoseconds: 150_000_000)
        let earlier = transport.histories.count > 1 ? transport.histories[1].last(where: { $0.role == "tool" })?.content : nil
        try require(canceled && log.all.map(\.call) == ["stop-2"] && log.finished.isEmpty && transport.schemas.count == 2
                    && repairFields(earlier)["fault"] == NativeJSONValue.string(NativeToolCallFault.invalidArguments.rawValue),
                    "Stopping after a repair ends the turn as stopped and runs nothing more: \(log.all.map(\.call))")
        return "stopping a turn after a repair ends it as stopped with no further handler or model call"
    }

    private static func repairUncertainWrite() async throws -> String {
        let require = NativeTaskFixture.require
        let call = NativeWebToolsSelftest.call
        let reply = NativeWebToolsSelftest.reply
        let repository = try LocalChatRepository(inMemory: true)
        let ledger = NativeEffectLedgerStore(database: repository.database)
        let (_, turn) = try chatLedgerTurn(repository)
        let hook = chatLedgerHook(ledger, turn: turn, rules: chatLedgerRules([.otherChanges: .act]), grants: NativeFolderGrantSource(),
                                  log: NativeChatLedgerLog()) { _ in NativeCardAnswer(kind: .allowOnce, byPerson: true) }
        let log = NativeToolExtensionLog()
        var water = NativeToolDefinition(
            id: "repair-water", name: "water_bed", title: "Water a bed",
            description: "Waters one garden bed. When to use: the person asks for a bed to be watered.",
            parameters: .object(["type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("bed")]),
                                 "properties": .object(["bed": .object(["type": .string("string"), "minLength": .number(1),
                                                                        "description": .string("The bed to water.")])])]),
            confirmation: .none, effect: .write, action: .otherChanges, isAvailable: { true },
            execute: { arguments in
                log.started(arguments)
                if arguments["bed"] == NativeJSONValue.string("north") { try await Task.sleep(nanoseconds: 2_000_000_000) }
                return .object(["watered": .bool(true)])
            })
        water.confirmationFor = { _ in false }
        let (watered, wateredTransport) = try await repairLoop(NativeToolRegistry(definitions: [water]), rounds: [
            call("w-north", "water_bed", #"{"bed":"north"}"#),
            call("w-north-again", "water_bed", #"{"bed":"north"}"#),
            call("w-south", "water_bed", #"{"bed":"south"}"#),
            reply("The north bed could not be confirmed."),
        ], enabled: [water.id], timeout: .milliseconds(150), effects: hook)
        let wateredResults = repairResults(wateredTransport)
        let unsure = repairFields(wateredResults["w-north"])
        let refused = repairFields(wateredResults["w-north-again"])
        try require(unsure["error"] == NativeJSONValue.string(NativeToolLoop.timedOutMessage) && unsure["outcome"] == NativeJSONValue.string("uncertain")
                    && unsure["fix"] == NativeJSONValue.string(NativeToolRepair.unconfirmed),
                    "A recorded write that timed out is reported as unconfirmed: \(unsure)")
        try require(refused["error"] == NativeJSONValue.string(NativeToolRepair.repeated) && refused["not_run"] == NativeJSONValue.bool(true)
                    && refused["outcome"] == NativeJSONValue.string("uncertain") && refused["fix"] == NativeJSONValue.string(NativeToolRepair.unconfirmed),
                    "The same write with the same arguments is refused for the rest of the answer: \(refused)")
        try require(NativeJSONValue.object(repairFields(wateredResults["w-south"])) == NativeJSONValue.object(["watered": .bool(true)])
                    && log.all.map(\.call) == ["w-north", "w-south"],
                    "The handler ran once for the unconfirmed write and once for different arguments: \(log.all.map(\.call))")
        let rows = try chatLedgerRows(ledger, turn, "water_bed")
        try require(rows.count == 2 && rows.contains { $0.state == .uncertain && $0.receipt == NativeJSONValue.object(["reason": .string("timeout")]) }
                    && rows.contains { $0.state == .completed },
                    "The refused repeat leaves no row of its own: \(rows.map(\.state))")
        try require(watered?.activities.map(\.state) == [NativeToolActivityState.failed, .failed, .succeeded]
                    && NativeToolActivityChip.shownResult(watered?.activities.first?.result ?? "") == NativeToolLoop.timedOutMessage,
                    "The activity row shows the timeout sentence alone")

        let readLog = NativeToolExtensionLog()
        let slowShelf = repairShelf(readLog, timeout: .milliseconds(150))
        let (_, readTransport) = try await repairLoop(NativeToolRegistry(definitions: [slowShelf]), rounds: [
            call("rd-1", "shelf_lookup", #"{"packet":"Peas","wait":600}"#),
            call("rd-2", "shelf_lookup", #"{"packet":"Peas","wait":600}"#),
            reply("The lookup kept timing out."),
        ], enabled: [slowShelf.id])
        let readResults = repairResults(readTransport)
        let readFirst = repairFields(readResults["rd-1"])
        let readSecond = repairFields(readResults["rd-2"])
        try require(readLog.all.map(\.call) == ["rd-1", "rd-2"] && readLog.finished.isEmpty
                    && readFirst["error"] == NativeJSONValue.string(NativeToolLoop.timedOutMessage) && readFirst["outcome"] == nil
                    && readSecond["error"] == NativeJSONValue.string(NativeToolLoop.timedOutMessage) && readSecond["not_run"] == nil,
                    "A read that timed out can be called again and runs again: \(readLog.all.map(\.call))")

        let blankLog = NativeToolExtensionLog()
        let label = NativeToolDefinition(
            id: "repair-label", name: "label_shelf", title: "Label a shelf",
            description: "Prints a label for a greenhouse shelf. When to use: the person asks for a shelf to be labelled.",
            parameters: .object(["type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("label")]),
                                 "properties": .object(["label": .object(["type": .string("string"), "minLength": .number(1),
                                                                          "description": .string("The text to print.")])])]),
            confirmation: .none, effect: .write, isAvailable: { true },
            execute: { arguments in
                blankLog.started(arguments)
                return .null
            })
        let (labelled, labelTransport) = try await repairLoop(NativeToolRegistry(definitions: [label]), rounds: [
            call("l-1", "label_shelf", #"{"label":"Beans"}"#),
            call("l-2", "label_shelf", #"{"label":"Beans"}"#),
            reply("The label could not be confirmed."),
        ], enabled: [label.id])
        let labelResults = repairResults(labelTransport)
        let emptyWrite = repairFields(labelResults["l-1"])
        try require(emptyWrite["fault"] == NativeJSONValue.string(NativeToolCallFault.invalidResult.rawValue) && emptyWrite["error"] == NativeJSONValue.string(NativeToolRepair.emptyResult)
                    && emptyWrite["outcome"] == NativeJSONValue.string("uncertain") && emptyWrite["fix"] == NativeJSONValue.string(NativeToolRepair.unconfirmed)
                    && repairFields(labelResults["l-2"])["error"] == NativeJSONValue.string(NativeToolRepair.repeated)
                    && blankLog.all.map(\.call) == ["l-1"] && labelled?.activities.map(\.state) == [NativeToolActivityState.failed, .failed],
                    "A write that returns nothing is unconfirmed and is not run again: \(emptyWrite)")
        return "a recorded write that timed out is unconfirmed and the same call is refused while different arguments run, a read can time out and run again, and a write that returns nothing is unconfirmed"
    }

    private static func repairReturned() async throws -> String {
        let require = NativeTaskFixture.require
        let log = NativeToolExtensionLog()
        let shape: NativeJSONValue = .object(["type": .string("object"), "required": .array([.string("shelf")]),
                                              "properties": .object(["shelf": .object(["type": .string("string")])])])
        func answered(_ definition: NativeToolDefinition) async throws -> (fields: [String: NativeJSONValue], state: NativeToolActivityState?) {
            let registry = NativeToolRegistry(definitions: [definition])
            guard registry.issues.isEmpty else { throw NativeTaskFixture.Failure.assertion("The result fixture passes the registry") }
            let (snapshot, transport) = try await repairLoop(registry, rounds: [
                NativeWebToolsSelftest.call("ret", definition.name, #"{"packet":"Beans"}"#), NativeWebToolsSelftest.reply("Done."),
            ], enabled: [definition.id])
            return (repairFields(repairResults(transport)["ret"]), snapshot?.activities.first?.state)
        }
        let invalidResult = NativeJSONValue.string(NativeToolCallFault.invalidResult.rawValue)

        let nothing = try await answered(repairShelf(log, answer: { _ in .null }))
        try require(nothing.fields["fault"] == invalidResult && nothing.fields["error"] == NativeJSONValue.string(NativeToolRepair.emptyResult)
                    && nothing.fields["outcome"] == nil && nothing.state == .failed,
                    "A read that returns null is an error, not a success: \(nothing.fields)")
        let blank = try await answered(repairShelf(log, answer: { _ in .string("  ") }))
        try require(blank.fields["fault"] == invalidResult && blank.fields["error"] == NativeJSONValue.string(NativeToolRepair.emptyResult) && blank.state == .failed,
                    "A read that returns blank text is an error, not a success: \(blank.fields)")

        var mismatched = repairShelf(log, answer: { _ in .object(["rack": .number(3)]) })
        mismatched.outputSchema = shape
        let wrongShape = try await answered(mismatched)
        try require(wrongShape.fields["fault"] == invalidResult && wrongShape.fields["error"] == NativeJSONValue.string(NativeToolRepair.mismatchedResult)
                    && wrongShape.state == .failed,
                    "A result that breaks the declared output schema is an error: \(wrongShape.fields)")

        var matching = repairShelf(log, answer: { _ in .object(["shelf": .string("B3")]) })
        matching.outputSchema = shape
        let rightShape = try await answered(matching)
        try require(NativeJSONValue.object(rightShape.fields) == NativeJSONValue.object(["shelf": .string("B3")]) && rightShape.state == .succeeded,
                    "A result that fits the declared output schema passes unchanged: \(rightShape.fields)")

        var own = repairShelf(log, answer: { _ in .object(["rack": .number(3)]) })
        own.outputSchema = shape
        own.checksOwnResult = true
        let ownShape = try await answered(own)
        try require(NativeJSONValue.object(ownShape.fields) == NativeJSONValue.object(["rack": .number(3)]) && ownShape.state == .succeeded,
                    "A tool that checks its own results is not checked again: \(ownShape.fields)")
        return "null, blank and wrongly shaped results are errors, a fitting result passes unchanged, and a tool that checks its own results is left alone"
    }

    private static func repairRequestShape() async throws -> String {
        let require = NativeTaskFixture.require
        let log = NativeToolExtensionLog()
        let shelf = repairShelf(log)
        let registry = NativeToolRegistry(definitions: [shelf])
        let lookalike = #"<tool_call>{"name":"shelf_lookup","arguments":{"packet":"Beans"}}</tool_call>"#
        let (answer, transport) = try await repairLoop(registry, rounds: [NativeWebToolsSelftest.reply(lookalike)], enabled: [shelf.id])
        try require(log.all.isEmpty && answer?.content == lookalike && answer?.activities.isEmpty == true && transport.schemas.count == 1,
                    "Text that only looks like a call runs nothing and is the answer: \(String(describing: answer?.content))")
        let sentSchemas = transport.schemas.flatMap { $0 }
        try require(sentSchemas.map(\.name) == ["shelf_lookup"], "The tool is offered")
        for schema in sentSchemas {
            let data = try JSONSerialization.data(withJSONObject: schema.requestObject, options: [.sortedKeys])
            try require(!String(decoding: data, as: UTF8.self).contains("\"strict\""), "\(schema.name) is sent without a strict flag")
        }
        let client = NativeChatClient(config: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
                                                               model: "local-model", chatTemplateKwargs: nil))
        let request = try client.request(messages: [NativeChatMessage(role: "user", content: "Where are the beans?")], model: "local-model",
                                         tools: sentSchemas)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        try require(body.contains("shelf_lookup") && !body.contains("\"strict\""), "The chat request carries no strict flag anywhere")
        return "requests carry no strict flag and text that looks like a call is only text"
    }

    private static func repairWorkModel(_ rounds: [[NativeTaskGenerationToolCall]]) -> NativeCompanionFinishModel {
        NativeCompanionFinishModel(closing: .text("The beans are on shelf B3.")) { messages in
            let replied = messages.filter { $0.role == "assistant" && $0.toolCalls != nil }.count
            guard rounds.indices.contains(replied) else { return .text("The beans are on shelf B3.") }
            return NativeTaskGenerationCompletion(content: "", toolCalls: rounds[replied], finishReason: "tool_calls")
        }
    }

    private static func repairWorkRun(_ rig: NativeCompanionFinishRig) async throws -> (record: NativeTaskRecord, saved: [NativeCompanionCheckpoint]) {
        var saved: [NativeCompanionCheckpoint] = []
        for _ in 0..<40 {
            let record = try await rig.step()
            if let checkpoint = try? rig.checkpoint(record) { saved.append(checkpoint) }
            if record.state != .queued { return (record, saved) }
        }
        throw NativeTaskFixture.Failure.assertion("The handed-off work settles")
    }

    private static func repairWorkResults(_ checkpoint: NativeCompanionCheckpoint?) -> [String: String] {
        var found: [String: String] = [:]
        for message in checkpoint?.transcript ?? [] where message.role == "tool" {
            if let id = message.toolCallID { found[id] = message.content }
        }
        return found
    }

    private static func repairHandedOff() async throws -> String {
        let require = NativeTaskFixture.require
        let call = { (id: String, name: String, arguments: String) in NativeTaskGenerationToolCall(id: id, name: name, arguments: arguments) }
        let assignment = "Find where the seed packets are kept"
        let log = NativeToolExtensionLog()
        let shelf = repairShelf(log)
        let invalid = NativeJSONValue.string(NativeToolCallFault.invalidArguments.rawValue)
        let beans: [String: NativeJSONValue] = ["packet": .string("Beans")]

        let fixing = try NativeCompanionFinishRig(tools: [shelf], model: repairWorkModel([
            [call("work-bad", "shelf_lookup", #"{"count":2}"#)],
            [call("work-good", "shelf_lookup", #"{"packet":"Beans"}"#)],
        ]))
        _ = try fixing.create(assignment)
        let (fixed, fixedSaved) = try await repairWorkRun(fixing)
        let fixedResults = repairWorkResults(fixedSaved.last)
        let badFields = repairFields(fixedResults["work-bad"])
        try require(fixed.state == .completed && fixedSaved.last.map(NativeCompanionFinishRig.answeredOnce) == true,
                    "Handed-off work with a corrected call completes and answers every call once")
        try require(log.all.map(\.arguments) == [beans] && NativeJSONValue.object(repairFields(fixedResults["work-good"])) == repairEcho(beans),
                    "The corrected handed-off call runs once with the corrected arguments: \(log.all)")
        try require(badFields["fault"] == invalid && badFields["repairs_left"] == NativeJSONValue.number(2) && badFields["not_run"] == NativeJSONValue.bool(true)
                    && repairProblems(badFields) == [NativeSchemaProblem(path: "packet", expected: "is required")],
                    "The failed handed-off call is answered with what to fix: \(badFields)")
        try require(fixedSaved.contains { $0.repairs?.counts["shelf_lookup"] == 1 } && fixedSaved.last?.repairs?.counts.isEmpty == true,
                    "The saved count rises with the failure and clears with the valid call")

        log.clear()
        let lost = try NativeCompanionFinishRig(tools: [shelf], model: repairWorkModel([
            [call("work-missing", "shelf_missing", #"{"packet":"Beans"}"#)],
        ]))
        _ = try lost.create(assignment)
        let (lostRecord, lostSaved) = try await repairWorkRun(lost)
        let lostFields = repairFields(repairWorkResults(lostSaved.last)["work-missing"])
        try require(lostRecord.state == .completed && log.all.isEmpty && lostFields["error"] == NativeJSONValue.string(NativeCompanionWorker.unknownTool)
                    && lostFields["fault"] == NativeJSONValue.string(NativeToolCallFault.unknownTool.rawValue) && repairNames(lostFields["offered"]) == ["shelf_lookup"]
                    && lostFields["repairs_left"] == NativeJSONValue.number(2) && lostFields["not_run"] == NativeJSONValue.bool(true),
                    "An unknown name in handed-off work is answered with the offered names: \(lostFields)")

        let closingRounds = [
            [call("work-1", "shelf_lookup", #"{"count":2}"#)],
            [call("work-2", "shelf_lookup", #"{"count":"two"}"#)],
            [call("work-3", "shelf_lookup", #"{"packet":""}"#)],
            [call("work-4", "shelf_lookup", #"{"packet":"Beans"}"#)],
        ]
        log.clear()
        let closing = try NativeCompanionFinishRig(tools: [shelf], model: repairWorkModel(closingRounds))
        _ = try closing.create(assignment)
        let (closed, closedSaved) = try await repairWorkRun(closing)
        let closedResults = repairWorkResults(closedSaved.last)
        let closedFields = repairFields(closedResults["work-3"])
        try require(closed.state == .completed && log.all.isEmpty && closedResults["work-4"] == nil,
                    "Handed-off work whose name closed completes without running or asking for anything more")
        try require(closedFields["closed"] == NativeJSONValue.bool(true) && closedFields["repairs_left"] == NativeJSONValue.number(0)
                    && closedFields["fix"] == NativeJSONValue.string(NativeToolRepair.stop) && closedFields["fault"] == invalid,
                    "The third failure closes the name in handed-off work: \(closedFields)")
        try require(closedSaved.contains { $0.repairs?.counts["shelf_lookup"] == 1 } && closedSaved.contains { $0.repairs?.counts["shelf_lookup"] == 2 }
                    && closedSaved.contains { $0.finishing == true && $0.repairs?.isClosed("shelf_lookup") == true },
                    "Each failure is saved in the checkpoint and closing marks the work as finishing")
        let asked = closing.model.calls
        try require(asked.filter { $0.choice == "auto" }.count == 3 && asked.last?.attempt.hasSuffix("-finish") == true && asked.last?.choice == "none",
                    "After the name closes the work goes straight to its closing write-up: \(asked.map(\.attempt))")

        guard let midway = closedSaved.first(where: { $0.repairs?.counts["shelf_lookup"] == 2 }) else {
            throw NativeTaskFixture.Failure.assertion("A checkpoint holds two failures")
        }
        let reread = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: try midway.encoded())
        try require(reread == midway && reread.repairs?.counts["shelf_lookup"] == 2 && reread.finishing != true,
                    "The saved count survives encoding and decoding the checkpoint")
        log.clear()
        let resumed = try NativeCompanionFinishRig(tools: [shelf], model: repairWorkModel(closingRounds))
        let resumedID = try resumed.create(assignment)
        _ = try resumed.seed(resumedID, checkpoint: try reread.encoded())
        let (resumedRecord, resumedSaved) = try await repairWorkRun(resumed)
        let resumedFields = repairFields(repairWorkResults(resumedSaved.last)["work-3"])
        try require(resumedRecord.state == .completed && log.all.isEmpty && resumedFields["closed"] == NativeJSONValue.bool(true)
                    && resumed.model.calls.filter { $0.choice == "auto" }.count == 1
                    && resumedSaved.contains { $0.finishing == true && $0.repairs?.isClosed("shelf_lookup") == true },
                    "Work continued from the saved checkpoint keeps its count, so one more failure closes the name: \(resumedFields)")

        let old = Data(#"{"attempt":"0ldattempt","calls":1,"effects":[],"rounds":1,"thread_id":"companion-thread-1","transcript":[]}"#.utf8)
        let decodedOld = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: old)
        try require(decodedOld.repairs == nil && !String(decoding: try decodedOld.encoded(), as: UTF8.self).contains("repairs"),
                    "An older checkpoint without counts still reads and writes as before")
        return "handed-off work answers a corrected call once, lists offered names for an unknown one, closes a name after three failures and finishes, and keeps its counts in the checkpoint across a save and an older checkpoint"
    }
}
