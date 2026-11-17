import Foundation

@MainActor
extension SelfTest {
    static func runInstructions() async throws {
        let require = NativeTaskFixture.require
        let chat = "instruction-chat"
        let address = "ana@greenhouse.test"
        let told = "Send the notes to \(address)"
        func target(_ kind: NativeRuleTargetKind, _ value: String) throws -> NativeRuleTarget {
            guard let made = NativeRuleTarget.make(kind, value) else { throw NativeTaskFixture.Failure.assertion("fixture target \(value)") }
            return made
        }
        let ana = try target(.recipient, address)
        let bo = try target(.recipient, "bo@greenhouse.test")
        func rules(_ choice: NativeRuleChoice, for action: NativeActionClass = .networkSends, base: NativeRules = .defaults) -> NativeRules {
            var made = base
            made.set(choice, for: action)
            return made
        }
        func resolver(_ global: NativeRules = rules(.ask), typed: NativeTypedWords, claim: NativeInstructionClaim? = NativeInstructionClaim(),
                      targets: [NativeRuleTarget], uses: NativeInstructionUses? = nil, tool: String = "fixture-notes") -> NativeRuleResolver {
            var made = NativeRuleResolver(global: global, conversation: NativeConversationRules(), requestText: typed.said)
            made.typed = typed
            made.asked = claim
            made.uses = uses
            return made.tool(tool, targets: targets)
        }

        try require(NativeInstruction.canonical("  make   pdf ") == "make pdf" && NativeInstruction.canonical("") == "",
                    "A command is compared with its spacing collapsed")
        let spacedRun = NativeTypedWords(typed: "Run `make pdf`")
        let runUses = NativeInstructionUses()
        let tight = resolver(rules(.ask, for: .commands), typed: spacedRun, targets: [], uses: runUses, tool: NativeCommandTools.toolID)
        let tightQuery = tight.query(for: .commands, command: "make pdf")
        let wideQuery = tight.query(for: .commands, command: "make  pdf")
        guard let tightSignature = tight.instructed(tightQuery, honoringLimitedUse: false) else {
            throw NativeTaskFixture.Failure.assertion("A typed plain command is eligible")
        }
        try require(tight.instructed(wideQuery, honoringLimitedUse: false) == tightSignature, "Extra spaces in a command do not make it a different use")
        runUses.take(tightSignature)
        try require(tight.instructed(wideQuery, honoringLimitedUse: false) == nil, "The same command with extra spaces is spent with the first run")
        try require(NativeInstruction.signature(action: .networkSends, toolID: "t", targets: [ana, bo], names: [])
                        == NativeInstruction.signature(action: .networkSends, toolID: "t", targets: [bo, ana], names: [])
                        && NativeInstruction.signature(action: .networkSends, toolID: "t", targets: [ana], names: [])
                        != NativeInstruction.signature(action: .networkSends, toolID: "u", targets: [ana], names: [])
                        && NativeInstruction.signature(action: .networkSends, toolID: "t", targets: [ana], names: [])
                        != NativeInstruction.signature(action: .trash, toolID: "t", targets: [ana], names: []),
                    "A signature names the action, the tool and the targets in any order")

        let typedTold = NativeTypedWords(typed: told)
        let shared = NativeInstructionUses()
        let first = resolver(typed: typedTold, targets: [ana], uses: shared)
        guard let signature = first.instructed(first.query(for: .networkSends), honoringLimitedUse: false) else {
            throw NativeTaskFixture.Failure.assertion("The typed send gives a signature")
        }
        try require(shared.take(signature) && !shared.take(signature), "A signature is spent once")
        try require(first.decision(for: .networkSends) == .ask, "The same send asks after it ran once")
        let refusing = NativeInstructionUses()
        let other = resolver(typed: typedTold, targets: [ana], uses: refusing)
        refusing.refuse(signature)
        try require(other.decision(for: .networkSends) == .ask, "A refused send asks without being checked again")
        let both = NativeTypedWords(typed: "Send the notes to \(address) and bo@greenhouse.test")
        try require(resolver(typed: both, targets: [], uses: NativeInstructionUses()).tool("fixture-notes", subjects: [[ana], [bo]])
                        .decision(for: .networkSends) == .act(.instruction),
                    "A message naming two addresses can cover one send to both")

        let sent = NativeChatRulesCounter()
        func sender(_ confirmation: NativeToolConfirmation) -> NativeToolDefinition {
            var made = NativeToolDefinition(id: "fixture-notes", name: "send_notes", title: "Send the notes", description: "Fixture",
                                            parameters: .object(["type": .string("object")]), confirmation: confirmation, effect: .write,
                                            action: .networkSends, isAvailable: { true },
                                            execute: { _ in sent.hit(); return .object(["sent": .bool(true)]) })
            made.ruleSubjects = { arguments in
                guard case .string(let to)? = arguments["to"], let target = NativeRuleTarget.make(.recipient, to) else { return [] }
                return [[target]]
            }
            made.authorizable = true
            return made
        }
        let source = NativeRuleSource()
        source.setGlobal(rules(.ask))
        let mail = sender(.none)
        let call: [String: NativeJSONValue] = ["to": .string(address)]
        let message = UUID()
        let request = try authorizationRequest(told, message: message, conversation: chat)
        let turnUses = NativeInstructionUses(messageID: message, conversationID: chat)
        let wrapped = ChatStore.ruled(mail, rules: source, store: nil, conversationID: chat, requestText: told, typed: typedTold, uses: turnUses)
        try require(wrapped.confirmationFor?(call) == false, "An eligible send shows no card before the check")
        guard let pending = wrapped.instructionFor?(call) else { throw NativeTaskFixture.Failure.assertion("The eligible send is offered for the check") }
        let decision = NativeAuthorizationDecision(.authorized, source: .model, request: request, action: pending.action)
        let sink = NativeToolReasonSink()
        _ = try await NativeToolCallContext.$confirmed.withValue(false) {
            try await NativeToolCallContext.$reason.withValue(sink) {
                try await NativeRequestAuthorizer.$cleared.withValue(decision) { try await wrapped.execute(call) }
            }
        }
        try require(sent.count == 1 && sink.value == .instruction, "It runs once without a card and reports why")
        try require(wrapped.confirmationFor?(call) == true, "The same send now needs the card")
        var again: String?
        do { _ = try await NativeToolCallContext.$confirmed.withValue(false) { try await wrapped.execute(call) } } catch { again = error.localizedDescription }
        try require(again != nil && sent.count == 1, "The same send never runs twice on one message")
        try require(wrapped.confirmationFor?(["to": .string("bo@greenhouse.test")]) == true, "A send to an address that wasn't typed needs the card")
        let strictWrapped = ChatStore.ruled(sender(.required), rules: source, store: nil, conversationID: chat, requestText: told, typed: typedTold,
                                            uses: NativeInstructionUses(messageID: message, conversationID: chat))
        try require(strictWrapped.confirmationFor?(call) == true && strictWrapped.instructionFor?(call) == nil, "A tool that always asks still asks")

        sent.reset()
        let loopTool = ChatStore.ruled(mail, rules: source, store: nil, conversationID: chat, requestText: told, typed: typedTold,
                                       uses: NativeInstructionUses(messageID: message, conversationID: chat))
        let arguments = "{\"to\":\"\(address)\"}"
        let transport = ScriptedNativeToolTransport(rounds: [
            [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: "first", name: "send_notes", arguments: arguments)],
                                      finishReason: "tool_calls")],
            [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: "second", name: "send_notes", arguments: arguments)],
                                      finishReason: "tool_calls")],
            [NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")],
        ])
        let script = NativeAuthorizationScript(.authorized)
        let loop = NativeToolLoop(transport: transport, registry: NativeToolRegistry(definitions: [loopTool]),
                                  confirm: { (_: NativeToolActivity) async -> Bool in false }, authorizer: script.authorizer(), request: request)
        var final: NativeToolTurnSnapshot?
        for try await snapshot in loop.stream(messages: [NativeChatMessage(role: "user", content: told)], model: "local-model",
                                              enabledToolIDs: ["fixture-notes"]) {
            final = snapshot
        }
        let steps = final?.activities ?? []
        try require(steps.count == 2 && steps[0].state == .succeeded && steps[0].ranBecause == .instruction
                        && steps[1].state == .failed && steps[1].ranBecause == nil && steps[1].confirmationRequired && sent.count == 1 && script.calls == 1,
                    "In a reply the first send runs and says why, the repeat asks with no second check: \(steps.map { ($0.state, $0.ranBecause as Any) })")

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("instructed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let grant = try FolderGrant.make(url: base)
        let commands = NativeRuleSource()
        commands.setGlobal(rules(.ask, for: .commands))
        let recorder = NativeCommandRunRecorder()
        let typedRun = "Run `echo hi`"
        let runMessage = UUID()
        let runUsesShared = NativeInstructionUses(messageID: runMessage, conversationID: chat)
        let live = ChatStore.commandLive(commands, store: nil, conversationID: chat, requestText: typedRun, typed: NativeTypedWords(typed: typedRun),
                                         uses: runUsesShared)
        let runner = NativeCommandTools.definitions(grants: { [grant] }, decision: .ask, reason: { _ in nil }, record: { recorder.add($0) },
                                                    live: live.live, liveTargets: live.liveTargets,
                                                    instruction: { command, action, subjects, call in
                                                        ChatStore.commandInstruction(commands, conversationID: chat, requestText: typedRun,
                                                                                     typed: NativeTypedWords(typed: typedRun), uses: runUsesShared,
                                                                                     command: command, action: action, subjects: subjects, call: call)
                                                    })
        let runTransport = ScriptedNativeToolTransport(rounds: [
            [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: "run", name: NativeCommandTools.runName,
                                                                                  arguments: "{\"command\":\"echo hi\"}")], finishReason: "tool_calls")],
            [NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")],
        ])
        let runLoop = NativeToolLoop(transport: runTransport, registry: NativeToolRegistry(definitions: runner),
                                     confirm: { (_: NativeToolActivity) async -> Bool in false },
                                     authorizer: NativeAuthorizationScript(.authorized).authorizer(),
                                     request: try authorizationRequest(typedRun, message: runMessage, conversation: chat))
        for try await _ in runLoop.stream(messages: [NativeChatMessage(role: "user", content: typedRun)], model: "local-model",
                                          enabledToolIDs: [NativeCommandTools.toolID]) {}
        let ran = recorder.recorded
        try require(ran.count == 1 && ran[0].outcome == .ran && ran[0].reason == .instruction
                        && ran[0].decisionLine == "Ran because you asked for this",
                    "A typed command runs without a card and its card says why: \(ran.map { ($0.outcome, $0.reason as Any) })")

        let folder = NativeRuleSource()
        folder.setGlobal(rules(.ask, for: .fileEdits, base: rules(.ask, for: .trash)))
        let notes = try target(.folder, base.path + "/notes.md")
        let old = try target(.folder, base.path + "/old.txt")
        func folderDecision(_ typed: String, _ action: NativeActionClass, _ file: NativeRuleTarget) -> NativeRuleDecision {
            ChatStore.folderDecision(folder, conversationID: chat, requestText: typed, typed: NativeTypedWords(typed: typed),
                                     uses: NativeInstructionUses(), action: action, subjects: [[file]]).decision
        }
        try require(folderDecision("Save this as notes.md", .fileEdits, notes) == .act(.instruction), "A typed save is eligible")
        try require(folderDecision("Delete old.txt", .trash, old) == .act(.instruction), "A typed delete is eligible")
        try require(folderDecision("Save \"notes.md\" with the summary", .fileEdits, notes) == .act(.instruction),
                    "Quote marks no longer decide anything on their own; the check reads them")
        try require(folderDecision("", .fileEdits, notes) == .ask, "With nothing typed a save asks")

        let plain = NativeToolActivity(id: "a1", toolID: "fixture-notes", name: "send_notes", title: "Send the notes", round: 0, request: "{}",
                                       result: "{}", state: .succeeded, confirmationRequired: false)
        let plainData = try JSONEncoder().encode(plain)
        try require(!String(decoding: plainData, as: UTF8.self).contains("ranBecause"), "An old saved step has no reason field")
        let decoded = try JSONDecoder().decode(NativeToolActivity.self, from: plainData)
        var marked = plain
        marked.ranBecause = .instruction
        let markedBack = try JSONDecoder().decode(NativeToolActivity.self, from: try JSONEncoder().encode(marked))
        try require(decoded == plain && decoded.ranBecause == nil && markedBack.ranBecause == .instruction,
                    "Old saved steps still load and the reason survives saving")
        try require(NativeRuleReason.instruction.title == "Ran because you asked for this", "The reason reads plainly")
        let earlier = NativeCommandRun(id: "r1", command: "make test", directory: "/tmp", outcome: .ran, reason: .rule, exitCode: 0)
        let earlierText = String(decoding: try JSONEncoder().encode(earlier), as: UTF8.self)
        let oldText = earlierText.replacingOccurrences(of: "\"reason\":\"rule\"", with: "\"reason\":\"request_preapproval\"")
        let oldRun = try JSONDecoder().decode(NativeCommandRun.self, from: Data(oldText.utf8))
        try require(oldText != earlierText && oldRun.reason == .requestPreapproval && oldRun.decisionLine == "Ran because your request pre-approved it",
                    "An old saved command step still loads and keeps its line: \(String(describing: oldRun.decisionLine))")

        print("  instructions OK (canonical commands, signatures, single use, refusals, ruled send, reply steps, command card reason, folder saves and deletes, old steps)")
    }
}
