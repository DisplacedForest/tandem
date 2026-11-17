import Foundation

final class NativeToolExtensionLog: @unchecked Sendable {
    struct Entry: Equatable {
        let call: String?
        let arguments: [String: NativeJSONValue]
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var finishes: [String] = []

    var all: [Entry] { lock.withLock { entries } }
    var finished: [String] { lock.withLock { finishes } }

    func started(_ arguments: [String: NativeJSONValue]) {
        let call = NativeToolCallContext.activityID
        lock.withLock { entries.append(Entry(call: call, arguments: arguments)) }
    }

    func ended(_ arguments: [String: NativeJSONValue]) {
        guard case .string(let packet)? = arguments["packet"] else { return }
        lock.withLock { finishes.append(packet) }
    }

    func clear() {
        lock.withLock {
            entries = []
            finishes = []
        }
    }
}

final class NativeToolExtensionModel: @unchecked Sendable {
    private let lock = NSLock()
    private var offered: [[String]] = []
    let rounds: [[NativeTaskGenerationToolCall]]

    init(rounds: [[NativeTaskGenerationToolCall]]) {
        self.rounds = rounds
    }

    var offeredNames: [[String]] { lock.withLock { offered } }

    func complete(_ messages: [NativeTaskGenerationMessage], _ tools: [NativeTaskGenerationTool]?) -> NativeTaskGenerationCompletion {
        if messages.first?.content == NativeCompanionShape.classifierPrompt { return .text("{\"keep\": false}") }
        lock.withLock { offered.append(tools?.map(\.name) ?? []) }
        let replied = messages.filter { $0.role == "assistant" && $0.toolCalls != nil }.count
        guard rounds.indices.contains(replied) else { return .text("The shelves are checked.") }
        return NativeTaskGenerationCompletion(content: "", toolCalls: rounds[replied], finishReason: "tool_calls")
    }
}

@MainActor
extension SelfTest {
    private static let extensionInputs: NativeJSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([.string("packet")]),
        "properties": .object([
            "packet": .object(["type": .string("string"), "minLength": .number(1),
                               "description": .string("The seed packet to find, as written on its label.")]),
            "count": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(99),
                              "description": .string("How many packets are wanted.")]),
            "tags": .object(["type": .string("array"), "maxItems": .number(4), "items": .object(["type": .string("string"), "minLength": .number(1)]),
                             "description": .string("Labels that narrow the shelf.")]),
            "wait": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(1000),
                             "description": .string("Milliseconds the lookup takes in this fixture.")]),
        ]),
    ])

    private static func extensionShelf(_ log: NativeToolExtensionLog, name: String = "shelf_lookup", id: String = "extension-shelf",
                                       description: String = "Reads which greenhouse shelf holds a seed packet. When to use: the person asks where a packet is kept.") -> NativeToolDefinition {
        NativeToolDefinition(
            id: id, name: name, title: "Look up a shelf", description: description,
            parameters: extensionInputs, confirmation: .none, timeout: .seconds(5), effect: .read, isAvailable: { true },
            execute: { arguments in
                log.started(arguments)
                if case .number(let wait)? = arguments["wait"], wait > 0 {
                    try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
                }
                log.ended(arguments)
                return .object(["echo": .object(arguments), "shelf": .string("B3")])
            })
    }

    private static func extensionEcho(_ arguments: [String: NativeJSONValue]) -> NativeJSONValue {
        .object(["echo": .object(arguments), "shelf": .string("B3")])
    }

    private static func extensionParsed(_ text: String?) -> NativeJSONValue? {
        guard let text, let data = text.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return try? NativeJSONValue(any: any)
    }

    private static func extensionResults(_ transport: ScriptedNativeToolTransport) -> [String: String] {
        var found: [String: String] = [:]
        for message in transport.histories.last ?? [] where message.role == "tool" {
            if let id = message.toolCallID { found[id] = message.content }
        }
        return found
    }

    static func runNativeToolExtension() async throws {
        let require = NativeTaskFixture.require
        let summary = [
            try await extensionReadFixture(),
            try await extensionWriteFixture(),
            try await extensionChatIdentity(),
            try await extensionHandedOffIdentity(),
            try extensionAdapter(),
        ]
        try require(summary.allSatisfy { !$0.isEmpty }, "Every extension check reports what it covered")
        print("  native tool extension OK (\(summary.joined(separator: "; ")))")
    }

    private static func extensionReadFixture() async throws -> String {
        let require = NativeTaskFixture.require
        let log = NativeToolExtensionLog()
        let shelf = extensionShelf(log)
        let registry = NativeToolRegistry(definitions: [shelf])
        try require(registry.issues.isEmpty && registry.definitions.map(\.name) == ["shelf_lookup"],
                    "The new read tool passes the registry with nothing else registered")
        let arguments = #"{"packet":"Beans","count":2}"#
        let (final, transport) = try await NativeWebToolsSelftest.loop(
            registry, rounds: [NativeWebToolsSelftest.call("call-shelf", "shelf_lookup", arguments), NativeWebToolsSelftest.reply("Shelf B3.")],
            enabled: [shelf.id], prompt: "Where are the beans?")
        try require(transport.schemas.first?.map(\.name) == ["shelf_lookup"],
                    "The new read tool is offered from its definition alone, with nothing else registered")
        try require(log.all == [NativeToolExtensionLog.Entry(call: "call-shelf", arguments: ["packet": .string("Beans"), "count": .number(2)])],
                    "The handler of the new read tool runs once with the validated arguments, with nothing else registered: \(log.all)")
        let activity = final?.activities.first
        try require(final?.activities.count == 1 && activity?.id == "call-shelf" && activity?.state == .succeeded
                    && activity?.toolID == shelf.id && activity?.title == shelf.title,
                    "The call to the new read tool is matched and succeeds, with nothing else registered")
        try require(extensionParsed(extensionResults(transport)["call-shelf"]) == extensionEcho(["packet": .string("Beans"), "count": .number(2)]),
                    "The result of the new read tool comes back tied to its call, with nothing else registered")
        try require(final?.content == "Shelf B3.", "The reply after the new read tool is the model's answer")

        log.clear()
        let (missing, missingTransport) = try await NativeWebToolsSelftest.loop(
            registry, rounds: [NativeWebToolsSelftest.call("call-missing", "shelf_missing", arguments), NativeWebToolsSelftest.reply("No shelf.")],
            enabled: [shelf.id])
        let refusal = extensionParsed(extensionResults(missingTransport)["call-missing"])
        try require(log.all.isEmpty && missing?.activities.first?.state == .failed
                    && refusal == .object(["error": .string(NativeToolError.unavailable.localizedDescription)]),
                    "A call to a name that was never registered is refused as not available and runs nothing: \(String(describing: refusal))")

        log.clear()
        let (wrong, wrongTransport) = try await NativeWebToolsSelftest.loop(
            registry, rounds: [NativeWebToolsSelftest.call("call-wrong", "shelf_lookup", #"{"count":2}"#), NativeWebToolsSelftest.reply("No shelf.")],
            enabled: [shelf.id])
        try require(log.all.isEmpty && wrong?.activities.first?.state == .failed
                    && extensionResults(wrongTransport)["call-wrong"]?.contains("Missing required field 'packet'") == true,
                    "A call without its required input is refused by the declared schema before the handler runs")
        return "a read tool added as one definition and one handler is offered, matched, validated, run and answered by call id; unknown names and bad inputs are refused"
    }

    private static func extensionWriteFixture() async throws -> String {
        let require = NativeTaskFixture.require
        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
        let callRound = [NativeChatStreamSnapshot(content: "", toolCalls: [
            NativeChatToolCall(id: "call-label", name: "label_shelf", arguments: #"{"label":"Early beans"}"#),
        ], finishReason: "tool_calls")]
        let doneRound = [NativeChatStreamSnapshot(content: "Labelled.", toolCalls: [], finishReason: "stop")]
        func ruledStore(_ choice: NativeRuleChoice, counter: NativeChatRulesCounter) async -> ChatStore {
            let label = NativeToolDefinition(
                id: "extension-label", name: "label_shelf", title: "Label a shelf",
                description: "Prints a label for a greenhouse shelf. When to use: the person asks for a shelf to be labelled.",
                parameters: .object(["type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("label")]),
                                     "properties": .object(["label": .object(["type": .string("string"), "minLength": .number(1),
                                                                              "description": .string("The text to print.")])])]),
                confirmation: .none, effect: .write, action: .networkSends, isAvailable: { true },
                execute: { _ in counter.hit(); return .object(["printed": .bool(true)]) })
            var rules = NativeRules.defaults
            rules.set(choice, for: .networkSends)
            let store = ChatStore(nativeConfig: config, nativeTransport: ScriptedNativeToolTransport(rounds: [callRound, doneRound]),
                                  repository: try! LocalChatRepository(inMemory: true), nativeEnabledToolIDs: [label.id], nativeRules: rules,
                                  nativeToolRegistry: NativeToolRegistry(definitions: [label]), artifactPersistenceEnabled: false)
            await store.connect()
            store.newConversation()
            return store
        }
        func settle(_ store: ChatStore) async throws -> Bool {
            var sawCard = false
            for _ in 0..<6_000 {
                if !store.turnConfirmations.isEmpty { sawCard = true }
                if let reply = store.selected?.messages.last, reply.role == .assistant,
                   reply.state == .complete || reply.state == .interrupted,
                   store.turnExecutions.isEmpty, !store.generating {
                    return sawCard
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if sawCard { return true }
            throw NativeTaskFixture.Failure.assertion("The labelling turn never finished")
        }

        let asked = NativeChatRulesCounter()
        let asking = await ruledStore(.ask, counter: asked)
        asking.sendText("Label the bean shelf")
        var waited = 0
        while asking.turnConfirmations.isEmpty && waited < 500 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        guard let (messageID, card) = asking.turnConfirmations.first.map({ ($0.key, $0.value) }) else {
            throw NativeTaskFixture.Failure.assertion("A write tool added with its policy shows a card when its kind is set to ask")
        }
        try require(card.id == "call-label" && card.subject?.governed == true && card.subject?.action == .networkSends,
                    "The card belongs to the labelling call and names its kind")
        try require(asked.count == 0, "The labelling handler waits for the card")
        asking.resolveTurnConfirmation(messageID, decision: .allowOnce, requestID: card.id, token: asking.turnConfirmationTokens[messageID])
        _ = try await settle(asking)
        let approved = asking.selected?.messages.last?.toolActivities.first
        try require(asked.count == 1 && approved?.id == "call-label" && approved?.state == .succeeded,
                    "Once approved, the labelling handler runs once for its call")

        let handed = NativeChatRulesCounter()
        let handing = await ruledStore(.handOff, counter: handed)
        handing.sendText("Label the bean shelf")
        let handedCard = try await settle(handing)
        try require(!handedCard && handed.count == 0 && handing.selected?.messages.last?.toolActivities.first?.state == .failed,
                    "With its kind handed off, the labelling handler never runs and no card is shown")

        let acted = NativeChatRulesCounter()
        let acting = await ruledStore(.act, counter: acted)
        acting.sendText("Label the bean shelf")
        let actedCard = try await settle(acting)
        try require(!actedCard && acted.count == 1 && acting.selected?.messages.last?.toolActivities.first?.state == .succeeded,
                    "With its kind allowed, the labelling handler runs with no card")
        return "a write tool with its policy asks and runs only after approval, never runs when handed off, and runs when allowed"
    }

    private static func extensionChatIdentity() async throws -> String {
        let require = NativeTaskFixture.require
        let log = NativeToolExtensionLog()
        let shelf = extensionShelf(log)
        let registry = NativeToolRegistry(definitions: [shelf])

        let (simple, simpleTransport) = try await NativeWebToolsSelftest.loop(
            registry, rounds: [NativeWebToolsSelftest.call("chat-simple", "shelf_lookup", #"{"packet":"Peas"}"#), NativeWebToolsSelftest.reply("Shelf B3.")],
            enabled: [shelf.id])
        try require(log.all == [NativeToolExtensionLog.Entry(call: "chat-simple", arguments: ["packet": .string("Peas")])]
                    && simple?.activities.map(\.id) == ["chat-simple"]
                    && extensionParsed(extensionResults(simpleTransport)["chat-simple"]) == extensionEcho(["packet": .string("Peas")]),
                    "A simple chat call reaches its handler unchanged and its result carries its own call id")

        log.clear()
        let events = [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"chat-split","type":"function","function":{"name":"shelf_","arguments":"{\"packet\":\"Run"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"chat-split-two","type":"function","function":{"name":"shelf_lookup","arguments":"{\"packet\":\"Kale\","}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"lookup","arguments":"ner beans, early\",\"count\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\"tags\":[\"winter\"]}"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"12,\"tags\":[\"climbing\",\"tall\"]}"}}]},"finish_reason":"tool_calls"}]}"#,
        ]
        let raw = Data((events.map { "data: " + $0 + "\n\n" }.joined() + "data: [DONE]\n\n").utf8)
        var decoder = ChatSSEDecoder()
        var accumulator = NativeChatDeltaAccumulator()
        var streamed: [NativeChatStreamSnapshot] = []
        var finished = false
        var offset = 0
        while offset < raw.count {
            let next = min(offset + 37, raw.count)
            for payload in try decoder.feed(raw.subdata(in: offset..<next), finishing: next == raw.count) {
                if payload == "[DONE]" { finished = true; continue }
                streamed.append(try accumulator.consume(payload))
            }
            offset = next
        }
        let first: [String: NativeJSONValue] = ["packet": .string("Runner beans, early"), "count": .number(12),
                                                "tags": .array([.string("climbing"), .string("tall")])]
        let second: [String: NativeJSONValue] = ["packet": .string("Kale"), "tags": .array([.string("winter")])]
        try require(finished && streamed.count == events.count && streamed.last?.finishReason == "tool_calls"
                    && streamed.last?.toolCalls.map(\.id) == ["chat-split", "chat-split-two"]
                    && streamed.last?.toolCalls.map(\.name) == ["shelf_lookup", "shelf_lookup"],
                    "The client's own stream parsing rebuilds two interleaved calls from fragments cut at arbitrary bytes")
        let (split, splitTransport) = try await NativeWebToolsSelftest.loop(
            registry, rounds: [streamed, NativeWebToolsSelftest.reply("Both are on B3.")], enabled: [shelf.id])
        let splitResults = extensionResults(splitTransport)
        try require(log.all == [NativeToolExtensionLog.Entry(call: "chat-split", arguments: first),
                                NativeToolExtensionLog.Entry(call: "chat-split-two", arguments: second)],
                    "Several inputs split across fragments reach each handler exactly as sent: \(log.all)")
        try require(split?.activities.map(\.id) == ["chat-split", "chat-split-two"]
                    && extensionParsed(splitResults["chat-split"]) == extensionEcho(first)
                    && extensionParsed(splitResults["chat-split-two"]) == extensionEcho(second),
                    "Each reassembled call gets its own result under its own call id")

        log.clear()
        let slow: [String: NativeJSONValue] = ["packet": .string("Squash"), "wait": .number(250)]
        let quick: [String: NativeJSONValue] = ["packet": .string("Chard"), "wait": .number(0)]
        let pair = [NativeChatStreamSnapshot(content: "", toolCalls: [
            NativeChatToolCall(id: "chat-slow", name: "shelf_lookup", arguments: #"{"packet":"Squash","wait":250}"#),
            NativeChatToolCall(id: "chat-quick", name: "shelf_lookup", arguments: #"{"packet":"Chard","wait":0}"#),
        ], finishReason: "tool_calls")]
        let (both, bothTransport) = try await NativeWebToolsSelftest.loop(
            registry, rounds: [pair, NativeWebToolsSelftest.reply("Squash and chard are on B3.")], enabled: [shelf.id])
        let bothResults = extensionResults(bothTransport)
        let assistant = bothTransport.histories.last?.first { $0.role == "assistant" && !$0.toolCalls.isEmpty }
        try require(log.all == [NativeToolExtensionLog.Entry(call: "chat-slow", arguments: slow),
                                NativeToolExtensionLog.Entry(call: "chat-quick", arguments: quick)]
                    && log.finished == ["Squash", "Chard"],
                    "Two calls in one round each run with their own id and inputs; the chat runs them one after another")
        try require(both?.activities.map(\.id) == ["chat-slow", "chat-quick"] && both?.activities.allSatisfy { $0.state == .succeeded } == true
                    && assistant?.toolCalls.map(\.id) == ["chat-slow", "chat-quick"]
                    && extensionParsed(bothResults["chat-slow"]) == extensionEcho(slow)
                    && extensionParsed(bothResults["chat-quick"]) == extensionEcho(quick),
                    "The slower and the quicker call each answer under their own call id with their own content")

        log.clear()
        let long: [String: NativeJSONValue] = ["packet": .string("Leeks"), "wait": .number(600)]
        let began = Date()
        let (lasting, lastingTransport) = try await NativeWebToolsSelftest.loop(
            registry, rounds: [NativeWebToolsSelftest.call("chat-long", "shelf_lookup", #"{"packet":"Leeks","wait":600}"#),
                               NativeWebToolsSelftest.reply("Leeks are on B3.")],
            enabled: [shelf.id])
        try require(Date().timeIntervalSince(began) >= 0.6 && log.all == [NativeToolExtensionLog.Entry(call: "chat-long", arguments: long)]
                    && lasting?.activities.first?.id == "chat-long" && lasting?.activities.first?.state == .succeeded
                    && extensionParsed(extensionResults(lastingTransport)["chat-long"]) == extensionEcho(long),
                    "A call that takes over half a second finishes inside its deadline and answers under its own call id")
        return "chat calls keep their ids for a simple call, inputs split across stream fragments, two calls in one round and a long call"
    }

    private static func extensionHandedOffIdentity() async throws -> String {
        let require = NativeTaskFixture.require
        let log = NativeToolExtensionLog()
        let shelf = extensionShelf(log)
        let wordy = extensionShelf(log, name: "shelf_wordy", id: "extension-wordy",
                                   description: String(repeating: "Reads a shelf. ", count: 300))
        try require(wordy.description.utf8.count > NativeTaskGenerationJob.maximumToolDescriptionBytes,
                    "The wordy fixture is longer than handed-off work can carry")
        let call = { (id: String, name: String, arguments: String) in NativeTaskGenerationToolCall(id: id, name: name, arguments: arguments) }
        let model = NativeToolExtensionModel(rounds: [
            [call("work-simple", "shelf_lookup", #"{"packet":"Peas"}"#)],
            [call("work-slow", "shelf_lookup", #"{"packet":"Runner beans, early","count":12,"tags":["climbing","tall"],"wait":300}"#),
             call("work-several", "shelf_lookup", #"{"packet":"Kale","tags":["winter"]}"#)],
            [call("work-wordy", "shelf_wordy", #"{"packet":"Onions"}"#)],
        ])
        let rig = try NativeCompanionFinishRig(tools: [shelf, wordy], model: .looping())
        _ = try rig.create("Find where the seed packets are kept")
        var record: NativeTaskRecord?
        for _ in 0..<20 {
            guard let claimed = try rig.store.claim(workerTypes: ["companion"]) else {
                throw NativeTaskFixture.Failure.assertion("The handed-off work is queued")
            }
            let step = try await NativeCompanionWorker.step(claimed, environment: rig.environment) { _, _, _, messages, tools, _ in
                model.complete(messages, tools)
            }
            let committed = try rig.store.commitStep(claimed.id, generation: claimed.generation, step: step)
            if committed.state != .queued { record = committed; break }
        }
        guard let record else { throw NativeTaskFixture.Failure.assertion("The handed-off work settles") }
        let saved = try rig.checkpoint(record)
        var results: [String: String] = [:]
        for message in saved.transcript where message.role == "tool" {
            if let id = message.toolCallID { results[id] = message.content }
        }
        try require(record.state == .completed && NativeCompanionFinishRig.answeredOnce(saved),
                    "The handed-off work completes and answers every call once")
        try require(!model.offeredNames.isEmpty && model.offeredNames.allSatisfy { $0 == ["shelf_lookup"] },
                    "Handed-off work offers the shelf tool and withholds the one its limits cannot carry: \(model.offeredNames)")
        let simple: [String: NativeJSONValue] = ["packet": .string("Peas")]
        let slow: [String: NativeJSONValue] = ["packet": .string("Runner beans, early"), "count": .number(12),
                                               "tags": .array([.string("climbing"), .string("tall")]), "wait": .number(300)]
        let several: [String: NativeJSONValue] = ["packet": .string("Kale"), "tags": .array([.string("winter")])]
        try require(log.all.map(\.arguments) == [simple, slow, several] && log.finished == ["Peas", "Runner beans, early", "Kale"],
                    "Each handed-off call reaches the handler with its inputs unchanged: \(log.all)")
        try require(extensionParsed(results["work-simple"]) == extensionEcho(simple)
                    && extensionParsed(results["work-slow"]) == extensionEcho(slow)
                    && extensionParsed(results["work-several"]) == extensionEcho(several),
                    "Each handed-off result sits under its own call id with its own content")
        try require(extensionParsed(results["work-wordy"]) == .object(["error": .string("Unknown tool. Use only the tools offered.")])
                    && !log.finished.contains("Onions"),
                    "A call to a withheld tool is refused and its handler never runs")
        return "handed-off work keeps call ids for a simple call, a several-input call and a slower call, and a withheld tool cannot be called"
    }

    private static func extensionAdapter() throws -> String {
        let require = NativeTaskFixture.require
        let log = NativeToolExtensionLog()
        let shelf = extensionShelf(log)
        let wordy = extensionShelf(log, name: "shelf_wordy", id: "extension-wordy",
                                   description: String(repeating: "Reads a shelf. ", count: 300))
        try require(NativeToolAdapter.unsupported(wordy, for: .handedOffWork) == .descriptionTooLong,
                    "A description over the handed-off limit is named as too long")
        try require(NativeToolAdapter.unsupported(wordy, for: .chat) == nil && NativeToolAdapter.unsupported(shelf, for: .handedOffWork) == nil,
                    "Chat carries the long description and handed-off work carries the ordinary one")
        let handed = NativeToolAdapter.offered([shelf, wordy], for: .handedOffWork)
        try require(handed.schemas.map(\.name) == ["shelf_lookup"] && handed.withheld == [NativeToolIssue(name: "shelf_wordy", reason: .descriptionTooLong)],
                    "Handed-off work withholds the long description and reports it")
        let chatted = NativeToolAdapter.offered([shelf, wordy], for: .chat)
        try require(chatted.schemas.map(\.name) == ["shelf_lookup", "shelf_wordy"] && chatted.withheld.isEmpty, "Chat offers both")
        try require(NativeToolAdapter.unsupported(extensionShelf(log, name: "shelf lookup"), for: .handedOffWork) == .invalidName,
                    "A name handed-off work cannot carry is named")

        let twin = extensionShelf(log, id: "extension-twin")
        for transport in [NativeToolTransport.chat, .handedOffWork] {
            let carried = NativeToolAdapter.carried([shelf, twin], for: transport)
            try require(carried.definitions.map(\.id) == ["extension-shelf"]
                        && carried.withheld == [NativeToolIssue(name: "shelf_lookup", reason: .duplicateName)],
                        "With two tools of one name, the first is offered and the second is reported: \(transport)")
        }

        let limit = NativeTaskGenerationJob.maximumTools
        let many = (0..<(limit + 6)).map { extensionShelf(log, name: "shelf_row_\($0)", id: "extension-row-\($0)") }
        let capped = NativeToolAdapter.offered(many, for: .handedOffWork)
        try require(capped.schemas.count == limit && capped.schemas.map(\.name) == many.prefix(limit).map(\.name),
                    "Handed-off work offers the first \(limit) tools")
        try require(capped.withheld == many.dropFirst(limit).map { NativeToolIssue(name: $0.name, reason: .tooManyTools) },
                    "Handed-off work reports each tool past its limit")
        try require(NativeToolAdapter.offered(many, for: .chat).schemas.count == many.count, "Chat has no tool count limit of its own")
        let opening = [NativeTaskGenerationMessage(role: "user", content: "Find the seed packets")]
        try require(NativeTaskGenerationJob.validShape(opening, tools: capped.schemas, toolChoice: "auto", budget: .dot)
                    && !NativeTaskGenerationJob.validShape(opening, tools: many.map(\.schema), toolChoice: "auto", budget: .dot),
                    "What handed-off work offers fits its request shape, while the whole list would not")

        var described = extensionShelf(log)
        described.outputSchema = .object(["type": .string("object"), "properties": .object(["shelf": .object(["type": .string("string")])])])
        described.examples = [["packet": .string("Beans")]]
        try require(NativeToolRegistry.rejection(described) == nil, "The described fixture passes the registry")
        let schema = NativeToolAdapter.schema(described)
        try require(schema == NativeToolSchema(name: described.name, description: described.description, parameters: described.parameters)
                    && described.schema == schema, "The schema carries the name, description and inputs only")
        let function = (schema.requestObject["function"] as? [String: Any]).map { Set($0.keys) } ?? []
        try require(Set(schema.requestObject.keys) == ["type", "function"] && function == ["name", "description", "parameters"],
                    "The chat tool object has exactly a name, description and inputs: \(function.sorted())")
        let client = NativeChatClient(config: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
                                                               model: "local-model", chatTemplateKwargs: nil))
        let request = try client.request(messages: [NativeChatMessage(role: "user", content: "Where are the beans?")], model: "local-model",
                                         tools: [schema])
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let sent = ((body?["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any]).map { Set($0.keys) }
        try require(sent == ["name", "description", "parameters"], "The chat request sends exactly a name, description and inputs")
        let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(schema)) as? [String: Any]
        try require(encoded.map { Set($0.keys) } == ["name", "description", "parameters"],
                    "The handed-off tool entry has exactly a name, description and inputs")
        return "the adapter withholds what handed-off work cannot carry, keeps the first of two names, caps the count, and sends only name, description and inputs"
    }
}
