import NotchShell
import SwiftUI

@MainActor
@Observable
public final class WeatherModule: NotchModule {
    public let id = "weather"
    public let title = "Weather"
    public let systemImage = "cloud.sun"

    let service = WeatherService()

    public init() {}

    public func start(context: NotchContext) {
        // Resume updates if the user has used the tab before (no surprise prompts).
        if UserDefaults.standard.bool(forKey: "weather.activated") { service.activate() }
    }

    public func stop() { service.deactivate() }

    public func makeExpandedView() -> AnyView {
        AnyView(WeatherView(service: service))
    }

    public func makeHeaderAccessory() -> AnyView? {
        guard let forecast = service.forecast else { return nil }
        return AnyView(HStack(spacing: 3) {
            Image(systemName: WeatherSymbol.sfSymbol(for: forecast.symbol)).symbolRenderingMode(.multicolor)
            Text(service.format(forecast.temperature)).monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.8)))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(WeatherSettingsView(service: service))
    }
}

private struct WeatherView: View {
    let service: WeatherService

    var body: some View {
        Group {
            if let forecast = service.forecast {
                content(forecast)
            } else {
                statusView
            }
        }
        .onAppear {
            UserDefaults.standard.set(true, forKey: "weather.activated")
            service.activate()
        }
    }

    private func content(_ f: WeatherForecast) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: WeatherSymbol.sfSymbol(for: f.symbol))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(service.format(f.temperature)).font(.system(size: 30, weight: .semibold))
                        Text(WeatherSymbol.description(for: f.symbol)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    }
                    Text([service.placeName, "Feels \(service.format(f.feelsLike))", "Humidity \(Int(f.humidity))%",
                          "Wind \(Int(f.windSpeed.rounded())) m/s", f.precipitationNextHour.map { "Rain \($0) mm/h" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(f.days.prefix(4), id: \.date) { day in
                        HStack(spacing: 6) {
                            Text(Calendar.current.isDateInToday(day.date) ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                                .frame(width: 38, alignment: .leading)
                            Image(systemName: WeatherSymbol.sfSymbol(for: day.symbol)).symbolRenderingMode(.multicolor).frame(width: 18)
                            Text("\(service.format(day.low)) / \(service.format(day.high))").monospacedDigit()
                        }
                        .font(.system(size: 10))
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(f.hours, id: \.time) { hour in
                    VStack(spacing: 4) {
                        Text(hour.time.formatted(.dateTime.hour()))
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                        Image(systemName: WeatherSymbol.sfSymbol(for: hour.symbol))
                            .symbolRenderingMode(.multicolor).font(.system(size: 13))
                        Text(service.format(hour.temperature)).font(.system(size: 10, weight: .medium).monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            Text("Weather data: MET Norway (CC BY 4.0)")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    @ViewBuilder private var statusView: some View {
        VStack(spacing: 8) {
            switch service.status {
            case .needsLocation:
                Text("Allow location access, or set a city in Settings → Weather.")
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
                Button("Open Location Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
                .buttonStyle(.link).font(.caption)
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.white.opacity(0.6))
                Button("Try Again") { service.refresh(force: true) }.buttonStyle(.link).font(.caption)
            default:
                ProgressView().controlSize(.small)
                Text("Loading weather…").font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WeatherSettingsView: View {
    @Bindable var service: WeatherService
    @State private var cityDraft = ""

    var body: some View {
        Form {
            LabeledContent("City") {
                HStack {
                    TextField("Use current location", text: $cityDraft)
                        .onSubmit { service.city = cityDraft }
                    Button("Set") { service.city = cityDraft }
                }
            }
            Text("Leave empty to use your current location.").font(.caption).foregroundStyle(.secondary)
            Toggle("Show temperatures in °F", isOn: $service.useFahrenheit)
            Text("Weather data from MET Norway, licensed under CC BY 4.0.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { cityDraft = service.city }
    }
}
