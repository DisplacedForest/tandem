import SwiftUI
import AppKit

enum CompanionShape: String, CaseIterable, Codable, Sendable {
    case pebble, fold, mallow

    var displayName: String {
        switch self {
        case .pebble: return "Pebble"
        case .fold: return "Fold"
        case .mallow: return "Mallow"
        }
    }

    static let bodyAnchor = CGPoint(x: 50, y: 73)
    static let faceAnchor = CGPoint(x: 50, y: 52)
    static let eyeLeft = CGRect(x: 39, y: 43, width: 8, height: 17)
    static let eyeRight = CGRect(x: 54, y: 43, width: 8, height: 17)
    static let eyeCornerRadius: CGFloat = 4

    var faceAnchor: CGPoint { Self.faceAnchor }

    func bodyPath(in rect: CGRect) -> Path {
        let s = rect.width / 100
        let pt = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        switch self {
        case .pebble:
            path.move(to: pt(52, 12))
            path.addCurve(to: pt(85, 41), control1: pt(68, 9), control2: pt(77, 24))
            path.addCurve(to: pt(83, 83), control1: pt(93, 58), control2: pt(96, 75))
            path.addCurve(to: pt(17, 83), control1: pt(70, 92), control2: pt(32, 93))
            path.addCurve(to: pt(16, 44), control1: pt(3, 74), control2: pt(7, 59))
            path.addCurve(to: pt(52, 12), control1: pt(25, 29), control2: pt(38, 15))
        case .fold:
            path.move(to: pt(42, 13))
            path.addQuadCurve(to: pt(61, 14), control: pt(51, 5))
            path.addLine(to: pt(86, 39))
            path.addQuadCurve(to: pt(87, 62), control: pt(97, 50))
            path.addLine(to: pt(61, 87))
            path.addQuadCurve(to: pt(38, 87), control: pt(50, 98))
            path.addLine(to: pt(13, 62))
            path.addQuadCurve(to: pt(13, 39), control: pt(2, 51))
        case .mallow:
            path.move(to: pt(10, 50))
            path.addCurve(to: pt(37, 14), control1: pt(10, 29), control2: pt(20, 14))
            path.addCurve(to: pt(63, 35), control1: pt(51, 14), control2: pt(60, 25))
            path.addCurve(to: pt(92, 45), control1: pt(73, 24), control2: pt(88, 30))
            path.addCurve(to: pt(50, 90), control1: pt(102, 73), control2: pt(79, 90))
            path.addCurve(to: pt(10, 50), control1: pt(24, 90), control2: pt(5, 76))
        }
        path.closeSubpath()
        return path
    }

    func highlightPath(in rect: CGRect) -> Path? {
        guard self == .fold else { return nil }
        let s = rect.width / 100
        let pt = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: pt(54, 10))
        path.addCurve(to: pt(72, 40), control1: pt(66, 23), control2: pt(53, 37))
        path.addLine(to: pt(90, 46))
        path.addCurve(to: pt(61, 14), control1: pt(86, 36), control2: pt(70, 20))
        path.addQuadCurve(to: pt(54, 10), control: pt(57, 11))
        path.closeSubpath()
        return path
    }

    func eyeFrames(in rect: CGRect) -> (left: CGRect, right: CGRect) {
        let s = rect.width / 100
        let scaled = { (r: CGRect) in
            CGRect(x: rect.minX + r.minX * s, y: rect.minY + r.minY * s, width: r.width * s, height: r.height * s)
        }
        return (scaled(Self.eyeLeft), scaled(Self.eyeRight))
    }
}

enum CompanionColor: String, CaseIterable, Codable, Sendable {
    case sage, periwinkle, apricot, rose, sky, mint, pearl

    var displayName: String {
        switch self {
        case .sage: return "Sage"
        case .periwinkle: return "Periwinkle"
        case .apricot: return "Apricot"
        case .rose: return "Rose"
        case .sky: return "Sky"
        case .mint: return "Mint"
        case .pearl: return "Pearl"
        }
    }

    var hex: String {
        switch self {
        case .sage: return "#B6CE8C"
        case .periwinkle: return "#A4A5EE"
        case .apricot: return "#F2B77D"
        case .rose: return "#DE9AB5"
        case .sky: return "#81BFDF"
        case .mint: return "#7DCCB3"
        case .pearl: return "#CFD0DC"
        }
    }

    static let eyeHex = "#20221F"

    var fill: Color { Color(nsColor: NSColor(hex: hex)) }
    var eyeColor: Color { Color(nsColor: NSColor(hex: Self.eyeHex)) }
}

extension CompanionColor {
    static let lightBackgroundHex = "#FFFFFF"
    static let darkBackgroundHex = "#2A2A2A"
    static let minimumTextContrast = 4.5

    private static func channels(_ hex: String) -> (r: Double, g: Double, b: Double) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    private static func hex(_ rgb: (r: Double, g: Double, b: Double)) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.r), byte(rgb.g), byte(rgb.b))
    }

    private static func luminance(_ rgb: (r: Double, g: Double, b: Double)) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.r) + 0.7152 * linear(rgb.g) + 0.0722 * linear(rgb.b)
    }

    static func contrast(_ first: String, _ second: String) -> Double {
        let a = luminance(channels(first)), b = luminance(channels(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func hsl(_ rgb: (r: Double, g: Double, b: Double)) -> (h: Double, s: Double, l: Double) {
        let hi = max(rgb.r, rgb.g, rgb.b), lo = min(rgb.r, rgb.g, rgb.b)
        let l = (hi + lo) / 2
        let d = hi - lo
        if d == 0 { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if hi == rgb.r { h = ((rgb.g - rgb.b) / d).truncatingRemainder(dividingBy: 6) }
        else if hi == rgb.g { h = (rgb.b - rgb.r) / d + 2 }
        else { h = (rgb.r - rgb.g) / d + 4 }
        h /= 6
        if h < 0 { h += 1 }
        return (h, s, l)
    }

    private static func rgb(_ value: (h: Double, s: Double, l: Double)) -> (r: Double, g: Double, b: Double) {
        let c = (1 - abs(2 * value.l - 1)) * value.s
        let x = c * (1 - abs((value.h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = value.l - c / 2
        let sector = Int(value.h * 6) % 6
        let base: (Double, Double, Double)
        switch sector {
        case 0: base = (c, x, 0)
        case 1: base = (x, c, 0)
        case 2: base = (0, c, x)
        case 3: base = (0, x, c)
        case 4: base = (x, 0, c)
        default: base = (c, 0, x)
        }
        return (base.0 + m, base.1 + m, base.2 + m)
    }

    func textHex(dark: Bool) -> String {
        let background = dark ? Self.darkBackgroundHex : Self.lightBackgroundHex
        if Self.contrast(hex, background) >= Self.minimumTextContrast { return hex }
        var tone = Self.hsl(Self.channels(hex))
        let step = dark ? 0.01 : -0.01
        var candidate = hex
        while tone.l > 0, tone.l < 1 {
            tone.l = ((tone.l + step) * 100).rounded() / 100
            candidate = Self.hex(Self.rgb(tone))
            if Self.contrast(candidate, background) >= Self.minimumTextContrast { break }
        }
        return candidate
    }

    func textColor(for colorScheme: ColorScheme) -> Color {
        Color(nsColor: NSColor(hex: textHex(dark: colorScheme == .dark)))
    }
}

struct CompanionAppearance: Equatable, Codable, Sendable {
    var shape: CompanionShape
    var color: CompanionColor

    static let `default` = CompanionAppearance(shape: .pebble, color: .sage)
}

@MainActor
protocol CompanionAppearanceStore {
    func load() -> CompanionAppearance
    func save(_ appearance: CompanionAppearance) throws
}

@MainActor
struct ConfigCompanionAppearanceStore: CompanionAppearanceStore {
    let config: ConfigStore

    func load() -> CompanionAppearance { config.companionAppearance }

    func save(_ appearance: CompanionAppearance) throws {
        config.setCompanionAppearance(appearance)
    }
}
