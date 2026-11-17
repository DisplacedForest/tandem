import Foundation

enum NativePreferenceLabel: Equatable, Sendable {
    case standing
    case nothing
    case remove(Int)
    case removeUnclear
    case permission

    var writes: Bool {
        switch self {
        case .standing, .remove: return true
        case .nothing, .removeUnclear, .permission: return false
        }
    }
}

enum NativePreferenceExampleKind: String, CaseIterable, Sendable {
    case preference
    case removal
    case oneTime
    case question
    case attribution
    case nearMiss
    case permission
}

struct NativePreferenceExample: Sendable {
    let text: String
    let label: NativePreferenceLabel
    let kind: NativePreferenceExampleKind
    let heldOut: Bool
    var saved: [String] = []
    var previous: Int?

    func body() -> String {
        let items = saved.enumerated().map { index, statement in
            NativePreferenceClassifier.Saved(id: String(index + 1), statement: statement, fromPreviousMessage: previous == index + 1)
        }
        return NativePreferenceClassifier.body(text: text, saved: items)
    }

    static func predicted(_ classification: NativePreferenceClassifier.Classification) -> NativePreferenceLabel? {
        switch classification {
        case .preference: return .standing
        case .rejected: return .nothing
        case .remove(let number): return .remove(number)
        case .removeUnclear: return .removeUnclear
        case .permission: return .permission
        case .tooLong, .invalid: return nil
        }
    }
}

struct NativePreferenceScore: Equatable, Sendable {
    var standing = 0
    var saved = 0
    var removals = 0
    var removedRight = 0
    var others = 0
    var falseWrites = 0
    var unreadable = 0
    var misses: [String] = []

    mutating func add(_ example: NativePreferenceExample, _ predicted: NativePreferenceLabel?) {
        if predicted == nil { unreadable += 1 }
        switch example.label {
        case .standing:
            standing += 1
            if predicted == .standing { saved += 1 }
        case .remove:
            removals += 1
            if predicted == example.label { removedRight += 1 }
            if let predicted, predicted.writes, predicted != example.label { falseWrites += 1 }
        case .nothing, .removeUnclear, .permission:
            others += 1
            if let predicted, predicted.writes { falseWrites += 1 }
        }
        if predicted != example.label { misses.append(example.text) }
    }

    var line: String {
        func share(_ part: Int, _ whole: Int) -> String { whole == 0 ? "none" : "\(part) of \(whole)" }
        return "saved \(share(saved, standing)), removed the right one \(share(removedRight, removals)), wrote when it shouldn't \(share(falseWrites, others + removals)), unreadable \(unreadable)"
    }
}

@MainActor
enum NativePreferenceEval {
    static let mode = "--preferences-live"

    static func score(_ examples: [NativePreferenceExample], classify: (String) async -> String?) async -> NativePreferenceScore {
        var score = NativePreferenceScore()
        for example in examples {
            let raw = await classify(example.body())
            score.add(example, NativePreferenceExample.predicted(NativePreferenceClassifier.classify(raw, savedCount: example.saved.count)))
        }
        return score
    }

    static func run(arguments: [String]) async -> Int32 {
        guard let override = ProcessInfo.processInfo.environment["VERA_CONFIG_DIR"], !override.isEmpty,
              !AppLocations.holdsRealFiles(URL(fileURLWithPath: override).standardizedFileURL) else {
            print("preferences-live: set VERA_CONFIG_DIR to a separate folder holding a copy of config.json. It never runs against your own data.")
            return 2
        }
        let config = ConfigStore(writeConfiguration: { _ in })
        guard let native = config.nativeResolved else {
            print("preferences-live: no chat profile is configured in \(override)/config.json.")
            return 2
        }
        let runs = arguments.firstIndex(of: "--runs").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 3
        let transport = NativeChatClient.foreground(config: native)
        print("preferences-live: \(native.model), \(NativePreferenceLabeledSet.examples.count) messages, \(runs) runs")
        for run in 1...max(runs, 1) {
            for heldOut in [false, true] {
                let examples = NativePreferenceLabeledSet.examples.filter { $0.heldOut == heldOut }
                let result = await score(examples) { body in
                    await NativePreferenceClassifier.request(transport: transport, model: native.model, body: body)
                }
                print("preferences-live: run \(run) \(heldOut ? "held-out" : "development"): \(result.line)")
                for text in result.misses { print("preferences-live:   missed \(text)") }
            }
        }
        return 0
    }
}
