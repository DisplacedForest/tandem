import Foundation
import GRDB

enum ArtifactStoreSelftest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func run() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vera-artifact-selftest-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: directory)

        func files() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        }

        let report = ArtifactDraft(
            kind: .document, title: "Report", conversationID: "conversation-a", originTitle: "Trip planning",
            messageID: "message-1", sourceKey: "research:1", data: Data("# Report".utf8),
            mime: "text/markdown", fileExtension: "md",
            details: ArtifactDetails(sources: [PulseSource(n: 1, title: "Source", url: "https://example.com")]))
        let first = try repository.recordArtifact(report, revising: nil)
        try check(first.ordinal == 1, "A new artifact starts at ordinal 1")
        try check(first.fileName.hasPrefix("artifact-") && first.fileName.hasSuffix(".md"), "Artifact files use the artifact prefix and extension")
        try check(first.byteSize == 8, "Byte size matches the draft data")
        let listed = try repository.listArtifacts()
        try check(listed.count == 1 && listed[0].versionCount == 1 && listed[0].kind == .document, "The list shows one document with one version")
        try check(listed[0].title == "Report" && listed[0].originTitle == "Trip planning", "Title and origin title persist")
        try check(try files() == [first.fileName], "The bytes land in the artifact directory")
        try check(try Data(contentsOf: directory.appendingPathComponent(first.fileName)) == Data("# Report".utf8), "The stored bytes match the draft")
        try check(try repository.referencedAttachmentFileNames().contains(first.fileName), "Artifact files are protected from the orphan sweep")

        let repeated = try repository.recordArtifact(report, revising: nil)
        try check(repeated == first, "Recording the same source key returns the existing version")
        try check(try files().count == 1, "Recording the same source key writes no second file")
        try check(try repository.listArtifacts().count == 1, "Recording the same source key adds no artifact")

        var revision = report
        revision.title = "Report, revised"
        revision.sourceKey = "research:2"
        revision.data = Data("# Report v2".utf8)
        Thread.sleep(forTimeInterval: 0.01)
        let other = try repository.recordArtifact(
            ArtifactDraft(
                kind: .canvas, title: "Diagram", conversationID: "conversation-b", originTitle: "Diagrams",
                messageID: nil, sourceKey: "canvas:1", data: Data("graph TD".utf8), mime: "text/plain",
                fileExtension: "mmd", details: ArtifactDetails(canvasType: .mermaid, language: "mermaid")),
            revising: nil)
        Thread.sleep(forTimeInterval: 0.01)
        let second = try repository.recordArtifact(revision, revising: first.artifactID)
        try check(second.artifactID == first.artifactID && second.ordinal == 2, "A revision appends the next ordinal")
        let afterRevision = try repository.listArtifacts()
        try check(afterRevision.first?.id == first.artifactID, "The revised artifact sorts first")
        try check(afterRevision.first?.versionCount == 2, "The revised artifact counts two versions")
        try check(afterRevision.first?.title == "Report, revised", "A revision updates the title")
        try check(try repository.artifactVersions(first.artifactID).map(\.ordinal) == [1, 2], "Versions list in ordinal order")
        try check(try repository.artifactVersion(sourceKey: "research:2") == second, "A version is found by source key")
        try check(try repository.artifact(first.artifactID)?.versionCount == 2, "A single artifact reports its version count")
        try check(try repository.artifact("missing") == nil, "A missing artifact reads as nil")

        let image = try repository.recordArtifact(
            ArtifactDraft(
                kind: .image, title: "Sketch", conversationID: "conversation-a", originTitle: "Trip planning",
                messageID: nil, sourceKey: "image:1", data: Data([0x89, 0x50]), mime: "image/png",
                fileExtension: "png", details: ArtifactDetails(prompt: "a sketch", imageSize: "1024x1024")),
            revising: first.artifactID)
        try check(image.artifactID != first.artifactID && image.ordinal == 1, "Revising across kinds creates a separate artifact")
        let orphanRevision = try repository.recordArtifact(
            ArtifactDraft(
                kind: .fileChange, title: "notes.txt", conversationID: "conversation-c", originTitle: "Files",
                messageID: nil, sourceKey: "file:1", data: Data("after".utf8), mime: "text/plain",
                fileExtension: "txt",
                details: ArtifactDetails(filePath: "notes.txt", changeKind: .edited, beforeText: "before", truncated: true)),
            revising: "missing")
        try check(orphanRevision.ordinal == 1 && orphanRevision.artifactID != "missing", "Revising a missing artifact creates a new one")
        try check(try repository.listArtifacts().count == 4, "Four artifacts exist")

        let conversationA = Set(try repository.artifactIDs(conversationID: "conversation-a"))
        try check(conversationA == [first.artifactID, image.artifactID], "Artifact ids are listed per conversation")

        try repository.updateArtifactOrigin(conversationID: "conversation-a", title: "Lisbon trip")
        try check(try repository.artifact(image.artifactID)?.originTitle == "Lisbon trip", "Renaming a conversation updates the origin title")
        try check(try repository.artifact(other.artifactID)?.originTitle == "Diagrams", "Other conversations keep their origin title")

        let kept = try repository.resolveArtifacts(conversationID: "conversation-a", choice: .keep)
        try check(kept.isEmpty, "Keeping artifacts returns no file names")
        try check(try repository.artifactIDs(conversationID: "conversation-a").isEmpty, "Kept artifacts leave the conversation")
        let keptRecord = try repository.artifact(first.artifactID)
        try check(keptRecord?.conversationID == nil && keptRecord?.originTitle == "Lisbon trip", "Kept artifacts keep their origin title")
        try check(try repository.artifactVersions(first.artifactID).count == 2, "Kept artifacts keep their versions")

        let removed = try repository.resolveArtifacts(conversationID: "conversation-b", choice: .delete)
        try check(removed == [other.fileName], "Deleting returns every removed version's file name")
        try check(try repository.artifact(other.artifactID) == nil, "Deleted artifacts are gone")
        try check(try repository.artifactVersion(sourceKey: "canvas:1") == nil, "Deleted artifact versions cascade")
        let orphanRows = try repository.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifact_versions WHERE artifact_id = ?", arguments: [other.artifactID]) ?? -1
        }
        try check(orphanRows == 0, "No version rows outlive their artifact")
        try check(!(try repository.referencedAttachmentFileNames().contains(other.fileName)), "Deleted artifact files become sweepable")

        let stored = try repository.artifactVersion(sourceKey: "file:1")
        try check(stored?.details.changeKind == .edited && stored?.details.beforeText == "before" && stored?.details.truncated == true, "File change details round-trip")
        try check(try repository.artifactVersion(sourceKey: "research:1")?.details.sources.first?.url == "https://example.com", "Sources round-trip")
        try check(other.details.canvasType == .mermaid, "Canvas details carry the canvas type")
        let encoded = try nativeTaskEncoded(ArtifactDetails(sources: [PulseSource(n: 2, title: "T", url: "https://example.org")], canvasType: .svg))
        let decoded = try JSONDecoder().decode(ArtifactDetails.self, from: encoded)
        try check(decoded.canvasType == .svg && decoded.sources.first?.n == 2 && decoded.truncated == false, "Details encode and decode")
        let sparse = try JSONDecoder().decode(ArtifactDetails.self, from: Data("{\"changeKind\":\"moved\",\"movedFrom\":\"a.txt\"}".utf8))
        try check(sparse.changeKind == .moved && sparse.movedFrom == "a.txt" && sparse.sources.isEmpty && !sparse.truncated, "Sparse details decode with defaults")

        let filesBefore = try files().count
        let note = ArtifactDraft(
            kind: .document, title: "Note", conversationID: "conversation-d", originTitle: "Notes",
            messageID: "message-d", sourceKey: "note:1", data: Data("first".utf8),
            mime: "text/markdown", fileExtension: "md")
        let noteOne = try repository.recordArtifact(note, revising: nil)
        try check(noteOne.contentHash == LocalChatRepository.contentHash(Data("first".utf8)) && noteOne.contentHash.count == 64, "Versions carry a hex SHA-256 of their bytes")
        let noteAgain = try repository.recordArtifact(note, revising: nil)
        try check(noteAgain == noteOne, "Same key and same bytes return the existing version")
        try check(try files().count == filesBefore + 1, "Same key and same bytes write no file")
        try check(try repository.artifact(noteOne.artifactID)?.versionCount == 1, "Same key and same bytes add no version")

        var changed = note
        changed.title = "Note, edited"
        changed.data = Data("second".utf8)
        let noteTwo = try repository.recordArtifact(changed, revising: image.artifactID)
        try check(noteTwo.artifactID == noteOne.artifactID && noteTwo.ordinal == 2, "Same key and new bytes append to the same artifact")
        try check(noteTwo.contentHash == LocalChatRepository.contentHash(Data("second".utf8)) && noteTwo.contentHash != noteOne.contentHash, "The appended version carries the new hash")
        try check(noteTwo.fileName != noteOne.fileName && (try files().count) == filesBefore + 2, "The appended version writes a new file")
        try check(try repository.artifact(noteOne.artifactID)?.title == "Note, edited", "The appended version updates the title")
        try check(try repository.artifact(image.artifactID)?.versionCount == 1, "A known source key ignores the revising argument")
        try check(try repository.artifactVersion(sourceKey: "note:1")?.ordinal == 2, "The latest version answers its source key")
        try check(try repository.recordArtifact(changed, revising: nil) == noteTwo, "Repeating the latest bytes is a no-op")

        try check(try repository.revisionTarget(messageID: "message-r") == nil, "No revision target by default")
        try repository.setRevisionTarget(messageID: "message-r", artifactID: first.artifactID)
        try check(try repository.revisionTarget(messageID: "message-r") == first.artifactID, "A revision target reads back")
        try repository.setRevisionTarget(messageID: "message-r", artifactID: noteOne.artifactID)
        try check(try repository.revisionTarget(messageID: "message-r") == noteOne.artifactID, "Setting a revision target again replaces it")
        try repository.clearRevisionTarget(messageID: "message-r")
        try check(try repository.revisionTarget(messageID: "message-r") == nil, "A cleared revision target is gone")
        try repository.setRevisionTarget(messageID: "message-r", artifactID: noteOne.artifactID)
        let removedNotes = try repository.resolveArtifacts(conversationID: "conversation-d", choice: .delete)
        try check(Set(removedNotes) == [noteOne.fileName, noteTwo.fileName], "Deleting returns both versions of the note")
        try check(try repository.revisionTarget(messageID: "message-r") == nil, "A revision target to a deleted artifact reads as nil")
    }
}
