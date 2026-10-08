import Foundation
import Security

@main
struct SelectedCredentialAuthorizationTests {
    static func main() throws {
        typealias Flow = SelectedCredentialAuthorization
        let profile = "synthetic-selected-profile"
        let secret = "synthetic-value-never-in-output"
        let arguments = ["--certificate", String(repeating: "a", count: 40),
                         "--code-hash", String(repeating: "b", count: 40),
                         "--profile-digest", Flow.digest(profile)]
        let request = try Flow.Request(arguments)
        let configuration: [String: Any] = ["native_chat": ["activeProfileID": profile,
                                                          "profiles": [["id": profile], ["id": "unrelated"]]]]
        var passed = 0
        func require(_ condition: @autoclosure () -> Bool) throws {
            guard condition() else { throw Flow.Failure.invalid }
        }
        for raw in [["--unexpected", "--credential-reauthorization"] + arguments,
                    ["--pi-candidate-mock", "--credential-reauthorization"] + arguments,
                    ["--credential-reauthorization-typo"] + arguments] {
            try require(Flow.dispatch(raw) == .reject)
            passed += 1
        }
        try require(Flow.dispatch([]) == .unrelated)
        try require(Flow.dispatch(["--credential-reauthorization"] + arguments) == .authorize(arguments))
        passed += 2
        for raw in [[], Array(arguments.dropLast()), arguments + ["--extra", "value"],
                    ["--certificate", "bad", "--code-hash", arguments[3], "--profile-digest", arguments[5]],
                    ["--certificate", arguments[1], "--certificate", arguments[3], "--profile-digest", arguments[5]]] {
            do { _ = try Flow.Request(raw); throw NSError(domain: "Unexpected acceptance", code: 1) }
            catch Flow.Failure.invalid { passed += 1 }
        }
        for scenario in ["success", "denied", "missing", "malformed", "wrong-profile", "duplicate-profile",
                         "identity", "get-failure", "enable-failure", "restore-failure"] {
            var reads = 0
            var interactionChanges: [Bool] = []
            let operations = Flow.Operations(interactionAllowed: {
                (scenario == "get-failure" ? errSecAuthFailed : errSecSuccess, false)
            }, setInteraction: { allowed in
                interactionChanges.append(allowed)
                if scenario == "enable-failure" && allowed { return errSecAuthFailed }
                if scenario == "restore-failure" && !allowed { return errSecAuthFailed }
                return errSecSuccess
            }, read: { dictionary, result in
                reads += 1
                let query = dictionary as! [String: Any]
                precondition(query[kSecAttrAccount as String] as? String == profile)
                precondition(query[kSecAttrService as String] as? String == "org.displacedforest.vera.native-chat")
                precondition(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
                precondition(query[kSecReturnData as String] as? Bool == true)
                precondition(query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIAllow as String)
                precondition(query.count == 6 && interactionChanges == [true])
                if scenario == "denied" { return errSecAuthFailed }
                if scenario == "missing" { return errSecItemNotFound }
                result?.pointee = (scenario == "malformed" ? Data([0xff]) : Data(secret.utf8)) as CFData
                return errSecSuccess
            })
            var raw = configuration
            if scenario == "wrong-profile" { raw = ["native_chat": ["activeProfileID": "unrelated", "profiles": [["id": "unrelated"]]]] }
            if scenario == "duplicate-profile" { raw = ["native_chat": ["activeProfileID": profile, "profiles": [["id": profile], ["id": profile]]]] }
            let result = Flow.authorize(request, configuration: raw, verifyIdentity: {
                if scenario == "identity" { throw Flow.Failure.invalid }
            }, operations: operations)
            let blocked = ["wrong-profile", "duplicate-profile", "identity", "get-failure", "enable-failure"].contains(scenario)
            try require(reads == (blocked ? 0 : 1) && result.credentialReads == reads)
            try require(result.succeeded == (scenario == "success"))
            try require(result.encoded().range(of: Data(secret.utf8)) == nil)
            if !blocked { try require(interactionChanges == [true, false]) }
            passed += 1
        }
        var requirement: SecRequirement?
        let text = "identifier \"app.vera.mac\" and certificate leaf = H\"\(request.certificate)\" and cdhash H\"\(request.codeHash)\""
        try require(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess && requirement != nil)
        passed += 1
        print("PASS: \(passed) selected-credential authorization fixtures; no actual credential operations")
    }
}
