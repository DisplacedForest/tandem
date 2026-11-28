import CoreLocation
import Foundation
import MapKit
import WeatherKit

@MainActor
final class NativeWeatherService {
    static let shared = NativeWeatherService()
    private let location = NativeWeatherLocation()

    func fetch(_ request: NativeWeatherRequest) async throws -> NativeWeatherReport {
        let coordinate: CLLocation
        let place: String
        let timeZone: TimeZone
        if let named = request.place {
            guard let query = MKGeocodingRequest(addressString: named),
                  let match = try await query.mapItems.first else {
                throw NativeWeatherFailure.placeNotFound
            }
            coordinate = match.location
            place = match.name ?? named
            timeZone = match.timeZone ?? .current
        } else {
            coordinate = try await location.current()
            let query = MKReverseGeocodingRequest(location: coordinate)
            let match = try? await query?.mapItems.first
            place = match?.name ?? "Current location"
            timeZone = match?.timeZone ?? .current
        }
        try Task.checkCancellation()
        async let result = WeatherService.shared.weather(for: coordinate)
        async let credit = WeatherService.shared.attribution
        let (weather, attribution) = try await (result, credit)
        let units = NativeWeatherUnits(locale: .current)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return NativeWeatherReport(
            place: place, observedAt: weather.currentWeather.date,
            condition: weather.currentWeather.condition.description,
            temperature: units.temperature(weather.currentWeather.temperature),
            feelsLike: units.temperature(weather.currentWeather.apparentTemperature),
            temperatureUnit: units.temperatureSymbol,
            wind: units.speed(weather.currentWeather.wind.speed), windUnit: units.speedSymbol,
            rainChance: weather.dailyForecast.first?.precipitationChance,
            days: weather.dailyForecast.prefix(request.days).map {
                NativeWeatherReport.Day(date: formatter.string(from: $0.date), condition: $0.condition.description,
                    high: units.temperature($0.highTemperature), low: units.temperature($0.lowTemperature), rainChance: $0.precipitationChance)
            },
            alerts: (weather.weatherAlerts ?? []).map {
                NativeWeatherReport.Alert(headline: $0.summary, source: $0.source, url: $0.detailsURL)
            },
            attribution: NativeWeatherReport.Attribution(legalURL: attribution.legalPageURL,
                lightMarkURL: attribution.combinedMarkLightURL, darkMarkURL: attribution.combinedMarkDarkURL)
        )
    }


}

struct NativeWeatherUnits {
    let fahrenheit: Bool
    let imperialSpeed: Bool

    init(locale: Locale) {
        fahrenheit = locale.measurementSystem == .us
        imperialSpeed = locale.measurementSystem == .us || locale.measurementSystem == .uk
    }

    var temperatureSymbol: String { fahrenheit ? "°F" : "°C" }
    var speedSymbol: String { imperialSpeed ? "mph" : "km/h" }

    func temperature(_ value: Measurement<UnitTemperature>) -> Double {
        value.converted(to: fahrenheit ? .fahrenheit : .celsius).value
    }

    func speed(_ value: Measurement<UnitSpeed>) -> Double {
        value.converted(to: imperialSpeed ? .milesPerHour : .kilometersPerHour).value
    }
}

@MainActor
final class NativeWeatherLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation, Error>?
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func current() async throws -> CLLocation {
        guard pending == nil else { throw NativeWeatherFailure.busy }
        guard CLLocationManager.locationServicesEnabled(), manager.authorizationStatus != .denied,
              manager.authorizationStatus != .restricted else { throw NativeWeatherFailure.placeNeeded }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    self?.finish(.failure(NativeWeatherFailure.placeNeeded))
                }
                if manager.authorizationStatus == .notDetermined {
                    manager.requestWhenInUseAuthorization()
                } else {
                    manager.requestLocation()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard pending != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: finish(.failure(NativeWeatherFailure.placeNeeded))
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 300 }) else { return }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(NativeWeatherFailure.placeNeeded))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let continuation = pending
        pending = nil
        timeout?.cancel()
        timeout = nil
        manager.stopUpdatingLocation()
        continuation?.resume(with: result)
    }
}
