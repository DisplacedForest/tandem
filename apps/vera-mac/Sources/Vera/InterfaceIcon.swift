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
        }
    }

    var url: URL? { VeraResources.url(resource, ext: "svg") }

    @MainActor var image: NSImage? { InterfaceIconCache.shared.image(resource) }

    @MainActor var menuImage: Image? {
        InterfaceIconCache.shared.menuImage(resource).map { Image(nsImage: $0) }
    }
}

enum InterfaceIconCandidate: String, CaseIterable, Sendable {
    case libraryFolders
    case memoryArchive
    case workflowsBranch

    var role: InterfaceIcon {
        switch self {
        case .libraryFolders: .library
        case .memoryArchive: .memory
        case .workflowsBranch: .workflows
        }
    }

    var resource: String {
        switch self {
        case .libraryFolders: "interface-library-folders"
        case .memoryArchive: "interface-memory-archive"
        case .workflowsBranch: "interface-workflows-branch"
        }
    }

    var url: URL? { VeraResources.url(resource, ext: "svg") }

    @MainActor var image: NSImage? { InterfaceIconCache.shared.image(resource) }
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

    init(candidate: InterfaceIconCandidate, size: CGFloat = InterfaceIconSize.regular) {
        resource = candidate.resource
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
