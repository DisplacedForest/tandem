import AppKit
import Darwin
import Foundation
import MarkdownUI
import SwiftUI

@MainActor
enum NativeDocumentArtifactSelftest {
    private enum Failure: Error { case invalid }
    private static let maximumBytes = 1048576
    private static let fixtureID = "28be82a8-c436-4f34-8c86-9d17062c34de"
    private static let markdown = """
    # Workshop notes

    Keep literal [1] and [2, 3] in the document.

    ```text
    values[1] = "retained"
    https://reference.example/a https://reference.example/b
    ```

    [Unsafe link](file:///private/example) and [safe link](https://reference.example/notes).

    ![Omitted image](https://image.example/notes.png)

    ## Sources

    This section is part of the document.

    ## Next steps

    Keep this final paragraph too.
    """

    private static func require(_ condition: Bool) throws {
        guard condition else { throw Failure.invalid }
    }

    private static func fixture() -> [String: Any] {
        ["id": fixtureID, "worker_type": "document", "state": "completed", "result": [
            "kind": "document_report", "title": "Workshop notes", "markdown": markdown,
            "spoken_text": "The document is ready.", "display_blocks": [["type": "artifact", "artifact": [
                "id": fixtureID, "title": "Workshop notes", "report": markdown, "sources": []
            ]]]
        ]]
    }

    private static func consume(_ data: Data) throws -> NativeResearchArtifact {
        try NativeTaskJSON.validate(data, maximumBytes: maximumBytes)
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = snapshot["id"] as? String, UUID(uuidString: id) != nil,
              snapshot["worker_type"] as? String == "document", snapshot["state"] as? String == "completed",
              let result = snapshot["result"] as? [String: Any], result["kind"] as? String == "document_report",
              let title = result["title"] as? String, (1...200).contains(title.unicodeScalars.count),
              let markdown = result["markdown"] as? String, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let spoken = result["spoken_text"] as? String, spoken == "The document is ready." else { throw Failure.invalid }
        let envelope = try JSONDecoder().decode(NativeMessageEnvelope.self, from: JSONSerialization.data(withJSONObject: result))
        guard envelope.displayBlocks.count == 1, case .artifact(let artifact) = envelope.displayBlocks[0] else { throw Failure.invalid }
        try require(artifact.id == id && artifact.title == title && artifact.report == markdown
            && artifact.sources.isEmpty && artifact.taskOutput == nil)
        try require(envelope.speechInput == NativeSpokenText.clean(spoken))
        let reopened = try JSONDecoder().decode(NativeMessageEnvelope.self, from: JSONEncoder().encode(envelope))
        try require(reopened == envelope && reopened.displayBlocks[0].id == "artifact:" + id)
        let report = NativeResearchReportView(artifact: artifact)
        try require(report.reportText == markdown)
        try require(NativeArtifactMarkdown(text: report.reportText).content == MarkdownContent(markdown))
        _ = report.body
        _ = NativeDisplayBlocksView(blocks: reopened.displayBlocks).body
        return artifact
    }

    private static func tests() throws -> NativeResearchArtifact {
        let original = fixture()
        let artifact = try consume(JSONSerialization.data(withJSONObject: original))
        let content = NativeArtifactMarkdown(text: NativeResearchReportView(artifact: artifact).reportText).content
        let plain = content.renderPlainText()
        try require(plain.contains("literal [1] and [2, 3]") && plain.contains("Sources")
            && plain.contains("Keep this final paragraph too.")
            && plain.contains("https://reference.example/a https://reference.example/b"))
        try require(content != MarkdownContent(SourceFormatter.apply(markdown)))
        let cited = NativeResearchArtifact(id: fixtureID, title: "Research", report: markdown,
            sources: [PulseSource(n: 1, title: "Reference", url: "https://reference.example/notes")])
        try require(NativeResearchReportView(artifact: cited).reportText == PulseMarkers.stripSourcesSection(markdown))
        try require(NativeResearchReportView(artifact: cited).reportText != markdown)
        for invalid in ["file:///private/example", "javascript:alert(1)", "vera://delete/all",
                        "https://name:secret@reference.example/notes"] {
            try require(NativeResearchReportSafety.destination(invalid) == nil)
        }
        try require(NativeResearchReportSafety.destination("https://reference.example/notes") != nil)
        var invalidValues: [[String: Any]] = []
        for (key, value) in [("worker_type", "research"), ("state", "running"), ("id", "invalid")] {
            var snapshot = original
            snapshot[key] = value
            invalidValues.append(snapshot)
        }
        for key in ["kind", "title", "markdown", "spoken_text", "display_blocks"] {
            var snapshot = original
            var result = snapshot["result"] as! [String: Any]
            if key == "display_blocks" { result[key] = [] }
            else { result[key] = "mismatched" }
            snapshot["result"] = result
            invalidValues.append(snapshot)
        }
        for key in ["id", "title", "report", "sources", "taskOutput"] {
            var snapshot = original
            var result = snapshot["result"] as! [String: Any]
            var blocks = result["display_blocks"] as! [[String: Any]]
            var output = blocks[0]["artifact"] as! [String: Any]
            if key == "sources" { output[key] = [["n": 1, "title": "Reference", "url": "local"]] }
            else if key == "taskOutput" { output[key] = ["taskID": fixtureID, "index": 0] }
            else { output[key] = "mismatched" }
            blocks[0]["artifact"] = output
            result["display_blocks"] = blocks
            snapshot["result"] = result
            invalidValues.append(snapshot)
        }
        for snapshot in invalidValues {
            let bytes = try JSONSerialization.data(withJSONObject: snapshot)
            try require((try? consume(bytes)) == nil)
        }
        try require((try? consume(Data("{\"id\":\"a\",\"id\":\"b\"}".utf8))) == nil)
        try require((try? consume(Data(repeating: 32, count: maximumBytes + 1))) == nil)
        return artifact
    }

    private static func read(_ path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes,
              let bytes = try handle.read(upToCount: maximumBytes + 1), bytes.count <= maximumBytes else { throw Failure.invalid }
        return bytes
    }

    private static func render(_ artifact: NativeResearchArtifact, path: String) throws {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let size = NSSize(width: 800, height: 900)
        let hosting = NSHostingView(rootView: NativeResearchReportView(artifact: artifact)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw Failure.invalid }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.invalid }
        try png.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }

    static func run(_ arguments: [String]) async {
        do {
            try require(arguments.count.isMultiple(of: 2) && arguments.count <= 4)
            var options: [String: String] = [:]
            for index in stride(from: 0, to: arguments.count, by: 2) {
                let key = arguments[index]
                try require(["--snapshot", "--shot"].contains(key) && options[key] == nil && !arguments[index + 1].isEmpty)
                options[key] = arguments[index + 1]
            }
            var artifact = try tests()
            if let path = options["--snapshot"] { artifact = try consume(read(path)) }
            if let path = options["--shot"] { try render(artifact, path: path) }
            let evidence: [String: Any] = ["artifact_id": artifact.id, "artifact_count": 1,
                "markdown_bytes": artifact.report.utf8.count, "content_preserved": true,
                "speech_uses_spoken_text_only": true, "typed_roundtrip": true,
                "api_snapshot": options["--snapshot"] != nil, "offscreen_render": options["--shot"] != nil,
                "automatic_task_discovery": false, "real_provider_calls": 0, "visible_launch": false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) + Data([10]))
        } catch {
            FileHandle.standardError.write(Data("Document artifact fixture failed.\n".utf8))
            exit(1)
        }
    }
}
