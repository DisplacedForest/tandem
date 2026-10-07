import Foundation
import Darwin

final class PiPrivatePipe: @unchecked Sendable {
    let readHandle: FileHandle
    let writeHandle: FileHandle
    private var buffer = Data()
    private let lock = NSLock()
    init(read: FileHandle, write: FileHandle) { readHandle = read; writeHandle = write }
    func next(while alive: () -> Bool = { true }) throws -> PiValue? {
        while alive() {
            if let index = buffer.firstIndex(of: 10) {
                let data = buffer.prefix(upTo: index)
                buffer.removeSubrange(...index)
                return try PiValue.piRead(Data(data))
            }
            try piCheck(buffer.count <= 65536)
            var descriptor = pollfd(fd: readHandle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let available = poll(&descriptor, 1, 100)
            if available == 0 { continue }
            try piCheck(available > 0 || errno == EINTR, .unavailable)
            if available < 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(readHandle.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            try piCheck(count >= 0, .unavailable)
            if count == 0 { try piCheck(buffer.isEmpty); return nil }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        return nil
    }
    func send(_ value: PiValue) throws {
        var data = try value.piData(); try piCheck(data.count <= 65536); data.append(10)
        lock.lock(); defer { lock.unlock() }
        let fd = writeHandle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        try piCheck(flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0, .unavailable)
        let until = ContinuousClock.now + .milliseconds(500)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                try piCheck(ContinuousClock.now < until && count < 0 && [EINTR, EAGAIN].contains(errno), .unavailable)
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, 10)
            }
        }
    }
    func closeWrite() { lock.lock(); defer { lock.unlock() }; try? writeHandle.close() }
}

final class NativePiRuntimeSession: @unchecked Sendable {
    let process: Process
    let child: PiPrivatePipe
    let controller: PiPrivatePipe
    let broker: NativePiModelBroker
    let ledger: PiModelLedger
    let channel: String
    let capability: String
    private let lock = NSLock()
    private var ended = false
    private var ownedGroup: Int32?
    private var grants: [String: (String, PiModelScope)] = [:]
    init(arguments: [String], controller injectedController: PiPrivatePipe? = nil, executor: any PiMockModelExecutor = PiFixtureModel(), ownerBinding: String = "fixture", requestTimeout: Double = 3) throws {
        signal(SIGPIPE, SIG_IGN)
        umask(0o077)
        var info = stat()
        try piCheck(fstat(injectedController?.readHandle.fileDescriptor ?? STDIN_FILENO, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO && fstat(injectedController?.writeHandle.fileDescriptor ?? STDOUT_FILENO, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO, .unauthorized)
        try piCheck(arguments.count == 10)
        var options: [String: String] = [:]
        for offset in stride(from: 0, to: arguments.count, by: 2) {
            try piCheck(options[arguments[offset]] == nil)
            options[arguments[offset]] = arguments[offset + 1]
        }
        try piCheck(Set(options.keys) == ["--root", "--repo", "--python", "--node", "--port"])
        guard let port = Int(options["--port"]!), (0...65535).contains(port) else { throw PiBrokerError.invalid }
        let repo = URL(fileURLWithPath: options["--repo"]!).standardizedFileURL.resolvingSymlinksInPath()
        let python = URL(fileURLWithPath: options["--python"]!).resolvingSymlinksInPath()
        let node = URL(fileURLWithPath: options["--node"]!).resolvingSymlinksInPath()
        try piCheck(FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.isExecutableFile(atPath: node.path))
        let files = ["app_bridge.py", "app_model.py", "runtime.py", "bridge.py", "process.py", "agent.mjs", "package-lock.json", "native.py"]
        let source = repo.appendingPathComponent("prototypes/pi_assistant")
        var digest = Data()
        for name in files { digest.append(Data(name.utf8)); digest.append(try Data(contentsOf: source.appendingPathComponent(name))) }
        digest.append(try Data(contentsOf: python)); digest.append(try Data(contentsOf: node))
        ledger = try PiModelLedger(root: URL(fileURLWithPath: options["--root"]!), manifest: piHash(digest), ownerBinding: ownerBinding)
        channel = UUID().uuidString.lowercased()
        capability = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
        broker = NativePiModelBroker(ledger: ledger, channel: channel, executor: executor, timeout: .seconds(requestTimeout))
        controller = injectedController ?? PiPrivatePipe(read: .standardInput, write: .standardOutput)
        let input = Pipe(), output = Pipe()
        process = Process()
        process.executableURL = python
        process.arguments = [source.appendingPathComponent("app_bridge.py").path, "--app-owned-mock"]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        child = PiPrivatePipe(read: output.fileHandleForReading, write: input.fileHandleForWriting)
        try process.run()
        rememberGroup()
        do { try child.send(.object(["op": .string("initialize"), "transport": .string("app-owned-mock"), "channel": .string(channel), "profile": .string(ledger.profile), "ui_capability": .string(capability), "root": .string(ledger.owner.url.appendingPathComponent("runtime").path), "node": .string(node.path), "port": .number(Double(port)), "request_timeout": .number(requestTimeout + 2)])) }
        catch { child.closeWrite(); Self.killGroup(process); throw error }
    }
    static func killGroup(_ process: Process) {
        let pid = process.processIdentifier
        if pid > 1 {
            if getpgid(pid) == pid { _ = kill(-pid, SIGKILL) }
            if process.isRunning { _ = kill(pid, SIGKILL) }
        }
    }
    func rememberGroup() {
        let pid = process.processIdentifier
        if pid > 1 && getpgid(pid) == pid { lock.lock(); ownedGroup = pid; lock.unlock() }
    }
    func killOwnedGroup() {
        lock.lock(); let group = ownedGroup; lock.unlock()
        if let group { _ = kill(-group, SIGKILL) }
        Self.killGroup(process)
    }
    func isOpen() -> Bool { lock.lock(); defer { lock.unlock() }; return !ended && process.isRunning }
    func markEnded() { lock.lock(); defer { lock.unlock() }; ended = true }
    func register(_ scope: PiModelScope, id: String) { lock.lock(); defer { lock.unlock() }; grants[scope.id] = (id, scope) }
    func acknowledge(_ id: String) throws {
        lock.lock(); let grant = grants.removeValue(forKey: id); lock.unlock()
        guard let grant else { throw PiBrokerError.unauthorized }
        try controller.send(.object(["op": .string("authorized"), "id": .string(grant.0), "binding": grant.1.wire]))
    }
    func receiveChild() async {
        var ready = false
        var received = 0
        let startupDeadline = Date().addingTimeInterval(10)
        do {
            while let value = try child.next(while: { self.process.isRunning && (ready || Date() < startupDeadline) }) {
                if value.pi("op").piString == "ready" {
                    try piCheck(!ready)
                    guard case .number(let port) = value.pi("port"), port.rounded() == port, (1...65535).contains(port) else { throw PiBrokerError.invalid }
                    rememberGroup()
                    ready = true
                    try value.piKeys(["op", "channel", "port"])
                    try piCheck(value.pi("channel").piString == channel, .unauthorized)
                    try controller.send(.object(["op": .string("ready"), "transport": .string("app-owned-mock"), "channel": .string(channel), "profile": .string(ledger.profile), "ui_capability": .string(capability), "port": value.pi("port"), "pid": .number(Double(process.processIdentifier))]))
                    continue
                }
                if value.pi("op").piString == "scoped" {
                    try value.piKeys(["op", "channel", "scope"])
                    try piCheck(ready && value.pi("channel").piString == channel, .unauthorized)
                    try acknowledge(piUUID(value.pi("scope")))
                    continue
                }
                let id = try piUUID(value.pi("id"))
                if value.pi("op").piString == "cancel" {
                    try value.piKeys(["op", "id", "channel"])
                    try piCheck(value.pi("channel").piString == channel, .unauthorized)
                    await broker.cancel(id)
                    continue
                }
                received += 1
                try piCheck(ready && value.pi("op").piString == "complete" && received <= 32, .unauthorized)
                Task {
                    do {
                        let reply = try await broker.complete(value)
                        try child.send(.object(["op": .string("reply"), "id": .string(id), "ok": .bool(true), "result": reply]))
                    } catch {
                        try? child.send(.object(["op": .string("reply"), "id": .string(id), "ok": .bool(false), "error": .string((error as? PiBrokerError)?.rawValue ?? "unavailable")]))
                    }
                }
            }
        } catch {}
        await broker.close()
        markEnded()
        child.closeWrite()
        try? controller.send(.object(["op": .string("disconnected")]))
    }
    func run() async {
        let reader = Task.detached { await self.receiveChild() }
        do {
            while let value = try controller.next(while: { self.isOpen() }) {
                let id = try piUUID(value.pi("id"))
                do {
                    switch value.pi("op").piString {
                    case "authorize":
                        try value.piKeys(["op", "id", "binding"])
                        let scope = try await broker.authorize(value.pi("binding"))
                        register(scope, id: id)
                        try child.send(.object(["op": .string("scope"), "channel": .string(channel), "binding": scope.wire]))
                    case "snapshot":
                        try value.piKeys(["op", "id"])
                        try controller.send(.object(["op": .string("snapshot"), "id": .string(id), "requests": try ledger.snapshot()]))
                    case "stop":
                        try value.piKeys(["op", "id"])
                        throw CancellationError()
                    default: throw PiBrokerError.unauthorized
                    }
                } catch is CancellationError { break }
                catch { try controller.send(.object(["op": .string("refused"), "id": .string(id), "error": .string((error as? PiBrokerError)?.rawValue ?? "unavailable")])) }
            }
        } catch {}
        await broker.close()
        markEnded()
        child.closeWrite()
        for _ in 0..<60 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
        for _ in 0..<20 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        killOwnedGroup()
        if process.isRunning { process.waitUntilExit() }
        _ = await reader.value
        controller.closeWrite()
    }
    static func main(_ arguments: [String]) async {
        do { try await NativePiRuntimeSession(arguments: arguments).run() }
        catch { FileHandle.standardError.write(Data("App-owned mock session unavailable\n".utf8)); exit(1) }
    }
}
