import CoreLocation
import Foundation
import NotchShell
import Observation

/// Fetches the forecast from MET Norway (free, CC BY 4.0; requires an
/// identifying User-Agent, caching, and ≤4-decimal coordinates).
@MainActor
@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable {
        case idle, locating, loading, ready, needsLocation, failed(String)
    }

    private(set) var forecast: WeatherForecast?
    private(set) var status: Status = .idle
    private(set) var placeName: String?

    /// Manual city; empty means "use current location".
    var city: String {
        didSet {
            UserDefaults.standard.set(city, forKey: "weather.city")
            coordinate = nil
            lastModified = nil
            refresh(force: true)
        }
    }
    var useFahrenheit: Bool {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "weather.fahrenheit") }
    }

    // MET Norway requires contact info in the User-Agent; the project URL is accepted.
    private static let userAgent = "\(AppInfo.name)/\(AppInfo.version) (+\(AppInfo.githubRepo.absoluteString))"
    private static let endpoint = "https://api.met.no/weatherapi/locationforecast/2.0/compact"

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var coordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var expires: Date?
    @ObservationIgnored private var lastModified: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var isActive = false

    override init() {
        let d = UserDefaults.standard
        city = d.string(forKey: "weather.city") ?? ""
        useFahrenheit = d.object(forKey: "weather.fahrenheit") as? Bool ?? (Locale.current.measurementSystem == .us)
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Starts updates. Called the first time the Weather tab is shown, so the
    /// location prompt never appears unprompted.
    func activate() {
        guard !isActive else { refresh(force: false); return }
        isActive = true
        refresh(force: true)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                self?.refresh(force: false)
            }
        }
    }

    func deactivate() {
        isActive = false
        refreshTask?.cancel()
    }

    func refresh(force: Bool) {
        guard isActive else { return }
        if !force, let expires, expires > Date() { return }
        if let coordinate {
            Task { await fetch(coordinate) }
        } else if !city.trimmingCharacters(in: .whitespaces).isEmpty {
            geocodeCity()
        } else {
            requestLocation()
        }
    }

    // MARK: - Location

    private func requestLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            status = .locating
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .needsLocation
        default:
            status = .locating
            locationManager.requestLocation()
        }
    }

    private func geocodeCity() {
        status = .locating
        let query = city
        Task {
            let placemarks = try? await CLGeocoder().geocodeAddressString(query)
            guard let place = placemarks?.first, let location = place.location else {
                status = .failed("Couldn't find “\(query)”.")
                return
            }
            placeName = place.locality ?? place.name ?? query
            coordinate = location.coordinate
            await fetch(location.coordinate)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isActive, self.coordinate == nil, self.city.isEmpty else { return }
            self.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        Task { @MainActor in
            self.coordinate = coordinate
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first
            self.placeName = placemark?.locality ?? placemark?.name
            await self.fetch(coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.forecast == nil { self.status = .needsLocation }
        }
    }

    // MARK: - Fetch

    private func fetch(_ coordinate: CLLocationCoordinate2D) async {
        // MET requires at most 4 decimals.
        func round4(_ v: Double) -> String { String(format: "%.4f", v) }
        guard var components = URLComponents(string: Self.endpoint) else { return }
        components.queryItems = [URLQueryItem(name: "lat", value: round4(coordinate.latitude)),
                                 URLQueryItem(name: "lon", value: round4(coordinate.longitude))]
        guard let url = components.url else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let lastModified, forecast != nil { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        if forecast == nil { status = .loading }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if let expiresHeader = http?.value(forHTTPHeaderField: "Expires") {
                expires = Self.httpDate(expiresHeader)
            }
            if http?.statusCode == 304 { status = .ready; return }
            guard http?.statusCode == 200, let parsed = WeatherForecast.parse(data) else {
                status = forecast == nil ? .failed("Weather is unavailable right now.") : .ready
                return
            }
            lastModified = http?.value(forHTTPHeaderField: "Last-Modified")
            forecast = parsed
            status = .ready
        } catch {
            status = forecast == nil ? .failed("No internet connection.") : .ready
        }
    }

    private static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }

    func format(_ celsius: Double) -> String {
        let value = useFahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°"
    }
}
