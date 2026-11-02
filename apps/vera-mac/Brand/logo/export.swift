import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
let greenLeft = ["#C9E6A5", "#90B66E"]
let greenRight = ["#A7CF86", "#628F47"]

func color(_ hex: String) -> CGColor {
    let value = UInt32(hex.dropFirst(), radix: 16)!
    return CGColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
}

func gradient(_ context: CGContext, _ colors: [String], _ rect: CGRect) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors.map(color) as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func mark(_ context: CGContext, rect: CGRect, monochrome: Bool = false) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.minY)
    context.scaleBy(x: rect.width / 410, y: rect.height / 256)
    let left = CGRect(x: 0, y: 0, width: 256, height: 256)
    let right = CGRect(x: 154, y: 0, width: 256, height: 256)
    for (circle, colors) in [(left, greenLeft), (right, greenRight)] {
        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        if monochrome {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(circle)
        } else {
            gradient(context, colors, circle)
        }
        context.restoreGState()
    }
    context.saveGState()
    context.addEllipse(in: left)
    context.clip()
    context.addEllipse(in: right)
    context.clip()
    if monochrome {
        context.setBlendMode(.clear)
        context.fill(left.union(right))
    } else {
        gradient(context, ["#BADC97", "#A2C780"], left.union(right))
    }
    context.restoreGState()
    context.restoreGState()
}

func draw(_ context: CGContext, size: CGSize, kind: String) {
    let whole = CGRect(origin: .zero, size: size)
    if kind == "icon" {
        let tile = whole.insetBy(dx: size.width * 0.0625, dy: size.height * 0.0625)
        context.saveGState()
        context.addPath(CGPath(roundedRect: tile, cornerWidth: size.width * 0.195, cornerHeight: size.height * 0.195, transform: nil))
        context.clip()
        gradient(context, ["#30332E", "#161815"], tile)
        context.restoreGState()
        let width = size.width * 0.70
        let height = width * 256 / 410
        mark(context, rect: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
    } else if kind == "wordmark" {
        mark(context, rect: CGRect(x: 0, y: 24, width: 205, height: 128))
        let text = NSAttributedString(string: "Tandem", attributes: [.font: NSFont.systemFont(ofSize: 100, weight: .semibold), .foregroundColor: NSColor.white])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: CGPoint(x: 245, y: 26))
        NSGraphicsContext.restoreGraphicsState()
    } else {
        mark(context, rect: whole, monochrome: kind == "template")
    }
}

func png(_ name: String, width: Int, height: Int, kind: String) throws {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setAllowsAntialiasing(true)
    draw(context, size: CGSize(width: width, height: height), kind: kind)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    let data = rep.representation(using: .png, properties: [:])!
    let url = root.appendingPathComponent(name)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

try png("tandem-mark.png", width: 1640, height: 1024, kind: "mark")
try png("tandem-wordmark-white.png", width: 650, height: 176, kind: "wordmark")
try png("tandem-app-icon-1024.png", width: 1024, height: 1024, kind: "icon")
for size in [16, 32, 128, 256, 512] {
    try png("Tandem.iconset/icon_\(size)x\(size).png", width: size, height: size, kind: "icon")
    try png("Tandem.iconset/icon_\(size)x\(size)@2x.png", width: size * 2, height: size * 2, kind: "icon")
}
for height in [16, 18, 22, 32] {
    let width = Int((Double(height) * 410 / 256).rounded())
    try png("menu-bar/tandem-\(height).png", width: width, height: height, kind: "template")
    try png("menu-bar/tandem-\(height)@2x.png", width: width * 2, height: height * 2, kind: "template")
}
var media = CGRect(x: 0, y: 0, width: 410, height: 256)
let pdf = CGContext(root.appendingPathComponent("tandem-mark.pdf") as CFURL, mediaBox: &media, nil)!
pdf.beginPDFPage(nil)
mark(pdf, rect: media)
pdf.endPDFPage()
pdf.closePDF()
print("Exported logo, wordmark, app icon, iconset, menu bar templates and vector PDF")
