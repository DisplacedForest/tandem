import AppKit
import SwiftUI

@MainActor
enum CompanionAttentionShot {
    static func render(to path: String) {
        let view = VStack(spacing: 20) {
            ForEach(CompanionShape.allCases, id: \.self) { shape in
                HStack(spacing: 28) {
                    ForEach([32.0, 48, 72, 128, 220], id: \.self) { size in
                        VStack {
                            let eyes = CompanionPose()
                            let face = CompanionAttentionMotion.containedFace(CompanionPose(tx: 6, ty: -4), eyes: eyes, shape: shape)
                            CompanionFigure(appearance: CompanionAppearance(shape: shape, color: .sage),
                                            bodyPose: CompanionPose(rotation: 3), face: face, eyes: eyes, size: size)
                            Text("\(Int(size))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(height: 250)
            }
        }.padding(24).frame(width: 760, height: 840).background(Theme.conversationBackground).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 840)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: AppLocations.checkedOutput(path)); print("Rendered companion attention") }
        catch { exit(1) }
    }
}
