import Foundation

struct NativeMCPStandingPermission: Equatable, Sendable {
    var all = false
    var tools: Set<String> = []

    var isEmpty: Bool { !all && tools.isEmpty }

    func allows(_ name: String) -> Bool {
        all || tools.contains { $0.utf8.elementsEqual(name.utf8) }
    }

    static func binding(id: String, endpoint: URL) -> String {
        piHash(Data((id.lowercased() + "\n" + endpoint.absoluteString).utf8))
    }

    static func load(_ raw: Any?, id: String, endpoint: URL) throws -> Self {
        guard let raw else { return Self() }
        guard let row = raw as? [String: Any], Set(row.keys) == ["binding", "all", "tools"],
              let bound = row["binding"] as? String, let all = row["all"] as? Bool,
              let tools = row["tools"] as? [String],
              tools.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw NativeToolError.failed("The saved service permissions could not be read.")
        }
        guard bound == binding(id: id, endpoint: endpoint) else { return Self() }
        return Self(all: all, tools: Set(tools))
    }

    func applying(to existing: [String: Any]) -> [String: Any] {
        var row = existing
        guard !isEmpty, let id = row["id"] as? String, let address = row["url"] as? String,
              let endpoint = URL(string: address) else {
            row.removeValue(forKey: "permissions")
            return row
        }
        row["permissions"] = ["binding": Self.binding(id: id, endpoint: endpoint), "all": all, "tools": tools.sorted()]
        return row
    }
}
