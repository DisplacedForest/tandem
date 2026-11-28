import AppKit
import SwiftUI

@MainActor
enum ConversationShot {
    static func render(view: String, to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        let size = NSSize(width: view.hasSuffix("narrow") ? 380 : view.hasSuffix("large") ? 1800 : 1000, height: 1000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-shot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil,
                              attachmentStore: NativeAttachmentStore(directory: directory))
        store.newConversation()
        let companion = view.contains("companion")
        var messages = [
            Message(role: .user, text: "Compare the two plans and explain the tradeoffs."),
            Message(role: .assistant, text: """
            The first plan is the best fit if you want to start this week.

            ## What changes

            Both plans cover the same work. The difference is how much preparation happens before the first session, and how much time you need afterward.

            | Plan | Preparation | Follow-up |
            | --- | --- | --- |
            | Start this week | Review the materials | Adjust after the first session |
            | Prepare first | Finish the full outline | Follow the agreed schedule |

            **Start with one session**, then review what worked before committing to the rest. Keep a short list of questions so the next session builds on what you learned.

            You can change the schedule without losing the notes or decisions from earlier sessions.
            """),
            Message(role: .user, text: "What should I prepare first?"),
            Message(role: .assistant, text: view.contains("streaming") ? "Gather the materials you already have, then" : "Gather the materials you already have and write down the main question you want to answer.", state: view.contains("streaming") ? .streaming : .complete)
        ]
        var confirmation: NativeToolConfirmationRequest?
        var confirmationMessageID: UUID?
        if view.contains("tools") {
            let activity = NativeToolActivity(id: "fixture-read", toolID: "mcp_fixture", name: "catalog__find_items",
                title: "Garden service: catalog__find_items", round: 1, request: "{\"area\":\"greenhouse\"}",
                result: "{\"level\":50}", state: .succeeded, confirmationRequired: false)
            var failed = activity
            failed.state = .failed
            failed.result = "{\"error\":\"The service isn't responding. Try again later.\"}"
            messages = [
                Message(role: .user, text: "Set the greenhouse lights to 50%."),
                Message(role: .assistant, text: "The greenhouse lights are at 50%.", toolActivities: [activity]),
                Message(role: .assistant, text: "", toolActivities: [activity]),
                Message(role: .user, text: "Return them to their earlier brightness."),
            ]
            var pending = activity
            pending.state = .pending
            pending.request = #"{"name":"garden__read_history","arguments":"{\"item_ids\":[\"greenhouse-lights\"],\"start_time\":\"2026-11-28T08:00:00\"}"}"#
            let message = Message(role: .assistant, text: "", toolActivities: [view.hasSuffix("failure") ? failed : pending])
            messages.append(message)
            if !view.hasSuffix("failure") && !view.hasSuffix("progress") {
                var request = NativeToolConfirmationRequest(activity: pending)
                request.subject = NativeCardSubject(action: .serviceChanges, toolID: pending.toolID, toolTitle: pending.title,
                    service: NativeServiceTool(tool: "Dispatch", service: "Garden service", detail: "Runs the requested operation."))
                confirmation = request
                confirmationMessageID = message.id
            }
        }
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(messages) { message in
                        MessageRow(message: message, pendingConfirmation: message.id == confirmationMessageID ? confirmation : nil,
                                   onToolDecision: { _, _ in }, companionThread: companion)
                    }
                }
                .padding(28)
                .frame(maxWidth: ConversationMetrics.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            ComposerField().padding(24).frame(maxWidth: ConversationMetrics.columnWidth)
        }
            .environmentObject(store).environmentObject(config)
            .frame(width: size.width, height: size.height)
            .background(Theme.conversationBackground).environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: AppLocations.checkedOutput(path)); print("Rendered conversation") }
        catch { exit(1) }
    }
}
