import Foundation
import Darwin

struct NativeFolderIdentity: Codable, Equatable, Hashable, Sendable {
    let device: Int64
    let inode: UInt64

    static func of(descriptor: Int32) -> NativeFolderIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return NativeFolderIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }

    static func of(path: String) -> NativeFolderIdentity? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return NativeFolderIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

struct NativeFolderLocation: Equatable, Sendable {
    let root: FolderGrant
    let components: [String]

    var path: String { components.isEmpty ? root.path : root.path + "/" + components.joined(separator: "/") }
    var name: String { components.last ?? root.name }
    var parentComponents: [String] { Array(components.dropLast()) }
}

final class NativeFolderDescriptor: @unchecked Sendable {
    let raw: Int32

    init(_ raw: Int32) { self.raw = raw }
    deinit { close(raw) }
}

enum NativeFolderIO {
    static let chunk = 65_536
    static let temporaryPrefix = ".tandem-"

    static func errno(_ context: String) -> NativeToolError {
        NativeToolError.failed("\(context): \(String(cString: strerror(Darwin.errno)))")
    }

    static func openRoot(_ grant: FolderGrant) throws -> NativeFolderDescriptor {
        let fd = open(grant.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFolderAccessError.notFound(grant.path) }
        let descriptor = NativeFolderDescriptor(fd)
        if let identity = grant.identity {
            guard NativeFolderIdentity.of(descriptor: fd) == identity else { throw NativeFolderAccessError.outsideGrants(grant.path) }
        }
        return descriptor
    }

    static func openDirectory(_ parent: NativeFolderDescriptor, _ name: String, display: String) throws -> NativeFolderDescriptor {
        let fd = openat(parent.raw, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if let info = status(parent, name), (info.st_mode & S_IFMT) == S_IFLNK { throw NativeFolderAccessError.symlink(display) }
            switch Darwin.errno {
            case ELOOP: throw NativeFolderAccessError.symlink(display)
            case ENOENT: throw NativeFolderAccessError.notFound(display)
            case ENOTDIR: throw NativeFolderAccessError.notADirectory(display)
            default: throw errno("Couldn't open \(display)")
            }
        }
        return NativeFolderDescriptor(fd)
    }

    static func walk(_ location: NativeFolderLocation, components: [String]) throws -> NativeFolderDescriptor {
        var current = try openRoot(location.root)
        var display = location.root.path
        for component in components {
            display += "/" + component
            current = try openDirectory(current, component, display: display)
        }
        return current
    }

    static func parent(of location: NativeFolderLocation) throws -> NativeFolderDescriptor {
        try walk(location, components: location.parentComponents)
    }

    static func realPath(_ directory: NativeFolderDescriptor, display: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard fcntl(directory.raw, F_GETPATH, &buffer) == 0 else { throw errno("Couldn't resolve \(display)") }
        return String(cString: buffer)
    }

    static func status(_ directory: NativeFolderDescriptor, _ name: String) -> stat? {
        var info = stat()
        guard fstatat(directory.raw, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return info
    }

    static func kind(_ info: stat) -> String {
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return "folder"
        case S_IFLNK: return "link"
        case S_IFREG: return "file"
        default: return "other"
        }
    }

    static func openFile(_ directory: NativeFolderDescriptor, _ name: String, display: String) throws -> FileHandle {
        let fd = openat(directory.raw, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if let info = status(directory, name), (info.st_mode & S_IFMT) == S_IFLNK { throw NativeFolderAccessError.symlink(display) }
            switch Darwin.errno {
            case ELOOP: throw NativeFolderAccessError.symlink(display)
            case ENOENT: throw NativeFolderAccessError.notFound(display)
            default: throw errno("Couldn't open \(display)")
            }
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw NativeFolderAccessError.binary(display)
        }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func fileSize(_ handle: FileHandle) -> Int {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return 0 }
        return Int(info.st_size)
    }

    static func readText(_ directory: NativeFolderDescriptor, _ name: String, display: String, limit: Int) throws -> String {
        let handle = try openFile(directory, name, display: display)
        let size = fileSize(handle)
        guard size <= limit else { throw NativeFolderAccessError.tooLarge(display, limit) }
        let data = handle.readData(ofLength: size)
        guard !NativeFolderTools.isBinary(data), let text = String(data: data, encoding: .utf8) else { throw NativeFolderAccessError.binary(display) }
        return text
    }

    static func readTextIfSmall(_ directory: NativeFolderDescriptor, _ name: String, display: String, limit: Int) -> String? {
        try? readText(directory, name, display: display, limit: limit)
    }

    struct Window: Sendable {
        var content: String
        var startLine: Int
        var endLine: Int
        var more: Bool
    }

    static func readWindow(_ directory: NativeFolderDescriptor, _ name: String, display: String, startLine: Int, maximumBytes: Int) throws -> Window {
        let handle = try openFile(directory, name, display: display)
        var pendingLine = Data()
        var currentLine = 1
        var collected = Data()
        var collectedLines = 0
        var more = false
        var sawAny = false
        var checkedBinary = false
        var finished = false
        var scanned = 0
        let scanLimit = 64 * 1_048_576
        func consume(_ line: Data, terminated: Bool) throws -> Bool {
            if currentLine >= startLine {
                if line.count > maximumBytes {
                    throw NativeToolError.failed("Line \(currentLine) of \(display) is longer than \(maximumBytes) bytes. Raise max_bytes to read it.")
                }
                if collected.count + line.count + (collectedLines == 0 ? 0 : 1) > maximumBytes {
                    more = true
                    return false
                }
                if collectedLines > 0 { collected.append(0x0A) }
                collected.append(line)
                collectedLines += 1
                sawAny = true
            }
            if terminated { currentLine += 1 }
            return true
        }
        while !finished {
            let data = handle.readData(ofLength: chunk)
            if !checkedBinary {
                checkedBinary = true
                if NativeFolderTools.isBinary(data) { throw NativeFolderAccessError.binary(display) }
            }
            if data.isEmpty {
                finished = true
                if !pendingLine.isEmpty || (currentLine >= startLine && !sawAny && pendingLine.isEmpty && scanned == 0) {
                    _ = try consume(pendingLine, terminated: false)
                }
                break
            }
            scanned += data.count
            guard scanned <= scanLimit else { throw NativeFolderAccessError.tooLarge(display, scanLimit) }
            var start = data.startIndex
            while let newline = data[start...].firstIndex(of: 0x0A) {
                pendingLine.append(data[start..<newline])
                guard try consume(pendingLine, terminated: true) else { finished = true; break }
                pendingLine = Data()
                start = data.index(after: newline)
            }
            if finished { break }
            pendingLine.append(data[start...])
            guard pendingLine.count <= maximumBytes + chunk else {
                throw NativeToolError.failed("Line \(currentLine) of \(display) is longer than \(maximumBytes) bytes. Raise max_bytes to read it.")
            }
        }
        guard let text = String(data: collected, encoding: .utf8) else { throw NativeFolderAccessError.binary(display) }
        let endLine = collectedLines == 0 ? startLine - 1 : startLine + collectedLines - 1
        return Window(content: text, startLine: startLine, endLine: max(endLine, 0), more: more)
    }

    static func writeAtomically(_ directory: NativeFolderDescriptor, _ name: String, display: String, data: Data) throws {
        let temporary = temporaryPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        let existing = status(directory, name)
        if let existing {
            guard (existing.st_mode & S_IFMT) == S_IFREG else { throw NativeFolderAccessError.notADirectory(display) }
        }
        let mode: mode_t = existing.map { $0.st_mode & 0o7777 } ?? 0o644
        let fd = openat(directory.raw, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw errno("Couldn't write \(display)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            unlinkat(directory.raw, temporary, 0)
            throw NativeToolError.failed("Couldn't write \(display): \(error.localizedDescription)")
        }
        guard fchmod(fd, mode) == 0 else {
            let failure = errno("Couldn't keep the permissions of \(display)")
            unlinkat(directory.raw, temporary, 0)
            throw failure
        }
        guard renameat(directory.raw, temporary, directory.raw, name) == 0 else {
            let failure = errno("Couldn't replace \(display)")
            unlinkat(directory.raw, temporary, 0)
            throw failure
        }
    }

    static func makeDirectory(_ directory: NativeFolderDescriptor, _ name: String, display: String) throws -> Bool {
        if let existing = status(directory, name) {
            guard (existing.st_mode & S_IFMT) == S_IFDIR else { throw NativeFolderAccessError.exists(display) }
            return false
        }
        guard mkdirat(directory.raw, name, 0o755) == 0 else { throw errno("Couldn't create \(display)") }
        return true
    }

    static func rename(from: NativeFolderDescriptor, _ fromName: String, to: NativeFolderDescriptor, _ toName: String, display: String) throws {
        guard renameatx_np(from.raw, fromName, to.raw, toName, UInt32(RENAME_EXCL)) == 0 else {
            switch Darwin.errno {
            case EEXIST, ENOTEMPTY: throw NativeFolderAccessError.exists(display)
            case ENOENT: throw NativeFolderAccessError.notFound(display)
            default: throw errno("Couldn't move to \(display)")
            }
        }
    }

    static func entries(_ directory: NativeFolderDescriptor) throws -> [String] {
        let duplicate = dup(directory.raw)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw errno("Couldn't list the folder")
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names.sorted()
    }
}
