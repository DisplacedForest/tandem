import Foundation

final class NativeTaskTimingCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NativeTaskTransportTiming] = []
    func append(_ value: NativeTaskTransportTiming) { lock.withLock { values.append(value) } }
    var snapshot: [NativeTaskTransportTiming] { lock.withLock { values } }
}

enum NativeTaskTransportFixture {
    struct Input: Decodable {
        let base: URL
        let scenario: String
        let overall: Double
        let setup: Double
        let idle: Double
    }

    static func terminalFence() throws {
        let capture = NativeTaskTimingCapture()
        let observer = NativeTaskTransportObserver(phase: .plan, expectedBytes: 10, overallSeconds: 5, sink: { capture.append($0) })
        try NativeTaskFixture.require(observer.finish(.canceled), "Cancellation must claim terminal state")
        let expired = NativeTaskTransportObserver(phase: .synthesize, expectedBytes: 10, overallSeconds: 0.001, sink: { capture.append($0) })
        Thread.sleep(forTimeInterval: 0.005)
        try NativeTaskFixture.require(expired.finish(.completed) && expired.outcome == .overall_timeout,
                                      "Completion after the cutoff must atomically become timeout")
        let timely = NativeTaskTransportObserver(phase: .plan, expectedBytes: 10, overallSeconds: 5, sink: { _ in })
        try NativeTaskFixture.require(timely.finish(.completed) && timely.outcome == .completed, "Timely completion remains accepted")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://fixture.test")!)
        let task = session.dataTask(with: request)
        observer.urlSession(session, task: task, didSendBodyData: 10, totalBytesSent: 10, totalBytesExpectedToSend: 10)
        observer.received(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        try NativeTaskFixture.require(!observer.finish(.completed) && capture.snapshot.count == 2,
                                      "Late callbacks cannot replace terminal outcome or emit another diagnostic")
        try NativeTaskFixture.require(capture.snapshot[0].status == nil && capture.snapshot[0].setupSeconds == nil,
                                      "Late response metadata cannot rewrite the saved diagnostic")
    }

    static func run(_ raw: String) async throws {
        try terminalFence()
        let input = try JSONDecoder().decode(Input.self, from: Data(raw.utf8))
        guard ["127.0.0.1", "localhost", "::1"].contains(input.base.host) else {
            throw NativeTaskFixture.Failure.assertion("Transport fixture requires loopback")
        }
        let provider = try NativeTaskEngineIdentity(input.base)
        let binding = NativeTaskProfileBinding(id: UUID().uuidString, profileID: "transport-fixture", provider: provider,
            savedModel: "fixture", executionModel: "fixture", limits: try NativeTaskGenerationLimits(maximumRequests: 4))
        let messages = [NativeTaskGenerationMessage(role: "user", content: "Synthetic transport question")]
        let job = NativeTaskGenerationJob(id: UUID().uuidString, taskID: UUID().uuidString, bindingID: binding.id,
            enrollmentDigest: String(repeating: "a", count: 64), admissionBase: input.base,
            phase: "synthesize", attempt: "initial-0", messages: messages,
            messagesDigest: NativeTaskGenerationJob.digest(messages), deadlineSeconds: input.overall, generation: 1)
        let capture = NativeTaskTimingCapture()
        let config = NativeChatConfig(baseURL: input.base, apiKey: "synthetic-secret-sentinel", model: "fixture", chatTemplateKwargs: nil)
        let operation = Task {
            try await NativeTaskProvider.complete(config: config, binding: binding, job: job,
                limits: .init(connectAndSend: input.setup, readIdle: input.idle), diagnostics: { capture.append($0) })
        }
        let cancel = Task {
            guard input.scenario == "cancel" else { return }
            try? await Task.sleep(for: .milliseconds(100))
            operation.cancel()
        }
        defer { cancel.cancel() }
        var failure: String?
        do {
            let answer = try await operation.value
            try NativeTaskFixture.require(answer == "Synthetic complete answer", "Only complete response accepted")
        } catch is CancellationError {
            failure = "canceled"
        } catch let known as NativeTaskGenerationFailure {
            failure = known.code
        }
        try await Task.sleep(for: .milliseconds(80))
        let values = capture.snapshot
        try NativeTaskFixture.require(values.count == 1, "Exactly one terminal diagnostic")
        let bytes = try JSONEncoder().encode(values[0])
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        print(String(data: try JSONSerialization.data(withJSONObject: ["timing": object, "failure": failure as Any? ?? NSNull()], options: [.sortedKeys]), encoding: .utf8)!)
    }
}
