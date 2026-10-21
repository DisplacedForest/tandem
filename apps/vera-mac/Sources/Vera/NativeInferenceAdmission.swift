import CryptoKit
import Foundation

struct NativeInferenceBudget: Sendable {
    let deadline: ContinuousClock.Instant
    let seconds: Double

    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw NativeInferenceAdmission.AdmissionError.deadline }
    }
}

struct NativeInferenceAdmission: Sendable {
    enum Priority: String, Codable, Sendable { case foreground, background }

    enum AdmissionError: Error, LocalizedError {
        case unavailable
        case expired
        case deadline
        case malformed

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Vera can't coordinate the model request right now. Check the engine connection and try again."
            case .expired: return "The model reservation expired. Please try again."
            case .deadline: return "The model request reached its time limit."
            case .malformed: return "The engine returned an invalid model reservation."
            }
        }
    }

    struct Reply: Codable, Sendable {
        let request_id: String
        let state: String
        let generation_seconds_remaining: Double
        let lease_seconds_remaining: Double
        let poll_seconds: Double
        let queue_seconds: Double
        let queue_wait_seconds: Double
    }

    private struct Body: Encodable {
        let request_id: String
        let resource: String
        let priority: Priority
        let requested_seconds: Double
    }

    let baseURL: URL
    var session: URLSession = .shared
    var observe: (@Sendable (String, Double) -> Void)? = nil
    var arbiter: NativeInferenceArbiter? = nil

    static func configured() -> NativeInferenceAdmission? { local() }

    static func local(_ arbiter: NativeInferenceArbiter = .shared) -> NativeInferenceAdmission {
        NativeInferenceAdmission(baseURL: NativeTaskLocalEngine.identity.base, arbiter: arbiter)
    }

    static func resource(for base: URL) throws -> String {
        guard let parts = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = parts.host?.lowercased(), !rawHost.isEmpty else { throw AdmissionError.malformed }
        let host = rawHost.contains(":") && !rawHost.hasPrefix("[") ? "[\(rawHost)]" : rawHost
        let defaultPort = scheme == "https" ? 443 : 80
        let port = parts.port.map { $0 == defaultPort ? "" : ":\($0)" } ?? ""
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let unreserved = Set("abcdefghijklmnopqrstuvwxyz".utf8).union("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~".utf8)
        let bytes = Array(path.utf8)
        var normalized = ""
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37, index + 2 < bytes.count,
               let byte = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                normalized += unreserved.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
                index += 3
            } else {
                normalized.append(Character(UnicodeScalar(bytes[index])))
                index += 1
            }
        }
        let canonical = "\(scheme)://\(host)\(port)\(normalized)"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func perform<T: Sendable>(
        endpoint: URL, priority: Priority, requestedSeconds: Double,
        operation: @escaping @Sendable (NativeInferenceBudget) async throws -> T
    ) async throws -> T {
        if let arbiter {
            return try await performLocally(arbiter, endpoint: endpoint, priority: priority,
                                            requestedSeconds: requestedSeconds, operation: operation)
        }
        let requestID = UUID().uuidString.lowercased()
        let body = Body(request_id: requestID, resource: try Self.resource(for: endpoint),
                        priority: priority, requested_seconds: requestedSeconds)
        let queueStart = ContinuousClock.now
        var operationStarted = false
        do {
            while true {
                try Task.checkCancellation()
                let started = ContinuousClock.now
                let reply = try await acquire(body)
                guard reply.request_id == requestID,
                      reply.poll_seconds.isFinite, reply.poll_seconds > 0,
                      reply.generation_seconds_remaining.isFinite,
                      reply.queue_seconds.isFinite, reply.queue_seconds > 0 else { throw AdmissionError.malformed }
                let elapsed = Self.seconds(started.duration(to: .now))
                if reply.state == "admitted" {
                    let remaining = min(requestedSeconds, reply.generation_seconds_remaining) - elapsed
                    guard remaining > 0 else { throw AdmissionError.expired }
                    let budget = NativeInferenceBudget(deadline: .now.advanced(by: .seconds(remaining)), seconds: remaining)
                    observe?("admission_seconds", Self.seconds(queueStart.duration(to: .now)))
                    observe?("queue_wait_seconds", reply.queue_wait_seconds)
                    let cleanup = NativeInferenceCleanup { await releaseBestEffort(requestID) }
                    operationStarted = true
                    let value = try await NativeInferenceDeadline.run(seconds: remaining, onNotStarted: { await cleanup.release() }) {
                        let generationStarted = ContinuousClock.now
                        defer {
                            observe?("generation_seconds", Self.seconds(generationStarted.duration(to: .now)))
                            Task { await cleanup.release() }
                        }
                        do {
                            try budget.check()
                            let value = try await operation(budget)
                            try budget.check()
                            return value
                        } catch {
                            await cleanup.release()
                            throw error
                        }
                    }
                    await cleanup.release()
                    return value
                }
                guard reply.state == "pending" else { throw AdmissionError.expired }
                guard Self.seconds(queueStart.duration(to: .now)) < reply.queue_seconds else { throw AdmissionError.deadline }
                try await Task.sleep(for: .seconds(min(reply.poll_seconds, 0.25)))
            }
        } catch {
            if !operationStarted { await releaseBestEffort(requestID) }
            throw error
        }
    }

    private func performLocally<T: Sendable>(
        _ arbiter: NativeInferenceArbiter, endpoint: URL, priority: Priority, requestedSeconds: Double,
        operation: @escaping @Sendable (NativeInferenceBudget) async throws -> T
    ) async throws -> T {
        guard requestedSeconds.isFinite, requestedSeconds > 0 else { throw AdmissionError.deadline }
        let resource = try Self.resource(for: endpoint)
        let queueStart = ContinuousClock.now
        let lease = try await arbiter.acquire(resource: resource, priority: priority, queueSeconds: requestedSeconds)
        let waited = Self.seconds(queueStart.duration(to: .now))
        observe?("admission_seconds", waited)
        observe?("queue_wait_seconds", waited)
        let remaining = requestedSeconds - waited
        guard remaining > 0 else {
            await arbiter.release(lease)
            throw AdmissionError.expired
        }
        let budget = NativeInferenceBudget(deadline: .now.advanced(by: .seconds(remaining)), seconds: remaining)
        let cleanup = NativeInferenceCleanup { await arbiter.release(lease) }
        do {
            let value = try await NativeInferenceDeadline.run(seconds: remaining, onNotStarted: { await cleanup.release() }) {
                let generationStarted = ContinuousClock.now
                defer { observe?("generation_seconds", Self.seconds(generationStarted.duration(to: .now))) }
                try budget.check()
                let value = try await operation(budget)
                try budget.check()
                return value
            }
            await cleanup.release()
            return value
        } catch {
            await cleanup.release()
            throw error
        }
    }

    private func acquire(_ body: Body) async throws -> Reply {
        var request = URLRequest(url: baseURL.appendingPathComponent("inference/admission"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        for attempt in 0..<2 {
            do {
                return try await control(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if attempt == 1 { throw AdmissionError.unavailable }
            }
        }
        throw AdmissionError.unavailable
    }

    private func control(_ request: URLRequest) async throws -> Reply {
        try await NativeInferenceDeadline.run(seconds: 3) {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AdmissionError.unavailable }
            return try JSONDecoder().decode(Reply.self, from: data)
        }
    }

    private func releaseBestEffort(_ requestID: String) async {
        let client = self
        await Task.detached {
            var request = URLRequest(url: client.baseURL.appendingPathComponent("inference/admission/\(requestID)/release"))
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            _ = try? await client.control(request)
        }.value
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

private final class NativeInferenceRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var finished = false
    private var canceled = false

    func start(
        _ continuation: CheckedContinuation<Value, Error>, seconds: Double,
        body: @escaping @Sendable () async throws -> Value,
        onNotStarted: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        if canceled {
            lock.unlock()
            Task { await onNotStarted() }
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        let operation = Task {
            guard beginOperation() else { await onNotStarted(); return }
            do { finish(.success(try await body())) }
            catch { finish(.failure(error)) }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
                finish(.failure(NativeInferenceAdmission.AdmissionError.deadline))
            } catch {}
        }
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished {
            self.operation = operation
            self.timer = timer
        }
        lock.unlock()
        if alreadyFinished {
            operation.cancel()
            timer.cancel()
        }
    }

    private func beginOperation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished && !canceled
    }

    func cancel() {
        lock.lock()
        canceled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let operation = operation
        let timer = timer
        self.operation = nil
        self.timer = nil
        lock.unlock()
        operation?.cancel()
        timer?.cancel()
        continuation.resume(with: result)
    }
}

enum NativeInferenceDeadline {
    static func run<T: Sendable>(seconds: Double, onNotStarted: @escaping @Sendable () async -> Void = {}, body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds.isFinite, seconds > 0 else { throw NativeInferenceAdmission.AdmissionError.deadline }
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        let race = NativeInferenceRace<T>()
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, seconds: seconds, body: body, onNotStarted: onNotStarted)
            }
        } onCancel: {
            race.cancel()
        }
        guard ContinuousClock.now < deadline else { throw NativeInferenceAdmission.AdmissionError.deadline }
        return value
    }
}

private actor NativeInferenceCleanup {
    private let action: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(action: @escaping @Sendable () async -> Void) { self.action = action }

    func release() async {
        if task == nil { task = Task { await action() } }
        await task?.value
    }
}
