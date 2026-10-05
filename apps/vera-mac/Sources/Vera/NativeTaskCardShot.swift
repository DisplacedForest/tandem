import AppKit
import SwiftUI

@MainActor
enum NativeTaskCardShot {
    static var report: NativeResearchArtifact {
        NativeResearchArtifact(
            id: "example-report", title: "Workshop insulation comparison",
            report: """
            The best fit depends on the wall assembly, available space, and installation requirements. [1]

            Compare the total installed cost, not just the material price. Measure the walls and note any areas where moisture control needs attention. [1]

            Before choosing a material, confirm the target thermal performance and the thickness the wall can accommodate.
            """,
            sources: [PulseSource(n: 1, title: "Installation reference", url: "local")])
    }

    static var unsafeReport: NativeResearchArtifact {
        NativeResearchArtifact(
            id: "example-unsafe-report", title: "Saved report links",
            report: """
            Read the [local reference](file:///private/example) or [application reference](vera://example). These labels remain readable. [1]

            ![A remote illustration](https://image.example/illustration.png)

            An inline image ![small illustration](https://image.example/inline.png) cannot fetch remote content. [2]
            """,
            sources: [PulseSource(n: 1, title: "Local reference", url: "file:///private/example"),
                      PulseSource(n: 2, title: "Account reference", url: "https://name:secret@example.com/reference")])
    }

    static func render(view: String, to path: String, appearance: String) {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let narrow = view.hasSuffix("-narrow")
        let variant = narrow ? String(view.dropLast("-narrow".count)) : view
        let content: AnyView
        if variant == "task-card-report" || variant == "task-card-report-unsafe" {
            content = AnyView(NativeResearchReportView(artifact: variant == "task-card-report" ? report : unsafeReport))
        } else {
            content = AnyView(NativeTaskCardShotSurface(variant: variant))
        }
        let size = NSSize(width: narrow ? 620 : 1000, height: 760)
        let hosting = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .background(Theme.bg)
            .environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("Task card render failed\n".utf8))
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Task card render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("Rendered task card")
        } catch {
            FileHandle.standardError.write(Data("Task card image couldn't be saved\n".utf8))
            exit(1)
        }
    }
}

struct NativeTaskCardShotSurface: View {
    let variant: String

    private var card: NativeTaskCardPresentation {
        var result = NativeTaskCardPresentation(
            id: "example-request", title: "Compare insulation options for the workshop",
            status: .working, milestone: "Gathered three sources. Checking the remaining questions.",
            canCancel: true)
        switch variant {
        case "task-card-complete":
            result.status = .completed
            result.milestone = "The report is ready."
            result.canCancel = false
        case "task-card-stopped":
            result.status = .stopped
            result.milestone = "Stopped with three sources saved."
            result.canCancel = false
        case "task-card-retry":
            result.status = .needsInput
            result.milestone = "The report didn't cite its sources correctly. Retry this step?"
            result.canRetry = true
        case "task-card-offline":
            break
        default: break
        }
        if [.stopped, .needsInput].contains(result.status) {
            result.sources = [
                PulseSource(n: 1, title: "Installation reference", url: "local"),
                PulseSource(n: 2, title: "Material comparison", url: "local"),
                PulseSource(n: 3, title: "Measurement notes", url: "local"),
            ]
        }
        return result
    }

    private var blocks: [NativeDisplayBlock] {
        var result: [NativeDisplayBlock] = [.taskCard(card)]
        if card.status == .completed {
            result.append(.artifact(NativeTaskCardShot.report))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Vera").font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            .padding(.bottom, 12)
            HStack {
                Spacer(minLength: 100)
                Text("Compare insulation options for the workshop. I need costs and tradeoffs.")
                    .font(.system(size: 14))
                    .padding(14)
                    .foregroundStyle(.white)
                    .background(Theme.userBubble)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("I'll research that in the background. We can keep talking here.")
                    .font(.system(size: 14))
                NativeDisplayBlocksView(
                    blocks: blocks, engineConfigured: variant != "task-card-offline",
                    onCancel: { _ in }, onRetry: { _ in })
            }
            HStack {
                Spacer()
                Text("While that's running, help me plan the measurements.")
                    .font(.system(size: 14))
                    .padding(14)
                    .foregroundStyle(.white)
                    .background(Theme.userBubble)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text("Start with the wall lengths and ceiling height. Note the doors and windows separately.")
                .font(.system(size: 14))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(36)
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
