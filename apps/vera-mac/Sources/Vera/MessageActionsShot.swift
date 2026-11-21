import SwiftUI
import AppKit

@MainActor
enum MessageActionsShot {
    static let views: Set<String> = ["message-actions", "message-actions-own", "message-actions-top", "message-reaction",
                                     "message-reactions", "message-reply-bar", "message-reply-sent"]

    static func size(_ view: String) -> CGSize {
        view == "message-actions-top" ? CGSize(width: 1180, height: 760) : CGSize(width: 1180, height: 1040)
    }

    static func seed(_ store: ChatStore, view: String) -> MessageActionsModel {
        _ = NativeTaskDeliveryShot.seed(store, view: view == "message-actions-top" ? "result-two-at-once" : "result-message")
        let messages = store.selected?.messages ?? []
        let conversationID = store.veraThreadID
        let ask = messages.first { $0.role == .user }
        let answer = messages.first { $0.role == .assistant && $0.delivery == nil }
        let pressed: Message?
        switch view {
        case "message-actions": pressed = answer
        case "message-actions-own": pressed = ask
        case "message-actions-top": pressed = messages.first { $0.text.hasPrefix("I'll check which") }
        default: pressed = nil
        }
        saveThread(store)
        if view == "message-reaction", let answer { store.toggleReaction(MessageReaction.thumbsUp.emoji, on: answer.id) }
        if view == "message-reactions" { seedReactions(store, messages: messages, answer: answer) }
        if view == "message-reply-bar", let answer { store.selectedID = conversationID; store.startReply(to: answer) }
        if view == "message-reply-sent", let answer { seedReply(store, answer: answer) }
        return MessageActionsModel(open: pressed.map { MessageActionsTarget(messageID: $0.id, conversationID: conversationID) })
    }

    static func saveThread(_ store: ChatStore) {
        guard let id = store.veraThreadID, let messages = store.conversations.first(where: { $0.id == id })?.messages else { return }
        for (ordinal, message) in messages.enumerated() {
            try? store.repository?.saveMessage(message, conversationID: id, ordinal: ordinal)
        }
    }

    static func seedReactions(_ store: ChatStore, messages: [Message], answer: Message?) {
        guard let answer else { return }
        for reaction in [MessageReaction.heart, .thumbsUp, .emphasis] { store.toggleReaction(reaction.emoji, on: answer.id) }
        if let later = messages.last(where: { $0.role == .assistant && $0.id != answer.id }) {
            store.toggleReaction(MessageReaction.check.emoji, on: later.id)
        }
    }

    static func seedReply(_ store: ChatStore, answer: Message) {
        guard let id = store.veraThreadID, let index = store.conversations.firstIndex(where: { $0.id == id }) else { return }
        let start = (store.conversations[index].messages.last?.createdAt ?? Date()).addingTimeInterval(60)
        let ask = Message(role: .user, text: "Already been to the first one", createdAt: start)
        let reply = Message(role: .assistant, text: "Good to know. I'll leave it off next time.", createdAt: start.addingTimeInterval(3))
        let ordinal = store.conversations[index].messages.count
        try? store.repository?.saveMessage(ask, conversationID: id, ordinal: ordinal)
        try? store.repository?.saveMessage(reply, conversationID: id, ordinal: ordinal + 1)
        store.conversations[index].messages += [ask, reply]
        store.recordReply(PendingReply(messageID: answer.id, quote: MessageReplyQuote.source(answer)), messageID: ask.id, conversationID: id)
    }

    static func renderComposer(to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        unsetenv("VERA_ASSISTANT_NAME")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reply-shot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: try? LocalChatRepository(inMemory: true),
                              attachmentStore: NativeAttachmentStore(directory: directory), artifactPersistenceEnabled: false)
        CompanionNameShot.apply(to: store)
        _ = seed(store, view: "message-reply-bar")
        let messages = store.selected?.messages ?? []
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        let size = NSSize(width: 1000, height: 760)
        let root = VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(messages) { MessageRow(message: $0, companionThread: true) }
                }
                .padding(28)
                .frame(maxWidth: ConversationMetrics.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            ComposerField().padding(24).frame(maxWidth: ConversationMetrics.columnWidth)
        }
            .environmentObject(store).environmentObject(config)
            .environment(\.companionName, store.companionDisplayName)
            .frame(width: size.width, height: size.height)
            .background(Theme.conversationBackground).environment(\.colorScheme, scheme)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: AppLocations.checkedOutput(path)); print("wrote \(path)"); exit(0) }
        catch { exit(1) }
    }

    static func render(view: String, to path: String, appearance: String) {
        if view == "message-reply-bar" { renderComposer(to: path, appearance: appearance) }
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        unsetenv("VERA_ASSISTANT_NAME")
        let store = ChatStore()
        CompanionNameShot.apply(to: store)
        let size = size(view)
        let model = seed(store, view: view)
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { [:] }, writeConfiguration: { _ in })
        let content = ShotView(store: store, section: .vera, dotHeader: false, height: size.height,
                               transcript: store.selected?.messages ?? [], width: size.width)
            .environment(\.renderSafe, true)
            .modifier(MessageActionsHost(model: model))
            .environmentObject(store)
            .environmentObject(config)
            .frame(width: size.width, height: size.height)
            .background(Theme.bg)
            .environment(\.colorScheme, scheme)
            .environment(\.companionName, store.companionDisplayName)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: AppLocations.checkedOutput(path))
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
