import Foundation

@MainActor
enum NativeSessionHTTPFixture {
    static func run(_ raw: String) async throws {
        guard let base = URL(string: raw), base.scheme == "http", base.host == "127.0.0.1",
              base.user == nil, base.password == nil else { throw NativeTaskHTTPError.invalidResponse }
        let repository = try LocalChatRepository(inMemory: true)
        let config = NativeChatConfig(baseURL: base.appendingPathComponent("v1"), apiKey: nil,
                                      model: "local-model", chatTemplateKwargs: nil, streaming: false)
        let hold = NativeToolDefinition(id: "hold", name: "hold", title: "Read the reference",
            description: "Read a test reference", parameters: .object(["type": .string("object")]),
            confirmation: .none, isAvailable: { true }, execute: { _ in
                let (_, response) = try await URLSession.shared.data(from: base.appendingPathComponent("hold"))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NativeTaskHTTPError.invalidResponse }
                return .object(["finding": .string("The reference is ready")])
            })
        let store = ChatStore(nativeConfig: config, nativeTransport: NativeChatClient(config: config),
            repository: repository, nativeEnabledToolIDs: ["hold"],
            nativeToolRegistry: NativeToolRegistry(definitions: [hold]), artifactPersistenceEnabled: false)
        store.newConversation()
        store.setSessionMode(.continuous)
        store.sendText("slow question")
        let first = store.selected!.messages.last!.id
        try await NativeSessionFixture.eventually("Native HTTP tool must start") {
            store.selected?.messages.first(where: { $0.id == first })?.toolActivities.isEmpty == false
        }
        let start = ContinuousClock.now
        store.draft = "fridge question"
        store.send()
        let accepted = start.duration(to: .now)
        let second = store.selected!.messages.last!.id
        try await NativeSessionFixture.eventually("Second native HTTP answer must complete while first tool waits") {
            store.selected?.messages.first(where: { $0.id == second })?.state == .complete
        }
        let completed = start.duration(to: .now)
        try NativeTaskFixture.require(store.selected?.messages.first(where: { $0.id == first })?.state == .streaming,
                                      "The first native HTTP answer must remain independently active")
        store.stopAnswer(first)
        let stopped = store.selected!.messages.first(where: { $0.id == first })!
        _ = try await URLSession.shared.data(from: base.appendingPathComponent("release"))
        try await Task.sleep(for: .milliseconds(100))
        try NativeTaskFixture.require(store.selected?.messages.first(where: { $0.id == first }) == stopped,
                                      "Late HTTP completion must not change a stopped answer")
        let evidence: [String: Any] = ["accepted_seconds": accepted.seconds,
            "second_answer_seconds": completed.seconds, "messages": try repository.messages(conversationID: store.selectedID!).count,
            "first_stopped": true, "second_completed": true]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        print("SESSION_HTTP_FIXTURE \(String(decoding: data, as: UTF8.self))")
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

extension NativeSessionHTTPFixture {
    struct RestartConfiguration: Decodable {
        let base: URL
        let database: URL
        let mode: String
    }

    static func restart(_ raw: String) async throws {
        let input = try JSONDecoder().decode(RestartConfiguration.self, from: Data(raw.utf8))
        guard input.base.scheme == "http", input.base.host == "127.0.0.1", input.database.isFileURL,
              ["owner", "recover"].contains(input.mode) else { throw NativeTaskHTTPError.invalidResponse }
        let repository = try LocalChatRepository(url: input.database)
        let config = NativeChatConfig(baseURL: input.base.appendingPathComponent("v1"), apiKey: nil,
                                      model: "local-model", chatTemplateKwargs: nil, streaming: false)
        let mutation = NativeToolDefinition(id: "fixture-mutation", name: "hold", title: "Save the test item",
            description: "Save a synthetic item", parameters: .object(["type": .string("object")]),
            confirmation: .none, isAvailable: { true }, execute: { _ in
                _ = try await URLSession.shared.data(from: input.base.appendingPathComponent("effect"))
                return .object(["saved": .bool(true)])
            })
        let store = ChatStore(nativeConfig: config, nativeTransport: NativeChatClient(config: config),
            repository: repository, nativeEnabledToolIDs: ["fixture-mutation"],
            nativeToolRegistry: NativeToolRegistry(definitions: [mutation]), artifactPersistenceEnabled: false)
        if input.mode == "owner" {
            store.newConversation()
            store.sendText("slow question")
            store.sendText("pending question")
            FileHandle.standardOutput.write(Data("SESSION_OWNER_READY\n".utf8))
            try await Task.sleep(for: .seconds(30))
        } else {
            store.conversations = try repository.listConversations()
            guard let id = store.conversations.first?.id else { throw NativeTaskHTTPError.invalidResponse }
            store.select(id)
            store.resumeConversationTurns()
            try await NativeSessionFixture.eventually("The surviving process must recover pending work") {
                store.conversationTurns.contains { $0.state == .complete }
            }
            let turns = try repository.conversationTurns()
            try NativeTaskFixture.require(turns.count == 2 && turns[0].state == .interrupted && turns[1].state == .complete,
                                          "Process restart must never replay the interrupted turn")
            try NativeTaskFixture.require(turns[0].mayHaveEffect, "The pre-dispatch effect marker must survive SIGKILL")
            let visible = store.selected?.messages.first(where: { $0.id == turns[0].assistantMessageID })
            try NativeTaskFixture.require(visible?.state == .interrupted && visible?.failure?.contains("action") == true,
                                          "The surviving transcript must show the recovered original answer and action uncertainty")
            store.retryAnswer(turns[0].assistantMessageID)
            try NativeTaskFixture.require(try repository.conversationTurns()[0].state == .interrupted,
                                          "Explicit Retry must not duplicate an uncertain mutation")
            FileHandle.standardOutput.write(Data("SESSION_RESTART_OK\n".utf8))
        }
    }
}
