import AppKit
import Foundation

struct PendingConversationDeletion: Identifiable, Equatable {
    var id: String
    var title: String
    var artifactCount: Int
}

extension ChatStore {
    var artifactRepository: (any ArtifactRepository)? { repository as? any ArtifactRepository }

    func reloadArtifacts() {
        artifactRecords = (try? artifactRepository?.listArtifacts()) ?? []
    }

    func artifactVersions(_ artifactID: String) -> [ArtifactVersion] {
        (try? artifactRepository?.artifactVersions(artifactID)) ?? []
    }

    func artifactFileURL(_ version: ArtifactVersion) -> URL? {
        guard let url = attachmentStore.url(for: version.fileName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func artifactData(_ version: ArtifactVersion) -> Data? {
        artifactFileURL(version).flatMap { try? Data(contentsOf: $0) }
    }

    func artifactText(_ version: ArtifactVersion) -> String? {
        artifactData(version).flatMap { String(data: $0, encoding: .utf8) }
    }

    func artifactConversationExists(_ record: ArtifactRecord) -> Bool {
        guard let id = record.conversationID else { return false }
        return conversations.contains { $0.id == id }
    }

    func openArtifactConversation(_ record: ArtifactRecord) {
        guard let id = record.conversationID, conversations.contains(where: { $0.id == id }) else { return }
        select(id)
    }

    @discardableResult
    func recordArtifact(_ draft: ArtifactDraft) -> ArtifactVersion? {
        guard let artifactRepository else { return nil }
        let target = draft.conversationID.flatMap { artifactRevisionTargets[$0] }
        guard let version = try? artifactRepository.recordArtifact(draft, revising: target) else { return nil }
        reloadArtifacts()
        return version
    }

    func syncArtifactOrigin(conversationID: String, title: String) {
        guard let artifactRepository else { return }
        try? artifactRepository.updateArtifactOrigin(conversationID: conversationID, title: title)
        reloadArtifacts()
    }

    static func canvasFormat(_ artifact: Artifact) -> (mime: String, fileExtension: String) {
        switch artifact.type {
        case .markdown: return ("text/markdown", "md")
        case .html: return ("text/html", "html")
        case .svg: return ("image/svg+xml", "svg")
        case .code: return ("text/plain", codeExtension(artifact.language))
        case .mermaid, .unknown: return ("text/plain", "txt")
        }
    }

    static func codeExtension(_ language: String) -> String {
        let lower = language.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lower.isEmpty, lower.count <= 10,
              lower.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return "txt" }
        return lower
    }

    static func canvasArtifactDraft(
        _ artifact: Artifact, sourceKey: String, conversationID: String?, originTitle: String?,
        messageID: String?, asDocument: Bool = false
    ) -> ArtifactDraft {
        let format = asDocument ? (mime: "text/markdown", fileExtension: "md") : canvasFormat(artifact)
        let language = artifact.language.trimmingCharacters(in: .whitespaces)
        return ArtifactDraft(
            kind: asDocument ? .document : .canvas, title: artifact.title, conversationID: conversationID,
            originTitle: originTitle, messageID: messageID, sourceKey: sourceKey, data: Data(artifact.content.utf8),
            mime: format.mime, fileExtension: format.fileExtension,
            details: ArtifactDetails(canvasType: artifact.type, language: language.isEmpty ? nil : language))
    }

    func recordCanvasArtifacts(_ artifacts: [Artifact], conversationID: String, messageID: String) {
        guard let artifactRepository, !artifacts.isEmpty else { return }
        let origin = conversations.first(where: { $0.id == conversationID })?.title
        let revisingDocument = artifactRevisionTargets[conversationID]
            .flatMap { try? artifactRepository.artifact($0) }?.kind == .document
        for artifact in artifacts {
            recordArtifact(Self.canvasArtifactDraft(
                artifact, sourceKey: "canvas:\(messageID):\(artifact.id)", conversationID: conversationID,
                originTitle: origin, messageID: messageID, asDocument: revisingDocument))
        }
    }

    func recordImageArtifact(_ image: MessageAttachment, activity: NativeToolActivity, conversationID: String, messageID: String) {
        guard artifactRepository != nil, let fileName = image.fileName, let data = attachmentStore.data(for: fileName) else { return }
        let request = activity.request.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        func text(_ key: String) -> String? {
            guard let value = (request?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        var ext = image.ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        if ext.isEmpty { ext = (fileName as NSString).pathExtension.lowercased() }
        if ext.isEmpty { ext = "png" }
        let stem = (image.name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        recordArtifact(ArtifactDraft(
            kind: .image, title: stem.isEmpty ? "Image" : stem, conversationID: conversationID,
            originTitle: conversations.first(where: { $0.id == conversationID })?.title, messageID: messageID,
            sourceKey: "image:\(fileName)", data: data, mime: image.mime ?? "image/png", fileExtension: ext,
            details: ArtifactDetails(prompt: text("prompt"), imageSize: text("size"))))
    }

    func recordFileChangeArtifact(_ change: NativeFileChange, conversationID: String, messageID: String) {
        guard artifactRepository != nil, change.kind != .directory else { return }
        let ext = (change.path as NSString).pathExtension.lowercased()
        recordArtifact(ArtifactDraft(
            kind: .fileChange, title: change.title, conversationID: conversationID,
            originTitle: conversations.first(where: { $0.id == conversationID })?.title, messageID: messageID,
            sourceKey: "file:\(change.id)", data: Data((change.after ?? "").utf8), mime: "text/plain",
            fileExtension: ext.isEmpty ? "txt" : ext,
            details: ArtifactDetails(
                filePath: change.path, changeKind: change.kind, movedFrom: change.movedFrom,
                beforeText: change.before, truncated: change.truncated)))
    }

    func recordTaskArtifacts(_ blocks: [NativeDisplayBlock], conversationID: String, messageID: String) {
        guard artifactRepository != nil else { return }
        let origin = conversations.first(where: { $0.id == conversationID })?.title
        for block in blocks {
            guard case .artifact(let artifact) = block,
                  !artifact.report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            recordArtifact(ArtifactDraft(
                kind: .document, title: artifact.title, conversationID: conversationID, originTitle: origin,
                messageID: messageID, sourceKey: "task:\(artifact.id)", data: Data(artifact.report.utf8),
                mime: "text/markdown", fileExtension: "md", details: ArtifactDetails(sources: artifact.sources)))
        }
    }

    static let revisionContentCap = 24_000

    func artifactRevisionNote(conversationID: String) -> String? {
        guard let target = artifactRevisionTargets[conversationID],
              let record = try? artifactRepository?.artifact(target),
              let latest = artifactVersions(target).last else { return nil }
        switch record.kind {
        case .document, .canvas:
            let content = String((artifactText(latest) ?? "").prefix(Self.revisionContentCap))
            let directiveTitle = record.title.replacingOccurrences(of: "\"", with: "'")
            if record.kind == .document {
                return "The user is revising the document titled \"\(record.title)\". Produce the complete revised document as markdown in your reply rather than a summary of changes. "
                    + "Put the whole revised document in one block that opens with the line :::vera-artifact title=\"\(directiveTitle)\" type=\"markdown\" and closes with a line containing only :::. "
                    + "Current content:\n\n" + content
            }
            let type = latest.details.canvasType.map(\.rawValue) ?? "markdown"
            let language = latest.details.language.map { " language=\"\($0)\"" } ?? ""
            return "The user is revising the canvas piece titled \"\(record.title)\". Produce the complete revised piece as a vera-artifact block with the same title rather than a summary of changes. "
                + "Open the block with the line :::vera-artifact title=\"\(directiveTitle)\" type=\"\(type)\"\(language) and close it with a line containing only :::. "
                + "Current content:\n\n" + content
        case .image:
            let original = latest.details.prompt.map { " Its original prompt was: \($0)." } ?? ""
            return "The user is revising the image titled \"\(record.title)\".\(original) Generate a new image with the requested change."
        case .fileChange:
            let path = latest.details.filePath ?? record.title
            return "The user is revising the file at \(path). Apply the requested change to that file with the file tools."
        }
    }

    func clearArtifactRevisionTarget(conversationID: String, matching target: String?) {
        guard let target, artifactRevisionTargets[conversationID] == target else { return }
        artifactRevisionTargets[conversationID] = nil
    }

    func reviseArtifact(_ record: ArtifactRecord, change: String) {
        let trimmed = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let conversationID = record.conversationID,
              conversations.contains(where: { $0.id == conversationID }) else { return }
        select(conversationID)
        artifactRevisionTargets[conversationID] = record.id
        if !sendText("Revise \"\(record.title)\": \(trimmed)") {
            artifactRevisionTargets[conversationID] = nil
        }
        focusTick &+= 1
    }

    @discardableResult
    static func importLegacyCanvasLibrary(from url: URL, into repository: any ArtifactRepository) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let artifacts = try JSONDecoder().decode([Artifact].self, from: Data(contentsOf: url))
        for artifact in artifacts {
            _ = try repository.recordArtifact(canvasArtifactDraft(
                artifact, sourceKey: "canvas-library:\(artifact.id)", conversationID: nil, originTitle: nil,
                messageID: nil), revising: nil)
        }
        let backup = url.deletingLastPathComponent().appendingPathComponent("artifacts-migrated.json")
        if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
        try FileManager.default.moveItem(at: url, to: backup)
        return artifacts.count
    }

    func requestDeleteConversation(_ id: String) {
        guard !isVeraThread(id) else { return }
        let ids = (try? artifactRepository?.artifactIDs(conversationID: id)) ?? []
        guard !ids.isEmpty, let conversation = conversations.first(where: { $0.id == id }) else {
            deleteConversation(id)
            return
        }
        pendingConversationDeletion = PendingConversationDeletion(id: id, title: conversation.title, artifactCount: ids.count)
    }

    func confirmDeleteConversation(_ choice: ArtifactConversationDeletion) {
        guard let pending = pendingConversationDeletion else { return }
        pendingConversationDeletion = nil
        let removed = (try? artifactRepository?.resolveArtifacts(conversationID: pending.id, choice: choice)) ?? []
        for fileName in removed {
            if let url = attachmentStore.url(for: fileName) { try? FileManager.default.removeItem(at: url) }
        }
        deleteConversation(pending.id, confirmed: true)
        reloadArtifacts()
    }

    func cancelDeleteConversation() {
        pendingConversationDeletion = nil
    }
}
