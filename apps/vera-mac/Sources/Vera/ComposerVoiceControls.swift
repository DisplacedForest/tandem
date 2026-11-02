import SwiftUI

enum ComposerDictation {
    static func merge(base: String, _ text: String) -> String {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return base }
        guard let last = base.last, !last.isWhitespace else { return base + spoken }
        return base + " " + spoken
    }
}

struct ComposerVoiceAvailability: Equatable {
    var dictation: Bool
    var voiceChat: Bool

    var any: Bool { dictation || voiceChat }
}

struct ComposerVoiceControls: View {
    let availability: ComposerVoiceAvailability
    let dictating: Bool
    let assistantName: String
    var animated = true
    var onDictate: () -> Void = {}
    var onVoiceChat: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            if availability.dictation {
                Button(action: onDictate) { DictationGlyph(active: dictating, animated: animated) }
                    .buttonStyle(.plain)
                    .help(dictating ? "Stop dictating" : "Dictate into the message")
                    .accessibilityLabel(dictating ? "Stop dictating" : "Dictate")
            }
            if availability.voiceChat {
                Button(action: onVoiceChat) { ComposerControlGlyph(kind: .voice) }
                    .buttonStyle(.plain)
                    .disabled(dictating)
                    .help("Talk with \(assistantName)")
                    .accessibilityLabel("Voice chat")
            }
        }
    }
}

struct DictationGlyph: View {
    let active: Bool
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ComposerControlGlyph(kind: .dictate(active: active))
            .overlay {
                if active {
                    Circle()
                        .stroke(Theme.sage.opacity(expanded ? 0 : 0.5), lineWidth: 2)
                        .scaleEffect(expanded ? 1.45 : 1.12)
                        .allowsHitTesting(false)
                        .onAppear {
                            guard animated, !reduceMotion else { return }
                            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { expanded = true }
                        }
                        .onDisappear { expanded = false }
                }
            }
    }
}
