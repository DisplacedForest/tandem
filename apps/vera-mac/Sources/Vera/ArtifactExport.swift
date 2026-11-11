import Foundation

enum ArtifactExportProblem: Error, Equatable, Sendable, CaseIterable {
    case sourceMissing
    case sourceUnreadable
    case notAllowed
    case folderUnavailable
    case noSpace
    case readOnly
    case other
}

struct ArtifactExportAttempt: Equatable, Identifiable, Sendable {
    enum Source: Equatable, Sendable {
        case version(artifactID: String, ArtifactVersion)
        case image(URL)
    }

    let id: UUID
    let title: String
    let source: Source
    var destination: URL

    init(id: UUID, title: String, source: Source, destination: URL) {
        self.id = id
        self.title = title
        self.source = source
        self.destination = destination
    }

    init(id: UUID, artifactID: String, title: String, version: ArtifactVersion, destination: URL) {
        self.init(id: id, title: title, source: .version(artifactID: artifactID, version), destination: destination)
    }
}

enum ArtifactExportNotice: Equatable, Identifiable {
    case saved(id: UUID, title: String, fileName: String)
    case savedImage(id: UUID, fileName: String)
    case failed(ArtifactExportAttempt, ArtifactExportProblem)

    static let imageNameLimit = 45

    var id: UUID {
        switch self {
        case .saved(let id, _, _): return id
        case .savedImage(let id, _): return id
        case .failed(let attempt, _): return attempt.id
        }
    }

    var message: String {
        switch self {
        case .saved(_, let title, let fileName):
            let stem = (fileName as NSString).deletingPathExtension
            if stem == title || fileName == title { return "Saved \"\(fileName)\"." }
            return "Saved \"\(title)\" as \"\(fileName)\"."
        case .savedImage(_, let fileName):
            return fileName.count <= Self.imageNameLimit ? "Saved \"\(fileName)\"." : "Saved this image."
        case .failed(let attempt, let problem):
            var lead = "Couldn't save \"\(attempt.title)\"."
            if case .image = attempt.source { lead = "Couldn't save this image." }
            switch problem {
            case .sourceMissing: return "\(lead) The original is no longer on this Mac."
            case .sourceUnreadable: return "\(lead) The original couldn't be read."
            case .notAllowed: return "\(lead) Tandem isn't allowed to save in that folder."
            case .folderUnavailable: return "\(lead) That folder isn't available."
            case .noSpace: return "\(lead) There isn't enough space there."
            case .readOnly: return "\(lead) That disk can't be written to."
            case .other: return "\(lead) The file couldn't be written."
            }
        }
    }

    var canChooseLocation: Bool {
        guard case .failed(_, let problem) = self else { return false }
        switch problem {
        case .sourceMissing, .sourceUnreadable: return false
        case .notAllowed, .folderUnavailable, .noSpace, .readOnly, .other: return true
        }
    }

    var attempt: ArtifactExportAttempt? {
        guard case .failed(let attempt, _) = self else { return nil }
        return attempt
    }

    var isSaved: Bool {
        switch self {
        case .saved, .savedImage: return true
        case .failed: return false
        }
    }
}

struct ArtifactExporter {
    var read: (ArtifactVersion) -> Result<Data, ArtifactExportProblem> = { _ in .failure(.sourceMissing) }
    var write: (Data, URL) throws -> Void = ArtifactExporter.atomicWrite
    var stage: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func run(_ attempt: ArtifactExportAttempt) -> ArtifactExportNotice {
        let version: ArtifactVersion
        switch attempt.source {
        case .version(_, let value): version = value
        case .image(let source): return copy(attempt, from: source)
        }
        let data: Data
        switch read(version) {
        case .success(let value): data = value
        case .failure(let problem): return .failed(attempt, problem)
        }
        do {
            try write(data, attempt.destination)
        } catch {
            return .failed(attempt, Self.problem(for: error))
        }
        return .saved(id: attempt.id, title: attempt.title, fileName: attempt.destination.lastPathComponent)
    }

    private func copy(_ attempt: ArtifactExportAttempt, from source: URL) -> ArtifactExportNotice {
        func unreadable() -> ArtifactExportProblem? {
            do {
                try FileHandle(forReadingFrom: source).close()
                return nil
            } catch {
                return Self.sourceProblem(for: error)
            }
        }
        if let problem = unreadable() { return .failed(attempt, problem) }
        let manager = FileManager.default
        let destination = attempt.destination
        do {
            let staging = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
            defer { try? manager.removeItem(at: staging) }
            let staged = staging.appendingPathComponent(source.lastPathComponent)
            do {
                try stage(source, staged)
            } catch {
                if let problem = unreadable() { return .failed(attempt, problem) }
                throw error
            }
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: destination)
            }
        } catch {
            return .failed(attempt, Self.problem(for: error))
        }
        return .savedImage(id: attempt.id, fileName: destination.lastPathComponent)
    }

    static func problem(for error: Error) -> ArtifactExportProblem {
        problem(for: error as NSError, depth: 0) ?? .other
    }

    static func sourceProblem(for error: Error) -> ArtifactExportProblem {
        problem(for: error as NSError, depth: 0) == .folderUnavailable ? .sourceMissing : .sourceUnreadable
    }

    private static func problem(for error: NSError, depth: Int) -> ArtifactExportProblem? {
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteNoPermissionError: return .notAllowed
            case NSFileNoSuchFileError, NSFileWriteInvalidFileNameError, NSFileReadNoSuchFileError: return .folderUnavailable
            case NSFileWriteOutOfSpaceError: return .noSpace
            case NSFileWriteVolumeReadOnlyError: return .readOnly
            default: break
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(truncatingIfNeeded: error.code) {
            case EACCES, EPERM: return .notAllowed
            case ENOENT, ENOTDIR: return .folderUnavailable
            case ENOSPC: return .noSpace
            case EROFS: return .readOnly
            default: break
            }
        }
        guard depth < 4, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
        return problem(for: underlying, depth: depth + 1)
    }
}

struct ArtifactExportFlow {
    var exporter: ArtifactExporter
    var choose: (_ fileName: String, _ directory: URL?) -> URL?
    var folderExists: (URL) -> Bool = ArtifactExportFlow.folderExists

    static func folderExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func begin(_ record: ArtifactRecord, version: ArtifactVersion, fileName: String) -> ArtifactExportNotice? {
        guard let destination = choose(fileName, nil) else { return nil }
        let attempt = ArtifactExportAttempt(
            id: UUID(), artifactID: record.id, title: record.title, version: version, destination: destination)
        return exporter.run(attempt)
    }

    func begin(file source: URL, title: String, fileName: String) -> ArtifactExportNotice? {
        guard let destination = choose(fileName, nil) else { return nil }
        return run(ArtifactExportAttempt(id: UUID(), title: title, source: .image(source), destination: destination))
    }

    func chooseAnother(_ attempt: ArtifactExportAttempt) -> ArtifactExportNotice? {
        let folder = attempt.destination.deletingLastPathComponent()
        let directory = folderExists(folder) ? folder : nil
        guard let destination = choose(attempt.destination.lastPathComponent, directory) else { return nil }
        var moved = attempt
        moved.destination = destination
        return run(moved)
    }

    private func run(_ attempt: ArtifactExportAttempt) -> ArtifactExportNotice? {
        if case .image(let source) = attempt.source, Self.sameFile(source, attempt.destination) { return nil }
        return exporter.run(attempt)
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
