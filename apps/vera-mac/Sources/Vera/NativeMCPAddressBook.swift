import Foundation

@MainActor
final class NativeMCPAddressBook {
    nonisolated static let holders = "connected-service-addresses"
    static let marker = "address_saved"
    static let unsaved = "A service's address couldn't be saved in your keychain, so nothing was changed. Unlock your keychain and try again."
    static let unmoved = "This service's address couldn't be moved to your keychain, so it's still in Tandem's settings file. Unlock your keychain and reopen Tandem."
    private let store: any NativeCredentialStore
    private(set) var known: [String: String] = [:]

    init(store: any NativeCredentialStore) { self.store = store }

    nonisolated static func account(_ id: String) -> String { "connected-service-address." + id }

    static func identity(_ row: [String: Any]) -> String { (row["id"] as? String ?? "").lowercased() }

    static func origin(_ address: String) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme, let host = url.host(percentEncoded: true), !host.isEmpty else { return nil }
        return scheme.lowercased() + "://" + (host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host)
    }

    static func hides(_ row: [String: Any]) -> Bool {
        guard row["authentication"] as? String != NativeMCPServerConfiguration.Authentication.oauth.rawValue,
              let address = row["url"] as? String, let url = URL(string: address), origin(address) != nil else { return false }
        return !["", "/"].contains(url.path(percentEncoded: true))
    }

    static func unresolved(_ row: [String: Any]) -> Bool { row[marker] as? Bool == true }

    func resolved(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.map { row in
            guard Self.unresolved(row) else { return row }
            var row = row
            let id = Self.identity(row)
            guard !Self.hides(row) else {
                row.removeValue(forKey: Self.marker)
                return row
            }
            guard let address = try? store.readForStartup(for: Self.account(id)), !address.isEmpty else { return row }
            row.removeValue(forKey: Self.marker)
            guard let shown = row["url"] as? String, Self.origin(shown) == Self.origin(address) else { return row }
            row["url"] = address
            known[id] = address
            return row
        }
    }

    func saveAddresses(_ rows: [[String: Any]]) throws -> [String: String?] {
        var replaced: [String: String?] = [:]
        do {
            for row in rows where Self.hides(row) {
                let id = Self.identity(row)
                guard let address = row["url"] as? String, known[id] != address else { continue }
                let before = try store.readForStartup(for: Self.account(id))
                if before != address {
                    try remember(id)
                    try store.set(address, for: Self.account(id))
                    replaced.updateValue(before, forKey: id)
                }
                known[id] = address
            }
        } catch {
            undo(replaced)
            throw error
        }
        return replaced
    }

    func saveEach(_ rows: [[String: Any]]) {
        for row in rows { _ = try? saveAddresses([row]) }
    }

    func exposed(_ rows: [[String: Any]]) -> Set<String> {
        Set(rows.filter { Self.hides($0) && known[Self.identity($0)] != $0["url"] as? String }.map(Self.identity))
    }

    func checked(_ raw: [String: Any], over current: [String: Any]) throws -> [String: Any] {
        let rows = raw["native_mcp_servers"] as? [[String: Any]] ?? []
        saveEach(rows)
        let left = exposed(rows)
        let held = current["native_mcp_servers"] as? [[String: Any]] ?? []
        for row in rows where left.contains(Self.identity(row)) {
            let already = held.contains { Self.identity($0) == Self.identity(row) && $0["url"] as? String == row["url"] as? String }
            guard already else { throw NativeToolError.failed(Self.unsaved) }
        }
        return stripped(raw)
    }

    func undo(_ replaced: [String: String?]) {
        for (id, address) in replaced {
            if let address { if (try? store.set(address, for: Self.account(id))) != nil { known[id] = address } }
            else { forget(id) }
        }
    }

    func stripped(_ raw: [String: Any]) -> [String: Any] {
        guard let rows = raw["native_mcp_servers"] as? [[String: Any]] else { return raw }
        var raw = raw
        raw["native_mcp_servers"] = rows.map { row -> [String: Any] in
            guard Self.hides(row), let address = row["url"] as? String, known[Self.identity(row)] == address, let origin = Self.origin(address) else { return row }
            var row = row
            row["url"] = origin
            row[Self.marker] = true
            return row
        }
        return raw
    }

    func prune(_ rows: [[String: Any]]) {
        let kept = Set(rows.filter { Self.hides($0) || Self.unresolved($0) }.map(Self.identity))
        guard let ids = try? held() else { return }
        for id in ids.subtracting(kept) { forget(id) }
    }

    private func forget(_ id: String) {
        guard (try? store.set(nil, for: Self.account(id))) != nil else { return }
        known.removeValue(forKey: id)
        if let ids = try? held(), ids.contains(id) { try? hold(ids.subtracting([id])) }
    }

    private func held() throws -> Set<String> {
        guard let value = try store.readForStartup(for: Self.holders) else { return [] }
        return try JSONDecoder().decode(Set<String>.self, from: Data(value.utf8))
    }

    private func hold(_ ids: Set<String>) throws {
        let data = try JSONEncoder().encode(ids.sorted())
        try store.set(ids.isEmpty ? nil : String(decoding: data, as: UTF8.self), for: Self.holders)
    }

    private func remember(_ id: String) throws {
        let ids = try held()
        if !ids.contains(id) { try hold(ids.union([id])) }
    }
}

extension NativeMCPServerConfiguration {
    private var pathParts: [String] {
        let raw = endpoint.path(percentEncoded: true).split(separator: "/").map(String.init)
        return Array(Set(raw + raw.compactMap(\.removingPercentEncoding)))
    }

    private var hiddenParts: [String] {
        Set(pathParts.flatMap { segment in
            segment.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { part in
                guard part.count >= 12, part.contains(where: \.isLetter) else { return false }
                return part.contains(where: \.isNumber) || (part.dropFirst().contains(where: \.isUppercase) && part.contains(where: \.isLowercase))
            }
        }).sorted { $0.count > $1.count }
    }

    private var hiddenSegments: [String] {
        pathParts.filter { $0.count >= 5 && $0.contains(where: \.isNumber) && $0.contains(where: \.isLetter) }.sorted { $0.count > $1.count }
    }

    private var hiddenPaths: [String] {
        let raw = endpoint.path(percentEncoded: true)
        var spellings = [raw, raw.removingPercentEncoding ?? raw]
        spellings += spellings.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }
        spellings += spellings.map { String($0.dropFirst()) }.filter { $0.dropLast($0.hasSuffix("/") ? 1 : 0).contains("/") }
        spellings += spellings.map { $0.replacingOccurrences(of: "/", with: "\\/") }
        return Set(spellings.filter { $0.count > 1 }).sorted { $0.count > $1.count }
    }

    func redacted(_ text: String) -> String {
        guard authentication != .oauth, !["", "/"].contains(endpoint.path(percentEncoded: true)) else { return text }
        let full = endpoint.absoluteString
        let schemeless = full.range(of: "://").map { String(full[$0.upperBound...]) } ?? full
        let portless = (endpoint.host(percentEncoded: true) ?? "") + endpoint.path(percentEncoded: true)
        var spellings = [full, schemeless, portless].flatMap { [$0, $0.removingPercentEncoding ?? $0] }
        spellings += spellings.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }
        spellings += spellings.map { $0.replacingOccurrences(of: "/", with: "\\/") }
        spellings += [full, schemeless].flatMap { [$0.replacingOccurrences(of: "/", with: "%2F"), $0.replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: "/", with: "%2F")] }
        var result = text
        for spelling in Set(spellings).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: spelling, with: spelling.contains("://") || spelling.contains(":\\/\\/") ? source : endpoint.host ?? "", options: .caseInsensitive)
        }
        for path in hiddenPaths {
            let pattern = "(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: path) + "(?![A-Za-z0-9_-])"
            result = result.replacingOccurrences(of: path.hasPrefix("/") || path.hasPrefix("\\") ? pattern.replacingOccurrences(of: "(?<![A-Za-z0-9_-])", with: "(?<![A-Za-z_-])") : pattern,
                                                 with: "[hidden]", options: [.regularExpression, .caseInsensitive])
        }
        for segment in hiddenSegments {
            result = result.replacingOccurrences(of: "(/|%2F)" + NSRegularExpression.escapedPattern(for: segment) + "(?![A-Za-z0-9_-])", with: "$1[hidden]", options: [.regularExpression, .caseInsensitive])
        }
        for part in hiddenParts { result = result.replacingOccurrences(of: part, with: "[hidden]", options: .caseInsensitive) }
        return result
    }

    func redacted(_ value: NativeJSONValue) -> NativeJSONValue {
        switch value {
        case .string(let text): return .string(redacted(text))
        case .array(let items): return .array(items.map(redacted))
        case .object(let fields):
            return .object(Dictionary(fields.map { (redacted($0.key), redacted($0.value)) }, uniquingKeysWith: { first, _ in first }))
        default: return value
        }
    }

    func quotesAddress(_ schema: NativeJSONValue) -> Bool {
        let shown = redactedSchema(schema)
        return redacted(shown) != shown
    }

    func redactedSchema(_ schema: NativeJSONValue) -> NativeJSONValue {
        switch schema {
        case .array(let items): return .array(items.map(redactedSchema))
        case .object(let fields):
            return .object(Dictionary(uniqueKeysWithValues: fields.map { key, value in
                if ["description", "title", "$comment"].contains(key), case .string = value { return (key, redacted(value)) }
                if ["default", "examples"].contains(key) { return (key, redacted(value)) }
                return (key, redactedSchema(value))
            }))
        default: return schema
        }
    }
}
