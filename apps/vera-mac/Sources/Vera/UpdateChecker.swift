import SwiftUI
import AppKit


enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    }

    static var isSelfBuilt: Bool {
        current == "0.0.0-dev" || ProcessInfo.processInfo.environment["VERA_NO_UPDATE"] == "1"
    }
}

enum Semver {
    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
                .split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let (pa, pb) = (parts(a), parts(b))
        for i in 0..<max(pa.count, pb.count) {
            let (x, y) = (i < pa.count ? pa[i] : 0, i < pb.count ? pb[i] : 0)
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    static func minor(_ s: String) -> Int {
        let p = s.replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: ".")
        return p.count > 1 ? (Int(p[1].prefix(while: \.isNumber)) ?? 0) : 0
    }
}

struct ReleaseInfo: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browser_download_url: String
    }
    let tag_name: String
    let html_url: String
    let body: String?
    let assets: [Asset]

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var appZip: Asset? { assets.first { $0.name == "Tandem.app.zip" } }
    func asset(named: String) -> Asset? { assets.first { $0.name == named } }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let repo = "DisplacedForest/tandem"

    @Published var available: ReleaseInfo?
    @Published var checking = false
    @Published var installing = false
    @Published var lastResult: String?

    private var timer: Timer?

    func start() {
        guard !AppVersion.isSelfBuilt else { return }
        Task { await check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { await self?.check(manual: false) }
        }
    }

    func check(manual: Bool) async {
        if AppVersion.isSelfBuilt {
            if manual { lastResult = "Built from source. Update with git pull." }
            return
        }
        checking = true
        defer { checking = false }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            let release = try JSONDecoder().decode(ReleaseInfo.self, from: data)
            if Semver.compare(AppVersion.current, release.version) < 0 {
                available = release
                if manual { lastResult = "Update available (\(release.tag_name))" }
            } else {
                available = nil
                if manual { lastResult = "Up to date (\(AppVersion.current))" }
            }
        } catch {
            if manual { lastResult = "Check failed: \(error.localizedDescription)" }
            NSLog("UpdateChecker: \(error.localizedDescription)")
        }
    }

    func install() async {
        guard !installing, let release = available, let asset = release.appZip else { return }
        installing = true
        defer { installing = false }
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("vera-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let url = URL(string: asset.browser_download_url), url.scheme == "https" else {
                throw UpdateError("The update download URL is invalid")
            }
            let (zipTmp, response) = try await URLSession.shared.download(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw UpdateError("The update download failed")
            }
            let zip = tmp.appendingPathComponent("Tandem.app.zip")
            try FileManager.default.moveItem(at: zipTmp, to: zip)
            let expanded = tmp.appendingPathComponent("expanded", isDirectory: true)
            try AppUpdateArchive.extract(zip, to: expanded)
            let staged = expanded.appendingPathComponent("Tandem.app")
            let installed = Bundle.main.bundleURL
            let identifier = Bundle.main.bundleIdentifier ?? "app.vera.mac"
            let version = release.version
            let receipt = try await Task.detached {
                try SafeAppReplacement.replace(source: staged, target: installed,
                                               version: version, identifier: identifier)
            }.value
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"",
                                  "vera-relaunch", String(ProcessInfo.processInfo.processIdentifier), installed.path]
            do {
                try relaunch.run()
            } catch {
                _ = try SafeAppReplacement.rollback(receiptURL: receipt)
                throw error
            }
            NSLog("Update installed; rollback receipt: %@", receipt.path)
            NSApp.terminate(nil)
        } catch {
            lastResult = "Install failed: \(error.localizedDescription)"
        }
    }

}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct UpdateBanner: View {
    @EnvironmentObject var updates: UpdateChecker

    var body: some View {
        if let release = updates.available {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available (\(release.tag_name))")
                        .font(.system(size: 12, weight: .medium))
                    Button("View release notes") { openExternal(release.html_url) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                        .pointerCursor()
                }
                Spacer()
                Button(updates.installing ? "Installing…" : "Install") {
                    Task { await updates.install() }
                }
                .disabled(updates.installing)
                .controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline, lineWidth: 1))
            .padding(.horizontal, 10).padding(.bottom, 6)
        }
    }
}
