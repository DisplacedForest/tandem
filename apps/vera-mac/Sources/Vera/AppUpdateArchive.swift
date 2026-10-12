import Foundation

enum AppUpdateArchive {
    static func extract(_ archive: URL, to destination: URL) throws {
        try validate(archive)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppReplacementError("Update extraction failed") }
    }

    static func validate(_ url: URL) throws {
        let reader = ZIPReader(data: try Data(contentsOf: url, options: .mappedIfSafe))
        let size = reader.data.count
        guard size >= 22, size <= 512 * 1024 * 1024 else { throw AppReplacementError("Update archive size is unsupported") }
        var end: Int?
        for offset in stride(from: size - 22, through: max(0, size - 65_557), by: -1) {
            if (try reader.u32(offset)) == 0x06054b50, offset + 22 + (try reader.u16(offset + 20)) == size {
                end = offset
                break
            }
        }
        guard let end, (try reader.u16(end + 4)) == 0, (try reader.u16(end + 6)) == 0,
              (try reader.u16(end + 8)) == (try reader.u16(end + 10)) else {
            throw AppReplacementError("Update archive directory is invalid")
        }
        let count = (try reader.u16(end + 10))
        let centralSize = (try reader.u32(end + 12))
        let centralStart = (try reader.u32(end + 16))
        guard count > 0, count < 65_535, centralStart + centralSize == end else {
            throw AppReplacementError("Update archive layout is unsupported")
        }
        var cursor = centralStart
        var entries: [(offset: Int, end: Int)] = []
        var names = Set<String>()
        var files = Set<String>()
        var expanded = 0
        for _ in 0..<count {
            guard (try reader.u32(cursor)) == 0x02014b50, (try reader.u16(cursor + 34)) == 0 else {
                throw AppReplacementError("Update archive entry is invalid")
            }
            let flags = (try reader.u16(cursor + 8))
            let method = (try reader.u16(cursor + 10))
            let crc = (try reader.u32(cursor + 16))
            let compressed = (try reader.u32(cursor + 20))
            let uncompressed = (try reader.u32(cursor + 24))
            let nameLength = (try reader.u16(cursor + 28))
            let extraLength = (try reader.u16(cursor + 30))
            let commentLength = (try reader.u16(cursor + 32))
            let mode = (try reader.u32(cursor + 38)) >> 16
            let local = (try reader.u32(cursor + 42))
            let nameBytes = (try reader.bytes(cursor + 46, nameLength))
            guard let name = String(data: nameBytes, encoding: .utf8), !name.isEmpty,
                  !name.contains("\\"), !name.contains(":"), !name.contains("\0"), !name.hasPrefix("/"),
                  flags & ~0x080e == 0, method == 0 || method == 8,
                  mode & 0xf000 == 0 || mode & 0xf000 == 0x8000 || mode & 0xf000 == 0x4000 else {
                throw AppReplacementError("Update archive contains an unsafe entry")
            }
            let normalized = name.hasSuffix("/") ? String(name.dropLast()) : name
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            guard components.first == "Vera.app" || components.first == "__MACOSX",
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  names.insert(normalized).inserted else {
                throw AppReplacementError("Update archive contains an unsafe path")
            }
            if components.first == "Vera.app", components.contains(where: { $0.hasPrefix("._") }) {
                throw AppReplacementError("Update archive contains misplaced metadata")
            }
            if !name.hasSuffix("/") { files.insert(normalized) }
            expanded += uncompressed
            guard uncompressed <= 512 * 1024 * 1024, expanded <= 2 * 1024 * 1024 * 1024 else {
                throw AppReplacementError("Expanded update archive is too large")
            }
            try reader.extra(cursor + 46 + nameLength, extraLength)
            cursor += 46 + nameLength + extraLength + commentLength
            guard cursor <= end, (try reader.u32(local)) == 0x04034b50,
                  (try reader.u16(local + 6)) == flags, (try reader.u16(local + 8)) == method,
                  (try reader.u16(local + 26)) == nameLength,
                  (try reader.bytes(local + 30, nameLength)) == nameBytes else {
                throw AppReplacementError("Update archive headers disagree")
            }
            let localExtra = (try reader.u16(local + 28))
            try reader.extra(local + 30 + nameLength, localExtra)
            var localEnd = local + 30 + nameLength + localExtra + compressed
            if flags & 8 != 0 {
                if (try reader.u32(localEnd)) == 0x08074b50 { localEnd += 4 }
                guard (try reader.u32(localEnd)) == crc, (try reader.u32(localEnd + 4)) == compressed,
                      (try reader.u32(localEnd + 8)) == uncompressed else {
                    throw AppReplacementError("Update archive descriptor is invalid")
                }
                localEnd += 12
            } else {
                guard (try reader.u32(local + 14)) == crc, (try reader.u32(local + 18)) == compressed,
                      (try reader.u32(local + 22)) == uncompressed else {
                    throw AppReplacementError("Update archive sizes disagree")
                }
            }
            guard localEnd <= centralStart else { throw AppReplacementError("Update archive data exceeds its directory") }
            entries.append((local, localEnd))
        }
        guard cursor == end else { throw AppReplacementError("Update archive directory is incomplete") }
        var next = 0
        for entry in entries.sorted(by: { $0.offset < $1.offset }) {
            guard entry.offset == next else { throw AppReplacementError("Update archive has unlisted or overlapping data") }
            next = entry.end
        }
        guard next == centralStart else { throw AppReplacementError("Update archive has unlisted data") }
        for name in names {
            var components = name.split(separator: "/")
            if components.first == "__MACOSX" {
                if components.count == 1 {
                    guard !files.contains(name) else { throw AppReplacementError("Update metadata root must be a directory") }
                } else {
                    var counterpart = Array(components.dropFirst()).map(String.init)
                    if files.contains(name) {
                        guard let leaf = counterpart.last, leaf.hasPrefix("._") else {
                            throw AppReplacementError("Update archive metadata name is invalid")
                        }
                        counterpart[counterpart.count - 1] = String(leaf.dropFirst(2))
                    }
                    guard counterpart.first == "Vera.app",
                          !counterpart.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix("._") }),
                          names.contains(counterpart.joined(separator: "/")),
                          files.contains(name) || !files.contains(counterpart.joined(separator: "/")) else {
                        throw AppReplacementError("Update metadata points outside its matching bundle entry")
                    }
                }
            }
            while components.count > 1 {
                components.removeLast()
                guard !files.contains(components.joined(separator: "/")) else {
                    throw AppReplacementError("Update archive contains conflicting paths")
                }
            }
        }
    }
}

private struct ZIPReader {
    let data: Data

    func bytes(_ offset: Int, _ count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw AppReplacementError("Update archive is truncated")
        }
        return data.subdata(in: offset..<(offset + count))
    }

    func u16(_ offset: Int) throws -> Int {
        let value = try bytes(offset, 2)
        return Int(value[0]) | Int(value[1]) << 8
    }

    func u32(_ offset: Int) throws -> Int {
        let value = try bytes(offset, 4)
        return Int(value[0]) | Int(value[1]) << 8 | Int(value[2]) << 16 | Int(value[3]) << 24
    }

    func extra(_ offset: Int, _ size: Int) throws {
        var cursor = offset
        while cursor < offset + size {
            let kind = try u16(cursor)
            let length = try u16(cursor + 2)
            let supported = kind == 0x5455 || kind == 0x7875 || (kind == 0x5855 && (length == 8 || length == 12))
            guard supported, cursor + 4 + length <= offset + size else {
                throw AppReplacementError("Update archive metadata is unsupported")
            }
            cursor += 4 + length
        }
    }
}
