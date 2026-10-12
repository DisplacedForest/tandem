import Foundation
import Security
import CryptoKit

enum SelectedCredentialAuthorization {
    enum Dispatch: Equatable {
        case unrelated, reject, authorize([String])
    }

    static func dispatch(_ arguments: [String]) -> Dispatch {
        if arguments == ["--openrouter-smoke", "--credential-status"] { return .unrelated }
        guard arguments.contains(where: { $0.hasPrefix("--credential-") }) else { return .unrelated }
        guard arguments.first == "--credential-reauthorization" else { return .reject }
        return .authorize(Array(arguments.dropFirst()))
    }

    struct Request {
        let certificate: String
        let codeHash: String
        let profileDigest: String

        init(_ arguments: [String]) throws {
            guard arguments.count == 6 else { throw Failure.invalid }
            var values: [String: String] = [:]
            for index in stride(from: 0, to: arguments.count, by: 2) {
                guard values[arguments[index]] == nil else { throw Failure.invalid }
                values[arguments[index]] = arguments[index + 1]
            }
            guard Set(values.keys) == ["--certificate", "--code-hash", "--profile-digest"],
                  let certificate = values["--certificate"], Self.hex(certificate, count: 40),
                  let codeHash = values["--code-hash"], Self.hex(codeHash, count: 40),
                  let profileDigest = values["--profile-digest"], Self.hex(profileDigest, count: 64) else {
                throw Failure.invalid
            }
            self.certificate = certificate.lowercased()
            self.codeHash = codeHash.lowercased()
            self.profileDigest = profileDigest.lowercased()
        }

        private static func hex(_ value: String, count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        }
    }

    struct Operations {
        var interactionAllowed: () -> (OSStatus, Bool)
        var setInteraction: (Bool) -> OSStatus
        var read: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

        static var live: Self {
            Self(interactionAllowed: {
                var allowed = DarwinBoolean(false)
                let status = SecKeychainGetUserInteractionAllowed(&allowed)
                return (status, allowed.boolValue)
            }, setInteraction: { SecKeychainSetUserInteractionAllowed($0) },
                 read: { SecItemCopyMatching($0, $1) })
        }
    }

    struct Result: Encodable {
        let outcome: String
        let credentialReads: Int
        let status: OSStatus?

        var succeeded: Bool { outcome == "credential_read_succeeded" }
        func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data("{}".utf8) }
    }

    enum Failure: Error { case invalid }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func authorize(_ request: Request, configuration: [String: Any],
                          verifyIdentity: () throws -> Void, operations: Operations) -> Result {
        do {
            try verifyIdentity()
            guard let settings = configuration["native_chat"] as? [String: Any],
                  let selected = settings["activeProfileID"] as? String, !selected.isEmpty,
                  selected.utf8.count <= 128, digest(selected) == request.profileDigest,
                  let profiles = settings["profiles"] as? [[String: Any]],
                  profiles.filter({ $0["id"] as? String == selected }).count == 1 else { throw Failure.invalid }
            let (status, wasAllowed) = operations.interactionAllowed()
            guard status == errSecSuccess else {
                return Result(outcome: "interaction_unavailable", credentialReads: 0, status: status)
            }
            let enabled = operations.setInteraction(true)
            guard enabled == errSecSuccess else {
                return Result(outcome: "interaction_unavailable", credentialReads: 0, status: enabled)
            }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "org.displacedforest.vera.native-chat",
                kSecAttrAccount as String: selected,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow
            ]
            var value: CFTypeRef?
            let readStatus = operations.read(query as CFDictionary, &value)
            let valid = (value as? Data).map { !$0.isEmpty && String(data: $0, encoding: .utf8) != nil } ?? false
            value = nil
            let restored = operations.setInteraction(wasAllowed)
            guard restored == errSecSuccess else {
                return Result(outcome: "interaction_restore_failed", credentialReads: 1, status: restored)
            }
            if readStatus == errSecSuccess && valid {
                return Result(outcome: "credential_read_succeeded", credentialReads: 1, status: readStatus)
            }
            return Result(outcome: readStatus == errSecItemNotFound ? "credential_missing" : "credential_unavailable",
                          credentialReads: 1, status: readStatus)
        } catch {
            return Result(outcome: "scope_rejected", credentialReads: 0, status: nil)
        }
    }

    static func verifyIdentity(_ request: Request) throws {
        guard Bundle.main.bundleURL.path == "/Applications/Vera.app",
              Bundle.main.bundleIdentifier == "app.vera.mac" else { throw Failure.invalid }
        let text = "identifier \"app.vera.mac\" and certificate leaf = H\"\(request.certificate)\" and cdhash H\"\(request.codeHash)\""
        var code: SecCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw Failure.invalid
        }
    }

    static func main(_ arguments: [String], configuration: () -> [String: Any]) -> Never {
        let result: Result
        do {
            let request = try Request(arguments)
            try verifyIdentity(request)
            result = authorize(request, configuration: configuration(),
                               verifyIdentity: { try verifyIdentity(request) }, operations: .live)
        } catch {
            result = Result(outcome: "scope_rejected", credentialReads: 0, status: nil)
        }
        FileHandle.standardOutput.write(result.encoded() + Data([10]))
        exit(result.succeeded ? 0 : 1)
    }

    static func rejectInvocation() -> Never {
        FileHandle.standardOutput.write(Result(outcome: "scope_rejected", credentialReads: 0, status: nil).encoded() + Data([10]))
        exit(1)
    }
}
