import AudioToolbox
import CoreAudio

/// Reads and sets the default output device's volume and mute state.
enum AudioController {
    private static var defaultOutputDevice: AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// 0...1, or nil when the device has no software volume (e.g. some HDMI outputs).
    static var volume: Float? {
        guard let device = defaultOutputDevice else { return nil }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setVolume(_ newValue: Float) {
        guard let device = defaultOutputDevice else { return }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(min(max(newValue, 0), 1))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if value > 0, isMuted { setMuted(false) }
    }

    static var isMuted: Bool {
        guard let device = defaultOutputDevice else { return false }
        var address = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = defaultOutputDevice else { return }
        var address = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return }
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
