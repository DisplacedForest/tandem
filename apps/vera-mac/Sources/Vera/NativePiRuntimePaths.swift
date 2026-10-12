import Foundation

enum NativePiRuntimePaths {
    private struct Entry: Decodable {
        let path: String
        let sha256: String?
        let link: String?
    }
    private struct Manifest: Decodable {
        let schema: Int
        let platform: String
        let python: String
        let node: String
        let repo: String
        let files: [Entry]
    }
    static func expanded(_ arguments: [String], resources: URL? = Bundle.main.resourceURL) throws -> [String] {
        try piCheck(arguments.count.isMultiple(of: 2))
        var options: [String: String] = [:]
        for offset in stride(from: 0, to: arguments.count, by: 2) {
            try piCheck(options[arguments[offset]] == nil)
            options[arguments[offset]] = arguments[offset + 1]
        }
        let explicit = Set(options.keys).intersection(["--repo", "--python", "--node"])
        if !explicit.isEmpty {
            try piCheck(explicit.count == 3)
            return arguments
        }
        guard let resources else { throw PiBrokerError.unavailable }
        let root = resources.appendingPathComponent("PiRuntime", isDirectory: true).standardizedFileURL
        try piCheck(root == root.resolvingSymlinksInPath(), .unavailable)
        let manifestURL = root.appendingPathComponent("manifest.json")
        try piCheck(manifestURL == manifestURL.resolvingSymlinksInPath(), .unavailable)
        let data = try Data(contentsOf: manifestURL)
        try piCheck(data.count <= 16 * 1024 * 1024)
        #if VERA_PACKAGED_RUNTIME
        try piCheck(piHash(data) == VeraPackagedRuntimeSeal.sha256, .unavailable)
        #else
        throw PiBrokerError.unavailable
        #endif
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        try piCheck(manifest.schema == 1 && manifest.platform == "macos-arm64" && manifest.python == "python/bin/python3" && manifest.node == "node/bin/node" && manifest.repo == "repo")
        var expected = Set<String>()
        for entry in manifest.files {
            try piCheck(!entry.path.isEmpty && !entry.path.hasPrefix("/") && !entry.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }))
            try piCheck(expected.insert(entry.path).inserted)
            let url = root.appendingPathComponent(entry.path)
            let resolved = url.resolvingSymlinksInPath()
            try piCheck(resolved.path.hasPrefix(root.path + "/"), .unavailable)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if let link = entry.link {
                try piCheck(entry.sha256 == nil && values.isSymbolicLink == true && !link.hasPrefix("/"))
                try piCheck(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == link)
            } else {
                try piCheck(values.isSymbolicLink != true && values.isRegularFile == true && entry.sha256?.count == 64)
                try piCheck(piHash(try Data(contentsOf: url, options: .mappedIfSafe)) == entry.sha256, .unavailable)
            }
        }
        var actual = Set<String>()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { throw PiBrokerError.unavailable }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory != true || values.isSymbolicLink == true {
                actual.insert(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        try piCheck(actual == expected.union(["manifest.json"]), .unavailable)
        return arguments + (options["--port"] == nil ? ["--port", "0"] : []) + [
            "--repo", root.appendingPathComponent(manifest.repo).path,
            "--python", root.appendingPathComponent(manifest.python).path,
            "--node", root.appendingPathComponent(manifest.node).path,
        ]
    }
}
