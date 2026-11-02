import SwiftUI
import AppKit

/// Resolves the SwiftPM resource bundle WITHOUT the generated `Bundle.module` accessor.
/// That accessor's search paths vary by toolchain — some emit one that probes only the app
/// root and the machine-specific build directory, which fatalErrors in a packaged app built
/// on another machine. This probes every real layout and degrades to nil instead of crashing.
enum VeraResources {
    static let bundle: Bundle? = {
        let name = "Vera_Vera.bundle"
        let candidates = [
            Bundle.main.resourceURL,                                  // packaged .app (Contents/Resources)
            Bundle.main.executableURL?.deletingLastPathComponent(),   // swift run / .build binaries
            Bundle.main.bundleURL,                                    // app root
        ]
        for c in candidates {
            if let u = c?.appendingPathComponent(name), let b = Bundle(url: u) { return b }
        }
        return nil
    }()

    static func url(_ name: String, ext: String) -> URL? {
        bundle?.url(forResource: name, withExtension: ext)
    }
}

enum Brand {
    static let glyph: NSImage? = load("vera-mark")
    static let icon: NSImage? = load("vera-icon")

    private static func load(_ name: String) -> NSImage? {
        guard let url = VeraResources.url(name, ext: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        return img
    }
}

struct VeraMark: View {
    var size: CGFloat = 26
    var animated: Bool = false
    @StateObject private var controller = TandemMotionController()

    var body: some View {
        Group {
            if animated {
                AnimatedTandemLogo(controller: controller)
            } else {
                TandemLogoView(pose: .rest)
            }
        }
        .frame(width: size * TandemLogoGeometry.aspectRatio, height: size)
        .accessibilityElement()
        .accessibilityLabel("Tandem")
        .onAppear { sync() }
        .onChange(of: animated) { _, _ in sync() }
    }

    private func sync() {
        if animated { controller.play("Breathe", loop: true) } else { controller.stop() }
    }
}

struct TandemLogoMark: View {
    var size: CGFloat

    var body: some View {
        TandemLogoView(pose: .rest)
            .frame(width: size * TandemLogoGeometry.aspectRatio, height: size)
            .accessibilityElement()
            .accessibilityLabel("Tandem")
    }
}

struct CompanionAvatar: View {
    var size: CGFloat
    @Environment(\.companionName) private var name
    @Environment(\.companionAppearance) private var appearance
    @Environment(\.companionLiveState) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CompanionAvatarView(appearance: appearance, state: state, size: size, name: name, reduceMotion: reduceMotion)
    }
}

private struct CompanionNameKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var companionName: String? {
        get { self[CompanionNameKey.self] }
        set { self[CompanionNameKey.self] = newValue }
    }
}

private struct CompanionAppearanceKey: EnvironmentKey {
    static let defaultValue = CompanionAppearance.default
}

extension EnvironmentValues {
    var companionAppearance: CompanionAppearance {
        get { self[CompanionAppearanceKey.self] }
        set { self[CompanionAppearanceKey.self] = newValue }
    }
}

private struct CompanionLiveStateKey: EnvironmentKey {
    static let defaultValue = CompanionState.ready
}

extension EnvironmentValues {
    var companionLiveState: CompanionState {
        get { self[CompanionLiveStateKey.self] }
        set { self[CompanionLiveStateKey.self] = newValue }
    }
}
