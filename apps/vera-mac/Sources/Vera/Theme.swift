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
    static let ink = Color(light: "#F6F2EA", dark: "#1C1B19")
    static let sidebar = Color(light: "#EEE9DF", dark: "#141311")
    static let surface = Color(light: "#FDFBF6", dark: "#262522")
    static let surfaceHover = Color(light: "#E9E3D7", dark: "#2E2C29")
    static let surfaceSelected = Color(light: "#E0D8C9", dark: "#383530")
    static let hairline = Color(light: "#E2DBCD", dark: "#2B2A27")
    static let accent = Color(light: "#A05A2C", dark: "#C97E4C")
    static let accentGlow = Color(light: "#C77B4A", dark: "#E8A97E")
    static let onAccent = Color(light: "#FFF8F0", dark: "#1A120C")
    static let userBubble = Color(light: "#E9E3D7", dark: "#2E2C29")
    static let textPrimary = Color(light: "#1E1C19", dark: "#ECE8DF")
    static let textSecondary = Color(light: "#6F685D", dark: "#9A958B")

    static let bg = ink
    static let assistantBubble = surface
}
