import Foundation

let mode = CommandLine.arguments[1]
if mode == "async" {
    NativeApplicationEntry.runAsync {
        await Task.yield()
        print("PASS: async CLI completion")
    }
}
if mode == "deadline" {
    let start = ProcessInfo.processInfo.systemUptime
    var cleaned = false
    do {
        try NativeApplicationEntry.prepare(timeout: 0.05) {
            do { try await Task.sleep(for: .seconds(20)) }
            catch { await Task.yield(); cleaned = true; throw error }
        }
        exit(1)
    } catch NativeApplicationEntry.Failure.timeout {
        precondition(ProcessInfo.processInfo.systemUptime - start < 1 && cleaned)
        print("PASS: bounded bootstrap deadline")
    } catch { exit(1) }
    exit(0)
}
if mode == "forced-cleanup" {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["20"]
    try process.run()
    var suspended: CheckedContinuation<Void, Never>?
    let start = ProcessInfo.processInfo.systemUptime
    do {
        try NativeApplicationEntry.prepare(timeout: 0.03, cleanupTimeout: 0.05, onTimeout: {
            process.terminate()
        }) {
            await withCheckedContinuation { suspended = $0 }
        }
        exit(1)
    } catch NativeApplicationEntry.Failure.timeout {
        precondition(ProcessInfo.processInfo.systemUptime - start < 1)
        suspended?.resume()
        process.waitUntilExit()
        precondition(!process.isRunning)
        print("PASS: uncooperative bootstrap invokes owned child cleanup")
    } catch { exit(1) }
    exit(0)
}
var prepared = false
try NativeApplicationEntry.prepare {
    try await Task.sleep(for: .milliseconds(5))
    prepared = true
}
precondition(prepared)
var actorRan = false
var dispatchRan = false
Task { actorRan = true }
DispatchQueue.main.async { dispatchRan = true }
let deadline = Date().addingTimeInterval(1)
while !(actorRan && dispatchRan) && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
precondition(actorRan && dispatchRan)
print("PASS: synchronous bootstrap leaves MainActor and main queue runnable")
