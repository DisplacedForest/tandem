import SwiftUI
import AppKit

extension Color {
    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(hex: hex)
        })
    }
}

extension NSColor {
    convenience init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

enum Theme {
    static let ink = Color(light: "#F7F7F7", dark: "#181818")
    static let sidebar = Color(light: "#EFEFEF", dark: "#202020")
    static let surface = Color(light: "#FFFFFF", dark: "#2A2A2A")
    static let surfaceHover = Color(light: "#E7E7E7", dark: "#303030")
    static let surfaceSelected = Color(light: "#DCDCDC", dark: "#383838")
    static let hairline = Color(light: "#D5D5D5", dark: "#383838")
    static let accent = Color(light: "#286D36", dark: "#86C78A")
    static let accentGlow = Color(light: "#3C8248", dark: "#A4D7A7")
    static let onAccent = Color(light: "#FFFFFF", dark: "#142016")
    static let userBubble = Color(light: "#E7E7E7", dark: "#343434")
    static let textPrimary = Color(light: "#202020", dark: "#ECECEC")
    static let textSecondary = Color(light: "#606060", dark: "#ABABAB")

    static let conversationBackground = ink
    static let assistantBubble = Color(light: "#EEEEEE", dark: "#282828")
    static let cardFill = surface
    static let cardStroke = hairline
    static let sage = accent
    static let onSage = onAccent
    static let statusGreen = Color(light: "#286D36", dark: "#86C78A")
    static let warmTextPrimary = textPrimary
    static let warmTextSecondary = textSecondary

    static let bg = ink
}

enum ConversationMetrics {
    static let columnWidth: CGFloat = 760
    static let bubbleRadius: CGFloat = 18
    static let bubblePaddingH: CGFloat = 14
    static let bubblePaddingV: CGFloat = 10
    static let bodySize: CGFloat = 15
    static let metaSize: CGFloat = 12
    static let headerNameSize: CGFloat = 17
    static let avatarSize: CGFloat = 44
    static let replyAvatarSize: CGFloat = 24
    static let cardRadius: CGFloat = 14
    static let composerRadius: CGFloat = 24
}
