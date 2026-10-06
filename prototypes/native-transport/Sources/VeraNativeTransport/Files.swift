import Foundation
import Darwin

struct PrivateFiles {
    static func read(_ url: URL, limit: Int = 65536) throws -> Data {
        try require(url.isFileURL && url.standardizedFileURL.path == url.standardizedFileURL.resolvingSymlinksInPath().path, .storage)
        var parent = stat()
        try require(lstat(url.deletingLastPathComponent().path, &parent) == 0 && (parent.st_mode & S_IFMT) == S_IFDIR && parent.st_uid == getuid() && (parent.st_mode & 0o077) == 0, .storage)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        try require(fd >= 0, .storage)
        defer { close(fd) }
        var info = stat()
        try require(fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && (info.st_mode & 0o077) == 0 && info.st_size <= limit, .storage)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            try require(count >= 0, .storage)
            if count == 0 { return data }
            try require(data.count + count <= limit, .storage)
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

struct SelectedProfileMetadata {
    static func validate(_ url: URL, profile: String) throws {
        try require(url.isFileURL && url.standardizedFileURL.path == url.standardizedFileURL.resolvingSymlinksInPath().path, .storage)
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try require(directory >= 0, .storage)
        defer { close(directory) }
        var parent = stat()
        try require(fstat(directory, &parent) == 0 && (parent.st_mode & S_IFMT) == S_IFDIR && parent.st_uid == getuid() && (parent.st_mode & 0o022) == 0, .storage)
        let fd = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        try require(fd >= 0, .storage)
        defer { close(fd) }
        var info = stat()
        let limit = 4_000_000
        try require(fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && (info.st_mode & 0o077) == 0 && info.st_size <= limit, .storage)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            try require(count >= 0, .storage)
            if count == 0 { break }
            try require(data.count + count <= limit, .storage)
            data.append(contentsOf: buffer.prefix(count))
        }
        try SavedProfile.validate(J.parse(data, limit: limit), profile: profile)
    }
}

struct SelectedCredential: CredentialSource {
    let profileURL: URL
    func read(profile: String) throws -> String {
        try SelectedProfileMetadata.validate(profileURL, profile: profile)
        return try NativeCredential().read(profile: profile)
    }
}
