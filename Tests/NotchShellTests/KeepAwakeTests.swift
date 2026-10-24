import Foundation
import IOKit.pwr_mgt
import Testing
@testable import NotchShell

@MainActor
private func makeAwake() -> KeepAwake {
    let defaults = UserDefaults(suiteName: "notch-awake-\(UUID().uuidString)")!
    return KeepAwake(defaults: defaults)
}

/// Whether the app's own assertion is currently registered with macOS.
private func notchAssertionExists() -> Bool {
    var raw: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
          let byPID = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
    let mine = byPID[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
    return mine.contains { ($0[kIOPMAssertionNameKey] as? String)?.hasPrefix("\(AppInfo.name):") == true }
}

@MainActor @Test func holdsCreateAndReleaseTheAssertion() {
    let awake = makeAwake()
    awake.hold("a", label: "Test")
    #expect(awake.isActive)
    #expect(notchAssertionExists())
    awake.hold("b", label: "Other", until: Date().addingTimeInterval(60))
    awake.release("a")
    #expect(awake.isActive)
    awake.release("b")
    #expect(!awake.isActive)
    #expect(!notchAssertionExists())
}

@MainActor @Test func expiredHoldsAndLowBatteryStop() {
    let awake = makeAwake()
    let now = Date()
    awake.hold("timer", label: "30m", until: now.addingTimeInterval(1800))
    awake.hold("forever", label: "∞")
    awake.check(now: now.addingTimeInterval(1801), battery: nil)
    #expect(awake.hold(for: "timer") == nil)
    #expect(awake.hold(for: "forever") != nil)

    var stopped = false
    awake.onLowBatteryStop = { stopped = true }
    awake.minimumBattery = 20
    awake.check(now: now, battery: (percent: 25, onBattery: true))
    #expect(awake.isActive)
    awake.check(now: now, battery: (percent: 15, onBattery: false)) // charging: keep going
    #expect(awake.isActive)
    awake.check(now: now, battery: (percent: 15, onBattery: true))
    #expect(!awake.isActive && stopped)
    #expect(!notchAssertionExists())
}
