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
    static let ownerMarkerName = ".tandem-run-owner"

    let situation: Situation
    let configDirectory: URL
    let database: URL
    let configFile: URL
    let dataRoot: URL
    let attachments: URL
    let projects: URL
    let artifactsIndex: URL
    let assistant: URL
    let reports: URL

    var dataLocations: [URL] { [attachments, projects, artifactsIndex, assistant, reports] }
    var usesStandardLocations: Bool { situation == .plain }

    nonisolated(unsafe) private(set) static var headlessRoot: URL?
    nonisolated(unsafe) private static var settled: AppLocations?

    static var isHeadless: Bool { headlessRoot != nil }

    static var current: AppLocations {
        if let settled { return settled }
        let value = resolve(environment: ProcessInfo.processInfo.environment,
                            home: FileManager.default.homeDirectoryForCurrentUser,
                            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                            headlessRoot: headlessRoot)
        settled = value
        return value
    }

    @discardableResult
    static func settle() -> AppLocations { current }

    static var settingInEffect: Bool {
        if case .setting = current.situation { return true }
        return false
    }

    static func settingDirectory(_ environment: [String: String]) -> URL? {
        guard let raw = environment[settingName], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static func existingAncestor(_ url: URL) -> URL {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" && fileType(candidate.path) == nil {
            candidate = candidate.deletingLastPathComponent().standardizedFileURL
        }
        return candidate
    }

    static func isCaseInsensitiveVolume(_ url: URL) -> Bool {
        let ancestor = existingAncestor(url)
        let values = try? ancestor.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard let sensitive = values?.volumeSupportsCaseSensitiveNames else { return true }
        return !sensitive
    }

    static func sameNode(_ first: String, _ second: String) -> Bool {
        var left = stat()
        var right = stat()
        let bothExist = stat(first, &left) == 0 && stat(second, &right) == 0
        guard bothExist else { return false }
        let sameDevice = left.st_dev == right.st_dev
        let sameInode = left.st_ino == right.st_ino
        return sameDevice && sameInode
    }

    static func comparableForms(_ url: URL, foldCase: Bool) -> Set<String> {
        let forms = [url.standardizedFileURL.path, canonicalPath(url)]
        return Set(foldCase ? forms.map { $0.lowercased() } : forms)
    }

    static func namesSameFolder(_ first: URL, _ second: URL, foldCase: Bool? = nil) -> Bool {
        let fold = foldCase ?? isCaseInsensitiveVolume(second)
        let samePath = !comparableForms(first, foldCase: fold).isDisjoint(with: comparableForms(second, foldCase: fold))
        return samePath || sameNode(first.path, second.path)
    }

    static func isInside(_ url: URL, _ folder: URL, includingFolder: Bool = true, foldCase: Bool? = nil) -> Bool {
        let fold = foldCase ?? isCaseInsensitiveVolume(folder)
        let roots = comparableForms(folder, foldCase: fold)
        let paths = comparableForms(url, foldCase: fold)
        let byPath = paths.contains { path in
            roots.contains { root in
                let sameFolder = includingFolder && path == root
                let nested = path.hasPrefix(root == "/" ? "/" : root + "/")
                return sameFolder || nested
            }
        }
        if byPath { return true }
        guard fileType(folder.path) != nil else { return false }
        var ancestor = includingFolder ? url.standardizedFileURL : url.standardizedFileURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if sameNode(ancestor.path, folder.path) { return true }
            if ancestor.path == "/" { return false }
            ancestor = ancestor.deletingLastPathComponent().standardizedFileURL
        }
    }

    static func situation(environment: [String: String], home: URL, headlessRoot: URL?) -> Situation {
        if let setting = settingDirectory(environment) {
            let standard = home.appendingPathComponent(".vera", isDirectory: true)
            if !namesSameFolder(setting, standard) { return .setting(setting) }
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
            dataRoot: dataRoot,
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

    static func dataFolder(home: URL) -> URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(NativeAttachmentStore.supportFolderName, isDirectory: true)
    }

    static var realDataFolder: URL? { accountHome.map(dataFolder(home:)) }

    static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var remainder: [String] = []
        while existing.path != "/" {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                var path = String(cString: resolved)
                for component in remainder.reversed() { path = (path as NSString).appendingPathComponent(component) }
                return path
            }
            remainder.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent().standardizedFileURL
        }
        return url.standardizedFileURL.path
    }

    static func isInsideRealDataFolder(_ url: URL, realFolder: URL? = realDataFolder, foldCase: Bool? = nil) -> Bool {
        guard let realFolder else { return true }
        return isInside(url, realFolder, foldCase: foldCase)
    }

    static func refuseRealData(_ url: URL) {
        let separateRun = isHeadless || settingInEffect
        guard separateRun, isInsideRealDataFolder(url) else { return }
        let message = "This run keeps its data apart from the app's real data folder, but it was given \(url.path), which is inside it. Pass a separate folder instead."
        FileHandle.standardError.write(Data((message + "\n").utf8))
        fatalError(message)
    }

    static func checkSettingDataRoot() {
        let locations = current
        guard case .setting = locations.situation else { return }
        refuseRealData(locations.dataRoot)
        for location in locations.dataLocations { refuseRealData(location) }
    }

    static func isAcceptableScratchParent(_ folder: URL, home: URL?) -> Bool {
        guard let home else { return false }
        let insideDataFolder = isInside(folder, dataFolder(home: home))
        let insideConfigFolder = isInside(folder, home.appendingPathComponent(".vera", isDirectory: true))
        let isHome = namesSameFolder(folder, home)
        return !insideDataFolder && !insideConfigFolder && !isHome
    }

    static var systemTemporaryDirectory: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0 else { return URL(fileURLWithPath: "/tmp", isDirectory: true) }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
    }

    static func scratchParent(_ environment: [String: String], home: URL? = accountHome) -> URL {
        if let chosen = environment["TMPDIR"], !chosen.isEmpty {
            let folder = URL(fileURLWithPath: chosen, isDirectory: true)
            if isAcceptableScratchParent(folder, home: home) { return folder }
        }
        let system = systemTemporaryDirectory
        if isAcceptableScratchParent(system, home: home) { return system }
        return URL(fileURLWithPath: "/tmp", isDirectory: true)
    }

    static func isolateForHeadlessRun() {
        guard headlessRoot == nil else { return }
        let parent = scratchParent(ProcessInfo.processInfo.environment)
        let name = runPrefix + "\(getpid())-\(UUID().uuidString.lowercased())"
        let root = parent.appendingPathComponent(name, isDirectory: true)
        removeAbandonedRoots(in: parent, home: accountHome)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(ownerMarker(pid: getpid(), name: name).utf8).write(to: root.appendingPathComponent(ownerMarkerName))
        headlessRoot = root
        settled = nil
        atexit { AppLocations.removeHeadlessRoot() }
    }

    static func ownerMarker(pid: pid_t, name: String) -> String { "\(pid)\n\(name)" }

    static func runOwner(_ name: String) -> pid_t? {
        guard name.hasPrefix(runPrefix) else { return nil }
        let rest = name.dropFirst(runPrefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let pidText = rest[rest.startIndex..<dash]
        let uuidText = String(rest[rest.index(after: dash)...])
        let digitsOnly = !pidText.isEmpty && pidText.allSatisfy { $0.isASCII && $0.isNumber }
        let validUUID = UUID(uuidString: uuidText)?.uuidString.lowercased() == uuidText
        guard digitsOnly, validUUID, let pid = pid_t(pidText), pid > 0 else { return nil }
        return pid
    }

    static func fileType(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    static func isAbandonedRoot(_ entry: URL) -> Bool {
        let name = entry.lastPathComponent
        guard let pid = runOwner(name), fileType(entry.path) == S_IFDIR else { return false }
        let processIsGone = kill(pid, 0) == -1 && errno == ESRCH
        guard processIsGone else { return false }
        let marker = entry.appendingPathComponent(ownerMarkerName)
        guard fileType(marker.path) == S_IFREG, let contents = try? String(contentsOf: marker, encoding: .utf8) else { return false }
        return contents == ownerMarker(pid: pid, name: name)
    }

    static func removeAbandonedRoots(in folder: URL, home: URL?) {
        guard isAcceptableScratchParent(folder, home: home) else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(runPrefix) {
            let entry = folder.appendingPathComponent(name, isDirectory: true)
            guard isAbandonedRoot(entry) else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    static func removeHeadlessRoot() {
        guard let root = headlessRoot, runOwner(root.lastPathComponent) == getpid() else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
