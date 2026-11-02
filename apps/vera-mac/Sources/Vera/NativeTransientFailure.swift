import Foundation

enum NativeTransientFailure {
    static let retryPauseSeconds: Double = 2
    static let retryingStatus = "Trying once more"
    static let transientStatuses: Set<Int> = [429, 500, 502, 503, 504]
    static let reasonLimit = 160

    static func isTransient(_ error: Error) -> Bool {
        guard let client = error as? NativeChatClient.ClientError else { return false }
        switch client {
        case .http(let status, _): return transientStatuses.contains(status)
        case .provider: return true
        default: return false
        }
    }

    static func describe(_ error: Error) -> String {
        guard let client = error as? NativeChatClient.ClientError else { return error.localizedDescription }
        switch client {
        case .http(let status, let detail):
            let cause: String
            switch status {
            case 429: cause = "Rate limited by the model endpoint"
            case 500, 502, 503, 504: cause = "The model endpoint was unavailable"
            default: cause = "The model endpoint rejected the request"
            }
            let reason = reasonLine(detail)
            return reason.isEmpty ? "\(cause) (\(status))." : "\(cause) (\(status)): \(reason)"
        case .provider(let message, let raw):
            let reason = reasonLine(raw).isEmpty ? reasonLine(message) : reasonLine(raw)
            return reason.isEmpty ? "The model endpoint reported an error." : "The model endpoint reported an error: \(reason)"
        default:
            return client.localizedDescription
        }
    }

    static func reasonLine(_ detail: String) -> String {
        var text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
            text = summary(of: object) ?? ""
        }
        text = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("{") || text.contains("}") || text.contains("\"") { return "" }
        if text.count > reasonLimit { text = String(text.prefix(reasonLimit)).trimmingCharacters(in: .whitespaces) }
        return text
    }

    private static func summary(of object: Any) -> String? {
        guard let dict = object as? [String: Any] else {
            if let array = object as? [Any] { return array.lazy.compactMap(summary(of:)).first }
            return object as? String
        }
        if let nested = dict["error"], !(nested is String), let inner = summary(of: nested) { return inner }
        var parts: [String] = []
        if let message = (dict["message"] as? String) ?? (dict["error"] as? String) ?? (dict["detail"] as? String) {
            parts.append(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let metadata = dict["metadata"] as? [String: Any] {
            if let raw = metadata["raw"] as? String, let line = raw.split(whereSeparator: \.isNewline).first {
                let upstream = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if !upstream.isEmpty, !parts.contains(upstream) { parts.append(upstream) }
            }
            if let provider = metadata["provider_name"] as? String, !provider.isEmpty { parts.append("from \(provider)") }
        }
        let joined = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }
}
