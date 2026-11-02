import Foundation

struct CompanionStateSnapshot: Equatable, Sendable {
    var foregroundGenerating = false
    var voiceCapturing = false
    var voicePlaying = false
    var decisionPending = false
    var explicitlyResting = false
    var appInactive = false
}

enum CompanionStateMapper {
    static func state(_ snapshot: CompanionStateSnapshot) -> CompanionState {
        if snapshot.voicePlaying { return .speaking }
        if snapshot.voiceCapturing { return .listening }
        if snapshot.decisionPending { return .needsYou }
        if snapshot.foregroundGenerating { return .thinking }
        if snapshot.explicitlyResting || snapshot.appInactive { return .resting }
        return .ready
    }
}
