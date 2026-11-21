import Foundation
import os

struct NativeTaskTransportLimits: Sendable, Equatable {
    static let defaultConnectAndSendSeconds: Double = 10
    static let defaultFirstReplySeconds: Double = 180
    static let defaultReplyIdleSeconds: Double = 45
    static let defaultRequestSeconds: Double = 600
    static let stepOtherWorkSeconds: Double = 120
    static let connectAndSendSetting = "VERA_BACKGROUND_CONNECT_SECONDS"
    static let firstReplySetting = "VERA_BACKGROUND_FIRST_REPLY_SECONDS"
    static let replyIdleSetting = "VERA_BACKGROUND_REPLY_IDLE_SECONDS"
    static let requestSetting = "VERA_BACKGROUND_REQUEST_SECONDS"
    static let configured = NativeTaskTransportLimits(environment: ProcessInfo.processInfo.environment)

    var connectAndSend: Double
    var firstReply: Double
    var replyIdle: Double
    var request: Double

    init(connectAndSend: Double = Self.configured.connectAndSend, firstReply: Double = Self.configured.firstReply,
         replyIdle: Double = Self.configured.replyIdle, request: Double = Self.configured.request) {
        self.connectAndSend = connectAndSend
        self.firstReply = firstReply
        self.replyIdle = replyIdle
        self.request = request
    }

    init(environment: [String: String]) {
        func seconds(_ name: String, _ fallback: Double) -> Double {
            guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let value = Double(raw), value.isFinite, value > 0, value <= 86400 else { return fallback }
            return value
        }
        self.init(connectAndSend: seconds(Self.connectAndSendSetting, Self.defaultConnectAndSendSeconds),
                  firstReply: seconds(Self.firstReplySetting, Self.defaultFirstReplySeconds),
                  replyIdle: seconds(Self.replyIdleSetting, Self.defaultReplyIdleSeconds),
                  request: seconds(Self.requestSetting, Self.defaultRequestSeconds))
    }

    var valid: Bool {
        [connectAndSend, firstReply, replyIdle, request].allSatisfy { $0.isFinite && $0 > 0 }
    }

    var stepSeconds: Double { request * 2 + Self.stepOtherWorkSeconds }
}

struct NativeTaskTransportTiming: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case plan, review, synthesize, outline, draft, revise, work, condense, notes

        init?(jobPhase: String) {
            let name = jobPhase.split(separator: "-", maxSplits: 1).first.map(String.init) ?? jobPhase
            self.init(rawValue: name)
        }
    }
    enum Outcome: String, Codable, Sendable {
        case completed, connect_send_timeout, first_reply_timeout, read_idle_timeout, overall_timeout, transport_timeout, canceled
        case provider_auth, provider_quota, provider_unavailable, provider_response
        case response_cut_short, response_finish, response_tool_calls, response_empty, response_too_large, response_unreadable, provider_error
    }
    let phase: Phase
    let outcome: Outcome
    let status: Int?
    let setupSeconds: Double?
    let headersSeconds: Double?
    let firstByteSeconds: Double?
    let firstReplySeconds: Double?
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
    private var firstByte: Double?
    private var firstReply: Double?
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
    var httpStatus: Int? { lock.withLock { status } }
    private var elapsed: Double { nativeTaskSeconds(started.duration(to: .now)) }

    func received(_ response: HTTPURLResponse) {
        lock.withLock {
            guard terminal == nil else { return }
            setup = setup ?? elapsed
            headers = elapsed
            status = response.statusCode
        }
    }

    func receivedBytes() {
        lock.withLock {
            guard terminal == nil else { return }
            let now = elapsed
            setup = setup ?? now
            firstByte = firstByte ?? now
            lastData = now
        }
    }

    func replied() {
        lock.withLock {
            guard terminal == nil else { return }
            firstReply = firstReply ?? lastData ?? elapsed
        }
    }

    static let timedOut: Set<NativeTaskTransportTiming.Outcome> = [.connect_send_timeout, .first_reply_timeout, .read_idle_timeout,
                                                                    .overall_timeout, .transport_timeout]

    @discardableResult
    func finishIfStalled(_ limits: NativeTaskTransportLimits) -> Bool {
        finish(.read_idle_timeout, onlyBeforeSetup: false, stall: limits)
    }

    @discardableResult
    func finish(_ outcome: NativeTaskTransportTiming.Outcome, onlyBeforeSetup: Bool = false) -> Bool {
        finish(outcome, onlyBeforeSetup: onlyBeforeSetup, stall: nil)
    }

    private func finish(_ outcome: NativeTaskTransportTiming.Outcome, onlyBeforeSetup: Bool,
                        stall: NativeTaskTransportLimits?) -> Bool {
        let value: NativeTaskTransportTiming? = lock.withLock {
            guard terminal == nil, !onlyBeforeSetup || setup == nil else { return nil }
            let now = elapsed
            var chosen = outcome
            if let stall {
                if firstReply == nil {
                    guard let sent = setup, now - sent >= stall.firstReply else { return nil }
                    chosen = .first_reply_timeout
                } else {
                    guard let last = lastData, now - last >= stall.replyIdle else { return nil }
                    chosen = .read_idle_timeout
                }
            }
            let selected = (Self.timedOut.contains(chosen) || chosen == .completed) && now >= overallSeconds ? .overall_timeout : chosen
            terminal = selected
            return NativeTaskTransportTiming(phase: phase, outcome: selected, status: status,
                setupSeconds: setup, headersSeconds: headers, firstByteSeconds: firstByte,
                firstReplySeconds: firstReply, finishSeconds: now,
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
