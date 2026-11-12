import SwiftUI
import AppKit

@MainActor
enum MessageActionsShot {
    static let views: Set<String> = ["message-actions", "message-actions-own", "message-actions-top", "message-reaction"]

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
        if view == "message-reaction", let answer { store.messageRatings[answer.id] = "up" }
        return MessageActionsModel(open: pressed.map { MessageActionsTarget(message: $0, conversationID: conversationID) })
    }

    static func render(view: String, to path: String, appearance: String) {
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
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
