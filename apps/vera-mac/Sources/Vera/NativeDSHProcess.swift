import Foundation

struct NativeDSHFailure: Error, Sendable {
    let code: String
}

final class NativeDSHProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var stopped = false
    static let maximumFrameBytes = 16 * 1024 * 1024

    func run(_ request: Data, executable: URL, script: URL,
             model: @escaping @Sendable (Data) async throws -> Data) async throws -> Data {
        process.executableURL = executable
        process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.environment = ["PATH": executable.deletingLastPathComponent().path, "LANG": "en_US.UTF-8", "DSH_TELEMETRY_DISABLED": "1"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            if lock.withLock({ stopped }) { stop(); throw CancellationError() }
            defer { stop() }
            try write(request)
            var buffer = Data()
            for try await byte in output.fileHandleForReading.bytes {
                try Task.checkCancellation()
                if byte != 10 {
                    buffer.append(byte)
                    guard buffer.count <= Self.maximumFrameBytes else { throw NativeDSHFailure(code: "frame_limit") }
                    continue
                }
                let frame = buffer
                buffer.removeAll(keepingCapacity: true)
                guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
                      let kind = object["type"] as? String else { throw NativeDSHFailure(code: "protocol") }
                switch kind {
                case "model":
                    try write(try await model(frame))
                case "boundary", "final":
                    return frame
                case "error":
                    throw NativeDSHFailure(code: object["code"] as? String ?? "runtime")
                default:
                    throw NativeDSHFailure(code: "protocol")
                }
            }
            try Task.checkCancellation()
            throw NativeDSHFailure(code: "exited")
        } onCancel: {
            self.stop()
        }
    }

    private func write(_ data: Data) throws {
        guard data.count <= Self.maximumFrameBytes, !lock.withLock({ stopped }) else { throw CancellationError() }
        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
    }

    func stop() {
        lock.withLock { stopped = true }
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
