import Foundation
import VeraAssistantUI

@MainActor
enum NativeDocumentContract {
    static func run(_ arguments: [String]) async {
        var presentation: NativePiPresentation?
        var provider: PiCandidateProviderFixture?
        var stage = "startup"
        do {
            guard let mode = arguments.first, ["complete", "reopen", "cancel", "hold-draft", "retry", "delayed", "foreign-origin", "foreign-conversation", "foreign-task", "foreign-assistant", "foreign-worker"].contains(mode) else { throw PiBrokerError.invalid }
            if mode == "delayed" { PiAdmissionFixtureProtocol.state.setGenerationSeconds(8) }
            defer { PiAdmissionFixtureProtocol.state.setGenerationSeconds(3) }
            let candidate = try await NativePiCandidate.create(Array(arguments.dropFirst()), httpTransport: { request in
                let response = try await PiOwnedHTTP.send(request)
                guard mode.hasPrefix("foreign-"), request.url?.path.hasPrefix("/tasks/") == true,
                      request.httpMethod == nil || request.httpMethod == "GET" else { return response }
                var task = try PiValue.piRead(response.0, maximumBytes: 1048576).piObject!
                var payload = task["payload"]!.piObject!
                let foreign = PiValue.string(UUID().uuidString.lowercased())
                if mode == "foreign-origin" { payload["originating_message_id"] = foreign }
                if mode == "foreign-conversation" { payload["conversation_id"] = foreign }
                if mode == "foreign-assistant" { payload["assistant_id"] = foreign }
                if mode == "foreign-task" { task["id"] = foreign }
                if mode == "foreign-worker" { task["worker_type"] = .string("pi_worker") }
                task["payload"] = .object(payload)
                return (try PiValue.object(task).piData(), response.1)
            })
            provider = candidate.provider
            let native = NativePiPresentation(factory: {
                NativePiConnection(workspace: candidate.workspace, stop: { await candidate.stop() })
            })
            presentation = native
            await native.connect()
            guard let session = native.session else { throw PiBrokerError.unavailable }
            stage = "create"
            if ["complete", "cancel", "hold-draft", "delayed"].contains(mode) || mode.hasPrefix("foreign-") {
                try piCheck(session.canCreateDocument)
                session.setDraft("Write a workshop plan. Prepare, discuss, then record next steps." + (mode == "delayed" ? " Slow acknowledgment fixture." : ""))
                await session.send()
                await session.refresh()
                try piCheck(session.pendingID == nil && session.tasks.count == 1)
            }
            guard let task = session.tasks.first else { throw PiBrokerError.invalid }
            let inactive: PiValue = .object(["subject": .string(task.originatingMessageID!.uuidString.lowercased()),
                "task_id": .string(task.id), "conversation": .string(session.id.uuidString.lowercased())])
            var inactiveRejected = false
            do { _ = try await candidate.owner.authorizeDocumentHandoff(inactive) }
            catch PiBrokerError.unauthorized { inactiveRejected = true }
            try piCheck(inactiveRejected)
            if mode.hasPrefix("foreign-") {
                _ = try await NativePiTaskStreamFixture.task(session, state: "needs_decision")
                try piCheck(await candidate.provider.documentCalls() == 0)
                try piCheck(session.tasks[0].outputs.isEmpty)
            } else if mode == "cancel" {
                stage = "cancel"
                for _ in 0..<100 {
                    if await candidate.provider.documentActive() { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try piCheck(await candidate.provider.documentActive())
                await session.stop(taskID: task.id)
                _ = try await NativePiTaskStreamFixture.task(session, state: "canceled")
                try piCheck(session.tasks[0].outputs.isEmpty && session.output(taskID: task.id, index: 0) == nil)
                session.setDraft("Continue chatting after cancellation.")
                await session.send()
                try piCheck(session.pendingID == nil)
            } else if mode == "hold-draft" {
                stage = "draft progress"
                try await NativePiTaskStreamFixture.wait { session.tasks.first?.summary == "Drafting the document." }
                let report: [String: Any] = ["task_id": task.id, "draft_progress": true, "real_provider_calls": 0]
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report) + Data([10]))
                while true { try await Task.sleep(for: .seconds(1)) }
            } else {
                if mode == "retry" {
                    stage = "restart decision"
                    let paused = try await NativePiTaskStreamFixture.task(session, state: "needs_decision")
                    try piCheck(await candidate.provider.calls() == 0)
                    guard let decision = paused.decisionID else { throw PiBrokerError.invalid }
                    await session.reply(taskID: task.id, decisionID: UUID().uuidString, approved: true)
                    try piCheck(await candidate.provider.calls() == 0)
                    await session.reply(taskID: task.id, decisionID: decision, approved: true)
                }
                if mode == "complete" {
                    stage = "foreground during drafting"
                    session.setDraft("Keep working on the document.")
                    await session.send()
                    try piCheck(session.pendingID == nil && session.tasks[0].state != "completed")
                }
                stage = "complete"
                let finished = try await NativePiTaskStreamFixture.task(session, state: "completed")
                try piCheck(finished.id == task.id && finished.outputs.count == 1)
                guard let output = finished.outputs.first, let markdown = output.markdown,
                      let url = session.output(taskID: task.id, index: 0) else { throw PiBrokerError.invalid }
                try piCheck(String(data: Data(contentsOf: url), encoding: .utf8) == markdown)
                try piCheck(markdown.contains("[1]") && markdown.contains("## Sources") && markdown.contains("```"))
                let projected = native.conversation!.messages
                let artifacts = projected.flatMap(\.displayBlocks).compactMap { block -> NativeResearchArtifact? in
                    if case .artifact(let value) = block { return value }; return nil
                }
                try piCheck(artifacts.count == 1 && artifacts[0].report == markdown)
                try piCheck(projected.allSatisfy { !$0.nativeEnvelope.speechInput.contains("values[1]") })
                try piCheck(session.output(taskID: UUID().uuidString, index: 0) == nil && session.output(taskID: task.id, index: 1) == nil)
                stage = "file scope"
                let original = try Data(contentsOf: url)
                try Data("changed".utf8).write(to: url)
                try piCheck(session.output(taskID: task.id, index: 0) == nil)
                try original.write(to: url)
                let sibling = url.deletingLastPathComponent().appendingPathComponent("sibling.md")
                try FileManager.default.moveItem(at: url, to: sibling)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: sibling)
                try piCheck(session.output(taskID: task.id, index: 0) == nil)
                try FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: sibling, to: url)
                try piCheck(session.output(taskID: task.id, index: 0) == url)
                if mode == "reopen" { try piCheck(await candidate.provider.calls() == 0) }
            }
            stage = "final projection"
            let report: [String: Any] = ["task_id": task.id, "conversation_id": session.id.uuidString,
                "state": session.tasks[0].state, "artifacts": session.tasks[0].outputs.count,
                "projected_ids": native.conversation!.messages.map { $0.id.uuidString },
                "fixture_calls": await candidate.provider.calls(), "real_provider_calls": 0,
                "real_keychain_reads": 0, "native_components": true, "mode": mode]
            await native.stop()
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]))
        } catch {
            if let session = presentation?.session {
                let tasks = session.tasks.map { "\($0.id):\($0.state):\($0.summary):\($0.decisionPrompt ?? "none")" }.joined(separator: " | ")
                FileHandle.standardError.write(Data("Task diagnostic: \(tasks); fixture calls=\(await provider?.calls() ?? 0); session error=\(session.error ?? "none")\n".utf8))
            }
            if let presentation { await presentation.stop() }
            FileHandle.standardError.write(Data("Native document contract failed during \(stage): \(error)\n".utf8))
            exit(1)
        }
    }
}
