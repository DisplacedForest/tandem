import Foundation
import CryptoKit

struct EngineLayout {
    let root: URL
    let launchAgent: URL
    let label: String

    init(root: URL, home: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        let normal = home.appendingPathComponent(".vera").standardizedFileURL.resolvingSymlinksInPath()
        if self.root == normal {
            label = "com.vera.engine"
            launchAgent = home.appendingPathComponent("Library/LaunchAgents/com.vera.engine.plist")
        } else {
            let suffix = SHA256.hash(data: Data(self.root.path.utf8)).prefix(12)
                .map { String(format: "%02x", $0) }.joined()
            label = "com.vera.engine.\(suffix)"
            launchAgent = self.root.appendingPathComponent("LaunchAgents/\(label).plist")
        }
    }

    var engineRoot: URL { root.appendingPathComponent("engine") }
    var dataDir: URL { root.appendingPathComponent("data") }
    var logFile: URL { engineRoot.appendingPathComponent("engine.log") }
    func versionDir(_ version: String) -> URL { engineRoot.appendingPathComponent(version) }
    func binary(_ version: String) -> URL { versionDir(version).appendingPathComponent("vera-api/vera-api") }

    func plist(binary: URL, port: Int) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "Label": label,
            "ProgramArguments": [binary.path],
            "EnvironmentVariables": ["VERA_DATA_DIR": dataDir.path, "VERA_BIND": "127.0.0.1", "VERA_PORT": String(port)],
            "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Background",
            "StandardOutPath": logFile.path, "StandardErrorPath": logFile.path,
        ], format: .xml, options: 0)
    }
}

struct EngineCommandResult {
    let status: Int32
    let output: String
}

enum EngineProbe: Equatable {
    case free, engine(String), conflict
}

struct EngineLifecycleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
struct EngineOperations {
    var command: (String, [String]) throws -> EngineCommandResult
    var request: (URLRequest) async throws -> (Data, HTTPURLResponse)
    var download: (URL) async throws -> URL
    var pause: () async throws -> Void
    var attempts = 10

    static var live: EngineOperations {
        EngineOperations(command: run, request: { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw EngineLifecycleError(message: "The engine server returned an invalid response.")
            }
            return (data, response)
        }, download: { url in
            let (file, response) = try await URLSession.shared.download(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw EngineLifecycleError(message: "The engine download failed.")
            }
            return file
        }, pause: { try await Task.sleep(for: .seconds(1)) })
    }

    static func run(_ path: String, _ arguments: [String]) throws -> EngineCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw EngineLifecycleError(message: "The engine command took too long.")
        }
        process.waitUntilExit()
        return EngineCommandResult(status: process.terminationStatus,
                                   output: String(decoding: try Data(contentsOf: file), as: UTF8.self))
    }
}

@MainActor
final class EngineLifecycle {
    let layout: EngineLayout
    let operations: EngineOperations
    private let fm = FileManager.default
    private struct Activation: Codable {
        let previous: Data?
        let candidate: String
    }
    private var receipt: URL { layout.engineRoot.appendingPathComponent("activation.json") }
    private var generation = 0
    private(set) var running = false
    private(set) var installedVersion: String?
    private(set) var starting = false

    init(layout: EngineLayout, operations: EngineOperations = .live) {
        self.layout = layout
        self.operations = operations
    }

    func stop() throws {
        generation += 1
        try validateStorage()
        try removeIfPresent(layout.launchAgent)
        try bootout()
        try removeIfPresent(receipt)
        running = false
    }

    func removeFiles() throws {
        try stop()
        try removeIfPresent(layout.engineRoot)
        installedVersion = nil
    }

    func deleteData() throws {
        try validateStorage()
        guard !starting, !running else {
            throw EngineLifecycleError(message: "Stop the engine before deleting its data.")
        }
        let result = try operations.command("/bin/launchctl", ["print", "gui/\(getuid())/\(layout.label)"])
        guard [3, 113].contains(result.status) else {
            throw EngineLifecycleError(message: "Stop the engine before deleting its data.")
        }
        try removeIfPresent(layout.dataDir)
    }

    func installed() -> String? {
        guard let bytes = try? Data(contentsOf: layout.launchAgent) else { return nil }
        return try? previousAgent(bytes).version
    }

    func refresh(port: Int) async {
        let operation = generation
        let installed = installed()
        let result = await probe(port: port)
        guard operation == generation else { return }
        installedVersion = installed
        running = false
        if case .engine(let version) = result, version == installed { running = true }
    }

    func start(version: String, port: Int, archive: () async throws -> URL,
               progress: (String) -> Void = { _ in }) async throws {
        guard !starting else { throw EngineLifecycleError(message: "The engine is already starting.") }
        guard Self.validVersion(version), (1...65535).contains(port) else {
            throw EngineLifecycleError(message: "The engine version or port is invalid.")
        }
        starting = true
        defer { starting = false }
        try validateStorage()
        try await recoverPending()
        generation += 1
        let operation = generation
        let priorBytes = fm.fileExists(atPath: layout.launchAgent.path) ? try Data(contentsOf: layout.launchAgent) : nil
        let prior = try priorBytes.map { try previousAgent($0) }
        let initial = await probe(port: port)
        try requireCurrent(operation)
        switch initial {
        case .conflict:
            throw EngineLifecycleError(message: "Port \(port) is in use by another program. Change the port and try again.")
        case .engine(let current):
            guard prior?.version == current, prior?.port == port else {
                throw EngineLifecycleError(message: "Another engine is using port \(port). Stop it before starting this engine.")
            }
            running = true
            installedVersion = current
            if current == version { return }
        case .free:
            running = false
        }

        try fm.createDirectory(at: layout.engineRoot, withIntermediateDirectories: true)
        let staging = layout.engineRoot.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        if !fm.fileExists(atPath: layout.versionDir(version).path) {
            let zip = try await archive()
            try requireCurrent(operation)
            progress("unpacking")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try command("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
            try validateBinary(staging.appendingPathComponent("vera-api/vera-api"), within: staging)
            try fm.moveItem(at: staging, to: layout.versionDir(version))
        }
        try validateBinary(layout.binary(version), within: layout.versionDir(version))
        try requireCurrent(operation)
        var switched = false
        do {
            progress("launching")
            try fm.createDirectory(at: layout.dataDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: layout.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Activation(previous: priorBytes, candidate: version)).write(to: receipt, options: .atomic)
            switched = true
            try removeIfPresent(layout.launchAgent)
            try bootout()
            try layout.plist(binary: layout.binary(version), port: port).write(to: layout.launchAgent, options: .atomic)
            try bootstrap()
            guard try await healthy(version: version, port: port, operation: operation) else {
                throw EngineLifecycleError(message: "The updated engine did not become healthy. See the engine log.")
            }
            installedVersion = version
            running = true
            try removeIfPresent(receipt)
            prune(keeping: Set([version, prior?.version].compactMap { $0 }))
        } catch {
            guard operation == generation else { throw CancellationError() }
            if switched {
                do {
                    try await restore(previous: priorBytes, operation: operation)
                    try removeIfPresent(receipt)
                } catch {
                    throw EngineLifecycleError(message: "The engine update failed and recovery needs attention: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    func recoverPending() async throws {
        try validateStorage()
        guard fm.fileExists(atPath: receipt.path) else { return }
        let activation = try JSONDecoder().decode(Activation.self, from: Data(contentsOf: receipt))
        guard Self.validVersion(activation.candidate) else {
            throw EngineLifecycleError(message: "The saved engine recovery record is invalid.")
        }
        if let previous = activation.previous { _ = try previousAgent(previous) }
        generation += 1
        let operation = generation
        try await restore(previous: activation.previous, operation: operation)
        try requireCurrent(operation)
        try removeIfPresent(receipt)
    }

    private func restore(previous bytes: Data?, operation: Int) async throws {
        let prior = try bytes.map { try previousAgent($0) }
        try removeIfPresent(layout.launchAgent)
        var stopError: Error?
        do { try bootout() } catch { stopError = error }
        if let bytes { try bytes.write(to: layout.launchAgent, options: .atomic) }
        if let stopError { throw stopError }
        running = false
        installedVersion = prior?.version
        if let prior {
            try bootstrap()
            running = try await healthy(version: prior.version, port: prior.port, operation: operation)
            guard running else { throw EngineLifecycleError(message: "The previous engine did not become healthy.") }
        }
    }

    func statusDetail() -> String? {
        guard let result = try? operations.command("/bin/launchctl", ["print", "gui/\(getuid())/\(layout.label)"]),
              result.status == 0 else { return nil }
        func field(_ key: String) -> String? {
            result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix(key) }?.split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let lastExit = field("last exit code ="), lastExit != "0", lastExit != "(never exited)" {
            let count = field("runs =").map { " after \($0) runs" } ?? ""
            return "Engine last exited with code \(lastExit)\(count). See the log."
        }
        return nil
    }

    private func validateStorage() throws {
        for path in [layout.engineRoot, layout.dataDir, layout.launchAgent, receipt] {
            guard path.standardizedFileURL == path.resolvingSymlinksInPath().standardizedFileURL else {
                throw EngineLifecycleError(message: "The engine storage contains a link outside its configured folder.")
            }
        }
    }

    func probe(port: Int) async -> EngineProbe {
        guard let url = URL(string: "http://127.0.0.1:\(port)/version") else { return .conflict }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await operations.request(request)
            if response.statusCode == 200,
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["version"] as? String, Self.validVersion(version) { return .engine(version) }
            return .conflict
        } catch {
            let error = error as NSError
            return error.domain == NSURLErrorDomain && error.code == NSURLErrorCannotConnectToHost ? .free : .conflict
        }
    }

    private func healthy(version: String, port: Int, operation: Int) async throws -> Bool {
        for _ in 0..<max(1, operations.attempts) {
            try requireCurrent(operation)
            let result = await probe(port: port)
            try requireCurrent(operation)
            if result == .engine(version) { return true }
            try await operations.pause()
        }
        return false
    }

    private func requireCurrent(_ operation: Int) throws {
        guard operation == generation else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func previousAgent(_ bytes: Data) throws -> (version: String, port: Int) {
        guard let object = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              object["Label"] as? String == layout.label,
              let arguments = object["ProgramArguments"] as? [String], arguments.count == 1,
              let path = arguments.first,
              let environment = object["EnvironmentVariables"] as? [String: String],
              environment["VERA_DATA_DIR"] == layout.dataDir.path,
              environment["VERA_BIND"] == "127.0.0.1",
              let portText = environment["VERA_PORT"], let port = Int(portText), (1...65535).contains(port) else {
            throw EngineLifecycleError(message: "The existing engine launch settings could not be verified.")
        }
        let binary = URL(fileURLWithPath: path)
        let version = binary.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        guard Self.validVersion(version), binary == layout.binary(version) else {
            throw EngineLifecycleError(message: "The existing engine path is outside its managed folder.")
        }
        try validateBinary(binary, within: layout.versionDir(version))
        return (version, port)
    }

    private func validateBinary(_ binary: URL, within directory: URL) throws {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let resolved = binary.standardizedFileURL.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
        guard root.hasPrefix(layout.engineRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"),
              resolved.path.hasPrefix(root), values.isRegularFile == true, fm.isExecutableFile(atPath: resolved.path) else {
            throw EngineLifecycleError(message: "The engine binary is missing or outside its managed folder.")
        }
    }

    private func bootout() throws {
        let result = try operations.command("/bin/launchctl", ["bootout", "gui/\(getuid())/\(layout.label)"])
        guard [0, 3, 113].contains(result.status) else {
            throw EngineLifecycleError(message: "The local engine could not be stopped (\(result.status)).")
        }
    }

    private func bootstrap() throws {
        try command("/bin/launchctl", ["bootstrap", "gui/\(getuid())", layout.launchAgent.path])
    }

    private func command(_ path: String, _ arguments: [String]) throws {
        let result = try operations.command(path, arguments)
        guard result.status == 0 else {
            throw EngineLifecycleError(message: "\(URL(fileURLWithPath: path).lastPathComponent) exited \(result.status).")
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    private func prune(keeping versions: Set<String>) {
        guard let entries = try? fm.contentsOfDirectory(atPath: layout.engineRoot.path) else { return }
        for version in entries where Self.validVersion(version) && !versions.contains(version) {
            try? fm.removeItem(at: layout.versionDir(version))
        }
    }

    static func validVersion(_ version: String) -> Bool {
        version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil
    }
}
