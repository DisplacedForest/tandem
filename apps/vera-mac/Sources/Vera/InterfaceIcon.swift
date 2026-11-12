import SwiftUI
import AppKit

enum InterfaceIcon: String, CaseIterable, Sendable {
    case search
    case add
    case sidebar
    case sidebarShown
    case more

    var resource: String {
        switch self {
        case .search: "interface-search"
        case .add: "interface-add"
        case .sidebar: "interface-sidebar"
        case .sidebarShown: "interface-sidebar-shown"
        case .more: "interface-more"
        }
    }

    var url: URL? { VeraResources.url(resource, ext: "svg") }

    @MainActor var image: NSImage? { InterfaceIconCache.shared.image(self) }
}

@MainActor
final class InterfaceIconCache {
    static let shared = InterfaceIconCache()
    private var images: [InterfaceIcon: NSImage] = [:]

    func image(_ icon: InterfaceIcon) -> NSImage? {
        if let cached = images[icon] { return cached }
        guard let url = icon.url, let image = NSImage(contentsOf: url), image.isValid,
              image.size.width > 0, image.size.height > 0 else { return nil }
        image.isTemplate = true
        images[icon] = image
        return image
    }
}

struct InterfaceIconView: View {
    let icon: InterfaceIcon
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = icon.image {
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
