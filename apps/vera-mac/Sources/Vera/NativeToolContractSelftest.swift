import Foundation

@MainActor
extension SelfTest {
    private static func contractTool(_ name: String, id: String = "contract-fixture", description: String = "Read the garden status.",
                                     parameters: NativeJSONValue = .object(["type": .string("object"), "properties": .object([:]),
                                                                            "additionalProperties": .bool(false)]),
                                     outputSchema: NativeJSONValue? = nil,
                                     examples: [[String: NativeJSONValue]] = []) -> NativeToolDefinition {
        var definition = NativeToolDefinition(id: id, name: name, title: "Garden status", description: description, parameters: parameters,
                                              confirmation: .none, effect: .read, isAvailable: { true }, execute: { _ in .object([:]) })
        definition.outputSchema = outputSchema
        definition.examples = examples
        return definition
    }

    static func runNativeToolContract() async throws {
        let require = NativeTaskFixture.require

        let good = contractTool("garden_status")
        try require(NativeToolRegistry.rejection(good) == nil, "A well-formed read tool passes the registry check")
        let single = NativeToolRegistry(definitions: [good])
        try require(single.definitions.count == 1 && single.issues.isEmpty, "A well-formed read tool is kept and no issue is reported for it")

        let first = contractTool("garden_status", id: "contract-first")
        let second = contractTool("garden_status", id: "contract-second")
        let twice = NativeToolRegistry(definitions: [first, second])
        try require(twice.definitions.map(\.id) == ["contract-first"], "When two tools share a name, the first one is kept")
        try require(twice.issues == [NativeToolIssue(name: "garden_status", reason: .duplicateName)],
                    "When two tools share a name, the second one is reported as a duplicate")
        try require(twice.active(enabledIDs: ["contract-first", "contract-second"]).map(\.id) == ["contract-first"],
                    "Only one tool with a shared name is ever offered")
        try require(NativeToolRegistry.rejection(second, taken: ["garden_status"]) == .duplicateName,
                    "A name already taken is rejected as a duplicate")

        let longest = "garden_status-0123456789" + String(repeating: "x", count: 40)
        try require(longest.utf8.count == NativeToolRegistry.maximumNameBytes, "The longest fixture name is exactly 64 bytes")
        let badNames: [(String, String)] = [
            ("garden status", "A name with a space"),
            ("", "An empty name"),
            (longest + "x", "A name of 65 bytes"),
            ("g\u{E4}rden_status", "A name with a non-ASCII letter"),
        ]
        for (name, label) in badNames {
            try require(NativeToolRegistry.rejection(contractTool(name)) == .invalidName, "\(label) is rejected as an invalid name")
        }
        let named = NativeToolRegistry(definitions: badNames.map { contractTool($0.0) })
        try require(named.definitions.isEmpty && named.issues.map(\.reason) == Array(repeating: NativeToolIssue.Reason.invalidName, count: badNames.count),
                    "The registry keeps none of the badly named tools and reports each one")
        try require(NativeToolRegistry.rejection(contractTool(longest)) == nil,
                    "A 64-byte name of letters, digits, underscore and hyphen is accepted")

        try require(NativeToolRegistry.rejection(contractTool("garden_status", description: "  \n ")) == .emptyDescription,
                    "A tool with a blank description is rejected")

        let arrayRoot: NativeJSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")])])
        let patterned: NativeJSONValue = .object(["type": .string("object"), "properties": .object([
            "code": .object(["type": .string("string"), "pattern": .string("^[a-z]+$")]),
        ])])
        let formatted: NativeJSONValue = .object(["type": .string("object"), "properties": .object([
            "when": .object(["type": .string("string"), "format": .string("date-time")]),
        ])])
        try require(NativeToolRegistry.rejection(contractTool("garden_status", parameters: arrayRoot)) == .unsupportedSchema,
                    "A schema whose root is not an object is rejected")
        try require(NativeToolRegistry.rejection(contractTool("garden_status", parameters: patterned)) == .unsupportedSchema,
                    "A schema using the pattern keyword is rejected")
        try require(NativeToolRegistry.rejection(contractTool("garden_status", parameters: formatted)) == .unsupportedSchema,
                    "A schema using the format keyword is rejected")

        let plainOutput: NativeJSONValue = .object(["type": .string("object"), "properties": .object([
            "status": .object(["type": .string("string")]),
        ]), "required": .array([.string("status")])])
        let formattedOutput: NativeJSONValue = .object(["type": .string("object"), "properties": .object([
            "link": .object(["type": .string("string"), "format": .string("uri")]),
        ])])
        try require(NativeToolRegistry.rejection(contractTool("garden_status", outputSchema: formattedOutput)) == .unsupportedOutputSchema,
                    "An output schema using an unsupported keyword is rejected")
        try require(NativeToolRegistry.rejection(contractTool("garden_status", outputSchema: plainOutput)) == nil,
                    "A supported output schema is accepted")

        let queried: NativeJSONValue = .object(["type": .string("object"), "properties": .object([
            "query": .object(["type": .string("string"), "minLength": .number(1)]),
        ]), "required": .array([.string("query")]), "additionalProperties": .bool(false)])
        try require(NativeToolRegistry.rejection(contractTool("garden_search", parameters: queried, examples: [["limit": .number(3)]])) == .invalidExample,
                    "An example that breaks the tool's own schema is rejected")
        try require(NativeToolRegistry.rejection(contractTool("garden_search", parameters: queried, examples: [["query": .string("tomatoes")]])) == nil,
                    "An example that fits the tool's schema is accepted")

        let declared: NativeJSONValue = .object([
            "type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("title")]),
            "properties": .object([
                "title": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(10)]),
                "mode": .object(["type": .string("string"), "enum": .array([.string("fast"), .string("slow")])]),
                "count": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(5)]),
                "urgent": .object(["type": .string("boolean")]),
                "tags": .object(["type": .string("array"), "maxItems": .number(2), "items": .object(["type": .string("string")])]),
            ]),
        ])
        let form = contractTool("garden_plan", parameters: declared)
        try require(NativeToolRegistry.rejection(form) == nil, "The validation fixture passes the registry check")
        func refusal(_ raw: String) -> String? {
            do {
                _ = try form.validatedArguments(raw)
                return nil
            } catch NativeToolError.invalidArguments(let message) {
                return message
            } catch {
                return "an unexpected error: \(error)"
            }
        }
        let parsed = try form.validatedArguments(#"{"title":"Plan","mode":"fast","count":3,"urgent":true,"tags":["seeds","soil"]}"#)
        let expected: [String: NativeJSONValue] = [
            "title": .string("Plan"), "mode": .string("fast"), "count": .number(3), "urgent": .bool(true),
            "tags": .array([.string("seeds"), .string("soil")]),
        ]
        try require(parsed == expected, "Arguments that fit the schema come back as the parsed values")
        let refused: [(raw: String, message: String, label: String)] = [
            (#"{"mode":"fast"}"#, "Missing required field 'title'", "Arguments without the required title are refused"),
            (#"{"title":"Plan","colour":"red"}"#, "Unknown field 'colour'", "A field the schema does not declare is refused"),
            (#"{"title":"Plan","mode":"medium"}"#, "Field 'mode' must be one of: fast, slow", "A mode outside its choices is refused"),
            (#"{"title":"Plan the beds"}"#, "Field 'title' must be at most 10 characters", "A title over 10 characters is refused"),
            (#"{"title":"Plan","count":0}"#, "Field 'count' must be at least 1", "A count below its minimum is refused"),
            (#"{"title":"Plan","count":6}"#, "Field 'count' must be at most 5", "A count above its maximum is refused"),
            (#"{"title":"Plan","count":1.5}"#, "Field 'count' must be a whole number", "A fractional count is refused"),
            (#"{"title":"Plan","urgent":"yes"}"#, "Field 'urgent' must be a boolean", "A string where a boolean belongs is refused"),
            (#"{"title":"Plan","tags":["a","b","c"]}"#, "Field 'tags' must have at most 2 items", "A list with too many items is refused"),
            (#"{"title":"Plan","tags":["a",3]}"#, "Field 'tags' has an item that does not match its schema", "A list holding a number among strings is refused"),
            (#"["Plan"]"#, "Expected a JSON object", "A JSON list in place of an object is refused"),
            ("not json", "Expected a JSON object", "Text that is not JSON is refused"),
            (#"{"title":""}"#, "Field 'title' must be a non-empty string", "An empty title is refused by its declared minimum length"),
        ]
        for item in refused {
            let message = refusal(item.raw)
            try require(message == item.message, "\(item.label) with the message \(item.message), not \(message ?? "no refusal")")
        }
        try require(refusal(#"{"title":"   "}"#) == nil,
                    "A title of spaces meets the declared minimum length, so the schema alone decides and the tool's own check handles blank text")

        var own = contractTool("garden_service", parameters: declared)
        own.argumentValidator = { values in
            guard values["probe"] == .string("ok") else { throw NativeToolError.invalidArguments("probe") }
        }
        let passed = try own.validatedArguments(#"{"probe":"ok"}"#)
        try require(passed == ["probe": .string("ok")],
                    "A tool with its own argument check accepts what that check accepts, even outside the advertised schema")
        var ownRefusal: NativeToolError?
        do { _ = try own.validatedArguments(#"{"probe":"no","title":"Plan"}"#) } catch let error as NativeToolError { ownRefusal = error }
        try require(ownRefusal == .invalidArguments("probe"),
                    "A tool with its own argument check refuses through that check, in that check's own words, not the advertised schema")

        let repository = try LocalChatRepository(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vera-selftest-tool-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = FolderGrant(id: "contract", path: "/Volumes/Notes/Greenhouse", name: "Greenhouse", bookmark: nil)
        let origin = NativeTaskOrigin(conversationID: "contract-conversation", userMessageID: UUID(), assistantMessageID: UUID())
        let service = NativeTaskHandoffService(repository: repository, configuredBase: { nil })
        let declarations = NativeCapabilityTools.bundled
        try require(declarations.count == 3, "The three bundled server tools load")

        var shipped: [NativeToolDefinition] = []
        shipped += NativeRemindersTools.definitions(service: SelfTestRemindersService())
        shipped += NativeWebTools.definitions(searchBase: { nil })
        shipped += NativeImageTools.definitions(base: { nil }, attachments: NativeAttachmentStore(directory: directory))
        shipped += NativeCapabilityTools.definitions(declarations, base: { nil })
        shipped += NativeFolderTools.definitions(grants: { [grant] }, ledger: NativeFileChangeLedger())
        shipped += NativeCommandTools.definitions(grants: { [grant] }, decision: .ask, reason: { _ in nil }, record: { _ in })
        shipped.append(NativeTaskTools.definition(service: service, origin: origin, profile: nil, didSave: { _ in }))
        shipped.append(NativeScheduleTools.definition(save: { _ in throw NativeToolError.unavailable }))

        let storeRepository = try LocalChatRepository(inMemory: true)
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: storeRepository,
                              nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
        await store.connect()
        store.nativeSchedulerLoop?.cancel()
        await store.nativeSchedulerLoop?.value
        store.nativeSchedulerLoop = nil
        defer { store.stopNativeTaskRecovery() }
        store.ensureVeraThread()
        guard let threadID = store.veraThreadID else { throw NativeTaskFixture.Failure.assertion("The companion thread exists") }
        let user = Message(role: .user, text: "Set the seed order aside.")
        let turn = NativeConversationTurn(id: UUID(), conversationID: threadID, userMessageID: user.id, assistantMessageID: UUID(),
            mode: .chat, profile: "", enabledToolIDs: [], persona: "Persona", userScope: "", instructions: "", grounding: [],
            memorySettings: store.nativeMemorySettings, createdAt: Date(), history: [NativeTurnHistoryMessage(user)])
        guard let profileTool = store.companionProfileTool(for: turn) else {
            throw NativeTaskFixture.Failure.assertion("The companion thread offers the profile tool")
        }
        shipped.append(profileTool)
        shipped += store.companionTalkTools(CompanionTalkControl(entries: []), turn: turn, typed: NativeTypedWords.none, capture: nil,
                                            answerer: { _, _ in false }, timeout: .seconds(1))

        let variants: [NativeToolDefinition] = [
            NativeTaskTools.definition(service: service, origin: origin, profile: nil,
                                       general: { _ in throw NativeToolError.unavailable }, didSave: { _ in }),
        ] + ChatStore.companionCommandDefinitions(grants: { [grant] })

        for definition in shipped + variants {
            let reason = NativeToolRegistry.rejection(definition)
            try require(reason == nil, "\(definition.name) passes the registry check, but it was rejected as \(reason?.rawValue ?? "")")
            try require(definition.schema.parameters == definition.parameters && definition.schema.name == definition.name,
                        "\(definition.name) advertises the same schema it is validated against")
        }
        let names = shipped.map(\.name)
        try require(Set(names).count == names.count, "Every shipped tool has its own name across all families: \(names.sorted())")
        let together = NativeToolRegistry(definitions: shipped)
        try require(together.issues.isEmpty && together.definitions.count == shipped.count,
                    "All shipped tools taken together are kept by the registry with no issue")
        try require(shipped.count == 27, "Every shipped tool family that can be built here was checked: \(shipped.count) tools")
        let undeclared: Set<String> = [NativeCompanionProfileTools.toolID]
        for definition in shipped {
            if !undeclared.contains(definition.id) {
                try require(definition.isDeclared,
                            "\(definition.name) is declared as a read with no action or a write that names its action. This proves the declaration, not that the handler's effect matches it")
            }
            if definition.confirmation == .required || definition.governed || definition.alwaysAsks {
                try require(definition.effect == .write, "\(definition.name) asks first or is governed by rules, so it is declared a write")
            }
            if let deadline = definition.timeout {
                try require(deadline >= .seconds(1) && deadline <= .seconds(300),
                            "\(definition.name) declares a deadline between 1 and 300 seconds, not \(deadline)")
            }
            for example in definition.examples {
                let raw = try NativeToolLoop.serializedResult(.object(example))
                do { _ = try definition.validatedArguments(raw) } catch {
                    throw NativeTaskFixture.Failure.assertion("\(definition.name) accepts its own declared example \(raw). Its handler is not run here, so this proves the inputs it advertises, not what it does with them")
                }
            }
        }

        let stems: [[String]] = [["ta", "sk"], ["back", "ground"], ["work", "er"], ["ag", "ent"], ["eng", "ine"]]
        var listed: Set<String> = ["ve" + "ra"]
        for stem in stems {
            listed.insert(stem.joined())
            listed.insert(stem.joined() + "s")
        }
        func words(_ text: String) -> [String] {
            var found: [String] = []
            var current = ""
            for character in text {
                if character.isLetter || character.isNumber || character == "_" {
                    current.append(character)
                } else if !current.isEmpty {
                    found.append(current.lowercased())
                    current = ""
                }
            }
            if !current.isEmpty { found.append(current.lowercased()) }
            return found
        }
        for definition in shipped {
            let text = definition.description
            try require(text.contains("When to use:"), "\(definition.name) says when to use it")
            try require(text.utf8.count <= 4096, "\(definition.name) keeps its description within 4096 bytes, not \(text.utf8.count)")
            let hits = words(text).filter { listed.contains($0) }
            try require(hits.isEmpty, "\(definition.name) describes itself in plain words, without \(hits)")
            try require(!text.contains("\u{2014}"), "\(definition.name) has no em dash in its description")
            guard case .object(let root) = definition.parameters else {
                throw NativeTaskFixture.Failure.assertion("\(definition.name) declares an object schema")
            }
            let properties: [String: NativeJSONValue]
            if case .object(let declared)? = root["properties"] { properties = declared } else { properties = [:] }
            for (key, property) in properties.sorted(by: { $0.key < $1.key }) {
                guard case .object(let fields) = property else {
                    throw NativeTaskFixture.Failure.assertion("\(definition.name) declares \(key) as an object")
                }
                var described = false
                if case .string(let note)? = fields["description"] {
                    described = !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                try require(described, "\(definition.name) explains its \(key) field")
                if fields["type"] == .string("string") {
                    try require(fields["minLength"] != nil, "\(definition.name) says whether its \(key) field may be empty")
                }
            }
        }

        let section = NativeContextAssembler.toolsSection(shipped)
        for definition in shipped {
            try require(!section.contains(definition.description), "The prompt's tool list leaves out the description of \(definition.name)")
            try require(section.contains("- \(definition.name) (\"\(NativeContextAssembler.plainName(for: definition))\")"),
                        "The prompt's tool list names \(definition.name) with its plain name")
        }
        try require(section.count < NativeContextAssembler.Caps.tools,
                    "The prompt's tool list for every shipped tool fits under its cap: \(section.count) characters")
        let composedKey = NativeToolSchemaCache.exactKey(.object(["enum": .array([.string("\u{E9}")])]))
        let decomposedKey = NativeToolSchemaCache.exactKey(.object(["enum": .array([.string("e\u{301}")])]))
        try require(composedKey != decomposedKey, "Two schemas that differ only in how an accented letter is written never share a validator")
        let flag: NativeJSONValue = .object(["type": .string("boolean")])
        let flagged = "{14:types7:boolean}"
        let described: NativeJSONValue = .object(["type": .string("boolean"), "description": .string(String(repeating: "x", count: 761))])
        let describedFlag = "{211:descriptions761:" + String(repeating: "x", count: 761) + "4:types7:boolean}"
        var eleven: [String: NativeJSONValue] = [String(repeating: "a", count: 110): described]
        for name in ["b", "c", "d", "e", "f", "g", "h", "i", "j", "k"] { eleven[name] = flag }
        let crafted = String(repeating: "a", count: 110) + describedFlag
            + ["b", "c", "d", "e", "f", "g", "h", "i", "j"].map { "1:" + $0 + flagged }.joined() + "1:k"
        try require(crafted.utf8.count == 1_110, "The crafted field name is the length that made two schemas collide before")
        func wrapped(_ properties: [String: NativeJSONValue]) -> NativeJSONValue {
            .object(["type": .string("object"), "properties": .object(properties), "required": .array([]), "additionalProperties": .bool(false)])
        }
        let manyFields = wrapped(eleven)
        let oneField = wrapped([crafted: flag])
        try require(NativeToolSchemaCache.exactKey(manyFields) != NativeToolSchemaCache.exactKey(oneField),
                    "Two schemas built to collide when a count ran into a key length never share a key")
        let manyValidator = NativeToolSchemaCache.shared.validator(manyFields)
        let oneValidator = NativeToolSchemaCache.shared.validator(oneField)
        try require(manyValidator?.violation(.object(["b": .bool(true)])) == nil && oneValidator?.violation(.object(["b": .bool(true)])) != nil,
                    "Each of the two schemas gets its own validator, so a field one forbids is refused by it")
        let composed = NativeToolSchemaCache.shared.validator(.object(["type": .string("string"), "enum": .array([.string("\u{E9}")])]))
        let decomposed = NativeToolSchemaCache.shared.validator(.object(["type": .string("string"), "enum": .array([.string("e\u{301}")])]))
        try require(composed?.violation(.string("\u{E9}")) == nil && decomposed?.violation(.string("e\u{301}")) == nil
                    && composed?.violation(.string("e\u{301}")) != nil && decomposed?.violation(.string("\u{E9}")) != nil,
                    "Each schema accepts exactly its own spelling of an accented value")
        print("  native tool contract OK (registry rules, schema-declared validation messages, \(shipped.count) shipped tools and \(variants.count) variants pass the registry, every shipped description says when to use it in plain words within 4096 bytes, every field is explained and says whether it may be empty, and the prompt lists tools by name only within its cap)")
    }
}
