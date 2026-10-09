import Foundation

final class PiProviderHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = [:]
        self.configuration = configuration
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
    }
    static func validate(_ request: URLRequest) throws -> Int {
        guard let url = request.url else { throw PiBrokerError.unauthorized }
        let allowed = ["https://openrouter.ai/api/v1/models", "https://openrouter.ai/api/v1/key", "https://openrouter.ai/api/v1/chat/completions"]
        try piCheck(allowed.contains(url.absoluteString) && request.httpBodyStream == nil, .unauthorized)
        let completion = url.path.hasSuffix("/chat/completions")
        try piCheck(request.httpMethod == (completion ? "POST" : "GET") && (request.httpBody != nil) == completion, .unauthorized)
        try piCheck((request.httpBody?.count ?? 0) <= 49152)
        guard let credential = request.value(forHTTPHeaderField: "Authorization"), credential.hasPrefix("Bearer "), credential.utf8.count > 7, credential.utf8.count <= 4103, !credential.contains("\r"), !credential.contains("\n") else { throw PiBrokerError.unauthorized }
        let headers = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        try piCheck(headers.isSubset(of: ["authorization", "content-type", "accept"]), .unauthorized)
        return url.path.hasSuffix("/models") ? 8_000_000 : 65536
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let limit = try Self.validate(request)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { throw PiBrokerError.unavailable }
                try piCheck(response.statusCode == 200 && response.url == request.url && response.expectedContentLength <= limit, .unavailable)
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    try piCheck(data.count < limit, .unavailable)
                    data.append(byte)
                }
                return (data, response.statusCode)
            } catch is CancellationError { throw CancellationError() }
            catch { throw PiBrokerError.unavailable }
        } onCancel: { session.invalidateAndCancel() }
    }
}
