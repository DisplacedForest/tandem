import Foundation

@MainActor
extension SelfTest {
    static func plainCompanionRows() throws {
        let require = NativeTaskFixture.require
        let finished = NativeToolActivity(id: "read", toolID: "mcp_fixture", name: "catalog__find_items", title: "Garden service: catalog__find_items", round: 1,
            request: "{\"area\":\"greenhouse\"}", result: "{\"found\":true}", state: .succeeded, confirmationRequired: false)
        let completed = Message(role: .assistant, text: "The greenhouse lights are at 50%.", toolActivities: [finished])
        try require(NativeTaskTranscript.visibleActivities(in: completed, companionThread: true).isEmpty,
                    "Companion results never show service selectors or tool rows")
        try require(NativeTaskTranscript.visibleActivities(in: completed).map(\.id) == ["read"],
                    "Ordinary chat retains its compact activity and deliberate inspection")
        try require(NativeToolActivityChip.activityLabel(finished) == "Garden service", "Ordinary activity names the service without its selector")
        try require(completed.toolActivities == [finished], "Presentation preserves exact activity records")
        try require(NativeTaskTranscript.showsCompanionMessage(completed, awaitingDecision: false), "The verified result remains visible")
        let historical = Message(role: .assistant, text: "", toolActivities: [finished])
        try require(!NativeTaskTranscript.showsCompanionMessage(historical, awaitingDecision: false),
                    "A historical activity-only reply does not leave an empty avatar or invented answer")
        var waiting = finished
        waiting.state = .pending
        let live = Message(role: .assistant, text: "", toolActivities: [waiting])
        try require(NativeTaskTranscript.companionStatus(in: live, awaitingDecision: false) == "Working on your request.",
                    "An active call without prose remains visible")
        try require(NativeTaskTranscript.companionStatus(in: live, awaitingDecision: true) == nil
                    && NativeTaskTranscript.showsCompanionMessage(live, awaitingDecision: true), "A necessary approval remains visible without a working claim")
        var failed = finished
        failed.state = .failed
        failed.result = "{\"error\":\"The service is unavailable. Try again later.\"}"
        try require(NativeTaskTranscript.companionStatus(in: Message(role: .assistant, text: "", toolActivities: [failed]), awaitingDecision: false)
                    == "I couldn't finish that request.", "An empty failed reply never disappears")
        try require(NativeToolActivityChip.failureSummary(failed) == "The service is unavailable. Try again later.",
                    "An ordinary failed call keeps its actionable error visible")
        var canceled = finished
        canceled.state = .canceled
        try require(NativeTaskTranscript.companionStatus(in: Message(role: .assistant, text: "", toolActivities: [canceled]), awaitingDecision: false)
                    == "That request was stopped.", "Cancellation stays visible without execution metadata")
        let command = NativeDisplayBlock.commandRun(NativeCommandRun(id: "command", command: "make report", directory: "/tmp", outcome: .timedOut))
        let link = NativeDisplayBlock.link(NativeDisplayLink(id: "result", title: "Open the report", url: "https://example.org/report"))
        let withBlocks = Message(role: .assistant, text: "The report is ready.", displayBlocks: [command, link])
        try require(NativeTaskTranscript.visibleBlocks(in: withBlocks, companionThread: true).map(\.id) == [link.id],
                    "Companion results retain useful links and omit execution panels")
        try require(NativeTaskTranscript.visibleBlocks(in: withBlocks, companionThread: false).count == 2, "Normal chat keeps its command outcome")
        let commandFailure = Message(role: .assistant, text: "", displayBlocks: [command])
        try require(NativeTaskTranscript.showsCompanionMessage(commandFailure, awaitingDecision: false)
                    && NativeTaskTranscript.companionStatus(in: commandFailure, awaitingDecision: false) == "I couldn't finish that request.",
                    "A failed hidden command panel retains a truthful visible outcome")
        let lockQuestion = CompanionPermissionText.question(service: "Door service", action: "doors__lock_door")
        let unlockQuestion = CompanionPermissionText.question(service: "Door service", action: "doors__unlock_door")
        let target = CompanionPermissionText.arguments(#"{"entity_id":"front-door"}"#)
        try require(lockQuestion.contains("Lock door") && unlockQuestion.contains("Unlock door")
                    && lockQuestion != unlockQuestion && target == "Entity id: front-door",
                    "Equal inputs for opposing service actions retain distinct readable approval questions")
        try require(!lockQuestion.contains("__") && !unlockQuestion.contains("__"),
                    "Action questions remove raw service namespaces without removing action meaning")
        let nested = #"{"name":"garden__read_history","arguments":"{\"item_ids\":[\"greenhouse-lights\"],\"start_time\":\"2026-11-28T08:00:00\",\"changes_only\":false}"}"#
        let nestedQuestion = CompanionPermissionText.question(service: "Garden service", action: "Dispatch", details: nested)
        try require(nestedQuestion.contains("Read history") && !nestedQuestion.contains("Dispatch"),
                    "Exact dispatcher structure shows the requested operation in its approval question")
        try require(CompanionPermissionText.question(service: "Door service", action: "doors__lock_door", details: #"{"name":"front-door","level":0.5}"#) == lockQuestion,
                    "Ordinary name inputs cannot replace the actual service action")
        let shown = CompanionPermissionText.arguments(nested, service: "Garden service") ?? ""
        try require(shown.contains("Action: Read history") && shown.contains("Item ids: greenhouse-lights")
                    && shown.contains("Changes only: No") && shown.contains("Start time: 2026-11-28T08:00:00"),
                    "A dispatcher approval explains its action and nested inputs")
        try require(!shown.contains("garden__read_history") && !shown.contains("{") && !shown.contains("["),
                    "Ordinary approval contains no namespace selector or JSON dump")
        let old = NativeCompanionWorker.shownDetails("Dispatch", argumentsJSON: nested)
        try require(CompanionPermissionText.question(service: "Garden service", action: "Dispatch", details: old) == nestedQuestion,
                    "Saved dispatcher details show the same requested operation in the approval question")
        try require(CompanionPermissionText.savedDetails(old, service: "Garden service") == shown, "Saved delegated approval details use the same plain presentation")
        try require(CompanionPermissionText.arguments("not json") == nil, "Malformed saved inputs are never presented as readable approval details")
        try require(CompanionPermissionText.arguments(#"{"name":"My_name","level":0.5}"#)?.contains("Name: My_name") == true,
                    "Names that are ordinary input data keep their exact spelling")
        var request = NativeToolConfirmationRequest(activity: waiting)
        request.subject = NativeCardSubject(action: .serviceChanges, toolID: waiting.toolID, toolTitle: waiting.title,
                                           service: NativeServiceTool(tool: "Dispatch", service: "Garden service", detail: "Applies the selected operation."))
        let bar = NativeToolConfirmationBar(request: request, onDecision: { _ in }, onChoice: { _, _ in }, companionThread: true)
        try require(bar.answers.allowMenu.isEmpty && bar.answers.declineMenu.isEmpty,
                    "Companion decisions offer Allow and Decline without per-tool implementation menus")
    }
}
