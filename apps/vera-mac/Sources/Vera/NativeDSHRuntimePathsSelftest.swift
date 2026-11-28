import Foundation

enum NativeDSHRuntimePathsSelftest {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-paths-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appendingPathComponent("services/dsh-runtime")
        let dependency = application.appendingPathComponent("node_modules/@deepseek-ai/dsh-session")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = application.appendingPathComponent("sidecar.mjs")
        try Data().write(to: script)
        try Data("{}".utf8).write(to: dependency.appendingPathComponent("package.json"))
        let executable = bin.appendingPathComponent("node")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let found = try NativeDSHRuntimePaths.source(root: root, searchPath: ".:relative:" + bin.path)
        try piCheck(found.executable == executable && found.script == script)
        let linkedBin = root.appendingPathComponent("linked-bin")
        try FileManager.default.createDirectory(at: linkedBin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkedBin.appendingPathComponent("node").path, withDestinationPath: executable.path)
        let linked = try NativeDSHRuntimePaths.source(root: root, searchPath: linkedBin.path)
        try piCheck(linked.executable == executable.resolvingSymlinksInPath() && linked.script == script)
        try refuses { _ = try NativeDSHRuntimePaths.source(root: root, searchPath: ".:relative:") }
        let packaged = try NativeDSHRuntimePaths.packaged(["--repo", root.path, "--node", executable.path])
        try piCheck(packaged.executable == executable && packaged.script == script)
        try refuses { _ = try NativeDSHRuntimePaths.packaged(["--node", executable.path, "--node", executable.path]) }
        try FileManager.default.removeItem(at: dependency.appendingPathComponent("package.json"))
        try refuses { _ = try NativeDSHRuntimePaths.source(root: root, searchPath: bin.path) }
        try FileManager.default.removeItem(at: script)
        try refuses { _ = try NativeDSHRuntimePaths.packaged(["--repo", root.path, "--node", executable.path]) }
        print("PASS: local execution paths require installed source dependencies or verified package locations")
    }

    private static func refuses(_ action: () throws -> Void) throws {
        do { try action() } catch NativeDSHRuntimePaths.Failure.missing { return }
        throw PiBrokerError.invalid
    }
}
