import Darwin
import Foundation

enum NativeCommandLimits {
    static let defaultTimeout = Duration.seconds(60)
    static let maximumTimeout = Duration.seconds(240)
    static let outputCap = 65_536
    static let maximumCommandLength = 4096
    static let drainGraceMilliseconds = 2000
}

struct NativeCommandOutcome: Equatable, Sendable {
    var exitCode: Int32?
    var signal: Int32?
    var timedOut: Bool
    var canceled: Bool
    var stdout: String
    var stderr: String
    var stdoutTruncated: Bool
    var stderrTruncated: Bool
    var durationMilliseconds: Int
}

enum NativeCommandRunner {
    static let shell = "/bin/sh"
    static let searchPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    static let inheritedVariables = ["HOME", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "USER", "LOGNAME"]

    static func environment(from source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var scrubbed: [String: String] = [:]
        for name in inheritedVariables {
            if let value = source[name], !value.isEmpty, !value.contains("\0") { scrubbed[name] = value }
        }
        scrubbed["PATH"] = searchPath
        if scrubbed["LANG"] == nil { scrubbed["LANG"] = "en_US.UTF-8" }
        if scrubbed["TERM"] == nil { scrubbed["TERM"] = "dumb" }
        return scrubbed
    }

    private final class Reader: @unchecked Sendable {
        let descriptor: Int32
        let cap: Int
        private let lock = NSLock()
        private var buffer = Data()
        private var total = 0
        private var stopRequested = false
        private let finished = DispatchSemaphore(value: 0)

        init(descriptor: Int32, cap: Int) {
            self.descriptor = descriptor
            self.cap = cap
        }

        func start() {
            Thread.detachNewThread { [self] in
                var chunk = [UInt8](repeating: 0, count: 16_384)
                var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                loop: while true {
                    lock.lock()
                    let stop = stopRequested
                    lock.unlock()
                    if stop { break }
                    poller.revents = 0
                    let ready = poll(&poller, 1, 250)
                    if ready == 0 { continue }
                    if ready < 0 {
                        if Darwin.errno == EINTR { continue }
                        break
                    }
                    let count = read(descriptor, &chunk, chunk.count)
                    if count > 0 {
                        lock.lock()
                        total += count
                        let room = cap - buffer.count
                        if room > 0 { buffer.append(contentsOf: chunk[0..<min(count, room)]) }
                        lock.unlock()
                        continue
                    }
                    if count < 0 && Darwin.errno == EINTR { continue }
                    break loop
                }
                close(descriptor)
                finished.signal()
            }
        }

        func stop() {
            lock.lock()
            stopRequested = true
            lock.unlock()
        }

        func wait(_ timeout: DispatchTime) -> Bool {
            finished.wait(timeout: timeout) == .success
        }

        func collect() -> (String, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (String(decoding: buffer, as: UTF8.self), total > buffer.count)
        }
    }

    private final class Child: @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var reaped = false
        private(set) var killedForTimeout = false
        private(set) var killedForCancel = false

        init(pid: pid_t) { self.pid = pid }

        func kill(timeout: Bool) {
            lock.lock(); defer { lock.unlock() }
            if !reaped {
                if timeout { killedForTimeout = true } else { killedForCancel = true }
            }
            Darwin.kill(-pid, SIGKILL)
        }

        func markReaped() {
            lock.lock(); defer { lock.unlock() }
            reaped = true
            Darwin.kill(-pid, SIGKILL)
        }
    }

    static func run(command: String, directory: NativeFolderDescriptor, timeout: Duration,
                    outputCap: Int = NativeCommandLimits.outputCap,
                    environment: [String: String] = environment()) async throws -> NativeCommandOutcome {
        guard !command.isEmpty, command.utf8.count <= NativeCommandLimits.maximumCommandLength, !command.contains("\0") else {
            throw NativeToolError.invalidArguments("The command must be between 1 and \(NativeCommandLimits.maximumCommandLength) bytes")
        }
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw NativeFolderIO.errno("Couldn't create the output pipe") }
        guard pipe(&err) == 0 else {
            close(out[0]); close(out[1])
            throw NativeFolderIO.errno("Couldn't create the error pipe")
        }
        for fd in [out[0], out[1], err[0], err[1]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        posix_spawn_file_actions_addfchdir_np(&actions, directory.raw)

        var attributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var empty = sigset_t()
        sigemptyset(&empty)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-c"), strdup(command), nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let started = Date()
        let spawn = posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
        close(out[1])
        close(err[1])
        guard spawn == 0 else {
            close(out[0]); close(err[0])
            throw NativeToolError.failed("Couldn't start the command: \(String(cString: strerror(spawn)))")
        }
        let child = Child(pid: pid)
        let stdoutReader = Reader(descriptor: out[0], cap: outputCap)
        let stderrReader = Reader(descriptor: err[0], cap: outputCap)
        stdoutReader.start()
        stderrReader.start()

        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            child.kill(timeout: true)
        }
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                Thread.detachNewThread {
                    var raw: Int32 = 0
                    while waitpid(pid, &raw, 0) < 0 {
                        if Darwin.errno != EINTR { raw = -1; break }
                    }
                    child.markReaped()
                    continuation.resume(returning: raw)
                }
            }
        } onCancel: {
            child.kill(timeout: false)
        }
        timer.cancel()
        let deadline = DispatchTime.now() + .milliseconds(NativeCommandLimits.drainGraceMilliseconds)
        if !stdoutReader.wait(deadline) { stdoutReader.stop() }
        if !stderrReader.wait(deadline) { stderrReader.stop() }
        _ = stdoutReader.wait(.now() + .milliseconds(600))
        _ = stderrReader.wait(.now() + .milliseconds(600))
        let (stdout, stdoutTruncated) = stdoutReader.collect()
        let (stderr, stderrTruncated) = stderrReader.collect()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        var exitCode: Int32?
        var signal: Int32?
        if status >= 0 {
            if (status & 0x7f) == 0 {
                exitCode = (status >> 8) & 0xff
            } else {
                signal = status & 0x7f
            }
        }
        return NativeCommandOutcome(
            exitCode: exitCode, signal: signal,
            timedOut: child.killedForTimeout, canceled: child.killedForCancel && !child.killedForTimeout,
            stdout: stdout, stderr: stderr,
            stdoutTruncated: stdoutTruncated, stderrTruncated: stderrTruncated,
            durationMilliseconds: elapsed)
    }
}
