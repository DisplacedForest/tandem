import Foundation
import Darwin
import Network
import WebKit

enum OutboundGuard {
    enum Policy: Equatable, Sendable {
        case open
        case loopbackOnly(Set<String>)
    }

    struct Refusal: LocalizedError, Equatable, Sendable {
        let host: String
        var errorDescription: String? {
            "This test run only reaches this Mac, so it didn't contact \(host.isEmpty ? "that address" : host)."
        }
    }

    static let errorDomain = "OutboundGuard"
    static let refusalCode = 1
    static let optInSettings = ["VERA_MEMORY_LIVE_BASE", "VERA_IMAGE_LIVE_BASE", "VERA_PAGE_FETCH_LIVE_URL"]
    static let localSchemes: Set<String> = ["file", "data", "about", "blob"]

    nonisolated(unsafe) private(set) static var policy: Policy = .open
    nonisolated(unsafe) private static var refusalCount = 0
    private static let lock = NSLock()

    static var refusals: Int { lock.withLock { refusalCount } }

    static func policy(for mode: LaunchPlan.Mode, environment: [String: String]) -> Policy {
        guard LaunchPlan.isHeadless(mode, environment: environment) else { return .open }
        return .loopbackOnly(optInHosts(environment))
    }

    static func optInHosts(_ environment: [String: String]) -> Set<String> {
        Set(optInSettings.compactMap { name in
            guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  let host = URL(string: raw)?.host, !host.isEmpty else { return nil }
            return normalized(host)
        })
    }

    static func install(_ chosen: Policy) {
        policy = chosen
        guard chosen != .open else { return }
        URLProtocol.registerClass(OutboundGuardProtocol.self)
    }

    static func normalized(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    static func isLoopback(_ host: String) -> Bool {
        let bare = normalized(host)
        if bare == "localhost" { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, bare, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        let loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
        let mappedPrefix = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        return loopback || (mappedPrefix && bytes[12] == 127)
    }

    static func permits(_ url: URL?, policy: Policy) -> Bool {
        guard case .loopbackOnly(let allowed) = policy else { return true }
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if localSchemes.contains(scheme) { return true }
        guard let host = url.host, !host.isEmpty else { return false }
        return isLoopback(host) || allowed.contains(normalized(host))
    }

    static func permits(_ url: URL?) -> Bool { permits(url, policy: policy) }

    static func refusal(for url: URL?) -> Refusal { Refusal(host: url?.host ?? "") }

    static func check(_ url: URL?) throws {
        guard !permits(url) else { return }
        noteRefusal()
        throw refusal(for: url)
    }

    static func check(host: String) throws {
        guard case .loopbackOnly(let allowed) = policy else { return }
        guard !isLoopback(host), !allowed.contains(normalized(host)) else { return }
        noteRefusal()
        throw Refusal(host: host)
    }

    static func noteRefusal() { lock.withLock { refusalCount += 1 } }

    static func guarded(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        guard policy != .open, let copy = configuration.copy() as? URLSessionConfiguration else { return configuration }
        let standard = URLSessionConfiguration.ephemeral.protocolClasses ?? []
        let standardIDs = Set(standard.map { ObjectIdentifier($0) })
        let current = configuration.protocolClasses ?? standard
        let guardID = ObjectIdentifier(OutboundGuardProtocol.self)
        let own = current.filter { !standardIDs.contains(ObjectIdentifier($0)) && ObjectIdentifier($0) != guardID }
        let rest = current.filter { standardIDs.contains(ObjectIdentifier($0)) }
        copy.protocolClasses = own + [OutboundGuardProtocol.self] + rest
        return copy
    }

    static func session(configuration: URLSessionConfiguration = .ephemeral, delegate: (any URLSessionDelegate)? = nil,
                        delegateQueue: OperationQueue? = nil) -> URLSession {
        URLSession(configuration: guarded(configuration), delegate: delegate, delegateQueue: delegateQueue)
    }
}

final class OutboundGuardProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        !OutboundGuard.permits(request.url)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        OutboundGuard.noteRefusal()
        let refusal = OutboundGuard.refusal(for: request.url)
        let error = NSError(domain: OutboundGuard.errorDomain, code: OutboundGuard.refusalCode,
                            userInfo: [NSLocalizedDescriptionKey: refusal.errorDescription ?? ""])
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}

extension OutboundGuard {
    static let closedProxyPort: UInt16 = 9

    static func webRules(for chosen: Policy) -> String? {
        guard case .loopbackOnly(let allowed) = chosen else { return nil }
        var rules: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        var filters = [
            "^[a-z][a-z0-9+.-]*://localhost[:/]",
            "^[a-z][a-z0-9+.-]*://127\\.[0-9]+\\.[0-9]+\\.[0-9]+[:/]",
            "^[a-z][a-z0-9+.-]*://\\[::1\\][:/]",
            "^file:", "^data:", "^about:", "^blob:",
        ]
        for host in allowed.sorted() {
            let escaped = host.map { character -> String in
                character.isLetter || character.isNumber || character == "-" ? String(character) : "\\" + String(character)
            }.joined()
            filters.append("^[a-z][a-z0-9+.-]*://\(escaped)[:/]")
        }
        for filter in filters {
            rules.append(["trigger": ["url-filter": filter], "action": ["type": "ignore-previous-rules"]])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    static func webView(policy chosen: Policy = policy) -> WKWebView {
        guard chosen != .open else { return WKWebView() }
        return GuardedWebView(policy: chosen)
    }
}

@MainActor
final class GuardedWebView: WKWebView {
    enum State: Equatable { case waiting, ready, refused }

    private(set) var state: State = .waiting
    private var pending: (() -> Void)?
    private let navigationGuard: GuardedWebNavigation

    init(policy chosen: OutboundGuard.Policy) {
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(httpCONNECTProxy: NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: OutboundGuard.closedProxyPort)!))
        proxy.allowFailover = false
        proxy.excludedDomains = ["localhost", "127.0.0.1", "::1"] + {
            if case .loopbackOnly(let allowed) = chosen { return allowed.sorted() }
            return []
        }()
        store.proxyConfigurations = [proxy]
        configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        navigationGuard = GuardedWebNavigation(policy: chosen)
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = navigationGuard
        Task { await self.attachRules(chosen) }
    }

    required init?(coder: NSCoder) { nil }

    private func attachRules(_ chosen: OutboundGuard.Policy) async {
        guard let encoded = OutboundGuard.webRules(for: chosen),
              let list = try? await GuardedWebRules.compiled(encoded) else {
            state = .refused
            pending = nil
            return
        }
        configuration.userContentController.add(list)
        state = .ready
        let load = pending
        pending = nil
        load?()
    }

    private func whenReady(_ load: @escaping () -> Void) {
        switch state {
        case .ready: load()
        case .waiting: pending = load
        case .refused: break
        }
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        if state == .ready { return super.loadHTMLString(string, baseURL: baseURL) }
        whenReady { [weak self] in _ = self?.loadHTMLString(string, baseURL: baseURL) }
        return nil
    }

    override func load(_ request: URLRequest) -> WKNavigation? {
        guard OutboundGuard.permits(request.url, policy: navigationGuard.policy) else { OutboundGuard.noteRefusal(); return nil }
        if state == .ready { return super.load(request) }
        whenReady { [weak self] in _ = self?.load(request) }
        return nil
    }

    override func loadFileURL(_ URL: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
        if state == .ready { return super.loadFileURL(URL, allowingReadAccessTo: readAccessURL) }
        whenReady { [weak self] in _ = self?.loadFileURL(URL, allowingReadAccessTo: readAccessURL) }
        return nil
    }

    override func load(_ data: Data, mimeType MIMEType: String, characterEncodingName: String, baseURL: URL?) -> WKNavigation? {
        let base = baseURL ?? Foundation.URL(string: "about:blank")!
        if state == .ready { return super.load(data, mimeType: MIMEType, characterEncodingName: characterEncodingName, baseURL: base) }
        whenReady { [weak self] in _ = self?.load(data, mimeType: MIMEType, characterEncodingName: characterEncodingName, baseURL: base) }
        return nil
    }
}

@MainActor
final class GuardedWebNavigation: NSObject, WKNavigationDelegate {
    let policy: OutboundGuard.Policy

    init(policy: OutboundGuard.Policy) { self.policy = policy }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = false
        guard OutboundGuard.permits(navigationAction.request.url, policy: policy) else {
            OutboundGuard.noteRefusal()
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }
}

@MainActor
enum GuardedWebRules {
    private static var compiledLists: [String: WKContentRuleList] = [:]

    static func compiled(_ encoded: String) async throws -> WKContentRuleList? {
        if let existing = compiledLists[encoded] { return existing }
        let folder = (AppLocations.headlessRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("web-rules-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: folder) else { return nil }
        let list = try await store.compileContentRuleList(forIdentifier: "outbound", encodedContentRuleList: encoded)
        if let list { compiledLists[encoded] = list }
        return list
    }
}
