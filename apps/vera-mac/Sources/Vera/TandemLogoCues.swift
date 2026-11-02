import Foundation

enum TandemLogoCue: String, CaseIterable, Sendable {
    case breathe = "Breathe"
    case hello = "Hello"
    case exchange = "Exchange"
    case orbit = "Orbit"
    case rally = "Rally"
    case nudge = "Nudge"
    case listen = "Listen"
    case speak = "Speak"
    case gather = "Gather"
    case pause = "Pause"
    case recover = "Recover"
    case rest = "Rest"
}

struct TandemLogoSnapshot: Equatable, Sendable {
    var appActive = true
    var launchedJustNow = false
    var generating = false
    var decisionPending = false
    var turnCompleted = false
    var turnFailed = false
    var turnCanceled = false
    var voiceCapturing = false
    var voicePlaying = false
    var handoff = false
    var idleBreathing = false

    static let idle = TandemLogoSnapshot()
}

enum TandemLogoCueMapper {
    static func cue(previous: TandemLogoSnapshot?, current: TandemLogoSnapshot) -> (cue: TandemLogoCue, loop: Bool)? {
        let before = previous ?? .idle
        func rose(_ key: KeyPath<TandemLogoSnapshot, Bool>) -> Bool { current[keyPath: key] && !before[keyPath: key] }

        if current.voicePlaying { return (.speak, true) }
        if current.voiceCapturing { return (.listen, true) }
        if rose(\.decisionPending) { return (.nudge, false) }
        if rose(\.turnFailed) { return (.recover, false) }
        if rose(\.turnCanceled) { return (.pause, false) }
        if rose(\.turnCompleted) { return (.gather, false) }
        if rose(\.handoff) { return (.exchange, false) }
        if current.generating { return (.orbit, true) }
        if rose(\.launchedJustNow) { return (.hello, false) }
        if before.appActive && !current.appActive { return (.rest, false) }
        if current.idleBreathing && current.appActive { return (.breathe, true) }
        if loopHeld(before) { return (.rest, false) }
        return nil
    }

    private static func loopHeld(_ s: TandemLogoSnapshot) -> Bool {
        s.voicePlaying || s.voiceCapturing || s.generating || (s.idleBreathing && s.appActive)
    }
}
