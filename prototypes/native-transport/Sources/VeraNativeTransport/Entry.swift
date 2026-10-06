import Foundation
import CryptoKit
import Darwin

actor Output {
    func send(_ value: J) {
        guard var data = try? value.data() else { return }
        data.append(10)
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else { exit(1) }
        let deadline = ContinuousClock.now + .milliseconds(500)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR && ContinuousClock.now < deadline { continue }
                guard count < 0 && errno == EAGAIN && ContinuousClock.now < deadline else { exit(1) }
                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, 20)
            }
        }
    }
}

actor Requests {
    let broker: Broker
    let directory: URL
    let output: Output
    var running: [String: Task<Void, Never>] = [:]
    var seen = Set<String>()
    init(broker: Broker, directory: URL, output: Output) { self.broker = broker; self.directory = directory; self.output = output }
    func accept(_ data: Data) async {
        var id: String?
        do {
            let value = try J.parse(data)
            let parsedID = try identifier(value["request_id"])
            id = parsedID
            if value["op"].string == "cancel" {
                try value.keys(["op", "request_id"], required: ["op", "request_id"])
                guard let task = running[parsedID] else { throw Failure.invalidRequest }
                task.cancel()
                return
            }
            try require(seen.count < 12, .budget)
            try require(!seen.contains(parsedID), .duplicate)
            let authorization = try J.parse(PrivateFiles.read(directory.appendingPathComponent(parsedID + ".json")))
            seen.insert(parsedID)
            running[parsedID] = Task {
                do { await output.send(try await broker.complete(value, requestPermit: authorization)) }
                catch { await output.send(Self.failure(parsedID, error)) }
                self.finished(parsedID)
            }
        } catch { await output.send(Self.failure(id, error)) }
    }
    func finished(_ id: String) { running.removeValue(forKey: id) }
    func close() async {
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
    static func failure(_ id: String?, _ error: any Error) -> J {
        .object(["request_id": id.map(J.string) ?? .null, "ok": .bool(false), "error": .string((error as? Failure)?.rawValue ?? (error is CancellationError ? "canceled" : "unavailable"))])
    }
}

@main struct Entry {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--selftest"] { try await Selftest.run(); return }
            if args.first == "--lock-test", args.count == 2 {
                let ledger = try Ledger(root: URL(fileURLWithPath: args[1]))
                _ = try ledger.snapshot()
                return
            }
            try require(args.count == 9 && ["--live", "--mock-stdio"].contains(args[0]), .unauthorized)
            var options: [String: String] = [:]
            for index in stride(from: 1, to: args.count, by: 2) {
                try require(options[args[index]] == nil, .unauthorized)
                options[args[index]] = args[index + 1]
            }
            try require(Set(options.keys) == ["--permit", "--request-permits", "--ledger-root", "--approved-sha256"], .unauthorized)
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            let hash = SHA256.hash(data: try Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined()
            try require(options["--approved-sha256"] == hash, .unauthorized)
            let permit = try Permit(J.parse(PrivateFiles.read(URL(fileURLWithPath: options["--permit"]!))))
            let ledger = try Ledger(root: URL(fileURLWithPath: options["--ledger-root"]!))
            let credentials: any CredentialSource
            let http: any HTTPTransport
            if args[0] == "--mock-stdio" { credentials = FixtureCredential(); http = FixtureHTTP(delay: .seconds(10)) }
            else {
                credentials = SelectedCredential(profileURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vera/config.json"))
                http = URLTransport()
            }
            let broker = try Broker(permit: permit, ledger: ledger, credentials: credentials, http: http)
            let requests = Requests(broker: broker, directory: URL(fileURLWithPath: options["--request-permits"]!), output: Output())
            await Task.detached {
                var buffer = Data()
                while true {
                    let chunk = FileHandle.standardInput.availableData
                    if chunk.isEmpty { break }
                    for byte in chunk {
                        if byte == 10 { await requests.accept(buffer); buffer.removeAll(keepingCapacity: true) }
                        else {
                            if buffer.count >= 65536 { await requests.close(); return }
                            buffer.append(byte)
                        }
                    }
                }
                await requests.close()
            }.value
        } catch {
            let value = Requests.failure(nil, error)
            if var data = try? value.data() { data.append(10); try? FileHandle.standardOutput.write(contentsOf: data) }
            exit(1)
        }
    }
}
