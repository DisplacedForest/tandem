import Foundation

extension NativeMCPServerConfiguration.Authentication: Codable {}

struct NativeMCPStarterField: Identifiable, Hashable, Codable, Sendable {
    enum Target: String, Codable, Sendable { case address, credential, name }
    var id: String
    var label: String
    var placeholder: String?
    var help: String?
    var secret: Bool
    var optional: Bool?
    var target: Target

    var required: Bool { optional != true }
}

struct NativeMCPStarterEntry: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var publisher: String
    var description: String
    var category: String
    var icon: String?
    var url: String
    var authentication: NativeMCPServerConfiguration.Authentication
    var fields: [NativeMCPStarterField]
    var sourceURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, publisher, description, category, icon, url, authentication, fields
        case sourceURL = "source_url"
    }

    static let own = NativeMCPStarterEntry(
        id: "own", name: "", publisher: "", description: "", category: "", icon: nil, url: "{address}", authentication: .bearer,
        fields: [
            NativeMCPStarterField(id: "name", label: "Name", placeholder: "What to call it", help: nil, secret: false, optional: nil, target: .name),
            NativeMCPStarterField(id: "address", label: "Address of the tool server", placeholder: "https://", help: "The full address, the way the service shows it.", secret: false, optional: nil, target: .address),
            NativeMCPStarterField(id: "token", label: "Access token, if it needs one", placeholder: nil, help: nil, secret: true, optional: true, target: .credential),
        ], sourceURL: nil)

    private init(id: String, name: String, publisher: String, description: String, category: String, icon: String?, url: String,
                 authentication: NativeMCPServerConfiguration.Authentication, fields: [NativeMCPStarterField], sourceURL: URL?) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.description = description
        self.category = category
        self.icon = icon
        self.url = url
        self.authentication = authentication
        self.fields = fields
        self.sourceURL = sourceURL
    }

    var isOwn: Bool { id == Self.own.id }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        publisher = try values.decode(String.self, forKey: .publisher)
        description = try values.decode(String.self, forKey: .description)
        category = try values.decode(String.self, forKey: .category)
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        url = try values.decode(String.self, forKey: .url)
        authentication = try values.decode(NativeMCPServerConfiguration.Authentication.self, forKey: .authentication)
        fields = try values.decodeIfPresent([NativeMCPStarterField].self, forKey: .fields) ?? []
        sourceURL = try values.decode(URL.self, forKey: .sourceURL)
    }

    var addressField: NativeMCPStarterField? { fields.first { $0.target == .address } }
    var nameField: NativeMCPStarterField? { fields.first { $0.target == .name } }
    var credentialField: NativeMCPStarterField? { fields.first { $0.target == .credential } }

    func matches(_ server: NativeMCPServerConfiguration) -> Bool {
        if addressField == nil { return server.endpoint.absoluteString == url }
        return server.sourceURL == sourceURL && server.publisher == publisher
    }

    func endpoint(_ values: [String: String]) throws -> URL {
        guard let field = addressField else {
            guard let fixed = URL(string: url) else { throw NativeToolError.failed("The service address must be a plain https address.") }
            return fixed
        }
        let typed = (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { throw NativeToolError.failed("Enter the address of your server.") }
        guard !typed.contains(where: \.isWhitespace) else { throw NativeToolError.failed("An address can't have spaces in it.") }
        let lowered = typed.lowercased()
        guard let scheme = ["http://", "https://"].first(where: lowered.hasPrefix) else { throw NativeToolError.failed("Start the address with http:// or https://.") }
        guard let parts = URLComponents(string: typed), parts.port.map({ (1...65535).contains($0) }) ?? true,
              let endpoint = URL(string: scheme + typed.dropFirst(scheme.count)) else {
            throw NativeToolError.failed("That isn't a full address. Check it and try again.")
        }
        try NativeMCPAddress.validate(endpoint, personSupplied: true)
        return endpoint
    }
}

struct NativeMCPStarterSkip: Hashable, Sendable {
    var id: String
    var reason: String
}

struct NativeMCPStarterCatalog: Sendable {
    static let resourceName = "mcp-starter-catalog"

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
        guard !entry.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeToolError.failed("The entry has no category.") }
        try checkFields(entry)
        guard entry.id != NativeMCPStarterEntry.own.id, entry.nameField == nil else { throw NativeToolError.failed("The entry uses an id or a value that is taken.") }
        guard entry.sourceURL.map(isSecure) == true else { throw NativeToolError.failed("The documentation address must be https.") }
        return entry
    }

    private static func checkFields(_ entry: NativeMCPStarterEntry) throws {
        let fields = entry.fields
        guard fields.allSatisfy({ !$0.id.isEmpty && !$0.id.contains { "{}".contains($0) } && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(fields.map(\.id)).count == fields.count else {
            throw NativeToolError.failed("Each value the entry asks for needs its own id and a label.")
        }
        let addresses = fields.filter { $0.target == .address }
        let credentials = fields.filter { $0.target == .credential }
        guard addresses.count <= 1, credentials.count <= 1 else { throw NativeToolError.failed("The entry asks for the same kind of value twice.") }
        guard addresses.allSatisfy({ !$0.secret }), credentials.allSatisfy(\.secret) else {
            throw NativeToolError.failed("The sign-in value must be secret and the address must not be.")
        }
        guard credentials.isEmpty || entry.authentication == .bearer else { throw NativeToolError.failed("The entry asks for a sign-in value it has no use for.") }
        guard entry.authentication != .bearer || !credentials.isEmpty else { throw NativeToolError.failed("The entry doesn't ask for the sign-in it needs.") }
        if let address = addresses.first {
            guard address.required else { throw NativeToolError.failed("The entry needs its address filled in.") }
            guard entry.url == "{\(address.id)}" else { throw NativeToolError.failed("The entry asks for an address it has no place for.") }
            return
        }
        guard !entry.url.contains("{"), !entry.url.contains("}"), let url = URL(string: entry.url), url.query == nil, url.fragment == nil,
              (try? NativeMCPAddress.validate(url, personSupplied: false)) != nil else {
            throw NativeToolError.failed("The service address must be a plain https address.")
        }
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

    func configurationRow(for entry: NativeMCPStarterEntry, name: String? = nil, endpoint: URL, authentication: NativeMCPServerConfiguration.Authentication, scopes: [String],
                          id: String = UUID().uuidString.lowercased()) -> [String: Any] {
        var row: [String: Any] = [
            "id": id,
            "name": name ?? entry.name,
            "url": endpoint.absoluteString,
            "scopes": scopes,
            "timeout_seconds": 20.0,
        ]
        if let source = entry.sourceURL {
            row["publisher"] = entry.publisher
            row["source_url"] = source.absoluteString
        }
        if authentication != .none { row["authentication"] = authentication.rawValue }
        return row
    }
}
