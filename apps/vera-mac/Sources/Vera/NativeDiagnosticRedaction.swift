import Foundation

enum NativeDiagnosticRedaction {
    static let placeholder = "[redacted]"
    static let sensitiveKeyParts = ["key", "token", "secret", "authorization", "password", "cookie", "credential"]
    static let minimumSecretLength = 6
    static let authorizationValues = #"(?i)\b(?:bearer\s+[A-Za-z0-9._~+/=\-]{8,}|basic\s+[A-Za-z0-9+/=]{8,})"#
    static let credentialAssignment = #"(?i)\b(x[-_]?api[-_]?key|api[-_]?key|access[-_]?token|auth[-_]?token|client[-_]?secret|secret|password|authorization)("?\s*[=:]\s*"?)[^\s&",;}]+"#
    static let knownKeyShapes = [
        #"\bsk[-_][A-Za-z0-9_\-]{8,}"#,
        #"\b[pr]k_(?:live|test)_[A-Za-z0-9]{8,}"#,
        #"\bAIza[0-9A-Za-z_\-]{35}"#,
        #"\bgh[opus]_[A-Za-z0-9]{16,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{16,}"#,
        #"\bxox[bpa]-[A-Za-z0-9\-]{10,}"#,
        #"\bxapp-[A-Za-z0-9\-]{10,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bya29\.[A-Za-z0-9_\-]{16,}"#,
        #"\bglpat-[A-Za-z0-9_\-]{16,}"#,
        #"\bhf_[A-Za-z0-9]{16,}"#,
        #"\br8_[A-Za-z0-9]{16,}"#,
        #"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#,
    ]
    static let consolePatterns = [#"[A-Za-z0-9+/=_\-]{24,}"#]

    static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return sensitiveKeyParts.contains { lowered.contains($0) }
    }

    static func value(_ value: Any, secrets: [String] = []) -> Any {
        switch value {
        case let object as [String: Any]:
            return Dictionary(uniqueKeysWithValues: object.map { key, nested in
                (key, isSensitiveKey(key) ? placeholder as Any : self.value(nested, secrets: secrets))
            })
        case let array as [Any]:
            return array.map { self.value($0, secrets: secrets) }
        case let string as String:
            return text(string, secrets: secrets)
        default:
            return value
        }
    }

    static func serialized(_ value: Any, secrets: [String] = []) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: self.value(value, secrets: secrets),
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return text(String(decoding: data, as: UTF8.self), secrets: secrets)
    }

    static func payload(_ data: Data, secrets: [String] = []) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] || object is [Any] {
            return serialized(object, secrets: secrets)
        }
        return text(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), secrets: secrets)
    }

    static func text(_ input: String, secrets: [String] = []) -> String {
        var output = secrets.filter { $0.count >= minimumSecretLength }.reduce(input) {
            $0.replacingOccurrences(of: $1, with: placeholder)
        }
        output = output.replacingOccurrences(of: authorizationValues, with: placeholder, options: .regularExpression)
        output = output.replacingOccurrences(of: credentialAssignment, with: "$1$2" + placeholder, options: .regularExpression)
        return knownKeyShapes.reduce(output) { current, pattern in
            current.replacingOccurrences(of: pattern, with: placeholder, options: .regularExpression)
        }
    }

    static func console(_ input: String, secrets: [String] = []) -> String {
        consolePatterns.reduce(text(input, secrets: secrets)) { current, pattern in
            current.replacingOccurrences(of: pattern, with: placeholder, options: .regularExpression)
        }
    }
}
