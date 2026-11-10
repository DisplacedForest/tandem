import SwiftUI

enum TranscriptMarker: Equatable, Sendable {
    case preferenceSaved
    case preferenceRemoved

    var text: String {
        switch self {
        case .preferenceSaved: "Preferences updated"
        case .preferenceRemoved: "Preference removed"
        }
    }

    var symbol: String {
        switch self {
        case .preferenceSaved, .preferenceRemoved: "checkmark.circle"
        }
    }
}

struct TranscriptMarkerRow: View {
    let marker: TranscriptMarker

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: marker.symbol)
            Text(marker.text)
        }
        .font(.system(size: ConversationMetrics.metaSize))
        .foregroundStyle(Theme.warmTextSecondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(marker.text)
    }
}
