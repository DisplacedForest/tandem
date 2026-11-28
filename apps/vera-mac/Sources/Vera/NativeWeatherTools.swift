import Foundation
import Security

struct NativeWeatherRequest: Equatable, Sendable {
    let place: String?
    let days: Int

    init(_ arguments: [String: NativeJSONValue]) throws {
        guard Set(arguments.keys).isSubset(of: ["place", "days"]) else {
            throw NativeToolError.invalidArguments("Use a place and a number of days from 1 to 10.")
        }
        if let value = arguments["place"], value != .null {
            guard let text = arguments.webString("place", limit: 200) else {
                throw NativeToolError.invalidArguments("Enter a city or place name.")
            }
            place = text
        } else {
            place = nil
        }
        if let value = arguments["days"], value != .null {
            guard let count = arguments.webInt("days"), (1...10).contains(count) else {
                throw NativeToolError.invalidArguments("Choose from 1 to 10 days.")
            }
            days = count
        } else {
            days = 1
        }
    }
}

struct NativeWeatherReport: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        let date: String
        let condition: String
        let high: Double
        let low: Double
        let rainChance: Double
    }

    struct Alert: Codable, Equatable, Sendable {
        let headline: String
        let source: String
        let url: URL
    }

    struct Attribution: Codable, Equatable, Sendable {
        let legalURL: URL
        let lightMarkURL: URL
        let darkMarkURL: URL
    }

    let place: String
    let observedAt: Date
    let condition: String
    let temperature: Double
    let feelsLike: Double
    let temperatureUnit: String
    let wind: Double
    let windUnit: String
    let rainChance: Double?
    let days: [Day]
    let alerts: [Alert]
    let attribution: Attribution

    func json() throws -> NativeJSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try NativeJSONValue(any: JSONSerialization.jsonObject(with: encoder.encode(self)))
    }
}

enum NativeWeatherFailure: Error, LocalizedError {
    case placeNeeded, placeNotFound, unavailable, busy

    var errorDescription: String? {
        switch self {
        case .placeNeeded: return "Tell me a city or place to check the weather."
        case .placeNotFound: return "I couldn't find that place. Try a city and country."
        case .unavailable: return "I couldn't get the weather right now. Try again shortly."
        case .busy: return "A location lookup is already running. Try again shortly."
        }
    }
}

struct NativeWeatherSource: Sendable {
    let available: @Sendable () -> Bool
    let fetch: @Sendable (NativeWeatherRequest) async throws -> NativeWeatherReport

    static let live = NativeWeatherSource(available: { NativeWeatherTools.isAvailable }, fetch: { request in
        try await NativeWeatherService.shared.fetch(request)
    })
}

enum NativeWeatherTools {
    static let toolID = "apple-weather"
    static let toolName = "apple_weather"

    static var isAvailable: Bool {
        guard Bundle.main.url(forResource: "embedded", withExtension: "provisionprofile") != nil
            || FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile").path) else { return false }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.developer.weatherkit"] as? Bool == true
    }

    static func definitions(source: NativeWeatherSource = .live) -> [NativeToolDefinition] {
        guard source.available() else { return [] }
        return [NativeToolDefinition(
            id: toolID, name: toolName, title: "Check the weather",
            description: "Reads current conditions and up to ten days of forecast from Apple Weather. When to use: the person asks about weather for a place or their current location. When not to use: historical weather or unattended updates. Effects: read only; a request without a place may ask for Mac location permission once. Returns current conditions, forecast, units, alerts and attribution. Use the returned units and facts. Include weather attribution and preserve alert headlines, issuing agencies and links exactly. If location is unavailable, ask for a city. If weather fails, say so plainly without inventing conditions.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "place": .object(["type": .string("string"), "maxLength": .number(200), "description": .string("City or place. Omit to use the Mac's current location.")]),
                    "days": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(10), "description": .string("Forecast days, including today. Defaults to 1.")]),
                ]),
                "required": .array([]), "additionalProperties": .bool(false),
            ]),
            confirmation: .none, timeout: .seconds(45), effect: .read,
            isAvailable: source.available,
            execute: { arguments in
                let request = try NativeWeatherRequest(arguments)
                guard source.available() else { throw NativeToolError.unavailable }
                do {
                    return try await source.fetch(request).json()
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as NativeWeatherFailure {
                    throw error
                } catch {
                    throw NativeWeatherFailure.unavailable
                }
            },
            examples: [["place": .string("Paris, France"), "days": .number(3)]]
        )]
    }

    static func descriptor(available: Bool = isAvailable) -> [NativeChatToolDescriptor] {
        guard available else { return [] }
        return [NativeChatToolDescriptor(id: toolID, name: "Weather", summary: "Checks current conditions and the forecast.", available: true, setup: "Uses a place you name or asks for your Mac's location.")]
    }
}
