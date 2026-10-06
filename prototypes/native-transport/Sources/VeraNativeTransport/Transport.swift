import Foundation
import Security
import LocalAuthentication

protocol CredentialSource: Sendable {
    func read(profile: String, progress: @Sendable (Stage) throws -> Void) throws -> String
}

struct NativeCredential: CredentialSource {
    static func query(profile: String, context: LAContext = LAContext()) throws -> [String: Any] {
        context.interactionNotAllowed = true
        try require(context.interactionNotAllowed, .credentialUnavailable)
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.displacedforest.vera.native-chat",
            kSecAttrAccount as String: profile,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
    }
    func read(profile: String, progress: @Sendable (Stage) throws -> Void) throws -> String {
        let query = try Self.query(profile: profile)
        try progress(.keychainBegin)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try progress(.keychainReturned)
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty,
              key.utf8.count <= 4096, !key.contains("\r"), !key.contains("\n") else { throw Failure.credentialUnavailable }
        return key
    }
}

struct SavedProfile {
    static func validate(_ value: J, profile: String) throws {
        let settings = value["native_chat"]
        try require(settings["activeProfileID"].string == profile, .unauthorized)
        let matches = settings["profiles"].array?.filter { $0["id"].string == profile } ?? []
        try require(matches.count == 1, .unauthorized)
        guard let text = matches[0]["baseURL"].string, let url = URL(string: text) else { throw Failure.unauthorized }
        try require(url.scheme == "https" && url.host == "openrouter.ai" && ["/api/v1", "/api/v1/"].contains(url.path) && url.port == nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil, .unauthorized)
        try require(matches[0]["selectedModel"].string == modelID, .unauthorized)
    }
}

protocol HTTPTransport: Sendable {
    func send(path: String, body: Data?, credential: String, limit: Int) async throws -> Data
}

final class URLTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        self.configuration = configuration
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    func send(path: String, body: Data?, credential: String, limit: Int) async throws -> Data {
        try require(["models", "key", "chat/completions"].contains(path), .unauthorized)
        try require((path == "chat/completions") == (body != nil), .unauthorized)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: origin + path)!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return try await withTaskCancellationHandler {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.url == request.url, response.expectedContentLength <= limit else { throw Failure.providerResponse }
                var result = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard result.count < limit else { throw Failure.providerResponse }
                    result.append(byte)
                }
                return result
            } catch is CancellationError { throw Failure.canceled }
            catch let failure as Failure { throw failure }
            catch { throw Task.isCancelled ? Failure.canceled : Failure.unavailable }
        } onCancel: { session.invalidateAndCancel() }
    }
}
