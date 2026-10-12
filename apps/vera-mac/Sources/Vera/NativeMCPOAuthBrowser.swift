import AppKit
import AuthenticationServices
import Foundation

@MainActor
protocol NativeMCPOAuthBrowser: AnyObject {
    func authenticate(url: URL, callback: URL) async throws -> URL
    func cancel()
}

@MainActor
final class NativeMCPOAuthSystemBrowser: NSObject, NativeMCPOAuthBrowser {
    private let window: @MainActor () -> NSWindow?
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var generation: UUID?
    private var presentation: NativeMCPOAuthPresentationAnchor?

    init(window: @escaping @MainActor () -> NSWindow? = { NSApplication.shared.keyWindow }) { self.window = window }

    func authenticate(url: URL, callback: URL) async throws -> URL {
        guard session == nil, continuation == nil, url.scheme == "https", callback.scheme == "vera-oauth", let anchor = window() else { throw NativeMCPOAuthError.invalidState }
        try Task.checkCancellation()
        self.presentation = NativeMCPOAuthPresentationAnchor(anchor)
        let generation = UUID()
        self.generation = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { finish(.failure(NativeMCPOAuthError.cancelled)); return }
                let candidate = ASWebAuthenticationSession(url: url, callback: .customScheme("vera-oauth")) { [weak self] callback, error in
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        if error == nil, let callback { self.finish(.success(callback)) }
                        else { self.finish(.failure(NativeMCPOAuthError.cancelled)) }
                    }
                }
                candidate.prefersEphemeralWebBrowserSession = true
                candidate.presentationContextProvider = presentation
                session = candidate
                if !candidate.start() { finish(.failure(NativeMCPOAuthError.invalidState)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == generation else { return }
                self?.cancel()
            }
        }
    }

    func cancel() { finish(.failure(NativeMCPOAuthError.cancelled)) }

    private func finish(_ result: Result<URL, any Error>) {
        generation = nil
        let continuation = continuation
        let session = session
        self.continuation = nil
        self.session = nil
        session?.cancel()
        presentation = nil
        continuation?.resume(with: result)
    }
}

@MainActor
private final class NativeMCPOAuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: NSWindow
    init(_ window: NSWindow) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}
