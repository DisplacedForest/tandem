import SwiftUI

struct VoiceView: View {
    enum Phase: Equatable { case idle, listening, transcribing, thinking, speaking }

    let phase: Phase
    var playing: Bool = false
    var statusLine: String? = nil
    var error: String? = nil
    var onEnd: () -> Void = {}
    @EnvironmentObject var store: ChatStore
    @Environment(\.companionAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    (Text("\(store.companion.leading) ").foregroundStyle(.white)
                        + Text("Voice").foregroundStyle(Theme.textSecondary))
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 28).padding(.top, 36)

                Spacer()
                CompanionAvatarView(appearance: appearance, state: Self.companionState(for: phase, playing: playing), size: 220,
                                    name: store.companionName, reduceMotion: reduceMotion)
                Text(caption)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 30)
                Spacer()

                if let err = error {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.9))
                        .padding(.bottom, 10)
                }
                Button(action: onEnd) {
                    InterfaceIconView(icon: .close, size: InterfaceIconSize.rail)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Theme.surfaceHover)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
                .help("End voice session")
                .accessibilityLabel("End voice session")
            }
        }
    }

    static func companionState(for state: Phase, playing: Bool) -> CompanionState {
        switch state {
        case .listening: return .listening
        case .speaking: return playing ? .speaking : .thinking
        case .transcribing, .thinking: return .thinking
        case .idle: return .ready
        }
    }

    private var caption: String {
        switch phase {
        case .idle:         return ""
        case .listening:    return "Listening…"
        case .transcribing: return "Transcribing…"
        case .thinking:     return statusLine ?? "Thinking…"
        case .speaking:     return "Speaking…"
        }
    }
}
