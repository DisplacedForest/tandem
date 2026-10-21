import Foundation

actor NativeInferenceArbiter {
    static let shared = NativeInferenceArbiter()
    static let defaultCooldownSeconds: Double = 2

    static var cooldownSeconds: Double {
        guard let raw = ProcessInfo.processInfo.environment["VERA_FOREGROUND_COOLDOWN_SECONDS"],
              let value = Double(raw), value.isFinite, value >= 0, value <= 60 else { return defaultCooldownSeconds }
        return value
    }

    struct Lease: Equatable, Sendable {
        let id: UUID
        let resource: String
        let priority: NativeInferenceAdmission.Priority
    }

    let cooldown: Double
    let pollSeconds: Double
    private var foreground: [String: Int] = [:]
    private var lastForegroundEnd: [String: ContinuousClock.Instant] = [:]
    private var background: Set<String> = []
    private var leases: [UUID: Lease] = [:]

    init(cooldown: Double = NativeInferenceArbiter.cooldownSeconds, pollSeconds: Double = 0.02) {
        self.cooldown = cooldown
        self.pollSeconds = pollSeconds
    }

    func acquire(resource: String, priority: NativeInferenceAdmission.Priority, queueSeconds: Double) async throws -> Lease {
        let lease = Lease(id: UUID(), resource: resource, priority: priority)
        if priority == .foreground {
            foreground[resource, default: 0] += 1
            leases[lease.id] = lease
            return lease
        }
        let started = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            let foregroundIdle = (foreground[resource] ?? 0) == 0
            let cooled = lastForegroundEnd[resource].map { ContinuousClock.now >= $0.advanced(by: .seconds(cooldown)) } ?? true
            if foregroundIdle && cooled && !background.contains(resource) {
                background.insert(resource)
                leases[lease.id] = lease
                return lease
            }
            guard nativeTaskSeconds(started.duration(to: .now)) < queueSeconds else {
                throw NativeInferenceAdmission.AdmissionError.deadline
            }
            try await Task.sleep(for: .seconds(pollSeconds))
        }
    }

    func release(_ lease: Lease) {
        guard leases.removeValue(forKey: lease.id) != nil else { return }
        switch lease.priority {
        case .foreground:
            let remaining = max(0, (foreground[lease.resource] ?? 1) - 1)
            foreground[lease.resource] = remaining
            if remaining == 0 { lastForegroundEnd[lease.resource] = .now }
        case .background:
            background.remove(lease.resource)
        }
    }

    func activeCounts(resource: String) -> (foreground: Int, background: Bool) {
        (foreground[resource] ?? 0, background.contains(resource))
    }
}
