import Foundation

@MainActor
extension SelfTest {
    static func companionUnnamedWorker() async throws {
        let require = NativeTaskFixture.require
        let builtIn = "Ver" + "a"
        for name in [nil, "Ada"] as [String?] {
            var harness = try NativeCompanionHarness(rules: [.networkSends: .act]) { messages in
                NativeCompanionScriptedModel.call("garden_status", "{}", id: "call-\(NativeCompanionScriptedModel.toolResults(messages).count)")
            }
            let tools = NativeCompanionHarness.tools(harness.service, reconcile: false)
            let thread = harness.thread
            harness.environment.context = { _, _ in NativeCompanionWorkerContext(assistantName: name, threadID: thread.current, tools: tools) }
            _ = try harness.create("Check the garden")
            let waiting = try await harness.runUntilSettled(40)
            let system = harness.model.allRequests.first?.first { $0.role == "system" }?.content ?? ""
            let question = try harness.decision(waiting)["prompt"] as? String ?? ""
            if let name {
                try require(system.hasPrefix("You are \(name), working on one assignment") && question.hasPrefix("\(name) has used this run's"),
                            "A named companion's worker prompt and its question to the person use the name")
            } else {
                try require(system.hasPrefix("You are the user's assistant, working on one assignment")
                                && !system.contains("our companion") && !system.contains(builtIn),
                            "An unnamed companion's worker prompt claims no name: \(system.prefix(80))")
                try require(question.hasPrefix("Your companion has used this run's") && !question.contains(builtIn),
                            "An unnamed companion's question to the person starts with Your companion: \(question.prefix(80))")
            }
        }
        let ordinaryTransport = NativeSessionFixtureTransport()
        let ordinary = ChatStore(nativeConfig: NativeSessionFixture.config, nativeTransport: ordinaryTransport,
                                 repository: try LocalChatRepository(inMemory: true), nativeAssistantName: "Ada", artifactPersistenceEnabled: false)
        ordinary.newConversation()
        try require(ordinary.sendText("What's a good name for a boat?"), "The ordinary chat accepts a message")
        try await NativeSessionFixture.eventually("The ordinary chat replies") {
            ordinary.selected?.messages.last?.role == .assistant && ordinary.selected?.messages.last?.state == .complete
        }
        let ordinaryPrompt = ordinaryTransport.histories.last?.first { $0.role == "system" }?.content ?? ""
        try require(!ordinaryPrompt.isEmpty && !ordinaryPrompt.contains("Your name is") && !ordinaryPrompt.contains("Ada"),
                    "An ordinary chat's prompt never carries the companion's name")
        let namedContext = NativeContextAssembler.assemble(NativeContextInput(
            persona: "You are an assistant.", timestamp: Date(timeIntervalSince1970: 1_786_000_000),
            timeZone: TimeZone(identifier: "America/Chicago")!, assistantName: ordinary.companionName))
        try require(namedContext.prompt.contains("Your name is Ada."), "The companion's own conversation is still told its name")
        let unnamed = CompanionSubject(nil), named = CompanionSubject(" Ada ")
        try require(unnamed.thread == "your companion's thread" && named.thread == "the Ada thread"
                        && CompanionSentence.plain("Results go to " + unnamed.threadTemplate + ".", name: nil) == "Results go to your companion's thread."
                        && CompanionSentence.plain("Results go to " + named.threadTemplate + ".", name: "Ada") == "Results go to the Ada thread.",
                    "The thread is named the Ada thread, or your companion's thread when there is no name")
        try require(NativeCompanionWorker.handOffText(name: unnamed.leading, title: "Send it", action: nil).hasPrefix("Your companion stopped before this step"),
                    "The hand off line starts with Your companion when there is no name")
    }
}
