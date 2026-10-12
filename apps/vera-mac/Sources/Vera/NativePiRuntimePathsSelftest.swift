import Foundation

enum NativePiRuntimePathsSelftest {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-inventory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("notice".utf8).write(to: root.appendingPathComponent("NOTICE.md"))
        try Data("child".utf8).write(to: root.appendingPathComponent("nested/child"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "nested")
        let canonical = try piCanonical(root)
        for location in [root, canonical, canonical.standardizedFileURL] {
            try piCheck(try NativePiRuntimePaths.inventory(location) == ["NOTICE.md", "nested/child", "link"])
        }
        try Data().write(to: root.appendingPathComponent("unexpected"))
        try piCheck(try NativePiRuntimePaths.inventory(canonical.standardizedFileURL) == ["NOTICE.md", "nested/child", "link", "unexpected"])
        print("PASS: packaged runtime inventory preserves relative paths across filesystem aliases")
    }
}
