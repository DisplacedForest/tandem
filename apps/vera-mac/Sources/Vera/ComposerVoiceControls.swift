import SwiftUI

enum ComposerDictation {
    static func merge(base: String, _ text: String) -> String {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return base }
        guard let last = base.last, !last.isWhitespace else { return base + spoken }
        return base + " " + spoken
    }
}

struct DictationDraftBinding {
    let conversationID: String?
    private(set) var anchor: Int
    private(set) var inserted = ""

    init(conversationID: String?, draft: String) {
        self.conversationID = conversationID
        self.anchor = draft.count
    }

    mutating func apply(_ text: String, to draft: String) -> String {
        var chars = Array(draft)
        let previous = Array(inserted)
        if anchor <= chars.count, anchor + previous.count <= chars.count,
           Array(chars[anchor..<(anchor + previous.count)]) == previous {
            chars.removeSubrange(anchor..<(anchor + previous.count))
        } else {
            anchor = chars.count
        }
        let segment = Array(ComposerDictation.merge(base: String(chars[..<anchor]), text).dropFirst(anchor))
        chars.insert(contentsOf: segment, at: anchor)
        inserted = String(segment)
        return String(chars)
    }
}

@MainActor
final class ComposerDictationController {
    private var binding: DictationDraftBinding?
    private var token = 0

    var isBound: Bool { binding != nil }

    func start(voice: VoiceSession, conversationID: String?,
               read: @escaping @MainActor () -> String,
               write: @escaping @MainActor (String) -> Void,
               selected: @escaping @MainActor () -> String?,
               onFinal: @escaping @MainActor () -> Void = {}) {
        token &+= 1
        let current = token
        binding = DictationDraftBinding(conversationID: conversationID, draft: read())
        voice.startDictation { [weak self, weak voice] text, isFinal in
            guard let self, current == self.token, var binding = self.binding else { return }
            guard selected() == binding.conversationID else {
                self.binding = nil
                voice?.stopDictation()
                return
            }
            write(binding.apply(text, to: read()))
            self.binding = isFinal ? nil : binding
            if isFinal { onFinal() }
        }
        if !voice.isDictating, current == token { binding = nil }
    }

    func detach(_ voice: VoiceSession) {
        guard binding != nil else { return }
        binding = nil
        token &+= 1
        voice.stopDictation()
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
