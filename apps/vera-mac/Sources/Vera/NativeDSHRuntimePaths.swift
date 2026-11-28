import Foundation

enum NativeDSHRuntimePaths {
    enum Failure: Error, LocalizedError {
        case missing
        var errorDescription: String? { "The local execution files are unavailable. Rebuild or reinstall Tandem." }
    }

    static func resolve() throws -> (executable: URL, script: URL) {
        #if VERA_PACKAGED_RUNTIME
        let arguments = try NativePiRuntimePaths.expanded([])
        return try packaged(arguments)
        #else
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try source(root: root, searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "")
        #endif
    }

    static func packaged(_ arguments: [String]) throws -> (executable: URL, script: URL) {
        guard arguments.count.isMultiple(of: 2) else { throw Failure.missing }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard options[arguments[index]] == nil else { throw Failure.missing }
            options[arguments[index]] = arguments[index + 1]
        }
        guard let node = options["--node"], let repository = options["--repo"] else { throw Failure.missing }
        let executable = URL(fileURLWithPath: node)
        let script = URL(fileURLWithPath: repository).appendingPathComponent("services/dsh-runtime/sidecar.mjs")
        guard regular(executable), FileManager.default.isExecutableFile(atPath: executable.path), regular(script) else { throw Failure.missing }
        return (executable, script)
    }

    static func source(root: URL, searchPath: String) throws -> (executable: URL, script: URL) {
        let application = root.appendingPathComponent("services/dsh-runtime")
        let script = application.appendingPathComponent("sidecar.mjs")
        let dependency = application.appendingPathComponent("node_modules/@deepseek-ai/dsh-session/package.json")
        guard regular(script), regular(dependency) else { throw Failure.missing }
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            guard directory.hasPrefix("/") else { continue }
            let executable = URL(fileURLWithPath: String(directory)).appendingPathComponent("node").resolvingSymlinksInPath()
            if regular(executable), FileManager.default.isExecutableFile(atPath: executable.path) { return (executable, script) }
        }
        throw Failure.missing
    }

    private static func regular(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
