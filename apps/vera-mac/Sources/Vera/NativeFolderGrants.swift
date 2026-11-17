import Foundation
import Darwin

enum FolderAvailability: Equatable, Hashable, Sendable {
    case usable
    case missing
    case offline(String)
    case denied

    var rowNote: String? {
        switch self {
        case .usable: return nil
        case .missing: return "Can't be found."
        case .offline: return "On a drive that isn't connected."
        case .denied: return "Can't be opened."
        }
    }

    func chipNote(_ name: String) -> String? {
        switch self {
        case .usable: return nil
        case .missing: return "\(name) can't be found"
        case .offline: return "\(name) is on a drive that isn't connected"
        case .denied: return "\(name) can't be opened"
        }
    }

    var modelNote: String? {
        switch self {
        case .usable: return nil
        case .missing: return "can't be found right now"
        case .offline: return "its drive isn't connected right now"
        case .denied: return "can't be opened right now"
        }
    }

    var canChooseAgain: Bool { self == .missing || self == .denied }

    static let notes: [FolderAvailability] = [.missing, .offline("Storage"), .denied]
}

struct FolderGrant: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var path: String
    var name: String
    var bookmark: Data?
    var identity: NativeFolderIdentity?
    var readOnly: Bool = false

    init(id: String = UUID().uuidString.lowercased(), path: String, name: String? = nil, bookmark: Data? = nil, identity: NativeFolderIdentity? = nil, readOnly: Bool = false) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.bookmark = bookmark
        self.identity = identity
        self.readOnly = readOnly
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, name, bookmark, identity, readOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        name = try container.decode(String.self, forKey: .name)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        identity = try container.decodeIfPresent(NativeFolderIdentity.self, forKey: .identity)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }

    static func make(url: URL) throws -> FolderGrant {
        let standardized = url.standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &directory), directory.boolValue else {
            throw NativeFolderAccessError.notADirectory(standardized.path)
        }
        let real = standardized.resolvingSymlinksInPath().path
        guard let identity = NativeFolderIdentity.of(path: real) else { throw NativeFolderAccessError.notADirectory(real) }
        let bookmark = try? standardized.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return FolderGrant(path: real, name: standardized.lastPathComponent, bookmark: bookmark, identity: identity)
    }

    func current() -> FolderGrant? { resolved().grant }

    var availability: FolderAvailability { resolved().state }

    static func volume(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/Volumes/"), parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    static func isTrashName(_ component: Substring) -> Bool {
        let name = component.lowercased()
        return name == ".trash" || name == ".trashes"
    }

    static func inTrash(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).contains(where: isTrashName)
    }

    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func reachable(_ grant: FolderGrant) -> (grant: FolderGrant?, state: FolderAvailability) {
        if inTrash(grant.path) || inTrash(real(grant.path)) { return (nil, .missing) }
        return access(grant.path, R_OK | X_OK) == 0 ? (grant, .usable) : (nil, .denied)
    }

    func resolved() -> (grant: FolderGrant?, state: FolderAvailability) {
        var info = stat()
        if stat(path, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFDIR {
                let found = NativeFolderIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
                if identity == nil || found == identity { return Self.reachable(self) }
            }
        } else if Darwin.errno == EACCES {
            return (nil, .denied)
        }
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                let real = url.resolvingSymlinksInPath().path
                if let found = NativeFolderIdentity.of(path: real), identity == nil || found == identity {
                    var moved = self
                    moved.path = real
                    return Self.reachable(moved)
                }
            }
        }
        if let volume = Self.volume(of: path), !FileManager.default.fileExists(atPath: "/Volumes/" + volume) {
            return (nil, .offline(volume))
        }
        return (nil, .missing)
    }

    static func encode(_ grants: [FolderGrant]) -> String? {
        guard !grants.isEmpty, let data = try? JSONEncoder().encode(grants) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ raw: String?) -> [FolderGrant] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([FolderGrant].self, from: data)) ?? []
    }
}

enum NativeFolderAccessError: Error, LocalizedError, Equatable {
    case notADirectory(String)
    case noGrants
    case relativeWithoutAnchor(String)
    case outsideGrants(String)
    case symlink(String)
    case notFound(String)
    case exists(String)
    case binary(String)
    case tooLarge(String, Int)
    case invalidPath(String)
    case readOnly(String)
    case unavailable(name: String, path: String, state: FolderAvailability)
    case unchangeable(String)
    case inTrash(String)

    static func gone(_ grant: FolderGrant, _ state: FolderAvailability) -> NativeFolderAccessError {
        .unavailable(name: grant.name, path: grant.path, state: state)
    }

    var errorDescription: String? {
        switch self {
        case .notADirectory(let path): return "\(path) is not a folder."
        case .noGrants: return "No folder has been shared with this chat."
        case .relativeWithoutAnchor(let path): return "\(path) is a relative path and this chat has more than one shared folder. Use a full path."
        case .outsideGrants(let path): return "\(path) is outside every folder shared with this chat."
        case .symlink(let path): return "\(path) goes through a symbolic link, which the file tools do not follow."
        case .notFound(let path): return "\(path) does not exist."
        case .exists(let path): return "\(path) already exists."
        case .binary(let path): return "\(path) is not a text file."
        case .tooLarge(let path, let limit): return "\(path) is larger than the \(limit / 1024) KB limit."
        case .invalidPath(let path): return "\(path) is not a valid path."
        case .readOnly(let path): return "\(path) is read-only in this chat."
        case .unavailable(let name, let path, let state):
            switch state {
            case .offline(let volume): return "The shared folder \(name) is on the drive \(volume), which isn't connected. Connect the drive and try again."
            case .denied: return "macOS won't let Tandem open the shared folder \(name). Choose it again in Settings, Rules to give access."
            case .missing, .usable:
                return "The shared folder \(name) can't be found. It was at \(path) and may have been moved, renamed or deleted. It's still shared with this chat. Put it back, or choose it again in Settings, Rules."
            }
        case .inTrash(let path): return "\(path) is in the Trash, which the file tools leave alone."
        case .unchangeable(let name): return "\(name) can be read but not changed. The folder or its drive doesn't allow changes."
        }
    }
}

struct NativeFolderAccess: Sendable {
    let roots: [FolderGrant]
    let unavailable: [NativeFolderAccessError]
    private let lost: [String]

    init(grants: [FolderGrant]) {
        var usable: [FolderGrant] = []
        var failures: [NativeFolderAccessError] = []
        var paths: [String] = []
        for grant in grants {
            let result = grant.resolved()
            if let found = result.grant {
                usable.append(found)
            } else {
                failures.append(.gone(grant, result.state))
                paths.append(grant.path)
            }
        }
        roots = usable
        unavailable = failures
        lost = paths
    }

    func only() throws -> FolderGrant {
        let total = roots.count + unavailable.count
        guard total > 0 else { throw NativeFolderAccessError.noGrants }
        guard total == 1 else { throw NativeFolderAccessError.relativeWithoutAnchor(".") }
        if let failure = unavailable.first { throw failure }
        return roots[0]
    }

    static func changeable(_ location: NativeFolderLocation) -> Bool {
        let root = location.root.path
        var path = location.components.isEmpty ? root : (location.path as NSString).deletingLastPathComponent
        while path != root, contains(root: root, path: path), !FileManager.default.fileExists(atPath: path) {
            path = (path as NSString).deletingLastPathComponent
        }
        guard FileManager.default.fileExists(atPath: path) else { return true }
        return access(path, W_OK) == 0
    }

    static func reserved(_ component: Substring) -> Bool {
        component == "." || component == ".." || component.lowercased().hasPrefix(NativeFolderIO.temporaryPrefix)
    }

    static func contains(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    func readOnlyRoot(under path: String) -> FolderGrant? {
        roots.first { $0.readOnly && Self.contains(root: path, path: $0.path) }
    }

    func containsReadOnlyRoot(under path: String) -> Bool {
        readOnlyRoot(under: path) != nil
    }

    func requireNoReadOnlyRoot(under location: NativeFolderLocation) throws {
        if let protected = readOnlyRoot(under: location.path) { throw NativeFolderAccessError.readOnly(protected.path) }
    }

    func locate(_ requested: String) throws -> NativeFolderLocation {
        guard !requested.isEmpty, !requested.contains("\0"), !requested.contains("\n"), !requested.contains("\r"), requested.utf8.count <= 4096,
              !requested.split(separator: "/", omittingEmptySubsequences: true).contains(where: Self.reserved) else {
            throw NativeFolderAccessError.invalidPath(requested)
        }
        guard !roots.isEmpty || !unavailable.isEmpty else { throw NativeFolderAccessError.noGrants }
        let absolute: String
        if requested.hasPrefix("/") {
            absolute = requested
        } else if requested.hasPrefix("~") {
            throw NativeFolderAccessError.outsideGrants(requested)
        } else {
            guard roots.count + unavailable.count == 1 else { throw NativeFolderAccessError.relativeWithoutAnchor(requested) }
            absolute = try only().path + "/" + requested
        }
        let candidates = [URL(fileURLWithPath: absolute).standardizedFileURL.path,
                          URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath().path]
        let matches = candidates.flatMap { candidate in
            roots.filter { Self.contains(root: $0.path, path: candidate) }.map { (root: $0, path: candidate) }
        }
        if let best = matches.max(by: { $0.root.path.count < $1.root.path.count }) {
            let relative = String(best.path.dropFirst(best.root.path.count)).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !relative.contains(where: { Self.reserved(Substring($0)) }) else { throw NativeFolderAccessError.invalidPath(requested) }
            guard !relative.contains(where: { FolderGrant.isTrashName(Substring($0)) }) else { throw NativeFolderAccessError.inTrash(requested) }
            return NativeFolderLocation(root: best.root, components: relative)
        }
        for candidate in candidates {
            if let index = lost.firstIndex(where: { Self.contains(root: $0, path: candidate) }) { throw unavailable[index] }
        }
        throw NativeFolderAccessError.outsideGrants(requested)
    }
}

enum NativeFileChangeKind: String, Codable, Equatable, Hashable, Sendable {
    case created, edited, moved, directory, trashed
}

struct NativeFileChange: Codable, Equatable, Hashable, Identifiable, Sendable {
    static let contentCap = 65_536

    var id: String
    var path: String
    var kind: NativeFileChangeKind
    var before: String?
    var after: String?
    var movedFrom: String?
    var truncated: Bool = false

    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    var title: String {
        switch kind {
        case .created: return "Created \(name)"
        case .edited: return "Edited \(name)"
        case .moved: return "Moved to \(name)"
        case .directory: return "Created folder \(name)"
        case .trashed: return "Moved \(name) to the Trash"
        }
    }

    init(id: String = UUID().uuidString.lowercased(), path: String, kind: NativeFileChangeKind,
         before: String? = nil, after: String? = nil, movedFrom: String? = nil) {
        self.id = id
        self.path = path
        self.kind = kind
        self.movedFrom = movedFrom
        let tooLarge = (before?.utf8.count ?? 0) > Self.contentCap || (after?.utf8.count ?? 0) > Self.contentCap
        truncated = tooLarge
        self.before = tooLarge ? nil : before
        self.after = tooLarge ? nil : after
    }
}

enum NativeToolCallContext {
    @TaskLocal static var activityID: String?
    @TaskLocal static var request: String?
    @TaskLocal static var confirmed: Bool?
    @TaskLocal static var reason: NativeToolReasonSink?
    @TaskLocal static var boundary: NativeEffectBoundary?
    @TaskLocal static var round: Int?
    @TaskLocal static var otherToolRan: Bool?
    @TaskLocal static var sameToolOrdinal: Int?
    @TaskLocal static var replyCallOrdinal: Int?
    @TaskLocal static var instructionHolder: String?

    static func effectStarts() {
        boundary?.mark()
    }
}

final class NativeToolReasonSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NativeRuleReason?

    var value: NativeRuleReason? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func note(_ reason: NativeRuleReason) {
        lock.lock(); defer { lock.unlock() }
        stored = reason
    }
}

enum NativeToolRequestKey {
    static func canonical(name: String, request: String) -> String {
        guard let data = request.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: canonical, encoding: .utf8) else {
            return name + "\n" + request.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return name + "\n" + text
    }
}

final class NativeFileChangeLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (String, NativeFileChange) -> Void)?
    private var held: [(String, NativeFileChange)] = []

    func attach(_ sink: @escaping @Sendable (String, NativeFileChange) -> Void) {
        lock.lock()
        self.sink = sink
        let pending = held
        held = []
        lock.unlock()
        for (activity, change) in pending { sink(activity, change) }
    }

    func record(_ change: NativeFileChange) {
        let activity = NativeToolCallContext.activityID ?? ""
        lock.lock()
        guard let sink else {
            held.append((activity, change))
            lock.unlock()
            return
        }
        lock.unlock()
        sink(activity, change)
    }

    func recorded() -> [NativeFileChange] {
        lock.lock(); defer { lock.unlock() }
        return held.map(\.1)
    }
}

enum NativeLineDiff {
    enum Line: Equatable, Hashable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    struct Hunk: Equatable, Hashable, Identifiable, Sendable {
        let id: Int
        let lines: [Line]
    }

    static let maximumLines = 400

    static func lines(before: String, after: String) -> [Line] {
        let old = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let new = after.isEmpty ? [] : after.components(separatedBy: "\n")
        if old.count * new.count > 4_000_000 {
            return old.map(Line.removed) + new.map(Line.added)
        }
        var table = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        if !old.isEmpty && !new.isEmpty {
            for i in stride(from: old.count - 1, through: 0, by: -1) {
                for j in stride(from: new.count - 1, through: 0, by: -1) {
                    table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var result: [Line] = []
        var i = 0
        var j = 0
        while i < old.count && j < new.count {
            if old[i] == new[j] {
                result.append(.same(old[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append(.removed(old[i])); i += 1
            } else {
                result.append(.added(new[j])); j += 1
            }
        }
        while i < old.count { result.append(.removed(old[i])); i += 1 }
        while j < new.count { result.append(.added(new[j])); j += 1 }
        return result
    }

    struct Rendering: Equatable, Sendable {
        let hunks: [Hunk]
        let omittedLines: Int
    }

    static func hunks(before: String, after: String, context: Int = 2) -> [Hunk] {
        render(before: before, after: after, context: context).hunks
    }

    static func render(before: String, after: String, context: Int = 2) -> Rendering {
        let all = lines(before: before, after: after)
        var keep = Array(repeating: false, count: all.count)
        for (index, line) in all.enumerated() {
            if case .same = line { continue }
            for offset in max(0, index - context)...min(all.count - 1, index + context) { keep[offset] = true }
        }
        var hunks: [Hunk] = []
        var current: [Line] = []
        var emitted = 0
        var omitted = 0
        for (index, line) in all.enumerated() where keep[index] {
            if emitted >= maximumLines {
                if case .same = line {} else { omitted += 1 }
                continue
            }
            if index > 0, !keep[index - 1], !current.isEmpty {
                hunks.append(Hunk(id: hunks.count, lines: current))
                current = []
            }
            current.append(line)
            emitted += 1
        }
        if !current.isEmpty { hunks.append(Hunk(id: hunks.count, lines: current)) }
        return Rendering(hunks: hunks, omittedLines: omitted)
    }

    static func summary(before: String?, after: String?) -> String {
        let changed = lines(before: before ?? "", after: after ?? "")
        let added = changed.filter { if case .added = $0 { return true }; return false }.count
        let removed = changed.filter { if case .removed = $0 { return true }; return false }.count
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if removed > 0 { parts.append("-\(removed)") }
        return parts.isEmpty ? "No line changes" : parts.joined(separator: " ")
    }
}
