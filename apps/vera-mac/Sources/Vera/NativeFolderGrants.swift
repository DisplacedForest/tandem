import Foundation

struct FolderGrant: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var path: String
    var name: String
    var bookmark: Data?

    init(id: String = UUID().uuidString.lowercased(), path: String, name: String? = nil, bookmark: Data? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.bookmark = bookmark
    }

    static func make(url: URL) throws -> FolderGrant {
        let standardized = url.standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &directory), directory.boolValue else {
            throw NativeFolderAccessError.notADirectory(standardized.path)
        }
        let real = standardized.resolvingSymlinksInPath().path
        let bookmark = try? standardized.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return FolderGrant(path: real, name: standardized.lastPathComponent, bookmark: bookmark)
    }

    func currentRealPath() -> String? {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return nil }
        return url.resolvingSymlinksInPath().path
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
    case notFound(String)
    case exists(String)
    case binary(String)
    case tooLarge(String, Int)
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let path): return "\(path) is not a folder."
        case .noGrants: return "No folder has been granted to this chat."
        case .relativeWithoutAnchor(let path): return "\(path) is a relative path and this chat has more than one granted folder. Use a full path."
        case .outsideGrants(let path): return "\(path) is outside every folder granted to this chat."
        case .notFound(let path): return "\(path) does not exist."
        case .exists(let path): return "\(path) already exists."
        case .binary(let path): return "\(path) is not a text file."
        case .tooLarge(let path, let limit): return "\(path) is larger than the \(limit / 1024) KB read limit. Read a smaller range."
        case .invalidPath(let path): return "\(path) is not a valid path."
        }
    }
}

struct NativeFolderAccess: Sendable {
    let roots: [String]

    init(grants: [FolderGrant]) {
        roots = grants.compactMap { $0.currentRealPath() }
    }

    static func contains(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    func resolve(_ requested: String, mustExist: Bool = true) throws -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), trimmed.utf8.count <= 4096 else { throw NativeFolderAccessError.invalidPath(requested) }
        guard !roots.isEmpty else { throw NativeFolderAccessError.noGrants }
        var absolute: String
        if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else if trimmed.hasPrefix("~") {
            throw NativeFolderAccessError.outsideGrants(trimmed)
        } else {
            guard roots.count == 1 else { throw NativeFolderAccessError.relativeWithoutAnchor(trimmed) }
            absolute = roots[0] + "/" + trimmed
        }
        absolute = URL(fileURLWithPath: absolute).standardizedFileURL.path
        let real = try Self.realPath(absolute)
        guard roots.contains(where: { Self.contains(root: $0, path: real) }) else {
            throw NativeFolderAccessError.outsideGrants(trimmed)
        }
        if mustExist, !FileManager.default.fileExists(atPath: real) { throw NativeFolderAccessError.notFound(trimmed) }
        return real
    }

    static func realPath(_ absolute: String) throws -> String {
        var existing = absolute
        var remainder: [String] = []
        let manager = FileManager.default
        while !manager.fileExists(atPath: existing) {
            let url = URL(fileURLWithPath: existing)
            remainder.insert(url.lastPathComponent, at: 0)
            let parent = url.deletingLastPathComponent().path
            guard parent != existing, !parent.isEmpty else { throw NativeFolderAccessError.invalidPath(absolute) }
            existing = parent
        }
        let resolved = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        guard !remainder.contains(where: { $0 == ".." || $0 == "." }) else { throw NativeFolderAccessError.invalidPath(absolute) }
        return remainder.isEmpty ? resolved : resolved + "/" + remainder.joined(separator: "/")
    }
}

enum NativeFileChangeKind: String, Codable, Equatable, Hashable, Sendable {
    case created, edited, moved, directory
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
        }
    }

    static func capped(_ text: String?) -> (String?, Bool) {
        guard let text else { return (nil, false) }
        guard text.utf8.count > contentCap else { return (text, false) }
        return (String(decoding: Array(text.utf8.prefix(contentCap)), as: UTF8.self), true)
    }

    init(id: String = UUID().uuidString.lowercased(), path: String, kind: NativeFileChangeKind,
         before: String? = nil, after: String? = nil, movedFrom: String? = nil) {
        self.id = id
        self.path = path
        self.kind = kind
        let (beforeText, beforeCut) = Self.capped(before)
        let (afterText, afterCut) = Self.capped(after)
        self.before = beforeText
        self.after = afterText
        self.movedFrom = movedFrom
        truncated = beforeCut || afterCut
    }
}

enum NativeToolCallContext {
    @TaskLocal static var activityID: String?
}

actor NativeFileChangeLedger {
    private var changes: [String: [NativeFileChange]] = [:]

    func record(_ change: NativeFileChange) {
        guard let id = NativeToolCallContext.activityID else { return }
        changes[id, default: []].append(change)
    }

    func take(_ activityID: String) -> [NativeFileChange] {
        changes.removeValue(forKey: activityID) ?? []
    }

    func peek(_ activityID: String) -> [NativeFileChange] {
        changes[activityID] ?? []
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

    static func hunks(before: String, after: String, context: Int = 2) -> [Hunk] {
        let all = lines(before: before, after: after)
        var keep = Array(repeating: false, count: all.count)
        for (index, line) in all.enumerated() {
            if case .same = line { continue }
            for offset in max(0, index - context)...min(all.count - 1, index + context) { keep[offset] = true }
        }
        var hunks: [Hunk] = []
        var current: [Line] = []
        var emitted = 0
        for (index, line) in all.enumerated() {
            if keep[index] {
                current.append(line)
                emitted += 1
                if emitted >= maximumLines { break }
            } else if !current.isEmpty {
                hunks.append(Hunk(id: hunks.count, lines: current))
                current = []
            }
        }
        if !current.isEmpty { hunks.append(Hunk(id: hunks.count, lines: current)) }
        return hunks
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
