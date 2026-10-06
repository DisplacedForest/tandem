import Foundation
import os

struct NativeTaskTransportLimits: Sendable {
    var connectAndSend: Double = 10
    var readIdle: Double = 45
}

struct NativeTaskTransportTiming: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case plan, synthesize }
    enum Outcome: String, Codable, Sendable {
        case completed, connect_send_timeout, read_idle_timeout, overall_timeout, transport_timeout, canceled
        case provider_auth, provider_quota, provider_unavailable, provider_response
    }
    let phase: Phase
    let outcome: Outcome
    let status: Int?
    let setupSeconds: Double?
    let headersSeconds: Double?
    let finishSeconds: Double
    let dnsSeconds: Double?
    let connectSeconds: Double?
    let tlsSeconds: Double?

    static func log(_ value: Self) {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        Logger(subsystem: "Vera", category: "native_generation_timing").notice("native_generation_timing \(text, privacy: .public)")
    }
}

final class NativeTaskTransportObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let started = ContinuousClock.now
    private let phase: NativeTaskTransportTiming.Phase
    private let expectedBytes: Int64
    private let overallSeconds: Double
    private let sink: @Sendable (NativeTaskTransportTiming) -> Void
    private var setup: Double?
    private var headers: Double?
    private var lastData: Double?
    private var status: Int?
    private var dns: Double?
    private var connect: Double?
    private var tls: Double?
    private var terminal: NativeTaskTransportTiming.Outcome?

    init(phase: NativeTaskTransportTiming.Phase, expectedBytes: Int, overallSeconds: Double,
         sink: @escaping @Sendable (NativeTaskTransportTiming) -> Void) {
        self.phase = phase
        self.expectedBytes = Int64(expectedBytes)
        self.overallSeconds = overallSeconds
        self.sink = sink
    }

    var setupComplete: Bool { lock.withLock { setup != nil || terminal != nil } }
    var outcome: NativeTaskTransportTiming.Outcome? { lock.withLock { terminal } }
    private var elapsed: Double { nativeTaskSeconds(started.duration(to: .now)) }

    func received(_ response: HTTPURLResponse) {
        lock.withLock {
            guard terminal == nil else { return }
            setup = setup ?? elapsed
            headers = elapsed
            lastData = elapsed
            status = response.statusCode
        }
    }

    func receivedByte() {
        lock.withLock { if terminal == nil { lastData = elapsed } }
    }

    @discardableResult
    func finish(_ outcome: NativeTaskTransportTiming.Outcome, onlyBeforeSetup: Bool = false, readIdle: Double? = nil) -> Bool {
        let value: NativeTaskTransportTiming? = lock.withLock {
            guard terminal == nil, !onlyBeforeSetup || setup == nil else { return nil }
            if let readIdle {
                guard let last = lastData ?? setup, elapsed - last >= readIdle else { return nil }
            }
            let timedOut: Set<NativeTaskTransportTiming.Outcome> = [.connect_send_timeout, .read_idle_timeout, .overall_timeout, .transport_timeout]
            let now = elapsed
            let selected = (timedOut.contains(outcome) || outcome == .completed) && now >= overallSeconds ? .overall_timeout : outcome
            terminal = selected
            return NativeTaskTransportTiming(phase: phase, outcome: selected, status: status,
                setupSeconds: setup, headersSeconds: headers, finishSeconds: now,
                dnsSeconds: dns, connectSeconds: connect, tlsSeconds: tls)
        }
        if let value { sink(value) }
        return value != nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.withLock {
            guard terminal == nil, expectedBytes > 0, totalBytesSent >= expectedBytes else { return }
            setup = setup ?? elapsed
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        func duration(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            let value = end.timeIntervalSince(start)
            return value.isFinite && value >= 0 ? value : nil
        }
        lock.withLock {
            guard terminal == nil, let metric = metrics.transactionMetrics.last else { return }
            dns = duration(metric.domainLookupStartDate, metric.domainLookupEndDate)
            connect = duration(metric.connectStartDate, metric.connectEndDate)
            tls = duration(metric.secureConnectionStartDate, metric.secureConnectionEndDate)
        }
    }
}
