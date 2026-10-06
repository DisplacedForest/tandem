import Foundation
import Darwin

enum Stage: String, Sendable {
    case accepted, metadataBegin, metadataValidated, keychainBegin, keychainReturned, credentialReturned
    case modelsBegin, modelsReturned, usageBegin, usageReturned, inferenceReserved, inferenceBegin, inferenceReturned, settled
}

final class HardDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var generation = 0
    private var deadline = DispatchTime.distantFuture
    private let queue = DispatchQueue(label: "vera.native.deadline", qos: .userInitiated)
    init(after: DispatchTimeInterval, code: Int32 = 124) { arm(after: after, code: code) }
    func arm(after: DispatchTimeInterval, code: Int32) {
        lock.lock()
        let target = DispatchTime.now() + after
        guard !finished && target < deadline else { lock.unlock(); return }
        deadline = target
        generation += 1
        let expected = generation
        lock.unlock()
        queue.asyncAfter(deadline: target) { [self] in
            lock.lock()
            guard !finished && generation == expected else { lock.unlock(); return }
            finished = true
            lock.unlock()
            var info = stat()
            let flags = fcntl(STDERR_FILENO, F_GETFL)
            if fstat(STDERR_FILENO, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO && flags >= 0 && fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 {
                let marker = code == 126 ? "native_credential_watchdog\n" : (code == 125 ? "native_cancel_watchdog\n" : "native_deadline_watchdog\n")
                marker.withCString { pointer in _ = Darwin.write(STDERR_FILENO, pointer, strlen(pointer)) }
            }
            _exit(code)
        }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
    }
}
