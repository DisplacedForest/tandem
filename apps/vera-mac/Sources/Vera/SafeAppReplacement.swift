import Foundation
import Darwin
import Security
import CryptoKit

struct AppReplacementError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct AppFileIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64

    static func read(_ url: URL) throws -> Self? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw AppReplacementError("Cannot inspect \(url.lastPathComponent): \(errno)")
        }
        guard value.st_mode & S_IFMT == S_IFDIR else {
            throw AppReplacementError("App must be a directory, not a link or file")
        }
        return Self(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }
}

struct AppReplacementReceipt: Codable {
    let target: URL
    let identifier: String
    let staged: AppFileIdentity
    let previous: AppFileIdentity?
    let stagedManifest: String
    let previousManifest: String?

    enum State: String {
        case prepared, installed, changed
    }

    func state(at receipt: URL) throws -> State {
        let current = try AppFileIdentity.read(target)
        let retained = try AppFileIdentity.read(receipt.deletingLastPathComponent().appendingPathComponent("Vera.app"))
        let retainedURL = receipt.deletingLastPathComponent().appendingPathComponent("Vera.app")
        let currentContent = current == nil ? nil : try? SafeAppReplacement.manifest(target)
        let retainedContent = retained == nil ? nil : try? SafeAppReplacement.manifest(retainedURL)
        if current == staged, retained == previous, currentContent == stagedManifest,
           retainedContent == previousManifest { return .installed }
        if current == previous, retained == staged, currentContent == previousManifest,
           retainedContent == stagedManifest { return .prepared }
        return .changed
    }
}

struct SafeAppReplacement {
    struct Hooks {
        var copy: (URL, URL) throws -> Void = SafeAppReplacement.copyBundle
        var validateSignature: (URL, URL?) throws -> Void = SafeAppReplacement.validateSignature
        var checkpoint: (String) throws -> Void = { _ in }
    }

    static func replace(source: URL, target requestedTarget: URL, version: String,
                        identifier: String = "app.vera.mac", allowFirstInstall: Bool = false,
                        expectedTarget: AppFileIdentity? = nil, expectedTargetManifest: String? = nil,
                        expectedSourceManifest: String? = nil, hooks: Hooks = Hooks()) throws -> URL {
        let fm = FileManager.default
        let target = requestedTarget.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(requestedTarget.lastPathComponent)
        guard target.pathExtension == "app", source.standardizedFileURL != target.standardizedFileURL else {
            throw AppReplacementError("Use distinct source and target app bundles")
        }
        let lock = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).replacement.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AppReplacementError("Cannot lock the installation directory") }
        defer { close(descriptor) }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == geteuid(), flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw AppReplacementError("Another installation is active or its lock is unavailable")
        }
        let previous = try AppFileIdentity.read(target)
        guard previous != nil || allowFirstInstall else { throw AppReplacementError("The installed app is missing") }
        if let expectedTarget, expectedTarget != previous { throw AppReplacementError("The installed app has changed") }
        let reference = previous == nil ? nil : target
        if let reference { _ = try validateBundle(reference, identifier: identifier) }
        let previousManifest = try reference.map { try manifest($0) }
        if let expectedTargetManifest, expectedTargetManifest != previousManifest {
            throw AppReplacementError("The installed app contents have changed")
        }
        let transaction = target.deletingLastPathComponent()
            .appendingPathComponent(".Vera-replacement-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: transaction, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let candidate = transaction.appendingPathComponent("Vera.app", isDirectory: true)
        let receiptURL = transaction.appendingPathComponent("receipt.json")
        var retain = false
        defer { if !retain { try? fm.removeItem(at: transaction) } }
        _ = try validateBundle(source, identifier: identifier, version: version)
        try hooks.copy(source, candidate)
        try hooks.checkpoint("copied")
        _ = try validateBundle(candidate, identifier: identifier, version: version)
        try hooks.validateSignature(candidate, reference)
        guard let staged = try AppFileIdentity.read(candidate) else { throw AppReplacementError("The staged app is missing") }
        let stagedManifest = try manifest(candidate)
        if let expectedSourceManifest, expectedSourceManifest != stagedManifest {
            throw AppReplacementError("The rollback app contents have changed")
        }
        let receipt = AppReplacementReceipt(target: target, identifier: identifier, staged: staged, previous: previous,
                                            stagedManifest: stagedManifest, previousManifest: previousManifest)
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        try hooks.checkpoint("prepared")
        let currentManifest = try reference.map { try manifest($0) }
        guard try AppFileIdentity.read(target) == previous,
              currentManifest == previousManifest else {
            throw AppReplacementError("The installed app changed during staging")
        }
        retain = true
        let flags = previous == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
        guard renamex_np(candidate.path, target.path, flags) == 0 else {
            retain = false
            throw AppReplacementError("Atomic app replacement failed: \(errno)")
        }
        try hooks.checkpoint("installed")
        return receiptURL
    }

    static func rollback(receiptURL: URL) throws -> URL {
        let receipt = try JSONDecoder().decode(AppReplacementReceipt.self, from: Data(contentsOf: receiptURL))
        guard receipt.previous != nil, try receipt.state(at: receiptURL) == .installed else {
            throw AppReplacementError("This receipt does not describe the current installation")
        }
        let previous = receiptURL.deletingLastPathComponent().appendingPathComponent("Vera.app")
        let version = try validateBundle(previous, identifier: receipt.identifier)
        return try replace(source: previous, target: receipt.target, version: version,
                           identifier: receipt.identifier, expectedTarget: receipt.staged,
                           expectedTargetManifest: receipt.stagedManifest, expectedSourceManifest: receipt.previousManifest)
    }

    static func manifest(_ app: URL) throws -> String {
        struct Entry: Codable {
            let path: String
            let type: String
            let value: String
            let permissions: UInt16
        }
        let fm = FileManager.default
        var failure: Error?
        guard let files = fm.enumerator(at: app, includingPropertiesForKeys: nil, errorHandler: { _, error in
            failure = error
            return false
        }) else { throw AppReplacementError("Cannot read app contents") }
        var entries: [Entry] = []
        for case let url as URL in files {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw AppReplacementError("Cannot read app content identity") }
            let type: String
            let value: String
            switch info.st_mode & S_IFMT {
            case S_IFDIR: type = "directory"; value = ""
            case S_IFREG:
                type = "file"
                value = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
                    .map { String(format: "%02x", $0) }.joined()
            case S_IFLNK:
                type = "link"
                value = try fm.destinationOfSymbolicLink(atPath: url.path)
            default: throw AppReplacementError("App contains an unsupported file type")
            }
            entries.append(Entry(path: String(url.path.dropFirst(app.path.count + 1)), type: type,
                                 value: value, permissions: info.st_mode & 0o777))
        }
        if let failure { throw failure }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(entries.sorted { $0.path < $1.path }))
            .map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func validateBundle(_ app: URL, identifier: String, version: String? = nil) throws -> String {
        guard try AppFileIdentity.read(app) != nil else { throw AppReplacementError("The app bundle is missing") }
        let root = app.resolvingSymlinksInPath().path + "/"
        guard let entries = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw AppReplacementError("Cannot inspect app contents")
        }
        for case let entry as URL in entries {
            guard entry.resolvingSymlinksInPath().path.hasPrefix(root) else {
                throw AppReplacementError("App contains a link outside its bundle")
            }
        }
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == identifier,
              plist["CFBundlePackageType"] as? String == "APPL",
              let foundVersion = plist["CFBundleShortVersionString"] as? String, !foundVersion.isEmpty,
              version == nil || version == foundVersion,
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != ".." else {
            throw AppReplacementError("App identity or version does not match")
        }
        let executableURL = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        let values = try executableURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AppReplacementError("App executable is missing or invalid")
        }
        return foundVersion
    }

    static func copyBundle(_ source: URL, _ destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["--rsrc", "--extattr", "--acl", source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppReplacementError("App staging failed") }
    }

    static func validateSignature(_ candidate: URL, _ reference: URL?) throws {
        func code(_ url: URL) throws -> SecStaticCode {
            var value: SecStaticCode?
            let result = SecStaticCodeCreateWithPath(url as CFURL, [], &value)
            guard result == errSecSuccess, let value else {
                throw AppReplacementError("Cannot inspect app signature: \(result)")
            }
            return value
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        var requirement: SecRequirement?
        if let reference {
            let installed = try code(reference)
            let valid = SecStaticCodeCheckValidity(installed, flags, nil)
            guard valid == errSecSuccess else { throw AppReplacementError("Installed app signature is invalid: \(valid)") }
            let result = SecCodeCopyDesignatedRequirement(installed, [], &requirement)
            guard result == errSecSuccess, requirement != nil else {
                throw AppReplacementError("Cannot establish installed signing identity: \(result)")
            }
        }
        let result = SecStaticCodeCheckValidity(try code(candidate), flags, requirement)
        guard result == errSecSuccess else {
            throw AppReplacementError("App signature does not match the trusted installation: \(result)")
        }
    }
}
