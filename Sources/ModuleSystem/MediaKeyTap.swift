import AppKit
import ApplicationServices

/// Intercepts the volume/brightness keys so the island can show its own HUD
/// instead of the system one. Requires Accessibility permission.
@MainActor
final class MediaKeyTap {
    enum Key {
        case volumeUp, volumeDown, mute, brightnessUp, brightnessDown
    }

    /// Return true to consume the key press.
    var handler: ((Key, _ fineStep: Bool) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt if needed.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.isTrusted else { return false }
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: refcon)
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Decodes an NX_SYSDEFINED media-key event; returns true if it was handled.
    fileprivate func handle(_ cgEvent: CGEvent) -> Bool {
        guard let event = NSEvent(cgEvent: cgEvent), event.subtype.rawValue == 8 else { return false }
        let data = event.data1
        let keyCode = (data & 0xFFFF0000) >> 16
        let isKeyDown = ((data & 0xFF00) >> 8) == 0xA
        let key: Key
        switch keyCode {
        case 0: key = .volumeUp          // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown        // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute              // NX_KEYTYPE_MUTE
        case 2: key = .brightnessUp      // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: key = .brightnessDown    // NX_KEYTYPE_BRIGHTNESS_DOWN
        default: return false
        }
        let flags = event.modifierFlags
        // ⌥ alone opens the matching System Settings pane; leave that to the system.
        if flags.contains(.option), !flags.contains(.shift) { return false }
        // Swallow key-ups too, so the system never sees half a key press.
        guard isKeyDown else { return true }
        return handler?(key, flags.contains(.option) && flags.contains(.shift)) ?? false
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    nonisolated(unsafe) let event = event
    nonisolated(unsafe) let context = refcon
    // The tap's run loop source is on the main run loop.
    let consume = MainActor.assumeIsolated {
        let tap = Unmanaged<MediaKeyTap>.fromOpaque(context).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tap.reenable()
            return false
        }
        return tap.handle(event)
    }
    return consume ? nil : Unmanaged.passUnretained(event)
}
