import SwiftUI
import AppKit

struct TandemMotionGalleryView: View {
    var renderSafe = false

    enum StageSize: CGFloat, CaseIterable, Identifiable {
        case menuBar = 18
        case sidebar = 28
        case header = 44
        case large = 160

        var id: CGFloat { rawValue }

        var label: String {
            switch self {
            case .menuBar: "Menu bar"
            case .sidebar: "Sidebar"
            case .header: "Header"
            case .large: "Large"
            }
        }
    }

    @StateObject private var controller = TandemMotionController()
    @State private var selected = TandemMotionLibrary.sequences.first?.name ?? ""
    @State private var speed: Double = 1
    @State private var size: StageSize = .large
    @State private var lightStage = false
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var paused = false

    private static let ink = TandemPalette.rgb(0x171917)
    private static let panel = TandemPalette.rgb(0x20241E)
    private static let light = TandemPalette.rgb(0xF1F1EA)
    private static let line = TandemPalette.rgb(0x383E33)
    private static let accent = TandemPalette.rgb(0xBDDB9C)
    private static let staticSizes: [CGFloat] = [16, 18, 22, 32]

    private var sequence: TandemMotionSequence? { TandemMotionLibrary.sequence(named: selected) }

    var body: some View {
        ShotSafeScroll(renderSafe: renderSafe) {
            VStack(alignment: .leading, spacing: 20) {
                stage
                caption
                controls
                choices
                strip(light: true)
                strip(light: false)
            }
            .padding(24)
        }
        .background(Self.ink)
        .foregroundStyle(TandemPalette.rgb(0xF3F4EF))
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard !renderSafe else { return }
            controller.speed = speed
            controller.play(selected)
        }
        .onChange(of: selected) { _, name in controller.play(name) }
        .onChange(of: speed) { _, value in controller.speed = value }
        .onChange(of: paused) { _, value in controller.isPaused = value }
    }

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(lightStage ? Self.light : Self.panel)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Self.line))
            Group {
                if renderSafe {
                    TandemLogoStage(pose: reduceMotion ? .rest : (sequence?.frames.first?.pose ?? .rest))
                } else {
                    AnimatedTandemLogo(controller: controller, reduceMotionOverride: reduceMotion)
                }
            }
            .frame(width: size.rawValue * TandemLogoGeometry.aspectRatio, height: size.rawValue)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected logo animation")
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selected).font(.title2.weight(.semibold))
            if let sequence {
                Text(sequence.use).foregroundStyle(.secondary)
                Text(Self.timing(sequence)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    static func timing(_ sequence: TandemMotionSequence) -> String {
        let seconds = sequence.duration.formatted(.number.precision(.fractionLength(0...2)))
        return sequence.loop ? "Lasts \(seconds) seconds and repeats." : "Lasts \(seconds) seconds and plays once."
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button("Replay") {
                paused = false
                controller.replay()
            }
            .accessibilityLabel("Replay animation")
            Button(paused ? "Resume" : "Pause") { paused.toggle() }
                .accessibilityLabel(paused ? "Resume animation" : "Pause animation")
            Picker("Speed", selection: $speed) {
                Text("0.5x").tag(0.5)
                Text("1x").tag(1.0)
                Text("2x").tag(2.0)
            }
            .frame(width: 140)
            .accessibilityLabel("Animation speed")
            Picker("Size", selection: $size) {
                ForEach(StageSize.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 170)
            .accessibilityLabel("Logo size")
            Toggle("Light background", isOn: $lightStage)
                .accessibilityLabel("Light background")
            Toggle("Reduce motion", isOn: $reduceMotion)
                .accessibilityLabel("Reduce motion")
        }
        .controlSize(.regular)
    }

    private var choices: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(TandemMotionLibrary.sequences, id: \.name) { item in
                let isSelected = item.name == selected
                Button {
                    if item.name == selected { controller.play(item.name) } else { selected = item.name }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.headline)
                        Text(item.use).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? TandemPalette.rgb(0x303B29) : Self.panel))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Self.accent : Self.line))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.name), \(item.use)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func strip(light: Bool) -> some View {
        HStack(spacing: 28) {
            ForEach(Self.staticSizes, id: \.self) { point in
                VStack(spacing: 10) {
                    TandemLogoView()
                        .frame(width: point * TandemLogoGeometry.aspectRatio, height: point)
                        .frame(height: Self.staticSizes.last ?? point)
                    Image(nsImage: TandemTemplate.image(pointSize: point))
                        .renderingMode(.template)
                        .foregroundStyle(light ? Color.black : Color.white)
                        .frame(height: Self.staticSizes.last ?? point)
                        .accessibilityLabel("Tandem")
                    Text("\(Int(point)) pt").font(.caption2).foregroundStyle(light ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(light ? Self.light : Self.panel))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(light ? "Marks on a light background" : "Marks on a dark background")
    }
}
