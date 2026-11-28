import Foundation

@MainActor
enum NativeWeatherLiveCheckSelftest {
    static func run() async throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NativeToolError.failed(message) }
        }
        let mode = LaunchPlan.Mode.run(LaunchPlan.weatherLiveMode)
        let arguments = [LaunchPlan.weatherLiveMode, "Paris, France"]
        try require(LaunchPlan.mode(arguments, isolatedModes: []) == mode, "Named weather verification selects its explicit entry")
        try require(LaunchPlan.isHeadless(mode, environment: [:]), "Weather verification isolates user data")
        try require(!LaunchPlan.usesRealData(mode, environment: [:]), "Weather verification never selects saved user configuration")
        try require(OutboundGuard.policy(for: mode, environment: [:]) == .open, "The explicit weather check can reach native Apple services")
        try require(OutboundGuard.policy(for: .run(LaunchPlan.selftestMode), environment: [:]) == .loopbackOnly([]), "Ordinary selftests remain offline")
        for invalid in [[], [""], ["  "], ["Paris", "France"], ["--selftest"], ["Paris\nFrance"], [String(repeating: "a", count: 201)]] {
            do {
                _ = try NativeWeatherLiveCheck.place(invalid)
                throw NativeToolError.failed("Weather verification accepted malformed arguments")
            } catch NativeWeatherLiveCheck.Failure.arguments { }
            try require(LaunchPlan.mode([LaunchPlan.weatherLiveMode] + invalid, isolatedModes: []) == .refused(LaunchPlan.weatherLiveMode), "Malformed weather invocations cannot fall through to normal app startup")
        }
        for mixed in [["--selftest", LaunchPlan.weatherLiveMode, "Paris"], arguments + ["--credential-reauthorization"], arguments + ["--shot", "output.png"]] {
            try require(LaunchPlan.mode(mixed, isolatedModes: []) == .refused(LaunchPlan.weatherLiveMode), "Weather verification rejects combined modes")
        }
        let fixture = NativeWeatherReport(place: "Paris, France", observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            condition: "Clear", temperature: 8, feelsLike: 7, temperatureUnit: "°C", wind: 10, windUnit: "km/h", rainChance: 0,
            days: [.init(date: "2027-01-15", condition: "Clear", high: 10, low: 5, rainChance: 0)], alerts: [],
            attribution: .init(legalURL: URL(string: "https://weatherkit.apple.com/legal")!,
                lightMarkURL: URL(string: "https://weatherkit.apple.com/light.png")!, darkMarkURL: URL(string: "https://weatherkit.apple.com/dark.png")!))
        let source = NativeWeatherSource(available: { true }, fetch: { request in
            guard request.place == "Paris, France", request.days == 1 else { throw NativeWeatherFailure.placeNeeded }
            return fixture
        })
        let result = try await NativeWeatherLiveCheck.check(["Paris, France"], source: source)
        try require(result == fixture, "Live diagnostic uses the real tool adapter, explicit place and complete attribution")
        do {
            _ = try await NativeWeatherLiveCheck.check(["Paris, France"], source: .init(available: { false }, fetch: { _ in
                throw NativeToolError.failed("An unavailable tool must never query its source")
            }))
            throw NativeToolError.failed("Weather verification accepted an unsigned runtime")
        } catch NativeWeatherLiveCheck.Failure.unavailable { }
        do {
            try NativeApplicationEntry.prepare(timeout: 0.02, cleanupTimeout: 0.02) {
                try await Task.sleep(for: .seconds(30))
            }
            throw NativeToolError.failed("Weather verification deadline failed to end a stalled request")
        } catch NativeApplicationEntry.Failure.timeout { }
    }
}
