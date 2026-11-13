import Foundation
import Darwin

struct AppLocations: Equatable, Sendable {
    enum Situation: Equatable, Sendable {
        case plain
        case setting(URL)
        case headless(URL)
    }

    static let settingName = "VERA_CONFIG_DIR"
    static let runPrefix = "tandem-run-"

    let situation: Situation
    let configDirectory: URL
    let database: URL
    let configFile: URL
    let attachments: URL
    let projects: URL
    let artifactsIndex: URL
    let assistant: URL
    let reports: URL

    var dataLocations: [URL] { [attachments, projects, artifactsIndex, assistant, reports] }
    var usesStandardLocations: Bool { situation == .plain }

    nonisolated(unsafe) private(set) static var headlessRoot: URL?

    static var isHeadless: Bool { headlessRoot != nil }

    static var current: AppLocations {
        resolve(environment: ProcessInfo.processInfo.environment,
                home: FileManager.default.homeDirectoryForCurrentUser,
                applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                headlessRoot: headlessRoot)
    }

    static func settingDirectory(_ environment: [String: String]) -> URL? {
        guard let raw = environment[settingName], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static func situation(environment: [String: String], home: URL, headlessRoot: URL?) -> Situation {
        if let setting = settingDirectory(environment) {
            let standard = home.appendingPathComponent(".vera", isDirectory: true).standardizedFileURL.path
            let namesStandardFolder = setting.standardizedFileURL.path == standard
            if !namesStandardFolder { return .setting(setting) }
        }
        if let headlessRoot { return .headless(headlessRoot) }
        return .plain
    }

    static func resolve(environment: [String: String], home: URL, applicationSupport: URL, headlessRoot: URL?) -> AppLocations {
        let situation = situation(environment: environment, home: home, headlessRoot: headlessRoot)
        let configDirectory = settingDirectory(environment) ?? home.appendingPathComponent(".vera", isDirectory: true)
        let dataRoot: URL
        switch situation {
        case .plain:
            dataRoot = applicationSupport.appendingPathComponent(NativeAttachmentStore.supportFolderName, isDirectory: true)
        case .setting(let folder):
            dataRoot = folder.appendingPathComponent("data", isDirectory: true)
        case .headless(let root):
            dataRoot = root
        }
        return AppLocations(
            situation: situation,
            configDirectory: configDirectory,
            database: configDirectory.appendingPathComponent("vera.sqlite"),
            configFile: configDirectory.appendingPathComponent("config.json"),
            attachments: dataRoot.appendingPathComponent("attachments", isDirectory: true),
            projects: dataRoot.appendingPathComponent("projects", isDirectory: true),
            artifactsIndex: dataRoot.appendingPathComponent("artifacts.json"),
            assistant: dataRoot.appendingPathComponent("Assistant", isDirectory: true),
            reports: dataRoot.appendingPathComponent("reports", isDirectory: true))
    }

    static let accountHome: URL? = {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }()

    static var realDataFolder: URL? {
        accountHome?.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(NativeAttachmentStore.supportFolderName, isDirectory: true)
    }

    static func isInsideRealDataFolder(_ url: URL) -> Bool {
        guard let folder = realDataFolder else { return true }
        let roots = Set([folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path].map { $0.lowercased() })
        let paths = Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().path].map { $0.lowercased() })
        return paths.contains { path in
            roots.contains { root in
                let sameFolder = path == root
                let nested = path.hasPrefix(root + "/")
                return sameFolder || nested
            }
        }
    }

    static func refuseRealDataInHeadlessRun(_ url: URL) {
        guard isHeadless, isInsideRealDataFolder(url) else { return }
        let message = "This run is a test or tool run and may not use the app's real data folder, but it was given \(url.path). Pass a scratch folder instead."
        FileHandle.standardError.write(Data((message + "\n").utf8))
        fatalError(message)
    }

    static func isolateForHeadlessRun() {
        guard headlessRoot == nil else { return }
        let root = scratchParent(ProcessInfo.processInfo.environment)
            .appendingPathComponent(runPrefix + "\(getpid())-\(UUID().uuidString.lowercased())", isDirectory: true)
        removeAbandonedRoots(in: root.deletingLastPathComponent())
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        headlessRoot = root
        atexit { AppLocations.removeHeadlessRoot() }
    }

    static func scratchParent(_ environment: [String: String]) -> URL {
        guard let chosen = environment["TMPDIR"], !chosen.isEmpty else { return FileManager.default.temporaryDirectory }
        return URL(fileURLWithPath: chosen, isDirectory: true)
    }

    static func removeAbandonedRoots(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(runPrefix) {
            let pidText = name.dropFirst(runPrefix.count).prefix { $0 != "-" }
            guard let pid = pid_t(pidText), pid > 0 else { continue }
            let processIsGone = kill(pid, 0) == -1 && errno == ESRCH
            guard processIsGone else { continue }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name, isDirectory: true))
        }
    }

    static func removeHeadlessRoot() {
        guard let root = headlessRoot, root.lastPathComponent.hasPrefix(runPrefix) else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
