import Foundation

enum NativeDiagnosticRedaction {
    static let placeholder = "[redacted]"
    static let sensitiveKeyParts = ["key", "token", "secret", "authorization", "password", "cookie", "credential"]
    static let minimumSecretLength = 6
    static let opaqueSegmentLength = 16
    static let textPatterns = [
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]+"#, placeholder),
        (#"(?i)\b(x[-_]?api[-_]?key|api[-_]?key|apikey|key|token|secret|password|authorization)("?\s*[=:]\s*"?)[^\s&",;}]+"#, "$1$2" + placeholder),
        (#"\bsk-[A-Za-z0-9_\-]{8,}"#, placeholder),
        (#"\b[0-9A-Fa-f]{32,}\b"#, placeholder),
    ]
    static let base64Candidate = #"[A-Za-z0-9+/_\-]{40,}={0,2}"#
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

    static func payload(_ data: Data, secrets: [String] = []) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
           object is [String: Any] || object is [Any],
           let encoded = try? JSONSerialization.data(withJSONObject: self.value(object, secrets: secrets), options: [.sortedKeys]) {
            return text(String(decoding: encoded, as: UTF8.self), secrets: secrets)
        }
        return text(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), secrets: secrets)
    }

    static func text(_ input: String, secrets: [String] = []) -> String {
        var output = secrets.filter { $0.count >= minimumSecretLength }.reduce(input) {
            $0.replacingOccurrences(of: $1, with: placeholder)
        }
        for (pattern, template) in textPatterns {
            output = output.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return maskOpaque(output)
    }

    static func console(_ input: String) -> String {
        consolePatterns.reduce(text(input)) { current, pattern in
            current.replacingOccurrences(of: pattern, with: placeholder, options: .regularExpression)
        }
    }

    private static func maskOpaque(_ input: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: base64Candidate) else { return input }
        var output = input
        let matches = expression.matches(in: input, range: NSRange(input.startIndex..., in: input))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let candidate = output[range]
            let longest = candidate.split(whereSeparator: { $0 == "/" || $0 == "-" }).map(\.count).max() ?? 0
            guard longest >= opaqueSegmentLength, candidate.contains(where: \.isNumber), candidate.contains(where: \.isLetter) else { continue }
            output.replaceSubrange(range, with: placeholder)
        }
        return output
    }
}
