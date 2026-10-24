import Foundation

/// Parsed MET Norway locationforecast/2.0 "compact" response.
struct WeatherForecast: Equatable, Sendable {
    struct Hour: Equatable, Sendable {
        let time: Date
        let temperature: Double      // °C
        let symbol: String?          // e.g. "partlycloudy_day"
        let precipitation: Double?   // mm next hour
    }

    struct Day: Equatable, Sendable {
        let date: Date
        let low: Double
        let high: Double
        let symbol: String?
    }

    let temperature: Double
    let feelsLike: Double
    let humidity: Double
    let windSpeed: Double           // m/s
    let symbol: String?
    let precipitationNextHour: Double?
    let hours: [Hour]
    let days: [Day]

    static func parse(_ data: Data, now: Date = Date(), calendar: Calendar = .current) -> WeatherForecast? {
        struct Response: Decodable {
            struct Properties: Decodable { let timeseries: [Entry] }
            struct Entry: Decodable {
                let time: Date
                let data: EntryData
            }
            struct EntryData: Decodable {
                let instant: Instant
                let next_1_hours: Period?
                let next_6_hours: Period?
            }
            struct Instant: Decodable { let details: Details }
            struct Details: Decodable {
                let air_temperature: Double?
                let relative_humidity: Double?
                let wind_speed: Double?
            }
            struct Period: Decodable {
                struct Summary: Decodable { let symbol_code: String }
                struct PeriodDetails: Decodable { let precipitation_amount: Double? }
                let summary: Summary?
                let details: PeriodDetails?
            }
            let properties: Properties
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(Response.self, from: data) else { return nil }
        // Entries from the current hour onwards.
        let series = response.properties.timeseries.filter { $0.time > now.addingTimeInterval(-3600) }
        guard let current = series.first, let temp = current.data.instant.details.air_temperature else { return nil }

        let details = current.data.instant.details
        let wind = details.wind_speed ?? 0
        let hours = series.prefix(13).dropFirst().compactMap { entry -> Hour? in
            guard let t = entry.data.instant.details.air_temperature else { return nil }
            return Hour(time: entry.time, temperature: t,
                        symbol: entry.data.next_1_hours?.summary?.symbol_code ?? entry.data.next_6_hours?.summary?.symbol_code,
                        precipitation: entry.data.next_1_hours?.details?.precipitation_amount)
        }

        let byDay = Dictionary(grouping: series) { calendar.startOfDay(for: $0.time) }
        let days = byDay.keys.sorted().prefix(7).compactMap { day -> Day? in
            let entries = byDay[day]!
            let temps = entries.compactMap(\.data.instant.details.air_temperature)
            guard let low = temps.min(), let high = temps.max() else { return nil }
            // Prefer the midday 6-hour summary as the day's icon.
            let midday = entries.min { abs(calendar.component(.hour, from: $0.time) - 12) < abs(calendar.component(.hour, from: $1.time) - 12) }
            return Day(date: day, low: low, high: high,
                       symbol: midday?.data.next_6_hours?.summary?.symbol_code ?? midday?.data.next_1_hours?.summary?.symbol_code)
        }

        return WeatherForecast(
            temperature: temp,
            feelsLike: feelsLike(temperature: temp, windSpeed: wind),
            humidity: details.relative_humidity ?? 0,
            windSpeed: wind,
            symbol: current.data.next_1_hours?.summary?.symbol_code ?? current.data.next_6_hours?.summary?.symbol_code,
            precipitationNextHour: current.data.next_1_hours?.details?.precipitation_amount,
            hours: Array(hours),
            days: days
        )
    }

    /// Wind chill below 10 °C (Environment Canada formula); otherwise the air temperature.
    static func feelsLike(temperature t: Double, windSpeed ms: Double) -> Double {
        let kmh = ms * 3.6
        guard t <= 10, kmh > 4.8 else { return t }
        let v = pow(kmh, 0.16)
        return 13.12 + 0.6215 * t - 11.37 * v + 0.3965 * t * v
    }
}

enum WeatherSymbol {
    /// Maps MET Norway symbol codes to SF Symbols.
    static func sfSymbol(for code: String?) -> String {
        guard let code else { return "cloud" }
        let night = code.hasSuffix("_night") || code.hasSuffix("_polartwilight")
        let base = code.split(separator: "_").first.map(String.init) ?? code
        switch base {
        case "clearsky": return night ? "moon.stars.fill" : "sun.max.fill"
        case "fair", "partlycloudy": return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case "cloudy": return "cloud.fill"
        case "fog": return "cloud.fog.fill"
        default: break
        }
        if base.contains("thunder") { return "cloud.bolt.rain.fill" }
        if base.contains("snow") { return "cloud.snow.fill" }
        if base.contains("sleet") { return "cloud.sleet.fill" }
        if base.contains("heavyrain") { return "cloud.heavyrain.fill" }
        if base.contains("rain") { return base.contains("showers") ? (night ? "cloud.moon.rain.fill" : "cloud.sun.rain.fill") : "cloud.rain.fill" }
        return "cloud"
    }

    static func description(for code: String?) -> String {
        guard let code else { return "" }
        let base = code.split(separator: "_").first.map(String.init) ?? code
        let names = ["clearsky": "Clear", "fair": "Mostly clear", "partlycloudy": "Partly cloudy", "cloudy": "Cloudy", "fog": "Fog"]
        if let name = names[base] { return name }
        var text = base
        for (word, replacement) in [("heavy", "heavy "), ("light", "light "), ("showers", " showers"), ("andthunder", " and thunder")] {
            text = text.replacingOccurrences(of: word, with: replacement)
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
