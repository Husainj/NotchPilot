import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global keyboard shortcut (Carbon key code + Carbon modifier mask).
public struct HotKeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// Printable key as it appeared when recorded, e.g. "N".
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public static let defaultToggle = HotKeyCombo(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey), keyLabel: "N")

    public var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        // Require at least one of ⌘ ⌥ ⌃ so plain typing never triggers it.
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        let label = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !label.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, keyLabel: label)
    }

    public static func load(key: String, from defaults: UserDefaults) -> HotKeyCombo? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKeyCombo.self, from: data)
    }

    public static func store(_ combo: HotKeyCombo?, key: String, in defaults: UserDefaults) {
        if let combo, let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: key)
        } else {
            // Store an explicit "none" so the default isn't restored on next launch.
            defaults.set(Data(), forKey: key)
        }
    }
}

/// Registers global hotkeys with Carbon (works without Accessibility permission).
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var ids: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    /// Registers (or replaces) the hotkey identified by `name`. Pass nil to remove it.
    public func register(_ name: String, combo: HotKeyCombo?, action: @escaping () -> Void) {
        unregister(name)
        guard let combo else { return }
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4F5443), id: id) // 'NOTC'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        refs[id] = ref
        actions[id] = action
        ids[name] = id
    }

    public func unregister(_ name: String) {
        guard let id = ids.removeValue(forKey: name) else { return }
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id: id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Click, then press a shortcut to record it. Esc cancels, Delete clears.
public struct HotKeyRecorder: View {
    @Binding var combo: HotKeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?

    public init(combo: Binding<HotKeyCombo?>) {
        _combo = combo
    }

    public var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Type shortcut…" : (combo?.displayString ?? "None"))
                .frame(minWidth: 110)
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stopRecording()
            case kVK_Delete, kVK_ForwardDelete:
                combo = nil
                stopRecording()
            default:
                if let recorded = HotKeyCombo(event: event) {
                    combo = recorded
                    stopRecording()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
