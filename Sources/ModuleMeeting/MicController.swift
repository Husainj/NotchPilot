import AppKit
import CoreAudio
import Observation

/// An app currently recording from the microphone.
struct MicClient: Equatable, Sendable, Identifiable {
    let bundleID: String
    let name: String
    let pid: pid_t

    var id: String { bundleID }
}

/// Watches the default input device: who's using it, and mutes it system-wide.
/// Uses CoreAudio property listeners; needs no permission (nothing is recorded).
@MainActor
@Observable
final class MicController {
    private(set) var deviceID = AudioObjectID(kAudioObjectUnknown)
    private(set) var deviceName = ""
    private(set) var isMuted = false
    /// Apps other than NotchPilot using the mic right now.
    private(set) var clients: [MicClient] = []
    /// False when the device supports neither a mute switch nor an input volume.
    private(set) var canMute = true
    /// Per-app attribution needs macOS 14.2; earlier versions only know "in use".
    private(set) var deviceRunning = false
    var onChange: (() -> Void)?

    var isInUse: Bool {
        if #available(macOS 14.2, *) { return !clients.isEmpty }
        return deviceRunning
    }

    @ObservationIgnored private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let mutedKey = "meeting.mutedByNotch"
    private static let savedVolumeKey = "meeting.savedVolume"

    func start() {
        // If NotchPilot quit (or crashed) while muted, don't leave the user silently muted.
        if defaults.bool(forKey: Self.mutedKey) {
            switchDevice()
            setMuted(false)
        }
        addSystemListener(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.switchDevice() }
        if #available(macOS 14.2, *) {
            addSystemListener(kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refreshClients() }
        }
        switchDevice()
    }

    func stop() {
        if defaults.bool(forKey: Self.mutedKey) { setMuted(false) }
        removeDeviceListeners()
        for (address, block) in systemListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        systemListeners = []
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Mute

    func toggleMute() { setMuted(!isMuted) }

    func setMuted(_ muted: Bool) {
        guard deviceID != kAudioObjectUnknown else { return }
        if CA.isSettable(deviceID, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput) {
            CA.setUInt32(deviceID, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput, muted ? 1 : 0)
        } else if let volumeElement = CA.volumeElement(deviceID) {
            // No mute switch: drop the input volume to zero and restore it later.
            if muted {
                let current = CA.getFloat(deviceID, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput,
                                          element: volumeElement) ?? 0.75
                if current > 0 { defaults.set(current, forKey: Self.savedVolumeKey) }
                CA.setVolume(deviceID, 0)
            } else {
                let saved = defaults.object(forKey: Self.savedVolumeKey) as? Float ?? 0.75
                CA.setVolume(deviceID, saved > 0 ? saved : 0.75)
            }
        } else {
            canMute = false
            return
        }
        defaults.set(muted, forKey: Self.mutedKey)
        refreshMute()
    }

    // MARK: - Device

    private func switchDevice() {
        let wasMutedByNotch = defaults.bool(forKey: Self.mutedKey)
        let newID = CA.defaultInputDevice()
        guard newID != deviceID else { return }
        // Follow the user to the new mic: unmute the old one, mute the new one.
        if wasMutedByNotch, deviceID != kAudioObjectUnknown { setMuted(false) }
        removeDeviceListeners()
        deviceID = newID
        deviceName = CA.deviceName(newID) ?? "Microphone"
        canMute = CA.isSettable(newID, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
            || CA.volumeElement(newID) != nil
        addDeviceListener(kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioObjectPropertyScopeGlobal) { [weak self] in
            self?.refreshRunning()
        }
        addDeviceListener(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput) { [weak self] in self?.refreshMute() }
        addDeviceListener(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput) { [weak self] in self?.refreshMute() }
        if wasMutedByNotch { setMuted(true) }
        refreshMute()
        refreshRunning()
    }

    private func refreshMute() {
        let muteFlag = CA.getUInt32(deviceID, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput) == 1
        let volumeZero = CA.volumeElement(deviceID).flatMap {
            CA.getFloat(deviceID, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: $0)
        }.map { $0 <= 0.001 } ?? false
        let muted = muteFlag || volumeZero
        if muted != isMuted {
            isMuted = muted
            onChange?()
        }
        // Someone unmuted in System Settings: forget our flag.
        if !muted { defaults.set(false, forKey: Self.mutedKey) }
    }

    private func refreshRunning() {
        deviceRunning = CA.getUInt32(deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere,
                                     scope: kAudioObjectPropertyScopeGlobal) == 1
        refreshClients()
        // Per-process "is recording" flags have no device-level listener; poll while the mic runs.
        if deviceRunning, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshClients() }
            }
        } else if !deviceRunning {
            pollTimer?.invalidate()
            pollTimer = nil
        }
        onChange?()
    }

    private func refreshClients() {
        var result: [MicClient] = []
        if #available(macOS 14.2, *) {
            let regular = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in app.bundleIdentifier.map { (bundleID: $0, name: app.localizedName ?? $0, pid: app.processIdentifier) } }
            let me = ProcessInfo.processInfo.processIdentifier
            for process in CA.processObjects() where CA.getUInt32(process, kAudioProcessPropertyIsRunningInput) == 1 {
                guard let pid = CA.processPID(process), pid != me else { continue }
                let bundleID = CA.processBundleID(process) ?? ""
                guard let app = MicAttribution.app(forBundleID: bundleID, pid: pid, regularApps: regular),
                      !result.contains(where: { $0.bundleID == app.bundleID }) else { continue }
                result.append(MicClient(bundleID: app.bundleID, name: app.name, pid: app.pid))
            }
        }
        if result != clients {
            clients = result
            onChange?()
        }
    }

    // MARK: - Listeners

    private func addSystemListener(_ selector: AudioObjectPropertySelector, _ action: @escaping @MainActor () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { action() } }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            systemListeners.append((address, block))
        }
    }

    private func addDeviceListener(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                                   _ action: @escaping @MainActor () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { action() } }
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr {
            deviceListeners.append((address, block))
        }
    }

    private func removeDeviceListeners() {
        for (address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        }
        deviceListeners = []
    }
}

/// Maps an audio process to the app the user would recognise.
/// Browsers and Electron apps record from helper processes.
enum MicAttribution {
    typealias App = (bundleID: String, name: String, pid: pid_t)

    static func app(forBundleID bundleID: String, pid: pid_t, regularApps: [App]) -> App? {
        if let exact = regularApps.first(where: { $0.pid == pid }) { return exact }
        // com.google.Chrome.helper → com.google.Chrome, com.tinyspeck.slackmacgap.helper → Slack
        if let parent = regularApps
            .filter({ !bundleID.isEmpty && bundleID.hasPrefix($0.bundleID + ".") })
            .max(by: { $0.bundleID.count < $1.bundleID.count }) {
            return parent
        }
        // Safari's audio comes from WebKit's shared processes.
        if bundleID.hasPrefix("com.apple.WebKit"), let safari = regularApps.first(where: { $0.bundleID == "com.apple.Safari" }) {
            return safari
        }
        // Background system services (Siri, dictation) aren't calls.
        if bundleID.isEmpty || bundleID.hasPrefix("com.apple.") { return nil }
        return (bundleID, bundleID.split(separator: ".").last.map(String.init) ?? bundleID, pid)
    }
}

/// Thin CoreAudio helpers.
enum CA {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultInputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    static func deviceName(_ id: AudioObjectID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static func has(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var address = address(selector, scope: scope, element: element)
        return AudioObjectHasProperty(id, &address)
    }

    static func isSettable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                           element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        guard has(id, selector, scope: scope, element: element) else { return false }
        var address = address(selector, scope: scope, element: element)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    static func getUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        guard has(id, selector, scope: scope) else { return nil }
        var address = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, _ value: UInt32) {
        var address = address(selector, scope: scope)
        var value = value
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func getFloat(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                         element: AudioObjectPropertyElement) -> Float? {
        guard has(id, selector, scope: scope, element: element) else { return nil }
        var address = address(selector, scope: scope, element: element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// The element carrying input volume: the main element, or channel 1 on devices without one.
    static func volumeElement(_ id: AudioObjectID) -> AudioObjectPropertyElement? {
        for element in [kAudioObjectPropertyElementMain, 1] where
            isSettable(id, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element) {
            return element
        }
        return nil
    }

    static func setVolume(_ id: AudioObjectID, _ volume: Float) {
        // Set every settable channel so stereo mics go fully silent.
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] where
            isSettable(id, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element) {
            var address = address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element)
            var value = Float32(volume)
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    @available(macOS 14.2, *)
    static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    @available(macOS 14.2, *)
    static func processPID(_ id: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    @available(macOS 14.2, *)
    static func processBundleID(_ id: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
