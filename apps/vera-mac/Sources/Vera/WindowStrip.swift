import AppKit
import SwiftUI

enum WindowStripMetrics {
    static let height: CGFloat = 44
    static let buttonSize: CGFloat = 13
    static let buttonPitch: CGFloat = 22
    static let firstButtonCentre: CGFloat = 23.5
    static let glyphSlot: CGFloat = 26
    static let glyphSize: CGFloat = 14
    static let glyphCentres: [CGFloat] = [99, 131, 164]
    static let fullScreenLeading: CGFloat = 16
    static let dividerHeight: CGFloat = 16
    static let dividerGap: CGFloat = 12
    static let control: CGFloat = 36
    static let controlTop: CGFloat = (height - control) / 2
    static let centre: CGFloat = height / 2
    static let glyphTop: CGFloat = (height - glyphSlot) / 2

    static func buttonsTrailing(buttonSize: CGFloat = buttonSize, pitch: CGFloat = buttonPitch) -> CGFloat {
        firstButtonCentre + 2 * pitch + buttonSize / 2
    }

    static func buttonOrigin(index: Int, size: CGSize = CGSize(width: buttonSize, height: buttonSize),
                             pitch: CGFloat = buttonPitch, containerHeight: CGFloat = height) -> CGPoint {
        CGPoint(x: firstButtonCentre - size.width / 2 + CGFloat(index) * pitch, y: (containerHeight - size.height) / 2)
    }

    static func fullScreenShift(_ fullScreen: Bool) -> CGFloat {
        fullScreen ? glyphCentres[0] - glyphSlot / 2 - fullScreenLeading : 0
    }

    static func glyphLeading(_ index: Int, fullScreen: Bool) -> CGFloat {
        glyphCentres[index] - glyphSlot / 2 - fullScreenShift(fullScreen)
    }

    static func dividerLeading(sidebarWide: Bool, fullScreen: Bool) -> CGFloat {
        sidebarWide ? VeraSidebar.expandedWidth : glyphLeading(2, fullScreen: fullScreen) + glyphSlot + dividerGap
    }
}

struct WindowHistory: Equatable {
    struct Stop: Equatable {
        let section: AppSection
        var conversationID: String? = nil

        init(section: AppSection, conversationID: String?) {
            self.section = section
            self.conversationID = section == .chat ? conversationID : nil
        }
    }

    static let cap = 50
    private(set) var stops: [Stop] = []
    private(set) var index = -1

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < stops.count - 1 }
    var current: Stop? { stops.indices.contains(index) ? stops[index] : nil }

    mutating func visit(_ stop: Stop) {
        if current == stop { return }
        if index < stops.count - 1 { stops.removeSubrange((index + 1)...) }
        stops.append(stop)
        if stops.count > Self.cap { stops.removeFirst(stops.count - Self.cap) }
        index = stops.count - 1
    }

    mutating func back() -> Stop? {
        guard canGoBack else { return nil }
        index -= 1
        return stops[index]
    }

    mutating func forward() -> Stop? {
        guard canGoForward else { return nil }
        index += 1
        return stops[index]
    }

    mutating func forget(conversationID: String) {
        let kept = current
        stops.removeAll { $0.conversationID == conversationID }
        var merged: [Stop] = []
        for stop in stops where merged.last != stop { merged.append(stop) }
        stops = merged
        index = kept.flatMap { stops.lastIndex(of: $0) } ?? stops.count - 1
    }
}

struct WindowStripGlyph: View {
    let icon: InterfaceIcon
    var bright = false
    var dimmed = false

    var body: some View {
        InterfaceIconView(icon: icon, size: WindowStripMetrics.glyphSize)
            .foregroundStyle(bright ? Theme.textPrimary : Theme.textSecondary)
            .opacity(dimmed ? 0.35 : 1)
            .frame(width: WindowStripMetrics.glyphSlot, height: WindowStripMetrics.glyphSlot)
            .contentShape(Rectangle())
    }
}

struct WindowStripGlyphStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { GlyphBody(configuration: configuration) }

    private struct GlyphBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(enabled && (hovering || configuration.isPressed) ? Theme.textPrimary : Theme.textSecondary)
                .opacity(enabled ? 1 : 0.35)
                .frame(width: WindowStripMetrics.glyphSlot, height: WindowStripMetrics.glyphSlot)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

struct WindowStripControls: View {
    @Environment(\.renderSafe) private var renderSafe
    let collapsed: Bool
    let fullScreen: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let back: @MainActor () -> Void
    let forward: @MainActor () -> Void
    let toggle: @MainActor () -> Void

    static let backTitle = "Back"
    static let forwardTitle = "Forward"

    var body: some View {
        ZStack(alignment: .topLeading) {
            backGlyph.offset(x: WindowStripMetrics.glyphLeading(0, fullScreen: fullScreen))
            forwardGlyph.offset(x: WindowStripMetrics.glyphLeading(1, fullScreen: fullScreen))
            toggleGlyph.offset(x: WindowStripMetrics.glyphLeading(2, fullScreen: fullScreen))
        }
        .offset(y: WindowStripMetrics.glyphTop)
    }

    @ViewBuilder private var backGlyph: some View {
        if renderSafe {
            WindowStripGlyph(icon: .goBack, dimmed: !canGoBack).accessibilityLabel(Self.backTitle)
        } else {
            Button { back() } label: { InterfaceIconView(icon: .goBack, size: WindowStripMetrics.glyphSize) }
                .buttonStyle(WindowStripGlyphStyle()).disabled(!canGoBack)
                .help(Self.backTitle).accessibilityLabel(Self.backTitle)
        }
    }

    @ViewBuilder private var forwardGlyph: some View {
        if renderSafe {
            WindowStripGlyph(icon: .goForward, dimmed: !canGoForward).accessibilityLabel(Self.forwardTitle)
        } else {
            Button { forward() } label: { InterfaceIconView(icon: .goForward, size: WindowStripMetrics.glyphSize) }
                .buttonStyle(WindowStripGlyphStyle()).disabled(!canGoForward)
                .help(Self.forwardTitle).accessibilityLabel(Self.forwardTitle)
        }
    }

    @ViewBuilder private var toggleGlyph: some View {
        let title = ConversationTopBarModel.sidebarTitle(collapsed: collapsed)
        let icon = ConversationTopBarModel.sidebarIcon(collapsed: collapsed)
        if renderSafe {
            WindowStripGlyph(icon: icon).accessibilityLabel(title)
        } else {
            Button { toggle() } label: { InterfaceIconView(icon: icon, size: WindowStripMetrics.glyphSize) }
                .buttonStyle(WindowStripGlyphStyle())
                .help(title).accessibilityLabel(title)
        }
    }
}

struct WindowStripChrome: ViewModifier {
    let sidebarWide: Bool
    let collapsed: Bool
    let fullScreen: Bool
    var standIns = false
    let canGoBack: Bool
    let canGoForward: Bool
    let back: @MainActor () -> Void
    let forward: @MainActor () -> Void
    let toggle: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .background(Theme.bg)
            .overlay(alignment: .topLeading) {
                WindowStripControls(collapsed: collapsed, fullScreen: fullScreen, canGoBack: canGoBack, canGoForward: canGoForward,
                                    back: back, forward: forward, toggle: toggle)
            }
            .overlay(alignment: .topLeading) {
                Rectangle().fill(Theme.hairline)
                    .frame(width: 1, height: WindowStripMetrics.dividerHeight)
                    .offset(x: WindowStripMetrics.dividerLeading(sidebarWide: sidebarWide, fullScreen: fullScreen),
                            y: (WindowStripMetrics.height - WindowStripMetrics.dividerHeight) / 2)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if standIns, !fullScreen { WindowButtonStandIns() }
            }
    }
}

struct WindowStripPane: ViewModifier {
    let conversation: Bool

    func body(content: Content) -> some View {
        if conversation {
            content
        } else {
            content.padding(.top, WindowStripMetrics.height)
        }
    }
}

struct WindowButtonStandIns: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { index in
                let origin = WindowStripMetrics.buttonOrigin(index: index)
                Circle().fill(Theme.textSecondary.opacity(0.55))
                    .frame(width: WindowStripMetrics.buttonSize, height: WindowStripMetrics.buttonSize)
                    .offset(x: origin.x, y: origin.y)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct WindowButtonsPlacer: NSViewRepresentable {
    @Binding var fullScreen: Bool

    func makeCoordinator() -> Coordinator { Coordinator(fullScreen: $fullScreen) }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.place() }

    final class AnchorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(window)
        }
    }

    @MainActor final class Coordinator {
        private let fullScreen: Binding<Bool>
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(fullScreen: Binding<Bool>) { self.fullScreen = fullScreen }

        func attach(_ window: NSWindow?) {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            self.window = window
            guard let window else { return }
            let names = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            place()
        }

        func place() {
            guard let window else { return }
            let full = window.styleMask.contains(.fullScreen)
            if fullScreen.wrappedValue != full {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.fullScreen.wrappedValue = full }
                }
            }
            guard !full, let close = window.standardWindowButton(.closeButton),
                  let minimise = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let bar = close.superview, let container = bar.superview, let frameView = container.superview else { return }
            let height = WindowStripMetrics.height
            var frame = container.frame
            let top = frameView.isFlipped ? 0 : frameView.bounds.height - height
            if frame.height != height || frame.origin.y != top {
                frame.size.height = height
                frame.origin.y = top
                container.frame = frame
            }
            if bar.frame != container.bounds { bar.frame = container.bounds }
            let measured = minimise.frame.minX - close.frame.minX
            let pitch = measured > 0 ? measured : WindowStripMetrics.buttonPitch
            for (index, button) in [close, minimise, zoom].enumerated() {
                let origin = WindowStripMetrics.buttonOrigin(index: index, size: button.frame.size, pitch: pitch, containerHeight: bar.bounds.height)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}
