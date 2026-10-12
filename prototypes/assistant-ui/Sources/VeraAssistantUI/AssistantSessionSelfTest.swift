import Foundation

@MainActor
enum AssistantSessionSelfTest {
    static func run(root: URL) async throws {
        let artifactRoot = root.appendingPathComponent("outputs")
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        let artifact = artifactRoot.appendingPathComponent("sum.py")
        try Data("result".utf8).write(to: artifact)
        let fixture = WorkspaceFixture(artifact: artifact)
        let endpoint = URL(string: "http://127.0.0.1:49152")!
        let workspace = try AssistantWorkspace(dataRoot: root.appendingPathComponent("state"), endpoint: endpoint,
            workspaceRoot: artifactRoot, runtimeIdentity: "native-session") { try await fixture.send($0) }
        let session = workspace.session
        session.setDraft("/task Native session")
        await session.send()
        let initialPaths = await fixture.paths
        try PrototypeSelfTest.require(initialPaths.isEmpty, "Unconnected native session cannot send")
        await session.refresh()
        await session.send()
        await session.refresh()
        guard let task = session.tasks.first, let decision = task.decisionID else { throw PrototypeError.invalidResponse }
        let before = await fixture.paths
        await session.reply(taskID: task.id, decisionID: UUID().uuidString, approved: true)
        await session.stop(taskID: UUID().uuidString)
        let after = await fixture.paths
        try PrototypeSelfTest.require(before == after, "Stale decision and unknown task have no effects")
        await session.reply(taskID: task.id, decisionID: decision, approved: true)
        session.setDraft("Foreground reply")
        await session.send()
        await session.refresh()
        await session.refresh()
        await session.refresh()
        try PrototypeSelfTest.require(session.messages.filter { $0.id == "task:" + task.id }.count == 1,
            "Native facade projects one completed result")
        try PrototypeSelfTest.require(session.output(taskID: task.id, index: 0) == artifact, "Native output uses checked workspace")
        try FileManager.default.removeItem(at: artifact)
        try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: root.appendingPathComponent("state/assistant-ui.json"))
        try PrototypeSelfTest.require(session.output(taskID: task.id, index: 0) == nil && session.tasks.first?.outputs.isEmpty == true,
            "Output click revalidates a replaced file")
        let recoveryFixture = ContractFixture()
        let recovery = try AssistantWorkspace(dataRoot: root.appendingPathComponent("recovery"), endpoint: endpoint,
            workspaceRoot: artifactRoot, runtimeIdentity: "native-recovery") { try await recoveryFixture.send($0) }
        await recoveryFixture.bind(recovery.assistantID, recovery.session.id)
        await recovery.session.refresh()
        recovery.session.setDraft("Accepted work")
        await recoveryFixture.interruptNextMessage()
        await recovery.session.send()
        guard let pending = recovery.session.pendingID else { throw PrototypeError.invalidResponse }
        await recovery.session.refresh()
        let originalTasks = recovery.session.tasks.map(\.id)
        await recovery.session.review(messageID: UUID())
        recovery.session.continueWithoutReply(messageID: pending)
        try PrototypeSelfTest.require(recovery.session.pendingID == pending, "Review requires displayed request identity")
        await recovery.session.retry(messageID: pending)
        await recovery.session.review(messageID: pending)
        recovery.session.setDraft("Edited draft")
        recovery.session.continueWithoutReply(messageID: UUID())
        try PrototypeSelfTest.require(recovery.session.pendingID == pending, "Stale recovery action cannot archive a request")
        let sends = await recoveryFixture.requests.count
        recovery.session.continueWithoutReply(messageID: pending)
        let finalSends = await recoveryFixture.requests.count
        try PrototypeSelfTest.require(sends == finalSends && recovery.session.pendingID == nil
            && recovery.session.draft == "Edited draft" && recovery.session.tasks.map(\.id) == originalTasks,
            "Native recovery archives without sending, canceling tasks or clearing edited draft")
        print("PASS: nonvisual native session, scoped actions, stale token rejection, result identity and recovery")
    }
}
