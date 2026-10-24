import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac from idle-sleeping while any module holds a reason to.
/// Uses a standard power assertion (like `caffeinate`), which macOS drops
/// automatically if NotchPilot quits or crashes. Closing the lid still sleeps.
@MainActor
@Observable
public final class KeepAwake {
    public static let shared = KeepAwake()

    public struct Hold: Equatable, Sendable {
        public let label: String
        /// nil = until released.
        public let until: Date?
    }

    public private(set) var holds: [String: Hold] = [:]
    public var isActive: Bool { !holds.isEmpty }

    /// Let the screen turn off while the Mac itself stays awake (saves battery).
    public var allowDisplaySleep: Bool {
        didSet {
            defaults.set(allowDisplaySleep, forKey: "awake.allowDisplaySleep")
            applyAssertion(force: true)
        }
    }
    /// On battery, release everything below this charge. 0 = never.
    public var minimumBattery: Int {
        didSet { defaults.set(minimumBattery, forKey: "awake.minimumBattery") }
    }

    /// Called when holds are dropped for low battery, so the UI can say why.
    @ObservationIgnored public var onLowBatteryStop: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private var assertionType: String?
    @ObservationIgnored private var checkTimer: Timer?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["awake.allowDisplaySleep": true, "awake.minimumBattery": 20])
        allowDisplaySleep = defaults.bool(forKey: "awake.allowDisplaySleep")
        minimumBattery = defaults.integer(forKey: "awake.minimumBattery")
    }

    public func hold(_ id: String, label: String, until: Date? = nil) {
        holds[id] = Hold(label: label, until: until)
        update()
    }

    public func release(_ id: String) {
        guard holds.removeValue(forKey: id) != nil else { return }
        update()
    }

    public func releaseAll() {
        holds = [:]
        update()
    }

    public func hold(for id: String) -> Hold? { holds[id] }

    /// The label shown to the user for why the Mac is being kept awake.
    public var summary: String? {
        holds.values.sorted { ($0.until ?? .distantFuture) > ($1.until ?? .distantFuture) }.first?.label
    }

    /// Drops expired holds and enforces the battery floor. Exposed for tests.
    func check(now: Date, battery: (percent: Int, onBattery: Bool)?) {
        let before = holds.count
        holds = holds.filter { $0.value.until.map { $0 > now } ?? true }
        if !holds.isEmpty, minimumBattery > 0, let battery, battery.onBattery, battery.percent < minimumBattery {
            holds = [:]
            onLowBatteryStop?()
        }
        if holds.count != before { applyAssertion(force: false) }
    }

    private func update() {
        check(now: Date(), battery: Self.readBattery())
        applyAssertion(force: false)
        if isActive, checkTimer == nil {
            checkTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(now: Date(), battery: Self.readBattery()) }
            }
        } else if !isActive {
            checkTimer?.invalidate()
            checkTimer = nil
        }
    }

    private func applyAssertion(force: Bool) {
        let wanted: String? = isActive
            ? (allowDisplaySleep ? kIOPMAssertPreventUserIdleSystemSleep : kIOPMAssertPreventUserIdleDisplaySleep)
            : nil
        guard force || wanted != assertionType else { return }
        if assertionType != nil {
            IOPMAssertionRelease(assertionID)
            assertionType = nil
        }
        guard let wanted else { return }
        let reason = "\(AppInfo.name): \(summary ?? "keep awake")" as CFString
        if IOPMAssertionCreateWithName(wanted as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       reason, &assertionID) == kIOReturnSuccess {
            assertionType = wanted
        }
    }

    public static func readBattery() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (current * 100 / max, d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return nil
    }
}
