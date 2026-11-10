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
    let id: UUID
    let artifactID: String
    let title: String
    let version: ArtifactVersion
    var destination: URL
}

enum ArtifactExportNotice: Equatable, Identifiable {
    case saved(id: UUID, fileName: String)
    case failed(ArtifactExportAttempt, ArtifactExportProblem)

    var id: UUID {
        switch self {
        case .saved(let id, _): return id
        case .failed(let attempt, _): return attempt.id
        }
    }

    var message: String {
        switch self {
        case .saved(_, let fileName):
            return "Saved \"\(fileName)\"."
        case .failed(let attempt, let problem):
            let lead = "Couldn't save \"\(attempt.title)\"."
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
        if case .saved = self { return true }
        return false
    }
}

struct ArtifactExporter {
    var read: (ArtifactVersion) -> Result<Data, ArtifactExportProblem>
    var write: (Data, URL) throws -> Void = ArtifactExporter.atomicWrite

    static func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func run(_ attempt: ArtifactExportAttempt) -> ArtifactExportNotice {
        let data: Data
        switch read(attempt.version) {
        case .success(let value): data = value
        case .failure(let problem): return .failed(attempt, problem)
        }
        do {
            try write(data, attempt.destination)
        } catch {
            return .failed(attempt, Self.problem(for: error))
        }
        return .saved(id: attempt.id, fileName: attempt.destination.lastPathComponent)
    }

    static func problem(for error: Error) -> ArtifactExportProblem {
        problem(for: error as NSError, depth: 0) ?? .other
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

    func chooseAnother(_ attempt: ArtifactExportAttempt) -> ArtifactExportNotice? {
        let folder = attempt.destination.deletingLastPathComponent()
        let directory = folderExists(folder) ? folder : nil
        guard let destination = choose(attempt.destination.lastPathComponent, directory) else { return nil }
        var moved = attempt
        moved.destination = destination
        return exporter.run(moved)
    }
}
