import SwiftUI
import AppKit

struct MessageActionsHost: ViewModifier {
    static let space = "message-actions-host"

    @EnvironmentObject private var store: ChatStore
    @State private var model: MessageActionsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: MessageActionsModel = MessageActionsModel()) {
        _model = State(initialValue: model)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.messageActions, model)
            .coordinateSpace(.named(Self.space))
            .overlayPreferenceValue(MessageActionsAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    if let target = model.open, let anchor {
                        MessageActionsOverlay(target: target, frame: proxy[anchor],
                                              bounds: CGRect(origin: .zero, size: proxy.size), model: model)
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.open?.message.id)
            }
            .background(MessageActionsEventBridge(model: model))
            .onChange(of: store.selectedID) { model.close(); model.selecting = nil }
            .onChange(of: store.section) { model.close(); model.selecting = nil }
    }
}

struct MessageActionsOverlay: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.colorScheme) private var scheme
    let target: MessageActionsTarget
    let frame: CGRect
    let bounds: CGRect
    let model: MessageActionsModel

    private var cutout: CGRect {
        guard let visible = model.visibleFrame(target.message.id) else { return frame }
        let clipped = frame.intersection(visible)
        return clipped.isNull ? frame : clipped
    }

    var body: some View {
        let placement = MessageActionsPlacement.place(message: frame, bounds: bounds,
                                                      row: MessageActionsMetrics.rowSize, menu: MessageActionsMetrics.menuSize)
        ZStack(alignment: .topLeading) {
            MessageActionsDim(cutout: cutout)
                .fill(Color.black.opacity(scheme == .dark ? 0.55 : 0.3), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture { model.close() }
                .accessibilityHidden(true)
            MessageReactionRow(marks: MessageReaction.marks(rating: store.messageRatings[target.message.id])) { react($0) }
                .offset(x: placement.row.x, y: placement.row.y)
            MessageActionsMenu { perform($0) }
                .offset(x: placement.menu.x, y: placement.menu.y)
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    }

    private func react(_ reaction: MessageReaction) {
        MessageActionsPerform.react(reaction, to: target.message, conversationID: target.conversationID, store: store)
        model.close()
    }

    private func perform(_ action: MessageMenuAction) {
        switch action {
        case .copy:
            MessageActions.copy(target.message)
            model.close()
        case .selectText:
            model.beginSelecting(target.message.id)
        }
    }
}

@MainActor
enum MessageActionsPerform {
    static func react(_ reaction: MessageReaction, to message: Message, conversationID: String?, store: ChatStore) {
        let conversation = store.conversations.first { $0.id == conversationID } ?? store.selected
        guard let conversation else { return }
        store.rateMessage(message, in: conversation, reaction.rating)
    }
}

struct MessageActionsDim: Shape {
    let cutout: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: cutout, cornerSize: CGSize(width: ConversationMetrics.bubbleRadius, height: ConversationMetrics.bubbleRadius),
                            style: .continuous)
        return path
    }
}

struct MessageReactionRow: View {
    let marks: [MessageReaction]
    let onPick: (MessageReaction) -> Void

    var body: some View {
        HStack(spacing: MessageActionsMetrics.rowSpacing) {
            ForEach(MessageReaction.offered) { reaction in
                MessageReactionButton(reaction: reaction, on: marks.contains(reaction)) { onPick(reaction) }
            }
        }
        .padding(MessageActionsMetrics.rowPadding)
        .frame(width: MessageActionsMetrics.rowSize.width, height: MessageActionsMetrics.rowSize.height)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MessageActionsMetrics.rowLabel)
        .accessibilityValue(MessageReaction.onAnnouncement(marks))
    }
}

private struct MessageReactionButton: View {
    let reaction: MessageReaction
    let on: Bool
    let go: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: go) {
            Text(reaction.emoji)
                .font(.system(size: 22))
                .frame(width: MessageActionsMetrics.itemSize, height: MessageActionsMetrics.itemSize)
                .background(Circle().fill(on ? Theme.surfaceSelected : (hovering ? Theme.surfaceHover : Color.clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(reaction.label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(reaction.label)
    }
}

struct MessageActionsMenu: View {
    let onPick: (MessageMenuAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(MessageMenuAction.offered) { action in
                MessageActionsMenuRow(action: action) { onPick(action) }
            }
        }
        .padding(MessageActionsMetrics.menuPadding)
        .frame(width: MessageActionsMetrics.menuSize.width, height: MessageActionsMetrics.menuSize.height)
        .background(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: ConversationMetrics.cardRadius, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MessageActionsMetrics.menuLabel)
    }
}

private struct MessageActionsMenuRow: View {
    let action: MessageMenuAction
    let go: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: go) {
            HStack(spacing: 12) {
                Image(systemName: action.symbol)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(action.label)
                    .font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: MessageActionsMetrics.menuRowHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.surfaceHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(action.label)
    }
}

struct MessageReactionMark: View {
    let marks: [MessageReaction]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(marks) { Text($0.emoji).font(.system(size: 12)) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(marks.map(\.label).joined(separator: ", "))
    }
}

struct MessageActionsBubble: ViewModifier {
    @Environment(\.messageActions) private var model
    @EnvironmentObject private var store: ChatStore
    let message: Message
    let companionThread: Bool
    let fill: Color
    let trailing: Bool
    let selectableText: String

    func body(content: Content) -> some View {
        if MessageActions.offered(companionThread: companionThread), let model {
            decorated(content, model: model)
        } else {
            content
        }
    }

    private func decorated(_ content: Content, model: MessageActionsModel) -> some View {
        let isOpen = model.open?.message.id == message.id
        let marks = MessageReaction.marks(rating: store.messageRatings[message.id])
        let conversationID = store.veraThreadID
        return Group {
            if model.selecting == message.id {
                MessageSelectionText(text: MessageActions.selectableText(message)) { model.endSelecting(message.id) }
                    .padding(.horizontal, ConversationMetrics.bubblePaddingH)
                    .padding(.vertical, ConversationMetrics.bubblePaddingV)
                    .background(fill)
                    .clipShape(RoundedRectangle(cornerRadius: ConversationMetrics.bubbleRadius, style: .continuous))
            } else {
                content
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            let frame = proxy.frame(in: .named(MessageActionsHost.space))
            let local = CGRect(origin: .zero, size: proxy.size)
            let shown = proxy.bounds(of: .scrollView).map { local.intersection($0) } ?? local
            return shown.isNull ? .zero : shown.offsetBy(dx: frame.minX, dy: frame.minY)
        } action: { frame in
            model.register(message, conversationID: conversationID, frame: frame)
        }
        .onDisappear { model.unregister(message.id) }
        .anchorPreference(key: MessageActionsAnchorKey.self, value: .bounds) { isOpen ? $0 : nil }
        .overlay(alignment: trailing ? .bottomTrailing : .bottomLeading) {
            if !marks.isEmpty {
                MessageReactionMark(marks: marks)
                    .padding(trailing ? .trailing : .leading, 12)
                    .offset(y: MessageActionsMetrics.markOverhang)
            }
        }
        .padding(.bottom, marks.isEmpty ? 0 : MessageActionsMetrics.markOverhang)
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            ForEach(MessageMenuAction.offered) { action in
                Button(action.label) { perform(action, model: model) }
            }
            ForEach(MessageReaction.offered) { reaction in
                Button(reaction.label) {
                    MessageActionsPerform.react(reaction, to: message, conversationID: conversationID, store: store)
                }
            }
        }
        .focusable(interactions: .activate)
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.control) else { return .ignored }
            model.present(message, conversationID: conversationID)
            return .handled
        }
    }

    private func perform(_ action: MessageMenuAction, model: MessageActionsModel) {
        switch action {
        case .copy: MessageActions.copy(message)
        case .selectText: model.beginSelecting(message.id)
        }
    }
}

struct MessageSelectionText: NSViewRepresentable {
    let text: String
    let onEnd: () -> Void

    final class SelectionView: NSTextView {
        var onEnd: () -> Void = {}
        var selectsOnArrival = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard selectsOnArrival, let window else { return }
            selectsOnArrival = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                window.makeFirstResponder(self)
                self.selectAll(nil)
            }
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                let end = onEnd
                DispatchQueue.main.async { end() }
            }
            return resigned
        }

        override func cancelOperation(_ sender: Any?) {
            window?.makeFirstResponder(nil)
        }
    }

    func makeNSView(context: Context) -> SelectionView {
        let view = SelectionView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.font = .systemFont(ofSize: ConversationMetrics.bodySize)
        view.textColor = NSColor(Theme.textPrimary)
        view.string = text
        view.onEnd = onEnd
        view.setAccessibilityLabel(text)
        return view
    }

    func updateNSView(_ view: SelectionView, context: Context) {
        if view.string != text { view.string = text }
        view.onEnd = onEnd
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SelectionView, context: Context) -> CGSize? {
        let width = proposal.width ?? ConversationMetrics.columnWidth
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }
}

struct MessageActionsEventBridge: NSViewRepresentable {
    let model: MessageActionsModel

    final class BridgeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        let model: MessageActionsModel
        weak var view: NSView?
        var monitor: Any?
        var watcher: Task<Void, Never>?

        init(model: MessageActionsModel) { self.model = model }

        func install() {
            guard monitor == nil else { return }
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .scrollWheel, .keyDown]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
                return consumed ? nil : event
            }
        }

        func remove() {
            watcher?.cancel()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func point(_ event: NSEvent) -> CGPoint? {
            guard let view, let window = view.window, event.window === window, window.attachedSheet == nil else { return nil }
            let local = view.convert(event.locationInWindow, from: nil)
            return CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
        }

        private func consumes(_ event: NSEvent) -> Bool {
            switch event.type {
            case .keyDown:
                return key(event)
            case .scrollWheel:
                model.close()
                return false
            case .rightMouseDown:
                return secondary(event)
            case .leftMouseDown:
                if event.modifierFlags.contains(.control) { return secondary(event) }
                begin(event)
                return false
            case .leftMouseDragged:
                model.hold.moved(to: NSEvent.mouseLocation)
                return false
            case .leftMouseUp:
                model.hold.release()
                return false
            default:
                return false
            }
        }

        private func key(_ event: NSEvent) -> Bool {
            let escape = event.keyCode == 53
            guard escape, model.open != nil else { return false }
            model.close()
            return true
        }

        private func secondary(_ event: NSEvent) -> Bool {
            guard model.open == nil, let point = point(event), let bubble = model.bubble(at: point) else { return false }
            model.present(bubble.message, conversationID: bubble.conversationID)
            return true
        }

        private func begin(_ event: NSEvent) {
            watcher?.cancel()
            model.hold.reset()
            guard model.open == nil, let point = point(event), let bubble = model.bubble(at: point) else { return }
            model.hold.down(at: NSEvent.mouseLocation, time: ProcessInfo.processInfo.systemUptime)
            let id = bubble.message.id
            watcher = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(40))
                    guard let self, !Task.isCancelled else { return }
                    let buttonUp = NSEvent.pressedMouseButtons & 1 == 0
                    if buttonUp { self.model.hold.release() }
                    self.model.hold.moved(to: NSEvent.mouseLocation)
                    if self.model.hold.abandoned { return }
                    if self.model.hold.opens(at: ProcessInfo.processInfo.systemUptime) {
                        guard let current = self.model.bubbles[id] else { return }
                        self.model.present(current.message, conversationID: current.conversationID)
                        return
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        context.coordinator.view = view
    }

    static func dismantleNSView(_ view: BridgeView, coordinator: Coordinator) {
        coordinator.remove()
    }
}
