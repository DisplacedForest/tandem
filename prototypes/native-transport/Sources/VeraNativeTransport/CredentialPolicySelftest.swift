import Foundation
import Security
import LocalAuthentication

final class FixtureAuthenticationContext: LAContext {
    override var interactionNotAllowed: Bool {
        get { true }
        set {}
    }
}

final class FixtureKeychainAccess: NativeKeychainAccess, @unchecked Sendable {
    enum Mode { case accepted, setFailure, getFailure, stillAllowed, refused }
    let mode: Mode
    private let lock = NSLock()
    private var calls: [String] = []
    init(_ mode: Mode) { self.mode = mode }
    func disableInteraction() -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        calls.append("disable")
        return mode == .setFailure ? errSecParam : errSecSuccess
    }
    func interactionAllowed() -> (OSStatus, Bool) {
        lock.lock(); defer { lock.unlock() }
        calls.append("verify")
        return (mode == .getFailure ? errSecParam : errSecSuccess, mode == .stillAllowed)
    }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.lock(); defer { lock.unlock() }
        let valid = calls == ["disable", "verify"] && query[kSecClass as String] as? String == kSecClassGenericPassword as String
            && query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String
            && (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
            && query[kSecAttrService as String] as? String == "org.displacedforest.vera.native-chat"
            && query[kSecAttrAccount as String] as? String != nil
            && query[kSecReturnData as String] as? Bool == true
            && query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String
        calls.append("read")
        guard valid else { return (errSecParam, nil) }
        return mode == .refused ? (errSecInteractionNotAllowed, nil) : (errSecSuccess, Data("synthetic-policy-key".utf8))
    }
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return calls }
}

enum CredentialPolicySelftest {
    static func run() throws {
        for mode in [FixtureKeychainAccess.Mode.setFailure, .getFailure, .stillAllowed, .refused] {
            let access = FixtureKeychainAccess(mode)
            let reader = NativeCredential(access: access, context: { FixtureAuthenticationContext() })
            try Selftest.expect(.credentialUnavailable) { _ = try reader.read(profile: UUID().uuidString, progress: { _ in }) }
            let expected = mode == .setFailure ? ["disable"] : (mode == .refused ? ["disable", "verify", "read"] : ["disable", "verify"])
            try ensure(access.recorded == expected)
        }
        let rejected = FixtureKeychainAccess(.accepted)
        let reader = NativeCredential(access: rejected, context: { RefusingAuthenticationContext() })
        try Selftest.expect(.credentialUnavailable) { _ = try reader.read(profile: UUID().uuidString, progress: { _ in }) }
        try ensure(rejected.recorded == ["disable", "verify"])
        let access = FixtureKeychainAccess(.accepted)
        let accepted = NativeCredential(access: access, context: { FixtureAuthenticationContext() })
        let result = try accepted.read(profile: UUID().uuidString, progress: { _ in })
        try ensure(result == "synthetic-policy-key" && access.recorded == ["disable", "verify", "read"])
    }
}
