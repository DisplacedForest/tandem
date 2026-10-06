import Foundation

enum ScopeSelftest {
    static func binding() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let value = changed(fixture.value, "sessions", .array(fixture.value["sessions"].array!.map { changed($0, "task_id", .null) }))
        let permit = try Permit(value)
        let root = fixture.root.appendingPathComponent("late")
        let original = fixture.request()
        let a = changed(original, "task_id", .string(UUID().uuidString.lowercased()))
        let b = changed(changed(a, "request_id", .string(UUID().uuidString.lowercased())), "task_id", .string(UUID().uuidString.lowercased()))
        func exercise() async throws -> J {
            let ledger = try Ledger(root: root)
            let credential = FixtureCredential()
            let broker = try Broker(permit: permit, ledger: ledger, credentials: credential, http: FixtureHTTP(delay: .milliseconds(30)))
            let bad = changed(a, "messages", .array([.object(["role": .string("user"), "content": .object(["image": .string("invalid")])])]))
            try await Selftest.expectAsync { _ = try await broker.complete(bad, requestPermit: fixture.authorization(bad)) }
            try await Selftest.expectAsync(.unauthorized) { _ = try await broker.complete(a, requestPermit: changed(fixture.authorization(a), "input_sha256", .string("wrong"))) }
            try ensure(credential.count == 0)
            let requests = [a, b]
            let tasks = requests.map { request in Task { try? await broker.complete(request, requestPermit: fixture.authorization(request)) } }
            var winners: [J] = []
            for (index, task) in tasks.enumerated() { if await task.value != nil { winners.append(requests[index]) } }
            try ensure(winners.count == 1 && credential.count == 1)
            try ensure(try ledger.snapshot().count == 1)
            return winners[0]
        }
        let winner = try await exercise()
        let reopened = try Ledger(root: root)
        try reopened.bind(permit)
        let fresh = changed(winner, "request_id", .string(UUID().uuidString.lowercased()))
        try reopened.check(Completion(fresh, permit: permit, requestPermit: fixture.authorization(fresh)))
        let foreign = changed(fresh, "task_id", .string(UUID().uuidString.lowercased()))
        try Selftest.expect(.unauthorized) { try reopened.check(Completion(foreign, permit: permit, requestPermit: fixture.authorization(foreign))) }
        let switched = changed(fresh, "mode", .string("focused"))
        try Selftest.expect(.unauthorized) { try reopened.check(Completion(switched, permit: permit, requestPermit: fixture.authorization(switched))) }
    }
    static func focused() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let request = changed(f.request(text: "/task explicit text in focused chat"), "mode", .string("focused"))
        let completion = try f.completion(request)
        try ensure(completion.tools.isEmpty)
        var missing = request.object!
        missing.removeValue(forKey: "mode")
        try Selftest.expect { _ = try f.completion(.object(missing)) }
        let args: J = .object(["objective": .string("fixture")])
        let history: J = .array([.object(["role": .string("assistant"), "content": .array([.object(["type": .string("toolCall"), "id": .string("call"), "name": .string("delegate"), "arguments": args])])]), .object(["role": .string("toolResult"), "toolCallId": .string("call"), "content": .string("done")])])
        try Selftest.expect { _ = try f.completion(changed(request, "messages", history)) }
        let response = changed(FixtureHTTP.answer, "choices", .array([.object(["finish_reason": .string("tool_calls"), "message": .object(["role": .string("assistant"), "content": .null, "tool_calls": .array([.object(["id": .string("call"), "type": .string("function"), "function": .object(["name": .string("delegate"), "arguments": .string("{\"objective\":\"fixture\"}")])])])])])]))
        try Selftest.expect { _ = try Reply(response.data(), request: completion) }
    }
    static func mode() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.permit.authorizeTransport(live: false)
        try Selftest.expect(.unauthorized) { try fixture.permit.authorizeTransport(live: true) }
        let live = try Permit(changed(fixture.value, "transport", .string("live")))
        try Selftest.expect(.unauthorized) { try live.authorizeTransport(live: false) }
        let late = changed(changed(fixture.value, "transport", .string("live")), "sessions", .array(fixture.value["sessions"].array!.map { changed($0, "task_id", .null) }))
        try Selftest.expect(.unauthorized) { _ = try Permit(late) }
        let ledger = try Ledger(root: fixture.root.appendingPathComponent("mode"))
        try ledger.bind(fixture.permit)
        try Selftest.expect(.unauthorized) { try ledger.bind(live) }
        var missing = fixture.value.object!
        missing.removeValue(forKey: "transport")
        try Selftest.expect { _ = try Permit(.object(missing)) }
    }
}
