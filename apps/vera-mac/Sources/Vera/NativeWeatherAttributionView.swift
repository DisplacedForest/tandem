import SwiftUI

struct NativeWeatherAttributionView: View {
    let activities: [NativeToolActivity]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let report = NativeWeatherAttribution.report(in: activities) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(report.alerts.enumerated()), id: \.offset) { _, alert in
                    if NativeWeatherAttribution.allowed(alert.url) {
                        Link(destination: alert.url) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(alert.headline)
                                Text(alert.source).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    let mark = colorScheme == .dark ? report.attribution.darkMarkURL : report.attribution.lightMarkURL
                    if NativeWeatherAttribution.allowed(mark) {
                        AsyncImage(url: mark) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Text("Apple Weather").font(.caption)
                        }
                        .frame(width: 100, height: 20)
                        .accessibilityLabel("Apple Weather")
                    }
                    if NativeWeatherAttribution.allowed(report.attribution.legalURL) {
                        Link("Data sources", destination: report.attribution.legalURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

enum NativeWeatherAttribution {
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com")
    }

    static func report(in activities: [NativeToolActivity]) -> NativeWeatherReport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return activities.reversed().lazy.compactMap { activity -> NativeWeatherReport? in
            guard activity.toolID == NativeWeatherTools.toolID, activity.name == NativeWeatherTools.toolName,
                  activity.state == .succeeded, let data = activity.result?.data(using: .utf8) else { return nil }
            return try? decoder.decode(NativeWeatherReport.self, from: data)
        }.first
    }
}
