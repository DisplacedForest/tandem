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

struct CompanionSubject: Equatable, Sendable {
    let name: String?

    init(_ name: String?) {
        self.name = CompanionSentence.savedName(name)
    }

    var inline: String { name ?? CompanionSentence.unnamedSubject }
    var leading: String { CompanionSentence.subject(name: name, after: "") }
    var threadTitle: String { leading }
    var menuBarTitle: String { name ?? "Tandem" }
    var thread: String { "\(inline)'s thread" }
}

enum CompanionSentence {
    static let placeholder = "{name}"
    static let unnamedSubject = "your companion"

    static func savedName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func startsSentence(after prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return true }
        return ".!?".contains(last) && prefix.hasSuffix(" ")
    }

    static func subject(name: String?, after prefix: String) -> String {
        if let saved = savedName(name) { return saved }
        return startsSentence(after: prefix) ? unnamedSubject.prefix(1).uppercased() + unnamedSubject.dropFirst() : unnamedSubject
    }

    static func plain(_ template: String, name: String?) -> String {
        var result = ""
        for (index, part) in parts(template).enumerated() {
            if index > 0 { result += subject(name: name, after: result) }
            result += part
        }
        return result
    }

    static func parts(_ template: String) -> [String] {
        template.components(separatedBy: placeholder)
    }
}

enum CompanionLinePart: Equatable, Sendable {
    case name
    case text(String)
}

enum CompanionLine: Equatable, Sendable {
    case named(String)
    case literal(String)
    case namedThenText(String, String)
    case parts([CompanionLinePart])

    var parts: [CompanionLinePart] {
        switch self {
        case .named(let template): Self.templateParts(template)
        case .namedThenText(let template, let text): Self.templateParts(template) + [.text(text)]
        case .literal(let text): [.text(text)]
        case .parts(let parts): parts
        }
    }

    func plain(name: String?) -> String {
        var result = ""
        for part in parts {
            switch part {
            case .name: result += CompanionSentence.subject(name: name, after: result)
            case .text(let text): result += text
            }
        }
        return result
    }

    private static func templateParts(_ template: String) -> [CompanionLinePart] {
        var parts: [CompanionLinePart] = []
        for (index, piece) in CompanionSentence.parts(template).enumerated() {
            if index > 0 { parts.append(.name) }
            if !piece.isEmpty { parts.append(.text(String(piece))) }
        }
        return parts
    }
}

enum CompanionSavedText {
    static let questionLead = CompanionSentence.placeholder + " wants to "

    static func question(_ saved: String, companionWork: Bool) -> CompanionLine {
        guard companionWork, saved.hasPrefix(questionLead) else { return .literal(saved) }
        return .parts([.name, .text(String(saved.dropFirst(CompanionSentence.placeholder.count)))])
    }
}

struct CompanionLineText: View {
    var line: CompanionLine
    @Environment(\.companionName) private var name
    @Environment(\.companionAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme

    private var sentence: Text {
        var prefix = ""
        var text = Text(verbatim: "")
        for part in line.parts {
            switch part {
            case .name:
                let subject = CompanionSentence.subject(name: name, after: prefix)
                if CompanionSentence.savedName(name) != nil {
                    text = text + Text(verbatim: subject).bold().foregroundStyle(appearance.color.textColor(for: colorScheme))
                } else {
                    text = text + Text(verbatim: subject)
                }
                prefix += subject
            case .text(let literal):
                text = text + Text(verbatim: literal)
                prefix += literal
            }
        }
        return text
    }

    var body: some View {
        if case .literal(let text) = line {
            Text(verbatim: text)
        } else {
            sentence
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(line.plain(name: name))
        }
    }
}

struct CompanionNamedText: View {
    var template: String
    var suffix = ""

    var body: some View {
        CompanionLineText(line: suffix.isEmpty ? .named(template) : .namedThenText(template, suffix))
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
