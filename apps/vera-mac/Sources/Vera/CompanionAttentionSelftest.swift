import AppKit
import SwiftUI

@MainActor
extension SelfTest {
    static func runCompanionAttention() throws {
        let require = NativeTaskFixture.require
        let frame = CGRect(x: 100, y: 200, width: 100, height: 100)
        try require(CompanionAttentionMotion.target(CGPoint(x: 150, y: 250), frame: frame) == .zero, "Centered window coordinates map to neutral gaze")
        let far = CompanionAttentionMotion.target(CGPoint(x: 10000, y: -10000), frame: frame)
        try require(far == CGPoint(x: 6, y: 4), "Far points clamp and invert the window vertical axis")
        var input = CompanionAttentionInput(pointer: CGPoint(x: 400, y: 500), pointerTime: 0, active: true)
        var motion = CompanionAttentionMotion()
        motion.step(now: 0, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 })
        for tick in 1...120 {
            motion.step(now: Double(tick) / 60, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 })
            try require(abs(motion.gaze.x) <= 6 && abs(motion.gaze.y) <= 4 && abs(motion.lean) <= 3, "Spring response stays bounded")
        }
        try require(motion.gaze.x > 5.9 && motion.gaze.y < -3.9, "Eyes converge toward the pointer")
        var interrupted = motion
        interrupted.step(now: 2.1, input: input, frame: frame, state: .listening, enabled: true, random: { 0.5 })
        try require(interrupted.gaze == .zero && interrupted.velocity == .zero && interrupted.lean == 0, "Live listening immediately takes priority over an existing glance")
        input.composer = CGPoint(x: 0, y: 0); input.composerFocused = true
        for tick in 121...240 { motion.step(now: Double(tick) / 60, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 }) }
        try require(motion.gaze.x < -5 && motion.gaze.y > 3, "Composer wins after pointer movement settles")
        input.pointer = nil; input.pointerOutside = true; input.pointerTime = 4
        for tick in 241...360 { motion.step(now: Double(tick) / 60, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 }) }
        try require(abs(motion.gaze.x) < 0.01 && abs(motion.gaze.y) < 0.01, "Pointer exit recenters even with an old composer focus")
        input.pointerOutside = false
        motion.step(now: 6.1, input: input, frame: frame, state: .ready, enabled: false, random: { 0.5 })
        try require(motion.gaze == .zero && motion.velocity == .zero && motion.lastTime == nil, "Reduced motion clears pose and velocity")
        motion.step(now: 100, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 })
        try require(motion.gaze == .zero, "Reentry cannot catch up elapsed animation")
        motion.step(now: 10000, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 })
        try require(abs(motion.gaze.x) < 1, "Long frame gaps have bounded integration")
        motion.step(now: 10001, input: input, frame: frame, state: .resting, enabled: true, random: { 0.5 })
        try require(motion.gaze == .zero && motion.perk == 0, "Resting ignores attention")
        input.pointer = CGPoint(x: 150, y: 250); input.pointerTime = 0; input.composerFocused = false
        motion.step(now: 0, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 })
        motion.step(now: 0.1, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 })
        motion.step(now: 0.3, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 })
        try require(motion.perk > 0, "Entering nearby hover perks once")
        motion.step(now: 1, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 })
        try require(motion.perk == 0, "Stationary hover stops perking")
        input.pointer = nil
        motion.step(now: 1.1, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 })
        input.pointer = CGPoint(x: 150, y: 250)
        motion.step(now: 1.2, input: input, frame: frame, state: .ready, enabled: true, random: { 0.5 })
        try require(motion.perk == 0, "Reentry respects hover cooldown")
        for state in [CompanionState.listening, .speaking] {
            var voice = CompanionAttentionMotion()
            input.pointerTime = 0
            for tick in 0...120 { voice.step(now: Double(tick) / 60, input: input, frame: frame, state: state, enabled: true, random: { 0.5 }) }
            try require(voice.gaze == .zero && voice.lean == 0, "Voice state keeps its own cues")
        }
        for shape in CompanionShape.allCases {
            for state in CompanionState.allCases {
                for phase in stride(from: 0.0, through: 5.0, by: 0.1) {
                    let eyes = CompanionMotion.of(state).eyes.pose(at: phase)
                    for x in [-6.0, 0, 6] {
                        for y in [-4.0, 0, 4] {
                            let face = CompanionAttentionMotion.containedFace(CompanionPose(tx: x, ty: y), eyes: eyes, shape: shape)
                            for size in [32.0, 48, 72, 128, 220] {
                                let scale = size / 100
                                let body = shape.bodyPath(in: CGRect(x: 0, y: 0, width: size, height: size))
                                let frames = shape.eyeFrames(in: CGRect(x: 0, y: 0, width: size, height: size))
                                for eye in [frames.left, frames.right] {
                                    for sx in [-1.0, 1] {
                                        for sy in [-1.0, 1] {
                                            try require(body.contains(CGPoint(x: eye.midX + face.tx * scale + sx * eye.width * eyes.sx / 2,
                                                                               y: eye.midY + face.ty * scale + sy * eye.height * eyes.sy / 2)), "Eyes stay inside every shape and size")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        let source = CompanionAttentionSource()
        source.clock = { 42 }
        source.pointer(CGPoint(x: 10, y: 10))
        try require(source.input.pointer == nil, "Inactive tracker ignores input")
        source.activate(true); source.pointer(CGPoint(x: 10, y: 10))
        try require(source.input.pointerTime == 42, "Tracker uses its injected clock")
        source.activate(false)
        try require(source.input.pointer == nil, "Deactivation discards pointer position")
        print("  companion attention OK (coordinates, springs, handoff, cooldown, voice priority, motion reset, eye containment, clock)")
    }
}
