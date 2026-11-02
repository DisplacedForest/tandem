import SwiftUI

struct VoiceView: View {
    @EnvironmentObject var voice: VoiceSession
    @EnvironmentObject var store: ChatStore
    @Environment(\.companionAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    (Text("\(store.assistantName) ").foregroundStyle(.white)
                        + Text("Voice").foregroundStyle(Theme.textSecondary))
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 28).padding(.top, 36)

                Spacer()
                CompanionAvatarView(appearance: appearance, state: companionState, size: 220,
                                    name: store.assistantName, reduceMotion: reduceMotion)
                Text(caption)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 30)
                Spacer()

                if let err = voice.lastError {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.9))
                        .padding(.bottom, 10)
                }
                Button(action: { voice.stop() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Theme.surfaceHover)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
                .help("End voice session")
            }
        }
    }

    private var companionState: CompanionState {
        switch voice.state {
        case .listening: return .listening
        case .speaking: return .speaking
        case .transcribing, .thinking: return .thinking
        case .idle: return .ready
        }
    }

    private var caption: String {
        switch voice.state {
        case .idle:         return ""
        case .listening:    return "Listening…"
        case .transcribing: return "Transcribing…"
        case .thinking:     return voice.statusLine ?? "Thinking…"
        case .speaking:     return "Speaking…"
        }
    }
}
