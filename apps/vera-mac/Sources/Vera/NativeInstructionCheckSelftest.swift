import Foundation

final class NativeInstructionCheckAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [(said: String, about: String)] = []
    private let answer: Bool

    init(_ answer: Bool) { self.answer = answer }

    var count: Int { lock.withLock { asked.count } }
    var all: [(said: String, about: String)] { lock.withLock { asked } }

    var answerer: NativeInstructionAnswerer {
        { said, about in
            self.lock.withLock { self.asked.append((said, about)) }
            return self.answer
        }
    }
}

final class NativeInstructionCheckTransport: NativeChatTransport, @unchecked Sendable {
    enum Reply: Sendable {
        case text(String)
        case failure
        case silence
        case toolCall
    }

    private let lock = NSLock()
    private let reply: Reply
    private var seen: [[NativeChatMessage]] = []
    private var offered: [[NativeToolSchema]] = []

    init(_ reply: Reply) { self.reply = reply }

    var requests: [[NativeChatMessage]] { lock.withLock { seen } }
    var tools: [[NativeToolSchema]] { lock.withLock { offered } }

    func discoverModels() async throws -> [String] { ["local-model"] }

    func stream(messages: [NativeChatMessage], model: String, tools: [NativeToolSchema]) -> AsyncThrowingStream<NativeChatStreamSnapshot, Error> {
        lock.withLock {
            seen.append(messages)
            offered.append(tools)
        }
        let reply = self.reply
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch reply {
                case .text(let text):
                    continuation.yield(NativeChatStreamSnapshot(content: text, toolCalls: [], finishReason: "stop"))
                    continuation.finish()
                case .failure:
                    continuation.finish(throwing: NativeChatClient.ClientError.http(500, ""))
                case .silence:
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish()
                case .toolCall:
                    continuation.yield(NativeChatStreamSnapshot(content: "{\"run\": true}", toolCalls: [
                        NativeChatToolCall(id: "check", name: "send_notes", arguments: "{}"),
                    ], finishReason: "tool_calls"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
extension SelfTest {
    static func runInstructionCheck() async throws {
        let require = NativeTaskFixture.require
        try instructionCheckParser()
        try instructionCheckRequest()
        try await instructionCheckAsk()
        try await instructionCheckLoop()
        try await instructionCheckFolders()
        try await instructionCheckCommands()
        try await instructionCheckWorker()
        try await instructionCheckStore()
        try require(!NativeInstructionCheck.systemPrompt.contains("Ver" + "a") && !NativeInstructionCheck.systemPrompt.contains("\u{2014}"),
                    "The fixed question names no product and has no long dashes")
        print("  instruction check OK (strict parser, two part question, reply cap, ask errors and timeout, tool loop yes and no, refusal sticks, no answerer asks, folder writes, commands, worker yes, no, retry and scheduled, store)")
    }

    private static func instructionCheckParser() throws {
        let require = NativeTaskFixture.require
        let accepted = ["{\"run\": true}", "{\"run\":true}", "  {\"run\": true}\n", "<think>It says send.</think>{\"run\": true}",
                        "<think>\nhmm\n</think>\n\n{ \"run\" : true }"]
        for reply in accepted {
            try require(NativeInstructionCheck.parse(reply), "An exact yes counts: \(reply)")
        }
        let refused = ["{\"run\": false}", "{\"run\": true, \"why\": \"typed\"}", "{\"run\": 1}", "{\"run\": \"true\"}", "Sure. {\"run\": true}",
                       "{\"run\": true} because they asked", "", "   ", "[true]", "[{\"run\": true}]", "true", "yes",
                       "```json\n{\"run\": true}\n```", "Here you go:\n```json\n{\"run\": true}\n```", "{\"run\": true}{\"run\": true}",
                       "{\"run\": false, \"run\": true}", "{\"Run\": true}", "{\"run\": TRUE}", "<think>no close {\"run\": true}",
                       "{\"run\": true}</think>", "<think>a</think>{\"run\": false}</think>{\"run\": true}", "{\"\\u0072un\": true}", "{}",
                       "null", "{\"run\": null}"]
        for reply in refused {
            try require(!NativeInstructionCheck.parse(reply), "Anything but an exact yes is no: \(reply)")
        }
    }

    private static func instructionCheckRequest() throws {
        let require = NativeTaskFixture.require
        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model",
                                      chatTemplateKwargs: nil, options: NativeChatRequestOptions(
                                          topLevel: [.init(key: "max_tokens", value: .number(1024), source: .override),
                                                     .init(key: "reasoning_effort", value: .string("high"), source: .override)],
                                          kwargs: [.init(key: "enable_thinking", value: .bool(true), source: .override)],
                                          streamingOverride: nil, contextCeiling: nil))
        let client = NativeChatClient(config: config)
        let prompt = NativeInstructionCheck.messages(said: "Send the notes to ana@greenhouse.test", about: "Send the notes: ana@greenhouse.test.")
        func body(_ request: URLRequest) throws -> [String: Any] {
            guard let data = request.httpBody, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeTaskFixture.Failure.assertion("The request has a JSON body")
            }
            return object
        }
        let quick = try body(try client.briefly(cap: NativeInstructionCheck.replyCap).request(messages: prompt, model: "local-model"))
        let ordinary = try body(try client.request(messages: prompt, model: "local-model"))
        try require(quick["max_tokens"] as? Int == NativeInstructionCheck.replyCap && quick["reasoning_effort"] as? String == "low"
                        && (quick["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false
                        && quick["model"] as? String == "local-model" && quick["tools"] == nil && (quick["messages"] as? [Any])?.count == 2,
                    "The check goes to the same model with a reply cap and thinking turned down where it is already set: \(quick)")
        try require(ordinary["max_tokens"] as? Int == 1024 && ordinary["reasoning_effort"] as? String == "high"
                        && (ordinary["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true,
                    "Ordinary chat requests are unchanged")
        let bare = try body(try NativeChatClient(config: NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil,
                                                                          model: "local-model", chatTemplateKwargs: nil))
            .briefly(cap: NativeInstructionCheck.replyCap).request(messages: prompt, model: "local-model"))
        try require(Set(bare.keys) == ["model", "stream", "messages", "max_tokens"],
                    "A thinking option nobody set is never added: \(bare.keys.sorted())")
    }

    private static func instructionCheckAsk() async throws {
        let require = NativeTaskFixture.require
        let said = "Send the notes to ana@greenhouse.test"
        let about = "Send the notes: ana@greenhouse.test."
        let yes = NativeInstructionCheckTransport(.text("{\"run\": true}"))
        try require(await NativeInstructionCheck.ask(transport: yes, model: "local-model", said: said, about: about),
                    "An exact yes from the model is yes")
        try require(yes.requests.count == 1 && yes.requests[0] == NativeInstructionCheck.messages(said: said, about: about)
                        && yes.tools.allSatisfy(\.isEmpty), "One request, no tools, only the fixed question")
        for (label, reply) in [("a no", NativeInstructionCheckTransport.Reply.text("{\"run\": false}")), ("garbage", .text("Yes, go for it")),
                               ("an error", .failure), ("a tool call", .toolCall)] {
            let transport = NativeInstructionCheckTransport(reply)
            try require(!(await NativeInstructionCheck.ask(transport: transport, model: "local-model", said: said, about: about)),
                        "The model answering with \(label) is no")
        }
        let silent = NativeInstructionCheckTransport(.silence)
        let started = ContinuousClock.now
        let waited = await NativeInstructionCheck.ask(transport: silent, model: "local-model", said: said, about: about, timeout: .milliseconds(50))
        try require(!waited && ContinuousClock.now - started < .seconds(5), "A model that doesn't answer in time is no")
        let canceled = Task { await NativeInstructionCheck.ask(transport: NativeInstructionCheckTransport(.silence), model: "local-model", said: said, about: about) }
        canceled.cancel()
        try require(!(await canceled.value), "A canceled check is no")
        try require(!(await NativeInstructionCheck.bounded(.milliseconds(50)) {
            try? await Task.sleep(for: .seconds(30))
            return true
        }), "A slow answer that would have been yes is no once the time is up")
    }

    nonisolated private static func round(_ id: String, _ name: String, _ arguments: String) -> [NativeChatStreamSnapshot] {
        [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: id, name: name, arguments: arguments)], finishReason: "tool_calls")]
    }

    nonisolated private static let finished = [NativeChatStreamSnapshot(content: "Done.", toolCalls: [], finishReason: "stop")]

    private static func instructionSource(_ choice: NativeRuleChoice, for action: NativeActionClass) -> NativeRuleSource {
        var rules = NativeRules.defaults
        rules.set(choice, for: action)
        let made = NativeRuleSource()
        made.setGlobal(rules)
        return made
    }

    private static func drive(_ definitions: [NativeToolDefinition], _ rounds: [[NativeChatStreamSnapshot]], enabled: Set<String>, said: String,
                              answerer: NativeInstructionAnswerer?, timeout: Duration = NativeInstructionCheck.timeout,
                              history: [NativeChatMessage]? = nil,
                              confirm: @escaping @Sendable (NativeToolActivity) async -> Bool) async throws -> [NativeToolActivity] {
        let loop = NativeToolLoop(transport: ScriptedNativeToolTransport(rounds: rounds), registry: NativeToolRegistry(definitions: definitions),
                                  confirm: confirm, instructionCheck: answerer, instructionTimeout: timeout, said: said)
        var final: NativeToolTurnSnapshot?
        for try await snapshot in loop.stream(messages: history ?? [NativeChatMessage(role: "user", content: said)], model: "local-model",
                                              enabledToolIDs: enabled) {
            final = snapshot
        }
        return final?.activities ?? []
    }

    private static func instructionCheckLoop() async throws {
        let require = NativeTaskFixture.require
        let chat = "instruction-check-chat"
        let told = "Send the notes to ana@greenhouse.test"
        let sent = NativeChatRulesCounter()
        let looked = NativeChatRulesCounter()
        var mail = NativeToolDefinition(id: "fixture-notes", name: "send_notes", title: "Send the notes", description: "Fixture",
                                        parameters: .object(["type": .string("object")]), confirmation: .none, effect: .write,
                                        action: .networkSends, isAvailable: { true },
                                        execute: { _ in sent.hit(); return .object(["sent": .bool(true)]) })
        mail.ruleSubjects = { arguments in
            guard case .string(let to)? = arguments["to"], let target = NativeRuleTarget.make(.recipient, to) else { return [] }
            return [[target]]
        }
        mail.verbs = ["send"]
        var lookup = NativeToolDefinition(id: "fixture-look", name: "look_up", title: "Look up the notes", description: "Fixture",
                                          parameters: .object(["type": .string("object")]), confirmation: .none, effect: .read,
                                          isAvailable: { true }, execute: { _ in looked.hit(); return .object(["text": .string("TOOL-RESULT-TEXT")]) })
        lookup.effect = .read
        let asking = instructionSource(.ask, for: .networkSends)
        func tools(_ source: NativeRuleSource = asking, typed: String = told, uses: NativeInstructionUses = NativeInstructionUses()) -> [NativeToolDefinition] {
            [mail, lookup].map {
                ChatStore.ruled($0, rules: source, store: nil, conversationID: chat, requestText: typed, typed: NativeTypedWords(typed: typed), uses: uses)
            }
        }
        let send = "{\"to\":\"ana@greenhouse.test\",\"body\":\"SECRET-BODY-TEXT\",\"cc\":\"OTHER-ARGUMENT-VALUE\"}"
        let enabled: Set<String> = ["fixture-notes", "fixture-look"]
        let cards = NativeChatRulesCounter()
        let refuse: @Sendable (NativeToolActivity) async -> Bool = { _ in cards.hit(); return false }
        let approve: @Sendable (NativeToolActivity) async -> Bool = { _ in cards.hit(); return true }

        let history = [NativeChatMessage(role: "user", content: "EARLIER-MESSAGE-TEXT"), NativeChatMessage(role: "assistant", content: "Noted."),
                       NativeChatMessage(role: "user", content: told)]
        let yes = NativeInstructionCheckAnswers(true)
        let ran = try await drive(tools(), [round("look", "look_up", "{}"), round("send", "send_notes", send), finished], enabled: enabled,
                                  said: told, answerer: yes.answerer, history: history, confirm: refuse)
        try require(ran.count == 2 && ran[1].state == .succeeded && ran[1].ranBecause == .instruction && !ran[1].confirmationRequired
                        && sent.count == 1 && cards.count == 0 && yes.count == 1 && looked.count == 1,
                    "A yes runs the typed send with no card and says why: \(ran.map { ($0.state, $0.ranBecause as Any) })")
        let expectedAbout = "Send the notes: ana@greenhouse.test."
        try require(yes.all.first?.said == told && yes.all.first?.about == expectedAbout,
                    "The check gets the typed message and the code-built sentence: \(yes.all)")
        let question = NativeInstructionCheck.messages(said: told, about: expectedAbout)
        let sentText = question.map(\.content).joined(separator: "\n")
        try require(question.count == 2 && question[0].role == "system" && question[0].content == NativeInstructionCheck.systemPrompt
                        && question[1].role == "user"
                        && question[1].content == "\(NativeInstructionCheck.saidLabel)\n\(told)\n\n\(NativeInstructionCheck.aboutLabel)\n\(expectedAbout)",
                    "The question is the fixed prompt and two labelled parts: \(question[1].content)")
        for leaked in ["SECRET-BODY-TEXT", "OTHER-ARGUMENT-VALUE", "TOOL-RESULT-TEXT", "EARLIER-MESSAGE-TEXT", "Noted."] {
            try require(!sentText.contains(leaked), "The question never carries \(leaked)")
        }
        let long = NativeInstructionCheck.about("Send\nthe notes", targets: [String(repeating: "a", count: 500) + "\nb", "\n"])
        try require(!long.contains("\n") && long.count <= "Send the notes: ".count + NativeInstructionCheck.targetLimit + 1,
                    "Targets are capped and carry no line breaks: \(long.count)")

        sent.reset(); cards.reset()
        let no = NativeInstructionCheckAnswers(false)
        let declined = try await drive(tools(), [round("send", "send_notes", send), finished], enabled: enabled, said: told,
                                       answerer: no.answerer, confirm: refuse)
        try require(declined.count == 1 && declined[0].state == .failed && declined[0].confirmationRequired && declined[0].ranBecause == nil
                        && sent.count == 0 && cards.count == 1 && no.count == 1,
                    "A no shows the card and a decline leaves it not run")

        sent.reset(); cards.reset()
        let noThenApprove = NativeInstructionCheckAnswers(false)
        let approved = try await drive(tools(), [round("send", "send_notes", send), finished], enabled: enabled, said: told,
                                       answerer: noThenApprove.answerer, confirm: approve)
        try require(approved.count == 1 && approved[0].state == .succeeded && approved[0].ranBecause == nil && approved[0].confirmationRequired
                        && sent.count == 1 && cards.count == 1,
                    "A no then an approval runs it once and reads as approved: \(approved.map { ($0.state, $0.ranBecause as Any) })")

        for (label, answerer, timeout) in [
            ("an answer that never comes", { (_: String, _: String) async -> Bool in try? await Task.sleep(for: .seconds(30)); return true } as NativeInstructionAnswerer,
             Duration.milliseconds(50)),
            ("a model error", { (said: String, about: String) async -> Bool in
                await NativeInstructionCheck.ask(transport: NativeInstructionCheckTransport(.failure), model: "local-model", said: said, about: about)
            } as NativeInstructionAnswerer, NativeInstructionCheck.timeout),
            ("garbage from the model", { (said: String, about: String) async -> Bool in
                await NativeInstructionCheck.ask(transport: NativeInstructionCheckTransport(.text("Sure, run it")), model: "local-model", said: said, about: about)
            } as NativeInstructionAnswerer, NativeInstructionCheck.timeout),
            ("a model that times out", { (said: String, about: String) async -> Bool in
                await NativeInstructionCheck.ask(transport: NativeInstructionCheckTransport(.silence), model: "local-model", said: said, about: about,
                                                 timeout: .milliseconds(50))
            } as NativeInstructionAnswerer, NativeInstructionCheck.timeout),
        ] {
            sent.reset(); cards.reset()
            let steps = try await drive(tools(), [round("send", "send_notes", send), finished], enabled: enabled, said: told,
                                        answerer: answerer, timeout: timeout, confirm: refuse)
            try require(steps.count == 1 && steps[0].state == .failed && steps[0].confirmationRequired && sent.count == 0 && cards.count == 1,
                        "\(label) ends on the card")
        }

        sent.reset(); cards.reset()
        let once = NativeInstructionCheckAnswers(false)
        let shared = NativeInstructionUses()
        let repeated = try await drive(tools(uses: shared), [round("first", "send_notes", send), round("second", "send_notes", send), finished],
                                       enabled: enabled, said: told, answerer: once.answerer, confirm: refuse)
        try require(repeated.count == 2 && repeated.allSatisfy { $0.state == .failed && $0.confirmationRequired } && once.count == 1
                        && cards.count == 2 && sent.count == 0,
                    "After a no the same send asks again with no second check")
        let toBo = "{\"to\":\"bo@greenhouse.test\"}"
        let other = try await drive(tools(typed: "Send the notes to bo@greenhouse.test", uses: shared), [round("bo", "send_notes", toBo), finished],
                                    enabled: enabled, said: "Send the notes to bo@greenhouse.test", answerer: once.answerer, confirm: refuse)
        try require(other.count == 1 && once.count == 2 && once.all.last?.about == "Send the notes: bo@greenhouse.test.",
                    "A different typed target gets its own check")

        sent.reset(); cards.reset()
        let none = NativeInstructionCheckAnswers(true)
        let question2 = "Can you send the notes to ana@greenhouse.test?"
        _ = try await drive(tools(typed: question2), [round("send", "send_notes", send), finished], enabled: enabled, said: question2,
                            answerer: none.answerer, confirm: refuse)
        try require(none.count == 0 && cards.count == 1 && sent.count == 0, "A message the code check refuses asks with no model check")
        let acting = instructionSource(.act, for: .networkSends)
        let allowed = try await drive(tools(acting), [round("send", "send_notes", send), finished], enabled: enabled, said: told,
                                      answerer: none.answerer, confirm: refuse)
        try require(none.count == 0 && allowed.first?.state == .succeeded && allowed.first?.ranBecause == nil && sent.count == 1 && cards.count == 1,
                    "A send the rules already allow runs with no check")

        sent.reset(); cards.reset()
        let unanswered = try await drive(tools(), [round("send", "send_notes", send), finished], enabled: enabled, said: told,
                                         answerer: nil, confirm: refuse)
        try require(unanswered.first?.state == .failed && unanswered.first?.confirmationRequired == true && cards.count == 1 && sent.count == 0,
                    "With nothing to answer the check, the typed send asks")
        let bareLoop = NativeToolLoop(transport: ScriptedNativeToolTransport(rounds: []), registry: NativeToolRegistry(definitions: []))
        try require(bareLoop.instructionCheck == nil, "A tool loop built without an answerer has none")

        var directRefused: String?
        let direct = tools()[0]
        do {
            _ = try await NativeToolCallContext.$confirmed.withValue(false) { try await direct.execute(["to": .string("ana@greenhouse.test")]) }
        } catch { directRefused = error.localizedDescription }
        try require(directRefused != nil && sent.count == 0, "A typed send that skipped the check never runs")
    }

    private static func instructionCheckFolders() async throws {
        let require = NativeTaskFixture.require
        let chat = "instruction-check-folder"
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("instruction-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let grant = try FolderGrant.make(url: base)
        let file = grant.path + "/notes.md"
        let typed = "Save this as notes.md"
        let rules = instructionSource(.ask, for: .fileEdits)
        func tools() -> [NativeToolDefinition] {
            let uses = NativeInstructionUses()
            let words = NativeTypedWords(typed: typed)
            return NativeFolderTools.definitions(grants: { [grant] }, ledger: NativeFileChangeLedger(), edits: .ask,
                liveTargets: { ChatStore.folderDecision(rules, conversationID: chat, requestText: typed, typed: words, uses: uses, action: $0, subjects: $1) },
                instruction: { ChatStore.folderInstruction(rules, conversationID: chat, requestText: typed, typed: words, uses: uses,
                                                           action: $0, subjects: $1, about: $2) })
        }
        let write = "{\"path\":\"\(file)\",\"content\":\"SECRET-FILE-CONTENT\"}"
        let cards = NativeChatRulesCounter()
        let yes = NativeInstructionCheckAnswers(true)
        let saved = try await drive(tools(), [round("write", NativeFolderTools.writeName, write), finished], enabled: [NativeFolderTools.toolID],
                                    said: typed, answerer: yes.answerer, confirm: { _ in cards.hit(); return false })
        try require(saved.first?.state == .succeeded && saved.first?.ranBecause == .instruction && cards.count == 0 && yes.count == 1
                        && (try? String(contentsOfFile: file, encoding: .utf8)) == "SECRET-FILE-CONTENT",
                    "A yes saves the typed file with no card: \(saved.map { ($0.state, $0.result ?? "") })")
        let aimed = yes.all.first?.about ?? ""
        try require(aimed.hasPrefix("Write a file: /") && aimed.hasSuffix("/\(base.lastPathComponent)/notes.md.") && !aimed.contains("\n") && yes.all.first.map { !$0.about.contains("SECRET") } == true,
                    "The check names the file the write is aimed at and none of its content: \(yes.all)")
        try FileManager.default.removeItem(atPath: file)

        let no = NativeInstructionCheckAnswers(false)
        let refused = try await drive(tools(), [round("write", NativeFolderTools.writeName, write), finished], enabled: [NativeFolderTools.toolID],
                                      said: typed, answerer: no.answerer, confirm: { _ in cards.hit(); return false })
        try require(refused.first?.state == .failed && refused.first?.confirmationRequired == true && cards.count == 1 && no.count == 1
                        && !FileManager.default.fileExists(atPath: file),
                    "A no shows the card and a decline writes nothing")
        let approved = try await drive(tools(), [round("write", NativeFolderTools.writeName, write), finished], enabled: [NativeFolderTools.toolID],
                                       said: typed, answerer: no.answerer, confirm: { _ in cards.hit(); return true })
        try require(approved.first?.state == .succeeded && approved.first?.ranBecause == nil && cards.count == 2
                        && FileManager.default.fileExists(atPath: file),
                    "A no then an approval writes it once and reads as approved")
    }

    private static func instructionCheckCommands() async throws {
        let require = NativeTaskFixture.require
        let chat = "instruction-check-command"
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("instruction-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let grant = try FolderGrant.make(url: base)
        let typed = "Run `echo hi`"
        let rules = instructionSource(.ask, for: .commands)
        let reasons = NativeCommandReasonSource()
        func tools(_ recorder: NativeCommandRunRecorder) -> [NativeToolDefinition] {
            let uses = NativeInstructionUses()
            let words = NativeTypedWords(typed: typed)
            let live = ChatStore.commandLive(rules, store: nil, conversationID: chat, requestText: typed, typed: words, uses: uses)
            return NativeCommandTools.definitions(grants: { [grant] }, decision: .ask, reason: { reasons.reason(for: $0) }, record: { recorder.add($0) },
                                                  live: live.live, liveTargets: live.liveTargets,
                                                  instruction: { command, action, subjects, about in
                                                      ChatStore.commandInstruction(rules, conversationID: chat, requestText: typed, typed: words, uses: uses,
                                                                                   command: command, action: action, subjects: subjects, about: about)
                                                  })
        }
        let run = round("run", NativeCommandTools.runName, "{\"command\":\"echo hi\"}")
        let yes = NativeInstructionCheckAnswers(true)
        let ranRecorder = NativeCommandRunRecorder()
        _ = try await drive(tools(ranRecorder), [run, finished], enabled: [NativeCommandTools.toolID], said: typed, answerer: yes.answerer,
                            confirm: { _ in false })
        try require(ranRecorder.recorded.count == 1 && ranRecorder.recorded[0].reason == .instruction && yes.count == 1
                        && yes.all.first?.about == "Run a command: echo hi.",
                    "A yes runs the typed command with no card: \(ranRecorder.recorded.map { ($0.outcome, $0.reason as Any) })")

        let no = NativeInstructionCheckAnswers(false)
        let declinedRecorder = NativeCommandRunRecorder()
        let cards = NativeChatRulesCounter()
        _ = try await drive(tools(declinedRecorder), [run, finished], enabled: [NativeCommandTools.toolID], said: typed, answerer: no.answerer,
                            confirm: { _ in cards.hit(); return false })
        try require(declinedRecorder.recorded.isEmpty && cards.count == 1 && no.count == 1, "A no shows the card and a decline runs nothing")

        let approvedRecorder = NativeCommandRunRecorder()
        _ = try await drive(tools(approvedRecorder), [run, finished], enabled: [NativeCommandTools.toolID], said: typed, answerer: no.answerer,
                            confirm: { activity in reasons.set(.userApproved, for: activity.id); cards.hit(); return true })
        try require(approvedRecorder.recorded.count == 1 && approvedRecorder.recorded[0].outcome == .ran
                        && approvedRecorder.recorded[0].reason == .userApproved
                        && approvedRecorder.recorded[0].decisionLine == NativeRuleReason.userApproved.title && cards.count == 2,
                    "A no then an approval runs the command and its card reads as approved: \(approvedRecorder.recorded.map { $0.decisionLine as Any })")
    }

    private static func instructionCheckWorker() async throws {
        let require = NativeTaskFixture.require
        let sent = NativeChatRulesCounter()
        var mail = NativeToolDefinition(id: "fixture-notes", name: "send_notes", title: "Send the notes", description: "Fixture",
                                        parameters: .object(["type": .string("object")]), confirmation: .none, effect: .write,
                                        action: .networkSends, isAvailable: { true },
                                        execute: { _ in sent.hit(); return .object(["sent": .bool(true)]) })
        mail.ruleSubjects = { arguments in
            guard case .string(let to)? = arguments["to"], let made = NativeRuleTarget.make(.recipient, to) else { return [] }
            return [[made]]
        }
        mail.verbs = ["send"]
        let tools = [mail]
        let call = "{\"to\":\"ana@greenhouse.test\",\"body\":\"SECRET-BODY-TEXT\"}"
        let assignment = "Send the notes to ana@greenhouse.test"
        func harness(retries: Bool = false) throws -> NativeCompanionHarness {
            var made = try NativeCompanionHarness(rules: [.networkSends: .ask]) { messages in
                let results = NativeCompanionScriptedModel.toolResults(messages)
                if results.isEmpty { return NativeCompanionScriptedModel.call("send_notes", call) }
                if retries && results.count == 1 { return NativeCompanionScriptedModel.call("send_notes", call, id: "call-2") }
                return NativeCompanionScriptedModel.text("Sent the notes.")
            }
            let thread = made.thread
            let rules = made.rules
            let grants = made.grants
            made.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: "Ada", threadID: thread.current, tools: tools) }
            made.environment.authority = { conversation, request in
                NativeCompanionWorkerAuthority(resolver: rules.resolver(for: conversation, requestText: request,
                                                                        typed: NativeTypedWords(typed: request.isEmpty ? nil : request)),
                                               grantsRevision: grants.revision)
            }
            return made
        }

        let yes = try harness()
        yes.model.checks { .text("{\"run\": true}") }
        let yesID = try yes.create(assignment)
        let yesDone = try await yes.runUntilSettled()
        let asked = yes.model.instructionChecks
        try require(yesDone.state == .completed && sent.count == 1 && (try yes.effects(yesID)).filter { $0.state == .completed }.count == 1
                        && asked.count == 1,
                    "A yes from the task's model sends once with no question: \(yesDone.state)")
        try require(asked.first?.content == "\(NativeInstructionCheck.saidLabel)\n\(assignment)\n\n\(NativeInstructionCheck.aboutLabel)\nSend the notes: ana@greenhouse.test."
                        && asked.first?.attempt.contains(NativeInstructionCheck.attemptSuffix) == true
                        && yes.model.allRequests.allSatisfy { $0.first?.content != NativeInstructionCheck.systemPrompt },
                    "The worker asks the fixed question on its own attempt and never mixes it into the work: \(asked)")

        sent.reset()
        let no = try harness()
        let noID = try no.create(assignment)
        let noDone = try await no.runUntilSettled()
        try require(noDone.state == .needsDecision && sent.count == 0 && no.model.instructionChecks.count == 1
                        && (try no.effects(noID)).allSatisfy { $0.state != .completed },
                    "A no leaves the work waiting on a decision with nothing sent: \(noDone.state)")

        sent.reset()
        let dropped = try harness()
        dropped.model.checks { throw CancellationError() }
        let droppedID = try dropped.create(assignment)
        let droppedDone = try await dropped.runUntilSettled()
        try require(droppedDone.state == .needsDecision && sent.count == 0 && (try dropped.effects(droppedID)).allSatisfy { $0.state != .completed },
                    "A check that gives up while the work is still going leaves it waiting on a decision: \(droppedDone.state)")

        sent.reset()
        let retry = try harness(retries: true)
        let retryID = try retry.create(assignment)
        let waiting = try await retry.runUntilSettled()
        try require(waiting.state == .needsDecision && retry.model.instructionChecks.count == 1, "The first send asks after a no")
        retry.clock.advance(NativeEffectProposal.lifetime + 1)
        try retry.reply(waiting, "approve", digest: try retry.decision(waiting)["digest"] as? String)
        let again = try await retry.runUntilSettled()
        let keys = Set((try retry.effects(retryID)).map(\.proposal.idempotencyKey))
        try require(again.state == .needsDecision && sent.count == 0 && retry.model.instructionChecks.count == 1 && keys.count == 2,
                    "A retry of the same send after a no asks without a second check: \(again.state), \(retry.model.instructionChecks.count) checks")

        sent.reset()
        let scheduled = try harness()
        scheduled.model.checks { .text("{\"run\": true}") }
        let scheduledID = try scheduled.create(assignment, mode: "scheduled", scheduleID: "schedule-1")
        _ = try await scheduled.runUntilSettled()
        try require(sent.count == 0 && scheduled.model.instructionChecks.isEmpty && (try scheduled.effects(scheduledID)).allSatisfy { $0.state != .completed },
                    "Scheduled work makes no check and sends nothing")
    }

    private static func instructionCheckStore() async throws {
        let require = NativeTaskFixture.require
        let config = NativeChatConfig(baseURL: URL(string: "https://model.example/v1")!, apiKey: nil, model: "local-model", chatTemplateKwargs: nil)
        let callRound = round("post-call", "garden_log", "{\"line\":\"Watered the beans\"}")
        func store(_ counter: NativeChatRulesCounter, check: NativeInstructionAnswerer?) async -> ChatStore {
            var send = NativeToolDefinition(id: "capability-garden_log", name: "garden_log", title: "Post to the garden log",
                description: "Post a line to the garden log",
                parameters: .object(["type": .string("object"), "properties": .object(["line": .object(["type": .string("string")])]),
                                     "required": .array([.string("line")])]),
                confirmation: .none, action: .networkSends, isAvailable: { true },
                execute: { _ in counter.hit(); return .object(["posted": .bool(true)]) }, fixedDestination: true)
            send.verbs = ["post"]
            send.namesNothing = true
            let store = ChatStore(nativeConfig: config, nativeTransport: ScriptedNativeToolTransport(rounds: [callRound, finished]),
                                  repository: try! LocalChatRepository(inMemory: true), nativeEnabledToolIDs: [send.id],
                                  nativeToolRegistry: NativeToolRegistry(definitions: [send]), artifactPersistenceEnabled: false)
            store.instructionCheck = check
            await store.connect()
            store.newConversation()
            return store
        }
        func settle(_ store: ChatStore) async throws -> Bool {
            var sawCard = false
            var waited = 0
            try await Task.sleep(nanoseconds: 20_000_000)
            while store.generating && waited < 500 {
                if !store.turnConfirmations.isEmpty { sawCard = true; break }
                try await Task.sleep(nanoseconds: 10_000_000); waited += 1
            }
            return sawCard || !store.turnConfirmations.isEmpty
        }
        let posted = NativeChatRulesCounter()
        let yes = NativeInstructionCheckAnswers(true)
        let running = await store(posted, check: yes.answerer)
        try require(running.sendText("Post the note to the garden log", fromComposer: true), "The typed message is accepted")
        let yesCard = try await settle(running)
        try require(!yesCard && posted.count == 1 && yes.count == 1 && yes.all.first?.said == "Post the note to the garden log"
                        && running.selected?.messages.last?.toolActivities.first?.ranBecause == .instruction,
                    "Through the store a yes runs the typed post with no card")

        let skipped = NativeChatRulesCounter()
        let no = NativeInstructionCheckAnswers(false)
        let asking = await store(skipped, check: no.answerer)
        try require(asking.sendText("Post the note to the garden log", fromComposer: true), "The typed message is accepted")
        let noCard = try await settle(asking)
        try require(noCard && skipped.count == 0 && no.count == 1, "Through the store a no shows the card")
        if let (messageID, card) = asking.turnConfirmations.first.map({ ($0.key, $0.value) }) {
            asking.resolveTurnConfirmation(messageID, decision: .decline, requestID: card.id, token: asking.turnConfirmationTokens[messageID])
        }
        _ = try await settle(asking)
        try require(skipped.count == 0, "Declining the card runs nothing")
    }
}
