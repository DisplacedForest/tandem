import AppKit
import Foundation
import SwiftUI
import VeraAssistantUI

private actor NativePiTranscriptFixture {
    let user = UUID(), reply = UUID(), interrupted = UUID()
    let completed = UUID(), waiting = UUID(), orphan = UUID()
    private let orphanOrigin = UUID(), decision = UUID()
    private var assistant = UUID(), conversation = UUID()

    func configure(assistant: UUID, conversation: UUID) {
        self.assistant = assistant
        self.conversation = conversation
    }

    func send(_ request: URLRequest) throws -> (Data, Int) {
        guard request.httpMethod == nil || request.httpMethod == "GET" else { throw PiBrokerError.unauthorized }
        let object: [String: Any]
        switch request.url?.path {
        case "/assistant/capabilities":
            object = ["protocol_version": 1, "foreground": true, "worker": true, "computers": false, "transport": "mock"]
        case "/assistant/messages":
            object = ["messages": [
                ["id": user.uuidString, "role": "user", "text": "Check the addition example", "task_ids": []],
                ["id": reply.uuidString, "role": "assistant", "text": "I'll keep the result here. https://example.invalid/reference", "task_ids": [completed.uuidString.lowercased()]],
                ["id": interrupted.uuidString, "role": "user", "text": "Check another example", "task_ids": []],
                ["id": "task:" + completed.uuidString.lowercased(), "role": "assistant", "text": "The addition example passed.", "task_ids": [completed.uuidString.lowercased()]]]]
        case "/tasks":
            object = ["tasks": [task(completed, origin: user, state: "completed"),
                task(waiting, origin: interrupted, state: "needs_decision"), task(orphan, origin: orphanOrigin, state: "running")]]
        default: throw PiBrokerError.invalid
        }
        return (try JSONSerialization.data(withJSONObject: object), 200)
    }

    private func task(_ id: UUID, origin: UUID, state: String) -> [String: Any] {
        var result: [String: Any] = ["id": id.uuidString.lowercased(), "worker_type": "pi_worker", "state": state,
            "cancel_requested": false, "updated_at": 1.0,
            "payload": ["assistant_id": assistant.uuidString, "conversation_id": conversation.uuidString,
                "originating_message_id": origin.uuidString, "objective": state == "completed" ? "Check the addition example" : "Check another example"]]
        if state == "completed" {
            result["result"] = ["summary": "The addition example passed.", "artifacts": [
                ["kind": "file", "path": "sum.py", "title": "Addition example"],
                ["kind": "file", "path": "../outside.py", "title": "Unavailable outside file"]]]
        }
        if state == "needs_decision" { result["decision"] = ["id": decision.uuidString, "prompt": "Allow the worker to edit the example?"] }
        return result
    }
}

@MainActor
enum NativePiTranscriptSelftest {
    static func run(root: URL) async throws {
        let fixtures = NativePiTranscriptFixture()
        let files = root.appendingPathComponent("outputs")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("print(1 + 1)\n".utf8).write(to: files.appendingPathComponent("sum.py"))
        try Data("outside\n".utf8).write(to: root.appendingPathComponent("outside.py"))
        let workspace = try AssistantWorkspace(dataRoot: root.appendingPathComponent("transcript-ui"),
            endpoint: URL(string: "http://127.0.0.1:49153")!, workspaceRoot: files,
            runtimeIdentity: "transcript-fixture") { try await fixtures.send($0) }
        await fixtures.configure(assistant: workspace.assistantID, conversation: workspace.session.id)
        let presentation = NativePiPresentation(factory: { NativePiConnection(workspace: workspace, stop: {}) })
        await presentation.connect()
        guard let conversation = presentation.conversation else { throw PiBrokerError.invalid }
        let replyID = NativePiPresentation.messageID(conversation: workspace.session.id, source: fixtures.reply.uuidString)
        let interruptedID = NativePiPresentation.messageID(conversation: workspace.session.id, source: fixtures.interrupted.uuidString)
        let resultID = NativePiPresentation.messageID(conversation: workspace.session.id, source: "task:" + fixtures.completed.uuidString.lowercased())
        try piCheck(presentation.tasks(for: replyID).map(\.id) == [fixtures.completed.uuidString.lowercased()])
        try piCheck(presentation.tasks(for: interruptedID).map(\.id) == [fixtures.waiting.uuidString.lowercased()])
        try piCheck(presentation.tasks(for: resultID).isEmpty && presentation.tasks(for: nil).map(\.id) == [fixtures.orphan.uuidString.lowercased()])
        guard let reply = conversation.messages.first(where: { $0.id == replyID }) else { throw PiBrokerError.invalid }
        try piCheck(reply.displayBlocks.count == 2 && !reply.nativeEnvelope.speechInput.contains("https")
            && !reply.nativeEnvelope.speechInput.contains("sum.py"))
        guard case .artifact(let artifact) = reply.displayBlocks[1], let reference = artifact.taskOutput else { throw PiBrokerError.invalid }
        try piCheck(reference.taskID == fixtures.completed.uuidString.lowercased() && reference.index == 0)
        try piCheck(workspace.session.output(taskID: reference.taskID, index: reference.index) == files.appendingPathComponent("sum.py").resolvingSymlinksInPath())
        let reopened = try JSONDecoder().decode(NativeMessageEnvelope.self, from: JSONEncoder().encode(reply.nativeEnvelope))
        try piCheck(reopened == reply.nativeEnvelope)
        let legacy = Data(#"{"id":"legacy","title":"Saved report","report":"Saved content","sources":[]}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(NativeResearchArtifact.self, from: legacy)
        try piCheck(legacyDecoded.taskOutput == nil)
        let originalIDs = conversation.messages.map(\.id)
        await workspace.session.refresh()
        try piCheck(presentation.conversation?.messages.map(\.id) == originalIDs)
        try piCheck(presentation.tasks(for: replyID).count == 1)
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--task-card-shot"), flag + 1 < arguments.count {
            try render(presentation, to: URL(fileURLWithPath: arguments[flag + 1]))
        }
        await presentation.stop()
        try piCheck(presentation.conversation == nil && !presentation.canSend)
        print("PASS: transcript handoff placement, interrupted origin, single result card, typed safe output and speech separation")
    }

    private static func render(_ presentation: NativePiPresentation, to url: URL) throws {
        _ = NSApplication.shared
        guard let conversation = presentation.conversation else { throw PiBrokerError.invalid }
        let content = VStack(alignment: .leading, spacing: 20) {
            Text("Task transcript fixture").font(.headline)
            ForEach(conversation.messages) { message in
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.text).font(.system(size: 14)).foregroundStyle(Theme.textPrimary)
                    NativePiTaskSection(assistant: presentation, messageID: message.id)
                }
            }
        }.padding(24).frame(width: 720, height: 860, alignment: .topLeading).background(Theme.bg)
            .environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 860)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw PiBrokerError.invalid }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PiBrokerError.invalid }
        try png.write(to: url)
    }
}
