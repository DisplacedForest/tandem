import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CompanionPanelController: ObservableObject {
    static let size = CGSize(width: 560, height: 440)

    @Published private(set) var isVisible = false

    private let store: ChatStore
    private let config: ConfigStore
    private let presence: CompanionPresence
    private var panel: CompanionPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(store: ChatStore, config: ConfigStore, presence: CompanionPresence? = nil) {
        self.store = store
        self.config = config
        self.presence = presence ?? CompanionPresence(store: store)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        position(panel)
        store.prepareCompanionThread(askForName: false)
        store.markCompanionSeen()
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
        installKeyMonitor()
        store.companionFocusTick &+= 1
    }

    func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        isVisible = false
    }

    private func makePanel() -> CompanionPanel {
        let panel = CompanionPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let root = CompanionPanelView()
            .modifier(CompanionAttentionWindow())
            .modifier(CompanionEnvironment(store: store, config: config, presence: presence))
            .environmentObject(store)
            .environmentObject(config)
            .environmentObject(self)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let x = visible.midX - Self.size.width / 2
        let top = visible.maxY - visible.height / 4
        let y = max(visible.minY, top - Self.size.height)
        panel.setFrame(NSRect(x: x, y: y, width: Self.size.width, height: Self.size.height), display: true)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isVisible, let panel, event.window === panel else { return event }
        if event.keyCode == 53 {
            hide()
            return nil
        }
        guard panel.isKeyWindow,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers == "v" else { return event }
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) != nil { return event }
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.filter(\.isFileURL) ?? []
        if !fileURLs.isEmpty {
            store.addCompanionFiles(fileURLs)
            return nil
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            let datas = images.compactMap(\.pngData)
            if !datas.isEmpty {
                store.addCompanionPastedImages(datas)
                return nil
            }
        }
        return event
    }
}

@MainActor
final class CompanionCoordinator: ObservableObject {
    let panel: CompanionPanelController
    private let config: ConfigStore
    private var hotkey: CompanionHotkey?

    init(store: ChatStore, config: ConfigStore, presence: CompanionPresence? = nil) {
        self.config = config
        self.panel = CompanionPanelController(store: store, config: config, presence: presence)
    }

    func toggle() { panel.toggle() }

    func start() {
        guard hotkey == nil else { return }
        let hotkey = CompanionHotkey { [weak self] in self?.toggle() }
        self.hotkey = hotkey
        hotkey.start(config: config)
    }

    @discardableResult
    func apply(_ shortcut: CompanionShortcut?) -> String? {
        if hotkey == nil { start() }
        guard let hotkey else { return CompanionHotkey.failureMessage }
        return hotkey.apply(shortcut, config: config)
    }
}

struct CompanionPanelView: View {
    var renderSafe = false
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var controller: CompanionPanelController
    @Environment(\.openWindow) private var openWindow
    @FocusState private var editorFocused: Bool
    @State private var dropTargeted = false

    private var thread: Conversation? {
        guard let id = store.veraThreadID else { return nil }
        return store.conversations.first { $0.id == id }
    }

    private var recent: [Message] {
        Array((thread?.messages ?? []).filter { message in
            guard TranscriptVisibility.shows(message), message.contentType != .runOrigin else { return false }
            return message.delivery == nil || !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.suffix(6))
    }

    private var canSend: Bool {
        !store.companionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.companionAttachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            transcript
            Rectangle().fill(Theme.hairline).frame(height: 1)
            composer
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bg))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(dropTargeted ? Theme.accent : Theme.hairline, lineWidth: dropTargeted ? 2 : 1))
        .frame(width: CompanionPanelController.size.width, height: CompanionPanelController.size.height)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDroppedFiles(providers)
            return true
        }
        .onChange(of: store.companionFocusTick) { _, _ in editorFocused = true }
        .onChange(of: store.companionUnreadCount) { _, count in
            if count > 0, NSApp.keyWindow is CompanionPanel { store.markCompanionSeen() }
        }
        .preferredColorScheme(renderSafe ? nil : config.colorSchemeOverride)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            CompanionNamedText(template: CompanionSentence.placeholder)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            let unread = store.companionUnreadCount
            if unread > 0 {
                Text("\(unread) new")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent))
            }
            Spacer()
            if !store.companionApprovalWaiting {
                Button(action: openInMain) {
                    Text("Open in Tandem")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in Tandem")
            }
            Button { controller.hide() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private static let bottomAnchor = "companion-bottom"

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recent.isEmpty {
                CompanionNamedText(template: "Ask anything. It goes to {name}'s thread.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else {
                ForEach(recent) { message in
                    CompanionMessageRow(message: message, onOpen: openInMain)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var transcript: some View {
        if renderSafe {
            ShotSafeScroll(renderSafe: true) { transcriptContent }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    transcriptContent
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .onAppear { scrollToBottom(proxy) }
                .onChange(of: recent.last?.id) { _, _ in scrollToBottom(proxy) }
                .onChange(of: recent.last?.text) { _, _ in scrollToBottom(proxy) }
                .onChange(of: store.companionFocusTick) { _, _ in scrollToBottom(proxy) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
    }

    private var approvalBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Waiting for your approval in Tandem.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            Button(action: openApproval) {
                Text("Open in Tandem")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open in Tandem to approve")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .accessibilityElement(children: .contain)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.companionApprovalWaiting {
                approvalBanner
            }
            CompanionWorkingLine(work: store.companionBackgroundWork.current, size: 12)
            if !store.companionAttachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(store.companionAttachments) { attachment in
                        CompanionAttachmentChip(attachment: attachment) {
                            store.removeCompanionAttachment(attachment.id)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if let error = store.companionErrorLine {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    CompanionLineText(line: error).font(.system(size: 11))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                editor
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(canSend ? Theme.onAccent : Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(canSend ? Theme.accent : Theme.surface))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var editorHeight: CGFloat {
        let lines = max(1, store.companionDraft.split(separator: "\n", omittingEmptySubsequences: false).count)
        return min(120, max(44, CGFloat(lines) * 18 + 16))
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if renderSafe {
                Text(store.companionDraft)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 5).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $store.companionDraft)
                    .modifier(CompanionComposerAttention(focused: editorFocused, draft: store.companionDraft))
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Message")
                    .onKeyPress(.return, phases: .down) { press in
                        if ComposerEditing.composing(ComposerEditing.editor) { return .ignored }
                        if press.modifiers.contains(.shift) { return .ignored }
                        send()
                        return .handled
                    }
            }
            if store.companionDraft.isEmpty {
                CompanionNamedText(template: "Message {name}…")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: editorHeight)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }

    private func send() {
        if store.sendCompanion() { editorFocused = true }
    }

    private func openInMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        store.openVeraThread()
        controller.hide()
    }

    private func openApproval() {
        openInMain()
        store.revealCompanionApproval()
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in store.addCompanionFiles([url]) }
            }
        }
    }
}

private struct CompanionMessageRow: View {
    let message: Message
    let onOpen: () -> Void

    private var failed: Bool {
        message.text.isEmpty && message.state != .streaming && message.failure != nil
    }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(message.text.isEmpty ? (message.attachments.first?.name ?? "") : message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(6)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            }
        } else if failed {
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't reply.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if let failure = message.failure, !failure.isEmpty {
                    Text(SavedWording.current(failure))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
                Button(action: onOpen) {
                    Text("Open in Tandem")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in Tandem to see the failed reply")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if message.state == .streaming && message.text.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Thinking")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            Text(message.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CompanionAttachmentChip: View {
    @ObservedObject var attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail = attachment.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable().scaledToFill()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: attachment.kind == .image ? "photo" : "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(attachment.name)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
    }
}
