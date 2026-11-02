import SwiftUI

@MainActor
final class CompanionAppearanceFixtureStore: CompanionAppearanceStore {
    var stored: CompanionAppearance = .default
    var saves = 0

    func load() -> CompanionAppearance { stored }

    func save(_ appearance: CompanionAppearance) throws {
        saves += 1
        stored = appearance
    }
}

@MainActor
final class CompanionAppearanceFixtureDisk {
    var contents: [String: Any] = [:]
    var writes = 0
}

@MainActor
extension SelfTest {
    static func runCompanionAppearance() throws {
        let require = NativeTaskFixture.require
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)

        for shape in CompanionShape.allCases {
            let path = shape.bodyPath(in: box)
            let bounds = path.boundingRect
            try require(!path.isEmpty && bounds.width > 50 && bounds.height > 50, "\(shape.displayName) has a body")
            try require(box.contains(bounds), "\(shape.displayName) stays inside its box")
            let eyes = shape.eyeFrames(in: box)
            for eye in [eyes.left, eyes.right] {
                try require(bounds.contains(eye), "\(shape.displayName) eyes sit inside the body bounds")
                let corners = [CGPoint(x: eye.minX + 1, y: eye.minY + 1), CGPoint(x: eye.maxX - 1, y: eye.minY + 1),
                               CGPoint(x: eye.minX + 1, y: eye.maxY - 1), CGPoint(x: eye.maxX - 1, y: eye.maxY - 1)]
                try require(corners.allSatisfy { path.contains($0) }, "\(shape.displayName) eyes sit on the body")
            }
            let scaled = shape.bodyPath(in: CGRect(x: 10, y: 20, width: 200, height: 200)).boundingRect
            try require(abs(scaled.minX - (10 + bounds.minX * 2)) < 0.5 && abs(scaled.width - bounds.width * 2) < 0.5,
                        "\(shape.displayName) scales with its rect")
        }
        try require(CompanionShape.fold.highlightPath(in: box) != nil && CompanionShape.pebble.highlightPath(in: box) == nil,
                    "Only Fold carries the highlight")

        var pairs = Set<String>()
        for shape in CompanionShape.allCases {
            for color in CompanionColor.allCases { pairs.insert("\(shape.rawValue)-\(color.rawValue)") }
        }
        try require(pairs.count == 21, "Every shape and color pairing is distinct")
        try require(Set(CompanionColor.allCases.map { $0.hex.uppercased() }).count == 7, "Every color has its own fill")
        try require(!CompanionColor.allCases.contains { $0.hex.uppercased() == CompanionColor.eyeHex }, "Eyes contrast with every fill")
        try require(Set(CompanionShape.allCases.map(\.displayName)).count == 3 && Set(CompanionColor.allCases.map(\.displayName)).count == 7,
                    "Names are distinct")

        for shape in CompanionShape.allCases {
            for color in CompanionColor.allCases {
                let value = CompanionAppearance(shape: shape, color: color)
                let decoded = try JSONDecoder().decode(CompanionAppearance.self, from: JSONEncoder().encode(value))
                try require(decoded == value, "Appearance survives encoding")
            }
        }

        let disk = CompanionAppearanceFixtureDisk()
        disk.contents = ["unrelated_setting": "kept"]
        let config = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents },
                                 nativeMCP: NativeMCPManager(servers: []),
                                 writeConfiguration: { disk.contents = $0; disk.writes += 1 })
        let configStore = ConfigCompanionAppearanceStore(config: config)
        try require(configStore.load() == .default, "An unset appearance is the default")
        let chosen = CompanionAppearance(shape: .mallow, color: .rose)
        try configStore.save(chosen)
        try require(configStore.load() == chosen, "A saved appearance reads back")
        try config.save()
        try require(disk.contents[ConfigStore.companionShapeKey] as? String == "mallow"
                    && disk.contents[ConfigStore.companionColorKey] as? String == "rose"
                    && disk.contents["unrelated_setting"] as? String == "kept", "The appearance persists beside other settings")
        let reopened = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { disk.contents },
                                   nativeMCP: NativeMCPManager(servers: []), writeConfiguration: { disk.contents = $0 })
        try require(ConfigCompanionAppearanceStore(config: reopened).load() == chosen, "A saved appearance survives a relaunch")
        config[ConfigStore.companionShapeKey] = "square"
        try require(configStore.load() == CompanionAppearance(shape: CompanionAppearance.default.shape, color: .rose),
                    "An unknown shape falls back to the default shape")
        config[ConfigStore.companionColorKey] = "plaid"
        try require(configStore.load() == .default, "Unknown values fall back to the default")

        for mask in 0..<64 {
            let snapshot = CompanionStateSnapshot(foregroundGenerating: mask & 1 != 0, voiceCapturing: mask & 2 != 0,
                                                  voicePlaying: mask & 4 != 0, decisionPending: mask & 8 != 0,
                                                  explicitlyResting: mask & 16 != 0, appInactive: mask & 32 != 0)
            let expected: CompanionState
            switch true {
            case snapshot.voicePlaying: expected = .speaking
            case snapshot.voiceCapturing: expected = .listening
            case snapshot.decisionPending: expected = .needsYou
            case snapshot.foregroundGenerating: expected = .thinking
            case snapshot.explicitlyResting || snapshot.appInactive: expected = .resting
            default: expected = .ready
            }
            try require(CompanionStateMapper.state(snapshot) == expected, "State priority holds for combination \(mask)")
        }

        for state in CompanionState.allCases {
            let motion = CompanionMotion.of(state)
            for channel in [motion.body, motion.face, motion.eyes] {
                guard let track = channel.track else { continue }
                try require(track.stops.first?.at == 0 && track.stops.last?.at == 1, "\(state.displayName) motion covers its cycle")
                if track.repeats {
                    try require(track.pose(at: 0) == track.pose(at: track.duration), "\(state.displayName) motion loops seamlessly")
                }
            }
        }
        let hop = CompanionMotion.of(.needsYou).body
        try require(hop.track?.repeats == false, "Needs you hops once")
        try require(hop.pose(at: 0.9) == hop.still && hop.pose(at: 30) == hop.still, "Needs you holds its tilt after the hop")
        try require((hop.pose(at: 0.468).ty) < -8, "Needs you lifts during the hop")
        try require(CompanionMotion.of(.resting).eyes.pose(at: nil).sy < 0.2, "Resting eyes are closed when still")
        try require(CompanionMotion.of(.needsYou).body.pose(at: nil).rotation == -10, "Needs you tilts when still")
        try require(CompanionMotion.of(.ready).body.pose(at: nil) == .identity, "Ready is neutral when still")
        let stills = CompanionState.allCases.map { state in
            let motion = CompanionMotion.of(state)
            return [motion.body.pose(at: nil), motion.face.pose(at: nil), motion.eyes.pose(at: nil)]
        }
        try require(Set(stills.map { "\($0)" }).count == CompanionState.allCases.count, "Every state has its own still pose")
        for state in [CompanionState.thinking, .speaking] {
            let motion = CompanionMotion.of(state)
            try require(motion.body.pose(at: nil) != .identity || motion.eyes.pose(at: nil) != .identity,
                        "\(state.displayName) is told apart from Ready when still")
        }
        let blink = CompanionMotion.of(.ready).eyes
        try require(abs(blink.pose(at: 4.8 * 0.42).sy - 0.1) < 0.001 && abs(blink.pose(at: 4.8 * 0.52).sy - 0.1) < 0.001
                    && blink.pose(at: 4.8 * 0.47).sy > 0.9, "Ready blinks twice")
        try require(CompanionState.thinking.accessibilityLabel(name: "Juniper") == "Juniper is thinking"
                    && CompanionState.needsYou.accessibilityLabel(name: "Juniper") == "Juniper needs you"
                    && CompanionState.resting.accessibilityLabel(name: nil) == "Resting", "Accessibility labels read naturally")

        let pickerDisk = CompanionAppearanceFixtureDisk()
        let pickerConfig = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { pickerDisk.contents },
                                       nativeMCP: NativeMCPManager(servers: []),
                                       writeConfiguration: { pickerDisk.contents = $0; pickerDisk.writes += 1 })
        let fake = CompanionAppearanceFixtureStore()
        var draft = CompanionAppearanceDraft(name: "Juniper", appearance: fake.load())
        draft.appearance = CompanionAppearance(shape: .fold, color: .sky)
        draft.name = "Wren"
        try require(fake.saves == 0 && fake.stored == .default && pickerDisk.writes == 0 && pickerConfig["assistant_name"].isEmpty,
                    "Editing without saving changes nothing")
        try draft.commit(config: pickerConfig, store: fake)
        try require(fake.saves == 1 && fake.stored == CompanionAppearance(shape: .fold, color: .sky), "Saving writes the appearance once")
        try require(pickerConfig["assistant_name"] == "Wren" && pickerDisk.contents["assistant_name"] as? String == "Wren"
                    && pickerDisk.writes == 1, "Saving writes a changed name")
        let chat = CompanionShotFixture.store()
        chat.adoptAssistantName("Juniper")
        var renaming = CompanionAppearanceDraft(name: "Juniper", appearance: fake.load())
        renaming.name = "Fern"
        try renaming.commit(config: pickerConfig, store: fake, chat: chat)
        try require(chat.assistantName == "Fern", "A saved rename reaches the running chat identity")
        var untouchedChat = CompanionAppearanceDraft(name: "Fern", appearance: fake.load())
        untouchedChat.appearance = CompanionAppearance(shape: .mallow, color: .rose)
        try untouchedChat.commit(config: pickerConfig, store: fake, chat: chat)
        try require(chat.assistantName == "Fern", "Saving only an appearance leaves the running name alone")

        let brokenDisk = CompanionAppearanceFixtureDisk()
        brokenDisk.contents = ["assistant_name": "Juniper"]
        let brokenConfig = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { brokenDisk.contents },
                                       nativeMCP: NativeMCPManager(servers: []),
                                       writeConfiguration: { _ in throw NativeTaskFixture.Failure.assertion("disk full") })
        let brokenStore = ConfigCompanionAppearanceStore(config: brokenConfig)
        var failing = CompanionAppearanceDraft(name: "Juniper", appearance: brokenStore.load())
        failing.name = "Moss"
        failing.appearance = CompanionAppearance(shape: .fold, color: .sky)
        var threw = false
        do { try failing.commit(config: brokenConfig, store: brokenStore, chat: chat) } catch { threw = true }
        try require(threw, "A failed write surfaces as an error")
        try require(brokenConfig["assistant_name"] == "Juniper" && brokenStore.load() == .default && chat.assistantName == "Fern",
                    "A failed save restores the previous name and appearance and leaves the running identity alone")

        for size in [CGFloat(20), 36, 120, 220] {
            let frame = CGRect(x: 0, y: 0, width: size, height: size)
            for shape in CompanionShape.allCases {
                for state in CompanionState.allCases {
                    let motion = CompanionMotion.of(state)
                    var poses = [motion.body.pose(at: nil)]
                    if let track = motion.body.track {
                        for step in 0...120 { poses.append(track.pose(at: track.duration * Double(step) / 120)) }
                    }
                    for pose in poses {
                        let bounds = CompanionFigure.bodyBounds(shape: shape, pose: pose, size: size)
                        try require(frame.insetBy(dx: -0.01, dy: -0.01).contains(bounds),
                                    "\(shape.displayName) stays inside a \(Int(size)) point frame while \(state.displayName)")
                    }
                }
            }
        }
        try require(VoiceView.companionState(for: .speaking, playing: false) == .thinking
                    && VoiceView.companionState(for: .speaking, playing: true) == .speaking
                    && VoiceView.companionState(for: .listening, playing: false) == .listening
                    && VoiceView.companionState(for: .idle, playing: false) == .ready,
                    "The voice view shows Speaking only while audio really plays")

        let untouched = CompanionAppearanceFixtureDisk()
        let untouchedConfig = ConfigStore(credentialStore: NativeCredentialFixtureStore(), readConfiguration: { untouched.contents },
                                          nativeMCP: NativeMCPManager(servers: []), writeConfiguration: { untouched.contents = $0 })
        var same = CompanionAppearanceDraft(name: "Juniper", appearance: .default)
        same.name = "   "
        try require(same.displayName == "Juniper" && !same.nameChanged, "A blank name keeps the current name")
        try same.commit(config: untouchedConfig, store: CompanionAppearanceFixtureStore())
        try require(untouched.contents["assistant_name"] == nil, "An unchanged name is not written")

        print("  companion appearance OK (shapes, colors, storage, state priority, motion, frame clearance, picker commit, rename, failed save)")
    }
}
