import Foundation
import Synchronization

struct NativeMCPOAuthHTTPTransport: NativeMCPOAuthTransport {
    private let fixtureProtocol: URLProtocol.Type?

    init(fixtureProtocol: URLProtocol.Type? = nil) { self.fixtureProtocol = fixtureProtocol }
    func send(_ request: NativeMCPOAuthRequest, gate: NativeMCPOAuthGate) async throws -> NativeMCPOAuthResponse {
        let exchange = NativeMCPOAuthHTTPExchange(request: request, gate: gate, fixtureProtocol: fixtureProtocol)
        return try await withTaskCancellationHandler {
            try await exchange.run()
        } onCancel: { exchange.finish(.failure(.cancelled)) }
    }
}

private final class NativeMCPOAuthHTTPExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<NativeMCPOAuthResponse, any Error>?
        var session: URLSession?
        var task: URLSessionDataTask?
        var response: HTTPURLResponse?
        var data = Data()
        var terminal: Result<NativeMCPOAuthResponse, NativeMCPOAuthError>?
        var observer: UUID?
        var timeout: Task<Void, Never>?
    }
    private let request: NativeMCPOAuthRequest
    private let gate: NativeMCPOAuthGate
    private let fixtureProtocol: URLProtocol.Type?
    private let state = Mutex(State())

    init(request: NativeMCPOAuthRequest, gate: NativeMCPOAuthGate, fixtureProtocol: URLProtocol.Type?) {
        self.request = request
        self.gate = gate
        self.fixtureProtocol = fixtureProtocol
    }

    func run() async throws -> NativeMCPOAuthResponse {
        try await withCheckedThrowingContinuation { continuation in
            let previous = state.withLock { value -> Result<NativeMCPOAuthResponse, NativeMCPOAuthError>? in
                if let result = value.terminal { return result }
                value.continuation = continuation
                return nil
            }
            if let previous { continuation.resume(with: previous.mapError { $0 as any Error }); return }
            let configuration = URLSessionConfiguration.ephemeral
            if let fixtureProtocol { configuration.protocolClasses = [fixtureProtocol] }
            configuration.connectionProxyDictionary = [:]
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = request.timeout
            configuration.timeoutIntervalForResource = request.timeout
            configuration.httpMaximumConnectionsPerHost = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            var wire = URLRequest(url: request.url)
            wire.httpMethod = request.body == nil ? "GET" : "POST"
            wire.httpBody = request.body
            wire.httpShouldHandleCookies = false
            wire.setValue("application/json", forHTTPHeaderField: "Accept")
            wire.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            if request.body != nil { wire.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
            let task = session.dataTask(with: wire)
            let observer = gate.register { [weak self] in self?.finish(.failure(.cancelled)) }
            do {
                try gate.perform {
                    let start = state.withLock { value in
                        guard value.terminal == nil else { return false }
                        value.session = session
                        value.task = task
                        value.observer = observer
                        return true
                    }
                    if start { task.resume() }
                    else { session.invalidateAndCancel() }
                }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.request.timeout ?? 20)) } catch { return }
                    self?.finish(.failure(.network))
                }
                let retain = state.withLock { value in
                    guard value.terminal == nil else { return false }
                    value.timeout = timer
                    return true
                }
                if !retain { timer.cancel(); gate.remove(observer) }
            } catch {
                gate.remove(observer)
                session.invalidateAndCancel()
                finish(.failure((error as? NativeMCPOAuthError) ?? .cancelled))
            }
        }
    }

    func finish(_ result: Result<NativeMCPOAuthResponse, NativeMCPOAuthError>) {
        let captured = state.withLock { value -> (CheckedContinuation<NativeMCPOAuthResponse, any Error>?, URLSession?, UUID?, Task<Void, Never>?)? in
            guard value.terminal == nil else { return nil }
            value.terminal = result
            let captured = (value.continuation, value.session, value.observer, value.timeout)
            value.continuation = nil
            value.session = nil
            value.task = nil
            value.observer = nil
            value.timeout = nil
            value.data = Data()
            value.response = nil
            return captured
        }
        guard let captured else { return }
        captured.3?.cancel()
        if let observer = captured.2 { gate.remove(observer) }
        captured.1?.invalidateAndCancel()
        captured.0?.resume(with: result.mapError { $0 as any Error })
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url?.absoluteString == request.url.absoluteString,
              response.statusCode == 200,
              response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            completionHandler(.cancel)
            finish(.failure(.network))
            return
        }
        guard response.expectedContentLength <= request.maximumBytes else {
            completionHandler(.cancel)
            finish(.failure(.responseTooLarge))
            return
        }
        do { try gate.check() } catch {
            completionHandler(.cancel)
            finish(.failure(.cancelled))
            return
        }
        let accept = state.withLock { value in
            guard value.terminal == nil else { return false }
            value.response = response
            return true
        }
        completionHandler(accept ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try gate.check() } catch { finish(.failure(.cancelled)); return }
        let overflow = state.withLock { value in
            guard value.terminal == nil else { return false }
            guard data.count <= request.maximumBytes - value.data.count else { return true }
            value.data.append(data)
            return false
        }
        if overflow { finish(.failure(.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard error == nil else { finish(.failure(.network)); return }
        do { try gate.check() } catch { finish(.failure(.cancelled)); return }
        let result = state.withLock { value -> NativeMCPOAuthResponse? in
            guard value.terminal == nil, let response = value.response, let url = response.url else { return nil }
            return NativeMCPOAuthResponse(url: url, status: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "", body: value.data)
        }
        if let result { finish(.success(result)) } else { finish(.failure(.network)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(.redirectDenied))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(.network))
        }
    }
}
