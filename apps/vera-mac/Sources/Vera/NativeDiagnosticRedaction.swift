import Foundation

enum NativeDiagnosticRedaction {
    static let placeholder = "[redacted]"
    static let sensitiveKeyParts = ["key", "token", "secret", "authorization", "password", "cookie", "credential"]
    static let textPatterns = [
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]+"#,
        #"\bsk-[A-Za-z0-9_\-]{8,}"#,
    ]
    static let consolePatterns = [#"[A-Za-z0-9+/=_\-]{24,}"#]

    static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return sensitiveKeyParts.contains { lowered.contains($0) }
    }

    static func value(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return Dictionary(uniqueKeysWithValues: object.map { key, nested in
                (key, isSensitiveKey(key) ? placeholder as Any : self.value(nested))
            })
        case let array as [Any]:
            return array.map { self.value($0) }
        case let string as String:
            return text(string)
        default:
            return value
        }
    }

    static func text(_ input: String) -> String {
        masked(input, textPatterns)
    }

    static func console(_ input: String) -> String {
        masked(text(input), consolePatterns)
    }

    private static func masked(_ input: String, _ patterns: [String]) -> String {
        patterns.reduce(input) { current, pattern in
            current.replacingOccurrences(of: pattern, with: placeholder, options: .regularExpression)
        }
    }
}
