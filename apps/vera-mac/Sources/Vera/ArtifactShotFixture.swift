import AppKit
import Foundation

@MainActor
enum ArtifactShotFixture {
    struct Seeded {
        let store: ChatStore
        let selection: String?
    }

    static func store(variant: String) -> Seeded {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandem-artifact-shot-\(UUID().uuidString.lowercased())", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let repository = try? LocalChatRepository(inMemory: true, artifactDirectory: directory) else {
            return Seeded(store: ChatStore(), selection: nil)
        }
        let store = ChatStore(
            nativeConfig: nil, nativeTransport: nil, repository: repository,
            attachmentStore: NativeAttachmentStore(directory: directory),
            artifactPersistenceEnabled: false)
        store.section = .artifacts
        guard variant != "artifacts-empty" else {
            store.reloadArtifacts()
            return Seeded(store: store, selection: nil)
        }
        let conversation = Conversation(id: "shot-greenhouse", title: "Greenhouse plan", messages: [], updatedAt: Date())
        try? repository.saveConversation(conversation)
        store.conversations = [conversation]

        func record(_ draft: ArtifactDraft, revising: String? = nil) -> ArtifactVersion? {
            let version = try? repository.recordArtifact(draft, revising: revising)
            Thread.sleep(forTimeInterval: 0.01)
            return version
        }

        _ = record(ArtifactDraft(
            kind: .canvas, title: "Planting calendar", conversationID: nil, originTitle: nil, messageID: nil,
            sourceKey: "shot:canvas", data: Data(canvasText.utf8), mime: "text/markdown", fileExtension: "md",
            details: ArtifactDetails(canvasType: .markdown)))
        var trashedDetails = ArtifactDetails(filePath: "~/Documents/Garden/old-seed-list.txt", changeKind: .trashed)
        trashedDetails.contentAvailable = false
        let trashed = record(ArtifactDraft(
            kind: .fileChange, title: "old-seed-list.txt", conversationID: conversation.id, originTitle: conversation.title,
            messageID: nil, sourceKey: "shot:trash", data: Data(), mime: "text/plain", fileExtension: "txt",
            details: trashedDetails))
        let fileChange = record(ArtifactDraft(
            kind: .fileChange, title: "beds.md", conversationID: conversation.id, originTitle: conversation.title,
            messageID: nil, sourceKey: "shot:file", data: Data(afterText.utf8), mime: "text/markdown", fileExtension: "md",
            details: ArtifactDetails(filePath: "~/Documents/Garden/beds.md", changeKind: .edited, beforeText: beforeText)))
        let image = record(ArtifactDraft(
            kind: .image, title: "Greenhouse at dusk", conversationID: conversation.id, originTitle: conversation.title,
            messageID: nil, sourceKey: "shot:image", data: gradientPNG(), mime: "image/png", fileExtension: "png",
            details: ArtifactDetails(prompt: "A small glass greenhouse at dusk", imageSize: "1024x640")))
        let sources = [
            PulseSource(n: 1, title: "Extension guide to cold frames", url: "https://example.org/cold-frames"),
            PulseSource(n: 2, title: "Polycarbonate glazing basics", url: "https://example.com/glazing"),
        ]
        let first = record(ArtifactDraft(
            kind: .document, title: "Greenhouse heating options", conversationID: conversation.id,
            originTitle: conversation.title, messageID: nil, sourceKey: "shot:doc:1", data: Data(reportDraft.utf8),
            mime: "text/markdown", fileExtension: "md", details: ArtifactDetails(sources: sources)))
        let document = record(ArtifactDraft(
            kind: .document, title: "Greenhouse heating options", conversationID: conversation.id,
            originTitle: conversation.title, messageID: nil, sourceKey: "shot:doc:2", data: Data(reportRevised.utf8),
            mime: "text/markdown", fileExtension: "md", details: ArtifactDetails(sources: sources)),
            revising: first?.artifactID)
        store.reloadArtifacts()
        let selection: String?
        switch variant {
        case "artifacts-image": selection = image?.artifactID
        case "artifacts-file-change": selection = fileChange?.artifactID
        case "artifacts-trashed": selection = trashed?.artifactID
        default: selection = document?.artifactID
        }
        return Seeded(store: store, selection: selection)
    }

    private static func gradientPNG() -> Data {
        let width = 1024
        let height = 640
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(colors: [
            NSColor(srgbRed: 0.16, green: 0.12, blue: 0.22, alpha: 1),
            NSColor(srgbRed: 0.78, green: 0.45, blue: 0.27, alpha: 1),
            NSColor(srgbRed: 0.96, green: 0.80, blue: 0.55, alpha: 1),
        ])?.draw(in: rect, angle: 90)
        NSColor(srgbRed: 0.10, green: 0.14, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: 150)).fill()
        NSColor(srgbRed: 1, green: 0.93, blue: 0.75, alpha: 0.85).setFill()
        let house = NSBezierPath()
        house.move(to: NSPoint(x: 360, y: 150))
        house.line(to: NSPoint(x: 360, y: 300))
        house.line(to: NSPoint(x: 512, y: 390))
        house.line(to: NSPoint(x: 664, y: 300))
        house.line(to: NSPoint(x: 664, y: 150))
        house.close()
        house.fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private static let reportDraft = """
        ## Summary

        A small hobby greenhouse can stay frost free with passive thermal mass and a thermostat heater [1].
        """

    private static let reportRevised = """
        ## Summary

        A small hobby greenhouse stays frost free through most winters with passive thermal mass, \
        such as water barrels along the north wall, backed by a small thermostat heater for the coldest nights [1].

        ## Glazing

        Twin wall polycarbonate holds heat noticeably better than single pane glass and is far less likely \
        to crack under snow load [2]. It diffuses light too, which keeps seedlings from scorching in early spring.

        ## Recommendation

        - Line the north wall with four dark water barrels.
        - Use twin wall polycarbonate on the roof and south face.
        - Add a 1500 watt heater set to 4 °C as a backstop [1][2].

        ## Sources

        1. Extension guide to cold frames
        2. Polycarbonate glazing basics
        """

    private static let canvasText = """
        # Planting calendar

        | Crop | Start indoors | Transplant |
        | --- | --- | --- |
        | Tomatoes | March | May |
        | Peppers | February | May |
        """

    private static let beforeText = """
        # Raised beds

        ## North bed
        - Garlic
        - Onions

        ## South bed
        - Tomatoes
        - Basil

        Water every other day.
        """

    private static let afterText = """
        # Raised beds

        ## North bed
        - Garlic
        - Leeks
        - Onions

        ## South bed
        - Tomatoes
        - Peppers
        - Basil

        Water every morning in July and August.
        """
}
