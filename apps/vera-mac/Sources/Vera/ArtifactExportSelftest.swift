import Foundation

enum ArtifactExportSelftest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func version(_ id: String, artifact: String, ordinal: Int, fileName: String) -> ArtifactVersion {
        ArtifactVersion(
            id: id, artifactID: artifact, ordinal: ordinal, sourceKey: "selftest:\(id)", fileName: fileName,
            mime: "application/octet-stream", byteSize: 0, contentHash: "", messageID: nil,
            details: ArtifactDetails(), createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func record(_ id: String, _ kind: ArtifactKind, _ title: String) -> ArtifactRecord {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return ArtifactRecord(id: id, kind: kind, title: title, conversationID: nil, originTitle: nil,
                              createdAt: date, updatedAt: date, versionCount: 1)
    }

    static func attempt(_ record: ArtifactRecord, _ version: ArtifactVersion, to destination: URL) -> ArtifactExportAttempt {
        ArtifactExportAttempt(id: UUID(), artifactID: record.id, title: record.title, version: version, destination: destination)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func samePath(_ a: URL?, _ b: URL?) -> Bool {
        a?.standardizedFileURL.resolvingSymlinksInPath().path == b?.standardizedFileURL.resolvingSymlinksInPath().path
    }

    @MainActor
    static func run() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("tandem-library-export-\(UUID().uuidString.lowercased())", isDirectory: true)
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        let attachments = root.appendingPathComponent("attachments", isDirectory: true)
        for folder in [sources, out, locked, attachments] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let unreadableSource = sources.appendingPathComponent("unreadable.md")
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableSource.path)
            try? manager.removeItem(at: root)
        }

        var reads: [ArtifactVersion] = []
        let fileReader: (ArtifactVersion) -> Result<Data, ArtifactExportProblem> = { version in
            reads.append(version)
            let url = sources.appendingPathComponent(version.fileName)
            guard manager.fileExists(atPath: url.path) else { return .failure(.sourceMissing) }
            do { return .success(try Data(contentsOf: url)) } catch { return .failure(.sourceUnreadable) }
        }
        let exporter = ArtifactExporter(read: { fileReader($0) })

        let report = record("doc-a", .document, "Heating report")
        let documentBytes = Data("# Heating report\n\nWater barrels along the north wall.\n".utf8)
        try documentBytes.write(to: sources.appendingPathComponent("doc-a-1.md"))
        let documentVersion = version("doc-a-v1", artifact: report.id, ordinal: 1, fileName: "doc-a-1.md")
        let documentDestination = out.appendingPathComponent("Heating report.md")
        let documentAttempt = attempt(report, documentVersion, to: documentDestination)
        let documentNotice = exporter.run(documentAttempt)
        try check(documentNotice == .saved(id: documentAttempt.id, fileName: "Heating report.md"), "A document export is saved under its file name")
        try check((try? Data(contentsOf: documentDestination)) == documentBytes, "The saved document has the source bytes")
        try check(documentNotice.message == "Saved \"Heating report.md\".", "The saved message names the file")
        try check(!documentNotice.canRetry && !documentNotice.canChooseLocation, "A saved notice offers no recovery")

        let dusk = record("img-a", .image, "Greenhouse at dusk")
        var imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x00, 0xFE])
        imageBytes.append(contentsOf: (0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        try imageBytes.write(to: sources.appendingPathComponent("img-a-1.png"))
        let imageVersion = version("img-a-v1", artifact: dusk.id, ordinal: 1, fileName: "img-a-1.png")
        let imageDestination = out.appendingPathComponent("Greenhouse at dusk.png")
        let imageAttempt = attempt(dusk, imageVersion, to: imageDestination)
        try check(exporter.run(imageAttempt) == .saved(id: imageAttempt.id, fileName: "Greenhouse at dusk.png"), "An image export is saved")
        try check((try? Data(contentsOf: imageDestination)) == imageBytes, "The saved image has the exact binary bytes")

        let notes = record("doc-b", .document, "Trip notes")
        let firstBytes = Data("first draft".utf8)
        let latestBytes = Data("latest draft, much longer".utf8)
        try firstBytes.write(to: sources.appendingPathComponent("doc-b-1.md"))
        try latestBytes.write(to: sources.appendingPathComponent("doc-b-2.md"))
        let firstVersion = version("doc-b-v1", artifact: notes.id, ordinal: 1, fileName: "doc-b-1.md")
        let olderDestination = out.appendingPathComponent("Trip notes.md")
        _ = exporter.run(attempt(notes, firstVersion, to: olderDestination))
        try check((try? Data(contentsOf: olderDestination)) == firstBytes, "Exporting version 1 writes version 1, not the latest")
        try check(reads.last == firstVersion, "The selected version is the one read")

        let gone = record("doc-c", .document, "Garden plan")
        let goneVersion = version("doc-c-v1", artifact: gone.id, ordinal: 1, fileName: "doc-c-1.md")
        let goneDestination = out.appendingPathComponent("Garden plan.md")
        let goneNotice = exporter.run(attempt(gone, goneVersion, to: goneDestination))
        guard case .failed(_, .sourceMissing) = goneNotice else { throw Failure(description: "A missing original is reported as missing") }
        try check(!goneNotice.canRetry && !goneNotice.canChooseLocation, "A missing original offers only dismissal")
        try check(!exists(goneDestination), "A missing original creates no file")

        try Data("locked away".utf8).write(to: unreadableSource)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableSource.path)
        let sealed = record("doc-d", .document, "Seed order")
        let sealedVersion = version("doc-d-v1", artifact: sealed.id, ordinal: 1, fileName: "unreadable.md")
        let sealedDestination = out.appendingPathComponent("Seed order.md")
        let sealedNotice = exporter.run(attempt(sealed, sealedVersion, to: sealedDestination))
        guard case .failed(_, .sourceUnreadable) = sealedNotice else {
            throw Failure(description: "An unreadable original is reported as unreadable, got \(sealedNotice)")
        }
        try check(sealedNotice.canRetry && !sealedNotice.canChooseLocation, "An unreadable original offers retry and dismissal only")
        try check(!exists(sealedDestination), "An unreadable original creates no file")

        let missingFolder = root.appendingPathComponent("not-yet", isDirectory: true)
        let strandedDestination = missingFolder.appendingPathComponent("Heating report.md")
        var realErrors: [String] = []
        do { try ArtifactExporter.atomicWrite(documentBytes, to: strandedDestination) } catch {
            realErrors.append(error.localizedDescription)
            try check(ArtifactExporter.problem(for: error) == .folderUnavailable,
                      "A missing folder maps to folderUnavailable, got \(ArtifactExporter.problem(for: error)) for \(error as NSError)")
        }
        let strandedAttempt = attempt(report, documentVersion, to: strandedDestination)
        let strandedNotice = exporter.run(strandedAttempt)
        try check(strandedNotice == .failed(strandedAttempt, .folderUnavailable), "A missing folder fails the export as unavailable")
        try check(strandedNotice.canRetry && strandedNotice.canChooseLocation, "A destination problem offers retry and another location")
        try check(!exists(strandedDestination) && !exists(missingFolder), "A missing folder is not created")

        let keptFile = locked.appendingPathComponent("Heating report.md")
        let oldBytes = Data("old copy".utf8)
        try oldBytes.write(to: keptFile)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        do { try ArtifactExporter.atomicWrite(documentBytes, to: locked.appendingPathComponent("probe.md")) } catch {
            realErrors.append(error.localizedDescription)
            try check(ArtifactExporter.problem(for: error) == .notAllowed,
                      "A read-only folder maps to notAllowed, got \(ArtifactExporter.problem(for: error)) for \(error as NSError)")
        }
        let lockedAttempt = attempt(report, documentVersion, to: keptFile)
        let lockedNotice = exporter.run(lockedAttempt)
        try check(lockedNotice == .failed(lockedAttempt, .notAllowed), "Saving into a read-only folder fails as not allowed, got \(lockedNotice)")
        try check((try? Data(contentsOf: keptFile)) == oldBytes, "A failed export leaves the existing destination file unchanged")
        try check(realErrors.count == 2, "Both real writes failed")

        func injected(_ error: Error) -> ArtifactExportProblem {
            let throwing = ArtifactExporter(read: { _ in .success(Data("x".utf8)) }, write: { _, _ in throw error })
            let probe = attempt(report, documentVersion, to: out.appendingPathComponent("never.md"))
            guard case .failed(_, let problem) = throwing.run(probe) else { return .sourceMissing }
            return problem
        }
        try check(injected(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .noSpace, "Out of space maps to noSpace")
        try check(injected(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)) == .readOnly, "A read-only volume maps to readOnly")
        try check(injected(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .noSpace, "ENOSPC maps to noSpace")
        try check(injected(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                   userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))])) == .readOnly,
                  "An underlying EROFS maps to readOnly")
        try check(injected(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                   userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])) == .notAllowed,
                  "An underlying EPERM maps to notAllowed")
        try check(injected(NSError(domain: "Elsewhere", code: 7)) == .other, "An unknown error maps to other")
        try check(!exists(out.appendingPathComponent("never.md")), "A throwing writer leaves no file")

        var offered: [(String, URL?)] = []
        var chosen: URL?
        let flow = ArtifactExportFlow(exporter: exporter, choose: { name, directory in
            offered.append((name, directory))
            return chosen
        })

        try manager.createDirectory(at: missingFolder, withIntermediateDirectories: true)
        let retried = flow.retry(strandedAttempt)
        try check(retried == .saved(id: strandedAttempt.id, fileName: "Heating report.md"), "A retry after the cause is fixed is saved with the same attempt")
        try check(reads.last == documentVersion, "A retry reads the same version")
        try check((try? Data(contentsOf: strandedDestination)) == documentBytes, "The retried file has the right bytes")
        try manager.removeItem(at: missingFolder)

        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        chosen = elsewhere.appendingPathComponent("Heating report copy.md")
        guard let moved = flow.chooseAnother(strandedAttempt) else { throw Failure(description: "Choosing another location runs the export") }
        try check(moved == .saved(id: strandedAttempt.id, fileName: "Heating report copy.md"), "Another location is saved with the same attempt")
        try check((try? Data(contentsOf: elsewhere.appendingPathComponent("Heating report copy.md"))) == documentBytes, "The new location has the bytes")
        try check(reads.last == documentVersion, "Another location keeps the same version")
        try check(offered.last?.0 == "Heating report.md" && offered.last?.1 == nil,
                  "A folder that no longer exists is not offered, and the previous file name is")

        chosen = out.appendingPathComponent("Heating report from locked.md")
        guard case .saved = flow.chooseAnother(lockedAttempt) ?? .saved(id: UUID(), fileName: "") else {
            throw Failure(description: "Choosing another location from a locked folder saves")
        }
        try check(offered.last?.0 == "Heating report.md" && samePath(offered.last?.1, locked),
                  "The previous folder is offered when it still exists")

        chosen = nil
        let before = try manager.contentsOfDirectory(atPath: out.path).sorted()
        try check(flow.chooseAnother(lockedAttempt) == nil, "Canceling another location changes nothing")
        try check(flow.begin(notes, version: firstVersion, fileName: "Trip notes.md") == nil, "Canceling the first save panel changes nothing")
        try check(offered.last?.0 == "Trip notes.md" && offered.last?.1 == nil, "The first panel is offered the suggested name")
        try check(try manager.contentsOfDirectory(atPath: out.path).sorted() == before, "Canceling writes no file")
        try check((try? Data(contentsOf: keptFile)) == oldBytes, "Canceling leaves the locked file unchanged")

        chosen = out.appendingPathComponent("Trip notes again.md")
        guard let begun = flow.begin(notes, version: firstVersion, fileName: "Trip notes.md") else {
            throw Failure(description: "A chosen destination runs the export")
        }
        try check(begun == .saved(id: begun.id, fileName: "Trip notes again.md"), "Beginning an export with a destination saves it")

        let paths = [out.path, locked.path, missingFolder.path, root.path, strandedDestination.path]
        for problem in ArtifactExportProblem.allCases {
            let notice = ArtifactExportNotice.failed(attempt(report, documentVersion, to: strandedDestination), problem)
            let message = notice.message
            try check(message.contains("\"Heating report\""), "Every failure names the item: \(message)")
            try check(!paths.contains { message.contains($0) } && !message.contains("/"), "No failure shows a path: \(message)")
            try check(!realErrors.contains { message.contains($0) }, "No failure shows system error text: \(message)")
            try check(!message.localizedCaseInsensitiveContains("vera") && !message.localizedCaseInsensitiveContains("artifact"),
                      "No failure uses internal words: \(message)")
        }
        try check(ArtifactExportNotice.failed(lockedAttempt, .sourceMissing).message
                  == "Couldn't save \"Heating report\". The original is no longer on this Mac.", "The missing original message reads plainly")
        try check(ArtifactExportNotice.failed(lockedAttempt, .notAllowed).message
                  == "Couldn't save \"Heating report\". Tandem isn't allowed to save in that folder.", "The not allowed message reads plainly")

        let repository = try LocalChatRepository(inMemory: true, artifactDirectory: attachments)
        let store = ChatStore(
            nativeConfig: nil, nativeTransport: nil, repository: repository,
            attachmentStore: NativeAttachmentStore(directory: attachments), artifactPersistenceEnabled: false)
        let storedBytes = Data("# Stored\n\nKept by the Library.\n".utf8)
        guard let stored = store.recordArtifact(ArtifactDraft(
            kind: .document, title: "Stored notes", conversationID: nil, originTitle: nil, messageID: nil,
            sourceKey: "selftest:stored", data: storedBytes, mime: "text/markdown", fileExtension: "md",
            details: ArtifactDetails())) else { throw Failure(description: "The store records an item") }
        try check(store.artifactSource(stored) == .success(storedBytes), "The store reads the original bytes")
        guard let storedURL = store.attachmentStore.url(for: stored.fileName) else { throw Failure(description: "The stored file has a location") }
        try check(samePath(storedURL.deletingLastPathComponent(), attachments), "The stored file lives in the temporary folder")
        try manager.removeItem(at: storedURL)
        try check(store.artifactSource(stored) == .failure(.sourceMissing), "A deleted original reads as missing")

        print("  artifact export OK")
    }
}
