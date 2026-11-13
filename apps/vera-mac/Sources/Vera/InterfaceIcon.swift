import SwiftUI
import AppKit

enum InterfaceIcon: String, CaseIterable, Sendable {
    case search
    case add
    case sidebar
    case sidebarShown
    case more
    case home
    case chat
    case settings
    case projects
    case projectOpen
    case library
    case scheduled
    case plugins
    case pulse
    case workflows
    case activity
    case memory
    case companion
    case attention
    case update
    case clear
    case pin
    case close
    case info
    case warning
    case connect
    case attach
    case folder
    case research
    case document
    case image
    case reminders
    case rules
    case tool
    case voice
    case dictate
    case dictating
    case send
    case stop
    case done
    case stopped
    case paused
    case question
    case failed
    case needsYou
    case declined
    case refused
    case timedOut
    case terminal
    case edit
    case fileAdded
    case moved
    case folderAdded
    case trash
    case link
    case copy
    case reply
    case selectText
    case addReaction
    case good
    case goodChosen
    case bad
    case badChosen
    case expand
    case collapse
    case next
    case back
    case choose
    case latest
    case bridged
    case withheld
    case checkboxOn
    case checkboxOff
    case radioOn
    case radioOff
    case tick
    case pauseMark

    var resource: String {
        switch self {
        case .search: "interface-search"
        case .add: "interface-add"
        case .sidebar: "interface-sidebar"
        case .sidebarShown: "interface-sidebar-shown"
        case .more: "interface-more"
        case .home: "interface-home"
        case .chat: "interface-chat"
        case .settings: "interface-settings"
        case .projects: "interface-projects"
        case .projectOpen: "interface-project-open"
        case .library: "interface-library"
        case .scheduled: "interface-scheduled"
        case .plugins: "interface-plugins"
        case .pulse: "interface-pulse"
        case .workflows: "interface-workflows"
        case .activity: "interface-activity"
        case .memory: "interface-memory"
        case .companion: "interface-companion"
        case .attention: "interface-attention"
        case .update: "interface-update"
        case .clear: "interface-clear"
        case .pin: "interface-pin"
        case .close: "interface-close"
        case .info: "interface-info"
        case .warning: "interface-warning"
        case .connect: "interface-connect"
        case .attach: "interface-attach"
        case .folder: "interface-folder"
        case .research: "interface-research"
        case .document: "interface-document"
        case .image: "interface-image"
        case .reminders: "interface-reminders"
        case .rules: "interface-rules"
        case .tool: "interface-tool"
        case .voice: "interface-voice"
        case .dictate: "interface-dictate"
        case .dictating: "interface-dictating"
        case .send: "interface-send"
        case .stop: "interface-stop"
        case .done: "interface-done"
        case .stopped: "interface-stopped"
        case .paused: "interface-paused"
        case .question: "interface-question"
        case .failed: "interface-failed"
        case .needsYou: "interface-needs-you"
        case .declined: "interface-declined"
        case .refused: "interface-refused"
        case .timedOut: "interface-timed-out"
        case .terminal: "interface-terminal"
        case .edit: "interface-edit"
        case .fileAdded: "interface-file-added"
        case .moved: "interface-moved"
        case .folderAdded: "interface-folder-added"
        case .trash: "interface-trash"
        case .link: "interface-link"
        case .copy: "interface-copy"
        case .reply: "interface-reply"
        case .selectText: "interface-select-text"
        case .addReaction: "interface-add-reaction"
        case .good: "interface-good"
        case .goodChosen: "interface-good-chosen"
        case .bad: "interface-bad"
        case .badChosen: "interface-bad-chosen"
        case .expand: "interface-expand"
        case .collapse: "interface-collapse"
        case .next: "interface-next"
        case .back: "interface-back"
        case .choose: "interface-choose"
        case .latest: "interface-latest"
        case .bridged: "interface-bridged"
        case .withheld: "interface-withheld"
        case .checkboxOn: "interface-checkbox-on"
        case .checkboxOff: "interface-checkbox-off"
        case .radioOn: "interface-radio-on"
        case .radioOff: "interface-radio-off"
        case .pauseMark: "interface-pause-mark"
        case .tick: "interface-tick"
        }
    }

    var url: URL? { VeraResources.url(resource, ext: "svg") }

    @MainActor var image: NSImage? { InterfaceIconCache.shared.image(resource) }

    @MainActor var menuImage: Image? {
        InterfaceIconCache.shared.menuImage(resource).map { Image(nsImage: $0) }
    }
}

enum InterfaceIconSize {
    static let badge: CGFloat = 10
    static let mark: CGFloat = 12
    static let small: CGFloat = 14
    static let regular: CGFloat = 16
    static let menu: CGFloat = 16
    static let row: CGFloat = 18
    static let rail: CGFloat = 22
    static let placeholder: CGFloat = 32
}

@MainActor
final class InterfaceIconCache {
    static let shared = InterfaceIconCache()
    private var images: [String: NSImage] = [:]
    private var menuImages: [String: NSImage] = [:]

    func image(_ resource: String) -> NSImage? {
        if let cached = images[resource] { return cached }
        guard let url = VeraResources.url(resource, ext: "svg"), let image = NSImage(contentsOf: url), image.isValid,
              image.size.width > 0, image.size.height > 0 else { return nil }
        image.isTemplate = true
        images[resource] = image
        return image
    }

    func menuImage(_ resource: String) -> NSImage? {
        if let cached = menuImages[resource] { return cached }
        guard let source = image(resource) else { return nil }
        let side = InterfaceIconSize.menu
        let sized = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        sized.isTemplate = true
        menuImages[resource] = sized
        return sized
    }
}

struct InterfaceIconView: View {
    private let resource: String
    private let size: CGFloat

    init(icon: InterfaceIcon, size: CGFloat = InterfaceIconSize.regular) {
        resource = icon.resource
        self.size = size
    }

    var body: some View {
        Group {
            if let image = InterfaceIconCache.shared.image(resource) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
