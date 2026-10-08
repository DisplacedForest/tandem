import Foundation

enum ConfigFile {
    static var defaultURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("unused-engine-fixture/config.json") }
    static func read(at url: URL = defaultURL) -> [String: Any] {
        guard let bytes = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
        return value
    }
    static func write(_ raw: [String: Any], at url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: raw, options: .sortedKeys).write(to: url, options: .atomic)
    }
}

enum AppVersion {
    static let current = "2.0.0"
    static let isSelfBuilt = false
}

enum UpdateChecker { static let repo = "fixture/unused" }

enum Semver {
    static func compare(_ a: String, _ b: String) -> Int {
        a == b ? 0 : (a.compare(b, options: .numeric) == .orderedAscending ? -1 : 1)
    }
}

enum VeraResources {
    static func url(_ name: String, ext: String) -> URL? { nil }
}

struct ReleaseInfo: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }
    let tag_name: String
    let assets: [Asset]
    func asset(named name: String) -> Asset? { assets.first { $0.name == name } }
}
