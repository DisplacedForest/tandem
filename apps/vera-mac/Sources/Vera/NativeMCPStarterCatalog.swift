import Foundation

extension NativeMCPServerConfiguration.Authentication: Codable {}

struct NativeMCPStarterEntry: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var publisher: String
    var description: String
    var category: String
    var url: URL
    var authentication: NativeMCPServerConfiguration.Authentication
    var readTools: [String]
    var sourceURL: URL

    enum CodingKeys: String, CodingKey {
        case id, name, publisher, description, category, url, authentication
        case readTools = "read_tools"
        case sourceURL = "source_url"
    }
}

struct NativeMCPStarterSkip: Hashable, Sendable {
    var id: String
    var reason: String
}

struct NativeMCPStarterCatalog: Sendable {
    static let resourceName = "mcp-starter-catalog"
    static let knownCategories: Set<String> = ["Documentation", "Developer tools", "Code hosting", "Monitoring", "Models and datasets", "Network"]

    var entries: [NativeMCPStarterEntry]
    var skipped: [NativeMCPStarterSkip]

    static func bundled() throws -> NativeMCPStarterCatalog {
        guard let url = VeraResources.url(resourceName, ext: "json") else {
            throw NativeToolError.failed("The integration catalogue is missing from this build.")
        }
        return try load(Data(contentsOf: url))
    }

    static func load(_ data: Data) throws -> NativeMCPStarterCatalog {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["entries"] as? [Any] else {
            throw NativeToolError.failed("The integration catalogue could not be read.")
        }
        var entries: [NativeMCPStarterEntry] = []
        var skipped: [NativeMCPStarterSkip] = []
        var ids = Set<String>()
        for (index, value) in rows.enumerated() {
            let fallbackID = ((value as? [String: Any])?["id"] as? String) ?? "entry \(index + 1)"
            do {
                let entry = try validated(value)
                guard ids.insert(entry.id).inserted else { throw NativeToolError.failed("Another entry already uses this id.") }
                entries.append(entry)
            } catch let NativeToolError.failed(reason) {
                skipped.append(NativeMCPStarterSkip(id: fallbackID, reason: reason))
            } catch {
                skipped.append(NativeMCPStarterSkip(id: fallbackID, reason: "The entry could not be read."))
            }
        }
        return NativeMCPStarterCatalog(entries: entries, skipped: skipped)
    }

    private static func validated(_ value: Any) throws -> NativeMCPStarterEntry {
        guard let row = value as? [String: Any], JSONSerialization.isValidJSONObject(row) else {
            throw NativeToolError.failed("The entry is not an object.")
        }
        let entry: NativeMCPStarterEntry
        do {
            entry = try JSONDecoder().decode(NativeMCPStarterEntry.self, from: JSONSerialization.data(withJSONObject: row))
        } catch {
            throw NativeToolError.failed("The entry is missing a field or has an unsupported sign-in type.")
        }
        guard !entry.id.isEmpty else { throw NativeToolError.failed("The entry has no id.") }
        guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.publisher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeToolError.failed("The entry needs a name and a publisher.")
        }
        guard knownCategories.contains(entry.category) else { throw NativeToolError.failed("The entry has an unknown category.") }
        guard isSecure(entry.url), entry.url.query == nil, entry.url.fragment == nil else {
            throw NativeToolError.failed("The service address must be a plain https address.")
        }
        guard isSecure(entry.sourceURL) else { throw NativeToolError.failed("The documentation address must be https.") }
        guard !entry.readTools.isEmpty,
              entry.readTools.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw NativeToolError.failed("The entry needs at least one valid read tool name.")
        }
        return entry
    }

    private static func isSecure(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    var categories: [String] { Array(Set(entries.map(\.category))).sorted() }

    func matching(query: String, category: String?) -> [NativeMCPStarterEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            guard category == nil || entry.category == category else { return false }
            guard !needle.isEmpty else { return true }
            return [entry.name, entry.publisher, entry.description].contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    func configurationRow(for entry: NativeMCPStarterEntry, readTools: [String], scopes: [String]) -> [String: Any] {
        var row: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "name": entry.name,
            "url": entry.url.absoluteString,
            "read_tools": readTools,
            "scopes": scopes,
            "timeout_seconds": 20.0,
            "publisher": entry.publisher,
            "source_url": entry.sourceURL.absoluteString,
        ]
        if entry.authentication != .none { row["authentication"] = entry.authentication.rawValue }
        return row
    }
}
