import SwiftUI

private enum BrandGreens {
    static let sage = Color(nsColor: NSColor(hex: "#9DBF8E"))
    static let deep = Color(nsColor: NSColor(hex: "#6F9A62"))
    static let deeper = Color(nsColor: NSColor(hex: "#557C4A"))
    static let highlight = Color(nsColor: NSColor(hex: "#C4DBB8"))
}

struct TandemLogoMark: View {
    var size: CGFloat

    var body: some View {
        let diameter = size * 0.62
        let offset = (size - diameter) / 2
        ZStack {
            circle(base: BrandGreens.deep, shade: BrandGreens.deeper, light: BrandGreens.sage, diameter: diameter)
                .offset(x: -offset)
            circle(base: BrandGreens.sage, shade: BrandGreens.deep, light: BrandGreens.highlight, diameter: diameter)
                .offset(x: offset)
                .shadow(color: .black.opacity(0.18), radius: size * 0.03, x: -size * 0.02, y: 0)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func circle(base: Color, shade: Color, light: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [light, base, shade],
                                 center: UnitPoint(x: 0.35, y: 0.3),
                                 startRadius: 0, endRadius: diameter * 0.75))
            .frame(width: diameter, height: diameter)
    }
}

struct CompanionAvatar: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
            .fill(LinearGradient(colors: [BrandGreens.highlight, BrandGreens.sage, BrandGreens.deep],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
                .stroke(BrandGreens.deeper.opacity(0.35), lineWidth: max(0.5, size * 0.03)))
            .frame(width: size * 0.86, height: size * 0.8)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
