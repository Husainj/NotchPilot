import CoreMediaIO
import Foundation
import Observation

/// Whether any camera is in use. macOS doesn't say by which app.
@MainActor
@Observable
final class CameraMonitor {
    private(set) var isInUse = false
    var onChange: (() -> Void)?

    @ObservationIgnored private var timer: Timer?

    func start() {
        refresh()
        // CoreMediaIO's change notifications are unreliable across camera types; a cheap poll is not.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let inUse = Self.anyCameraRunning()
        guard inUse != isInUse else { return }
        isInUse = inUse
        onChange?()
    }

    nonisolated static func anyCameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }

        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for device in devices {
            var running: UInt32 = 0
            var dataUsed: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &dataUsed, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }
}
