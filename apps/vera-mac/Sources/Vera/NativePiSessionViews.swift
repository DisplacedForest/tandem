import SwiftUI
import VeraAssistantUI

struct NativePiSessionStatus: View {
    @ObservedObject var assistant: NativePiPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = assistant.session {
                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                if let pendingID = session.pendingID, !session.busy {
                    Text("This reply wasn't confirmed. Review your message and its tasks before continuing.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    HStack {
                        Button("Retry reply") { Task { await session.retry(messageID: pendingID) } }.disabled(!session.canRetry)
                        Button("Review unconfirmed reply") { Task { await session.review(messageID: pendingID) } }.disabled(session.reviewing)
                    }
                    if session.canContinue {
                        Text(session.pendingText ?? "").font(.system(size: 12)).textSelection(.enabled)
                        Text("Continuing leaves existing tasks running and doesn't send this message again.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        Button("Continue without reply") { session.continueWithoutReply(messageID: pendingID) }
                    }
                }
            } else if assistant.starting {
                ProgressView("Connecting").controlSize(.small)
            } else {
                Text(assistant.failure ?? "The assistant isn't connected yet. Your focused chats are still available.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                if assistant.canConnect { Button("Connect assistant") { Task { await assistant.connect() } } }
            }
        }
        .font(.system(size: 12))
    }
}

struct NativePiTaskSection: View {
    @ObservedObject var assistant: NativePiPresentation
    var messageID: UUID? = nil
    @State private var document: NativeResearchArtifact?
    var body: some View {
        if let session = assistant.session {
            ForEach(assistant.tasks(for: messageID)) { task in
                VStack(alignment: .leading, spacing: 8) {
                    NativeTaskCardView(card: Self.card(task), statusTitle: task.status, stopTitle: "Stop",
                        onCancel: { Task { await session.stop(taskID: task.id) } })
                    if let decisionID = task.decisionID {
                        NativeToolConfirmationBar(request: Self.confirmation(task, decisionID), prompt: task.decisionPrompt,
                            defaultApproval: false,
                            allowApprove: !task.busy && session.connected && task.savedApproval != false,
                            allowDecline: !task.busy && session.connected && task.savedApproval != true) { approved in
                                Task { await session.reply(taskID: task.id, decisionID: decisionID, approved: approved) }
                            }
                    }
                    if let error = task.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(task.outputs) { output in
                        if let markdown = output.markdown {
                            Button {
                                document = NativeResearchArtifact(id: task.id, title: output.title, report: markdown, sources: [])
                            } label: {
                                ArtifactChip(artifact: Artifact(id: task.id, title: output.title, type: .unknown,
                                    language: "markdown", content: markdown), detail: "Read document")
                            }.buttonStyle(.plain).accessibilityLabel("Read document: " + output.title)
                        }
                        Button {
                            if let url = session.output(taskID: task.id, index: output.id) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        } label: {
                            ArtifactChip(artifact: Artifact(id: task.id + ":" + String(output.id), title: output.title,
                                type: .unknown, language: "", content: ""), detail: "Show in Finder")
                        }
                        .buttonStyle(.plain)
                        .disabled(session.output(taskID: task.id, index: output.id) == nil)
                        .accessibilityLabel("Reveal document: " + output.title)
                    }
                }
            }
            .sheet(item: $document) { NativeResearchReportView(artifact: $0).frame(minWidth: 600, minHeight: 500) }
        }
    }
    static func card(_ task: AssistantSessionTask) -> NativeTaskCardPresentation {
        let status: NativeTaskCardPresentation.Status
        switch task.state {
        case "completed": status = .completed
        case "canceled": status = .stopped
        case "failed": status = .failed
        case "needs_decision", "blocked": status = .needsInput
        case "running": status = .working
        default: status = .queued
        }
        return NativeTaskCardPresentation(id: task.id, title: task.title, status: status,
            milestone: task.summary, canCancel: task.canStop && !task.busy)
    }
    static func confirmation(_ task: AssistantSessionTask, _ decisionID: String) -> NativeToolConfirmationRequest {
        NativeToolConfirmationRequest(activity: NativeToolActivity(id: decisionID, toolID: "pi_worker", name: "worker",
            title: task.title, round: 0, request: "", result: nil, state: .pending, confirmationRequired: true))
    }
}
