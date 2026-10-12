import Foundation
import SwiftUI
import MarkdownUI

enum NativeResearchReportSafety {
    static func destination(_ value: String) -> URL? {
        NativeDisplayLink(id: "", title: "", url: value).destination
    }

    static func sources(_ values: [PulseSource]) -> [PulseSource] {
        values.map { source in
            PulseSource(n: source.n, title: source.title.isEmpty ? "Saved reference" : source.title,
                        url: destination(source.url)?.absoluteString ?? "local")
        }
    }
}

struct NativeResearchImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Text("Image omitted").font(.caption).foregroundStyle(.secondary)
    }
}

struct NativeResearchInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        Image(systemName: "photo")
    }
}
