import Foundation

private actor NativePreparedInvocationPipeFixture: NativePreparedInvocationRepository, NativePreparedInvocationDecisionHost {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var sequence = 0
    private var capability: String?

    init(python: URL, repositoryRoot: URL, dataRoot: URL) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = python
        process.arguments = ["-S", "-m", "pi_assistant.confirmed_invocation_fixture", "--isolated-fixture-stdio", dataRoot.path]
        process.environment = ["PYTHONPATH": repositoryRoot.appendingPathComponent("prototypes").path + ":" + repositoryRoot.appendingPathComponent("services/vera-api").path, "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
        try process.run()
    }

    func open(binding: NativePreparedToolInvocation, create: Bool) throws {
        let data = try call("open", ["binding": object(binding), "create": create])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String], Set(object.keys) == ["capability"], let capability = object["capability"], UUID(uuidString: capability) != nil else { throw NativePreparedInvocationError.invalidReceipt }
        self.capability = capability
    }

    func prepare(_ binding: NativePreparedToolInvocation) throws -> NativePreparedInvocationReceipt {
        try decode(call("prepare", ["binding": object(binding)]))
    }

    func inspect(scope: NativePreparedInvocationScope, taskID: String) throws -> NativePreparedInvocationReceipt {
        try decode(call("inspect", ["scope": object(scope), "taskID": taskID]))
    }

    func cancel(scope: NativePreparedInvocationScope, taskID: String) throws -> NativePreparedInvocationReceipt {
        try decode(call("cancel", ["scope": object(scope), "taskID": taskID, "capability": hostCapability()]))
    }

    func respond(review: NativePreparedInvocationReceipt, replyID: String, approved: Bool) throws -> NativePreparedInvocationReceipt {
        guard let decisionID = review.decisionID else { throw NativePreparedInvocationError.decisionUnavailable }
        return try decode(call("respond", ["scope": object(review.binding.scope), "taskID": review.taskID, "decisionID": decisionID, "replyID": replyID, "approved": approved, "capability": hostCapability()]))
    }

    func dispatch(scope: NativePreparedInvocationScope, taskID: String) throws -> NativePreparedInvocationResult {
        try decode(call("dispatch", ["scope": object(scope), "taskID": taskID, "capability": hostCapability()]))
    }

    func count() throws -> Int { try decode(call("count", [:])) }

    func rejectModelApproval(_ review: NativePreparedInvocationReceipt) throws {
        do {
            _ = try call("respond", ["scope": object(review.binding.scope), "taskID": review.taskID, "decisionID": review.decisionID!, "replyID": "model-forged", "approved": true, "capability": "model-controlled-text"])
            throw NativePreparedInvocationError.invalidReceipt
        } catch NativePreparedInvocationError.unavailable {}
        do {
            _ = try call("execute_remote_tool", [:])
            throw NativePreparedInvocationError.invalidReceipt
        } catch NativePreparedInvocationError.unavailable {}
    }

    func crash(scope: NativePreparedInvocationScope, taskID: String, phase: String) throws {
        do {
            _ = try call("crash", ["scope": object(scope), "taskID": taskID, "phase": phase, "capability": hostCapability()])
            throw NativePreparedInvocationError.invalidReceipt
        } catch NativePreparedInvocationError.unavailable {}
        process.waitUntilExit()
        guard process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGKILL else { throw NativePreparedInvocationError.invalidReceipt }
        capability = nil
    }

    func close() {
        capability = nil
        try? input.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? output.close()
    }

    private func hostCapability() throws -> String {
        guard let capability else { throw NativePreparedInvocationError.unavailable }
        return capability
    }

    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    private func call(_ method: String, _ parameters: [String: Any]) throws -> Data {
        guard process.isRunning else { throw NativePreparedInvocationError.unavailable }
        sequence += 1
        var request = try JSONSerialization.data(withJSONObject: ["id": sequence, "method": method, "params": parameters], options: [.sortedKeys])
        guard request.count < 32768 else { throw NativePreparedInvocationError.invalidBinding }
        request.append(10)
        let process = process
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        try input.write(contentsOf: request)
        var response = Data()
        while response.count < 32768 {
            guard let byte = try output.read(upToCount: 1), !byte.isEmpty else { throw NativePreparedInvocationError.unavailable }
            if byte[0] == 10 { break }
            response.append(byte)
        }
        guard response.count < 32768 else { process.terminate(); throw NativePreparedInvocationError.invalidReceipt }
        try NativeTaskJSON.validate(response, maximumBytes: 32768)
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              envelope["id"] as? Int == sequence, let ok = envelope["ok"] as? Bool else { throw NativePreparedInvocationError.invalidReceipt }
        if !ok {
            guard Set(envelope.keys) == ["id", "ok", "error"], envelope["error"] as? String == "rejected" else { throw NativePreparedInvocationError.invalidReceipt }
            throw NativePreparedInvocationError.unavailable
        }
        guard Set(envelope.keys) == ["id", "ok", "value"], let value = envelope["value"] else { throw NativePreparedInvocationError.invalidReceipt }
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
}

extension NativePreparedInvocationSelftest {
    static func runWire(python: URL, repositoryRoot: URL, dataRoot: URL) async throws {
        let binding = binding()
        let repository = try NativePreparedInvocationPipeFixture(python: python, repositoryRoot: repositoryRoot, dataRoot: dataRoot.appendingPathComponent("normal"))
        do {
            try await repository.open(binding: binding, create: true)
            let coordinator = NativePreparedInvocationCoordinator(repository: repository, scope: binding.scope)
            let focused = NativePreparedFocusedFixtureConsumer(coordinator: coordinator)
            let pi = NativePreparedPiFixtureConsumer(coordinator: coordinator)
            let clock = ContinuousClock()
            let start = clock.now
            let first = try await focused.submit(hostPrepared: binding)
            let duplicate = try await pi.submit(hostPrepared: binding)
            try require(first == duplicate && first.phase == "awaiting_decision", "Actual shared consumers must share the durable pending identity")
            try require(start.duration(to: clock.now) < .seconds(5), "Actual preparation must finish well before the Pi deadline")
            try await repository.rejectModelApproval(first)
            let second = try await pi.submit(hostPrepared: Self.binding(operationID: "foreground-second"))
            try require(second.taskID != first.taskID && second.phase == "awaiting_decision", "Foreground work must remain responsive during approval")
            try require(try await repository.count() == 0, "Preparation and forged approval must not execute effects")
            let ready = try await coordinator.respond(review: first, replyID: "host-decision", approved: true, host: repository)
            try require(ready.phase == "ready", "Host approval must reach the durable ready checkpoint")
            let result = try await repository.dispatch(scope: binding.scope, taskID: first.taskID)
            let replay = try await repository.dispatch(scope: binding.scope, taskID: first.taskID)
            try require(result == replay && result.status == "completed", "Completed dispatch must return its recorded result")
            try require(try await repository.count() == 1, "Completed replay must not repeat an effect")
            let completed = try await coordinator.inspect(taskID: first.taskID)
            try require(completed.phase == "effect_completed" && completed.result == result, "TaskStore completion must carry the recorded result")
            let canceled = try await coordinator.cancel(taskID: second.taskID)
            try require(canceled.phase == "canceled", "Second task cancellation must remain independent")
            await repository.close()
        } catch {
            await repository.close()
            throw error
        }
        for phase in ["intent", "effect"] {
            let binding = Self.binding(operationID: "crash-" + phase)
            let root = dataRoot.appendingPathComponent("crash-" + phase)
            let child = try NativePreparedInvocationPipeFixture(python: python, repositoryRoot: repositoryRoot, dataRoot: root)
            let taskID: String
            do {
                try await child.open(binding: binding, create: true)
                let coordinator = NativePreparedInvocationCoordinator(repository: child, scope: binding.scope)
                let prepared = try await coordinator.prepare(binding)
                _ = try await coordinator.respond(review: prepared, replyID: "crash-approval", approved: true, host: child)
                taskID = prepared.taskID
                try await child.crash(scope: binding.scope, taskID: taskID, phase: phase)
                await child.close()
            } catch {
                await child.close()
                throw error
            }
            let reopened = try NativePreparedInvocationPipeFixture(python: python, repositoryRoot: repositoryRoot, dataRoot: root)
            do {
                try await reopened.open(binding: binding, create: false)
                let coordinator = NativePreparedInvocationCoordinator(repository: reopened, scope: binding.scope)
                let recovered = try await coordinator.inspect(taskID: taskID)
                try require(recovered.taskID == taskID && recovered.phase == "effect_uncertain" && recovered.result == nil, "Abrupt restart must preserve identity and expose uncertainty")
                let expected = phase == "effect" ? 1 : 0
                try require(try await reopened.count() == expected, "Crash evidence must match the actual effect boundary")
                do {
                    _ = try await reopened.dispatch(scope: binding.scope, taskID: taskID)
                    throw NativePreparedInvocationError.invalidReceipt
                } catch NativePreparedInvocationError.unavailable {}
                try require(try await reopened.count() == expected, "Uncertain recovery must never replay an effect")
                await reopened.close()
                print("PASS actual SIGKILL signal 9 after durable \(phase), reopened effect count \(expected), stable task identity, explicit uncertainty, no replay")
            } catch {
                await reopened.close()
                throw error
            }
        }
        print("PASS Swift focused/Pi fixture consumers through bounded private pipe to Python TaskStore; one synthetic effect")
    }
}
