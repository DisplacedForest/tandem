import Foundation

enum LaunchPlan {
    enum Mode: Equatable {
        case app
        case run(String)
        case refused(String)
    }

    static let credentialMode = "--credential-reauthorization"
    static let documentArtifactMode = "--document-artifact-selftest"
    static let shotMode = "--shot"
    static let selftestMode = "--selftest"
    static let namedModes = ["--openrouter-smoke", "--provider-smoke-selftest", "--mcp-selftest", "--domain-state-selftest", "--domain-extraction-selftest", "--shared-runtime-memory-selftest", "--memory-gate-selftest", "--companion-live", "--memory-gate-live", "--memory-evidence-selftest", "--companion-introduction-selftest", "--rule-records-selftest", "--preferences-selftest", selftestMode, "--dump-context"]

    static let realDataModes: Set<String> = ["--memory-gate-live", "--companion-live", "--openrouter-smoke", "--dump-context"]

    static func mode(_ arguments: [String], isolatedModes piModes: Set<String>) -> Mode {
        switch SelectedCredentialAuthorization.dispatch(arguments) {
        case .authorize, .reject:
            return .run(credentialMode)
        case .unrelated:
            break
        }
        let first = arguments.first ?? ""
        let asksForIsolatedMode = arguments.contains { $0.hasPrefix("--pi-") }
        if asksForIsolatedMode && !piModes.contains(first) { return .refused(first) }
        if first == documentArtifactMode { return .run(documentArtifactMode) }
        if piModes.contains(first) { return .run(first) }
        if let index = arguments.firstIndex(of: shotMode), index + 1 < arguments.count { return .run(shotMode) }
        if let named = namedModes.first(where: { arguments.contains($0) }) { return .run(named) }
        if let flag = arguments.first(where: { $0.hasPrefix("--") }) { return .refused(flag) }
        return .app
    }

    static func usesRealData(_ mode: Mode, environment: [String: String]) -> Bool {
        guard case .run(let flag) = mode else { return false }
        return realDataModes.contains(flag)
    }

    static func isHeadless(_ mode: Mode, environment: [String: String]) -> Bool {
        guard case .run = mode else { return false }
        return !usesRealData(mode, environment: environment)
    }

    static func refusal(_ flag: String) -> String {
        "Tandem doesn't recognize the option \(flag). Nothing was started."
    }
}
