import Foundation
import IOKit.ps
import Observation

/// Internal battery state, updated via IOKit power-source notifications.
@MainActor
@Observable
final class BatteryMonitor {
    private(set) var hasBattery = false
    private(set) var percent = 0
    private(set) var isCharging = false
    private(set) var isPluggedIn = false
    /// Minutes, when macOS has an estimate.
    private(set) var timeRemaining: Int?

    /// Called when the charger is connected (not on first read).
    @ObservationIgnored var onPluggedIn: (() -> Void)?
    @ObservationIgnored private var source: CFRunLoopSource?

    func start() {
        update(notify: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().update(notify: true)
            }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    private func update(notify: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return }
        let battery = list.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        guard let battery else {
            hasBattery = false
            return
        }
        let wasPluggedIn = isPluggedIn
        hasBattery = true
        let current = battery[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = battery[kIOPSMaxCapacityKey] as? Int ?? 100
        percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 0
        isCharging = battery[kIOPSIsChargingKey] as? Bool ?? false
        isPluggedIn = (battery[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let minutes = (isCharging ? battery[kIOPSTimeToFullChargeKey] : battery[kIOPSTimeToEmptyKey]) as? Int
        timeRemaining = (minutes ?? -1) > 0 ? minutes : nil
        if notify, isPluggedIn, !wasPluggedIn { onPluggedIn?() }
    }

    var symbolName: String {
        if isCharging || isPluggedIn { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
