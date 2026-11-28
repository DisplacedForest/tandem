import Foundation

@MainActor
enum NativeWeatherLiveCheck {
    enum Failure: Error, LocalizedError, Equatable {
        case arguments, unavailable, response

        var errorDescription: String? {
            switch self {
            case .arguments: return "Use --weather-live-check with one quoted city or place name."
            case .unavailable: return "This app is not signed for Apple Weather."
            case .response: return "Apple Weather returned an incomplete response."
            }
        }
    }

    nonisolated static func place(_ arguments: [String]) throws -> String {
        guard arguments.count == 1 else { throw Failure.arguments }
        let text = arguments[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 200, !text.hasPrefix("-"),
              !arguments[0].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.arguments }
        return text
    }

    static func check(_ arguments: [String], source: NativeWeatherSource = .live) async throws -> NativeWeatherReport {
        let named = try place(arguments)
        guard let tool = NativeWeatherTools.definitions(source: source).first else { throw Failure.unavailable }
        let result = try await tool.execute(["place": .string(named), "days": .number(1)])
        let data = try JSONSerialization.data(withJSONObject: result.any)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(NativeWeatherReport.self, from: data)
        guard !report.place.isEmpty, !report.condition.isEmpty, !report.days.isEmpty,
              report.temperature.isFinite, report.wind.isFinite,
              NativeWeatherAttribution.allowed(report.attribution.legalURL),
              NativeWeatherAttribution.allowed(report.attribution.lightMarkURL),
              NativeWeatherAttribution.allowed(report.attribution.darkMarkURL) else { throw Failure.response }
        return report
    }

    static func main(_ arguments: [String]) -> Never {
        do {
            _ = try place(arguments)
            try NativeApplicationEntry.prepare(timeout: 45, cleanupTimeout: 1) {
                let report = try await check(arguments)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(report)
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            }
            exit(0)
        } catch NativeApplicationEntry.Failure.timeout {
            FileHandle.standardError.write(Data("Weather check timed out.\n".utf8))
            exit(1)
        } catch let error as Failure {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(error == .arguments ? 2 : 1)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
