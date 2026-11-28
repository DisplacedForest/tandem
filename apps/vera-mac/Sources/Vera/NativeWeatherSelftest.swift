import Foundation

enum NativeWeatherSelftest {
    static func run() async throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NativeToolError.failed(message) }
        }
        let fixture = report()
        let absent = NativeWeatherSource(available: { false }, fetch: { _ in fixture })
        try require(NativeWeatherTools.definitions(source: absent).isEmpty, "Weather is absent without a signed capability")
        try require(NativeWeatherTools.descriptor(available: false).isEmpty, "Unavailable weather has no settings entry")
        let source = NativeWeatherSource(available: { true }, fetch: { request in
            guard request.place != nil else { throw NativeWeatherFailure.placeNeeded }
            return fixture
        })
        let tool = NativeWeatherTools.definitions(source: source)[0]
        try require(NativeToolRegistry.rejection(tool) == nil, "Weather schema and example must pass the shipped contract")
        try require(tool.effect == .read && tool.confirmation == .none, "Weather needs no per-call confirmation")
        let defaults = try NativeWeatherRequest([:])
        try require(defaults.place == nil && defaults.days == 1, "Weather defaults to current location and today")
        let request = try tool.validatedArguments("{\"place\":\"Paris, France\",\"days\":3}")
        let result = try await tool.execute(request)
        try require(result == fixture.json(), "Weather preserves typed values, units, forecasts and attribution")
        for invalid in ["{\"days\":0}", "{\"days\":11}", "{\"days\":1.5}", "{\"place\":\"\"}", "{\"place\":\"a\\nb\"}", "{\"unknown\":true}"] {
            do {
                let values = try tool.validatedArguments(invalid)
                _ = try NativeWeatherRequest(values)
                throw NativeToolError.failed("Invalid weather arguments were accepted")
            } catch NativeToolError.invalidArguments { }
        }
        do {
            _ = try await tool.execute([:])
            throw NativeToolError.failed("Denied current location should ask for a place")
        } catch NativeWeatherFailure.placeNeeded { }
        _ = try await tool.execute(["place": .string("Paris, France")])
        let failed = NativeWeatherTools.definitions(source: NativeWeatherSource(available: { true }, fetch: { _ in throw URLError(.notConnectedToInternet) }))[0]
        do {
            _ = try await failed.execute([:])
            throw NativeToolError.failed("Weather failure should not create conditions")
        } catch NativeWeatherFailure.unavailable { }
        let us = NativeWeatherUnits(locale: Locale(identifier: "en_US"))
        let uk = NativeWeatherUnits(locale: Locale(identifier: "en_GB"))
        let fr = NativeWeatherUnits(locale: Locale(identifier: "fr_FR"))
        try require(us.temperatureSymbol == "°F" && us.speedSymbol == "mph", "US weather uses Fahrenheit and miles per hour")
        try require(uk.temperatureSymbol == "°C" && uk.speedSymbol == "mph", "UK weather uses Celsius and miles per hour")
        try require(fr.temperatureSymbol == "°C" && fr.speedSymbol == "km/h", "Metric weather uses Celsius and kilometers per hour")
        try require(abs(us.temperature(Measurement(value: 0, unit: .celsius)) - 32) < 0.001, "Temperature conversion is deterministic")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let raw = String(decoding: try encoder.encode(fixture), as: UTF8.self)
        let activity = NativeToolActivity(id: "weather-fixture", toolID: tool.id, name: tool.name, title: tool.title, round: 1,
            request: "{}", result: raw, state: .succeeded, confirmationRequired: false)
        try require(NativeWeatherAttribution.report(in: [activity]) == fixture, "Weather attribution survives the stored tool activity")
        try require(!NativeCompanionWorker.allowsTool(tool.id, unattended: true, typedRequest: "Check weather")
                    && !NativeCompanionWorker.allowsTool(tool.id, unattended: false, typedRequest: "")
                    && NativeCompanionWorker.allowsTool(tool.id, unattended: false, typedRequest: "Check weather"),
                    "Weather is limited to explicit manual work")
        var checkpoint = NativeCompanionCheckpoint()
        _ = checkpoint.numbered(result, definition: tool)
        let restored = try JSONDecoder().decode(NativeCompanionCheckpoint.self, from: checkpoint.encoded())
        let finished = try NativeCompanionWorker.report(restored, assignment: "Check weather", text: "It is clear.")
        let decoded = try JSONDecoder().decode(NativeResearchTaskResult.self, from: finished.result!)
        try require(decoded.weatherResult != nil, "Delegated weather preserves attribution separately from generated prose")
        var delivered = activity
        delivered.result = decoded.weatherResult
        try require(NativeWeatherAttribution.report(in: [delivered]) == fixture, "Saved delegated weather keeps unmodified alerts and attribution")
        var failedActivity = activity
        failedActivity.state = .failed
        try require(NativeWeatherAttribution.report(in: [failedActivity]) == nil, "Failed weather cannot surface fabricated attribution")
        try require(NativeWeatherAttribution.allowed(URL(string: "https://weatherkit.apple.com/legal")!), "Apple attribution is allowed")
        for url in ["http://weatherkit.apple.com/legal", "https://apple.com.example/legal", "file:///tmp/weather", "https://user@weatherkit.apple.com/legal"] {
            try require(!NativeWeatherAttribution.allowed(URL(string: url)!), "Weather attribution refuses unexpected destinations")
        }
    }

    private static func report() -> NativeWeatherReport {
        NativeWeatherReport(place: "Paris, France", observedAt: Date(timeIntervalSince1970: 1_800_000_000), condition: "Clear",
            temperature: 8, feelsLike: 7, temperatureUnit: "°C", wind: 10, windUnit: "km/h", rainChance: 0.2,
            days: [.init(date: "2027-01-15", condition: "Clear", high: 10, low: 5, rainChance: 0.2)],
            alerts: [.init(headline: "Wind warning", source: "Example weather agency", url: URL(string: "https://weatherkit.apple.com/alert")!)],
            attribution: .init(legalURL: URL(string: "https://weatherkit.apple.com/legal")!,
                lightMarkURL: URL(string: "https://weatherkit.apple.com/light.png")!, darkMarkURL: URL(string: "https://weatherkit.apple.com/dark.png")!))
    }
}
