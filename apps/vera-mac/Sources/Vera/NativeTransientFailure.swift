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
            return statusLine(status, reason: reasonLine(detail))
        case .provider(let message, let raw):
            let reason = reasonLine(raw).isEmpty ? reasonLine(message) : reasonLine(raw)
            if let status = providerCode(raw) { return statusLine(status, reason: reason) }
            return reason.isEmpty ? "The model endpoint reported an error." : "The model endpoint reported an error: \(reason)"
        default:
            return client.localizedDescription
        }
    }

    static func statusLine(_ status: Int, reason: String) -> String {
        let cause: String
        switch status {
        case 429: cause = "Rate limited by the model endpoint"
        case 500, 502, 503, 504: cause = "The model endpoint was unavailable"
        default: cause = "The model endpoint rejected the request"
        }
        return reason.isEmpty ? "\(cause) (\(status))." : "\(cause) (\(status)): \(reason)"
    }

    static func providerCode(_ raw: String) -> Int? {
        guard let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let error = (object["error"] as? [String: Any]) ?? object
        switch error["code"] {
        case let number as NSNumber:
            let value = number.doubleValue
            guard value.rounded() == value, (100...599).contains(value) else { return nil }
            return number.intValue
        case let text as String:
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (100...599).contains(value) else { return nil }
            return value
        default:
            return nil
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

    static func summary(of object: Any) -> String? {
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
            if let raw = metadata["raw"] as? String, let upstream = upstreamLine(raw), !parts.contains(upstream) {
                parts.append(upstream)
            }
            if let provider = metadata["provider_name"] as? String, !provider.isEmpty { parts.append("from \(provider)") }
        }
        let joined = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    private static func upstreamLine(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data), !(object is String) {
            text = summary(of: object) ?? ""
        }
        let line = (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains("{"), !line.contains("}"), !line.contains("\"") else { return nil }
        return line
    }
}
