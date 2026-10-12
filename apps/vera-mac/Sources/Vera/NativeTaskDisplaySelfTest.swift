import Foundation

enum NativeTaskDisplaySelfTest {
    static func run() throws {
        let card = NativeTaskCardPresentation(
            id: "request-one", title: "Compare insulation options", status: .working,
            milestone: "Gathered three sources.", canCancel: true)
        let artifact = NativeResearchArtifact(
            id: "report-one", title: "Insulation options", report: "A cited finding. [1]",
            sources: [PulseSource(n: 1, title: "Reference", url: "https://reference.example/report")])
        var envelope = NativeMessageEnvelope(
            spokenText: "I'll compare the options and keep the report here.",
            displayBlocks: [
                .taskCard(card),
                .link(NativeDisplayLink(id: "reference", title: "Reference", url: "https://reference.example/report")),
                .artifact(artifact),
            ])
        let encoded = try JSONEncoder().encode(envelope)
        let reopened = try JSONDecoder().decode(NativeMessageEnvelope.self, from: encoded)
        try expect(reopened == envelope, "Typed display blocks must survive persistence")
        try expect(reopened.speechInput == envelope.spokenText, "Display content must not become spoken text")
        try expect(!reopened.speechInput.contains("reference.example"), "Links must stay out of speech")
        let linkText = NativeSpokenText.clean(
            "Read [the report](https://reference.example/report), or https://another.example/page and www.sample.example.")
        try expect(linkText.contains("the report"), "Speech should retain a link's readable label")
        try expect(!linkText.contains("https") && !linkText.contains(".example"), "Spoken URLs must be removed")
        let silent = NativeMessageEnvelope(spokenText: "", displayBlocks: [.artifact(artifact)])
        try expect(silent.speechInput.isEmpty, "An artifact without spoken text must remain silent")
        for url in ["file:///private/document", "javascript:alert(1)", "https://name:secret@example.com/report"] {
            try expect(NativeDisplayLink(id: "invalid", title: "Invalid", url: url).destination == nil,
                       "Display links must reject unsafe destinations")
        }
        let unsafeSources = [
            PulseSource(n: 1, title: "Local document", url: "file:///private/document"),
            PulseSource(n: 2, title: "Account link", url: "https://name:secret@example.com/report"),
            PulseSource(n: 3, title: "Application link", url: "vera://delete/all"),
            PulseSource(n: 4, title: "Reference", url: "https://reference.example/report"),
        ]
        let safeSources = NativeResearchReportSafety.sources(unsafeSources)
        try expect(safeSources.map(\.title) == unsafeSources.map(\.title),
                   "Rejected source actions must preserve their readable labels")
        try expect(safeSources.prefix(3).allSatisfy { !sourceIsLinked($0.url) },
                   "Unsafe report sources must not become citation actions or favicon requests")
        try expect(safeSources.last?.url == unsafeSources.last?.url,
                   "Safe report sources must remain usable")
        for value in ["file:///private/document", "vera://delete/all", "javascript:alert(1)",
                      "https://name@example.com/report", "https://name:secret@example.com/report"] {
            try expect(NativeResearchReportSafety.destination(value) == nil,
                       "Generated Markdown must reject unsafe link actions")
        }
        try expect(NativeResearchReportSafety.destination("https://reference.example/report") != nil,
                   "Generated Markdown should preserve safe web links")
        var completed = card
        completed.status = .completed
        completed.canCancel = false
        completed.milestone = "The report is ready."
        envelope.reconcile(card: completed, artifact: artifact)
        envelope.reconcile(card: completed, artifact: artifact)
        try expect(envelope.displayBlocks.count == 3, "Replayed completion must not duplicate a card or artifact")
        try expect(envelope.displayBlocks.first == .taskCard(completed), "Progress must update the original block")
        try expect(envelope.spokenText == reopened.spokenText, "Background completion must not rewrite spoken text")
        let unknown = Data("{\"type\":\"unknown\"}".utf8)
        try expect((try? JSONDecoder().decode(NativeDisplayBlock.self, from: unknown)) == nil,
                   "Unknown display blocks must not be interpreted as commands")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "NativeTaskDisplaySelfTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
