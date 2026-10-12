import Foundation

@MainActor
enum NativeApplicationEntry {
    enum Failure: Error { case timeout }
    static func runAsync(_ operation: @escaping @MainActor () async -> Void) -> Never {
        Task {
            await operation()
            exit(0)
        }
        while true { RunLoop.main.run(until: .distantFuture) }
    }

    static func prepare(timeout: TimeInterval = 30, cleanupTimeout: TimeInterval = 5, onTimeout: @MainActor () -> Void = {}, _ operation: @escaping @MainActor () async throws -> Void) throws {
        var result: Result<Void, Error>?
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let task = Task {
            do { try await operation(); result = .success(()) }
            catch { result = .failure(error) }
        }
        while result == nil {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                task.cancel()
                onTimeout()
                let cleanupDeadline = ProcessInfo.processInfo.systemUptime + cleanupTimeout
                while result == nil && ProcessInfo.processInfo.systemUptime < cleanupDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                throw Failure.timeout
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try result!.get()
    }
}
