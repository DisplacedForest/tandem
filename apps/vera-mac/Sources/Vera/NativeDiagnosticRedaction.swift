import Foundation

enum NativeDiagnosticRedaction {
    static let placeholder = "[redacted]"
    static let sensitiveKeyParts = ["key", "token", "secret", "authorization", "password", "cookie", "credential"]
    static let minimumSecretLength = 6
    static let credentialAssignment = #"(?i)\b(x[-_]?api[-_]?key|api[-_]?key|access[-_]?token|auth[-_]?token|client[-_]?secret|secret|password|authorization)("?\s*[=:]\s*"?)[^\s&",;}]+"#
    static let minimumTokenLength = 20
    static let leadingBoundary = #"(?<![/A-Za-z0-9])"#
    static let trailingBoundary = #"(?![0-9A-Za-z_\-])"#
    static let knownKeyShapes: [(prefix: String, token: String)] = [
        (#"(?i:bearer)\s+"#, #"[A-Za-z0-9._~+/=\-]{20,}"#),
        (#"(?i:basic)\s+"#, #"[A-Za-z0-9+/=]{20,}"#),
        (#"sk[-_]"#, #"[A-Za-z0-9_\-]{20,}"#),
        (#"[pr]k_(?:live|test)_"#, #"[A-Za-z0-9]{20,}"#),
        (#"AIza"#, #"[0-9A-Za-z_\-]{35}"#),
        (#"gh[opus]_"#, #"[A-Za-z0-9]{20,}"#),
        (#"github_pat_"#, #"[A-Za-z0-9_]{20,}"#),
        (#"xox[bpa]-"#, #"[A-Za-z0-9\-]{20,}"#),
        (#"xapp-"#, #"[A-Za-z0-9\-]{20,}"#),
        (#"AKIA"#, #"[0-9A-Z]{16}"#),
        (#"ya29\."#, #"[A-Za-z0-9_\-]{20,}"#),
        (#"glpat-"#, #"[A-Za-z0-9_\-]{20,}"#),
        (#"hf_"#, #"[A-Za-z0-9]{20,}"#),
        (#"r8_"#, #"[A-Za-z0-9]{20,}"#),
        (#"eyJ"#, #"[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#),
    ]
    static let keyShapeExpressions: [NSRegularExpression] = knownKeyShapes.compactMap { shape in
        try? NSRegularExpression(pattern: leadingBoundary + "(?:" + shape.prefix + ")(" + shape.token + ")" + trailingBoundary)
    }
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
        output = keyShapeExpressions.reduce(output, maskKeyShape)
        return output.replacingOccurrences(of: credentialAssignment, with: "$1$2" + placeholder, options: .regularExpression)
    }

    static func isToken(_ token: Substring, exact: Bool) -> Bool {
        token.contains(where: \.isNumber) && (exact || token.count >= minimumTokenLength)
    }

    private static func maskKeyShape(_ input: String, _ expression: NSRegularExpression) -> String {
        var output = input
        for match in expression.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            guard let whole = Range(match.range, in: output), let token = Range(match.range(at: 1), in: output) else { continue }
            let exact = expression.pattern.contains("AKIA") || expression.pattern.contains("AIza")
            guard isToken(output[token], exact: exact) else { continue }
            output.replaceSubrange(whole, with: placeholder)
        }
        return output
    }

    static func console(_ input: String, secrets: [String] = []) -> String {
        consolePatterns.reduce(text(input, secrets: secrets)) { current, pattern in
            current.replacingOccurrences(of: pattern, with: placeholder, options: .regularExpression)
        }
    }
}
