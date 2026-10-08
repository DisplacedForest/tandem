import SwiftUI
import AppKit
import CryptoKit

enum EngineMode: String, CaseIterable {
    case remote, local, off
}

@MainActor
final class EngineManager: ObservableObject {
    nonisolated static let label = "com.vera.engine"
    static let engineZipName = "vera-api-macos-arm64.zip"
    static let engineShaName = "vera-api-macos-arm64.zip.sha256"

    enum Phase: Equatable {
        case idle, resolving, downloading, verifying, unpacking, launching, healthy
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var installedVersion: String?
    @Published var running = false
    @Published var runDetail: String?
    @Published var busy = false

    private let lifecycle: EngineLifecycle
    private var modeRevision = 0
    private let configURL: URL

    init(configURL: URL = ConfigFile.defaultURL, operations: EngineOperations = .live) {
        self.configURL = configURL
        lifecycle = EngineLifecycle(layout: EngineLayout(root: configURL.deletingLastPathComponent(),
            home: FileManager.default.homeDirectoryForCurrentUser), operations: operations)
    }

    var port: Int {
        let file = ConfigFile.read(at: configURL)
        if let n = file["engine_port"] as? Int { return n }
        if let s = file["engine_port"] as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
        return 8089
    }

    var currentMode: EngineMode {
        let file = ConfigFile.read(at: configURL)
        if let raw = file["engine_mode"] as? String, let mode = EngineMode(rawValue: raw) { return mode }
        let base = (file["vera_api_base"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return base.isEmpty ? .off : .remote
    }

    var logPathDisplay: String { lifecycle.layout.logFile.path }
    var dataPathDisplay: String { lifecycle.layout.dataDir.path }

    func reconcileOnLaunch() async {
        guard currentMode == .local else {
            await stopEngine()
            return
        }
        let revision = modeRevision
        do { try await lifecycle.recoverPending() }
        catch {
            guard revision == modeRevision, currentMode == .local else { return }
            phase = .failed(error.localizedDescription)
            synchronize()
            return
        }
        guard revision == modeRevision, currentMode == .local else { return }
        await refresh()
        guard revision == modeRevision, currentMode == .local else { return }
        if AppVersion.isSelfBuilt { return }
        if Self.needsEngineUpdate(installed: installedVersion, app: AppVersion.current) || !running {
            await installAndStart()
        }
    }

    func refresh() async {
        guard !busy else { return }
        await lifecycle.refresh(port: port)
        synchronize()
        if running { phase = .healthy }
    }

    func startEngine() async { await installAndStart() }

    func stopEngine() async {
        modeRevision += 1
        do {
            try lifecycle.stop()
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
        synchronize()
    }

    func apply(mode: EngineMode) async {
        guard mode != .local || !busy else { return }
        modeRevision += 1
        let revision = modeRevision
        do {
            if mode == .local {
                guard await installAndStart(), revision == modeRevision else { return }
            }
            var raw = ConfigFile.read(at: configURL)
            raw["engine_mode"] = mode.rawValue
            do { try ConfigFile.write(raw, at: configURL) }
            catch {
                if mode == .local { await stopEngine() }
                throw error
            }
            if mode != .local { await stopEngine() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func removeEngineFiles() {
        guard !busy else { return }
        do {
            try lifecycle.removeFiles()
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
        synchronize()
    }

    func deleteData() {
        do { try lifecycle.deleteData() }
        catch { phase = .failed(error.localizedDescription) }
    }

    @discardableResult
    func installAndStart() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false; synchronize() }
        guard !AppVersion.isSelfBuilt else {
            phase = .failed("Local engine needs a released app build. This copy was built from source.")
            return false
        }
        let target = AppVersion.current
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vera-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try await lifecycle.start(version: target, port: port, archive: {
                self.phase = .resolving
                let release = try await self.releaseForTag("v\(target)")
                guard let zipAsset = release.asset(named: Self.engineZipName),
                      let shaAsset = release.asset(named: Self.engineShaName),
                      let zipURL = URL(string: zipAsset.browser_download_url), zipURL.scheme == "https",
                      let shaURL = URL(string: shaAsset.browser_download_url), shaURL.scheme == "https" else {
                    throw EngineError("No engine download for \(release.tag_name).")
                }
                self.phase = .downloading
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                let download = try await self.lifecycle.operations.download(zipURL)
                let zip = temporary.appendingPathComponent(Self.engineZipName)
                try FileManager.default.moveItem(at: download, to: zip)
                var request = URLRequest(url: shaURL)
                request.timeoutInterval = 30
                let (shaData, response) = try await self.lifecycle.operations.request(request)
                self.phase = .verifying
                guard response.statusCode == 200,
                      let expected = Self.expectedSha(fromAsset: String(decoding: shaData, as: UTF8.self)) else {
                    throw EngineError("Checksum file was unreadable.")
                }
                guard Self.sha256Hex(try Data(contentsOf: zip)) == expected else {
                    throw EngineError("Checksum did not match. Nothing was installed.")
                }
                return zip
            }, progress: { self.phase = $0 == "unpacking" ? .unpacking : .launching })
            phase = .healthy
            return true
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
        return false
    }

    private func synchronize() {
        installedVersion = lifecycle.installedVersion ?? lifecycle.installed()
        running = lifecycle.running
        runDetail = lifecycle.statusDetail()
    }

    private func releaseForTag(_ tag: String) async throws -> ReleaseInfo {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(UpdateChecker.repo)/releases/tags/\(tag)")!)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await lifecycle.operations.request(request)
        guard response.statusCode == 200 else {
            throw EngineError("No release \(tag) on GitHub (HTTP \(response.statusCode)).")
        }
        let release = try JSONDecoder().decode(ReleaseInfo.self, from: data)
        guard release.tag_name == tag else { throw EngineError("The engine release version did not match.") }
        return release
    }

    static func plistTemplate() -> String? {
        guard let url = VeraResources.url("com.vera.engine.plist", ext: "template") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func renderPlist(_ template: String, home: String, binaryPath: String, port: Int) -> String {
        let homeURL = URL(fileURLWithPath: home)
        let layout = EngineLayout(root: homeURL.appendingPathComponent(".vera"), home: homeURL)
        guard let data = try? layout.plist(binary: URL(fileURLWithPath: binaryPath), port: port) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func expectedSha(fromAsset text: String) -> String? {
        let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).first
        let hex = token.map { String($0).lowercased() }
        guard let hex, hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    static func needsEngineUpdate(installed: String?, app: String) -> Bool {
        guard let installed else { return true }
        return Semver.compare(installed, app) != 0
    }

    static func versionsToPrune(_ versions: [String]) -> [String] {
        let sorted = versions.sorted { Semver.compare($0, $1) > 0 }
        return sorted.count <= 2 ? [] : Array(sorted[2...])
    }
}

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
